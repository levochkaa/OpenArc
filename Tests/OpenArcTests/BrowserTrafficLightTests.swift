// BrowserTrafficLightTests.swift

import AppKit
import Testing

// MARK: - BrowserTrafficLightTests

@MainActor struct BrowserTrafficLightTests {
    /// Buttons of a background window are plain gray discs; the
    /// colored rim belongs to the window in front. The test bundle has no
    /// app assets, so only the background state, drawn in code, is rendered.
    @Test func aWindowInTheBackgroundDrawsGrayDiscsWithoutTheColoredRim() throws {
        let side = BrowserWindowControlsLayout.buttonSize
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = BrowserTrafficLightButton(buttonType: type)
            button.frame = NSRect(x: 0, y: 0, width: side, height: side)
            button.isWindowFocused = false
            let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / side
            for x in [Int(1 * scale), rep.pixelsWide / 2] {
                let color = try #require(rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                #expect(color.alphaComponent > 0.5)
                #expect(abs(color.redComponent - color.greenComponent) < 0.03, "Gray, not colored")
                #expect(abs(color.greenComponent - color.blueComponent) < 0.03)
            }
        }
    }

    @Test func assistiveAppsCanPressTheWindowButtons() {
        final class Target: NSObject {
            var presses = 0
            @objc func press(_: Any?) { presses += 1 }
        }
        let target = Target()
        let button = BrowserTrafficLightButton(buttonType: .miniaturizeButton)
        button.target = target
        button.action = #selector(Target.press(_:))
        #expect(button.accessibilityPerformPress())
        #expect(target.presses == 1)
        button.isEnabled = false
        #expect(!button.accessibilityPerformPress(), "A disabled button does nothing")
        #expect(target.presses == 1)
    }

    @Test func windowButtonsAreNamedLikeTheSystemOnes() {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true,
        )
        let host = BrowserWindowControlsHostView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let buttons = host.subviews.compactMap { $0 as? BrowserTrafficLightButton }
        #expect(buttons.count == 3)
        #expect(Set(buttons.compactMap { $0.accessibilitySubrole() }) == [
            .closeButton,
            .minimizeButton,
            .fullScreenButton,
        ])
        #expect(buttons.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty })
    }
}
