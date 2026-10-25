import Foundation
import GRDB
import Testing

@Test func expiryBootstrapPreservesPendingBytesAndImportsTheFinalDivergentContent() throws {
    let f = try ExpiryRecoveryFixture()
    defer { f.cleanup() }
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: "Intermediate local title")
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: nil)
    try f.prettyPrintQueue()
    let frozen = try f.queueRows()
    let onlyFolderRows = frozen.allSatisfy { $0.version == 4 }
    #expect(frozen.count == 2 && onlyFolderRows)
    #expect(try f.store.syncPullProtocolVersion(for: f.owner) == 4)
    let revision = try f.store.syncArchiveRevision(for: f.owner)

    let projected = try f.store.completeExpirySyncBootstrap(events: f.history, cursor: 20, for: f.owner)
    #expect(projected.tabs.map(\.id) == ["survivor"])
    #expect(try f.store.syncCursor(for: f.owner) == 20)
    #expect(try f.store.syncPullProtocolVersion(for: f.owner) == 5)
    #expect(try f.queueRows() == frozen)
    let entries = try f.store.loadArchivePage().entries
    #expect(entries.count == 2)
    let canonical = try #require(entries.first { $0.tab.urlString == ExpiryRecoveryFixture.canonicalURL })
    let local = try #require(entries.first { $0.tab.urlString == ExpiryRecoveryFixture.offlineURL })
    #expect(canonical.tab.userTitleOverride == "Canonical custom title")
    #expect(canonical.title == "Canonical loaded title")
    #expect(local.tab.userTitleOverride == nil, "Explicit title clearing must not fall back to canonical text")
    #expect(canonical.tab.id == "expired" && local.tab.id == "expired")
    #expect(canonical.id != local.id)
    #expect(try f.store.syncArchiveRevision(for: f.owner) > revision)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    #expect(try reopened.loadSnapshotStrict() == projected)
    #expect(try reopened.loadArchivePage().entries == entries)
    #expect(try reopened.syncPullProtocolVersion(for: f.owner) == 5)
    #expect(try f.queueRows() == frozen)
    // Reading v5 must leave ordinary local edits on the existing v4 codec.
    let changed = expiryRecoveryReplacing(projected, projected.tabs.map {
        .init(id: $0.id, urlString: $0.urlString, userTitleOverride: "Later survivor edit", spaceID: $0.spaceID)
    })
    try reopened.writeSessionBatch([.init(snapshot: changed, origin: .local(syncMove: nil))])
    let queue = try reopened.pendingSyncQueue(for: f.owner)
    #expect(queue.count == 3 && queue.last?.protocolVersion == 4)
    #expect(try Array(f.queueRows().prefix(2)) == frozen)
}

@Test(arguments: ["pull", "ack", "bootstrap"])
func expiryRecoveryFailureRollsBackArchiveAndSyncStateTogether(path: String) throws {
    let f = try ExpiryRecoveryFixture()
    defer { f.cleanup() }
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: nil)
    let pending = try #require(try f.store.pendingSyncQueue(for: f.owner).first)
    let before = try f.evidence()
    try f
        .sql(
            "CREATE TRIGGER fail_expiry_archive BEFORE INSERT ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected recovery failure'); END"
        )
    #expect(throws: DatabaseError.self) {
        _ = try f.apply(path: path, pending: pending)
    }
    #expect(try f.evidence() == before)
    try f.sql("DROP TRIGGER fail_expiry_archive")

    let projected = try f.apply(path: path, pending: pending)
    #expect(projected.tabs.map(\.id) == ["survivor"])
    #expect(try f.store.loadArchivePage().entries.count == 2)
    let expectedCursor = path == "ack" ? before.cursor : 20
    #expect(try f.store.syncCursor(for: f.owner) == expectedCursor)
    let expectedRows = path == "ack" ? [] : before.queue
    #expect(try f.queueRows() == expectedRows)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    #expect(try reopened.loadArchivePage().entries.count == 2)
    #expect(try reopened.loadSnapshotStrict() == projected)
}

@Test(arguments: ["clear", "remove", "restore"]) @MainActor
func consumedExpiryRecoveryDoesNotReappearAfterBootstrapOrReceiptReplay(consumption: String) async throws {
    let f = try ExpiryRecoveryFixture()
    defer { f.cleanup() }
    _ = try f.store.completeExpirySyncBootstrap(events: f.history, cursor: 20, for: f.owner)
    let entry = try #require(try f.store.loadArchivePage().entries.first)
    #expect(try f.store.loadArchivePage().entries.count == 1)
    if consumption == "restore" {
        let current = try #require(try f.store.loadSnapshotStrict())
        let restored = BrowserTabSessionSnapshotTab(
            id: "fresh-restored", urlString: entry.tab.urlString,
            userTitleOverride: entry.tab.userTitleOverride, spaceID: "target", lastActivityTimestamp: 1_800_000_100
        )
        try f.store.writeSessionBatch([.init(
            snapshot: expiryRecoveryReplacing(current, current.tabs + [restored]),
            origin: .local(syncMove: nil), archiveAction: .restore(archiveID: entry.id, tabID: "fresh-restored")
        )])
    } else if consumption == "remove" {
        let removed = try await f.store.removeArchiveEntry(id: entry.id)
        #expect(removed)
    } else {
        let boundary = try await f.store.archiveClearBoundary()
        let removed = try await f.store.clearArchive(through: boundary)
        #expect(removed == 1)
    }
    #expect(try f.store.loadArchivePage().entries.isEmpty)
    let snapshot = try f.store.loadSnapshotStrict()
    let frozen = try f.queueRows()
    let revision = try f.store.syncArchiveRevision(for: f.owner)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    _ = try reopened.completeExpirySyncBootstrap(events: f.history, cursor: 20, for: f.owner)
    _ = try reopened.applyRemoteSyncEvents([f.recovery], cursor: 20, for: f.owner)
    _ = try reopened.acknowledgeSyncMutation(
        id: "already-consumed-ack", protocolVersion: 4, events: [f.recovery], for: f.owner
    )
    #expect(try reopened.loadArchivePage().entries.isEmpty)
    #expect(try reopened.syncArchiveRevision(for: f.owner) == revision)
    #expect(try reopened.loadSnapshotStrict() == snapshot)
    #expect(try f.queueRows() == frozen)
    #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "expired" } == false)
    if consumption == "restore" {
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "fresh-restored" } == true)
    }
}

@Test(arguments: [2, 3, 4])
func expiryRecoveryCapturesOldPendingContentEvenWhenTheTombstoneWasAlreadyKnown(protocolVersion: Int) throws {
    let f = try ExpiryRecoveryFixture(protocolVersion: protocolVersion)
    defer { f.cleanup() }
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: nil)
    try f.prettyPrintQueue()
    let queued = try f.store.pendingSyncQueue(for: f.owner)
    let pending = try #require(queued.first)
    #expect(queued.count == 1 && pending.protocolVersion == protocolVersion)
    let frozen = try f.queueRows()
    let oldClientDelete = BrowserSyncEvent(
        serverSeq: 20, deviceID: "other-device", entityType: "tab", entityID: "expired", op: "delete",
        data: .deleted(id: "expired"), createdAt: "2026-10-03T12:00:00Z"
    )
    _ = try f.store.applyRemoteSyncEvents([oldClientDelete], cursor: 20, for: f.owner)
    #expect(try f.store.loadSnapshotStrict()?.tabs.map(\.id) == ["survivor"])
    #expect(try f.store.loadArchivePage().entries.isEmpty)
    #expect(try f.queueRows() == frozen)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    let revision = try reopened.syncArchiveRevision(for: f.owner)
    // ACK must preserve its own still-pending payload before removing that row.
    // The current snapshot and ordinary pending projection both hide this ID.
    let projected = try reopened.acknowledgeSyncMutation(
        id: pending.id, protocolVersion: protocolVersion, events: [f.recovery], for: f.owner
    )
    #expect(projected.tabs.map(\.id) == ["survivor"])
    #expect(try reopened.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try reopened.syncCursor(for: f.owner) == 20)
    let entries = try reopened.loadArchivePage().entries
    #expect(entries.count == 2)
    let local = try #require(entries.first { $0.tab.urlString == ExpiryRecoveryFixture.offlineURL })
    #expect(local.tab.userTitleOverride == nil)
    let hasCanonical = entries.contains { $0.tab.urlString == ExpiryRecoveryFixture.canonicalURL }
    #expect(hasCanonical)
    #expect(try reopened.syncArchiveRevision(for: f.owner) > revision)
    let after = try reopened.syncArchiveRevision(for: f.owner)
    _ = try reopened.applyRemoteSyncEvents([f.recovery], cursor: 20, for: f.owner)
    #expect(try reopened.loadArchivePage().entries == entries)
    #expect(try reopened.syncArchiveRevision(for: f.owner) == after)
}

@Test(arguments: ["wrong-tab", "invalid-time", "wrong-sequence", "persistent-placement", "missing-url"])
func malformedExpiryRecoveryCannotAdvanceCursorOrApplyDeletion(corruption: String) throws {
    let f = try ExpiryRecoveryFixture()
    defer { f.cleanup() }
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: nil)
    let before = try f.evidence()
    var tab: [String: Any] = [
        "id": "expired", "spaceID": "source", "placement": "temporary", "rank": 0,
        "urlString": ExpiryRecoveryFixture.canonicalURL, "lastActivityAt": "2000-01-01T00:00:00.123456Z",
    ]
    if corruption == "wrong-tab" {
        tab["id"] = "someone-else"
    }
    if corruption == "persistent-placement" {
        tab["placement"] = "app"
    }
    if corruption == "missing-url" {
        tab.removeValue(forKey: "urlString")
    }
    let archive: [String: Any] = [
        "archivedAt": corruption == "invalid-time" ? "not-a-date" : "2026-10-03T12:00:00.123456Z",
        "sourceServerSeq": corruption == "wrong-sequence" ? 21 : 3, "tab": tab,
    ]
    let wire: [String: Any] = [
        "serverSeq": 20, "deviceID": "other-device", "entityType": "tab", "entityID": "expired", "op": "delete",
        "data": ["id": "expired", "autoArchive": archive], "createdAt": "2026-10-03T12:00:00Z",
    ]
    let bytes = try JSONSerialization.data(withJSONObject: wire)
    #expect(throws: (any Error).self) {
        let event = try JSONDecoder().decode(BrowserSyncEvent.self, from: bytes)
        _ = try f.store.applyRemoteSyncEvents([event], cursor: 20, for: f.owner)
    }
    #expect(try f.evidence() == before)
}

@Test(arguments: [2, 3, 4])
func expiryRecoveryMigrationPreservesOriginalQueueBytesAndStartsWithAnUnacknowledgedBootstrap(
    protocolVersion: Int
) throws {
    let f = try ExpiryRecoveryFixture(protocolVersion: protocolVersion)
    defer { f.cleanup() }
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: "First edit")
    try f.editExpired(url: ExpiryRecoveryFixture.offlineURL, title: nil)
    try f.prettyPrintQueue()
    let before = try f.evidence()
    #expect(before.queue.count == 2)
    // Reconstruct the immediately preceding schema. Existing request BLOBs have
    // deliberately non-default whitespace so decode/re-encode cannot pass.
    try f.sql("""
    ALTER TABLE browser_sync_state DROP COLUMN expiry_recovery_enabled;
    ALTER TABLE browser_sync_state DROP COLUMN archive_revision;
    DROP TABLE browser_sync_expiry_imports;
    DELETE FROM grdb_migrations WHERE identifier = 'addSyncExpiryRecovery';
    """)
    let migrated = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    #expect(try f.queueRows() == before.queue)
    #expect(try migrated.loadSnapshotStrict() == before.snapshot)
    #expect(try migrated.syncCursor(for: f.owner) == before.cursor)
    #expect(try migrated.syncPullProtocolVersion(for: f.owner) == before.pullVersion)
    #expect(try migrated.syncArchiveRevision(for: f.owner) == 0)
    let rows = try DatabaseQueue(path: f.databaseURL.path).read { db in
        try (
            Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
            Int.fetchOne(db, sql: "SELECT COUNT(*) FROM browser_sync_expiry_imports")
        )
    }
    #expect(rows.0 == before.baseline && rows.1 == 0)
    let versions = try migrated.pendingSyncQueue(for: f.owner).map(\.protocolVersion)
    #expect(versions == [protocolVersion, protocolVersion])
}

// MARK: - ExpiryRecoveryFixture

private struct ExpiryRecoveryFixture {
    // MARK: Lifecycle

    init(protocolVersion: Int = 4) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExpiryRecovery-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try store.bindSyncOwner(owner)
        _ =
            if protocolVersion == 4 {
                try store.completeFolderSyncBootstrap(events: seed, cursor: 4, for: owner)
            } else {
                try store.applyRemoteSyncEvents(
                    seed,
                    cursor: 4,
                    for: owner,
                    enableSemanticMutations: protocolVersion == 3
                )
            }
    }

    // MARK: Internal

    static let canonicalURL = "https://example.com/canonical-recovery"
    static let offlineURL = "https://example.com/offline-recovery"

    let directory: URL
    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://recovery.example")!, userID: "recovery-owner")

    var canonical: BrowserSyncEventTabData {
        .init(
            id: "expired", spaceID: "source", placement: .temporary, rank: 0,
            urlString: Self.canonicalURL, pinnedURLString: nil, title: "Canonical loaded title",
            userTitleOverride: "Canonical custom title", faviconURLString: "https://example.com/favicon.ico",
            lastActivityAt: "2000-01-01T00:00:00.123456Z", pinnedFolderID: nil
        )
    }

    var seed: [BrowserSyncEvent] {
        [
            event(sequence: 1, type: "space", id: "source", data: .space(.init(
                id: "source", title: "Source", systemImageName: "globe", rank: 0,
                isPinnedSectionCollapsed: false, selectedTabID: nil
            ))),
            event(sequence: 2, type: "space", id: "target", data: .space(.init(
                id: "target", title: "Target", systemImageName: "star", rank: 1,
                isPinnedSectionCollapsed: false, selectedTabID: nil
            ))),
            event(sequence: 3, type: "tab", id: "expired", data: .tab(canonical)),
            event(sequence: 4, type: "tab", id: "survivor", data: .tab(.init(
                id: "survivor", spaceID: "source", placement: .temporary, rank: 1,
                urlString: "https://example.com/survivor", pinnedURLString: nil, title: "Survivor",
                userTitleOverride: nil, faviconURLString: nil, lastActivityAt: "2026-10-03T11:00:00Z"
            ))),
        ]
    }

    var recovery: BrowserSyncEvent {
        .init(
            serverSeq: 20, deviceID: "other-device", entityType: "tab", entityID: "expired", op: "delete",
            data: .deleted(id: "expired", autoArchive: .init(
                archivedAt: "2026-10-03T12:00:00.123456Z", sourceServerSeq: 3, tab: canonical
            )), createdAt: "2026-10-03T12:00:00Z"
        )
    }

    var history: [BrowserSyncEvent] { seed + [recovery] }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func sql(_ statement: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: statement) }
    }

    func editExpired(url: String, title: String?) throws {
        let previous = try #require(try store.loadSnapshotStrict())
        let next = expiryRecoveryReplacing(previous, previous.tabs.map { tab in
            guard tab.id == "expired" else { return tab }
            return .init(
                id: tab.id, urlString: url, userTitleOverride: title, spaceID: tab.spaceID,
                lastActivityTimestamp: tab.lastActivityTimestamp
            )
        })
        try store.writeSessionBatch([.init(snapshot: next, origin: .local(syncMove: nil))])
    }

    func apply(path: String, pending: BrowserSyncQueuedMutation) throws -> BrowserTabSessionSnapshot {
        switch path {
        case "ack": try store.acknowledgeSyncMutation(
                id: pending.id, protocolVersion: pending.protocolVersion, events: [recovery], for: owner
            )
        case "bootstrap": try store.completeExpirySyncBootstrap(events: history, cursor: 20, for: owner)
        default: try store.applyRemoteSyncEvents([recovery], cursor: 20, for: owner)
        }
    }

    func prettyPrintQueue() throws {
        try DatabaseQueue(path: databaseURL.path).write { db in
            for row in try Row.fetchAll(db, sql: "SELECT mutation_id, payload FROM browser_sync_outbox") {
                let json = try JSONSerialization.jsonObject(with: row["payload"] as Data)
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try db.execute(
                    sql: "UPDATE browser_sync_outbox SET payload = ? WHERE mutation_id = ?",
                    arguments: [data, row["mutation_id"] as String]
                )
            }
        }
    }

    func queueRows() throws -> [ExpiryRecoveryQueueRow] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, protocol_version, payload FROM browser_sync_outbox ORDER BY position"
            )
            .map { .init(
                position: $0["position"],
                id: $0["mutation_id"],
                version: $0["protocol_version"],
                bytes: $0["payload"]
            ) }
        }
    }

    func evidence() throws -> ExpiryRecoveryEvidence {
        let rows = try DatabaseQueue(path: databaseURL.path).read { db in
            try (
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id, '') FROM browser_tab_archive_receipts ORDER BY id"
                )
            )
        }
        return try .init(
            snapshot: store.loadSnapshotStrict(), queue: queueRows(), baseline: rows.0, archive: rows.1,
            receipts: rows.2, cursor: store.syncCursor(for: owner),
            pullVersion: store.syncPullProtocolVersion(for: owner),
            revision: store.syncArchiveRevision(for: owner)
        )
    }

    // MARK: Private

    private func event(sequence: Int, type: String, id: String, data: BrowserSyncEventData) -> BrowserSyncEvent {
        .init(
            serverSeq: sequence,
            deviceID: "other-device",
            entityType: type,
            entityID: id,
            op: "upsert",
            data: data,
            createdAt: "2026-10-03T00:00:00Z"
        )
    }
}

// MARK: - ExpiryRecoveryQueueRow

private struct ExpiryRecoveryQueueRow: Equatable {
    let position: Int64
    let id: String
    let version: Int
    let bytes: Data
}

// MARK: - ExpiryRecoveryEvidence

private struct ExpiryRecoveryEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [ExpiryRecoveryQueueRow]
    let baseline: [Data]
    let archive: [Data]
    let receipts: [String]
    let cursor: Int
    let pullVersion: Int
    let revision: Int64
}

private func expiryRecoveryReplacing(
    _ snapshot: BrowserTabSessionSnapshot, _ tabs: [BrowserTabSessionSnapshotTab]
) -> BrowserTabSessionSnapshot {
    .init(version: snapshot.version, spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders, tabs: tabs)
}
