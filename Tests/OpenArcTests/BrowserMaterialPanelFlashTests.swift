// BrowserMaterialPanelFlashTests.swift

import AppKit
import Testing

// MARK: - BrowserMaterialPanelFlashTests

@MainActor struct BrowserMaterialPanelFlashTests {
    @Test func aSiteSearchFlashGlowsAndTintsInTheSitesColor() throws {
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let panel = BrowserNativeMaterialPanel(frame: NSRect(x: 0, y: 0, width: 600, height: 64))
        panel.layoutSubtreeIfNeeded()
        panel.flash(color: .systemPurple)
        let glow = try #require(panel.layer?.sublayers?.first { $0.animation(forKey: "siteSearchFlash") != nil })
        #expect(glow.shadowColor == NSColor.systemPurple.cgColor)
        #expect(glow.animation(forKey: "siteSearchFlash")?.duration == 1)
        #expect(glow.shadowOpacity == 0, "Nothing stays after the flash")
        let tint = panel.subviews.first?.layer?.sublayers?.first { $0.animation(forKey: "siteSearchFlash") != nil }
        #expect(tint?.backgroundColor == NSColor.systemPurple.cgColor)
        #expect(tint?.opacity == 0)
    }
}
