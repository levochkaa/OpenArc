import AppKit
import Testing

// MARK: - BrowserPeekPanelTests

@Suite(.serialized)
@MainActor struct BrowserPeekPanelTests {
    @Test func theCardCoversMostOfTheWindowAndClosesOrOpensAsATab() {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let expected = BrowserPeekPanel.frame(over: window)
        #expect(expected.width == 840 && expected.height == 588)
        #expect(abs(expected.midX - window.frame.midX) <= 1 && abs(expected.midY - window.frame.midY) <= 1)

        let panel = BrowserPeekPanel.present(over: window)
        defer { panel.dismiss() }
        #expect(panel.parent === window)
        #expect(panel.hostView.frame.height == panel.frame.height - BrowserPeekPanel.barHeight)
        panel.update(urlString: "https://www.example.com/page")
        #expect(panel.hostLabel.stringValue == "example.com")

        var closes = 0
        var opens = 0
        panel.onClose = { closes += 1 }
        panel.onOpenInTab = { opens += 1 }
        panel.closeButton.performClick(nil)
        panel.performClose(nil)
        panel.cancelOperation(nil)
        #expect(closes == 3, "Close, Command-W and Escape close the card")
        panel.openButton.performClick(nil)
        #expect(opens == 1)
        panel.dismiss()
        #expect(panel.parent == nil)
        #expect(BrowserPeekSettings.isEnabled || UserDefaults.standard
            .object(forKey: BrowserUserPreferencesStore.peekEnabledKey) != nil)
    }

    @Test func littleArcIsOptInAndOpensAStandaloneWindow() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(!f.model.opensExternalLinksInLittleWindow, "Links keep opening as tabs by default")
        f.model.userPreferencesStore.littleArcEnabled = true
        #expect(f.model.opensExternalLinksInLittleWindow)
        try f.model.openInLittleWindow(#require(URL(string: "https://example.com/a")))
        #expect(f.driver.littleWindowURLs == ["https://example.com/a"])

        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        #expect(panel.isStandalone && panel.parent == nil)
        #expect(panel.styleMask.contains(.resizable) && panel.closeButton.isHidden)
        var closes = 0
        panel.onClose = { closes += 1 }
        panel.cancelOperation(nil)
        #expect(closes == 0, "Escape stays with the page in the small window")
        panel.performClose(nil)
        #expect(closes == 1)
    }

    @Test func theSmallWindowsAddressFieldEditsAndLoadsTheAddress() throws {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        panel.update(urlString: "https://www.example.com/a")
        #expect(panel.hostLabel.stringValue == "example.com" && panel.hostLabel.isEditable)
        var loaded = [String]()
        var opens = 0
        panel.onNavigate = { loaded.append($0) }
        panel.onOpenInTab = { opens += 1 }

        let commandL = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
        ))
        #expect(panel.handleShortcut(commandL))
        let editor = try #require(panel.hostLabel.currentEditor() as? NSTextView)
        #expect(editor.string == "https://www.example.com/a", "Editing shows the full address")
        editor.string = "example.org"
        #expect(panel.control(panel.hostLabel, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(loaded.count == 1 && loaded[0].hasPrefix("https://example.org"))
        #expect(panel.hostLabel.currentEditor() == nil && panel.hostLabel.stringValue == "example.org")

        let commandO = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31
        ))
        #expect(panel.handleShortcut(commandO) && opens == 1, "Command-O opens the page as a tab")
    }

    @Test func openInListsTheWindowsSpacesAndOpensThePageThere() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let spaces = try #require(f.driver.peekSpaces?())
        #expect(spaces.map(\.id) == ["s", "t"] && spaces.map(\.title) == ["Space", "Other"])

        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        var chosen = [String]()
        panel.spacesProvider = { spaces }
        panel.onOpenInSpace = { chosen.append($0) }
        panel.menuNeedsUpdate(panel.openInMenu)
        #expect(panel.openInMenu.items.map(\.title) == [BrowserStrings.peekOpenInMenuTitle, "Space", "Other"])
        panel.openInMenu.performActionForItem(at: 2)
        #expect(chosen == ["t"])

        f.driver.onOpenPeekInSpace?("https://figma.com/file", "t")
        #expect(f.model.selectedSpaceID == "t")
        #expect(f.driver.createdTabRequests.last?.urlString == "https://figma.com/file")
    }

    @Test func newSmallWindowOpensFromTheWindow() {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(f.model.canOpenLittleWindow)
        #expect(f.model.openNewLittleWindow())
        #expect(f.driver.newLittleWindowCount == 1)
        #expect(BrowserCommandID.newLittleWindow.defaultDescriptor.shortcut
            == BrowserKeyboardShortcut("n", modifiers: [.command, .option]))
    }

    @Test func optionCommandClicksIntoTheSmallWindowAreOptIn() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserPeekPanelTests.\(UUID().uuidString)"))
        let store = BrowserUserPreferencesStore(userDefaults: defaults)
        #expect(!store.opensOptionCommandClicksInLittleWindow)
        store.opensOptionCommandClicksInLittleWindow = true
        #expect(defaults.bool(forKey: BrowserUserPreferencesStore.littleWindowOptionCommandClickKey))
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).opensOptionCommandClicksInLittleWindow)
    }

    @Test func closingTheWindowClosesItsPeeks() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.prepareForTermination()
        f.model.prepareForTermination()
        #expect(f.driver.closePeeksCount == 1, "Cards and small windows close once with their window")
    }
}
