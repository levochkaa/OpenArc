// BrowserSQLiteSessionStore.swift

import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import OSLog

// MARK: - BrowserSyncExpiryCandidateCursor

struct BrowserSyncExpiryCandidateCursor: Hashable {
    let serverSeq: Int
    let entityID: String
}

// MARK: - BrowserSQLiteSessionStore

final class BrowserSQLiteSessionStore: BrowserTabSessionSnapshotStoring, BrowserSessionPreferencesStoring,
    BrowserTabArchiveStoring, BrowserSyncOwnershipReading
{
    // MARK: Private

    private enum Key {
        static let selectedTabIndex = "browser.session.selectedTabIndex"
        static let selectedSpaceIndex = "browser.session.selectedSpaceIndex"
        static let sidebarWidth = "browser.session.sidebarWidth"
        static let temporaryTabLifetime = "browser.settings.temporaryTabLifetime"
        static let automaticTabArchivalEnabled = "browser.settings.automaticTabArchivalEnabled"
        static let localAutomaticTabArchivalOff = "browser.settings.localAutomaticTabArchivalOff"
        static let syncCursor = "browser.sync.cursor"
        static let syncRequiresSignIn = "browser.sync.requiresSignIn"
    }

    // MARK: Internal

    static let databaseFileName = "OpenArc.sqlite"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.OpenArc",
        category: "SQLiteSession",
    )

    private static let splitGroupsTable = "browser_tab_split_groups"

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createSessionTables") { db in
            try db.create(table: "browser_spaces", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("system_image_name", .text).notNull()
                table.column("is_pinned_section_collapsed", .boolean).notNull().defaults(to: false)
                table.column("selected_tab_index", .integer)
                table.column("position", .integer).notNull()
            }

            try db.create(table: "browser_tabs", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("url_string", .text).notNull()
                table.column("user_title_override", .text)
                table.column("placement", .text).notNull()
                table.column("space_id", .text)
                table.column("last_activity_timestamp", .double)
                table.column("position", .integer).notNull()
            }

            try db.create(table: "browser_preferences", ifNotExists: true) { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("addPinnedTabFolders") { db in
            try db.create(table: "browser_pinned_tab_folders", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("space_id", .text).notNull()
                table.column("title", .text).notNull()
                table.column("system_image_name", .text)
                table.column("is_expanded", .boolean).notNull().defaults(to: true)
                table.column("position", .integer).notNull()
            }

            try db.execute(sql: "ALTER TABLE browser_tabs ADD COLUMN pinned_folder_id TEXT")
        }
        migrator.registerMigration("addPinnedTabFolderParents") { db in
            try db.execute(sql: "ALTER TABLE browser_pinned_tab_folders ADD COLUMN parent_folder_id TEXT")
        }
        migrator.registerMigration("addPinnedURLString") { db in
            try db.execute(sql: "ALTER TABLE browser_tabs ADD COLUMN pinned_url_string TEXT")
        }
        migrator.registerMigration("bindProfileSyncOwner") { db in
            try db.execute(sql: """
            CREATE TABLE browser_sync_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                base_url TEXT NOT NULL,
                user_id TEXT NOT NULL,
                cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
                paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1))
            )
            """)
        }
        migrator.registerMigration("addDurableSyncOutbox") { db in
            try db.execute(sql: """
            CREATE TABLE browser_sync_baseline (
                id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE browser_sync_outbox (
                position INTEGER PRIMARY KEY AUTOINCREMENT,
                mutation_id TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL
            )
            """)
        }
        migrator.registerMigration("addVersionedSyncOutbox") { db in
            // ALTER leaves existing UUIDs, FIFO positions and immutable BLOBs untouched.
            try db
                .execute(
                    sql: "ALTER TABLE browser_sync_outbox ADD COLUMN protocol_version INTEGER NOT NULL DEFAULT 2 CHECK (protocol_version IN (2, 3))",
                )
            try db
                .execute(
                    sql: "ALTER TABLE browser_sync_state ADD COLUMN new_mutation_version INTEGER NOT NULL DEFAULT 2 CHECK (new_mutation_version IN (2, 3))",
                )
        }
        migrator.registerMigration("addFolderSyncOutbox") { db in
            try db.execute(sql: "ALTER TABLE browser_tabs ADD COLUMN pinned_sibling_rank DOUBLE")
            try db.execute(sql: "ALTER TABLE browser_pinned_tab_folders ADD COLUMN pinned_sibling_rank DOUBLE")
            // SQLite cannot widen a CHECK constraint in place. Copy immutable
            // payload BLOBs and FIFO positions directly, including deleted-row
            // sequence history, without decoding any existing mutation.
            let sequence = try Int64.fetchOne(
                db,
                sql: "SELECT seq FROM sqlite_sequence WHERE name = 'browser_sync_outbox'",
            )
            try db.execute(sql: """
            CREATE TABLE browser_sync_outbox_v4 (
                position INTEGER PRIMARY KEY AUTOINCREMENT,
                mutation_id TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL,
                protocol_version INTEGER NOT NULL DEFAULT 2 CHECK (protocol_version IN (2, 3, 4))
            );
            INSERT INTO browser_sync_outbox_v4 (position, mutation_id, payload, protocol_version)
                SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position;
            DROP TABLE browser_sync_outbox;
            ALTER TABLE browser_sync_outbox_v4 RENAME TO browser_sync_outbox;
            CREATE TABLE browser_sync_state_v4 (
                id INTEGER PRIMARY KEY CHECK (id = 1), base_url TEXT NOT NULL, user_id TEXT NOT NULL,
                cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
                paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1)),
                new_mutation_version INTEGER NOT NULL DEFAULT 2 CHECK (new_mutation_version IN (2, 3, 4))
            );
            INSERT INTO browser_sync_state_v4 SELECT id, base_url, user_id, cursor, paused, new_mutation_version FROM browser_sync_state;
            DROP TABLE browser_sync_state;
            ALTER TABLE browser_sync_state_v4 RENAME TO browser_sync_state;
            """)
            if let sequence {
                try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = 'browser_sync_outbox'")
                try db.execute(
                    sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('browser_sync_outbox', ?)",
                    arguments: [sequence],
                )
            }
        }
        migrator.registerMigration("distinguishSyncPauseFromLogout") { db in
            // Old paused records cannot distinguish Pause from failed logout.
            // Preserve their stricter reauthentication policy during upgrade.
            try db.execute(
                sql: """
                INSERT INTO browser_preferences (key, value)
                VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM browser_sync_state WHERE paused = 1) THEN '1' ELSE '0' END)
                """,
                arguments: [Key.syncRequiresSignIn],
            )
        }
        migrator.registerMigration("addLocalTabArchive") { db in
            // Consumed entries retain the chosen fresh tab ID as an idempotency
            // receipt. They are excluded from archive reads, never synced.
            try db.execute(sql: """
            CREATE TABLE browser_tab_archive (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                archived_at DOUBLE NOT NULL,
                restored_tab_id TEXT
            );
            CREATE INDEX browser_tab_archive_active_order
                ON browser_tab_archive (archived_at DESC, id DESC) WHERE restored_tab_id IS NULL;
            """)
        }
        migrator.registerMigration("separateArchiveContentFromReceipts") { db in
            try Self.migrateArchiveContent(in: db)
        }
        migrator.registerMigration("addSyncExpiryRecovery") { db in
            try db.execute(sql: """
            ALTER TABLE browser_sync_state ADD COLUMN expiry_recovery_enabled INTEGER NOT NULL DEFAULT 0 CHECK (expiry_recovery_enabled IN (0, 1));
            ALTER TABLE browser_sync_state ADD COLUMN archive_revision INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE browser_sync_expiry_imports (
                event_id TEXT PRIMARY KEY NOT NULL, payload_digest BLOB NOT NULL
            );
            """)
        }
        migrator.registerMigration("addExpirySyncOutbox") { db in
            let sequence = try Int64.fetchOne(
                db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'browser_sync_outbox'",
            )
            // Preserve original request bytes and consumed-row high-water marks.
            // The ordinary-write version CHECK remains 2/3/4 on sync_state.
            try db.execute(sql: """
            CREATE TABLE browser_sync_outbox_v5 (
                position INTEGER PRIMARY KEY AUTOINCREMENT,
                mutation_id TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL,
                protocol_version INTEGER NOT NULL DEFAULT 2 CHECK (protocol_version IN (2, 3, 4, 5))
            );
            INSERT INTO browser_sync_outbox_v5 (position, mutation_id, payload, protocol_version)
                SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position;
            DROP TABLE browser_sync_outbox;
            ALTER TABLE browser_sync_outbox_v5 RENAME TO browser_sync_outbox;
            """)
            if let sequence {
                try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = 'browser_sync_outbox'")
                try db.execute(
                    sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('browser_sync_outbox', ?)",
                    arguments: [sequence],
                )
            }
        }
        migrator.registerMigration("addAutomaticExpiryAttempts") { db in
            // Absence means a legacy/explicit request: never assume it was unsent.
            try db.execute(sql: """
            CREATE TABLE browser_sync_automatic_expiry (
                mutation_id TEXT PRIMARY KEY NOT NULL,
                attempted INTEGER NOT NULL CHECK(attempted IN (0,1))
            );
            """)
        }
        migrator.registerMigration("addTabSplitGroups") { db in
            // Local Split View groups. The payload is a validated JSON group whose
            // members are tab IDs; sync never reads or writes this table.
            try db.execute(sql: """
            CREATE TABLE \(Self.splitGroupsTable) (
                id TEXT PRIMARY KEY NOT NULL,
                position INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
            """)
        }
        migrator.registerMigration("addTabPageTitles") { db in
            // The last page title of each tab, local only, so unloaded tabs keep it.
            try db.execute(sql: "ALTER TABLE browser_tabs ADD COLUMN page_title TEXT")
        }
        migrator.registerMigration("addTabIcons") { db in
            // The icon chosen for a tab, local only.
            try db.execute(sql: "ALTER TABLE browser_tabs ADD COLUMN system_image_name TEXT")
        }
        migrator.registerMigration("addSpaceColors") { db in
            // The tint chosen for a Space, local only.
            try db.execute(sql: "ALTER TABLE browser_spaces ADD COLUMN color_name TEXT")
        }
        migrator.registerMigration("addSpaceProfiles") { db in
            // The browser profile chosen for a Space, local only.
            try db.execute(sql: "ALTER TABLE browser_spaces ADD COLUMN profile_directory TEXT")
        }
        migrator.registerMigration("addBoostSyncOutbox") { db in
            let sequence = try Int64.fetchOne(
                db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'browser_sync_outbox'",
            )
            // Version 6 rows carry boost writes. Copy rows byte for byte, as the
            // version 5 migration did, keeping consumed-row high-water marks.
            try db.execute(sql: """
            CREATE TABLE browser_sync_outbox_v6 (
                position INTEGER PRIMARY KEY AUTOINCREMENT,
                mutation_id TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL,
                protocol_version INTEGER NOT NULL DEFAULT 2 CHECK (protocol_version IN (2, 3, 4, 5, 6))
            );
            INSERT INTO browser_sync_outbox_v6 (position, mutation_id, payload, protocol_version)
                SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position;
            DROP TABLE browser_sync_outbox;
            ALTER TABLE browser_sync_outbox_v6 RENAME TO browser_sync_outbox;
            ALTER TABLE browser_sync_state ADD COLUMN boost_sync_enabled INTEGER NOT NULL DEFAULT 0 CHECK (boost_sync_enabled IN (0, 1));
            ALTER TABLE browser_sync_state ADD COLUMN boost_revision INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE browser_sync_boost_baseline (
                id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL
            );
            """)
            if let sequence {
                try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = 'browser_sync_outbox'")
                try db.execute(
                    sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('browser_sync_outbox', ?)",
                    arguments: [sequence],
                )
            }
        }
        return migrator
    }

    private let dbQueue: DatabaseQueue
    /// Used only inside `dbQueue` writes, which run one at a time.
    private let syncReplayMemo = BrowserSyncOutboxReplayMemo()

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        self.dbQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(dbQueue)
        try dbQueue.write { db in
            if try storedSyncOwner(db) != nil {
                try initializeSyncOutbox(in: db)
            }
        }
    }

    private static func decodeArchiveEntry(_ row: Row) throws -> BrowserTabArchiveEntry {
        let entry = try JSONDecoder().decode(BrowserTabArchiveEntry.self, from: row["payload"] as Data)
        try entry.validate()
        guard entry.id == row["id"] as String, entry.archivedAt == row["archived_at"] as Double else {
            throw BrowserTabArchiveError.invalidEntry
        }
        return entry
    }

    private static func foldArchiveSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func archiveFingerprint(_ entry: BrowserTabArchiveEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try Data(SHA256.hash(data: encoder.encode(entry)))
    }

    private static func readArchivePage(
        query: String, before cursor: BrowserTabArchiveCursor?, limit: Int, in db: Database,
    ) throws -> BrowserTabArchivePage {
        guard (1...100).contains(limit) else { throw BrowserTabArchiveError.invalidLimit }
        guard query.utf8.count <= 4096, query.count <= 256 else { throw BrowserTabArchiveError.invalidQuery }
        if let cursor, !cursor.archivedAt.isFinite || cursor.id.isEmpty {
            throw BrowserTabArchiveError.invalidCursor
        }
        var predicates = [String]()
        var arguments = StatementArguments()
        if !query.isEmpty {
            let folded = foldArchiveSearch(query)
            predicates
                .append("(instr(search_url, ?) > 0 OR instr(search_user_title, ?) > 0 OR instr(search_title, ?) > 0)")
            arguments += [folded, folded, folded]
        }
        if let cursor {
            predicates.append("(archived_at < ? OR (archived_at = ? AND id < ?))")
            arguments += [cursor.archivedAt, cursor.archivedAt, cursor.id]
        }
        let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        arguments += [limit + 1]
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, payload, archived_at FROM browser_tab_archive" + filter +
                " ORDER BY archived_at DESC, id DESC LIMIT ?",
            arguments: arguments,
        )
        let entries = try rows.prefix(limit).map(decodeArchiveEntry)
        let nextCursor = rows.count > limit
            ? entries.last.map {
                BrowserTabArchiveCursor(archivedAt: $0.archivedAt, id: $0.id)
            }
            : nil
        return BrowserTabArchivePage(entries: entries, nextCursor: nextCursor)
    }

    private static func insertArchiveContent(
        _ entry: BrowserTabArchiveEntry, sequence: Int64? = nil, in db: Database,
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO browser_tab_archive
                (insertion_sequence, id, payload, archived_at, search_url, search_user_title, search_title)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                sequence, entry.id, JSONEncoder().encode(entry), entry.archivedAt,
                foldArchiveSearch(entry.tab.urlString), foldArchiveSearch(entry.tab.userTitleOverride ?? ""),
                foldArchiveSearch(entry.title ?? ""),
            ],
        )
    }

    private static func migrateArchiveContent(in db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE browser_tab_archive RENAME TO browser_tab_archive_legacy;
        DROP INDEX browser_tab_archive_active_order;
        CREATE TABLE browser_tab_archive_receipts (
            id TEXT PRIMARY KEY NOT NULL,
            entry_digest BLOB NOT NULL CHECK (length(entry_digest) = 32),
            restored_tab_id TEXT CHECK (restored_tab_id IS NULL OR length(restored_tab_id) > 0)
        );
        CREATE TABLE browser_tab_archive (
            insertion_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE REFERENCES browser_tab_archive_receipts(id),
            payload BLOB NOT NULL,
            archived_at DOUBLE NOT NULL,
            search_url TEXT NOT NULL,
            search_user_title TEXT NOT NULL,
            search_title TEXT NOT NULL
        );
        CREATE INDEX browser_tab_archive_active_order ON browser_tab_archive (archived_at DESC, id DESC);
        """)
        let highWater = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM browser_tab_archive_legacy") ?? 0
        do {
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT rowid, id, payload, archived_at, restored_tab_id FROM browser_tab_archive_legacy ORDER BY rowid",
            )
            while let row = try rows.next() {
                let entry = try decodeArchiveEntry(row)
                let restoredID: String? = row["restored_tab_id"]
                try db.execute(
                    sql: "INSERT INTO browser_tab_archive_receipts (id, entry_digest, restored_tab_id) VALUES (?, ?, ?)",
                    arguments: [entry.id, archiveFingerprint(entry), restoredID],
                )
                if restoredID == nil {
                    try insertArchiveContent(entry, sequence: row["rowid"], in: db)
                }
            }
        }
        // Preserve the high-water mark even if the last legacy rows were consumed.
        try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = 'browser_tab_archive'")
        try db.execute(
            sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('browser_tab_archive', ?)", arguments: [highWater],
        )
        try db.execute(sql: "DROP TABLE browser_tab_archive_legacy")
    }

    /// Equality ignores local display fields, so they are compared too.
    private static func isStoredUnchanged(
        _ stored: BrowserTabSessionSnapshot,
        by next: BrowserTabSessionSnapshot,
    ) -> Bool {
        stored == next
            && stored.tabs.map(\.pageTitle) == next.tabs.map(\.pageTitle)
            && stored.tabs.map(\.systemImageName) == next.tabs.map(\.systemImageName)
            && (stored.spaces ?? []).map(\.colorName) == (next.spaces ?? []).map(\.colorName)
            && (stored.spaces ?? []).map(\.profileDirectory) == (next.spaces ?? []).map(\.profileDirectory)
    }

    /// New profile owners must distinguish an empty database from a failed read.
    func loadSnapshotStrict() throws -> BrowserTabSessionSnapshot? {
        try dbQueue.read { try readSnapshot($0) }
    }

    func hasCompletedSessionImport(_ identifier: String) throws -> Bool {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM browser_preferences WHERE key = ?",
                arguments: ["session_import:" + identifier],
            ) == "1"
        }
    }

    /// The marker and imported logical state commit together. Retrying after a
    /// crash cannot reintroduce imported tabs that the user has since deleted.
    @discardableResult func importSessionOnce(
        _ identifier: String,
        makeSnapshot: (BrowserTabSessionSnapshot?) throws -> BrowserTabSessionSnapshot,
    ) throws -> Bool {
        try dbQueue.write { db in
            let key = "session_import:" + identifier
            guard try String.fetchOne(
                db,
                sql: "SELECT value FROM browser_preferences WHERE key = ?",
                arguments: [key],
            ) != "1" else { return false }
            // Import precedes account binding. A separate explicit merge policy
            // is required for identities that may already have tombstones.
            guard try storedSyncOwner(db) == nil else { throw BrowserSessionImportError.syncedProfile }
            let snapshot = try makeSnapshot(readSnapshot(db))
            try saveLocalSnapshot(snapshot, syncMove: nil, in: db)
            try db.execute(
                sql: "INSERT OR REPLACE INTO browser_preferences (key, value) VALUES (?, '1')",
                arguments: [key],
            )
            return true
        }
    }

    func loadSnapshot() -> BrowserTabSessionSnapshot? {
        do {
            return try dbQueue.read { db in
                try readSnapshot(db)
            }
        } catch {
            Self.logger.error("Failed to load SQLite session snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        saveCompatibility(BrowserSessionWrite(snapshot: snapshot, origin: .local(syncMove: nil)))
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot, syncMove: BrowserSyncMoveIntent) {
        saveCompatibility(BrowserSessionWrite(snapshot: snapshot, origin: .local(syncMove: syncMove)))
    }

    func saveRemoteProjectionSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        saveCompatibility(BrowserSessionWrite(snapshot: snapshot, origin: .remoteProjection))
    }

    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws {
        guard !writes.isEmpty else { return }
        for write in writes {
            try write.validate()
        }
        try dbQueue.write { db in
            for write in writes {
                if let archiveAction = write.archiveAction,
                   try !applyArchiveAction(
                       archiveAction, snapshot: write.snapshot,
                       archiveProjectionSnapshot: write.archiveProjectionSnapshot, in: db,
                   )
                {
                    // A receipt retry must not replay an old full snapshot over
                    // edits committed after the original archive operation.
                    continue
                }
                switch write.origin {
                case .local(let syncMove): try saveLocalSnapshot(write.snapshot, syncMove: syncMove, in: db)
                case .remoteProjection: try writeSnapshot(write.snapshot, to: db)
                }
                if let archiveAction = write.archiveAction, case .restore(_, let tabID) = archiveAction {
                    // Permanent remote parent tombstones may filter a proposed
                    // destination. Never consume an entry without its new tab.
                    guard try readSnapshot(db)?.tabs.contains(where: { $0.id == tabID }) == true else {
                        throw BrowserTabArchiveError.invalidTransition
                    }
                }
            }
        }
    }

    func loadArchiveEntry(id: String) throws -> BrowserTabArchiveEntry? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, payload, archived_at FROM browser_tab_archive WHERE id = ?",
                arguments: [id],
            ) else { return nil }
            return try Self.decodeArchiveEntry(row)
        }
    }

    func loadArchivePage(
        before cursor: BrowserTabArchiveCursor? = nil, limit: Int = 50,
    ) throws -> BrowserTabArchivePage {
        try dbQueue.read { db in
            try Self.readArchivePage(query: "", before: cursor, limit: limit, in: db)
        }
    }

    nonisolated(nonsending) func searchArchivePage(
        query: String, before cursor: BrowserTabArchiveCursor? = nil, limit: Int = 50,
    ) async throws -> BrowserTabArchivePage {
        try await dbQueue.read { db in
            try Self.readArchivePage(query: query, before: cursor, limit: limit, in: db)
        }
    }

    nonisolated(nonsending) func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        try await dbQueue.read { db in
            try .init(insertionSequence: Int64.fetchOne(
                db, sql: "SELECT seq FROM sqlite_sequence WHERE name = 'browser_tab_archive'",
            ) ?? 0)
        }
    }

    nonisolated(nonsending) func removeArchiveEntry(id: String) async throws -> Bool {
        guard !id.isEmpty else { throw BrowserTabArchiveError.invalidEntry }
        return try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM browser_tab_archive WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    nonisolated(nonsending) func clearArchive(through boundary: BrowserTabArchiveBoundary) async throws -> Int {
        guard boundary.insertionSequence >= 0 else { throw BrowserTabArchiveError.invalidBoundary }
        return try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM browser_tab_archive WHERE insertion_sequence <= ?",
                arguments: [boundary.insertionSequence],
            )
            return db.changesCount
        }
    }

    func loadSnapshotForSync(for owner: BrowserSyncOwner) throws -> BrowserTabSessionSnapshot? {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try readSnapshot(db)
        }
    }

    func pendingSyncMutations(for owner: BrowserSyncOwner, limit: Int = 100) throws -> [BrowserSyncMutation] {
        try pendingSyncQueue(for: owner, limit: limit).map { mutation in
            guard case .legacy(let legacy) = mutation else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return legacy
        }
    }

    func pendingSyncQueue(for owner: BrowserSyncOwner, limit: Int = 100) throws -> [BrowserSyncQueuedMutation] {
        guard limit > 0 else { throw BrowserSyncOutboxError.invalidLimit }
        return try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try readSyncQueue(db, limit: limit)
        }
    }

    /// Persist a conditional intent without hiding its tab or changing the
    /// canonical baseline. Ordinary local edits continue to use the v4 codec.
    /// Retries reuse a queued row unchanged. Once ACK removes it, the server's
    /// permanent receipt owns replay identity; each new sweep needs a fresh UUID.
    func enqueueSyncExpiry(
        _ mutation: BrowserSyncExpiryMutation, for owner: BrowserSyncOwner, automaticBaseline: Data? = nil,
    ) throws {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            guard try folderSyncEnabled(in: db),
                  try Bool
                    .fetchOne(db, sql: "SELECT expiry_recovery_enabled FROM browser_sync_state WHERE id = 1") == true
            else { throw BrowserSyncQueueError.expiryBootstrapRequired }
            try mutation.validate()
            if let automaticBaseline {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM browser_sync_outbox") == 0,
                      try Data
                        .fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1") ==
                        automaticBaseline
                else { throw BrowserSyncExpiryError.candidatesChanged }
            }
            if let row = try Row.fetchOne(
                db, sql: "SELECT protocol_version, payload FROM browser_sync_outbox WHERE mutation_id = ?",
                arguments: [mutation.id],
            ) {
                guard row["protocol_version"] as Int == 5,
                      try JSONDecoder().decode(BrowserSyncExpiryMutation.self, from: row["payload"] as Data) == mutation
                else { throw BrowserSyncQueueError.mutationIdentityConflict }
                return
            }
            // Match the transport's default JSONEncoder, including escaped slashes.
            // Stored rows use a different representation and can be much smaller.
            let wirePayload = try JSONEncoder().encode(BrowserSyncExpiryPushRequest(
                mutationID: mutation.id,
                deviceID: "00000000-0000-4000-8000-000000000000",
                operations: mutation.operations,
            ))
            guard wirePayload.count <= 8 * 1024 * 1024 else { throw BrowserSyncQueueError.mutationTooLarge }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = try encoder.encode(mutation)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 5)",
                arguments: [mutation.id, payload],
            )
            if automaticBaseline != nil {
                try db.execute(
                    sql: "INSERT INTO browser_sync_automatic_expiry (mutation_id, attempted) VALUES (?, 0)",
                    arguments: [mutation.id],
                )
            }
        }
    }

    /// The potentially large baseline scan runs on GRDB's reader, not MainActor.
    nonisolated(nonsending) func syncExpiryCandidates(
        for owner: BrowserSyncOwner, state: BrowserSyncExpirySchedulingState, now: Date,
        ignoringMutationID: String? = nil, after: BrowserSyncExpiryCandidateCursor? = nil,
        excluding: Set<BrowserSyncExpiryCandidateCursor> = [], validatingEntityIDs: Set<String>? = nil,
    ) async throws -> BrowserSyncExpiryCandidateBatch {
        try await dbQueue.read { db in
            guard let ownerRow = try Row.fetchOne(
                db,
                sql: "SELECT base_url,user_id FROM browser_sync_state WHERE id=1",
            ),
                  let url = URL(string: ownerRow["base_url"] as String),
                  BrowserSyncOwner(baseURL: url, userID: ownerRow["user_id"]) == owner
            else { throw BrowserSyncStoreError.ownerMismatch }
            let payload = try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1") ?? Data()
            let empty = BrowserSyncExpiryCandidateBatch(baseline: payload, operations: [])
            guard let seconds = state.inactiveForSeconds, now.timeIntervalSince1970.isFinite,
                  [43200, 86400, 259_200, 604_800, 2_592_000].contains(seconds),
                  validatingEntityIDs.map({ $0.count <= 100 }) ?? true,
                  try Int.fetchOne(
                      db,
                      sql: "SELECT COUNT(*) FROM browser_sync_outbox WHERE mutation_id != ?",
                      arguments: [ignoringMutationID ?? ""],
                  ) == 0
            else { return empty }
            let baseline = try JSONDecoder().decode(BrowserSyncOutboxBaseline.self, from: payload)
            let rows = try Row.fetchAll(db, sql: "SELECT id, placement, last_activity_timestamp FROM browser_tabs")
            let local = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Row)? in
                guard let id = row["id"] as String? else { return nil }
                return (id, row)
            })
            let cutoff = now.timeIntervalSince1970 - Double(seconds)
            let dates = BrowserSyncActivityDates()
            let candidates = baseline.entities
                .filter { key, entity in
                    guard !baseline.deletedKeys.contains(key), entity.serverSeq > 0,
                          entity.change.entityType == .tab, entity.change.op == .upsert,
                          validatingEntityIDs?.contains(entity.change.entityID) ?? true,
                          !excluding.contains(.init(serverSeq: entity.serverSeq, entityID: entity.change.entityID)),
                          !state.protectedTabIDs.contains(entity.change.entityID),
                          let tab = entity.change.tabData, tab.placement == .temporary,
                          let activity = dates.projectedTimestamp(tab.lastActivityAt, local: nil), activity.isFinite,
                          activity <= cutoff, let row = local[entity.change.entityID],
                          row["placement"] as String == BrowserTabPlacement.temporary.rawValue,
                          let localActivity = row["last_activity_timestamp"] as Double?,
                          localActivity.isFinite, localActivity <= cutoff
                    else { return false }
                    return true
                }
                .values
                .sorted {
                    $0.serverSeq == $1.serverSeq ? $0.change.entityID < $1.change.entityID : $0.serverSeq < $1.serverSeq
                }
            // Rotate before limiting the batch. Rejected unchanged candidates
            // cannot permanently monopolize the first hundred positions.
            let start = after.flatMap { cursor in
                candidates.firstIndex {
                    $0.serverSeq > cursor.serverSeq ||
                        ($0.serverSeq == cursor.serverSeq && $0.change.entityID > cursor.entityID)
                }
            } ?? 0
            let ordered = candidates[start...] + candidates[..<start]
            return BrowserSyncExpiryCandidateBatch(baseline: payload, operations: ordered.prefix(100).map {
                BrowserSyncExpiryOperation(
                    id: $0.change.entityID,
                    expectedServerSeq: $0.serverSeq,
                    inactiveForSeconds: seconds,
                )
            })
        }
    }

    func automaticExpiryNeedsValidation(id: String, for owner: BrowserSyncOwner) throws -> Bool {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try Bool.fetchOne(
                db,
                sql: "SELECT attempted FROM browser_sync_automatic_expiry WHERE mutation_id=?",
                arguments: [id],
            ) == false
        }
    }

    /// Only never-attempted automatic intents can be consumed without an ACK.
    /// The exact body stays immutable; invalidating any member cancels the batch.
    @discardableResult func prepareAutomaticExpiry(
        id: String, baseline: Data?, for owner: BrowserSyncOwner,
    ) throws -> Bool {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT attempted FROM browser_sync_automatic_expiry WHERE mutation_id=?",
                arguments: [id],
            ) == false
            else { return true }
            if let baseline,
               try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1") == baseline,
               try Int.fetchOne(
                   db,
                   sql: "SELECT COUNT(*) FROM browser_sync_outbox WHERE mutation_id != ?",
                   arguments: [id],
               ) == 0
            {
                try db.execute(
                    sql: "UPDATE browser_sync_automatic_expiry SET attempted=1 WHERE mutation_id=?",
                    arguments: [id],
                )
                return true
            }
            try db.execute(sql: "DELETE FROM browser_sync_outbox WHERE mutation_id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM browser_sync_automatic_expiry WHERE mutation_id=?", arguments: [id])
            return false
        }
    }

    func enableSemanticSyncMutations(for owner: BrowserSyncOwner) throws {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            try db
                .execute(
                    sql: "UPDATE browser_sync_state SET new_mutation_version = MAX(new_mutation_version, 3) WHERE id = 1",
                )
        }
    }

    func syncPullProtocolVersion(for owner: BrowserSyncOwner) throws -> Int {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            if try boostSyncEnabled(in: db) {
                return 6
            }
            if try Bool
                .fetchOne(db, sql: "SELECT expiry_recovery_enabled FROM browser_sync_state WHERE id = 1") == true
            {
                return 5
            }
            return try folderSyncEnabled(in: db) ? 4 : 2
        }
    }

    func syncArchiveRevision(for owner: BrowserSyncOwner) throws -> Int64 {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try Int64.fetchOne(db, sql: "SELECT archive_revision FROM browser_sync_state WHERE id = 1") ?? 0
        }
    }

    func completeExpirySyncBootstrap(
        events: [BrowserSyncEvent], cursor: Int, for owner: BrowserSyncOwner,
    ) throws -> BrowserTabSessionSnapshot {
        try completeSyncBootstrap(events: events, cursor: cursor, for: owner, expiryRecovery: true)
    }

    /// Call only after every page of a v6 pull from cursor zero. Local boosts
    /// the server has not seen are queued in the same transaction.
    func completeBoostSyncBootstrap(
        events: [BrowserSyncEvent], cursor: Int, for owner: BrowserSyncOwner, localBoosts: [BrowserSyncBoostEntry],
    ) throws -> BrowserTabSessionSnapshot {
        try completeSyncBootstrap(
            events: events, cursor: cursor, for: owner, expiryRecovery: true, localBoosts: localBoosts,
        )
    }

    /// The server no longer offers v6: read at v5 until it does, then bootstrap
    /// boosts again. The boost baseline and queued rows stay.
    func suspendBoostSync(for owner: BrowserSyncOwner) throws {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            try db.execute(sql: """
            UPDATE browser_sync_state SET boost_sync_enabled = 0, boost_revision = boost_revision + 1 WHERE id = 1
            """)
        }
    }

    /// Changes whenever the synced boosts change, so the coordinator knows when to show them.
    func syncBoostRevision(for owner: BrowserSyncOwner) throws -> Int64 {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try Int64.fetchOne(db, sql: "SELECT boost_revision FROM browser_sync_state WHERE id = 1") ?? 0
        }
    }

    /// The synced boosts with queued writes on top. Nil until the profile has an
    /// account whose server carries boosts.
    func loadSyncBoostState() throws -> BrowserSyncBoostState? {
        try dbQueue.read { db in
            guard try storedSyncOwner(db) != nil, try boostSyncEnabled(in: db) else { return nil }
            return try BrowserSyncBoostState(baseline: readBoostBaseline(db), pending: readSyncQueue(db))
        }
    }

    /// Queues boost writes. False, writing nothing, until boost sync started:
    /// its first upload then takes every local boost.
    @discardableResult func enqueueSyncBoosts(_ operations: [BrowserSyncBoostOperation]) throws -> Bool {
        guard !operations.isEmpty else { return true }
        for operation in operations {
            try operation.validate()
        }
        return try dbQueue.write { db in
            guard try storedSyncOwner(db) != nil, try boostSyncEnabled(in: db) else { return false }
            try appendBoostSyncMutations(operations, to: db)
            try db.execute(sql: "UPDATE browser_sync_state SET boost_revision = boost_revision + 1 WHERE id = 1")
            return true
        }
    }

    /// Call only after every page of an explicit v4 pull starting at cursor zero.
    /// Re-registering a device can require the same bootstrap again; adoption is
    /// tied to the profile's durable version and never repeats on that path.
    func completeFolderSyncBootstrap(
        events: [BrowserSyncEvent], cursor: Int, for owner: BrowserSyncOwner,
    ) throws -> BrowserTabSessionSnapshot {
        try completeSyncBootstrap(events: events, cursor: cursor, for: owner, expiryRecovery: false)
    }

    /// How many queue replays this store skipped; tests read it.
    func syncReplayReuses() throws -> Int {
        try dbQueue.read { _ in syncReplayMemo.reuses }
    }

    func acknowledgeSyncMutation(
        id: String, protocolVersion: Int = 2, events: [BrowserSyncEvent], for owner: BrowserSyncOwner,
    ) throws -> BrowserTabSessionSnapshot {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            guard let storedVersion = try Int.fetchOne(
                db, sql: "SELECT protocol_version FROM browser_sync_outbox WHERE mutation_id = ?", arguments: [id],
            ) else {
                // Duplicate ACKs cannot introduce unproven events after their row is gone.
                return try readSnapshot(db) ?? BrowserTabSessionSnapshot(tabs: [])
            }
            guard storedVersion == protocolVersion else { throw BrowserSyncQueueError.protocolVersionMismatch }
            try importExpiryRecovery(events, owner: owner, in: db)
            var baseline = try readSyncBaseline(db)
            try baseline.apply(events.filter { $0.entityType != "boost" })
            try applyBoostEvents(events, in: db)
            if storedVersion == 6 {
                // The queued write left the overlay even when the server kept a newer state.
                try db.execute(sql: "UPDATE browser_sync_state SET boost_revision = boost_revision + 1 WHERE id = 1")
            }
            try db.execute(sql: "DELETE FROM browser_sync_outbox WHERE mutation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM browser_sync_automatic_expiry WHERE mutation_id = ?", arguments: [id])
            return try writeSyncProjection(baseline, in: db)
        }
    }

    func applyRemoteSyncEvents(
        _ events: [BrowserSyncEvent], cursor: Int, for owner: BrowserSyncOwner, enableSemanticMutations: Bool = false,
    ) throws -> BrowserTabSessionSnapshot {
        guard cursor >= 0 else { throw BrowserSyncStoreError.invalidCursor }
        return try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            try importExpiryRecovery(events, owner: owner, in: db)
            var baseline = try readSyncBaseline(db)
            try baseline.apply(events.filter { $0.entityType != "boost" })
            try applyBoostEvents(events, in: db)
            let snapshot = try writeSyncProjection(baseline, in: db)
            try db.execute(
                sql: "UPDATE browser_sync_state SET cursor = MAX(cursor, ?) WHERE id = 1", arguments: [cursor],
            )
            if enableSemanticMutations {
                try db
                    .execute(
                        sql: "UPDATE browser_sync_state SET new_mutation_version = MAX(new_mutation_version, 3) WHERE id = 1",
                    )
            }
            return snapshot
        }
    }

    func saveSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot, cursor: Int?, for owner: BrowserSyncOwner) throws {
        if let cursor, cursor < 0 {
            throw BrowserSyncStoreError.invalidCursor
        }
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            try writeSnapshot(snapshot, to: db)
            if let cursor {
                try db.execute(
                    sql: "UPDATE browser_sync_state SET cursor = MAX(cursor, ?) WHERE id = 1",
                    arguments: [cursor],
                )
            }
        }
    }

    func loadSelectedTabIndex(tabCount: Int) -> Int? {
        guard tabCount > 0, let storedIndex = integerPreference(for: Key.selectedTabIndex) else {
            return nil
        }

        return min(max(storedIndex, 0), tabCount - 1)
    }

    func saveSelectedTabIndex(_ index: Int?) {
        setPreference(index.map(String.init), for: Key.selectedTabIndex)
    }

    func loadSelectedSpaceIndex(spaceCount: Int) -> Int? {
        guard spaceCount > 0, let storedIndex = integerPreference(for: Key.selectedSpaceIndex) else {
            return nil
        }

        return min(max(storedIndex, 0), spaceCount - 1)
    }

    func saveSelectedSpaceIndex(_ index: Int?) {
        setPreference(index.map(String.init), for: Key.selectedSpaceIndex)
    }

    func loadSidebarWidth(minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard let value = doublePreference(for: Key.sidebarWidth), value.isFinite else {
            return nil
        }

        return min(max(CGFloat(value), minimum), maximum)
    }

    func saveSidebarWidth(_ width: CGFloat) {
        guard width.isFinite else {
            return
        }

        setPreference(String(Double(width)), for: Key.sidebarWidth)
    }

    func loadTemporaryTabLifetime() -> BrowserTemporaryTabLifetime {
        guard
            let rawValue = stringPreference(for: Key.temporaryTabLifetime),
            let lifetime = BrowserTemporaryTabLifetime(rawValue: rawValue)
        else {
            return .defaultValue
        }

        return lifetime
    }

    func saveTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime) {
        setPreference(lifetime.rawValue, for: Key.temporaryTabLifetime)
    }

    func loadLocalAutomaticArchivalOff() -> Bool {
        stringPreference(for: Key.localAutomaticTabArchivalOff) == "1"
    }

    func saveLocalAutomaticArchivalOff(_ off: Bool) {
        setPreference(off ? "1" : nil, for: Key.localAutomaticTabArchivalOff)
    }

    func loadAutomaticTabArchivalSettings() throws -> (enabled: Bool, lifetime: BrowserTemporaryTabLifetime) {
        try dbQueue.read { db in
            let enabled = try String.fetchOne(
                db,
                sql: "SELECT value FROM browser_preferences WHERE key=?",
                arguments: [Key.automaticTabArchivalEnabled],
            )
            let raw = try String.fetchOne(
                db,
                sql: "SELECT value FROM browser_preferences WHERE key=?",
                arguments: [Key.temporaryTabLifetime],
            )
            let lifetime = raw.flatMap(BrowserTemporaryTabLifetime.init(rawValue:))
            guard enabled == nil || enabled == "0" || enabled == "1",
                  raw == nil || lifetime != nil
            else {
                throw BrowserAutomaticArchivalSettingsError.invalidValue
            }
            return (enabled == "1", lifetime ?? .defaultValue)
        }
    }

    func loadAutomaticTabArchivalEnabled() -> Bool {
        (try? loadAutomaticTabArchivalSettings().enabled) ?? false
    }

    func saveAutomaticTabArchival(enabled: Bool, lifetime: BrowserTemporaryTabLifetime) throws {
        try dbQueue.write { db in
            for (key, value) in [
                (Key.automaticTabArchivalEnabled, enabled ? "1" : "0"),
                (Key.temporaryTabLifetime, lifetime.rawValue),
            ] {
                try db.execute(
                    sql: "INSERT INTO browser_preferences(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [key, value],
                )
            }
        }
    }

    func saveTemporaryTabLifetimeStrict(_ lifetime: BrowserTemporaryTabLifetime) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO browser_preferences(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                arguments: [Key.temporaryTabLifetime, lifetime.rawValue],
            )
        }
    }

    func syncCursor() -> Int {
        integerPreference(for: Key.syncCursor) ?? 0
    }

    func saveSyncCursor(_ cursor: Int) {
        do {
            try dbQueue.write { db in
                // Compatibility for pre-owner callers only. Once bound, every cursor
                // mutation must prove which account the response belongs to.
                guard try storedSyncOwner(db) == nil else { return }
                try db.execute(
                    sql: """
                    INSERT INTO browser_preferences (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [Key.syncCursor, String(cursor)],
                )
            }
        } catch {
            Self.logger.error("Failed to save legacy sync cursor: \(error.localizedDescription, privacy: .public)")
        }
    }

    func syncOwner() throws -> BrowserSyncOwner? {
        try dbQueue.read { db in try storedSyncOwner(db) }
    }

    func bindSyncOwner(_ owner: BrowserSyncOwner) throws {
        try dbQueue.write { db in
            guard try !requiresSyncSignIn(in: db) else { throw BrowserSyncStoreError.authenticationRequired }
            if let existingOwner = try storedSyncOwner(db) {
                guard existingOwner == owner else { throw BrowserSyncStoreError.ownerMismatch }
                try initializeSyncOutbox(in: db)
                return
            }
            try db.execute(
                sql: "INSERT INTO browser_sync_state (id, base_url, user_id, cursor, paused) VALUES (1, ?, ?, 0, 0)",
                arguments: [owner.baseURL.absoluteString, owner.userID],
            )
            // A v1 cursor has no proven server/account. Never assign it to a new owner.
            try db.execute(
                sql: "UPDATE browser_preferences SET value = '0' WHERE key = ?",
                arguments: [Key.syncCursor],
            )
            try initializeSyncOutbox(in: db)
        }
    }

    func syncCursor(for owner: BrowserSyncOwner) throws -> Int {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try Int.fetchOne(db, sql: "SELECT cursor FROM browser_sync_state WHERE id = 1") ?? 0
        }
    }

    func saveSyncCursor(_ cursor: Int, for owner: BrowserSyncOwner) throws {
        guard cursor >= 0 else { throw BrowserSyncStoreError.invalidCursor }
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            try db.execute(
                sql: "UPDATE browser_sync_state SET cursor = MAX(cursor, ?) WHERE id = 1",
                arguments: [cursor],
            )
        }
    }

    func pauseSync() throws {
        try dbQueue.write { db in
            guard try !requiresSyncSignIn(in: db) else { throw BrowserSyncStoreError.authenticationRequired }
            try db.execute(sql: "UPDATE browser_sync_state SET paused = 1 WHERE id = 1")
        }
    }

    /// Independent of ownership: logout before adoption must also quarantine
    /// credentials that Keychain failed to remove.
    func requiresSyncSignIn() throws -> Bool {
        try dbQueue.read { try requiresSyncSignIn(in: $0) }
    }

    func requireSyncSignIn() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO browser_preferences (key, value) VALUES (?, '1')",
                arguments: [Key.syncRequiresSignIn],
            )
            try db.execute(sql: "UPDATE browser_sync_state SET paused = 1 WHERE id = 1")
        }
    }

    /// Only a newly authenticated, durably saved credential may clear logout.
    /// Completing authentication never adopts an unbound local profile.
    func completeSyncAuthentication(for owner: BrowserSyncOwner) throws {
        try dbQueue.write { db in
            _ = try requiresSyncSignIn(in: db)
            if let existing = try storedSyncOwner(db) {
                guard existing == owner else { throw BrowserSyncStoreError.ownerMismatch }
                try db.execute(sql: "UPDATE browser_sync_state SET paused = 0 WHERE id = 1")
            }
            try db.execute(
                sql: "UPDATE browser_preferences SET value = '0' WHERE key = ?",
                arguments: [Key.syncRequiresSignIn],
            )
        }
    }

    func isSyncPaused(for owner: BrowserSyncOwner) throws -> Bool {
        try dbQueue.read { db in
            try requireSyncOwner(owner, in: db)
            return try Bool.fetchOne(db, sql: "SELECT paused FROM browser_sync_state WHERE id = 1") ?? false
        }
    }

    func resumeSync(for owner: BrowserSyncOwner) throws {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            guard try !requiresSyncSignIn(in: db) else { throw BrowserSyncStoreError.authenticationRequired }
            try db.execute(sql: "UPDATE browser_sync_state SET paused = 0 WHERE id = 1")
        }
    }

    private func completeSyncBootstrap(
        events: [BrowserSyncEvent], cursor: Int, for owner: BrowserSyncOwner, expiryRecovery: Bool,
        localBoosts: [BrowserSyncBoostEntry]? = nil,
    ) throws -> BrowserTabSessionSnapshot {
        guard cursor >= 0 else { throw BrowserSyncStoreError.invalidCursor }
        return try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            let pending = try readSyncQueue(db)
            guard pending.allSatisfy({ (4...6).contains($0.protocolVersion) }) else {
                throw BrowserSyncQueueError.bootstrapRequiresLegacyDrain
            }
            let local = try readSnapshot(db) ?? BrowserTabSessionSnapshot(tabs: [])
            let previous = try readSyncBaseline(db)
            try importExpiryRecovery(events, owner: owner, in: db)
            var baseline = BrowserSyncOutboxBaseline()
            baseline.deletedKeys = previous.deletedKeys
            try baseline.apply(events.filter { $0.entityType != "boost" })
            if let localBoosts {
                // Rebuild from zero, keeping deletions this device already knows.
                var boosts = try readBoostBaseline(db).tombstones
                try boosts.apply(events)
                try writeBoostBaseline(boosts, to: db)
                let state = BrowserSyncBoostState(baseline: boosts, pending: pending)
                try appendBoostSyncMutations(state.adoptionOperations(for: localBoosts), to: db)
                try db.execute(sql: """
                UPDATE browser_sync_state SET boost_sync_enabled = 1, boost_revision = boost_revision + 1 WHERE id = 1
                """)
            }
            if try !folderSyncEnabled(in: db) {
                let values = BrowserSyncOutboxProjection.effectiveChanges(baseline: baseline, pending: pending)
                let adoption = BrowserSyncFolderProjection.adoptionOperations(
                    local: local, values: values, deleted: baseline.deletedKeys,
                )
                try appendFolderSyncMutations(adoption, to: db)
            }
            try db.execute(
                sql: "UPDATE browser_sync_state SET new_mutation_version = 4, cursor = ? WHERE id = 1",
                arguments: [cursor],
            )
            try db.execute(
                sql: "UPDATE browser_sync_state SET expiry_recovery_enabled = ? WHERE id = 1",
                arguments: [expiryRecovery],
            )
            return try writeSyncProjection(baseline, in: db)
        }
    }

    /// Returns false only for an exact operation already committed. All effects
    /// and the following snapshot/outbox write share the surrounding transaction.
    private func applyArchiveAction(
        _ action: BrowserTabArchiveAction, snapshot: BrowserTabSessionSnapshot,
        archiveProjectionSnapshot: BrowserTabSessionSnapshot?, in db: Database,
    ) throws -> Bool {
        switch action {
        case .insert(let entry):
            let fingerprint = try Self.archiveFingerprint(entry)
            if let existing = try Data.fetchOne(
                db, sql: "SELECT entry_digest FROM browser_tab_archive_receipts WHERE id = ?", arguments: [entry.id],
            ) {
                guard existing == fingerprint else { throw BrowserTabArchiveError.archiveIDConflict }
                return false
            }
            if let archiveProjectionSnapshot {
                // The receipt must be checked first: replaying this preclose
                // snapshot after a successful insert would resurrect its tab.
                try writeSnapshot(archiveProjectionSnapshot, to: db)
            }
            guard let previous = try readSnapshot(db),
                  previous.tabs.first(where: { $0.id == entry.tab.id }) == entry.tab,
                  !snapshot.tabs.contains(where: { $0.id == entry.tab.id })
            else { throw BrowserTabArchiveError.invalidTransition }
            try db.execute(
                sql: "INSERT INTO browser_tab_archive_receipts (id, entry_digest) VALUES (?, ?)",
                arguments: [entry.id, fingerprint],
            )
            try Self.insertArchiveContent(entry, in: db)
            return true
        case .restore(let archiveID, let tabID):
            guard let receipt = try Row.fetchOne(
                db, sql: "SELECT restored_tab_id FROM browser_tab_archive_receipts WHERE id = ?",
                arguments: [archiveID],
            ) else { throw BrowserTabArchiveError.entryMissing }
            if let restoredID: String = receipt["restored_tab_id"] {
                guard restoredID == tabID else { throw BrowserTabArchiveError.archiveAlreadyRestored }
                return false
            }
            guard let row = try Row.fetchOne(
                db, sql: "SELECT id, payload, archived_at FROM browser_tab_archive WHERE id = ?",
                arguments: [archiveID],
            ) else { throw BrowserTabArchiveError.entryMissing }
            let entry = try Self.decodeArchiveEntry(row)
            guard tabID != entry.tab.id,
                  try readSnapshot(db)?.tabs.contains(where: { $0.id == tabID }) != true
            else { throw BrowserTabArchiveError.restoredTabIDNotFresh }
            if try storedSyncOwner(db) != nil,
               try readSyncBaseline(db).deletedKeys.contains(BrowserSyncOutboxProjection.key(type: .tab, id: tabID))
            {
                throw BrowserTabArchiveError.restoredTabIDNotFresh
            }
            guard let restored = snapshot.tabs.first(where: { $0.id == tabID }),
                  let spaceID = restored.spaceID, snapshot.spaces?.contains(where: { $0.id == spaceID }) == true,
                  restored.placement == .temporary, restored.pinnedFolderID == nil,
                  restored.urlString == entry.tab.urlString,
                  restored.userTitleOverride == entry.tab.userTitleOverride
            else { throw BrowserTabArchiveError.invalidTransition }
            try db.execute(
                sql: "UPDATE browser_tab_archive_receipts SET restored_tab_id = ? WHERE id = ? AND restored_tab_id IS NULL",
                arguments: [tabID, archiveID],
            )
            try db.execute(sql: "DELETE FROM browser_tab_archive WHERE id = ?", arguments: [archiveID])
            return true
        }
    }

    private func requiresSyncSignIn(in db: Database) throws -> Bool {
        let value = try String.fetchOne(
            db, sql: "SELECT value FROM browser_preferences WHERE key = ?", arguments: [Key.syncRequiresSignIn],
        )
        switch value {
        case "0": return false
        case "1": return true
        default: throw BrowserSyncStoreError.invalidAuthenticationState
        }
    }

    private func saveCompatibility(_ write: BrowserSessionWrite) {
        do {
            try writeSessionBatch([write])
        } catch {
            Self.logger.error("Failed to save SQLite session snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Must precede baseline deletion and queue removal in the same transaction.
    /// The event receipt survives local Clear/Restore and historical rebootstrap.
    private func importExpiryRecovery(
        _ events: [BrowserSyncEvent], owner: BrowserSyncOwner, in db: Database,
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var local: BrowserTabSessionSnapshot?
        var pending: [BrowserSyncQueuedMutation]?
        for event in events.sorted(by: { $0.serverSeq < $1.serverSeq }) {
            guard case .deleted(_, let recovery?) = event.data else { continue }
            let identity = try encoder.encode([
                owner.baseURL.absoluteString,
                owner.userID,
                String(event.serverSeq),
                event.entityID,
            ])
            let eventID = "sync-expiry-" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let canonical = try recovery.entry(event: event, id: eventID)
            let digest = try Data(SHA256.hash(data: encoder.encode(recovery)))
            if let previous = try Data.fetchOne(
                db,
                sql: "SELECT payload_digest FROM browser_sync_expiry_imports WHERE event_id = ?",
                arguments: [eventID],
            ) {
                guard previous == digest else { throw BrowserSyncOutboxError.invalidEvent }
                continue
            }
            if pending == nil {
                local = try readSnapshot(db)
                pending = try readSyncQueue(db)
            }
            let entries = [canonical] + BrowserSyncExpiryRecovery.localEntries(
                canonical: canonical, pending: pending ?? [], local: local,
            )
            for entry in entries {
                try entry.validate()
                try db.execute(
                    sql: "INSERT INTO browser_tab_archive_receipts (id, entry_digest) VALUES (?, ?)",
                    arguments: [entry.id, Self.archiveFingerprint(entry)],
                )
                try Self.insertArchiveContent(entry, in: db)
            }
            try db.execute(
                sql: "INSERT INTO browser_sync_expiry_imports (event_id, payload_digest) VALUES (?, ?)",
                arguments: [eventID, digest],
            )
            try db.execute(sql: "UPDATE browser_sync_state SET archive_revision = archive_revision + 1 WHERE id = 1")
        }
    }

    private func saveLocalSnapshot(
        _ snapshot: BrowserTabSessionSnapshot, syncMove: BrowserSyncMoveIntent?, in db: Database,
    ) throws {
        let previous = try readSnapshot(db)
        guard try storedSyncOwner(db) != nil else {
            try writeSnapshot(snapshot, to: db)
            return
        }
        var baseline = try readSyncBaseline(db)
        let filtered = BrowserSyncOutboxProjection.removingDeletedEntities(from: snapshot, baseline: baseline)
        try writeSnapshot(filtered, to: db)
        // Read back generated legacy tab IDs before making the immutable payload.
        let normalized = try readSnapshot(db) ?? BrowserTabSessionSnapshot(tabs: [])
        let version = try Int.fetchOne(
            db,
            sql: "SELECT new_mutation_version FROM browser_sync_state WHERE id = 1",
        ) ?? 2
        switch version {
        case 2:
            let changes = try BrowserSyncOutboxProjection.changes(
                from: previous, to: normalized, baseline: baseline, pending: readSyncQueue(db),
            )
            baseline.recordLocalDeletes(changes)
            try appendSyncMutations(changes, to: db)
        case 3:
            // Legacy operations cannot name a folder root. Infer its affected
            // tab movements instead of interpreting an empty tab hint as no move.
            let legacyMove = syncMove.flatMap { move in
                !move.tabIDs.isEmpty && move.items.allSatisfy { $0.entityType == .tab } ? move : nil
            }
            let operations = BrowserSyncSemanticProjection.operations(
                from: previous ?? BrowserTabSessionSnapshot(tabs: []), to: normalized, syncMove: legacyMove,
            )
            for operation in operations {
                switch operation {
                case .deleteSpace(let id): baseline.deletedKeys.insert(BrowserSyncOutboxProjection.key(
                        type: .space,
                        id: id,
                    ))
                case .deleteTab(let id): baseline.deletedKeys.insert(BrowserSyncOutboxProjection.key(
                        type: .tab,
                        id: id,
                    ))
                default: break
                }
            }
            try appendSemanticSyncMutations(operations, to: db)
        case 4:
            let operations = BrowserSyncFolderProjection.operations(
                from: previous,
                to: normalized,
                moveIntent: syncMove,
            )
            for operation in operations {
                let reference: BrowserSyncEntityReference? =
                    switch operation {
                    case .deleteSpace(let id): .init(entityType: .space, entityID: id)
                    case .deleteTab(let id): .init(entityType: .tab, entityID: id)
                    case .deleteFolder(let id): .init(entityType: .folder, entityID: id)
                    default: nil
                    }
                if let reference {
                    baseline.deletedKeys.insert(BrowserSyncOutboxProjection.key(
                        type: reference.entityType,
                        id: reference.entityID,
                    ))
                }
            }
            try appendFolderSyncMutations(operations, to: db)
        default: throw BrowserSyncQueueError.unsupportedProtocolVersion(version)
        }
        try writeSyncBaseline(baseline, to: db)
    }

    /// Earlier migrations read and write snapshots before the title column exists.
    private func hasPageTitleColumn(_ db: Database) throws -> Bool {
        try db.columns(in: "browser_tabs").contains { $0.name == "page_title" }
    }

    private func hasSpaceProfileColumn(_ db: Database) throws -> Bool {
        try db.columns(in: "browser_spaces").contains { $0.name == "profile_directory" }
    }

    private func hasSpaceColorColumn(_ db: Database) throws -> Bool {
        try db.columns(in: "browser_spaces").contains { $0.name == "color_name" }
    }

    private func hasTabIconColumn(_ db: Database) throws -> Bool {
        try db.columns(in: "browser_tabs").contains { $0.name == "system_image_name" }
    }

    private func readSnapshot(_ db: Database) throws -> BrowserTabSessionSnapshot? {
        let pageTitleColumn = try hasPageTitleColumn(db) ? ", page_title" : ""
        let iconColumn = try hasTabIconColumn(db) ? ", system_image_name" : ""
        let tabs = try Row.fetchAll(
            db,
            sql: """
            SELECT id, url_string, pinned_url_string, user_title_override, placement, space_id,
                   pinned_folder_id, last_activity_timestamp, pinned_sibling_rank\(pageTitleColumn)\(iconColumn)
            FROM browser_tabs
            ORDER BY position ASC
            """,
        )
        let hasSpaces = try hasStoredSpaces(db)
        guard !tabs.isEmpty || hasSpaces else {
            return nil
        }

        let spaceColorColumn = try hasSpaceColorColumn(db) ? ", color_name" : ""
        let spaceProfileColumn = try hasSpaceProfileColumn(db) ? ", profile_directory" : ""
        let spaces = try Row.fetchAll(
            db,
            sql: """
            SELECT id, title, system_image_name, is_pinned_section_collapsed, selected_tab_index\(spaceColorColumn)\(
                spaceProfileColumn
            )
            FROM browser_spaces
            ORDER BY position ASC
            """,
        )
        .map { row in
            BrowserSpaceSessionSnapshot(
                id: row["id"],
                title: row["title"],
                systemImageName: row["system_image_name"],
                isPinnedSectionCollapsed: row["is_pinned_section_collapsed"],
                selectedTabIndex: row["selected_tab_index"],
                colorName: spaceColorColumn.isEmpty ? nil : row["color_name"],
                profileDirectory: spaceProfileColumn.isEmpty ? nil : row["profile_directory"],
            )
        }
        let pinnedTabFolders = try Row.fetchAll(
            db,
            sql: """
            SELECT id, space_id, parent_folder_id, title, system_image_name, is_expanded, pinned_sibling_rank
            FROM browser_pinned_tab_folders
            ORDER BY position ASC
            """,
        )
        .map { row in
            BrowserPinnedTabFolderSessionSnapshot(
                id: row["id"],
                spaceID: row["space_id"],
                parentFolderID: row["parent_folder_id"],
                title: row["title"],
                systemImageName: row["system_image_name"],
                isExpanded: row["is_expanded"], pinnedSiblingRank: row["pinned_sibling_rank"],
            )
        }
        let splitGroups = try readSplitGroups(db)

        return BrowserTabSessionSnapshot(
            spaces: spaces.isEmpty ? nil : spaces,
            pinnedTabFolders: pinnedTabFolders.isEmpty ? nil : pinnedTabFolders,
            tabs: tabs.map { row in
                BrowserTabSessionSnapshotTab(
                    id: row["id"],
                    urlString: row["url_string"],
                    pinnedURLString: row["pinned_url_string"],
                    userTitleOverride: row["user_title_override"],
                    placement: BrowserTabPlacement(rawValue: row["placement"] as String) ?? .temporary,
                    spaceID: row["space_id"],
                    pinnedFolderID: row["pinned_folder_id"],
                    lastActivityTimestamp: row["last_activity_timestamp"],
                    pinnedSiblingRank: row["pinned_sibling_rank"],
                    pageTitle: pageTitleColumn.isEmpty ? nil : row["page_title"],
                    systemImageName: iconColumn.isEmpty ? nil : row["system_image_name"],
                )
            },
            splitGroups: splitGroups.isEmpty ? nil : splitGroups,
        )
    }

    /// Earlier migrations may read a snapshot before the split table exists.
    /// A malformed local group is dropped instead of failing session restore.
    private func readSplitGroups(_ db: Database) throws -> [BrowserTabSplitGroupSessionSnapshot] {
        guard try db.tableExists(Self.splitGroupsTable) else { return [] }
        return try Row.fetchAll(
            db,
            sql: "SELECT id, payload FROM \(Self.splitGroupsTable) ORDER BY position ASC",
        )
        .compactMap { row in
            guard let group = try? JSONDecoder().decode(
                BrowserTabSplitGroupSessionSnapshot.self,
                from: row["payload"] as Data,
            ), group.id == row["id"] as String else { return nil }
            return group
        }
    }

    /// A snapshot without split state (remote projection, mobile, archive
    /// transitions) keeps the stored groups. Either way only members that are
    /// still present survive, and a group needs two of them.
    private func writeSplitGroups(for snapshot: BrowserTabSessionSnapshot, to db: Database) throws {
        guard try db.tableExists(Self.splitGroupsTable) else { return }
        let groups = try snapshot.splitGroups ?? readSplitGroups(db)
        let tabIDs = Set(snapshot.tabs.compactMap(\.id))
        try db.execute(sql: "DELETE FROM \(Self.splitGroupsTable)")
        var seenGroupIDs = Set<String>()
        var claimedTabIDs = Set<String>()
        var position = 0
        for group in groups {
            guard seenGroupIDs.insert(group.id).inserted,
                  let kept = group.keeping(tabIDs: tabIDs.subtracting(claimedTabIDs))
            else { continue }
            claimedTabIDs.formUnion(kept.tabIDs)
            try db.execute(
                sql: "INSERT INTO \(Self.splitGroupsTable) (id, position, payload) VALUES (?, ?, ?)",
                arguments: [kept.id, position, JSONEncoder().encode(kept)],
            )
            position += 1
        }
    }

    private func initializeSyncOutbox(in db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM browser_sync_baseline") == 0 else { return }
        // Old owner-bound profiles have no trustworthy remote baseline. Seed current
        // records once and replay from zero; earlier offline deletions cannot be recovered.
        let snapshot = try readSnapshot(db) ?? BrowserTabSessionSnapshot(tabs: [])
        try appendSyncMutations(BrowserSyncOutboxProjection.changes(from: nil, to: snapshot), to: db)
        try writeSyncBaseline(BrowserSyncOutboxBaseline(), to: db)
        try db.execute(sql: "UPDATE browser_sync_state SET cursor = 0 WHERE id = 1")
    }

    private func readSyncBaseline(_ db: Database) throws -> BrowserSyncOutboxBaseline {
        guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1") else {
            throw BrowserSyncStoreError.ownerNotBound
        }
        return try JSONDecoder().decode(BrowserSyncOutboxBaseline.self, from: payload)
    }

    private func writeSyncBaseline(_ baseline: BrowserSyncOutboxBaseline, to db: Database) throws {
        try db.execute(
            sql: "INSERT INTO browser_sync_baseline (id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
            arguments: [JSONEncoder().encode(baseline)],
        )
    }

    private func appendSyncMutations(_ changes: [BrowserSyncChange], to db: Database) throws {
        for chunk in try syncChunks(changes) {
            let mutation = BrowserSyncMutation(id: UUID().uuidString, changes: chunk)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 2)",
                arguments: [mutation.id, JSONEncoder().encode(mutation)],
            )
        }
    }

    private func appendSemanticSyncMutations(_ operations: [BrowserSyncSemanticOperation], to db: Database) throws {
        for chunk in try syncChunks(operations) {
            let mutation = BrowserSyncSemanticMutation(id: UUID().uuidString, operations: chunk)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 3)",
                arguments: [mutation.id, JSONEncoder().encode(mutation)],
            )
        }
    }

    private func appendFolderSyncMutations(_ operations: [BrowserSyncFolderOperation], to db: Database) throws {
        for chunk in try syncChunks(operations) {
            let mutation = BrowserSyncFolderMutation(id: UUID().uuidString, operations: chunk)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 4)",
                arguments: [mutation.id, JSONEncoder().encode(mutation)],
            )
        }
    }

    private func appendBoostSyncMutations(_ operations: [BrowserSyncBoostOperation], to db: Database) throws {
        for chunk in try syncChunks(operations) {
            let mutation = BrowserSyncBoostMutation(id: UUID().uuidString, operations: chunk)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 6)",
                arguments: [mutation.id, JSONEncoder().encode(mutation)],
            )
        }
    }

    private func boostSyncEnabled(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT boost_sync_enabled FROM browser_sync_state WHERE id = 1") == true
    }

    private func readBoostBaseline(_ db: Database) throws -> BrowserSyncBoostBaseline {
        guard let payload = try Data.fetchOne(
            db, sql: "SELECT payload FROM browser_sync_boost_baseline WHERE id = 1",
        ) else { return BrowserSyncBoostBaseline() }
        return try JSONDecoder().decode(BrowserSyncBoostBaseline.self, from: payload)
    }

    private func writeBoostBaseline(_ baseline: BrowserSyncBoostBaseline, to db: Database) throws {
        try db.execute(
            sql: "INSERT INTO browser_sync_boost_baseline (id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
            arguments: [JSONEncoder().encode(baseline)],
        )
    }

    /// Boost events go to their own baseline; a change bumps the boost revision.
    private func applyBoostEvents(_ events: [BrowserSyncEvent], in db: Database) throws {
        let boostEvents = events.filter { $0.entityType == "boost" }
        guard !boostEvents.isEmpty else { return }
        let previous = try readBoostBaseline(db)
        var baseline = previous
        try baseline.apply(boostEvents)
        guard baseline != previous else { return }
        try writeBoostBaseline(baseline, to: db)
        try db.execute(sql: "UPDATE browser_sync_state SET boost_revision = boost_revision + 1 WHERE id = 1")
    }

    private func syncChunks<Item: Encodable>(_ items: [Item]) throws -> [[Item]] {
        // The server caps inflated JSON at 8 MiB. Reserve more than the fixed
        // UUID/device/version envelope requires, counting escaped UTF-8 item bytes.
        let maximumItemBytes = 8 * 1024 * 1024 - 1024
        let encoder = JSONEncoder()
        var chunks = [[Item]]()
        var current = [Item]()
        var currentBytes = 0
        for item in items {
            let itemBytes = try encoder.encode(item).count
            guard itemBytes <= maximumItemBytes else { throw BrowserSyncQueueError.mutationTooLarge }
            if !current.isEmpty, current.count == 1000 || currentBytes + itemBytes + 1 > maximumItemBytes {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(item)
            currentBytes += itemBytes + 1
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func readSyncQueue(_ db: Database, limit: Int? = nil) throws -> [BrowserSyncQueuedMutation] {
        try readSyncQueueRows(db, limit: limit).map(\.mutation)
    }

    private func readSyncQueueRows(
        _ db: Database, limit: Int? = nil,
    ) throws -> [(mutation: BrowserSyncQueuedMutation, identity: BrowserSyncQueuedRowIdentity)] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position ASC LIMIT ?",
            arguments: [limit ?? -1],
        )
        return try rows.map { row in
            let version: Int = row["protocol_version"]
            let mutation: BrowserSyncQueuedMutation
            switch version {
            case 2: mutation = try .legacy(JSONDecoder().decode(BrowserSyncMutation.self, from: row["payload"] as Data))
            case 3: mutation = try .semantic(JSONDecoder().decode(
                    BrowserSyncSemanticMutation.self,
                    from: row["payload"] as Data,
                ))
            case 4: mutation = try .folders(JSONDecoder().decode(
                    BrowserSyncFolderMutation.self,
                    from: row["payload"] as Data,
                ))
            case 5:
                let expiry = try JSONDecoder().decode(BrowserSyncExpiryMutation.self, from: row["payload"] as Data)
                try expiry.validate()
                mutation = .expiry(expiry)
            case 6:
                let boosts = try JSONDecoder().decode(BrowserSyncBoostMutation.self, from: row["payload"] as Data)
                try boosts.validate()
                mutation = .boosts(boosts)
            default: throw BrowserSyncQueueError.unsupportedProtocolVersion(version)
            }
            guard mutation.id == row["mutation_id"] as String
            else { throw BrowserSyncQueueError.invalidMutationIdentity }
            return (mutation, BrowserSyncQueuedRowIdentity(protocolVersion: version, payload: row["payload"]))
        }
    }

    private func writeSyncProjection(
        _ baseline: BrowserSyncOutboxBaseline,
        in db: Database,
    ) throws -> BrowserTabSessionSnapshot {
        let local = try readSnapshot(db)
        let rows = try readSyncQueueRows(db)
        // Each ACK removes the head row; the memo lets it skip replaying the rest.
        let snapshot = try BrowserSyncOutboxProjection.snapshot(
            baseline: baseline, pending: rows.map(\.mutation), local: local,
            folderSyncEnabled: folderSyncEnabled(in: db),
            reusing: (rows.map(\.identity), syncReplayMemo),
        )
        try writeSyncBaseline(baseline, to: db)
        // An ACK of a change already shown locally projects the stored snapshot
        // again; rewriting every row then costs the most of a queue drain.
        if let local, Self.isStoredUnchanged(local, by: snapshot) {
            return local
        }
        try writeSnapshot(snapshot, to: db)
        return snapshot
    }

    private func folderSyncEnabled(in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT new_mutation_version FROM browser_sync_state WHERE id = 1") == 4
    }

    private func storedSyncOwner(_ db: Database) throws -> BrowserSyncOwner? {
        guard let row = try Row.fetchOne(db, sql: "SELECT base_url, user_id FROM browser_sync_state WHERE id = 1")
        else {
            return nil
        }
        guard let url = URL(string: row["base_url"] as String) else {
            throw BrowserSyncStoreError.invalidStoredOwner
        }
        return BrowserSyncOwner(baseURL: url, userID: row["user_id"])
    }

    private func requireSyncOwner(_ owner: BrowserSyncOwner, in db: Database) throws {
        guard let stored = try storedSyncOwner(db) else { throw BrowserSyncStoreError.ownerNotBound }
        guard stored == owner else { throw BrowserSyncStoreError.ownerMismatch }
    }

    private func writeSnapshot(_ snapshot: BrowserTabSessionSnapshot, to db: Database) throws {
        try db.execute(sql: "DELETE FROM browser_spaces")
        try db.execute(sql: "DELETE FROM browser_pinned_tab_folders")
        try db.execute(sql: "DELETE FROM browser_tabs")

        let writesSpaceColors = try hasSpaceColorColumn(db)
        let writesSpaceProfiles = try hasSpaceProfileColumn(db)
        for (index, space) in (snapshot.spaces ?? []).enumerated() {
            try db.execute(
                sql: """
                INSERT INTO browser_spaces (
                  id, title, system_image_name, is_pinned_section_collapsed, selected_tab_index, position
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    space.id,
                    space.title,
                    space.systemImageName,
                    space.isPinnedSectionCollapsed,
                    space.selectedTabIndex,
                    index,
                ],
            )
            if writesSpaceColors, let color = space.colorName {
                try db.execute(
                    sql: "UPDATE browser_spaces SET color_name = ? WHERE id = ?",
                    arguments: [color, space.id],
                )
            }
            if writesSpaceProfiles, let profile = space.profileDirectory {
                try db.execute(
                    sql: "UPDATE browser_spaces SET profile_directory = ? WHERE id = ?",
                    arguments: [profile, space.id],
                )
            }
        }

        for (index, folder) in (snapshot.pinnedTabFolders ?? []).enumerated() {
            try db.execute(
                sql: """
                INSERT INTO browser_pinned_tab_folders (
                  id, space_id, parent_folder_id, title, system_image_name, is_expanded, position, pinned_sibling_rank
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    folder.id,
                    folder.spaceID,
                    folder.parentFolderID,
                    folder.title,
                    folder.systemImageName,
                    folder.isExpanded,
                    index,
                    folder.pinnedSiblingRank,
                ],
            )
        }

        let writesPageTitles = try hasPageTitleColumn(db)
        let writesIcons = try hasTabIconColumn(db)
        for (index, tab) in snapshot.tabs.enumerated() {
            let id = tab.id ?? UUID().uuidString
            try db.execute(
                sql: """
                INSERT INTO browser_tabs (
                  id, url_string, pinned_url_string, user_title_override, placement, space_id,
                  pinned_folder_id, last_activity_timestamp, position, pinned_sibling_rank
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    tab.urlString,
                    tab.pinnedURLString,
                    tab.userTitleOverride,
                    tab.placement.rawValue,
                    tab.spaceID,
                    tab.pinnedFolderID,
                    tab.lastActivityTimestamp,
                    index,
                    tab.pinnedSiblingRank,
                ],
            )
            if writesPageTitles, let pageTitle = tab.pageTitle {
                try db.execute(sql: "UPDATE browser_tabs SET page_title = ? WHERE id = ?", arguments: [pageTitle, id])
            }
            if writesIcons, let icon = tab.systemImageName {
                try db.execute(sql: "UPDATE browser_tabs SET system_image_name = ? WHERE id = ?", arguments: [icon, id])
            }
        }
        try writeSplitGroups(for: snapshot, to: db)
    }

    private func hasStoredSpaces(_ db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM browser_spaces") ?? 0 > 0
    }

    private func stringPreference(for key: String) -> String? {
        try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM browser_preferences WHERE key = ?", arguments: [key])
        }
    }

    private func integerPreference(for key: String) -> Int? {
        stringPreference(for: key).flatMap(Int.init)
    }

    private func doublePreference(for key: String) -> Double? {
        stringPreference(for: key).flatMap(Double.init)
    }

    private func setPreference(_ value: String?, for key: String) {
        do {
            try dbQueue.write { db in
                guard let value else {
                    try db.execute(sql: "DELETE FROM browser_preferences WHERE key = ?", arguments: [key])
                    return
                }

                try db.execute(
                    sql: """
                    INSERT INTO browser_preferences (key, value)
                    VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value],
                )
            }
        } catch {
            Self.logger.error("Failed to save SQLite preference: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - BrowserSessionImportError

enum BrowserSessionImportError: Error, LocalizedError {
    case syncedProfile

    // MARK: Internal

    var errorDescription: String? {
        "The saved windows cannot be imported into an already synchronized profile. The original files have been kept."
    }
}
