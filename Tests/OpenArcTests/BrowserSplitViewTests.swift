// BrowserSplitViewTests.swift

import AppKit
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

    @Test func aFavoriteKeepsItsTileAndACopyJoinsTheSplit() throws {
        let f = SidebarDragFixture(apps: ["app"])
        let app = f.id("app")
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: app))
        let panes = f.model.splitPaneTabIDs(forTabID: f.id("x"))
        #expect(panes.count == 2)
        #expect(!panes.contains(app))
        let copy = try #require(f.model.tabs.first { panes.contains($0.id) && $0.id != f.id("x") })
        let favorite = try #require(f.model.tabs.first { $0.id == app })
        #expect(copy.urlString == favorite.urlString)
        #expect(copy.placement != .app)
        #expect(favorite.placement == .app)
        f.model.selectTab(id: app)
        #expect(f.model.splitPaneTabIDs(forTabID: app) == [app], "Its tile shows it alone")

        #expect(f.model.openInSplitView(tabID: f.id("y")), "From a selected Favorite too")
        #expect(f.model.splitGroups.count == 2)
        #expect(f.model.splitGroup(containingTabID: app) == nil)
        #expect(f.model.splitGroup(containingTabID: f.id("y")) != nil)
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
            tabIDs: [f.id("x"), f.id("z")], orientation: .vertical, fractions: [0.25, 0.75],
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
            tabIDs: [f.id("x"), f.id("z")], orientation: .horizontal, fractions: [0.7, 0.3],
        ))
        f.driver.simulateSplitResize([f.id("z"), f.id("x")], fractions: [0.5, 0.5])
        #expect(f.model.selectedSplitGroup?.fractions == [0.7, 0.3], "Stale pane order is ignored")
        f.model.selectTab(id: f.id("y"))
        f.driver.simulateSplitResize([f.id("x"), f.id("z")], fractions: [0.5, 0.5])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.selectedSplitGroup?.fractions == [0.7, 0.3], "A hidden split keeps its sizes")
    }

    @Test func splitPaneCommandsFocusPanesByPositionAndWrap() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        #expect(f.model.selectedTabID == f.id("z"))
        #expect(f.model.focusSplitPane(at: 0))
        #expect(f.model.selectedTabID == f.id("x"))
        #expect(!f.model.focusSplitPane(at: 3), "There is no fourth pane")
        #expect(f.model.focusAdjacentSplitPane(offset: -1))
        #expect(f.model.selectedTabID == f.id("z"), "Previous wraps to the last pane")
        #expect(f.model.focusAdjacentSplitPane(offset: 1))
        #expect(f.model.selectedTabID == f.id("x"), "Next wraps to the first pane")
        func commands(_ query: String) -> [BrowserCommandID] {
            f.model.presentCommandBar()
            f.model.commandBarModel.query = query
            defer { f.model.dismissCommandBar() }
            return f.model.commandBarModel.suggestions.compactMap(\.commandID)
        }
        #expect(commands("split pane 3").contains(.focusSplitPane3))
        #expect(!commands("split pane 4").contains(.focusSplitPane4), "Only existing panes are offered")
        _ = f.model.separateSelectedSplitGroup()
        #expect(!commands("next split pane").contains(.focusNextSplitPane))
        #expect(!f.model.focusAdjacentSplitPane(offset: 1))
    }

    @Test func paneBarsSitOnEachPaneAndActOnTheirOwnPane() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        f.driver.emitNavigationStateChange(id: f.id("x"), canGoBack: true, canGoForward: false)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = BrowserContentNSView(hostView: NSView())
        content.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = content
        content.bindTabCreation(to: f.model)
        content.update(
            hostView: content.viewport.hostedView,
            isContextReady: true,
            hasSelectedTab: true,
            isSidebarVisible: true,
            usesWindowContentInsets: true,
        )
        content.layoutSubtreeIfNeeded()
        let host = content.viewport.hostedView
        let left = CGRect(x: 0, y: 0, width: 496, height: 600)
        let right = CGRect(x: 504, y: 0, width: 496, height: 600)
        f.driver.simulateSplitPaneLayout([f.id("x"), f.id("z")], frames: [left, right])
        f.driver.simulateSplitPaneLayout([f.id("x"), f.id("z")], frames: [left, right])
        let bars = content.splitPaneBars
        #expect(bars.paneTabIDs == [f.id("x"), f.id("z")])
        let focused = try #require(bars.bar(forTabID: f.id("z")))
        let other = try #require(bars.bar(forTabID: f.id("x")))
        let leftPane = bars.convert(left, from: host)
        #expect(other.frame == CGRect(
            x: leftPane.minX,
            y: leftPane.minY,
            width: leftPane.width,
            height: BrowserSplitPaneLayout.paneBarHeight,
        ), "The bar covers the top of its pane")
        #expect(focused.isFocused && !other.isFocused)
        #expect(!focused.reloadButton.isHidden && other.reloadButton.isHidden, "Only the focused pane reloads")
        #expect(other.backButton.isEnabled)
        content.appearance = NSAppearance(named: .darkAqua)
        bars.layoutSubtreeIfNeeded()
        let bitmap = try #require(bars.bitmapImageRepForCachingDisplay(in: CGRect(x: 0, y: 0, width: 1000, height: 60)))
        bars.cacheDisplay(in: CGRect(x: 0, y: 0, width: 1000, height: 60), to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/openarc-split-pane-bars.png"))

        func showSidebar(_ visible: Bool) {
            content.update(
                hostView: content.viewport.hostedView,
                isContextReady: true,
                hasSelectedTab: true,
                isSidebarVisible: visible,
                usesWindowContentInsets: true,
            )
            bars.layoutSubtreeIfNeeded()
        }
        showSidebar(false)
        #expect(other.showsWindowControls && !focused.showsWindowControls, "The top-leading pane holds the controls")
        #expect(other.backButton.frame.minX >= other.windowControls.frame.maxX, "Navigation moves past the controls")
        #expect(!other.windowControls.managesSystemButtons)
        showSidebar(true)
        #expect(!other.showsWindowControls, "With the sidebar shown its header holds them")

        other.backButton.performClick(nil)
        #expect(f.model.selectedTabID == f.id("x"), "The bar focuses its pane first")
        #expect(f.driver.goBackCount == 1)

        let close = try #require(bars.bar(forTabID: f.id("z")))
        close.closeButton.performClick(nil)
        #expect(f.model.selectedSplitGroup == nil, "Closing a pane of two dissolves the split")
        f.driver.simulateSplitPaneLayout([], frames: [])
        #expect(bars.paneTabIDs.isEmpty)
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

    @Test func addLeftAndRightSplitPlaceTheNewPaneNextToTheFocusedPane() throws {
        let f = SidebarDragFixture(temporary: ["w", "x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        f.model.presentSplitViewCommandBar(insertion: .before)
        f.model.commandBarModel.query = "y.example"
        let suggestion = try #require(f.model.commandBarModel.suggestions.first {
            $0.kind == .openTab && $0.tabIDs == [f.id("y")]
        })
        f.model.commandBarModel.submitSuggestion(id: suggestion.id)
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), f.id("y"), f.id("z")], "Add Left Split")
        #expect(f.model.selectedTabID == f.id("y"))
        #expect(f.model.openInSplitView(tabID: f.id("w"), insertion: .after))
        let after = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: after) == [f.id("x"), f.id("y"), f.id("w"), f.id("z")], "Add Right Split")
        #expect(f.model.pendingSplitInsertion == .end, "The insertion is consumed with the anchor")
    }

    @Test func movingTheFocusedPaneSwapsItsPlaceAndSize() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitFractions([0.7, 0.3], groupID: group.id))
        #expect(!f.model.canMoveSelectedSplitPane(by: 1))
        #expect(f.model.moveSelectedSplitPane(by: -1))
        let moved = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: moved) == [f.id("y"), f.id("x")])
        #expect(moved.fractions == [0.3, 0.7], "The pane keeps its size")
        #expect(f.model.selectedTabID == f.id("y"))
        #expect(!f.model.moveSelectedSplitPane(by: -1))
    }

    @Test func draggingThePaneGripMovesThePaneWhereItIsDropped() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitFractions([0.5, 0.3, 0.2], groupID: group.id))
        f.model.selectTab(id: f.id("x"))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = BrowserContentNSView(hostView: NSView())
        content.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = content
        content.bindTabCreation(to: f.model)
        content.update(
            hostView: content.viewport.hostedView,
            isContextReady: true,
            hasSelectedTab: true,
            isSidebarVisible: true,
            usesWindowContentInsets: true,
        )
        content.layoutSubtreeIfNeeded()
        let host = content.viewport.hostedView
        let ids = [f.id("x"), f.id("y"), f.id("z")]
        f.driver.simulateSplitPaneLayout(ids, frames: [
            CGRect(x: 0, y: 0, width: 496, height: 600),
            CGRect(x: 504, y: 0, width: 296, height: 600),
            CGRect(x: 808, y: 0, width: 192, height: 600),
        ])
        let bars = content.splitPaneBars
        #expect(bars.bar(forTabID: f.id("x"))?.grip.isHidden == false)
        #expect(bars.bar(forTabID: f.id("y"))?.grip.isHidden == true, "Only the focused pane has a grip")
        let overLast = bars.convert(CGPoint(x: 900, y: 300), from: host)
        #expect(bars.paneDropTarget(for: f.id("x"), at: overLast) == f.id("z"))
        #expect(
            bars.paneDropTarget(for: f.id("x"), at: bars.convert(CGPoint(x: 100, y: 300), from: host)) == nil,
            "Over its own pane nothing moves",
        )
        bars.finishPaneDrag(for: f.id("x"), at: overLast)
        let moved = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: moved) == [f.id("y"), f.id("z"), f.id("x")])
        #expect(moved.fractions == [0.3, 0.2, 0.5], "The pane keeps its size")
        #expect(f.model.selectedTabID == f.id("x"))
    }

    @Test func aSidebarTabDroppedOnThePageEdgeSplitsThePageThere() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        let drag = BrowserSidebarDragState(model: f.model)
        var clears = 0
        drag.pageSplitDropResolver = { point, _ in
            guard point != nil else {
                clears += 1
                return nil
            }
            return .init(anchorTabID: f.id("x"), insertion: .before, orientation: .vertical)
        }
        drag.begin(
            payload: .init(primary: .tab(f.id("x")), tabIDs: [f.id("x"), f.id("y")]),
            sourceFrame: .zero,
            start: .zero,
            pointer: .zero,
        )
        drag.updatePageDrop(atWindowPoint: CGPoint(x: 500, y: 20))
        #expect(drag.pageSplitTarget == nil, "A group of tabs cannot split the page")
        drag.complete()
        drag.begin(
            payload: .init(primary: .tab(f.id("y")), tabIDs: [f.id("y")]),
            sourceFrame: .zero,
            start: .zero,
            pointer: .zero,
        )
        drag.updatePageDrop(atWindowPoint: CGPoint(x: 500, y: 20))
        #expect(drag.pageSplitTarget?.orientation == .vertical)
        #expect(drag.release(at: .zero))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("y"), f.id("x")], "The top edge puts the tab first")
        #expect(group.orientation == .vertical)
        #expect(drag.pageSplitTarget == nil && clears > 0, "Releasing clears the preview")
    }

    @Test func pageDropZonesFollowThePanesAndTheSplitAxis() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = BrowserContentNSView(hostView: NSView())
        content.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = content
        content.bindTabCreation(to: f.model)
        content.update(
            hostView: content.viewport.hostedView,
            isContextReady: true,
            hasSelectedTab: true,
            isSidebarVisible: true,
            usesWindowContentInsets: true,
        )
        content.layoutSubtreeIfNeeded()
        let bars = content.splitPaneBars
        let host = content.viewport.hostedView
        func drop(_ x: CGFloat, _ y: CGFloat) -> BrowserSidebarDragState.PageSplitDropTarget? {
            let point = host.convert(CGPoint(x: x, y: y), to: nil)
            return bars.pageSplitDrop(atWindowPoint: point, draggedTabID: f.id("y"))
        }
        let page = bars.convert(host.bounds, from: host)
        let leading = try #require(drop(page.minX + 20, page.midY))
        #expect(leading.anchorTabID == f.id("x") && leading.insertion == .before && leading.orientation == .horizontal)
        #expect(bars.pageDropPreview?.width == page.width / 2)
        #expect(drop(host.bounds.midX, host.bounds.midY) == nil, "The middle of the page is not a drop zone")
        #expect(bars.pageDropPreview == nil)

        #expect(f.model.openInSplitView(tabID: f.id("z")))
        f.driver.simulateSplitPaneLayout([f.id("x"), f.id("z")], frames: [
            CGRect(x: 0, y: 0, width: 496, height: 600),
            CGRect(x: 504, y: 0, width: 496, height: 600),
        ])
        let trailing = try #require(drop(990, 300))
        #expect(trailing.anchorTabID == f.id("z") && trailing.insertion == .after)
        #expect(drop(750, host.isFlipped ? 590 : 10) == nil, "A side-by-side split does not grow downward")
        let middle = try #require(drop(250, 300))
        #expect(middle == .init(anchorTabID: f.id("x"), replacesAnchor: true), "The middle of a pane replaces it")
        #expect(bars.pageDropPreview?.size == CGSize(width: 496, height: 600), "The whole pane is outlined")
        _ = bars.pageSplitDrop(atWindowPoint: nil, draggedTabID: f.id("y"))
        #expect(bars.pageDropPreview == nil)
    }

    @Test func aTabDroppedInAPanesMiddleTakesItsPlaceAndSize() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z", "w"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.model.openInSplitView(tabID: f.id("z")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitFractions([0.5, 0.3, 0.2], groupID: group.id))
        #expect(!f.model.canReplaceSplitPane(anchorTabID: f.id("w"), with: f.id("x")), "Only a shown split's pane")

        #expect(f.model.replaceSplitPane(anchorTabID: f.id("y"), with: f.id("w")))
        let replaced = try #require(f.model.selectedSplitGroup)
        #expect(f.model.splitPaneTabIDs(of: replaced) == [f.id("x"), f.id("w"), f.id("z")])
        #expect(replaced.fractions == [0.5, 0.3, 0.2], "The new pane keeps the old pane's size")
        #expect(f.model.selectedTabID == f.id("w"))
        #expect(f.model.splitGroup(containingTabID: f.id("y")) == nil)
        let order = f.model.temporaryTabs.map(\.id)
        #expect(
            try #require(order.firstIndex(of: f.id("y"))) > #require(order.firstIndex(of: f.id("z"))),
            "The replaced row follows the split",
        )

        #expect(f.model.replaceSplitPane(anchorTabID: f.id("x"), with: f.id("z")), "A member moves to the pane")
        #expect(try f.model.splitPaneTabIDs(of: #require(f.model.selectedSplitGroup)) == [
            f.id("z"),
            f.id("x"),
            f.id("w"),
        ])
    }

    @Test func anUnloadedPinnedTabReplacingAPaneIsFocusedUnderItsNewID() throws {
        // The first pinned tab restores selected; the second restores unloaded.
        let f = SidebarDragFixture(pinned: [("a", nil), ("b", nil)], temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let unloadedID = f.id("b")
        #expect(!f.driver.createdTabRequests.contains { $0.id == unloadedID })
        #expect(f.model.replaceSplitPane(anchorTabID: f.id("y"), with: unloadedID))
        #expect(f.id("b") != unloadedID, "Moving among temporary tabs loads it with a new ID")
        let group = try #require(f.model.selectedSplitGroup, "The split stays shown")
        #expect(f.model.splitPaneTabIDs(of: group) == [f.id("x"), f.id("b")])
        #expect(f.model.selectedTabID == f.id("b"))
    }

    @Test func expandCurrentSplitShowsTheFocusedPaneUntilFocusMoves() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let split = BrowserTabVisibleLayout(tabIDs: [f.id("x"), f.id("y")], orientation: .horizontal, fractions: nil)
        #expect(f.driver.visibleTabLayouts.last == split)
        #expect(f.model.toggleExpandedSplitPane())
        #expect(f.model.isSelectedSplitPaneExpanded)
        #expect(f.driver.visibleTabLayouts.last == .some(nil), "Only the focused pane is shown")
        #expect(f.model.selectedSplitGroup != nil, "The split itself stays")
        #expect(f.model.toggleExpandedSplitPane())
        #expect(f.driver.visibleTabLayouts.last == split)
        #expect(f.model.toggleExpandedSplitPane())
        f.model.selectTab(id: f.id("x"))
        #expect(!f.model.isSelectedSplitPaneExpanded, "Moving focus ends the expansion")
        #expect(f.driver.visibleTabLayouts.last == split)
        f.model.selectTab(id: f.id("z"))
        #expect(!f.model.toggleExpandedSplitPane(), "Expansion needs a split")
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

    @Test func addSplitViewIsUnavailableForFullSplitsOnly() {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d"], apps: ["app"])
        f.model.selectTab(id: f.id("app"))
        #expect(f.model.canAddSplitView)
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
        let a = f.id("a")
        let c = f.id("c")
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
        in: bounds, count: 2, orientation: .horizontal, fractions: nil, flipped: false,
    )
    #expect(equal == [CGRect(x: 0, y: 0, width: 500, height: 600), CGRect(x: 500 + gap, y: 0, width: 500, height: 600)])
    let weighted = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .horizontal, fractions: [3, 1], flipped: false,
    )
    #expect(weighted.map(\.width) == [750, 250])
    #expect(weighted[1].maxX == bounds.maxX)
    let invalid = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .horizontal, fractions: [1, .nan], flipped: false,
    )
    #expect(invalid == equal)
    let three = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 10, y: 20, width: 900 + gap * 2, height: 100), count: 3, orientation: .horizontal,
        fractions: nil, flipped: false,
    )
    #expect(three.map(\.width).reduce(0, +) + gap * 2 == 900 + gap * 2)
    #expect(zip(three, three.dropFirst()).allSatisfy { $1.minX - $0.maxX == gap })
    #expect(BrowserSplitPaneLayout.frames(
        in: bounds, count: 1, orientation: .vertical, fractions: nil, flipped: false,
    ) == [bounds])
}

@Test func verticalSplitPanesRunTopToBottomInBothCoordinateSystems() {
    let gap = BrowserSplitPaneLayout.paneGap
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600 + gap)
    let unflipped = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .vertical, fractions: nil, flipped: false,
    )
    #expect(unflipped[0] == CGRect(x: 0, y: 300 + gap, width: 800, height: 300))
    #expect(unflipped[1] == CGRect(x: 0, y: 0, width: 800, height: 300))
    let flipped = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .vertical, fractions: nil, flipped: true,
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
        movingDivider: 0, to: 360 + gap / 2, length: length, count: 3, fractions: nil,
    ))
    #expect(abs(dragged[0] - 360 / 900) < 1e-9)
    #expect(abs(dragged[1] - 240 / 900) < 1e-9)
    #expect(abs(dragged[2] - 1 / 3) < 1e-9, "The far pane keeps its size")
    let clamped = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 1, to: 0, length: length, count: 3, fractions: dragged,
    ))
    #expect(abs(clamped[1] * 900 - minimum) < 1e-9, "A pane stops at the minimum length")
    #expect(abs(clamped.reduce(0, +) - 1) < 1e-9)
    #expect(BrowserSplitPaneLayout.fractions(movingDivider: 2, to: 10, length: length, count: 3, fractions: nil) == nil)
    let frames = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 0, y: 0, width: length, height: 500), count: 3, orientation: .horizontal,
        fractions: dragged, flipped: false,
    )
    #expect(frames[0].width == 360)
    #expect(frames[1].minX == 360 + gap)
}

@Test func dividersCoverTheGapsInBothOrientations() {
    let gap = BrowserSplitPaneLayout.paneGap
    let outset = BrowserSplitPaneLayout.dividerHitOutset
    let horizontal = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 0, y: 0, width: 1000 + gap, height: 600), count: 2, orientation: .horizontal,
        fractions: nil, flipped: false,
    )
    #expect(BrowserSplitPaneLayout.dividerFrames(between: horizontal, orientation: .horizontal) == [
        CGRect(x: 500 - outset, y: 0, width: gap + outset * 2, height: 600),
    ])
    let vertical = BrowserSplitPaneLayout.frames(
        in: CGRect(x: 0, y: 0, width: 800, height: 600 + gap), count: 2, orientation: .vertical,
        fractions: nil, flipped: false,
    )
    #expect(BrowserSplitPaneLayout.dividerFrames(between: vertical, orientation: .vertical) == [
        CGRect(x: 0, y: 300 - outset, width: 800, height: gap + outset * 2),
    ])
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 606)
    #expect(BrowserSplitPaneLayout.axisPosition(
        of: CGPoint(x: 10, y: 100), in: bounds, orientation: .vertical, flipped: false,
    ) == 506)
    #expect(BrowserSplitPaneLayout.axisPosition(
        of: CGPoint(x: 10, y: 100), in: bounds, orientation: .vertical, flipped: true,
    ) == 100)
}

@Test func thePagePartOfAPaneSitsBelowItsBar() {
    let bar = BrowserSplitPaneLayout.paneBarHeight
    let pane = CGRect(x: 10, y: 20, width: 400, height: 300)
    #expect(BrowserSplitPaneLayout.webContentFrame(forPaneFrame: pane, flipped: true)
        == CGRect(x: 10, y: 20 + bar, width: 400, height: 300 - bar))
    #expect(BrowserSplitPaneLayout.webContentFrame(forPaneFrame: pane, flipped: false)
        == CGRect(x: 10, y: 20, width: 400, height: 300 - bar))
}

@Test func dividerSnapsToEqualNeighborsAndDoubleClickEqualizesThem() throws {
    let gap = BrowserSplitPaneLayout.paneGap
    let snap = BrowserSplitPaneLayout.equalSnapDistance
    let length = 1000 + gap
    let near = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 0, to: 500 + snap - 1 + gap / 2, length: length, count: 2, fractions: [0.3, 0.7],
    ))
    #expect(near == [0.5, 0.5], "Within the snap distance the neighbors become equal")
    let far = try #require(BrowserSplitPaneLayout.fractions(
        movingDivider: 0, to: 500 + snap + 10 + gap / 2, length: length, count: 2, fractions: nil,
    ))
    #expect(abs(far[0] * 1000 - (500 + snap + 10)) < 1e-9)
    let three = try #require(BrowserSplitPaneLayout.equalizingNeighbors(
        ofDivider: 1, count: 3, fractions: [0.5, 0.1, 0.4],
    ))
    #expect(three == [0.5, 0.25, 0.25], "Only the divider's neighbors change")
    #expect(BrowserSplitPaneLayout.equalizingNeighbors(ofDivider: 2, count: 3, fractions: nil) == nil)
}

// MARK: - BrowserSplitViewPersistenceTests

@Test func aDraggedPaneLandsOnThePaneWithTheNearestCenter() {
    let row = [
        CGRect(x: 0, y: 0, width: 400, height: 600),
        CGRect(x: 408, y: 0, width: 200, height: 600),
        CGRect(x: 616, y: 0, width: 384, height: 600),
    ]
    #expect(BrowserSplitPaneLayout.paneIndex(at: CGPoint(x: 404, y: 10), in: row, orientation: .horizontal) == 1)
    #expect(BrowserSplitPaneLayout.paneIndex(at: CGPoint(x: -50, y: 10), in: row, orientation: .horizontal) == 0)
    #expect(BrowserSplitPaneLayout.paneIndex(at: CGPoint(x: 2000, y: 10), in: row, orientation: .horizontal) == 2)
    let stack = [CGRect(x: 0, y: 0, width: 800, height: 300), CGRect(x: 0, y: 308, width: 800, height: 292)]
    #expect(BrowserSplitPaneLayout.paneIndex(at: CGPoint(x: 10, y: 500), in: stack, orientation: .vertical) == 1)
    #expect(BrowserSplitPaneLayout.paneIndex(at: CGPoint(x: 10, y: 500), in: [], orientation: .vertical) == nil)
}

@Test func pageDropEdgesUseTheirZoneSizes() {
    let page = CGRect(x: 0, y: 0, width: 900, height: 600)
    #expect(BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 79, y: 300), in: page) == .leading)
    #expect(BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 81, y: 300), in: page) == nil, "At most 80 pt wide")
    #expect(BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 850, y: 300), in: page) == .trailing)
    #expect(BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 450, y: 49), in: page) == .top)
    #expect(BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 450, y: 560), in: page) == .bottom)
    #expect(
        BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 10, y: 40), in: page) == .leading,
        "The relatively closer edge wins",
    )
    let narrow = CGRect(x: 0, y: 0, width: 150, height: 600)
    #expect(
        BrowserSplitPaneLayout.pageDropEdge(at: CGPoint(x: 55, y: 300), in: narrow) == nil,
        "A third of a narrow pane",
    )
    #expect(BrowserSplitPaneLayout.pageDropPreview(for: .bottom, in: page) == CGRect(
        x: 0,
        y: 300,
        width: 900,
        height: 300,
    ))
}

@Test func splitGroupDecodingToleratesUnknownValuesAndOldSnapshots() throws {
    let group = try JSONDecoder().decode(
        BrowserTabSplitGroupSessionSnapshot.self,
        from: Data(#"{"id":"g","tabIDs":["a","b"],"orientation":"diagonal","fractions":[1,2,3],"focusedTabID":"z"}"#
            .utf8),
    )
    #expect(group.orientation == .horizontal)
    #expect(group.fractions == nil)
    #expect(group.focusedTabID == nil)
    let legacy = try JSONDecoder().decode(
        BrowserTabSessionSnapshot.self,
        from: Data(#"{"version":4,"tabs":[{"urlString":"https://a.example","placement":"temporary"}]}"#.utf8),
    )
    #expect(legacy.splitGroups == nil)
    let encoded = try JSONEncoder().encode(splitStoreSnapshot(ids: ["a", "b"], groups: [group]))
    #expect(try JSONDecoder().decode(BrowserTabSessionSnapshot.self, from: encoded).splitGroups == [group])
}

@Test func sqliteSplitGroupsSurviveRestartAndForeignWritersKeepThem() throws {
    let harness = try SplitStoreHarness()
    defer { harness.cleanup() }
    let group = BrowserTabSplitGroupSessionSnapshot(
        id: "g", tabIDs: ["a", "c"], orientation: .vertical, fractions: [0.4, 0.6], focusedTabID: "c",
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
    // MARK: Internal

    let directory: URL
    let owner: BrowserSyncOwner

    var databaseURL: URL { directory.appendingPathComponent("test.sqlite") }

    init() throws {
        self.directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("split-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.owner = try BrowserSyncOwner(baseURL: #require(URL(string: "https://sync.example")), userID: "owner")
    }

    func store() throws -> BrowserSQLiteSessionStore { try BrowserSQLiteSessionStore(databaseURL: databaseURL) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func splitStoreSnapshot(
    ids: [String],
    groups: [BrowserTabSplitGroupSessionSnapshot]?,
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: ids.map { BrowserTabSessionSnapshotTab(id: $0, urlString: "https://\($0).example", spaceID: "space") },
        splitGroups: groups,
    )
}

@Test @MainActor func aFavoriteKeepsItsPinnedURLThroughNavigationAndClosing() throws {
    let f = SidebarDragFixture(apps: ["app"])
    let app = f.id("app")
    let home = try #require(f.model.tabs.first { $0.id == app }?.urlString)
    #expect(f.model.setPinnedURLString("https://home.example/", forTabID: app))
    #expect(f.model.tabs.first { $0.id == app }?.pinnedURLString == "https://home.example/")
    #expect(f.model.tabs.first { $0.id == app }?.urlString == home, "The page stays until it is closed")
    #expect(f.model.closeAppTabProcess(id: app, forceClose: true))
    #expect(f.model.tabs.first { $0.id == app }?.urlString == "https://home.example/")
}

@Test @MainActor func aNestedFolderGoesInsideAndOpensItsParent() throws {
    let f = SidebarDragFixture(
        pinned: [("one", "top")],
        folders: [.init(id: "top", spaceID: "s", title: "Top", isExpanded: false)],
    )
    let nested = try #require(f.model.createNestedFolder(inFolderID: "top"))
    let folder = try #require(f.model.pinnedTabFolders.first { $0.id == nested })
    #expect(folder.parentFolderID == "top")
    #expect(f.model.pinnedTabFolders.first { $0.id == "top" }?.isExpanded == true)
}

@Test @MainActor func aDuplicatedFolderCopiesItsPagesAndFolders() throws {
    let f = SidebarDragFixture(pinned: [("a", nil), ("one", "top"), ("two", "inner")], folders: [
        .init(id: "top", spaceID: "s", title: "Top"),
        .init(id: "inner", spaceID: "s", parentFolderID: "top", title: "Inner"),
    ])
    let tabCount = f.model.tabs.count
    let copyID = try #require(f.model.duplicateFolder(id: "top"))
    let copy = try #require(f.model.pinnedTabFolders.first { $0.id == copyID })
    #expect(copy.title == "Top" && copy.parentFolderID == nil)
    #expect(f.model.tabs.count == tabCount + 2)
    #expect(f.model.tabs.filter { $0.pinnedFolderID == copyID }.map(\.urlString) == ["https://one.example"])
    let inner = try #require(f.model.pinnedTabFolders.first { $0.parentFolderID == copyID })
    #expect(inner.title == "Inner" && inner.id != "inner")
    #expect(f.model.tabs.first { $0.pinnedFolderID == inner.id }?.urlString == "https://two.example")
    #expect(f.model.tabs.first { $0.syncID == "one" }?.pinnedFolderID == "top", "The original stays")
}

@Test @MainActor func aFolderTurnsIntoASpaceWithItsContents() throws {
    let f = SidebarDragFixture(pinned: [("a", nil), ("one", "top"), ("two", "inner")], folders: [
        .init(id: "top", spaceID: "s", title: "Top"),
        .init(id: "inner", spaceID: "s", parentFolderID: "top", title: "Inner"),
    ])
    let before = f.model.spaces.count
    #expect(f.model.turnFolderIntoSpace(id: "top"))
    #expect(f.model.spaces.count == before + 1)
    let space = try #require(f.model.spaces.last)
    #expect(space.title == "Top")
    #expect(f.model.selectedSpaceID == space.id)
    #expect(!f.model.pinnedTabFolders.contains { $0.id == "top" })
    let one = try #require(f.model.tabs.first { $0.syncID == "one" })
    #expect(one.spaceID == space.id && one.pinnedFolderID == nil && one.placement == .spacePinned)
    let inner = try #require(f.model.pinnedTabFolders.first { $0.id == "inner" })
    #expect(inner.spaceID == space.id && inner.parentFolderID == nil)
    #expect(f.model.tabs.first { $0.syncID == "two" }?.pinnedFolderID == "inner")
    #expect(f.model.tabs.first { $0.syncID == "a" }?.spaceID == "s", "The rest of the old Space stays")
}

@Test @MainActor func aFolderMovesToAnotherSpace() {
    let f = SidebarDragFixture(pinned: [("one", "top")], folders: [.init(id: "top", spaceID: "s", title: "Top")])
    let other = "t"
    #expect(f.model.spacesForMovingFolder(id: "top").map(\.id) == [other])
    f.model.moveFolder(id: "top", toSpaceID: other)
    #expect(f.model.pinnedTabFolders.first { $0.id == "top" }?.spaceID == other)
    #expect(f.model.tabs.first { $0.syncID == "one" }?.spaceID == other)
}

@Test @MainActor func emptyFoldersMoveAndTurnIntoASpaceToo() throws {
    let f = SidebarDragFixture(folders: [
        .init(id: "top", spaceID: "s", title: "Top"),
        .init(id: "inner", spaceID: "s", parentFolderID: "top", title: "Inner"),
    ])
    f.model.moveFolder(id: "top", toSpaceID: "t")
    #expect(f.model.pinnedTabFolders.first { $0.id == "top" }?.spaceID == "t")
    #expect(f.model.pinnedTabFolders.first { $0.id == "inner" }?.spaceID == "t")
    #expect(f.model.pinnedTabFolders.first { $0.id == "inner" }?.parentFolderID == "top")
    #expect(f.model.turnFolderIntoSpace(id: "top"))
    let space = try #require(f.model.spaces.last)
    #expect(space.title == "Top")
    let inner = try #require(f.model.pinnedTabFolders.first { $0.id == "inner" })
    #expect(inner.spaceID == space.id && inner.parentFolderID == nil, "A nested folder outlives its parent")
    #expect(!f.model.pinnedTabFolders.contains { $0.id == "top" })
}
