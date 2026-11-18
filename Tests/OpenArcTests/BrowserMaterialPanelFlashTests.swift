// BrowserMaterialPanelFlashTests.swift

import AppKit
import Testing

// MARK: - BrowserMaterialPanelFlashTests

@MainActor struct BrowserMaterialPanelFlashTests {
    @Test func aSiteSearchFlashGlowsTintsAndDipsInTheSitesColor() throws {
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let panel = BrowserNativeMaterialPanel(frame: NSRect(x: 0, y: 0, width: 600, height: 64))
        panel.layoutSubtreeIfNeeded()
        panel.flash(color: .systemPurple)
        #expect(panel.layer?.animation(forKey: "siteSearchFlash") == nil, "The flash waits for the card's new size")
        panel.layoutSubtreeIfNeeded()
        let glow = try #require(panel.layer?.sublayers?.first { $0.animation(forKey: "siteSearchFlash") != nil })
        #expect(glow.shadowColor == NSColor.systemPurple.cgColor)
        #expect(glow.animation(forKey: "siteSearchFlash")?.duration == 1)
        #expect(glow.shadowOpacity == 0, "Nothing stays after the flash")
        let tint = panel.contentView.layer?.sublayers?.first { $0.animation(forKey: "siteSearchFlash") != nil }
        #expect(tint?.backgroundColor == NSColor.systemPurple.withAlphaComponent(0.2).cgColor)
        #expect(tint?.opacity == 0)
        let dip = try #require(panel.layer?.animation(forKey: "siteSearchFlash") as? CAKeyframeAnimation)
        let smallest = try #require(dip.values?
            .compactMap { ($0 as? NSValue)?.caTransform3DValue }
            .min { $0.m11 < $1.m11 })
        #expect(abs(smallest.m11 - 0.989) < 0.0001)
        #expect(abs(smallest.m41 + 300 * (smallest.m11 - 1)) < 0.001, "The card shrinks around its center")
        #expect(CATransform3DIsIdentity(panel.layer?.transform ?? CATransform3DIdentity))
    }
}
