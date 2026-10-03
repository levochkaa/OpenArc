import Foundation
import GRDB
import Testing

@Test func folderOutboxMigrationPreservesBothLegacyCodecsBytesFIFOAndSequence() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    store.saveSnapshot(folderOutboxSnapshot())
    try store.bindSyncOwner(fixture.owner)
    try store.enableSemanticSyncMutations(for: fixture.owner)
    store.saveSnapshot(folderOutboxSnapshot(spaceTitle: "Offline rename"))
    try store.saveSyncCursor(51, for: fixture.owner)
    try store.pauseSync()
    let db = try fixture.database()
    try db.write { db in
        for row in try Row.fetchAll(db, sql: "SELECT mutation_id, payload FROM browser_sync_outbox") {
            let json = try JSONSerialization.jsonObject(with: row["payload"] as Data)
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try db.execute(
                sql: "UPDATE browser_sync_outbox SET payload = ? WHERE mutation_id = ?",
                arguments: [bytes, row["mutation_id"] as String]
            )
        }
        try db.execute(sql: """
        ALTER TABLE browser_tabs DROP COLUMN pinned_sibling_rank;
        ALTER TABLE browser_pinned_tab_folders DROP COLUMN pinned_sibling_rank;
        CREATE TABLE old_outbox (
            position INTEGER PRIMARY KEY AUTOINCREMENT, mutation_id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL,
            protocol_version INTEGER NOT NULL DEFAULT 2 CHECK(protocol_version IN (2,3))
        );
        INSERT INTO old_outbox SELECT * FROM browser_sync_outbox;
        DROP TABLE browser_sync_outbox;
        ALTER TABLE old_outbox RENAME TO browser_sync_outbox;
        UPDATE sqlite_sequence SET seq = 900 WHERE name = 'browser_sync_outbox';
        CREATE TABLE old_state (
            id INTEGER PRIMARY KEY CHECK(id=1), base_url TEXT NOT NULL, user_id TEXT NOT NULL,
            cursor INTEGER NOT NULL DEFAULT 0, paused INTEGER NOT NULL DEFAULT 0,
            new_mutation_version INTEGER NOT NULL DEFAULT 2 CHECK(new_mutation_version IN (2,3))
        );
        INSERT INTO old_state SELECT * FROM browser_sync_state;
        DROP TABLE browser_sync_state;
        ALTER TABLE old_state RENAME TO browser_sync_state;
        DELETE FROM grdb_migrations WHERE identifier = 'addFolderSyncOutbox';
        """)
    }
    let before = try fixture.rows()
    let migrated = try fixture.store()
    #expect(try fixture.rows() == before)
    #expect(try migrated.pendingSyncQueue(for: fixture.owner).map(\.protocolVersion) == [2, 3])
    #expect(try migrated.syncCursor(for: fixture.owner) == 51)
    #expect(try migrated.isSyncPaused(for: fixture.owner))
    #expect(try migrated.syncPullProtocolVersion(for: fixture.owner) == 2)
    #expect(throws: BrowserSyncQueueError.bootstrapRequiresLegacyDrain) {
        try migrated.completeFolderSyncBootstrap(events: [], cursor: 99, for: fixture.owner)
    }
    #expect(try fixture.rows() == before)
    migrated.saveSnapshot(folderOutboxSnapshot(spaceTitle: "Later rename"))
    #expect(try fixture.rows().last?.position == 901)
    #expect(try Array(fixture.rows().prefix(before.count)) == before)
    #expect(try fixture.store().pendingSyncQueue(for: fixture.owner).map(\.protocolVersion) == [2, 3, 3])
}

@Test func folderBootstrapAdoptsLocalTreeOnceAfterLegacyAckAndKeepsFrozenV4RowsAcrossRebootstrap() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    let local = folderOutboxSnapshot()
    store.saveSnapshot(local)
    try store.bindSyncOwner(fixture.owner)
    let seed = try #require(store.pendingSyncMutations(for: fixture.owner).first)
    let remote = try folderOutboxEvents(seed.changes, startingAt: 1)
    _ = try store.acknowledgeSyncMutation(id: seed.id, events: remote, for: fixture.owner)
    #expect(store.loadSnapshot()?.pinnedTabFolders == local.pinnedTabFolders)
    #expect(store.loadSnapshot()?.tabs.first?.pinnedFolderID == "nested")
    #expect(store.loadSnapshot()?.tabs.last?.pinnedSiblingRank == 1)
    let projected = try store.completeFolderSyncBootstrap(events: remote, cursor: 10, for: fixture.owner)
    #expect(try store.syncPullProtocolVersion(for: fixture.owner) == 4)
    #expect(try store.syncCursor(for: fixture.owner) == 10)
    let queue = try store.pendingSyncQueue(for: fixture.owner)
    #expect(!queue.isEmpty && queue.allSatisfy { $0.protocolVersion == 4 })
    let operations = queue.flatMap { row -> [BrowserSyncFolderOperation] in
        guard case .folders(let mutation) = row else { return [] }
        return mutation.operations
    }
    #expect(operations
        .contains {
            if case .createFolder(id: "root", data: _, before: _, after: _) = $0 {
                true
            } else {
                false
            }
        })
    #expect(operations
        .contains {
            if case .createFolder(id: "nested", data: _, before: _, after: _) = $0 {
                true
            } else {
                false
            }
        })
    #expect(projected.tabs.first { $0.id == "child" }?.pinnedFolderID == "nested")
    #expect(projected.pinnedTabFolders?.first { $0.id == "nested" }?.parentFolderID == "root")
    #expect(projected.pinnedTabFolders?.first { $0.id == "root" }?.isExpanded == false)
    let frozen = try fixture.rows()
    let reopened = try fixture.store()
    try reopened.enableSemanticSyncMutations(for: fixture.owner)
    #expect(try reopened.syncPullProtocolVersion(for: fixture.owner) == 4)
    _ = try reopened.completeFolderSyncBootstrap(events: remote, cursor: 10, for: fixture.owner)
    #expect(try fixture.rows() == frozen)
    #expect(reopened.loadSnapshot() == projected)
    try reopened.writeSessionBatch([.init(snapshot: projected, origin: .local(syncMove: nil))])
    #expect(try fixture.rows() == frozen, "Reopening and saving the same projection cannot echo adoption")

    let acknowledged = try folderOutboxEvents(BrowserSyncFolderProjection.canonicalChanges(projected), startingAt: 100)
    for row in queue {
        _ = try reopened.acknowledgeSyncMutation(
            id: row.id,
            protocolVersion: 4,
            events: acknowledged,
            for: fixture.owner
        )
    }
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
    let saved = try #require(reopened.loadSnapshot())
    try reopened.writeSessionBatch([.init(snapshot: saved, origin: .local(syncMove: nil))])
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
}

@Test func folderBootstrapFreshProfileProjectsTypedMixedRanksAndKeepsRemoteFolderMetadata() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    try store.bindSyncOwner(fixture.owner)
    let snapshot = folderOutboxSnapshot(rootTitle: "Canonical folder", childRank: 2)
    let events = try folderOutboxEvents(BrowserSyncFolderProjection.canonicalChanges(snapshot), startingAt: 1)
    let projected = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: fixture.owner)
    #expect(
        try store.pendingSyncQueue(for: fixture.owner).isEmpty,
        "Fresh profile must not adopt remote folders as local creates"
    )
    #expect(projected.pinnedTabFolders?.first { $0.id == "root" }?.title == "Canonical folder")
    #expect(projected.pinnedTabFolders?.first { $0.id == "root" }?.pinnedSiblingRank == 0)
    #expect(projected.pinnedTabFolders?.first { $0.id == "nested" }?.parentFolderID == "root")
    #expect(projected.tabs.first { $0.id == "child" }?.pinnedSiblingRank == 2)
    #expect(projected.tabs.first { $0.id == "loose" }?.pinnedSiblingRank == 1)
    #expect(projected.pinnedTabFolders?.first { $0.id == "empty" }?.pinnedSiblingRank == 2)
    #expect(try fixture.store().loadSnapshot() == projected)
    try store.writeSessionBatch([.init(snapshot: projected, origin: .local(syncMove: nil))])
    #expect(try store.pendingSyncQueue(for: fixture.owner).isEmpty)
}

@Test func legacyFolderRootMoveStillCapturesDescendantTabsBeforeUpgrade() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    let spaces = [
        BrowserSpaceSessionSnapshot(id: "source", title: "Source", systemImageName: "globe"),
        BrowserSpaceSessionSnapshot(id: "target", title: "Target", systemImageName: "globe"),
    ]
    func snapshot(spaceID: String) -> BrowserTabSessionSnapshot {
        .init(
            spaces: spaces,
            pinnedTabFolders: [.init(id: "folder", spaceID: spaceID, title: "Folder")],
            tabs: [.init(
                id: "child",
                urlString: "https://example.com",
                placement: .spacePinned,
                spaceID: spaceID,
                pinnedFolderID: "folder"
            )]
        )
    }
    try store.writeSessionBatch([.init(snapshot: snapshot(spaceID: "source"), origin: .local(syncMove: nil))])
    try store.bindSyncOwner(fixture.owner)
    try store.enableSemanticSyncMutations(for: fixture.owner)
    let frozenSeed = try fixture.rows()
    try store.writeSessionBatch([.init(snapshot: snapshot(spaceID: "target"), origin: .local(syncMove: .init(items: [
        .init(entityType: .folder, entityID: "folder"),
    ])))])
    let row = try #require(store.pendingSyncQueue(for: fixture.owner).last)
    guard case .semantic(let mutation) = row else {
        Issue.record("Before v4 adoption, a folder action must retain the v3 codec")
        return
    }
    #expect(mutation.operations.contains {
        if case .moveTabs(let ids, let destination, _, _) = $0 {
            ids == ["child"] && destination.spaceID == "target" && destination.placement == .spacePinned
        } else {
            false
        }
    })
    #expect(try Array(fixture.rows().prefix(frozenSeed.count)) == frozenSeed)
}

@Test func folderBootstrapRollsBackAdoptionVersionCursorAndProjectionOnDatabaseFailure() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    store.saveSnapshot(folderOutboxSnapshot())
    try store.bindSyncOwner(fixture.owner)
    let seed = try #require(store.pendingSyncMutations(for: fixture.owner).first)
    let remote = try folderOutboxEvents(seed.changes, startingAt: 1)
    _ = try store.acknowledgeSyncMutation(id: seed.id, events: remote, for: fixture.owner)
    try store.saveSyncCursor(8, for: fixture.owner)
    let before = store.loadSnapshot()
    let baseline = try fixture.baseline()
    let database = try fixture.database()
    try database.write { db in
        try db
            .execute(
                sql: "CREATE TRIGGER fail_folder_adoption BEFORE INSERT ON browser_sync_outbox BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
    }
    #expect(throws: DatabaseError.self) { try store.completeFolderSyncBootstrap(
        events: remote,
        cursor: 10,
        for: fixture.owner
    ) }
    #expect(try store.syncPullProtocolVersion(for: fixture.owner) == 2)
    #expect(try store.syncCursor(for: fixture.owner) == 8)
    #expect(store.loadSnapshot() == before)
    #expect(try fixture.baseline() == baseline)
    #expect(try fixture.rows().isEmpty)
    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_folder_adoption") }
    let adopted = try store.completeFolderSyncBootstrap(events: remote, cursor: 10, for: fixture.owner)
    let frozen = try fixture.rows()
    let adoptedBaseline = try fixture.baseline()
    try database.write { db in
        try db
            .execute(
                sql: "CREATE TRIGGER fail_folder_projection BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
    }
    #expect(throws: DatabaseError.self) { try store.completeFolderSyncBootstrap(
        events: remote,
        cursor: 20,
        for: fixture.owner
    ) }
    #expect(try fixture.rows() == frozen)
    #expect(try fixture.baseline() == adoptedBaseline)
    #expect(store.loadSnapshot() == adopted)
    #expect(try store.syncCursor(for: fixture.owner) == 10)
}

@Test func folderOutboxCaptureVersionGuardTerminalAckAndRebootstrapPreserveDeletion() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    try store.bindSyncOwner(fixture.owner)
    let initial = folderOutboxSnapshot()
    let originalEvents = try folderOutboxEvents(BrowserSyncFolderProjection.canonicalChanges(initial), startingAt: 1)
    _ = try store.completeFolderSyncBootstrap(events: originalEvents, cursor: 10, for: fixture.owner)
    var changed = initial.pinnedTabFolders ?? []
    changed[0] = .init(id: "root", spaceID: "space", title: "Local rename", isExpanded: false, pinnedSiblingRank: 0)
    let renamed = BrowserTabSessionSnapshot(spaces: initial.spaces, pinnedTabFolders: changed, tabs: initial.tabs)
    try store.writeSessionBatch([.init(snapshot: renamed, origin: .local(syncMove: nil))])
    let pending = try #require(store.pendingSyncQueue(for: fixture.owner).first)
    let rows = try fixture.rows(), baseline = try fixture.baseline()
    #expect(throws: BrowserSyncQueueError.protocolVersionMismatch) {
        try store.acknowledgeSyncMutation(id: pending.id, protocolVersion: 3, events: [], for: fixture.owner)
    }
    #expect(try fixture.rows() == rows && fixture.baseline() == baseline)
    let canonical = try store.acknowledgeSyncMutation(
        id: pending.id,
        protocolVersion: 4,
        events: originalEvents,
        for: fixture.owner
    )
    #expect(canonical.pinnedTabFolders?.first { $0.id == "root" }?.title == "Local folder")
    #expect(try store.pendingSyncQueue(for: fixture.owner).isEmpty)

    let deleted = BrowserTabSessionSnapshot(
        spaces: canonical.spaces,
        pinnedTabFolders: canonical.pinnedTabFolders?.filter { $0.id == "empty" },
        tabs: canonical.tabs.filter { $0.id != "child" }
    )
    try store.writeSessionBatch([.init(snapshot: deleted, origin: .local(syncMove: nil))])
    let deletion = try #require(store.pendingSyncQueue(for: fixture.owner).first)
    let projected = try store.completeFolderSyncBootstrap(events: originalEvents, cursor: 10, for: fixture.owner)
    let projectedFolders = try #require(projected.pinnedTabFolders)
    #expect(!projectedFolders.contains { $0.id == "root" || $0.id == "nested" })
    #expect(!projected.tabs.contains { $0.id == "child" })
    let remoteDeletes = try [
        folderOutboxDelete(type: "folder", id: "root", sequence: 100),
        folderOutboxDelete(type: "folder", id: "nested", sequence: 101),
        folderOutboxDelete(type: "tab", id: "child", sequence: 102),
    ]
    _ = try store.acknowledgeSyncMutation(
        id: deletion.id,
        protocolVersion: 4,
        events: remoteDeletes,
        for: fixture.owner
    )
    _ = try store.applyRemoteSyncEvents(originalEvents, cursor: 103, for: fixture.owner)
    let reopened = try fixture.store()
    #expect(reopened.loadSnapshot()?.tabs.contains { $0.id == "child" } == false)
    #expect(reopened.loadSnapshot()?.pinnedTabFolders?.contains { $0.id == "root" } == false)
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
}

@Test func folderTombstonesFilterMissingParentReferencesWithoutOutboxResurrection() throws {
    let fixture = FolderOutboxFixture()
    defer { fixture.cleanup() }
    let store = try fixture.store()
    try store.bindSyncOwner(fixture.owner)
    let events = try folderOutboxEvents(
        BrowserSyncFolderProjection.canonicalChanges(folderOutboxSnapshot()),
        startingAt: 1
    )
    _ = try store.completeFolderSyncBootstrap(events: events, cursor: 10, for: fixture.owner)
    let deletes = try [
        folderOutboxDelete(type: "folder", id: "root", sequence: 11),
        folderOutboxDelete(type: "folder", id: "nested", sequence: 12),
        folderOutboxDelete(type: "tab", id: "child", sequence: 13),
    ]
    let canonical = try store.applyRemoteSyncEvents(deletes, cursor: 13, for: fixture.owner)
    let lateSnapshot = BrowserTabSessionSnapshot(
        spaces: canonical.spaces,
        pinnedTabFolders: (canonical.pinnedTabFolders ?? []) + [
            .init(id: "late-folder", spaceID: "space", parentFolderID: "root", title: "Late folder"),
            .init(id: "late-nested", spaceID: "space", parentFolderID: "late-folder", title: "Late nested"),
        ],
        tabs: canonical.tabs + [
            .init(
                id: "late-direct",
                urlString: "https://example.com/direct",
                placement: .spacePinned,
                spaceID: "space",
                pinnedFolderID: "root"
            ),
            .init(
                id: "late-descendant",
                urlString: "https://example.com/descendant",
                placement: .spacePinned,
                spaceID: "space",
                pinnedFolderID: "late-nested"
            ),
        ]
    )
    try store.writeSessionBatch([.init(snapshot: lateSnapshot, origin: .local(syncMove: nil))])
    #expect(store.loadSnapshot() == canonical, "A missing deleted parent must still suppress late children")
    #expect(try store.pendingSyncQueue(for: fixture.owner).isEmpty)
    let reopened = try fixture.store()
    #expect(reopened.loadSnapshot() == canonical)
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
}

// MARK: - FolderOutboxFixture

private struct FolderOutboxFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-outbox-\(UUID())")
    let owner = BrowserSyncOwner(baseURL: URL(string: "http://localhost:8080")!, userID: "folder-owner")

    var url: URL { directory.appendingPathComponent("session.sqlite") }

    func store() throws -> BrowserSQLiteSessionStore { try .init(databaseURL: url) }
    func database() throws -> DatabaseQueue { try DatabaseQueue(path: url.path) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func rows() throws -> [FolderOutboxRow] {
        try database().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position"
            )
            .map {
                FolderOutboxRow(
                    position: $0["position"],
                    id: $0["mutation_id"],
                    bytes: $0["payload"],
                    version: $0["protocol_version"]
                )
            }
        }
    }

    func baseline() throws -> Data? {
        try database().read { try Data.fetchOne($0, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1") }
    }
}

// MARK: - FolderOutboxRow

private struct FolderOutboxRow: Equatable {
    let position: Int
    let id: String
    let bytes: Data
    let version: Int
}

private func folderOutboxSnapshot(
    spaceTitle: String = "Work", rootTitle: String = "Local folder", childRank: Double = 0
) -> BrowserTabSessionSnapshot {
    .init(spaces: [.init(id: "space", title: spaceTitle, systemImageName: "globe")], pinnedTabFolders: [
        .init(id: "root", spaceID: "space", title: rootTitle, isExpanded: false, pinnedSiblingRank: 0),
        .init(id: "nested", spaceID: "space", parentFolderID: "root", title: "Nested", pinnedSiblingRank: 0),
        .init(id: "empty", spaceID: "space", title: "Empty", pinnedSiblingRank: 2),
    ], tabs: [
        .init(
            id: "child",
            urlString: "https://example.com/current",
            pinnedURLString: "https://example.com/home",
            placement: .spacePinned,
            spaceID: "space",
            pinnedFolderID: "nested",
            pinnedSiblingRank: childRank
        ),
        .init(
            id: "loose",
            urlString: "https://example.com/loose",
            pinnedURLString: "https://example.com/loose",
            placement: .spacePinned,
            spaceID: "space",
            pinnedSiblingRank: 1
        ),
    ])
}

private func folderOutboxEvents(_ changes: [BrowserSyncChange], startingAt start: Int) throws -> [BrowserSyncEvent] {
    try changes.enumerated().map { index, change in
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
        var data = encoded["data"] as? [String: Any] ?? [:]
        data["id"] = change.entityID
        return try folderOutboxEvent(
            type: change.entityType.rawValue,
            id: change.entityID,
            sequence: start + index,
            op: change.op.rawValue,
            data: data
        )
    }
}

private func folderOutboxDelete(type: String, id: String, sequence: Int) throws -> BrowserSyncEvent {
    try folderOutboxEvent(type: type, id: id, sequence: sequence, op: "delete", data: ["id": id])
}

private func folderOutboxEvent(
    type: String,
    id: String,
    sequence: Int,
    op: String,
    data: [String: Any]
) throws -> BrowserSyncEvent {
    let wire: [String: Any] = [
        "serverSeq": sequence,
        "deviceID": NSNull(),
        "entityType": type,
        "entityID": id,
        "op": op,
        "data": data,
        "createdAt": "2026-10-03T00:00:00Z",
    ]
    return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
}
