// BrowserFullScreenMenuTargetTests.swift

import AppKit
import Testing

@MainActor struct BrowserFullScreenMenuTargetTests {
    @Test func aChildWindowGivesFullScreenToTheWindowItBelongsTo() {
        let browser = makeWindow()
        let tools = makeWindow()
        let panel = makeWindow()
        browser.addChildWindow(tools, ordered: .above)
        tools.addChildWindow(panel, ordered: .above)
        defer {
            tools.removeChildWindow(panel)
            browser.removeChildWindow(tools)
            for window in [panel, tools, browser] {
                window.orderOut(nil)
            }
        }

        #expect(BrowserFullScreenMenuTarget.topLevelWindow(of: tools) === browser)
        #expect(BrowserFullScreenMenuTarget.topLevelWindow(of: panel) === browser)
        #expect(BrowserFullScreenMenuTarget.topLevelWindow(of: browser) === browser)
        #expect(BrowserFullScreenMenuTarget.topLevelWindow(of: nil) == nil)
    }

    @Test func theItemNamesWhatItWillDo() {
        let target = BrowserFullScreenMenuTarget()
        let item = NSMenuItem(
            title: "",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "",
        )
        item.target = target
        _ = target.validateMenuItem(item)
        #expect([BrowserStrings.menuEnterFullScreen, BrowserStrings.menuExitFullScreen].contains(item.title))

        let other = NSMenuItem(title: "Other", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        #expect(target.validateMenuItem(other))
        #expect(other.title == "Other")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
