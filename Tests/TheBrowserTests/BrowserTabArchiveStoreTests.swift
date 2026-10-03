import Foundation
import GRDB
import Testing

@Test(arguments: ["browser_tab_archive", "browser_sync_outbox"])
func archiveInsertAndSyncDeleteRollbackTogether(failingTable: String) throws {
    try withArchiveStore { f in
        let original = try #require(try f.store.loadSnapshotStrict())
        let before = try f.evidence()
        let entry = try f.entry(tabID: "a", archiveID: "archive-a")
        let write = BrowserSessionWrite(
            snapshot: replacingArchiveTabs(original, original.tabs.filter { $0.id != "a" }),
            origin: .local(syncMove: nil), archiveAction: .insert(entry)
        )
        try f
            .sql(
                "CREATE TRIGGER fail_archive BEFORE INSERT ON \(failingTable) BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        #expect(throws: DatabaseError.self) { try f.store.writeSessionBatch([write]) }
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        try f.sql("DROP TRIGGER fail_archive")
        try f.store.writeSessionBatch([write])
        #expect(try f.store.loadSnapshotStrict() == write.snapshot)
        #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
        #expect(try f.operations() == [.deleteTab(id: "a")])
        #expect(try f.store.syncCursor(for: f.owner) == before.cursor)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadArchivePage().entries == [entry])
        #expect(try reopened.pendingSyncQueue(for: f.owner) == f.store.pendingSyncQueue(for: f.owner))
    }
}

@Test func archiveRestoreReceiptAndFreshCreateAreAtomicAndReplayCannotRevertLaterEdits() throws {
    try withArchiveStore { f in
        let entry = try f.archive(tabID: "a", archiveID: "archive-a")
        let archived = try #require(try f.store.loadSnapshotStrict())
        let fresh = BrowserTabSessionSnapshotTab(
            id: "fresh-a", urlString: entry.tab.urlString, userTitleOverride: entry.tab.userTitleOverride,
            spaceID: "target", lastActivityTimestamp: 1_800_000_100
        )
        let restore = BrowserSessionWrite(
            snapshot: replacingArchiveTabs(archived, archived.tabs + [fresh]), origin: .local(syncMove: nil),
            archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a")
        )
        let before = try f.evidence()
        try f
            .sql(
                "CREATE TRIGGER fail_restore BEFORE UPDATE OF restored_tab_id ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        #expect(throws: DatabaseError.self) { try f.store.writeSessionBatch([restore]) }
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
        try f.sql("DROP TRIGGER fail_restore")
        try f.store.writeSessionBatch([restore])
        #expect(try f.store.loadArchiveEntry(id: entry.id) == nil)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        let queue = try f.store.pendingSyncQueue(for: f.owner)
        #expect(queue.count == 2 && queue.allSatisfy { $0.protocolVersion == 4 })
        let lastMutation = try #require(queue.last)
        guard case .folders(let mutation) = lastMutation else {
            Issue.record("Restore must use a v4 mutation")
            return
        }
        let operation = try #require(mutation.operations.first)
        guard case .createTab(let id, let data, _, _) = operation else {
            Issue.record("Restore must create one fresh v4 tab")
            return
        }
        #expect(mutation.operations.count == 1 && id == "fresh-a")
        #expect(data.base.urlString == entry.tab.urlString && data.base.spaceID == "target")
        #expect(data.base.userTitleOverride == entry.tab.userTitleOverride)

        // A delayed receipt/retried batch must not reinstall its old snapshot.
        let edited = replacingArchiveTabs(restore.snapshot, restore.snapshot.tabs.map {
            $0.id == "b" ? .init(id: "b", urlString: "https://example.com/later", spaceID: "source") : $0
        })
        try f.store.writeSessionBatch([.init(snapshot: edited, origin: .local(syncMove: nil))])
        let later = try f.evidence()
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        try reopened.writeSessionBatch([restore])
        #expect(try f.evidence() == later)
        try reopened.writeSessionBatch([.init(
            snapshot: archived, origin: .local(syncMove: nil), archiveAction: .insert(entry)
        )])
        #expect(try f.evidence() == later)
        #expect(try reopened.loadArchivePage().entries.isEmpty)
        let conflicting = BrowserSessionWrite(
            snapshot: replacingArchiveTabs(archived, archived.tabs + [
                .init(id: "another-fresh", urlString: entry.tab.urlString, spaceID: "target"),
            ]), origin: .local(syncMove: nil), archiveAction: .restore(archiveID: entry.id, tabID: "another-fresh")
        )
        #expect(throws: BrowserTabArchiveError.archiveAlreadyRestored) {
            try reopened.writeSessionBatch([conflicting])
        }
        #expect(try f.evidence() == later)
    }
}

@Test func archiveRejectsStaleInsertAndOldOrTombstonedRestoreIdentities() throws {
    try withArchiveStore { f in
        let stale = try f.entry(tabID: "a", archiveID: "stale")
        let original = try #require(try f.store.loadSnapshotStrict())
        let changed = replacingArchiveTabs(original, original.tabs.map {
            $0.id == "a" ? .init(id: "a", urlString: "https://example.com/newer", spaceID: "source") : $0
        })
        try f.store.writeSessionBatch([.init(snapshot: changed, origin: .local(syncMove: nil))])
        let before = try f.evidence()
        #expect(throws: BrowserTabArchiveError.invalidTransition) {
            try f.store.writeSessionBatch([.init(
                snapshot: replacingArchiveTabs(changed, changed.tabs.filter { $0.id != "a" }),
                origin: .local(syncMove: nil), archiveAction: .insert(stale)
            )])
        }
        #expect(try f.evidence() == before)
        let entry = try f.archive(tabID: "a", archiveID: "archive-a")
        var snapshot = try #require(try f.store.loadSnapshotStrict())
        // A different previously deleted identity is also permanently unavailable.
        snapshot = replacingArchiveTabs(snapshot, snapshot.tabs.filter { $0.id != "b" })
        try f.store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        let deleted = try f.evidence()
        for invalidID in ["a", "b"] {
            #expect(throws: BrowserTabArchiveError.restoredTabIDNotFresh) {
                try f.store.writeSessionBatch([.init(
                    snapshot: replacingArchiveTabs(snapshot, snapshot.tabs + [
                        .init(id: invalidID, urlString: entry.tab.urlString, spaceID: "target"),
                    ]), origin: .local(syncMove: nil),
                    archiveAction: .restore(archiveID: entry.id, tabID: invalidID)
                )])
            }
        }
        #expect(try f.evidence() == deleted)
        #expect(try f.store.loadArchivePage().entries == [entry])
    }
}

@Test func archiveKeysetPagesRemainStableAcrossNewInsertAndConsumedEntry() throws {
    try withArchiveStore { f in
        let consumed = try f.archive(tabID: "a", archiveID: "c", archivedAt: 20)
        _ = try f.archive(tabID: "b", archiveID: "b", archivedAt: 20)
        _ = try f.archive(tabID: "c", archiveID: "a", archivedAt: 10)
        let page = try f.store.loadArchivePage(before: nil, limit: 2)
        #expect(page.entries.map(\.id) == ["c", "b"])
        let cursor = try #require(page.nextCursor)
        _ = try f.archive(tabID: "d", archiveID: "new", archivedAt: 30)
        let current = try #require(try f.store.loadSnapshotStrict())
        try f.store.writeSessionBatch([.init(
            snapshot: replacingArchiveTabs(current, current.tabs + [
                .init(
                    id: "restored",
                    urlString: consumed.tab.urlString,
                    userTitleOverride: consumed.tab.userTitleOverride,
                    spaceID: "source"
                ),
            ]), origin: .local(syncMove: nil), archiveAction: .restore(archiveID: "c", tabID: "restored")
        )])
        let older = try f.store.loadArchivePage(before: cursor, limit: 2)
        #expect(older.entries.map(\.id) == ["a"] && older.nextCursor == nil)
        #expect(try f.store.loadArchivePage().entries.map(\.id) == ["new", "b", "a"])
        #expect(throws: BrowserTabArchiveError.invalidLimit) { try f.store.loadArchivePage(before: nil, limit: 0) }
        #expect(throws: BrowserTabArchiveError.invalidCursor) {
            try f.store.loadArchivePage(before: .init(archivedAt: .nan, id: "bad"), limit: 2)
        }
    }
}

@Test func archivePayloadCountsTowardFailureBufferAndUnsupportedStoresRejectEffects() throws {
    let snapshot = BrowserTabSessionSnapshot(tabs: [])
    let entry = BrowserTabArchiveEntry(
        id: "large", tab: .init(id: "a", urlString: "https://example.com"), archivedAt: 1,
        title: String(repeating: "x", count: 4096)
    )
    let write = BrowserSessionWrite(snapshot: snapshot, origin: .local(syncMove: nil), archiveAction: .insert(entry))
    var buffer = BrowserSessionWriteBuffer(maximumCount: 32, maximumBytes: 1024)
    let accepted = buffer.append(write)
    #expect(!accepted && buffer.writes.isEmpty && buffer.failure?.reason == .bufferLimitExceeded)
    let store = BrowserEphemeralSessionStore()
    #expect(throws: BrowserTabArchiveError.unsupportedStore) { try store.writeSessionBatch([write]) }
    #expect(throws: BrowserTabArchiveError.requiresLocalWrite) {
        try BrowserSessionWrite(snapshot: snapshot, origin: .remoteProjection, archiveAction: .insert(entry)).validate()
    }
}

@Test func archiveRestoreIntoPermanentlyDeletedSpaceDoesNotConsumeEntry() throws {
    try withArchiveStore { f in
        let entry = try f.archive(tabID: "a", archiveID: "archive-a")
        let old = try #require(try f.store.loadSnapshotStrict())
        let current = BrowserTabSessionSnapshot(spaces: old.spaces?.filter { $0.id != "target" }, tabs: old.tabs)
        try f.store.writeSessionBatch([.init(snapshot: current, origin: .local(syncMove: nil))])
        let before = try f.evidence()
        let stale = replacingArchiveTabs(old, old.tabs + [
            .init(
                id: "fresh-a",
                urlString: entry.tab.urlString,
                userTitleOverride: entry.tab.userTitleOverride,
                spaceID: "target"
            ),
        ])
        #expect(throws: BrowserTabArchiveError.invalidTransition) {
            try f.store.writeSessionBatch([.init(
                snapshot: stale, origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a")
            )])
        }
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
    }
}

@Test(arguments: [true, false])
func archiveRestoreCannotConsumeEntryWithChangedRecoveryMetadata(changesURL: Bool) throws {
    try withArchiveStore { f in
        let entry = try f.archive(tabID: "a", archiveID: "archive-a")
        let archived = try #require(try f.store.loadSnapshotStrict())
        let before = try f.evidence()
        let corrupted = BrowserTabSessionSnapshotTab(
            id: "fresh-a", urlString: changesURL ? "https://wrong.example" : entry.tab.urlString,
            userTitleOverride: changesURL ? entry.tab.userTitleOverride : "Wrong saved title", spaceID: "target"
        )
        #expect(throws: BrowserTabArchiveError.invalidTransition) {
            try f.store.writeSessionBatch([.init(
                snapshot: replacingArchiveTabs(archived, archived.tabs + [corrupted]), origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a")
            )])
        }
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
    }
}

// MARK: - ArchiveStoreEvidence

private struct ArchiveStoreEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [Data]
    let baseline: [Data]
    let archive: [Data]
    let receipts: [String]
    let cursor: Int
}

// MARK: - ArchiveStoreFixture

private struct ArchiveStoreFixture {
    // MARK: Lifecycle

    init(directory: URL) throws {
        self.directory = directory
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        try store.bindSyncOwner(owner)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "source", title: "Source", systemImageName: "globe"),
                .init(id: "target", title: "Target", systemImageName: "star"),
            ],
            tabs: ["a", "b", "c", "d"].map { (id: String) -> BrowserTabSessionSnapshotTab in
                .init(
                    id: id,
                    urlString: "https://example.com/\(id)",
                    userTitleOverride: "Name \(id)",
                    spaceID: "source",
                    lastActivityTimestamp: 1_800_000_000
                )
            }
        )
        let events = try archiveStoreEvents(BrowserSyncFolderProjection.canonicalChanges(snapshot))
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
    }

    // MARK: Internal

    let directory: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://archive.example")!, userID: "archive-owner")
    let store: BrowserSQLiteSessionStore

    var databaseURL: URL { directory.appendingPathComponent("Profile.sqlite") }

    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func entry(
        tabID: String,
        archiveID: String,
        archivedAt: TimeInterval = 1_800_000_100
    ) throws -> BrowserTabArchiveEntry {
        let tab = try #require(try store.loadSnapshotStrict()?.tabs.first { $0.id == tabID })
        return .init(id: archiveID, tab: tab, archivedAt: archivedAt, title: "Loaded title \(tabID)")
    }

    @discardableResult func archive(
        tabID: String,
        archiveID: String,
        archivedAt: TimeInterval = 1_800_000_100
    ) throws -> BrowserTabArchiveEntry {
        let entry = try entry(tabID: tabID, archiveID: archiveID, archivedAt: archivedAt)
        let previous = try #require(try store.loadSnapshotStrict())
        try store.writeSessionBatch([.init(
            snapshot: replacingArchiveTabs(previous, previous.tabs.filter { $0.id != tabID }),
            origin: .local(syncMove: nil), archiveAction: .insert(entry)
        )])
        return entry
    }

    func operations() throws -> [BrowserSyncFolderOperation] {
        try store.pendingSyncQueue(for: owner).flatMap {
            guard case .folders(let mutation) = $0 else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return mutation.operations
        }
    }

    func evidence() throws -> ArchiveStoreEvidence {
        let rows = try DatabaseQueue(path: databaseURL.path).read { db in
            try (
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || COALESCE(restored_tab_id, '') FROM browser_tab_archive ORDER BY id"
                )
            )
        }
        return try .init(
            snapshot: store.loadSnapshotStrict(),
            queue: rows.0,
            baseline: rows.1,
            archive: rows.2,
            receipts: rows.3,
            cursor: store.syncCursor(for: owner)
        )
    }
}

private func replacingArchiveTabs(
    _ snapshot: BrowserTabSessionSnapshot,
    _ tabs: [BrowserTabSessionSnapshotTab]
) -> BrowserTabSessionSnapshot {
    .init(version: snapshot.version, spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders, tabs: tabs)
}

private func archiveStoreEvents(_ changes: [BrowserSyncChange]) throws -> [BrowserSyncEvent] {
    try changes.enumerated().map { offset, change in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
        var payload = object["data"] as? [String: Any] ?? [:]
        payload["id"] = change.entityID
        let wire: [String: Any] = [
            "serverSeq": offset + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
            "entityID": change.entityID, "op": change.op.rawValue, "data": payload, "createdAt": "2026-10-03T00:00:00Z",
        ]
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
    }
}

private func withArchiveStore(_ body: (ArchiveStoreFixture) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveStore-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try runArchiveStore(directory: directory, body)
}

private func runArchiveStore(directory: URL, _ body: (ArchiveStoreFixture) throws -> Void) throws {
    try body(ArchiveStoreFixture(directory: directory))
}
