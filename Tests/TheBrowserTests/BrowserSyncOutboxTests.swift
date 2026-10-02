import Foundation
import GRDB
import Testing

@Test func syncOutboxFirstBindSeedsOnceAndKeepsImmutableIDsAcrossRestart() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let original = outboxSnapshot(ids: ["a", "b"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    let pending = try store.pendingSyncMutations(for: harness.owner)
    #expect(pending.count == 1)
    #expect(pending[0].changes.map(\.entityID) == ["space", "a", "b"])
    #expect(UUID(uuidString: pending[0].id) != nil)
    try store.saveSyncCursor(30, for: harness.owner)

    let reopened = try harness.store()
    try reopened.bindSyncOwner(harness.owner)
    #expect(try reopened.pendingSyncMutations(for: harness.owner) == pending)
    #expect(try reopened.syncCursor(for: harness.owner) == 30)
    #expect(try reopened.loadSnapshotForSync(for: harness.owner) == original)
}

@Test func syncOutboxOwnerUpgradeSeedsOnceAndReplaysHistoryFromZero() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let original = outboxSnapshot(ids: ["a"])
    do {
        let store = try harness.store()
        store.saveSnapshot(original)
        try store.bindSyncOwner(harness.owner)
        try store.saveSyncCursor(500, for: harness.owner)
    }
    // Recreate the exact pre-outbox owner state without changing the existing data.
    let database = try DatabaseQueue(path: harness.databaseURL.path)
    try database.write { db in
        try db.execute(sql: "DROP TABLE browser_sync_outbox")
        try db.execute(sql: "DROP TABLE browser_sync_baseline")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'addDurableSyncOutbox'")
    }
    let upgraded = try harness.store()
    #expect(try upgraded.syncCursor(for: harness.owner) == 0)
    #expect(try upgraded.pendingSyncMutations(for: harness.owner).flatMap(\.changes).map(\.entityID) == ["space", "a"])
    #expect(upgraded.loadSnapshot() == original)
    try upgraded.saveSyncCursor(12, for: harness.owner)
    let reopened = try harness.store()
    #expect(try reopened.syncCursor(for: harness.owner) == 12)
    #expect(try reopened.pendingSyncMutations(for: harness.owner) == upgraded.pendingSyncMutations(for: harness.owner))
}

@Test func syncOutboxChunksFirstBindAndOrdersParentsBeforeChildren() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(outboxSnapshot(ids: (0..<1001).map { "tab-\($0)" }))
    try store.bindSyncOwner(harness.owner)
    let mutations = try store.pendingSyncMutations(for: harness.owner)
    #expect(mutations.map(\.changes.count) == [1000, 2])
    #expect(mutations[0].changes.first?.entityType == .space)
    #expect(mutations.flatMap(\.changes).dropFirst().allSatisfy { $0.entityType == .tab })
    #expect(try store.pendingSyncMutations(for: harness.owner, limit: 1) == [mutations[0]])
    #expect(throws: BrowserSyncOutboxError.invalidLimit) { try store.pendingSyncMutations(for: harness.owner, limit: 0)
    }
}

@Test func syncOutboxNoOpAndRemoteProjectionDoNotEnqueueAndLocalDiffIsMinimal() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let original = outboxSnapshot(ids: ["a", "b"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    try outboxAcknowledgeAll(store, owner: harness.owner)
    store.saveSnapshot(original)
    store.saveRemoteProjectionSnapshot(original)
    #expect(try store.pendingSyncMutations(for: harness.owner).isEmpty)

    store.saveSnapshot(outboxSnapshot(ids: ["a", "b"], title: "Renamed"))
    let changes = try store.pendingSyncMutations(for: harness.owner).flatMap(\.changes)
    #expect(changes.map(\.entityID) == ["space"])
    #expect(changes[0].spaceData?.title == "Renamed")
}

@Test func syncOutboxPausedOfflineDeleteSurvivesRestartAndOldOwnUpsert() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(outboxSnapshot(ids: ["a", "b"]))
    try store.bindSyncOwner(harness.owner)
    let seed = try #require(store.pendingSyncMutations(for: harness.owner).first)
    let seedEvents = outboxEvents(seed.changes, startingAt: 1)
    _ = try store.acknowledgeSyncMutation(id: seed.id, events: seedEvents, for: harness.owner)
    try store.pauseSync()
    store.saveSnapshot(outboxSnapshot(ids: ["a"]))
    let pending = try store.pendingSyncMutations(for: harness.owner)
    #expect(pending.flatMap(\.changes).contains { $0.entityID == "b" && $0.op == .delete })

    let reopened = try harness.store()
    #expect(try reopened.isSyncPaused(for: harness.owner))
    #expect(try reopened.pendingSyncMutations(for: harness.owner) == pending)
    let merged = try reopened.applyRemoteSyncEvents(seedEvents, cursor: 3, for: harness.owner)
    #expect(merged.tabs.map(\.id) == ["a"])
    // Even a stale engine projection cannot recreate an explicitly deleted identity.
    reopened.saveSnapshot(outboxSnapshot(ids: ["a", "b"]))
    #expect(reopened.loadSnapshot()?.tabs.map(\.id) == ["a"])
}

@Test func syncOutboxAckOnlyRemovesMatchingMutationAndKeepsNewerLocalEdit() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(outboxSnapshot(ids: ["a"], override: "First"))
    try store.bindSyncOwner(harness.owner)
    let first = try #require(store.pendingSyncMutations(for: harness.owner).first)
    store.saveSnapshot(outboxSnapshot(ids: ["a"], override: "Second"))
    let second = try #require(store.pendingSyncMutations(for: harness.owner).last)
    let result = try store.acknowledgeSyncMutation(
        id: first.id,
        events: outboxEvents(first.changes, startingAt: 1),
        for: harness.owner
    )
    #expect(result.tabs.first?.userTitleOverride == "Second")
    #expect(try store.pendingSyncMutations(for: harness.owner) == [second])
    #expect(try store.syncCursor(for: harness.owner) == 0)

    // A lost response can be applied again without consuming the later mutation.
    _ = try store.acknowledgeSyncMutation(
        id: first.id,
        events: outboxEvents(first.changes, startingAt: 1),
        for: harness.owner
    )
    #expect(try store.pendingSyncMutations(for: harness.owner) == [second])
    _ = try store.acknowledgeSyncMutation(
        id: second.id,
        events: outboxEvents(second.changes, startingAt: 3),
        for: harness.owner
    )
    #expect(try store.pendingSyncMutations(for: harness.owner).isEmpty)
    #expect(store.loadSnapshot()?.tabs.first?.userTitleOverride == "Second")
}

@Test func syncOutboxNewerRemoteBaselineWinsOverAnOlderReceiptIncludingDelete() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    let latest = BrowserSyncOutboxProjection.changes(from: nil, to: outboxSnapshot(ids: ["a"], override: "Latest"))
    _ = try store.applyRemoteSyncEvents(outboxEvents(latest, startingAt: 10), cursor: 11, for: harness.owner)
    let older = BrowserSyncOutboxProjection.changes(from: nil, to: outboxSnapshot(ids: ["a"], override: "Old"))
    _ = try store.acknowledgeSyncMutation(
        id: UUID().uuidString,
        events: outboxEvents(older, startingAt: 1),
        for: harness.owner
    )
    _ = try store.acknowledgeSyncMutation(
        id: UUID().uuidString,
        events: [outboxDelete(id: "a", sequence: 5)],
        for: harness.owner
    )
    #expect(store.loadSnapshot()?.tabs.first?.userTitleOverride == "Latest")
    #expect(try store.syncCursor(for: harness.owner) == 11)
}

@Test func syncOutboxRemoteTombstonePersistsAndDominatesPendingStaleUpsert() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(outboxSnapshot(ids: ["a"]))
    try store.bindSyncOwner(harness.owner)
    let seed = try #require(store.pendingSyncMutations(for: harness.owner).first)
    let projection = try store.applyRemoteSyncEvents(
        [outboxDelete(id: "a", sequence: 10)],
        cursor: 10,
        for: harness.owner
    )
    #expect(projection.tabs.isEmpty)
    let reopened = try harness.store()
    _ = try reopened.acknowledgeSyncMutation(
        id: seed.id,
        events: outboxEvents(seed.changes, startingAt: 1),
        for: harness.owner
    )
    #expect(reopened.loadSnapshot()?.tabs.isEmpty == true)
    // Undo uses a new identity, which remains eligible for upload.
    reopened.saveSnapshot(outboxSnapshot(ids: ["restored-new-id"]))
    #expect(try reopened.pendingSyncMutations(for: harness.owner)
        .flatMap(\.changes)
        .contains { $0.entityID == "restored-new-id" })
}

@Test func syncOutboxProjectionPreservesLocalFolderTreeAndSelectionByIdentity() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let folders = [
        BrowserPinnedTabFolderSessionSnapshot(id: "parent", spaceID: "space", title: "Parent"),
        BrowserPinnedTabFolderSessionSnapshot(id: "child", spaceID: "space", parentFolderID: "parent", title: "Child"),
        BrowserPinnedTabFolderSessionSnapshot(id: "empty", spaceID: "space", title: "Empty"),
    ]
    let local = BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(
            id: "space",
            title: "Work",
            systemImageName: "briefcase",
            selectedTabIndex: 1
        )],
        pinnedTabFolders: folders,
        tabs: [
            BrowserTabSessionSnapshotTab(
                id: "a",
                urlString: "https://a.example",
                placement: .spacePinned,
                spaceID: "space",
                pinnedFolderID: "child"
            ),
            BrowserTabSessionSnapshotTab(id: "b", urlString: "https://b.example", spaceID: "space"),
        ]
    )
    store.saveSnapshot(local)
    try store.bindSyncOwner(harness.owner)
    try outboxAcknowledgeAll(store, owner: harness.owner)
    let projection = try store.applyRemoteSyncEvents(
        [outboxDelete(id: "a", sequence: 10)],
        cursor: 10,
        for: harness.owner
    )
    #expect(projection.pinnedTabFolders == folders)
    #expect(projection.spaces?.first?.selectedTabIndex == 0)
    #expect(projection.tabs.map(\.id) == ["b"])
}

@Test func syncOutboxExplicitTitleClearSurvivesAckAndRestart() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(outboxSnapshot(ids: ["a"], override: "Named"))
    try store.bindSyncOwner(harness.owner)
    try outboxAcknowledgeAll(store, owner: harness.owner)
    store.saveSnapshot(outboxSnapshot(ids: ["a"]))
    let clear = try #require(store.pendingSyncMutations(for: harness.owner).first)
    #expect(clear.changes.count == 1)
    #expect(clear.changes[0].tabData?.userTitleOverride == nil)
    _ = try store.acknowledgeSyncMutation(
        id: clear.id,
        events: outboxEvents(clear.changes, startingAt: 10),
        for: harness.owner
    )
    #expect(try harness.store().loadSnapshot()?.tabs.first?.userTitleOverride == nil)
}

@Test func syncOutboxLocalSnapshotAndQueueRollbackTogetherOnWriteFailure() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let original = outboxSnapshot(ids: ["a"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    let pending = try store.pendingSyncMutations(for: harness.owner)
    let database = try DatabaseQueue(path: harness.databaseURL.path)
    try database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_outbox_insert BEFORE INSERT ON browser_sync_outbox
        BEGIN SELECT RAISE(ABORT, 'injected outbox failure'); END
        """)
    }
    store.saveSnapshot(outboxSnapshot(ids: ["a", "b"]))
    #expect(store.loadSnapshot() == original)
    #expect(try store.pendingSyncMutations(for: harness.owner) == pending)
}

@Test func syncOutboxAckAndPullRollbackBaselineQueueProjectionAndCursorOnFailure() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let original = outboxSnapshot(ids: ["a"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    let mutation = try #require(store.pendingSyncMutations(for: harness.owner).first)
    let database = try DatabaseQueue(path: harness.databaseURL.path)
    try database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_projection BEFORE INSERT ON browser_tabs
        BEGIN SELECT RAISE(ABORT, 'injected projection failure'); END
        """)
    }
    #expect(throws: DatabaseError.self) {
        try store.acknowledgeSyncMutation(
            id: mutation.id,
            events: outboxEvents(mutation.changes, startingAt: 1),
            for: harness.owner
        )
    }
    #expect(throws: DatabaseError.self) {
        try store.applyRemoteSyncEvents(outboxEvents(mutation.changes, startingAt: 1), cursor: 2, for: harness.owner)
    }
    #expect(store.loadSnapshot() == original)
    #expect(try store.pendingSyncMutations(for: harness.owner) == [mutation])
    #expect(try store.syncCursor(for: harness.owner) == 0)
    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_projection") }
    _ = try store.acknowledgeSyncMutation(
        id: mutation.id,
        events: outboxEvents(mutation.changes, startingAt: 1),
        for: harness.owner
    )
    #expect(try store.pendingSyncMutations(for: harness.owner).isEmpty)
}

@Test func syncOutboxRejectsForeignOwnerAndMalformedEventsWithoutAcknowledging() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(outboxSnapshot(ids: ["a"]))
    try store.bindSyncOwner(harness.owner)
    let mutation = try #require(store.pendingSyncMutations(for: harness.owner).first)
    let foreign = BrowserSyncOwner(baseURL: harness.owner.baseURL, userID: "foreign")
    #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.loadSnapshotForSync(for: foreign) }
    #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.pendingSyncMutations(for: foreign) }
    #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.acknowledgeSyncMutation(
        id: mutation.id,
        events: [],
        for: foreign
    ) }
    #expect(throws: BrowserSyncStoreError.ownerMismatch) {
        try store.applyRemoteSyncEvents([], cursor: 99, for: foreign)
    }
    let malformed = BrowserSyncEvent(
        serverSeq: 10,
        deviceID: nil,
        entityType: "tab",
        entityID: "a",
        op: "upsert",
        data: .unknown,
        createdAt: ""
    )
    #expect(throws: BrowserSyncOutboxError.invalidEvent) {
        try store.acknowledgeSyncMutation(id: mutation.id, events: [malformed], for: harness.owner)
    }
    #expect(try store.pendingSyncMutations(for: harness.owner) == [mutation])
    #expect(try store.syncCursor(for: harness.owner) == 0)
}

// MARK: - SyncOutboxHarness

@Test func syncOutboxNonOrderEditsPreserveSparseRemoteRanks() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    let original = try store.applyRemoteSyncEvents(outboxSparseEvents(), cursor: 4, for: harness.owner)
    let renamed = outboxRenaming(original, tabID: "a", title: "Renamed")
    store.saveSnapshot(renamed)
    let mutation = try #require(store.pendingSyncMutations(for: harness.owner).first)
    #expect(mutation.changes.map(\.entityID) == ["a"])
    #expect(mutation.changes.first?.tabData?.rank == 200)
    let projection = try store.acknowledgeSyncMutation(
        id: mutation.id,
        events: outboxEvents(mutation.changes, startingAt: 10),
        for: harness.owner
    )
    #expect(projection.tabs.map(\.id) == ["z", "a", "m"])
    #expect(projection.tabs[1].userTitleOverride == "Renamed")

    let renamedSpace = BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Renamed space", systemImageName: "briefcase")],
        tabs: projection.tabs
    )
    store.saveSnapshot(renamedSpace)
    let spaceChange = try #require(store.pendingSyncMutations(for: harness.owner).first?.changes.first)
    #expect(spaceChange.entityID == "space")
    #expect(spaceChange.spaceData?.rank == 500)
}

@Test func syncOutboxDeleteThenRenamePreservesSurvivingNonzeroRanks() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    let original = try store.applyRemoteSyncEvents(outboxSparseEvents(), cursor: 4, for: harness.owner)
    let deleted = BrowserTabSessionSnapshot(spaces: original.spaces, tabs: Array(original.tabs.dropFirst()))
    store.saveSnapshot(deleted)
    store.saveSnapshot(outboxRenaming(deleted, tabID: "m", title: "Renamed after delete"))
    let pending = try store.pendingSyncMutations(for: harness.owner)
    #expect(pending.map(\.changes.count) == [1, 1])
    #expect(pending[0].changes[0].entityID == "z")
    #expect(pending[0].changes[0].op == .delete)
    #expect(pending[1].changes[0].entityID == "m")
    #expect(pending[1].changes[0].tabData?.rank == 300)
    _ = try store.acknowledgeSyncMutation(
        id: pending[0].id,
        events: outboxEvents(pending[0].changes, startingAt: 10),
        for: harness.owner
    )
    let projection = try store.acknowledgeSyncMutation(
        id: pending[1].id,
        events: outboxEvents(pending[1].changes, startingAt: 11),
        for: harness.owner
    )
    #expect(projection.tabs.map(\.id) == ["a", "m"])
}

@Test func syncOutboxActualReorderNormalizesAllSparseRankPeersTogether() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    let original = try store.applyRemoteSyncEvents(outboxSparseEvents(), cursor: 4, for: harness.owner)
    let reordered = BrowserTabSessionSnapshot(
        spaces: original.spaces,
        tabs: [original.tabs[1], original.tabs[0], original.tabs[2]]
    )
    store.saveSnapshot(reordered)
    let mutation = try #require(store.pendingSyncMutations(for: harness.owner).first)
    #expect(mutation.changes.map(\.entityID) == ["a", "z", "m"])
    #expect(mutation.changes.compactMap { $0.tabData?.rank } == [0, 1, 2])
    store.saveSnapshot(reordered)
    #expect(try store.pendingSyncMutations(for: harness.owner) == [mutation])
    let projection = try store.acknowledgeSyncMutation(
        id: mutation.id,
        events: outboxEvents(mutation.changes, startingAt: 10),
        for: harness.owner
    )
    #expect(projection.tabs.map(\.id) == ["a", "z", "m"])
}

@Test func syncOutboxInsertionNormalizesSparseRankPeersBeforeNewOrderIsAcknowledged() throws {
    let harness = try SyncOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    let original = try store.applyRemoteSyncEvents(outboxSparseEvents(), cursor: 4, for: harness.owner)
    let inserted = BrowserTabSessionSnapshot(
        spaces: original.spaces,
        tabs: [
            original.tabs[0],
            BrowserTabSessionSnapshotTab(id: "new", urlString: "https://new.example", spaceID: "space"),
        ] + Array(original.tabs.dropFirst())
    )
    store.saveSnapshot(inserted)
    let mutation = try #require(store.pendingSyncMutations(for: harness.owner).first)
    #expect(mutation.changes.map(\.entityID) == ["z", "new", "a", "m"])
    #expect(mutation.changes.compactMap { $0.tabData?.rank } == [0, 1, 2, 3])
    let projection = try store.acknowledgeSyncMutation(
        id: mutation.id,
        events: outboxEvents(mutation.changes, startingAt: 10),
        for: harness.owner
    )
    #expect(projection.tabs.map(\.id) == ["z", "new", "a", "m"])
}

private func outboxSparseEvents() -> [BrowserSyncEvent] {
    let space = BrowserSyncChange(
        entityType: .space, entityID: "space", op: .upsert,
        spaceData: BrowserSyncSpacePayload(
            title: "Work",
            systemImageName: "briefcase",
            rank: 500,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil
        ), tabData: nil
    )
    let tabs = ["z", "a", "m"].enumerated().map { index, id in
        BrowserSyncChange(
            entityType: .tab, entityID: id, op: .upsert, spaceData: nil,
            tabData: BrowserSyncTabPayload(
                spaceID: "space",
                placement: .temporary,
                rank: Double((index + 1) * 100),
                urlString: "https://\(id).example",
                pinnedURLString: nil,
                title: nil,
                userTitleOverride: nil,
                faviconURLString: nil,
                lastActivityAt: nil
            )
        )
    }
    return outboxEvents([space] + tabs, startingAt: 1)
}

private func outboxRenaming(
    _ snapshot: BrowserTabSessionSnapshot,
    tabID: String,
    title: String
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders,
        tabs: snapshot.tabs.map { tab in
            BrowserTabSessionSnapshotTab(
                id: tab.id,
                urlString: tab.urlString,
                pinnedURLString: tab.pinnedURLString,
                userTitleOverride: tab.id == tabID
                    ? title
                    : tab.userTitleOverride,
                placement: tab.placement,
                spaceID: tab.spaceID,
                pinnedFolderID: tab.pinnedFolderID,
                lastActivityTimestamp: tab.lastActivityTimestamp
            )
        }
    )
}

// MARK: - SyncOutboxHarness

private struct SyncOutboxHarness {
    // MARK: Lifecycle

    init() throws {
        self.directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("sync-outbox-\(UUID().uuidString)")
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

private func outboxSnapshot(
    ids: [String],
    title: String = "Work",
    override: String? = nil
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: title, systemImageName: "briefcase")],
        tabs: ids.map { BrowserTabSessionSnapshotTab(
            id: $0,
            urlString: "https://\($0).example",
            userTitleOverride: override,
            spaceID: "space"
        ) }
    )
}

private func outboxAcknowledgeAll(_ store: BrowserSQLiteSessionStore, owner: BrowserSyncOwner) throws {
    var sequence = 1
    for mutation in try store.pendingSyncMutations(for: owner) {
        _ = try store.acknowledgeSyncMutation(
            id: mutation.id,
            events: outboxEvents(mutation.changes, startingAt: sequence),
            for: owner
        )
        sequence += mutation.changes.count
    }
}

private func outboxDelete(id: String, sequence: Int) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence,
        deviceID: "remote",
        entityType: "tab",
        entityID: id,
        op: "delete",
        data: .deleted(id: id),
        createdAt: "2026-10-03T00:00:00Z"
    )
}

private func outboxEvents(_ changes: [BrowserSyncChange], startingAt sequence: Int) -> [BrowserSyncEvent] {
    changes.enumerated().map { index, change in
        let data: BrowserSyncEventData =
            if let space = change.spaceData {
                .space(BrowserSyncEventSpaceData(
                    id: change.entityID,
                    title: space.title,
                    systemImageName: space.systemImageName,
                    rank: space.rank,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                    selectedTabID: space.selectedTabID
                ))
            } else if let tab = change.tabData {
                .tab(BrowserSyncEventTabData(
                    id: change.entityID,
                    spaceID: tab.spaceID,
                    placement: tab.placement,
                    rank: tab.rank,
                    urlString: tab.urlString,
                    pinnedURLString: tab.pinnedURLString,
                    title: tab.title,
                    userTitleOverride: tab.userTitleOverride,
                    faviconURLString: tab.faviconURLString,
                    lastActivityAt: tab.lastActivityAt
                ))
            } else {
                .deleted(id: change.entityID)
            }
        return BrowserSyncEvent(
            serverSeq: sequence + index,
            deviceID: "local",
            entityType: change.entityType.rawValue,
            entityID: change.entityID,
            op: change.op.rawValue,
            data: data,
            createdAt: "2026-10-03T00:00:00Z"
        )
    }
}
