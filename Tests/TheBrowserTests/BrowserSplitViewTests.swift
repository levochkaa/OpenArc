import Foundation
import GRDB
import Testing

// MARK: - BrowserSplitViewModelTests

@Suite(.serialized)
@MainActor struct BrowserSplitViewModelTests {
    @Test func openInSplitViewKeepsTheAnchorRowAndFocusesTheNewPane() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        #expect(f.names(f.model.temporaryTabs) == ["x", "z", "y"])
        #expect(f.model.selectedTabID == f.id("z"))
        let group = try #require(f.model.splitGroup(containingTabID: f.id("x")))
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), f.id("z")])
        #expect(f.model.splitPaneTabIDs(forTabID: f.id("y")) == [f.id("y")])
        let saved = try #require(f.store.savedSnapshots.last?.splitGroups?.first)
        #expect(saved.tabIDs == [f.syncID("x"), f.syncID("z")])
        #expect(saved.focusedTabID == f.syncID("z"))
        #expect(saved.orientation == .horizontal)
    }

    @Test func selectingAPaneRemembersFocusWithoutChangingTheGroup() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        f.model.selectTab(id: f.id("x"))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(group.focusedTabSyncID == f.syncID("x"))
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), f.id("y")])
        f.model.selectTab(id: f.id("z"))
        #expect(f.model.selectedSplitGroup == nil)
        #expect(f.store.savedSnapshots.last?.splitGroups?.first?.focusedTabID == f.syncID("x"))
    }

    @Test func addingToAnExistingSplitAppendsAPaneUpToTheLimit() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d", "e"])
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("c")))
        #expect(f.model.openInSplitView(tabID: f.id("e")))
        #expect(f.model.openInSplitView(tabID: f.id("b")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == ["a", "c", "e", "b"].map(f.id))
        #expect(f.names(f.model.temporaryTabs) == ["a", "c", "e", "b", "d"])
        #expect(!f.model.openInSplitView(tabID: f.id("d")), "Splits hold at most four panes")
        #expect(!f.model.openInSplitView(tabID: f.id("a")), "A visible pane cannot be added twice")
    }

    @Test func separateAllKeepsPaneOrderAndTheFocusedTab() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.separateSplitGroup(id: group.id))
        #expect(f.model.splitGroups.isEmpty)
        #expect(f.names(f.model.temporaryTabs) == ["x", "z", "y"])
        #expect(f.model.selectedTabID == f.id("z"))
        #expect(f.store.savedSnapshots.last?.splitGroups == [])
    }

    @Test func separatingOneTabMovesItAfterTheRemainingPanes() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d"])
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("b")))
        #expect(f.model.openInSplitView(tabID: f.id("c")))
        #expect(f.model.separateTabFromSplit(tabID: f.id("a")))
        let group = try #require(f.model.splitGroup(containingTabID: f.id("b")))
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("b"), f.id("c")])
        #expect(f.names(f.model.temporaryTabs) == ["b", "c", "a", "d"])
        #expect(f.model.separateTabFromSplit(tabID: f.id("c")))
        #expect(f.model.splitGroups.isEmpty, "A group left with one pane dissolves")
    }

    @Test func closingOrMovingAMemberAwayDissolvesATwoPaneSplit() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        f.model.closeTab(id: f.id("y"))
        #expect(f.model.splitGroup(containingTabID: f.id("x")) == nil)
        #expect(f.store.savedSnapshots.last?.splitGroups == [])

        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        #expect(f.model.commitSidebarDrop(payload: f.payload("z"), destination: .init(container: .temporary("t"))))
        #expect(f.model.splitGroup(containingTabID: f.id("x")) == nil)
        #expect(f.store.savedSnapshots.last?.splitGroups == [])
    }

    @Test func aPinnedAnchorPullsTheAddedTabIntoItsSection() throws {
        let f = SidebarDragFixture()
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.pinnedNames() == ["a", "y", "b"])
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("a"), f.id("y")])
    }

    @Test func favoritesCannotJoinASplit() {
        let f = SidebarDragFixture(apps: ["app"])
        f.model.selectTab(id: f.id("x"))
        #expect(!f.model.openInSplitView(tabID: f.id("app")))
        f.model.selectTab(id: f.id("app"))
        #expect(!f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.model.splitGroups.isEmpty)
    }

    @Test func restoredGroupsKeepPaneOrderOrientationAndSizes() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitOrientation(.vertical, groupID: group.id))
        #expect(f.model.setSplitFractions([3, 1], groupID: group.id))
        #expect(!f.model.setSplitFractions([1, -1], groupID: group.id))
        let saved = try #require(f.store.savedSnapshots.last?.splitGroups?.first)
        #expect(saved.orientation == .vertical)
        #expect(saved.fractions == [0.75, 0.25])
        let restored = f.model.restoredSplitGroups(from: .init(tabs: [], splitGroups: [saved]))
        #expect(restored.first?.tabSyncIDs == [f.syncID("x"), f.syncID("y")])
        #expect(restored.first?.fractions == [0.75, 0.25])
    }

    @Test func theEngineShowsEveryPaneOfTheSelectedSplitOnly() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        let split = BrowserTabVisibleLayout(tabIDs: [f.id("x"), f.id("z")], orientation: .horizontal, fractions: nil)
        #expect(f.driver.visibleTabLayouts.last == split)
        #expect(f.driver.selectedTabIDs.last == f.id("z"))
        let sent = f.driver.visibleTabLayouts.count
        f.model.selectTab(id: f.id("x"))
        #expect(f.driver.visibleTabLayouts.count == sent, "Switching panes keeps the same layout")
        f.model.selectTab(id: f.id("y"))
        #expect(f.driver.visibleTabLayouts.last == .some(nil))
        f.model.selectTab(id: f.id("z"))
        #expect(f.driver.visibleTabLayouts.last == split)
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitOrientation(.vertical, groupID: group.id))
        #expect(f.model.setSplitFractions([1, 3], groupID: group.id))
        #expect(f.driver.visibleTabLayouts.last == BrowserTabVisibleLayout(
            tabIDs: [f.id("x"), f.id("z")], orientation: .vertical, fractions: [0.25, 0.75]
        ))
        f.model.closeTab(id: f.id("x"))
        #expect(f.driver.visibleTabLayouts.last == .some(nil), "A dissolved split shows one tab")
    }

    @Test func focusInAnotherVisiblePaneSelectsIt() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        f.driver.simulateTabFocus(f.id("x"))
        #expect(f.model.selectedTabID == f.id("x"))
        #expect(f.model.selectedSplitGroup?.focusedTabSyncID == f.syncID("x"))
        f.driver.simulateTabFocus(f.id("y"))
        #expect(f.model.selectedTabID == f.id("x"), "A hidden tab cannot take focus")
        f.model.selectTab(id: f.id("y"))
        f.driver.simulateTabFocus(f.id("z"))
        #expect(f.model.selectedTabID == f.id("y"), "Panes of an unselected split are hidden")
    }

    @Test func aDividerDragCommitsSizesOnlyForTheVisibleSplit() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        f.driver.simulateSplitResize([f.id("x"), f.id("z")], fractions: [0.7, 0.3])
        #expect(f.model.selectedSplitGroup?.fractions == [0.7, 0.3])
        #expect(f.driver.visibleTabLayouts.last == BrowserTabVisibleLayout(
            tabIDs: [f.id("x"), f.id("z")], orientation: .horizontal, fractions: [0.7, 0.3]
        ))
        f.driver.simulateSplitResize([f.id("z"), f.id("x")], fractions: [0.5, 0.5])
        #expect(f.model.selectedSplitGroup?.fractions == [0.7, 0.3], "Stale pane order is ignored")
        f.model.selectTab(id: f.id("y"))
        f.driver.simulateSplitResize([f.id("x"), f.id("z")], fractions: [0.5, 0.5])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.selectedSplitGroup?.fractions == [0.7, 0.3], "A hidden split keeps its sizes")
    }

    @Test func addSplitViewOpensTheCommandBarResultAsTheNextPane() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        let existing = Set(f.model.tabs.map(\.id))
        f.model.presentSplitViewCommandBar()
        #expect(f.model.commandBarModel.isPresented)
        f.model.commandBarModel.query = "https://new.example"
        f.model.commandBarModel.submitSelection()
        let added = try #require(f.model.tabs.first { !existing.contains($0.id) })
        #expect(f.model.selectedTabID == added.id)
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), added.id])
        #expect(f.model.temporaryTabs.map(\.id).firstIndex(of: added.id)
            == f.model.temporaryTabs.map(\.id).firstIndex(of: f.id("x")).map { $0 + 1 })
        #expect(!f.model.commandBarModel.isPresented)
        #expect(f.model.pendingSplitAnchorTabID == nil)
        #expect(f.store.savedSnapshots.last?.splitGroups?.first?.tabIDs == [f.syncID("x"), added.syncID])
    }

    @Test func addSplitViewWithAnOpenTabSuggestionJoinsThatTab() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        f.model.presentSplitViewCommandBar()
        f.model.commandBarModel.query = "z.example"
        let suggestion = try #require(f.model.commandBarModel.suggestions.first {
            $0.kind == .openTab && $0.tabIDs == [f.id("z")]
        })
        f.model.commandBarModel.submitSuggestion(id: suggestion.id)
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), f.id("z")])
        #expect(f.model.selectedTabID == f.id("z"))
        #expect(f.names(f.model.temporaryTabs) == ["x", "z", "y"])
    }

    @Test func anOrdinaryNewTabAfterACancelledSplitStaysOutOfTheSplit() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        f.model.presentSplitViewCommandBar()
        f.model.commandBarModel.dismiss()
        f.model.toggleCommandBar()
        #expect(f.model.pendingSplitAnchorTabID == nil)
        f.model.commandBarModel.query = "https://new.example"
        f.model.commandBarModel.submitSelection()
        #expect(f.model.selectedSplitGroup == nil)
        #expect(f.model.splitGroups.isEmpty)
    }

    @Test func addSplitViewIsUnavailableForFavoritesAndFullSplits() {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d"], apps: ["app"])
        f.model.selectTab(id: f.id("app"))
        #expect(!f.model.canAddSplitView)
        f.model.presentSplitViewCommandBar()
        #expect(f.model.pendingSplitAnchorTabID == nil)
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.canAddSplitView)
        for name in ["b", "c", "d"] {
            #expect(f.model.openInSplitView(tabID: f.id(name)))
        }
        #expect(!f.model.canAddSplitView, "A split holds at most four panes")
    }

    @Test func closingTheFocusedPaneFocusesTheNextPaneThenThePreviousOne() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d"])
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("b")))
        #expect(f.model.openInSplitView(tabID: f.id("c")))
        let (a, c) = (f.id("a"), f.id("c"))
        f.model.selectTab(id: f.id("b"))
        #expect(f.model.closeFocusedSplitPane())
        #expect(f.model.selectedTabID == c)
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == [a, c])
        #expect(f.model.closeFocusedSplitPane())
        #expect(f.model.selectedTabID == a, "The last pane hands focus to the previous one")
        #expect(f.model.selectedSplitGroup == nil, "One pane left is not a split")
        #expect(f.names(f.model.temporaryTabs) == ["a", "d"])
        #expect(!f.model.closeFocusedSplitPane(), "Outside a split the command does nothing")
    }

    @Test func closingAPinnedPaneUnloadsItAndKeepsItsRow() {
        let f = SidebarDragFixture()
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let y = f.id("y")
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.closeFocusedSplitPane())
        #expect(f.model.selectedTabID == y)
        #expect(f.pinnedNames() == ["a", "y", "b"])
        #expect(f.model.splitGroups.isEmpty)
    }

    @Test func closeTabOnAPaneSelectsAnotherPaneOfTheSplit() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        #expect(f.names(f.model.temporaryTabs) == ["x", "z", "y"])
        let x = f.id("x")
        #expect(f.model.archiveSelectedTab())
        #expect(f.model.selectedTabID == x, "The row below the closed pane is outside the split")
    }

    @Test func selectedSplitCommandsSeparateAndConvert() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c"])
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("b")))
        #expect(f.model.openInSplitView(tabID: f.id("c")))
        #expect(f.model.splitOrientationToggleTitle == BrowserStrings.splitConvertToVerticalAction)
        #expect(f.model.toggleSelectedSplitOrientation())
        #expect(f.model.selectedSplitGroup?.orientation == .vertical)
        #expect(f.model.splitOrientationToggleTitle == BrowserStrings.splitConvertToHorizontalAction)
        #expect(f.model.separateSelectedTabFromSplit())
        #expect(f.model.selectedSplitGroup == nil)
        let group = try #require(f.model.splitGroup(containingTabID: f.id("a")))
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("a"), f.id("b")])
        f.model.selectTab(id: f.id("b"))
        #expect(f.model.separateSelectedSplitGroup())
        #expect(f.model.splitGroups.isEmpty)
        #expect(!f.model.toggleSelectedSplitOrientation())
    }

    @Test func splitCommandsAppearInTheCommandBarOnlyWhenTheyApply() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        func commands(_ query: String) -> [BrowserCommandID] {
            f.model.presentCommandBar()
            f.model.commandBarModel.query = query
            return f.model.commandBarModel.suggestions.compactMap(\.commandID)
        }
        #expect(commands("split view").contains(.addSplitView))
        #expect(!commands("close split pane").contains(.closeSplitPane))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(commands("close split pane").contains(.closeSplitPane))
        #expect(commands("vertical split").contains(.toggleSplitOrientation))
    }
}

// MARK: - BrowserSplitPaneLayoutTests

@Test func splitPaneFramesFillTheHostWithFixedGaps() {
    let gap = BrowserSplitPaneLayout.paneGap
    let bounds = CGRect(x: 0, y: 0, width: 1000 + gap, height: 600)
    let equal = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .horizontal, fractions: nil, flipped: false
    )
    #expect(equal == [CGRect(x: 0, y: 0, width: 500, height: 600), CGRect(x: 500 + gap, y: 0, width: 500, height: 600)])
    let weighted = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .horizontal, fractions: [3, 1], flipped: false
    )
    #expect(weighted.map(\.width) == [750, 250])
    #expect(weighted[1].maxX == bounds.maxX)
    let invalid = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .horizontal, fractions: [1, .nan], flipped: false
    )
    #expect(invalid == equal)
    let three = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 10, y: 20, width: 900 + gap * 2, height: 100), count: 3, orientation: .horizontal,
        fractions: nil, flipped: false
    )
    #expect(three.map(\.width).reduce(0, +) + gap * 2 == 900 + gap * 2)
    #expect(zip(three, three.dropFirst()).allSatisfy { $1.minX - $0.maxX == gap })
    #expect(BrowserSplitPaneLayout.frames(
        in: bounds, count: 1, orientation: .vertical, fractions: nil, flipped: false
    ) == [bounds])
}

@Test func verticalSplitPanesRunTopToBottomInBothCoordinateSystems() {
    let gap = BrowserSplitPaneLayout.paneGap
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600 + gap)
    let unflipped = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .vertical, fractions: nil, flipped: false
    )
    #expect(unflipped[0] == CGRect(x: 0, y: 300 + gap, width: 800, height: 300))
    #expect(unflipped[1] == CGRect(x: 0, y: 0, width: 800, height: 300))
    let flipped = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .vertical, fractions: nil, flipped: true
    )
    #expect(flipped[0] == CGRect(x: 0, y: 0, width: 800, height: 300))
    #expect(flipped[1] == CGRect(x: 0, y: 300 + gap, width: 800, height: 300))
}

@Test func dividerDragMovesOnlyItsNeighborsAndKeepsAMinimumPane() throws {
    let gap = BrowserSplitPaneLayout.paneGap
    let minimum = BrowserSplitPaneLayout.minimumPaneLength
    // Three panes of 300 pt with two gaps.
    let length: CGFloat = 900 + gap * 2
    let dragged = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 0, to: 360 + gap / 2, length: length, count: 3, fractions: nil
    ))
    #expect(abs(dragged[0] - 360 / 900) < 1e-9)
    #expect(abs(dragged[1] - 240 / 900) < 1e-9)
    #expect(abs(dragged[2] - 1 / 3) < 1e-9, "The far pane keeps its size")
    let clamped = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 1, to: 0, length: length, count: 3, fractions: dragged
    ))
    #expect(abs(clamped[1] * 900 - minimum) < 1e-9, "A pane stops at the minimum length")
    #expect(abs(clamped.reduce(0, +) - 1) < 1e-9)
    #expect(BrowserSplitPaneLayout.fractions(movingDivider: 2, to: 10, length: length, count: 3, fractions: nil) == nil)
    let frames = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 0, y: 0, width: length, height: 500), count: 3, orientation: .horizontal,
        fractions: dragged, flipped: false
    )
    #expect(frames[0].width == 360)
    #expect(frames[1].minX == 360 + gap)
}

@Test func dividersCoverTheGapsInBothOrientations() {
    let gap = BrowserSplitPaneLayout.paneGap
    let outset = BrowserSplitPaneLayout.dividerHitOutset
    let horizontal = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 0, y: 0, width: 1000 + gap, height: 600), count: 2, orientation: .horizontal,
        fractions: nil, flipped: false
    )
    #expect(BrowserSplitPaneLayout.dividerFrames(between: horizontal, orientation: .horizontal) == [
        CGRect(x: 500 - outset, y: 0, width: gap + outset * 2, height: 600),
    ])
    let vertical = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 0, y: 0, width: 800, height: 600 + gap), count: 2, orientation: .vertical,
        fractions: nil, flipped: false
    )
    #expect(BrowserSplitPaneLayout.dividerFrames(between: vertical, orientation: .vertical) == [
        CGRect(x: 0, y: 300 - outset, width: 800, height: gap + outset * 2),
    ])
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 606)
    #expect(BrowserSplitPaneLayout.axisPosition(
        of: CGPoint(x: 10, y: 100), in: bounds, orientation: .vertical, flipped: false
    ) == 506)
    #expect(BrowserSplitPaneLayout.axisPosition(
        of: CGPoint(x: 10, y: 100), in: bounds, orientation: .vertical, flipped: true
    ) == 100)
}

@Test func dividerSnapsToEqualNeighborsAndDoubleClickEqualizesThem() throws {
    let gap = BrowserSplitPaneLayout.paneGap
    let snap = BrowserSplitPaneLayout.equalSnapDistance
    let length = 1000 + gap
    let near = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 0, to: 500 + snap - 1 + gap / 2, length: length, count: 2, fractions: [0.3, 0.7]
    ))
    #expect(near == [0.5, 0.5], "Within the snap distance the neighbors become equal")
    let far = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 0, to: 500 + snap + 10 + gap / 2, length: length, count: 2, fractions: nil
    ))
    #expect(abs(far[0] * 1000 - (500 + snap + 10)) < 1e-9)
    let three = try #require(BrowserSplitPaneLayout.equalizingNeighbors(
        ofDivider: 1, count: 3, fractions: [0.5, 0.1, 0.4]
    ))
    #expect(three == [0.5, 0.25, 0.25], "Only the divider's neighbors change")
    #expect(BrowserSplitPaneLayout.equalizingNeighbors(ofDivider: 2, count: 3, fractions: nil) == nil)
}

// MARK: - BrowserSplitViewPersistenceTests

@Test func splitGroupDecodingToleratesUnknownValuesAndOldSnapshots() throws {
    let group = try JSONDecoder().decode(
        BrowserTabSplitGroupSessionSnapshot.self,
        from: Data(#"{"id":"g","tabIDs":["a","b"],"orientation":"diagonal","fractions":[1,2,3],"focusedTabID":"z"}"#
            .utf8)
    )
    #expect(group.orientation == .horizontal)
    #expect(group.fractions == nil)
    #expect(group.focusedTabID == nil)
    let legacy = try JSONDecoder().decode(
        BrowserTabSessionSnapshot.self,
        from: Data(#"{"version":4,"tabs":[{"urlString":"https://a.example","placement":"temporary"}]}"#.utf8)
    )
    #expect(legacy.splitGroups == nil)
    let encoded = try JSONEncoder().encode(splitStoreSnapshot(ids: ["a", "b"], groups: [group]))
    #expect(try JSONDecoder().decode(BrowserTabSessionSnapshot.self, from: encoded).splitGroups == [group])
}

@Test func sqliteSplitGroupsSurviveRestartAndForeignWritersKeepThem() throws {
    let harness = try SplitStoreHarness()
    defer { harness.cleanup() }
    let group = BrowserTabSplitGroupSessionSnapshot(
        id: "g", tabIDs: ["a", "c"], orientation: .vertical, fractions: [0.4, 0.6], focusedTabID: "c"
    )
    do {
        let store = try harness.store()
        store.saveSnapshot(splitStoreSnapshot(ids: ["a", "b", "c"], groups: [group]))
        // A writer without split state, such as a remote projection, keeps groups.
        store.saveRemoteProjectionSnapshot(splitStoreSnapshot(ids: ["a", "b", "c"], groups: nil))
    }
    let reopened = try harness.store()
    #expect(reopened.loadSnapshot()?.splitGroups == [group])
    // A member deleted elsewhere leaves the group; one pane is not a split.
    reopened.saveRemoteProjectionSnapshot(splitStoreSnapshot(ids: ["a", "b"], groups: nil))
    #expect(try harness.store().loadSnapshot()?.splitGroups == nil)
}

@Test func sqliteSplitOnlyEditsQueueNoSyncMutations() throws {
    let harness = try SplitStoreHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let plain = splitStoreSnapshot(ids: ["a", "b"], groups: [])
    store.saveSnapshot(plain)
    try store.bindSyncOwner(harness.owner)
    let pending = try store.pendingSyncMutations(for: harness.owner)
    let split = splitStoreSnapshot(ids: ["a", "b"], groups: [.init(id: "g", tabIDs: ["a", "b"])])
    store.saveSnapshot(split)
    #expect(try store.pendingSyncMutations(for: harness.owner) == pending)
    #expect(store.loadSnapshot()?.splitGroups == split.splitGroups)
    store.saveSnapshot(plain)
    #expect(try store.pendingSyncMutations(for: harness.owner) == pending)
    #expect(store.loadSnapshot()?.splitGroups == nil)
}

@Test func sqliteMigrationAddsSplitGroupsToAnExistingProfile() throws {
    let harness = try SplitStoreHarness()
    defer { harness.cleanup() }
    let original = splitStoreSnapshot(ids: ["a", "b"], groups: nil)
    try harness.store().saveSnapshot(original)
    let database = try DatabaseQueue(path: harness.databaseURL.path)
    try database.write { db in
        try db.execute(sql: "DROP TABLE browser_tab_split_groups")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'addTabSplitGroups'")
    }
    let upgraded = try harness.store()
    #expect(upgraded.loadSnapshot() == original)
    let split = splitStoreSnapshot(ids: ["a", "b"], groups: [.init(id: "g", tabIDs: ["b", "a"])])
    upgraded.saveSnapshot(split)
    #expect(try harness.store().loadSnapshot() == split)
}

// MARK: - Helpers

private extension SidebarDragFixture {
    func syncID(_ name: String) -> String { model.tabs.first { $0.userTitleOverride == name }!.syncID }
}

// MARK: - SplitStoreHarness

private struct SplitStoreHarness {
    // MARK: Lifecycle

    init() throws {
        self.directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("split-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.owner = try BrowserSyncOwner(baseURL: #require(URL(string: "https://sync.example")), userID: "owner")
    }

    // MARK: Internal

    let directory: URL
    let owner: BrowserSyncOwner

    var databaseURL: URL { directory.appendingPathComponent("test.sqlite") }

    func store() throws -> BrowserSQLiteSessionStore { try BrowserSQLiteSessionStore(databaseURL: databaseURL) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func splitStoreSnapshot(
    ids: [String],
    groups: [BrowserTabSplitGroupSessionSnapshot]?
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: ids.map { BrowserTabSessionSnapshotTab(id: $0, urlString: "https://\($0).example", spaceID: "space") },
        splitGroups: groups
    )
}
