import Foundation
import GRDB
import Testing

@Test func versionedOutboxMigrationPreservesLegacyBytesIDsPositionsAndFIFO() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let original = versionedSnapshot(ids: ["a", "b"])
    let store = try harness.store()
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    store.saveSnapshot(versionedSnapshot(ids: ["a", "b"], title: "Before upgrade"))
    try store.saveSyncCursor(51, for: harness.owner)
    let database = try harness.database()
    // Deliberately use bytes different from JSONEncoder's default output. The
    // migration must never decode/re-encode an existing immutable mutation.
    try database.write { db in
        for row in try Row.fetchAll(db, sql: "SELECT mutation_id, payload FROM browser_sync_outbox") {
            let json = try JSONSerialization.jsonObject(with: row["payload"] as Data)
            let payload = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try db.execute(
                sql: "UPDATE browser_sync_outbox SET payload = ? WHERE mutation_id = ?",
                arguments: [payload, row["mutation_id"] as String]
            )
        }
    }
    let before = try harness.rows()
    try database.write { db in
        try db.execute(sql: "ALTER TABLE browser_sync_outbox DROP COLUMN protocol_version")
        try db.execute(sql: "ALTER TABLE browser_sync_state DROP COLUMN new_mutation_version")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'addVersionedSyncOutbox'")
    }

    let upgraded = try harness.store()
    #expect(try harness.rows() == before)
    #expect(try upgraded.syncCursor(for: harness.owner) == 51)
    #expect(try upgraded.pendingSyncQueue(for: harness.owner).map(\.protocolVersion) == [2, 2])
    try upgraded.enableSemanticSyncMutations(for: harness.owner)
    try upgraded.enableSemanticSyncMutations(for: harness.owner)
    upgraded.saveSnapshot(versionedSnapshot(ids: ["a", "b"], title: "After upgrade"))
    let queue = try upgraded.pendingSyncQueue(for: harness.owner)
    #expect(queue.map(\.protocolVersion) == [2, 2, 3])
    #expect(try Array(harness.rows().prefix(2)) == before)
    #expect(try upgraded.pendingSyncQueue(for: harness.owner, limit: 1) == [queue[0]])
    #expect(throws: BrowserSyncQueueError.protocolVersionMismatch) {
        try upgraded.pendingSyncMutations(for: harness.owner)
    }

    let reopened = try harness.store()
    try reopened.bindSyncOwner(harness.owner)
    #expect(try reopened.pendingSyncQueue(for: harness.owner) == queue)
    reopened.saveSnapshot(versionedSnapshot(ids: ["a", "b"], title: "After restart"))
    #expect(try reopened.pendingSyncQueue(for: harness.owner).map(\.protocolVersion) == [2, 2, 3, 3])
    #expect(try Array(harness.rows().prefix(2)) == before)
}

@Test func versionedOutboxAckValidatesRowVersionBeforeApplyingEventsAndKeepsFIFOOverlay() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let original = versionedSnapshot(ids: ["a"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    let seed = try #require(store.pendingSyncMutations(for: harness.owner).first)
    try store.enableSemanticSyncMutations(for: harness.owner)
    store.saveSnapshot(versionedSnapshot(ids: ["a"], title: "Pending rename"))
    let semantic = try #require(store.pendingSyncQueue(for: harness.owner).last)
    let before = try harness.rows()
    let baseline = try harness.baseline()
    for (id, wrongVersion) in [(seed.id, 3), (semantic.id, 2)] {
        #expect(throws: BrowserSyncQueueError.protocolVersionMismatch) {
            try store.acknowledgeSyncMutation(
                id: id, protocolVersion: wrongVersion,
                events: [versionedDelete(id: "space", type: "space", sequence: 100)], for: harness.owner
            )
        }
    }
    #expect(try harness.rows() == before)
    #expect(try harness.baseline() == baseline)
    #expect(store.loadSnapshot()?.spaces?.first?.title == "Pending rename")
    let projected = try store.acknowledgeSyncMutation(
        id: seed.id, events: versionedEvents(seed.changes, startingAt: 1), for: harness.owner
    )
    #expect(projected.spaces?.first?.title == "Pending rename")
    #expect(try store.pendingSyncQueue(for: harness.owner) == [semantic])

    // A terminal semantic rejection supplies canonical state and consumes the
    // overlay even when the operation produced no new server event.
    let canonical = try store.acknowledgeSyncMutation(
        id: semantic.id, protocolVersion: 3,
        events: versionedEvents(seed.changes, startingAt: 1), for: harness.owner
    )
    #expect(canonical == original)
    #expect(try store.pendingSyncQueue(for: harness.owner).isEmpty)
    #expect(try store.syncCursor(for: harness.owner) == 0)
    // Unknown or already removed ACKs must not introduce unrelated events.
    _ = try store.acknowledgeSyncMutation(
        id: semantic.id, protocolVersion: 3,
        events: [versionedDelete(id: "a", sequence: 200)], for: harness.owner
    )
    #expect(store.loadSnapshot() == original)
}

@Test func versionedOutboxLocalDeleteSurvivesOldLegacyAckRestartAndSemanticAck() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    store.saveSnapshot(versionedSnapshot(ids: ["a", "b"]))
    try store.bindSyncOwner(harness.owner)
    let seed = try #require(store.pendingSyncMutations(for: harness.owner).first)
    try store.enableSemanticSyncMutations(for: harness.owner)
    try store.pauseSync()
    store.saveSnapshot(versionedSnapshot(ids: ["a"]))
    let deletion = try #require(store.pendingSyncQueue(for: harness.owner).last)
    guard case .semantic(let mutation) = deletion else { Issue.record("Expected semantic delete")
        return
    }
    #expect(mutation.operations.contains(.deleteTab(id: "b")))
    let reopened = try harness.store()
    #expect(try reopened.isSyncPaused(for: harness.owner))
    _ = try reopened.acknowledgeSyncMutation(
        id: seed.id, events: versionedEvents(seed.changes, startingAt: 1), for: harness.owner
    )
    #expect(reopened.loadSnapshot()?.tabs.map(\.id) == ["a"])
    _ = try reopened.acknowledgeSyncMutation(
        id: mutation.id, protocolVersion: 3,
        events: [versionedDelete(id: "b", sequence: 10)], for: harness.owner
    )
    _ = try reopened.applyRemoteSyncEvents(
        versionedEvents(seed.changes, startingAt: 20),
        cursor: 22,
        for: harness.owner
    )
    #expect(reopened.loadSnapshot()?.tabs.map(\.id) == ["a"])
    #expect(try reopened.pendingSyncQueue(for: harness.owner).isEmpty)
}

@Test func versionedOutboxSemanticCaptureAndAckRollbackAllStateOnStorageFailure() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let original = versionedSnapshot(ids: ["a"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    let seed = try #require(store.pendingSyncMutations(for: harness.owner).first)
    _ = try store.acknowledgeSyncMutation(
        id: seed.id,
        events: versionedEvents(seed.changes, startingAt: 1),
        for: harness.owner
    )
    try store.enableSemanticSyncMutations(for: harness.owner)
    let baseline = try harness.baseline()
    let database = try harness.database()
    try database.write { db in
        try db
            .execute(
                sql: "CREATE TRIGGER fail_versioned_insert BEFORE INSERT ON browser_sync_outbox BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
    }
    store.saveSnapshot(versionedSnapshot(ids: ["a", "b"]))
    #expect(store.loadSnapshot() == original)
    #expect(try store.pendingSyncQueue(for: harness.owner).isEmpty)
    #expect(try harness.baseline() == baseline)
    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_versioned_insert") }
    store.saveSnapshot(versionedSnapshot(ids: ["a"], title: "Pending"))
    let pending = try #require(store.pendingSyncQueue(for: harness.owner).first)
    let beforeRows = try harness.rows()
    let beforeSnapshot = store.loadSnapshot()
    try database.write { db in
        try db
            .execute(
                sql: "CREATE TRIGGER fail_versioned_projection BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
    }
    #expect(throws: DatabaseError.self) {
        try store.acknowledgeSyncMutation(
            id: pending.id, protocolVersion: 3,
            events: versionedEvents(seed.changes, startingAt: 10), for: harness.owner
        )
    }
    #expect(try harness.rows() == beforeRows)
    #expect(try harness.baseline() == baseline)
    #expect(store.loadSnapshot() == beforeSnapshot)
    #expect(try store.syncCursor(for: harness.owner) == 0)
}

@Test func versionedOutboxOwnerGuardsAndImmutableRowIdentity() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let foreign = BrowserSyncOwner(baseURL: harness.owner.baseURL, userID: "foreign")
    #expect(throws: BrowserSyncStoreError.ownerNotBound) { try store.enableSemanticSyncMutations(for: harness.owner) }
    store.saveSnapshot(versionedSnapshot(ids: ["a"]))
    try store.bindSyncOwner(harness.owner)
    #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.enableSemanticSyncMutations(for: foreign) }
    #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.pendingSyncQueue(for: foreign) }
    #expect(throws: BrowserSyncOutboxError.invalidLimit) { try store.pendingSyncQueue(for: harness.owner, limit: 0) }
    let first = try #require(store.pendingSyncQueue(for: harness.owner).first)
    #expect(first.protocolVersion == 2)
    #expect(throws: BrowserSyncStoreError.ownerMismatch) {
        try store.acknowledgeSyncMutation(id: first.id, protocolVersion: 2, events: [], for: foreign)
    }
    try harness.database().write { db in
        try db.execute(sql: "UPDATE browser_sync_outbox SET mutation_id = ?", arguments: [UUID().uuidString])
    }
    #expect(throws: BrowserSyncQueueError.invalidMutationIdentity) { try store.pendingSyncQueue(for: harness.owner) }
}

@Test func versionedOutboxPullCapabilityBaselineProjectionAndCursorCommitTogether() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    let original = versionedSnapshot(ids: ["a"])
    let changes = BrowserSyncOutboxProjection.changes(from: nil, to: original)
    _ = try store.applyRemoteSyncEvents(versionedEvents(changes, startingAt: 1), cursor: 2, for: harness.owner)
    let baseline = try harness.baseline()
    let newer = BrowserSyncOutboxProjection.changes(
        from: nil,
        to: versionedSnapshot(ids: ["a"], title: "Remote rename")
    )
    let database = try harness.database()
    try database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_capability BEFORE UPDATE OF new_mutation_version ON browser_sync_state
        WHEN NEW.new_mutation_version = 3 BEGIN SELECT RAISE(ABORT, 'injected'); END
        """)
    }
    #expect(throws: DatabaseError.self) {
        try store.applyRemoteSyncEvents(
            versionedEvents(newer, startingAt: 10), cursor: 11, for: harness.owner, enableSemanticMutations: true
        )
    }
    #expect(store.loadSnapshot() == original)
    #expect(try harness.baseline() == baseline)
    #expect(try store.syncCursor(for: harness.owner) == 2)
    #expect(try database.read { db in
        try Int.fetchOne(db, sql: "SELECT new_mutation_version FROM browser_sync_state")
    } == 2)
    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_capability") }
    _ = try store.applyRemoteSyncEvents(
        versionedEvents(newer, startingAt: 10), cursor: 11, for: harness.owner, enableSemanticMutations: true
    )
    #expect(try store.syncCursor(for: harness.owner) == 11)
    #expect(store.loadSnapshot()?.spaces?.first?.title == "Remote rename")
    store.saveSnapshot(versionedSnapshot(ids: ["a"], title: "Local rename"))
    #expect(try store.pendingSyncQueue(for: harness.owner).map(\.protocolVersion) == [3])
}

@Test func versionedOutboxBothCodecsChunkByEncodedBytesBelowServerLimit() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    // Escapes and multibyte characters make character counts insufficient.
    let largeTitle = String(repeating: "\"\\é", count: 200_000)
    let ids = (0..<7).map { "tab-\($0)" }
    store.saveSnapshot(versionedSnapshot(ids: ids, override: largeTitle))
    try store.bindSyncOwner(harness.owner)
    let legacy = try store.pendingSyncMutations(for: harness.owner)
    #expect(legacy.count > 1)
    #expect(legacy.flatMap(\.changes).map(\.entityID) == ["space"] + ids)
    let legacyRows = try harness.rows()
    try store.enableSemanticSyncMutations(for: harness.owner)
    store.saveSnapshot(versionedSnapshot(ids: ids, override: largeTitle + "changed"))
    let all = try store.pendingSyncQueue(for: harness.owner)
    #expect(all.filter { $0.protocolVersion == 3 }.count > 1)
    #expect(try Array(harness.rows().prefix(legacyRows.count)) == legacyRows)
    let device = "00000000-0000-4000-8000-000000000000"
    for queued in all {
        let request: Data
        switch queued {
        case .legacy(let mutation):
            #expect(mutation.changes.count <= 1000)
            request = try JSONEncoder().encode(BrowserSyncPushRequest(
                mutationID: mutation.id,
                deviceID: device,
                changes: mutation.changes
            ))
        case .semantic(let mutation):
            #expect(mutation.operations.count <= 1000)
            request = try JSONEncoder().encode(BrowserSyncSemanticPushRequest(
                mutationID: mutation.id,
                deviceID: device,
                operations: mutation.operations
            ))
        }
        #expect(request.count < 8 * 1024 * 1024)
    }
}

@Test func versionedOutboxSingleOversizeRecordRollsBackBindingAndSemanticCapture() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    let hugeTitle = String(repeating: "x", count: 8 * 1024 * 1024)
    let oversized = versionedSnapshot(ids: ["a"], override: hugeTitle)
    store.saveSnapshot(oversized)
    #expect(throws: BrowserSyncQueueError.mutationTooLarge) { try store.bindSyncOwner(harness.owner) }
    #expect(try store.syncOwner() == nil)
    #expect(try harness.rows().isEmpty)
    #expect(store.loadSnapshot() == oversized)

    let original = versionedSnapshot(ids: ["a"])
    store.saveSnapshot(original)
    try store.bindSyncOwner(harness.owner)
    try store.enableSemanticSyncMutations(for: harness.owner)
    let rows = try harness.rows()
    let baseline = try harness.baseline()
    store.saveSnapshot(oversized)
    #expect(store.loadSnapshot() == original)
    #expect(try harness.rows() == rows)
    #expect(try harness.baseline() == baseline)
}

@Test func versionedOutboxSemanticCaptureChunksOperationCountAndPersistsUpgradeAfterPause() throws {
    let harness = try VersionedOutboxHarness()
    defer { harness.cleanup() }
    let store = try harness.store()
    try store.bindSyncOwner(harness.owner)
    try store.enableSemanticSyncMutations(for: harness.owner)
    try store.pauseSync()
    let reopened = try harness.store()
    reopened.saveSnapshot(versionedSnapshot(ids: (0..<1001).map { "tab-\($0)" }))
    let queue = try reopened.pendingSyncQueue(for: harness.owner)
    #expect(queue.count > 1)
    #expect(queue.allSatisfy { $0.protocolVersion == 3 })
    let counts = queue.compactMap { queued -> Int? in
        guard case .semantic(let mutation) = queued else { return nil }
        return mutation.operations.count
    }
    #expect(counts.allSatisfy { $0 > 0 && $0 <= 1000 })
    #expect(counts.reduce(0, +) >= 1002)
    #expect(try reopened.isSyncPaused(for: harness.owner))
}

// MARK: - VersionedOutboxHarness

private struct VersionedOutboxHarness {
    // MARK: Lifecycle

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    // MARK: Internal

    let directory = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("versioned-outbox-\(UUID().uuidString)")
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "owner")

    var databaseURL: URL { directory.appendingPathComponent("test.sqlite") }

    func store() throws -> BrowserSQLiteSessionStore { try BrowserSQLiteSessionStore(databaseURL: databaseURL) }
    func database() throws -> DatabaseQueue { try DatabaseQueue(path: databaseURL.path) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func baseline() throws -> Data? {
        try database()
            .read { db in try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1") }
    }

    func rows() throws -> [VersionedStoredRow] {
        try database().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position"
            )
            .map {
                VersionedStoredRow(
                    position: $0["position"],
                    id: $0["mutation_id"],
                    payload: $0["payload"],
                    version: $0["protocol_version"]
                )
            }
        }
    }
}

// MARK: - VersionedStoredRow

private struct VersionedStoredRow: Equatable {
    let position: Int
    let id: String
    let payload: Data
    let version: Int
}

private func versionedSnapshot(
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

private func versionedDelete(id: String, type: String = "tab", sequence: Int) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence,
        deviceID: "remote",
        entityType: type,
        entityID: id,
        op: "delete",
        data: .deleted(id: id),
        createdAt: "2026-10-03T00:00:00Z"
    )
}

private func versionedEvents(_ changes: [BrowserSyncChange], startingAt sequence: Int) -> [BrowserSyncEvent] {
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
            deviceID: "remote",
            entityType: change.entityType.rawValue,
            entityID: change.entityID,
            op: change.op.rawValue,
            data: data,
            createdAt: "2026-10-03T00:00:00Z"
        )
    }
}
