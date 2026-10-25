// BrowserTabArchiveStoreTests.swift

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
            origin: .local(syncMove: nil), archiveAction: .insert(entry),
        )
        try f
            .sql(
                "CREATE TRIGGER fail_archive BEFORE INSERT ON \(failingTable) BEGIN SELECT RAISE(ABORT, 'injected'); END",
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
            spaceID: "target", lastActivityTimestamp: 1_800_000_100,
        )
        let restore = BrowserSessionWrite(
            snapshot: replacingArchiveTabs(archived, archived.tabs + [fresh]), origin: .local(syncMove: nil),
            archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a"),
        )
        let before = try f.evidence()
        try f
            .sql(
                "CREATE TRIGGER fail_restore BEFORE UPDATE OF restored_tab_id ON browser_tab_archive_receipts BEGIN SELECT RAISE(ABORT, 'injected'); END",
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
            snapshot: archived, origin: .local(syncMove: nil), archiveAction: .insert(entry),
        )])
        #expect(try f.evidence() == later)
        #expect(try reopened.loadArchivePage().entries.isEmpty)
        let conflicting = BrowserSessionWrite(
            snapshot: replacingArchiveTabs(archived, archived.tabs + [
                .init(id: "another-fresh", urlString: entry.tab.urlString, spaceID: "target"),
            ]), origin: .local(syncMove: nil), archiveAction: .restore(archiveID: entry.id, tabID: "another-fresh"),
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
                origin: .local(syncMove: nil), archiveAction: .insert(stale),
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
                    archiveAction: .restore(archiveID: entry.id, tabID: invalidID),
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
                    spaceID: "source",
                ),
            ]), origin: .local(syncMove: nil), archiveAction: .restore(archiveID: "c", tabID: "restored"),
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
        title: String(repeating: "x", count: 4096),
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
                spaceID: "target",
            ),
        ])
        #expect(throws: BrowserTabArchiveError.invalidTransition) {
            try f.store.writeSessionBatch([.init(
                snapshot: stale, origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a"),
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
            userTitleOverride: changesURL ? entry.tab.userTitleOverride : "Wrong saved title", spaceID: "target",
        )
        #expect(throws: BrowserTabArchiveError.invalidTransition) {
            try f.store.writeSessionBatch([.init(
                snapshot: replacingArchiveTabs(archived, archived.tabs + [corrupted]), origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a"),
            )])
        }
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
    }
}

@Test func archiveSearchMatchesUnicodeAndLiteralPunctuationAcrossIndependentFieldsWithPaging() async throws {
    try await withAsyncArchiveStore { f in
        let original = try #require(try f.store.loadSnapshotStrict())
        let tabs: [BrowserTabSessionSnapshotTab] = [
            .init(
                id: "a",
                urlString: "https://example.com/CafÉ?discount=100%_literal",
                userTitleOverride: "СОХРАНЁННОЕ Café",
                spaceID: "source",
            ),
            .init(id: "b", urlString: "https://example.com/plain", userTitleOverride: "Other", spaceID: "source"),
            .init(id: "c", urlString: "https://example.com/100Xliteral", spaceID: "source"),
            .init(id: "d", urlString: "https://example.com/other", userTitleOverride: "CAFÉ final", spaceID: "source"),
        ]
        try f.store.writeSessionBatch([.init(
            snapshot: replacingArchiveTabs(original, tabs),
            origin: .local(syncMove: nil),
        )])
        for (id, title) in [("a", "First loaded"), ("b", "Résumé Loaded"), ("c", "Café sibling"), ("d", "Unrelated")] {
            let current = try #require(try f.store.loadSnapshotStrict())
            let tab = try #require(current.tabs.first { $0.id == id })
            let entry = BrowserTabArchiveEntry(id: "archive-" + id, tab: tab, archivedAt: 100, title: title)
            try f.store.writeSessionBatch([.init(
                snapshot: replacingArchiveTabs(current, current.tabs.filter { $0.id != id }),
                origin: .local(syncMove: nil), archiveAction: .insert(entry),
            )])
        }
        let before = try f.evidence()
        for (query, ids) in [
            ("cafe", ["archive-d", "archive-c", "archive-a"]),
            ("RESUME", ["archive-b"]), ("сохраненное", ["archive-a"]),
            ("DISCOUNT", ["archive-a"]), ("%_", ["archive-a"]), ("_", ["archive-a"]),
            ("literal First", []), ("missing", []),
        ] {
            let page = try await f.store.searchArchivePage(query: query, before: nil, limit: 50)
            #expect(page.entries.map(\.id) == ids, "Query: \(query)")
        }
        let first = try await f.store.searchArchivePage(query: "CAFE", before: nil, limit: 2)
        #expect(first.entries.map(\.id) == ["archive-d", "archive-c"])
        let cursor = try #require(first.nextCursor)
        let second = try await f.store.searchArchivePage(query: "café", before: cursor, limit: 2)
        #expect(second.entries.map(\.id) == ["archive-a"] && second.nextCursor == nil)
        await #expect(throws: BrowserTabArchiveError.invalidQuery) {
            try await f.store.searchArchivePage(query: String(repeating: "a", count: 257), before: nil, limit: 2)
        }
        let oversizedSingleGraphemes = String(repeating: "a" + String(repeating: "\u{0301}", count: 20), count: 256)
        #expect(oversizedSingleGraphemes.count == 256 && oversizedSingleGraphemes.utf8.count > 4096)
        await #expect(throws: BrowserTabArchiveError.invalidQuery) {
            try await f.store.searchArchivePage(query: oversizedSingleGraphemes, before: nil, limit: 2)
        }
        #expect(try f.evidence() == before)
    }
}

@Test(arguments: [false, true])
func archiveRemovalKeepsCompactReceiptsSoExactActionReplayCannotRestoreOldSnapshots(clear: Bool) async throws {
    try await withAsyncArchiveStore { f in
        let entry = try f.archive(tabID: "a", archiveID: "removed")
        let afterArchive = try #require(try f.store.loadSnapshotStrict())
        let consumed = try f.archive(tabID: "b", archiveID: "consumed")
        let afterSecond = try #require(try f.store.loadSnapshotStrict())
        let restored = BrowserTabSessionSnapshotTab(
            id: "fresh-b",
            urlString: consumed.tab.urlString,
            userTitleOverride: consumed.tab.userTitleOverride,
            spaceID: "target",
        )
        let restoreWrite = BrowserSessionWrite(
            snapshot: replacingArchiveTabs(afterSecond, afterSecond.tabs + [restored]), origin: .local(syncMove: nil),
            archiveAction: .restore(archiveID: consumed.id, tabID: "fresh-b"),
        )
        try f.store.writeSessionBatch([restoreWrite])
        let newer = replacingArchiveTabs(restoreWrite.snapshot, restoreWrite.snapshot.tabs.map {
            $0.id == "c" ? .init(id: "c", urlString: "https://later.example", spaceID: "source") : $0
        })
        try f.store.writeSessionBatch([.init(snapshot: newer, origin: .local(syncMove: nil))])
        if clear {
            let boundary = try await f.store.archiveClearBoundary()
            let removed = try await f.store.clearArchive(through: boundary)
            #expect(removed == 1)
        } else {
            let removed = try await f.store.removeArchiveEntry(id: entry.id)
            #expect(removed)
        }
        let afterRemoval = try f.evidence()
        #expect(afterRemoval.archive.isEmpty && afterRemoval.receipts.count == 2)
        try f.store.writeSessionBatch([
            .init(snapshot: afterArchive, origin: .local(syncMove: nil), archiveAction: .insert(entry)),
            .init(snapshot: afterSecond, origin: .local(syncMove: nil), archiveAction: .insert(consumed)),
            restoreWrite,
        ])
        #expect(try f.evidence() == afterRemoval)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadArchiveEntry(id: entry.id) == nil)
        #expect(try reopened.loadSnapshotStrict() == newer)
        #expect(throws: BrowserTabArchiveError.entryMissing) {
            try reopened.writeSessionBatch([.init(
                snapshot: replacingArchiveTabs(newer, newer.tabs + [
                    .init(
                        id: "fresh-a",
                        urlString: entry.tab.urlString,
                        userTitleOverride: entry.tab.userTitleOverride,
                        spaceID: "source",
                    ),
                ]), origin: .local(syncMove: nil), archiveAction: .restore(archiveID: entry.id, tabID: "fresh-a"),
            )])
        }
        #expect(try f.evidence() == afterRemoval)
    }
}

@Test(arguments: [false, true])
func archiveDeleteOrCapturedClearRollsBackAndNeverTouchesSyncState(clear: Bool) async throws {
    try await withAsyncArchiveStore { f in
        let first = try f.archive(tabID: "a", archiveID: "first", archivedAt: 100)
        _ = try f.archive(tabID: "b", archiveID: "second", archivedAt: 200)
        let boundary = try await f.store.archiveClearBoundary()
        let later = try f.archive(tabID: "c", archiveID: "later-backdated", archivedAt: -100)
        let before = try f.evidence()
        try f
            .sql(
                "CREATE TRIGGER fail_archive_remove BEFORE DELETE ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected'); END",
            )
        if clear {
            await #expect(throws: DatabaseError.self) { try await f.store.clearArchive(through: boundary) }
        } else {
            await #expect(throws: DatabaseError.self) { try await f.store.removeArchiveEntry(id: first.id) }
        }
        #expect(try f.evidence() == before)
        try f.sql("DROP TRIGGER fail_archive_remove")
        if clear {
            let count = try await f.store.clearArchive(through: boundary)
            #expect(count == 2)
            let repeated = try await f.store.clearArchive(through: boundary)
            #expect(repeated == 0)
            #expect(try f.store.loadArchivePage().entries == [later])
        } else {
            let removed = try await f.store.removeArchiveEntry(id: first.id)
            #expect(removed)
            let repeated = try await f.store.removeArchiveEntry(id: first.id)
            #expect(!repeated)
        }
        let after = try f.evidence()
        #expect(after.snapshot == before.snapshot && after.queue == before.queue && after.baseline == before.baseline)
        #expect(after.receipts == before.receipts && after.cursor == before.cursor)
        #expect(try f.store.loadArchiveEntry(id: later.id) == later)
        let highWater = try await f.store.archiveClearBoundary()
        #expect(highWater.insertionSequence > boundary.insertionSequence)
        _ = try await f.store.clearArchive(through: highWater)
        let emptyBoundary = try await f.store.archiveClearBoundary()
        #expect(emptyBoundary == highWater)
        let newest = try f.archive(tabID: "d", archiveID: "after-empty-clear", archivedAt: -200)
        let oldClear = try await f.store.clearArchive(through: highWater)
        #expect(try oldClear == 0 && f.store.loadArchiveEntry(id: newest.id) == newest)
    }
}

@Test func archiveMigrationSeparatesActiveContentAndConsumedReceiptsWithoutChangingSyncState() async throws {
    try await withAsyncArchiveStore { f in
        let active = try f.entry(tabID: "a", archiveID: "legacy-active")
        let consumed = try f.entry(tabID: "b", archiveID: "legacy-consumed")
        let original = try #require(try f.store.loadSnapshotStrict())
        let restoredTab = BrowserTabSessionSnapshotTab(
            id: "legacy-fresh",
            urlString: consumed.tab.urlString,
            userTitleOverride: consumed.tab.userTitleOverride,
            spaceID: "target",
        )
        let durable = replacingArchiveTabs(
            original,
            original.tabs.filter { $0.id != "a" && $0.id != "b" } + [restoredTab],
        )
        try f.store.writeSessionBatch([.init(snapshot: durable, origin: .local(syncMove: nil))])
        let before = try f.evidence()
        try await DatabaseQueue(path: f.databaseURL.path).write { db in
            try db.execute(sql: """
            DROP TABLE browser_tab_archive;
            DROP TABLE browser_tab_archive_receipts;
            CREATE TABLE browser_tab_archive (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL,
                archived_at DOUBLE NOT NULL, restored_tab_id TEXT);
            CREATE INDEX browser_tab_archive_active_order ON browser_tab_archive (archived_at DESC, id DESC)
                WHERE restored_tab_id IS NULL;
            DELETE FROM grdb_migrations WHERE identifier = 'separateArchiveContentFromReceipts';
            """)
            try db.execute(
                sql: "INSERT INTO browser_tab_archive(rowid,id,payload,archived_at,restored_tab_id) VALUES (3,?,?,?,NULL)",
                arguments: [active.id, JSONEncoder().encode(active), active.archivedAt],
            )
            try db.execute(
                sql: "INSERT INTO browser_tab_archive(rowid,id,payload,archived_at,restored_tab_id) VALUES (9,?,?,?,'legacy-fresh')",
                arguments: [consumed.id, JSONEncoder().encode(consumed), consumed.archivedAt],
            )
        }
        let migrated = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try migrated.loadArchivePage().entries == [active])
        #expect(try migrated.loadArchiveEntry(id: consumed.id) == nil)
        let boundary = try await migrated.archiveClearBoundary()
        #expect(boundary.insertionSequence == 9)
        let rows = try await DatabaseQueue(path: f.databaseURL.path).read { db in
            try (
                String.fetchAll(
                    db,
                    sql: "SELECT name FROM pragma_table_info('browser_tab_archive_receipts') ORDER BY cid",
                ),
                Int.fetchAll(db, sql: "SELECT length(entry_digest) FROM browser_tab_archive_receipts ORDER BY id"),
                String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name = 'browser_tab_archive_legacy'"),
            )
        }
        #expect(rows.0 == ["id", "entry_digest", "restored_tab_id"] && rows.1 == [32, 32] && rows.2.isEmpty)
        let after = try f.evidence()
        #expect(after.snapshot == before.snapshot && after.queue == before.queue && after.baseline == before.baseline)
        #expect(after.cursor == before.cursor && after.archive.count == 1 && after.receipts.count == 2)
        let search = try await migrated.searchArchivePage(query: "NAME A", before: nil, limit: 50)
        #expect(search.entries == [active])
        try migrated.writeSessionBatch([
            .init(snapshot: durable, origin: .local(syncMove: nil), archiveAction: .insert(consumed)),
            .init(
                snapshot: durable,
                origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: consumed.id, tabID: "legacy-fresh"),
            ),
        ])
        #expect(try f.evidence() == after)
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
    // MARK: Internal

    let directory: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://archive.example")!, userID: "archive-owner")
    let store: BrowserSQLiteSessionStore

    var databaseURL: URL { directory.appendingPathComponent("Profile.sqlite") }

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
                    lastActivityTimestamp: 1_800_000_000,
                )
            },
        )
        let events = try archiveStoreEvents(BrowserSyncFolderProjection.canonicalChanges(snapshot))
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
    }

    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func entry(
        tabID: String,
        archiveID: String,
        archivedAt: TimeInterval = 1_800_000_100,
    ) throws -> BrowserTabArchiveEntry {
        let tab = try #require(try store.loadSnapshotStrict()?.tabs.first { $0.id == tabID })
        return .init(id: archiveID, tab: tab, archivedAt: archivedAt, title: "Loaded title \(tabID)")
    }

    @discardableResult func archive(
        tabID: String,
        archiveID: String,
        archivedAt: TimeInterval = 1_800_000_100,
    ) throws -> BrowserTabArchiveEntry {
        let entry = try entry(tabID: tabID, archiveID: archiveID, archivedAt: archivedAt)
        let previous = try #require(try store.loadSnapshotStrict())
        try store.writeSessionBatch([.init(
            snapshot: replacingArchiveTabs(previous, previous.tabs.filter { $0.id != tabID }),
            origin: .local(syncMove: nil), archiveAction: .insert(entry),
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
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id, '') FROM browser_tab_archive_receipts ORDER BY id",
                ),
            )
        }
        return try .init(
            snapshot: store.loadSnapshotStrict(),
            queue: rows.0,
            baseline: rows.1,
            archive: rows.2,
            receipts: rows.3,
            cursor: store.syncCursor(for: owner),
        )
    }
}

private func replacingArchiveTabs(
    _ snapshot: BrowserTabSessionSnapshot,
    _ tabs: [BrowserTabSessionSnapshotTab],
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

private func withAsyncArchiveStore(_ body: (ArchiveStoreFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveStore-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runAsyncArchiveStore(directory: directory, body)
}

private func runAsyncArchiveStore(directory: URL, _ body: (ArchiveStoreFixture) async throws -> Void) async throws {
    try await body(ArchiveStoreFixture(directory: directory))
}
