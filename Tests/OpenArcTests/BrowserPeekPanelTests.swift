// BrowserPeekPanelTests.swift

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
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let expected = BrowserPeekPanel.frame(over: window)
        #expect(expected.width == 840 && expected.height == 588)
        #expect(abs(expected.midX - window.frame.midX) <= 1 && abs(expected.midY - window.frame.midY) <= 1)

        let panel = BrowserPeekPanel.present(over: window)
        defer { panel.dismiss() }
        #expect(panel.parent === window)
        #expect(panel.frame == window.frame, "It covers the window so the card can grow past its size")
        #expect(panel.cardScreenFrame == expected)
        #expect(panel.hostView.frame.height == expected.height - BrowserPeekPanel.barHeight)
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

    @Test func findWorksInTheCardsOwnPage() {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        #expect(!panel.canFind, "Find waits for the page")
        var finds = [String]()
        var stops = 0
        panel.onFind = { text, forward, selects in finds.append("\(text) \(forward) \(selects)") }
        panel.onStopFinding = { stops += 1 }
        #expect(panel.canFind)

        panel.presentFind()
        #expect(finds.isEmpty, "An empty query searches nothing")
        panel.findBar.queryField.stringValue = "needle"
        panel.findBar.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: panel.findBar.queryField,
        ))
        #expect(finds == ["needle true true"], "A typed query selects its first match")

        panel.updateFindResult(count: 3, activeOrdinal: 1, finalUpdate: true)
        panel.findBar.layoutSubtreeIfNeeded()
        #expect(panel.findBar.countLabel.stringValue == "1/3")
        panel.findNext()
        panel.findPrevious()
        #expect(finds.suffix(2) == ["needle true true", "needle false true"])

        panel.updateFindResult(count: 0, activeOrdinal: 0, finalUpdate: true)
        #expect(!panel.canStepThroughFindMatches)
        panel.findNext()
        #expect(finds.count == 3, "No match, nothing to step to")

        let editor = NSTextView()
        _ = panel.findBar.control(
            panel.findBar.queryField,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)),
        )
        #expect(stops == 1, "Escape closes find and clears the page's highlights")
        #expect(!panel.canStepThroughFindMatches)
    }

    @Test func theSmallWindowBarNamesTheSpaceItOpensIn() throws {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        panel.spacesProvider = {
            [
                BrowserPeekSpace(id: "a", title: "Home", systemImageName: "house"),
                BrowserPeekSpace(id: "b", title: "Work", systemImageName: "briefcase", isSelected: true),
            ]
        }
        panel.refreshOpenInTitle()
        #expect(panel.openInButton.accessibilityLabel() == BrowserStrings.peekOpenInPrefix + "Work")
        var opened = 0
        panel.onOpenInTab = { opened += 1 }
        #expect(panel.openInButton.accessibilityPerformPress())
        #expect(opened == 1)
        #expect(panel.openButton.isHidden, "The labeled button replaces the icon")
        #expect(!panel.addressPill.isHidden && panel.addressPill.frame.maxX < panel.openInButton.frame.minX)
        #expect(
            panel.copyLinkButton.tooltipShortcut == BrowserShortcutStore().shortcut(for: .copyLink),
            "Copy Link's tooltip names its keys",
        )

        panel.update(urlString: "https://example.com/a")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        panel.copyLinkButton.performClick(nil)
        #expect(pasteboard.string(forType: .string) == "https://example.com/a")
        #expect(!panel.copiedToast.isHidden, "Copying shows the note")
        #expect(try panel.copiedToast.frame.maxX <= #require(panel.contentView?.bounds.maxX))
    }

    @Test func theSmallWindowBarHasAnExtensionsButtonClearOfTheAddress() {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        let extensions = panel.extensionsButton
        #expect(extensions.superview === panel.addressPill)
        #expect(extensions.frame.maxX < panel.copyLinkButton.frame.minX, "Left of Copy Link")
        let buttonInBar = extensions.convert(extensions.bounds, to: panel.hostLabel.superview)
        #expect(panel.hostLabel.frame.maxX <= buttonInBar.minX, "The address does not cover it")
        #expect(extensions.accessibilityIdentifier() == "browser.peek.extensions")
    }

    @Test func theSmallWindowShowsTheLinkUnderThePointer() {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        let page = panel.hostView.frame
        panel.updateLinkStatus("https://www.iana.org/help/example-domains")
        let pill = panel.linkStatus.frame
        #expect(pill.minX == page.minX + BrowserPeekPanel.linkStatusInset)
        #expect(pill.minY == page.minY + BrowserPeekPanel.linkStatusInset, "At the page's bottom left")
        #expect(pill.height == BrowserPeekPanel.linkStatusHeight)
        #expect(pill.width > 0 && pill.width <= page.width * 0.6)
        #expect(panel.linkStatus.superview != nil)
    }

    @Test func newTabInTheSmallWindowSearchesOverItsPageAndGoesThereInIt() async throws {
        let f = SidebarDragFixture()
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        var navigated = [String]()
        let model = f.model.makeLittleWindowSearchModel { navigated.append($0) }
        panel.presentSearch(model: model)
        let bar = try #require(panel.searchBar)
        #expect(model.isPresented && bar.showsCloseButton)
        #expect(bar.panelWidthLimit == BrowserLittleWindowLauncher.barWidth, "As wide as the small window bar")

        model.query = "example.com"
        model.submitSelection()
        #expect(navigated.count == 1 && navigated[0].contains("example.com"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.searchBar == nil && bar.superview == nil, "A result closes the search")
    }

    @Test func viewSourceShowsTheSourceInTheCardItself() {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        var targets = [String]()
        panel.onNavigate = { targets.append($0) }
        panel.update(urlString: "https://example.com/")
        #expect(panel.viewSource())
        #expect(targets == ["view-source:https://example.com/"])
    }

    @Test func backForwardAndReloadGoToTheCardsPage() {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        var commands = [Int]()
        panel.onNavigationCommand = { commands.append($0) }
        panel.navigate(.back)
        panel.navigate(.forward)
        panel.navigate(.reload)
        panel.navigate(.forceReload)
        #expect(commands == [0, 1, 2, 3], "The engine's numbering")
    }

    @Test func theSmallWindowZoomsItsPageInStepsWithANote() {
        let panel = BrowserPeekPanel.presentStandalone()
        defer { panel.dismiss() }
        var levels = [Double]()
        panel.onSetZoomLevel = { levels.append($0) }
        panel.zoom(step: 1)
        #expect(panel.zoomPercent == 110 && abs(levels[0] - log(1.1) / log(1.2)) < 0.0001)
        #expect(!panel.copiedToast.isHidden, "The new zoom shows at the top right")
        panel.zoom(step: -1)
        panel.zoom(step: -1)
        #expect(panel.zoomPercent == 90)
        panel.zoom(step: 0)
        #expect(panel.zoomPercent == 100 && levels.last == 0)
    }

    @Test func theSpacePickerFiltersAndOpensTheChosenSpace() {
        let picker = BrowserPeekSpacePicker(spaces: [
            BrowserPeekSpace(id: "a", title: "Home", systemImageName: "house"),
            BrowserPeekSpace(id: "b", title: "Work", systemImageName: "briefcase", isSelected: true),
        ])
        var chosen = [String]()
        picker.onChoose = { chosen.append($0) }
        #expect(picker.preferredSize.height == BrowserPeekSpacePicker.fieldHeight + 2 * BrowserPeekSpacePicker
            .rowHeight + 4)
        let editor = NSTextView()
        _ = picker.control(picker.searchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(chosen == ["b"], "Return opens the highlighted Space, the window's own at first")
        picker.searchField.stringValue = "ho"
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        _ = picker.control(picker.searchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(chosen.last == "a", "Typing narrows the Spaces")
    }

    @Test func smallWindowIsOnByDefaultAndOpensAStandaloneWindow() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(f.model.opensExternalLinksInLittleWindow, "Links from other apps open in a small window by default")
        f.model.userPreferencesStore.littleArcEnabled = false
        #expect(!f.model.opensExternalLinksInLittleWindow)
        f.model.userPreferencesStore.littleArcEnabled = true
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
            context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37,
        ))
        #expect(panel.handleShortcut(commandL))
        #expect(panel.isEditingAddress, "The engine keeps a loading page from taking these keys")
        let editor = try #require(panel.hostLabel.currentEditor() as? NSTextView)
        #expect(editor.string == "https://www.example.com/a", "Editing shows the full address")
        editor.string = "example.org"
        #expect(panel.control(panel.hostLabel, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(loaded.count == 1 && loaded[0].hasPrefix("https://example.org"))
        #expect(panel.hostLabel.currentEditor() == nil && panel.hostLabel.stringValue == "example.org")

        let commandO = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31,
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

    @Test func aCardOpensBesideThePageInASplitView() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let card = BrowserPeekPanel.present(over: window)
        defer { card.dismiss() }
        var splits = 0
        card.onOpenInSplitView = { splits += 1 }
        #expect(!card.splitButton.isHidden)
        card.splitButton.performClick(nil)
        #expect(splits == 1)
        let small = BrowserPeekPanel.presentStandalone()
        defer { small.dismiss() }
        #expect(small.splitButton.isHidden, "A small window has no page beside it")

        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.onOpenPeekInSplitView?("https://figma.com/file")
        let group = try #require(f.model.selectedSplitGroup)
        let panes = f.model.splitPaneTabIDs(of: group)
        #expect(panes.first == f.id("x") && panes.count == 2)
        #expect(f.driver.createdTabRequests.last?.urlString == "https://figma.com/file")
    }

    @Test func aClosedPeekReopensWithRestoreLastClosedTab() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.onPeekClosedByUser?("https://peek.example/a", false)
        #expect(f.model.canRestoreLastClosedTab)
        #expect(f.model.restoreLastClosedTab())
        #expect(f.driver.peekURLs == ["https://peek.example/a"])

        f.driver.onPeekClosedByUser?("https://small.example", true)
        #expect(f.model.restoreLastClosedTab())
        #expect(f.driver.littleWindowURLs == ["https://small.example"], "A small window reopens as one")
        f.driver.onPeekClosedByUser?("about:blank", true)
        #expect(!f.model.canRestoreLastClosedTab, "An empty small window leaves nothing to reopen")
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
        let defaults = try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserPeekPanelTests")))
        let store = BrowserUserPreferencesStore(userDefaults: defaults)
        #expect(!store.opensOptionCommandClicksInLittleWindow)
        store.opensOptionCommandClicksInLittleWindow = true
        #expect(defaults.bool(forKey: BrowserUserPreferencesStore.littleWindowOptionCommandClickKey))
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).opensOptionCommandClicksInLittleWindow)
        #expect(!store.opensLittleWindowFromAnyApp, "The any-app shortcut is off until turned on")
    }

    @Test func closingTheWindowClosesItsPeeks() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.prepareForTermination()
        f.model.prepareForTermination()
        #expect(f.driver.closePeeksCount == 1, "Cards and small windows close once with their window")
    }
}

// MARK: - BrowserDevToolsDockMenuTests

@Suite(.serialized)
@MainActor struct BrowserDevToolsDockMenuTests {
    @Test func theToolsEdgeMenuDocksThemToAnotherSideAndKeepsIt() throws {
        let key = BrowserDevToolsDockSide.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(BrowserDevToolsDockMenu.currentSide == .right, "At the right by default")
        var notified = 0
        let observer = NotificationCenter.default.addObserver(
            forName: BrowserDevToolsDockSide.didChangeNotification, object: nil, queue: nil,
        ) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let menu = BrowserDevToolsDockMenu.menu()
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == BrowserDevToolsDockSide.allCases.map(\.title))
        #expect(menu.items.first?.state == .on)
        let bottom = try #require(menu.items.first { $0.title == BrowserDevToolsDockSide.bottom.title })
        _ = bottom.target?.perform(bottom.action, with: bottom)
        #expect(BrowserDevToolsDockMenu.currentSide == .bottom)
        #expect(notified == 1)
    }
}
