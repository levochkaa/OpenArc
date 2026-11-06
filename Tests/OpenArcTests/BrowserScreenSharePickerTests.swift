// BrowserScreenSharePickerTests.swift

import AppKit
import Testing

// MARK: - BrowserScreenSharePickerTests

@MainActor struct BrowserScreenSharePickerTests {
    @Test func aSourceTileIsOneButtonAssistiveAppsCanPress() {
        var chosen = [(String, Bool)]()
        let tile = BrowserScreenShareTile(source: .window(id: 7, title: "Notes", app: "TextEdit")) { tile, confirms in
            chosen.append((tile.source.mediaID, confirms))
        }
        #expect(tile.isAccessibilityElement())
        #expect(tile.accessibilityRole() == .button)
        #expect(tile.accessibilityLabel() == "Notes, TextEdit")
        #expect(tile.subviews.allSatisfy { !$0.isAccessibilityElement() }, "Its labels are read as the button")
        #expect(tile.accessibilityPerformPress())
        #expect(
            chosen.count == 1 && chosen[0].0 == "window:7:0" && chosen[0].1 == false,
            "A press chooses, it doesn't share",
        )
        tile.isChosen = true
        #expect(tile.isAccessibilitySelected())

        let screen = BrowserScreenShareTile(source: .screen(id: 1, title: "Entire Screen")) { _, _ in }
        #expect(screen.accessibilityLabel() == "Entire Screen")
    }
}
