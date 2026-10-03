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
}

// MARK: - BrowserSplitPaneLayoutTests

@Test func splitPaneFramesFillTheHostWithFixedGaps() {
    let gap = BrowserSplitPaneLayout.paneGap
    let bounds = CGRect(x: 0, y: 0, width: 1006, height: 600)
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
        in: CGRect(x: 10, y: 20, width: 912, height: 100), count: 3, orientation: .horizontal,
        fractions: nil, flipped: false
    )
    #expect(three.map(\.width).reduce(0, +) + gap * 2 == 912)
    #expect(zip(three, three.dropFirst()).allSatisfy { $1.minX - $0.maxX == gap })
    #expect(BrowserSplitPaneLayout.frames(
        in: bounds, count: 1, orientation: .vertical, fractions: nil, flipped: false
    ) == [bounds])
}

@Test func verticalSplitPanesRunTopToBottomInBothCoordinateSystems() {
    let gap = BrowserSplitPaneLayout.paneGap
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 606)
    let unflipped = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .vertical, fractions: nil, flipped: false
    )
    #expect(unflipped[0] == CGRect(x: 0, y: 303 + gap / 2, width: 800, height: 300))
    #expect(unflipped[1] == CGRect(x: 0, y: 0, width: 800, height: 300))
    let flipped = BrowserSplitPaneLayout.frames(
        in: bounds, count: 2, orientation: .vertical, fractions: nil, flipped: true
    )
    #expect(flipped[0] == CGRect(x: 0, y: 0, width: 800, height: 300))
    #expect(flipped[1] == CGRect(x: 0, y: 300 + gap, width: 800, height: 300))
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
