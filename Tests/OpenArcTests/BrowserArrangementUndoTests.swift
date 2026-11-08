// BrowserArrangementUndoTests.swift

import AppKit
import Testing

// MARK: - BrowserArrangementUndoTests

@Suite(.serialized)
@MainActor struct BrowserArrangementUndoTests {
    @Test func undoAndRedoADraggedTab() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.drop("z", before: "x")
        #expect(f.names(f.model.temporaryTabs) == ["z", "x", "y"])
        #expect(f.model.undoManager.undoActionName == BrowserStrings.undoMoveAction)

        f.model.undoManager.undo()
        #expect(f.names(f.model.temporaryTabs) == ["x", "y", "z"])
        #expect(f.model.undoManager.canRedo)

        f.model.undoManager.redo()
        #expect(f.names(f.model.temporaryTabs) == ["z", "x", "y"])
    }

    @Test func undoLeavesLaterUnrecordedMovesAlone() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.drop("z", before: "x")
        // A move without Undo, such as one from sync.
        f.model.commitSidebarDrop(
            payload: f.payload("y"),
            destination: .init(container: .temporary("s"), beforeItem: f.item("z")),
        )
        #expect(f.names(f.model.temporaryTabs) == ["y", "z", "x"])

        f.model.undoManager.undo()
        #expect(f.names(f.model.temporaryTabs) == ["y", "x", "z"])
    }

    @Test func undoPinAndUnpin() {
        let f = SidebarDragFixture(pinned: [("a", nil)], temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        f.model.togglePinned(forTabID: f.id("x"))
        #expect(f.pinnedNames() == ["a", "x"])
        #expect(f.model.undoManager.undoActionName == BrowserStrings.menuPinTab)

        f.model.undoManager.undo()
        #expect(f.pinnedNames() == ["a"])
        #expect(f.names(f.model.temporaryTabs) == ["x", "y"])

        f.model.undoManager.redo()
        #expect(f.pinnedNames() == ["a", "x"])
    }

    @Test func undoRenamingATab() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let id = f.id("x")
        f.model.setUserTitleOverride("Mail", forTabID: id)
        #expect(f.model.undoManager.undoActionName == BrowserStrings.undoRenameAction)

        f.model.undoManager.undo()
        #expect(f.model.tabs.first { $0.id == id }?.userTitleOverride == "x")

        f.model.undoManager.redo()
        #expect(f.model.tabs.first { $0.id == id }?.userTitleOverride == "Mail")
    }

    @Test func renamingToTheSameTitleRegistersNothing() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.setUserTitleOverride("x", forTabID: f.id("x"))
        #expect(!f.model.undoManager.canUndo)
    }

    @Test func undoRenamingAFolderAndASpace() {
        let f = SidebarDragFixture(
            pinned: [("a", "f")],
            folders: [.init(id: "f", spaceID: "s", title: "Folder", isExpanded: true)],
        )
        f.model.setTitle("Work", forPinnedTabFolderID: "f")
        f.model.setTitle("Home", forSpaceID: "s")

        f.model.undoManager.undo()
        #expect(f.model.spaces.first { $0.id == "s" }?.title == "Space")
        #expect(f.model.pinnedTabFolders.first?.title == "Work")

        f.model.undoManager.undo()
        #expect(f.model.pinnedTabFolders.first?.title == "Folder")
    }

    @Test func undoAndRedoOpeningASplit() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        #expect(f.names(f.model.temporaryTabs) == ["x", "z", "y"])

        f.model.undoManager.undo()
        #expect(f.model.splitGroups.isEmpty)
        #expect(f.names(f.model.temporaryTabs) == ["x", "y", "z"])
        #expect(f.store.savedSnapshots.last?.splitGroups == [])

        f.model.undoManager.redo()
        let group = try #require(f.model.splitGroup(containingTabID: f.id("x")))
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), f.id("z")])
        #expect(f.names(f.model.temporaryTabs) == ["x", "z", "y"])
    }

    @Test func undoSeparatingASplitRestoresItsPanesAndLayout() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d"])
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("b")))
        #expect(f.model.openInSplitView(tabID: f.id("c")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitOrientation(.vertical, groupID: group.id))
        #expect(f.model.separateTabFromSplit(tabID: f.id("a")))
        #expect(f.names(f.model.temporaryTabs) == ["b", "c", "a", "d"])

        f.model.undoManager.undo()
        let restored = try #require(f.model.splitGroup(containingTabID: f.id("a")))
        #expect(f.model.splitPaneTabIDs(of: restored) == ["a", "b", "c"].map(f.id))
        #expect(restored.orientation == .vertical)
        #expect(f.names(f.model.temporaryTabs) == ["a", "b", "c", "d"])

        f.model.undoManager.undo()
        #expect(f.model.splitGroup(containingTabID: f.id("a"))?.orientation == .horizontal)
    }

    @Test func undoSeparatingAllTabs() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.separateSplitGroup(id: group.id))
        #expect(f.model.undoManager.undoActionName == BrowserStrings.splitSeparateAllTabsAction)

        f.model.undoManager.undo()
        #expect(f.model.splitGroups.map(\.id) == [group.id])
    }

    @Test func undoMovingASpace() {
        let f = SidebarDragFixture()
        #expect(f.model.moveSpace(id: "t", toIndex: 0))
        #expect(f.model.spaces.map(\.id) == ["t", "s"])

        f.model.undoManager.undo()
        #expect(f.model.spaces.map(\.id) == ["s", "t"])
    }

    @Test func oneUndoBringsBackEveryTabClearClosed() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z", "w"])
        f.model.selectTab(id: f.id("w"))
        f.model.clearTemporaryTabs(includingActiveTab: false)
        #expect(f.names(f.model.temporaryTabs) == ["w"])
        #expect(f.model.undoManager.undoActionName == BrowserStrings.sidebarClearTemporaryTabs)

        f.model.undoManager.undo()
        f.driver.flushPendingCreateEvents()
        #expect(f.names(f.model.temporaryTabs) == ["x", "y", "z", "w"])
        #expect(f.model.undoManager.canRedo)

        f.model.undoManager.redo()
        #expect(f.names(f.model.temporaryTabs) == ["w"])
        f.model.undoManager.undo()
        f.driver.flushPendingCreateEvents()
        #expect(f.names(f.model.temporaryTabs) == ["x", "y", "z", "w"])
    }

    @Test func clearClosesConfirmedOutOfOrderStillUndoTogether() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.driver.automaticallyConfirmsCloseRequests = false
        f.model.selectTab(id: f.id("z"))
        f.model.clearTemporaryTabs(includingActiveTab: false)
        let requests = f.driver.confirmedCloseRequests
        #expect(requests.count == 2)
        for request in requests.reversed() {
            f.driver.emitCloseRequestOutcome(id: request.id, requestID: request.requestID, outcome: .closed)
        }
        #expect(f.names(f.model.temporaryTabs) == ["z"])
        f.driver.automaticallyConfirmsCloseRequests = true

        f.model.undoManager.undo()
        f.driver.flushPendingCreateEvents()
        #expect(f.names(f.model.temporaryTabs) == ["x", "y", "z"])
        #expect(!f.model.undoManager.canUndo)
    }

    @Test func aClosedTabAfterClearIsItsOwnUndo() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("z"))
        f.model.clearTemporaryTabs(includingActiveTab: false)
        f.model.closeTab(id: f.id("z"))
        #expect(f.model.undoManager.undoActionName == BrowserStrings.tabArchiveAction)

        f.model.undoManager.undo()
        f.driver.flushPendingCreateEvents()
        #expect(f.names(f.model.temporaryTabs) == ["z"])
        f.model.undoManager.undo()
        f.driver.flushPendingCreateEvents()
        #expect(f.names(f.model.temporaryTabs) == ["x", "y", "z"])
    }

    @Test func movedItemsAreTheFewestThatChangedPlace() {
        typealias Arrangement = BrowserChromeModel.SidebarArrangement
        func arrangement(_ names: [String]) -> Arrangement {
            Arrangement(
                children: [.temporary("s"): names.map { .tab(syncID: $0) }],
                tabTitles: [:], folderTitles: [:], spaceTitles: [:], spaceOrder: [], splitGroups: [],
            )
        }
        let moved = BrowserChromeModel.movedItems(
            from: arrangement(["a", "b", "c", "d", "e"]),
            to: arrangement(["a", "d", "b", "c", "e"]),
        )
        #expect(moved == [.tab(syncID: "d")])
        #expect(BrowserChromeModel.longestIncreasingSubsequence([3, 0, 1, 2]) == [1, 2, 3])
        #expect(BrowserChromeModel.longestIncreasingSubsequence([]).isEmpty)
    }
}

extension SidebarDragFixture {
    /// A sidebar drag, recorded for Undo like the sidebar records it.
    func drop(_ name: String, before anchor: String?) {
        model.withArrangementUndo(BrowserStrings.undoMoveAction) {
            model.commitSidebarDrop(
                payload: payload(name),
                destination: .init(container: .temporary("s"), beforeItem: anchor.map(item)),
            )
        }
    }
}
