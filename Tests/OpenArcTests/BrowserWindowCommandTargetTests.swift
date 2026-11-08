// BrowserWindowCommandTargetTests.swift

import AppKit
import Testing

@MainActor struct BrowserWindowCommandTargetTests {
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

        #expect(BrowserWindowCommandTarget.topLevelWindow(of: tools) === browser)
        #expect(BrowserWindowCommandTarget.topLevelWindow(of: panel) === browser)
        #expect(BrowserWindowCommandTarget.topLevelWindow(of: browser) === browser)
        #expect(BrowserWindowCommandTarget.topLevelWindow(of: nil) == nil)
    }

    @Test func theItemNamesWhatItWillDo() {
        let target = BrowserWindowCommandTarget()
        let item = NSMenuItem(
            title: "",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "",
        )
        item.target = target
        _ = target.validateMenuItem(item)
        #expect([BrowserStrings.menuEnterFullScreen, BrowserStrings.menuExitFullScreen].contains(item.title))

        for action in [#selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:))] {
            let windowItem = NSMenuItem(title: "Window", action: action, keyEquivalent: "")
            _ = target.validateMenuItem(windowItem)
            #expect(windowItem.title == "Window")
        }

        let other = NSMenuItem(title: "Other", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        #expect(target.validateMenuItem(other))
        #expect(other.title == "Other")
    }

    @Test func zoomComparesFramesWithinAPoint() {
        let visible = NSRect(x: 0, y: 25, width: 1728, height: 1084)
        #expect(BrowserWindowCommandTarget.frame(visible.insetBy(dx: 0.3, dy: 0.3), matches: visible))
        #expect(!BrowserWindowCommandTarget.frame(NSRect(x: 184, y: 89, width: 1360, height: 860), matches: visible))
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
