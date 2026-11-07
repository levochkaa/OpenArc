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

// MARK: - BrowserTabSwitcherSplitTests

@Suite(.serialized)
@MainActor struct BrowserTabSwitcherSplitTests {
    @Test func aSplitViewIsOneCardWithEveryPane() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.model.advanceTabSwitcher())
        let entries = f.model.tabSwitcherState?.entries ?? []
        let ids = entries.map { $0.id }
        #expect(Set(ids).intersection([f.id("x"), f.id("y")]).count == 1, "The split is listed once")
        #expect(ids.contains(f.id("z")))
        let split = entries.first { !$0.splitPanes.isEmpty }
        #expect(Set(split?.splitPanes.map { $0.tab.id } ?? []) == [f.id("x"), f.id("y")])
        #expect(entries.first { $0.id == f.id("z") }?.splitPanes.isEmpty == true)
    }
}
