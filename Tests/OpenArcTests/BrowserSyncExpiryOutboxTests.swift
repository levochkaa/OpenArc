import Foundation
import GRDB
import Testing

@Test(arguments: [false, true])
func expiryOutboxMigrationPreservesEveryLegacyByteAndConsumedFIFOHighWater(emptyQueue: Bool) throws {
    try withExpiryOutbox { fixture in
        let store = try fixture.readyStore()
        try store.pauseSync()
        let old: [BrowserSyncQueuedMutation] = emptyQueue
            ? []
            : [
                .legacy(.init(id: UUID().uuidString, changes: [
                    .init(
                        entityType: .space,
                        entityID: "work",
                        op: .upsert,
                        spaceData: .init(
                            title: "work",
                            systemImageName: "globe",
                            rank: 0,
                            isPinnedSectionCollapsed: false,
                            selectedTabID: nil
                        ),
                        tabData: nil
                    ),
                ])),
                .semantic(.init(
                    id: UUID().uuidString,
                    operations: [.patchSpace(id: "work", fields: .init(title: "work"))]
                )),
                .folders(.init(id: UUID().uuidString, operations: [.patchTab(
                    id: "expired", fields: .init(urlString: ExpiryOutboxFixture.canonicalURL)
                )])),
            ]
        try fixture.database { db in
            for (index, mutation) in old.enumerated() {
                let payload: Data
                switch mutation {
                case .legacy(let value): payload = try fixture.prettyEncoder.encode(value)
                case .semantic(let value): payload = try fixture.prettyEncoder.encode(value)
                case .folders(let value): payload = try fixture.prettyEncoder.encode(value)
                case .expiry: throw ExpiryOutboxFixtureError.unexpectedMutation
                }
                try db.execute(
                    sql: "INSERT INTO browser_sync_outbox(position, mutation_id, payload, protocol_version) VALUES (?, ?, ?, ?)",
                    arguments: [10 + index * 20, mutation.id, payload, mutation.protocolVersion]
                )
            }
            try db.execute(sql: """
            CREATE TABLE pre_expiry_outbox (
                position INTEGER PRIMARY KEY AUTOINCREMENT, mutation_id TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL, protocol_version INTEGER NOT NULL DEFAULT 2 CHECK(protocol_version IN (2,3,4))
            );
            INSERT INTO pre_expiry_outbox SELECT position,mutation_id,payload,protocol_version FROM browser_sync_outbox;
            DROP TABLE browser_sync_outbox;
            ALTER TABLE pre_expiry_outbox RENAME TO browser_sync_outbox;
            DELETE FROM sqlite_sequence WHERE name = 'browser_sync_outbox';
            INSERT INTO sqlite_sequence(name,seq) VALUES('browser_sync_outbox',900);
            DELETE FROM grdb_migrations WHERE identifier = 'addExpirySyncOutbox';
            """)
        }
        let before = try fixture.evidence(store)
        let migrated = try fixture.open()
        #expect(try fixture.evidence(migrated) == before)
        #expect(try migrated.pendingSyncQueue(for: fixture.owner) == old)
        #expect(try migrated.isSyncPaused(for: fixture.owner))
        let expiry = fixture.mutation()
        try migrated.enqueueSyncExpiry(expiry, for: fixture.owner)
        let after = try fixture.rows()
        #expect(Array(after.prefix(old.count)) == before.rows)
        #expect(after.last?.position == 901 && after.last?.version == 5)
        #expect(try migrated.pendingSyncQueue(for: fixture.owner) == old + [.expiry(expiry)])
        #expect(try migrated.loadSnapshotStrict() == before.snapshot)
        #expect(try fixture.baseline() == before.baseline)
        #expect(try migrated.syncCursor(for: fixture.owner) == before.cursor)
        #expect(try fixture.ordinaryVersion() == 4)
        #expect(try fixture.open().pendingSyncQueue(for: fixture.owner) == old + [.expiry(expiry)])
    }
}

@Test func expiryEnqueueRequiresRecoveryBootstrapAndRejectsInvalidOrCollidingRequestsWithoutWrites() throws {
    try withExpiryOutbox { fixture in
        let store = try fixture.open()
        let request = fixture.mutation()
        #expect(throws: BrowserSyncStoreError.ownerNotBound) {
            try store.enqueueSyncExpiry(request, for: fixture.owner)
        }
        try store.bindSyncOwner(fixture.owner)
        _ = try store.completeFolderSyncBootstrap(events: fixture.seed, cursor: 3, for: fixture.owner)
        #expect(throws: BrowserSyncQueueError.expiryBootstrapRequired) {
            try store.enqueueSyncExpiry(request, for: fixture.owner)
        }
        _ = try store.completeExpirySyncBootstrap(events: fixture.seed, cursor: 3, for: fixture.owner)
        let before = try fixture.evidence(store)
        let foreign = BrowserSyncOwner(baseURL: fixture.owner.baseURL, userID: "foreign")
        #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.enqueueSyncExpiry(request, for: foreign) }
        #expect(throws: BrowserSyncQueueError.invalidMutationIdentity) {
            try store.enqueueSyncExpiry(.init(id: "not-a-uuid", operations: request.operations), for: fixture.owner)
        }
        #expect(throws: BrowserSyncExpiryError.invalidOperation) {
            try store.enqueueSyncExpiry(.init(id: UUID().uuidString, operations: []), for: fixture.owner)
        }
        #expect(throws: BrowserSyncQueueError.mutationTooLarge) {
            try store.enqueueSyncExpiry(.init(id: UUID().uuidString, operations: [
                .init(
                    id: String(repeating: "x", count: 8 * 1024 * 1024),
                    expectedServerSeq: 2,
                    inactiveForSeconds: 43200
                ),
            ]), for: fixture.owner)
        }
        let escaped = BrowserSyncExpiryMutation(id: UUID().uuidString, operations: [
            .init(id: String(repeating: "/", count: 4 * 1024 * 1024), expectedServerSeq: 2, inactiveForSeconds: 43200),
        ])
        let storedBytes = try fixture.prettyEncoder.encode(escaped)
        let wireBytes = try JSONEncoder().encode(BrowserSyncExpiryPushRequest(
            mutationID: escaped.id,
            deviceID: "00000000-0000-4000-8000-000000000000",
            operations: escaped.operations
        ))
        #expect(storedBytes.count < 8 * 1024 * 1024 && wireBytes.count > 8 * 1024 * 1024)
        #expect(throws: BrowserSyncQueueError.mutationTooLarge) {
            try store.enqueueSyncExpiry(escaped, for: fixture.owner)
        }
        #expect(try fixture.evidence(store) == before)
        try fixture.database { db in
            try db.execute(sql: "UPDATE browser_sync_state SET new_mutation_version=3 WHERE id=1")
        }
        #expect(throws: BrowserSyncQueueError.expiryBootstrapRequired) {
            try store.enqueueSyncExpiry(request, for: fixture.owner)
        }
        try fixture.database { db in
            try db.execute(sql: "UPDATE browser_sync_state SET new_mutation_version=4 WHERE id=1")
            try db
                .execute(
                    sql: "CREATE TRIGGER fail_expiry_enqueue BEFORE INSERT ON browser_sync_outbox BEGIN SELECT RAISE(ABORT,'injected'); END"
                )
        }
        #expect(throws: DatabaseError.self) { try store.enqueueSyncExpiry(request, for: fixture.owner) }
        #expect(try fixture.evidence(store) == before)
        try fixture.database { try $0.execute(sql: "DROP TRIGGER fail_expiry_enqueue") }

        try store.enqueueSyncExpiry(request, for: fixture.owner)
        try fixture.database { db in
            try db.execute(
                sql: "UPDATE browser_sync_outbox SET payload=? WHERE mutation_id=?",
                arguments: [fixture.prettyEncoder.encode(request), request.id]
            )
        }
        let frozen = try fixture.evidence(store)
        try store.enqueueSyncExpiry(request, for: fixture.owner)
        #expect(try fixture.evidence(store) == frozen, "A same-payload retry cannot replace noncanonical JSON bytes")
        #expect(throws: BrowserSyncQueueError.mutationIdentityConflict) {
            try store.enqueueSyncExpiry(fixture.mutation(id: request.id, sequence: 99), for: fixture.owner)
        }
        #expect(try fixture.evidence(store) == frozen)
        try fixture.edit(store, id: "survivor", url: "https://example.com/ordinary")
        let ordinary = try #require(try store.pendingSyncQueue(for: fixture.owner).last)
        #expect(ordinary.protocolVersion == 4)
        let beforeCollision = try fixture.evidence(store)
        #expect(throws: BrowserSyncQueueError.mutationIdentityConflict) {
            try store.enqueueSyncExpiry(fixture.mutation(id: ordinary.id), for: fixture.owner)
        }
        #expect(try fixture.evidence(store) == beforeCollision)
    }
}

@Test(arguments: [false, true])
func expiryPendingOverlayIsInertAndTerminalRejectionKeepsInterveningLocalChanges(noCanonicalEvent: Bool) throws {
    try withExpiryOutbox { fixture in
        let store = try fixture.readyStore()
        let original = try fixture.evidence(store)
        let expiry = fixture.mutation()
        try store.enqueueSyncExpiry(expiry, for: fixture.owner)
        #expect(try store.loadSnapshotStrict() == original.snapshot)
        #expect(try fixture.baseline() == original.baseline)
        #expect(try store.syncCursor(for: fixture.owner) == original.cursor)
        #expect(try store.loadArchivePage().entries.isEmpty)

        try fixture.edit(store, id: "expired", url: ExpiryOutboxFixture.offlineURL)
        let edited = try #require(try store.loadSnapshotStrict())
        let queue = try store.pendingSyncQueue(for: fixture.owner)
        #expect(queue.map(\.protocolVersion) == [5, 4])
        let frozen = try fixture.rows()
        let remote = fixture.tabEvent(id: "expired", sequence: 5, url: "https://example.com/new-canonical")
        let rebased = try store.completeExpirySyncBootstrap(
            events: fixture.seed + [remote],
            cursor: 5,
            for: fixture.owner
        )
        #expect(rebased.tabs.first { $0.id == "expired" }?.urlString == ExpiryOutboxFixture.offlineURL)
        #expect(try fixture.rows() == frozen, "Device rebootstrap accepts immutable v4 and v5 rows together")
        #expect(try fixture.ordinaryVersion() == 4)

        // Empty canonical events represent a terminal response_limit rejection.
        // A normal rejection may return the latest canonical tab instead.
        let after = try store.acknowledgeSyncMutation(
            id: expiry.id, protocolVersion: 5, events: noCanonicalEvent ? [] : [remote], for: fixture.owner
        )
        #expect(after.tabs == edited.tabs)
        #expect(try store.pendingSyncQueue(for: fixture.owner) == [queue[1]])
        #expect(try fixture.rows() == [frozen[1]])
        #expect(try store.syncCursor(for: fixture.owner) == 5)
        #expect(try store.loadArchivePage().entries.isEmpty)
        let baseline = try fixture.decodedBaseline()
        #expect(!baseline.deletedKeys.contains("tab:expired"))
        #expect(baseline.entities["tab:expired"]?.change.op == .upsert)
        #expect(try fixture.open().loadSnapshotStrict() == after)
    }
}

@Test func acceptedExpiryACKAtomicallyRecoversInterveningContentAndOnlyConsumesItsOwnIntent() throws {
    try withExpiryOutbox { fixture in
        let store = try fixture.readyStore()
        let expiry = fixture.mutation()
        try store.enqueueSyncExpiry(expiry, for: fixture.owner)
        try fixture.edit(store, id: "expired", url: ExpiryOutboxFixture.offlineURL)
        let pending = try store.pendingSyncQueue(for: fixture.owner)
        let before = try fixture.evidence(store)
        try fixture.database { db in
            try db
                .execute(
                    sql: "CREATE TRIGGER fail_expiry_ack BEFORE INSERT ON browser_tab_archive BEGIN SELECT RAISE(ABORT,'injected'); END"
                )
        }
        #expect(throws: DatabaseError.self) {
            try store.acknowledgeSyncMutation(
                id: expiry.id,
                protocolVersion: 5,
                events: [fixture.recovery],
                for: fixture.owner
            )
        }
        #expect(try fixture.evidence(store) == before)
        try fixture.database { try $0.execute(sql: "DROP TRIGGER fail_expiry_ack") }
        let projected = try store.acknowledgeSyncMutation(
            id: expiry.id, protocolVersion: 5, events: [fixture.recovery], for: fixture.owner
        )
        #expect(projected.tabs.compactMap(\.id) == ["survivor"])
        #expect(try store.pendingSyncQueue(for: fixture.owner) == [pending[1]])
        #expect(try fixture.rows() == [before.rows[1]])
        #expect(try store.syncCursor(for: fixture.owner) == before.cursor, "Expiry ACK never advances the pull cursor")
        let entries = try store.loadArchivePage().entries
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.tab.urlString)) == [ExpiryOutboxFixture.canonicalURL, ExpiryOutboxFixture.offlineURL])
        #expect(try store.syncArchiveRevision(for: fixture.owner) == 1)
        let baseline = try fixture.decodedBaseline()
        #expect(baseline.deletedKeys.contains("tab:expired"))
        #expect(baseline.entities["tab:expired"]?.serverSeq == 10)

        let reopened = try fixture.open()
        _ = try reopened.acknowledgeSyncMutation(
            id: expiry.id, protocolVersion: 5, events: [fixture.recovery], for: fixture.owner
        )
        _ = try reopened.acknowledgeSyncMutation(
            id: pending[1].id, protocolVersion: 4, events: [fixture.seed[1]], for: fixture.owner
        )
        #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
        #expect(try reopened.loadSnapshotStrict() == projected)
        #expect(try reopened.loadArchivePage().entries == entries)
        #expect(try reopened.syncArchiveRevision(for: fixture.owner) == 1)
    }
}

private func withExpiryOutbox(_ body: (ExpiryOutboxFixture) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExpiryOutbox-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(ExpiryOutboxFixture(directory: directory))
}

// MARK: - ExpiryOutboxFixture

private struct ExpiryOutboxFixture {
    static let canonicalURL = "https://example.com/canonical"
    static let offlineURL = "https://example.com/offline"

    let directory: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://expiry-outbox.example")!, userID: "owner")

    var databaseURL: URL { directory.appendingPathComponent("Profile.sqlite") }
    var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    var seed: [BrowserSyncEvent] {
        [
            .init(
                serverSeq: 1,
                deviceID: "remote",
                entityType: "space",
                entityID: "work",
                op: "upsert",
                data: .space(.init(
                    id: "work",
                    title: "work",
                    systemImageName: "globe",
                    rank: 0,
                    isPinnedSectionCollapsed: false,
                    selectedTabID: nil
                )),
                createdAt: "2026-10-03T00:00:00Z"
            ),
            tabEvent(id: "expired", sequence: 2, url: Self.canonicalURL),
            tabEvent(id: "survivor", sequence: 3, url: "https://example.com/survivor"),
        ]
    }

    var recovery: BrowserSyncEvent {
        .init(
            serverSeq: 10,
            deviceID: "remote",
            entityType: "tab",
            entityID: "expired",
            op: "delete",
            data: .deleted(id: "expired", autoArchive: .init(
                archivedAt: "2026-10-03T00:00:00.123456Z", sourceServerSeq: 2,
                tab: tabData(id: "expired", url: Self.canonicalURL)
            )),
            createdAt: "2026-10-03T00:00:00Z"
        )
    }

    func open() throws -> BrowserSQLiteSessionStore { try BrowserSQLiteSessionStore(databaseURL: databaseURL) }
    func readyStore() throws -> BrowserSQLiteSessionStore {
        let store = try open()
        try store.bindSyncOwner(owner)
        _ = try store.completeExpirySyncBootstrap(events: seed, cursor: 3, for: owner)
        return store
    }

    func mutation(id: String = UUID().uuidString, sequence: Int = 2) -> BrowserSyncExpiryMutation {
        .init(id: id, operations: [.init(id: "expired", expectedServerSeq: sequence, inactiveForSeconds: 43200)])
    }

    func tabData(id: String, url: String) -> BrowserSyncEventTabData {
        .init(
            id: id,
            spaceID: "work",
            placement: .temporary,
            rank: id == "expired" ? 0 : 1,
            urlString: url,
            pinnedURLString: nil,
            title: "Loaded \(id)",
            userTitleOverride: nil,
            faviconURLString: nil,
            lastActivityAt: "2000-01-01T00:00:00.123456Z",
            pinnedFolderID: nil
        )
    }

    func tabEvent(id: String, sequence: Int, url: String) -> BrowserSyncEvent {
        .init(
            serverSeq: sequence,
            deviceID: "remote",
            entityType: "tab",
            entityID: id,
            op: "upsert",
            data: .tab(tabData(id: id, url: url)),
            createdAt: "2026-10-03T00:00:00Z"
        )
    }

    func edit(_ store: BrowserSQLiteSessionStore, id: String, url: String) throws {
        let old = try #require(try store.loadSnapshotStrict())
        let next = BrowserTabSessionSnapshot(
            spaces: old.spaces,
            pinnedTabFolders: old.pinnedTabFolders,
            tabs: old.tabs.map { tab in
                .init(
                    id: tab.id,
                    urlString: tab.id == id ? url : tab.urlString,
                    pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride,
                    placement: tab.placement,
                    spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID,
                    lastActivityTimestamp: tab.lastActivityTimestamp,
                    pinnedSiblingRank: tab.pinnedSiblingRank
                )
            }
        )
        try store.writeSessionBatch([.init(snapshot: next, origin: .local(syncMove: nil))])
    }

    func database<T>(_ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: databaseURL.path).write(body)
    }

    func rows() throws -> [ExpiryOutboxRow] {
        try database { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position,mutation_id,protocol_version,payload FROM browser_sync_outbox ORDER BY position"
            )
            .map {
                .init(
                    position: $0["position"],
                    id: $0["mutation_id"],
                    version: $0["protocol_version"],
                    payload: $0["payload"]
                )
            }
        }
    }

    func baseline() throws -> Data {
        let value = try database { try Data.fetchOne($0, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1") }
        return try #require(value)
    }

    func decodedBaseline() throws -> BrowserSyncOutboxBaseline {
        try JSONDecoder().decode(BrowserSyncOutboxBaseline.self, from: baseline())
    }

    func ordinaryVersion() throws -> Int {
        let value = try database { try Int.fetchOne(
            $0,
            sql: "SELECT new_mutation_version FROM browser_sync_state WHERE id=1"
        ) }
        return try #require(value)
    }

    func evidence(_ store: BrowserSQLiteSessionStore) throws -> ExpiryOutboxEvidence {
        let highWater = try database { try Int64.fetchOne(
            $0,
            sql: "SELECT seq FROM sqlite_sequence WHERE name='browser_sync_outbox'"
        ) }
        return try .init(
            snapshot: store.loadSnapshotStrict(),
            baseline: baseline(),
            rows: rows(),
            highWater: highWater,
            cursor: store.syncCursor(for: owner),
            pullVersion: store.syncPullProtocolVersion(for: owner),
            ordinaryVersion: ordinaryVersion(),
            archive: store.loadArchivePage(),
            archiveRevision: store.syncArchiveRevision(for: owner)
        )
    }
}

// MARK: - ExpiryOutboxRow

private struct ExpiryOutboxRow: Equatable {
    let position: Int64
    let id: String
    let version: Int
    let payload: Data
}

// MARK: - ExpiryOutboxEvidence

private struct ExpiryOutboxEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let baseline: Data
    let rows: [ExpiryOutboxRow]
    let highWater: Int64?
    let cursor: Int
    let pullVersion: Int
    let ordinaryVersion: Int
    let archive: BrowserTabArchivePage
    let archiveRevision: Int64
}

// MARK: - ExpiryOutboxFixtureError

private enum ExpiryOutboxFixtureError: Error { case unexpectedMutation }
