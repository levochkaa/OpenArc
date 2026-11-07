// BrowserTabSwitcherLayoutTests.swift

import AppKit
import Testing

// MARK: - BrowserTabSwitcherLayoutTests

struct BrowserTabSwitcherLayoutTests {
    @Test func cardsKeepTheirSizeAndThePanelFitsThem() {
        let layout = BrowserTabSwitcherLayout(containerSize: CGSize(width: 2400, height: 1300), entryCount: 4)
        #expect(layout.cardWidth == 180 && layout.cardHeight == 156)
        #expect(layout.panelWidth == CGFloat(4 * 180 + 3 * 2 + 32))
        #expect(layout.panelHeight == CGFloat(156 + 32))
    }

    @Test func aNarrowWindowScrollsTheCardsInsteadOfShrinkingThem() {
        let layout = BrowserTabSwitcherLayout(containerSize: CGSize(width: 600, height: 800), entryCount: 8)
        #expect(layout.panelWidth == CGFloat(600 - 32))
        #expect(layout.cardWidth == 180)
        #expect(layout.contentWidth > layout.panelWidth)
    }
}
