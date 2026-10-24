import AppKit
import Testing

// MARK: - BrowserTabRowActionTests

@Suite(.serialized)
@MainActor struct BrowserTabRowActionTests {
    @Test func duplicateOpensTheSamePageBelowATemporaryTab() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        let copy = try #require(f.model.duplicateTab(id: x))
        #expect(f.model.temporaryTabs.map(\.id) == [x, copy, f.id("y")])
        #expect(f.model.tabs.first { $0.id == copy }?.urlString == "https://x.example")
        #expect(f.model.selectedTabID == copy)

        let pinnedCopy = try #require(f.model.duplicateTab(id: f.id("a")))
        #expect(f.model.temporaryTabs.first?.id == pinnedCopy, "A pinned tab's copy opens at the top of the temporary tabs")
        #expect(f.pinnedNames() == ["a", "b"])
    }

    @Test func moveToPutsTheTabAtTheTopOfTheSameSectionInAnotherSpace() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        #expect(f.model.spacesForMovingTab(id: f.id("y")).map(\.id) == ["t"])
        #expect(f.model.moveTabToSpace(id: f.id("y"), spaceID: "t"))
        #expect(f.model.tabs.first { $0.id == f.id("y") }?.spaceID == "t")
        #expect(f.model.tabs.first { $0.id == f.id("y") }?.placement == .temporary)
        #expect(f.model.temporaryTabs.map(\.id) == [f.id("x")])
        #expect(!f.model.moveTabToSpace(id: f.id("x"), spaceID: "s"), "A tab cannot move to its own Space")
        #expect(f.model.moveTabToSpace(id: f.id("a"), spaceID: "t"))
        #expect(f.model.tabs.first { $0.id == f.id("a") }?.placement == .spacePinned)
    }

    @Test func archivingOthersOrAboveClosesOnlyTemporaryTabs() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z", "w"])
        #expect(f.model.temporaryTabIDsAbove(id: f.id("z")) == [f.id("x"), f.id("y")])
        #expect(f.model.temporaryTabIDsAbove(id: f.id("a")).isEmpty, "Pinned rows have no such action")
        f.model.closeTemporaryTabsAbove(id: f.id("y"))
        #expect(f.names(f.model.temporaryTabs) == ["y", "z", "w"])
        f.model.selectTab(id: f.id("z"))
        #expect(f.model.openInSplitView(tabID: f.id("w")))
        #expect(f.model.otherTemporaryTabIDs(id: f.id("z")) == [f.id("y")], "A split keeps its own panes")
        f.model.closeOtherTemporaryTabs(id: f.id("z"))
        #expect(f.names(f.model.temporaryTabs) == ["z", "w"])
        #expect(f.pinnedNames() == ["a", "b"], "Pinned tabs stay")
    }
}
