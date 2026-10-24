import AppKit
import Testing

// MARK: - BrowserPeekPanelTests

@Suite(.serialized)
@MainActor struct BrowserPeekPanelTests {
    @Test func theCardCoversMostOfTheWindowAndClosesOrOpensAsATab() throws {
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
        #expect(BrowserPeekSettings.isEnabled || UserDefaults.standard.object(forKey: BrowserUserPreferencesStore.peekEnabledKey) != nil)
    }

    @Test func littleArcIsOptInAndOpensAStandaloneWindow() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(!f.model.opensExternalLinksInLittleWindow, "Links keep opening as tabs by default")
        f.model.userPreferencesStore.littleArcEnabled = true
        #expect(f.model.opensExternalLinksInLittleWindow)
        f.model.openInLittleWindow(try #require(URL(string: "https://example.com/a")))
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
}

