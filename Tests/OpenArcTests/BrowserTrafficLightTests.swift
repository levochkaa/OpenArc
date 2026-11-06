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
}
