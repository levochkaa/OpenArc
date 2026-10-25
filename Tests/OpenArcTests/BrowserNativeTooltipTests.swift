// BrowserNativeTooltipTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeTooltipTests {
    @Test func tooltipWrapsLongTextWithinViewportAndKeepsShortcutVisible() {
        let shortcut = BrowserKeyboardShortcut("r", modifiers: [.command, .shift])
        let view = BrowserNativeTooltipContent(
            title: String(repeating: "Long title ", count: 20),
            caption: String(repeating: "Long caption ", count: 20),
            shortcut: shortcut,
            placement: .belowLeading,
        )
        let size = view.measuredSize(maximumWidth: 320)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        #expect(size.width <= 320)
        #expect(size.height > BrowserChromeLayout.tooltipKeyHeight)
        #expect(view.subviews.allSatisfy { view.bounds.contains($0.frame) })
        #expect(!view.roundsTopLeadingCorner)
        #expect(view.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.maximumNumberOfLines == 2 })
    }

    @Test func capsuleTooltipShrinksToContentAndHasNoEmptyCaption() {
        let view = BrowserNativeTooltipContent(title: "Back", caption: nil, shortcut: nil, placement: .aboveCapsule)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        #expect(view.frame.width < 100)
        #expect(view.roundsTopLeadingCorner)
        #expect(view.cornerRadius == view.bounds.height / 2)
        #expect(view.subviews.count(where: { !$0.isHidden }) == 1)
    }

    @Test func chromeButtonRetainsActionsAndAccessibilityAcrossStateChanges() {
        var count = 0
        let button = BrowserNativeChromeButton(symbol: "arrow.clockwise", title: "Reload") { count += 1 }
        button.performClick(nil)
        button.isEnabled = false
        button.performClick(nil)
        #expect(count == 1)
        button.isEnabled = true
        button.configureSymbol("xmark", title: "Stop")
        button.performClick(nil)
        #expect(count == 2)
        #expect(button.imagePosition == .imageOnly)
        #expect(button.accessibilityLabel() == "Stop")
        #expect(button.toolTip == nil, "Only the custom tooltip should appear")
    }
}
