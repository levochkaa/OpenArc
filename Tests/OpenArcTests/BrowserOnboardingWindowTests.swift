// BrowserOnboardingWindowTests.swift

import AppKit
import Foundation
import Testing

@MainActor struct BrowserOnboardingWindowTests {
    private static func render(_ view: NSView) -> NSBitmapImageRep? {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @Test func everyStepDrawsItsOwnGroundAndOneReturnAction() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserOnboardingWindowTests.\(UUID().uuidString)"))
        let controller = BrowserOnboardingWindowController(
            preferences: BrowserUserPreferencesStore(userDefaults: defaults),
        )
        let views = controller.stepViewsForTesting()
        #expect(views.count == 5)
        let directory = ProcessInfo.processInfo.environment["OPENARC_ONBOARDING_SNAPSHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        for (index, view) in views.enumerated() {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let returnButtons = descendants(view).compactMap { $0 as? NSButton }.filter { $0.keyEquivalent == "\r" }
            #expect(returnButtons.count == 1, "step \(index) has \(returnButtons.count) Return buttons")
            let rep = try #require(Self.render(view))
            // The blue bookends and the paper steps both fill the whole window.
            let corner = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
            #expect(corner.alphaComponent > 0.99)
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("step-\(index).png"))
            }
        }
    }

    /// However many browsers this Mac has, a step's controls and text never
    /// overlap: the window grows instead.
    @Test func stepsGrowSoTheirControlsNeverOverlap() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserOnboardingWindowTests.\(UUID().uuidString)"))
        let controller = BrowserOnboardingWindowController(
            preferences: BrowserUserPreferencesStore(userDefaults: defaults),
        )
        for (index, view) in controller.stepViewsForTesting().enumerated() {
            func leaves(_ view: NSView) -> [NSView] {
                if view is NSButton || view is NSTextField { return view.isHidden ? [] : [view] }
                return view.subviews.flatMap(leaves)
            }
            let frames = leaves(view).map { $0.convert($0.bounds, to: view) }.filter { $0.width > 0 && $0.height > 0 }
            for (a, first) in frames.enumerated() {
                for second in frames[(a + 1)...] {
                    let overlap = first.intersection(second)
                    #expect(overlap.width < 1 || overlap.height < 1, "step \(index): \(first) overlaps \(second)")
                }
            }
        }
    }
}
