import CoreGraphics
import Foundation
import GRDB
import OSLog

// MARK: - BrowserSQLiteSessionStore

final class BrowserSQLiteSessionStore: BrowserTabSessionSnapshotStoring, BrowserSessionPreferencesStoring {
    // MARK: Lifecycle

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dbQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(dbQueue)
        try dbQueue.write { db in
            if try storedSyncOwner(db) != nil {
                try initializeSyncOutbox(in: db)
            }
        }
    }

    // MARK: Internal

    static let databaseFileName = "TheBrowser.sqlite"

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
        do {
            try dbQueue.write { db in
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
                    sql: "SELECT new_mutation_version FROM browser_sync_state WHERE id = 1"
                ) ?? 2
                switch version {
                case 2:
                    let changes = try BrowserSyncOutboxProjection.changes(
                        from: previous, to: normalized, baseline: baseline, pending: readSyncQueue(db)
                    )
                    baseline.recordLocalDeletes(changes)
                    try appendSyncMutations(changes, to: db)
                case 3:
                    let operations = BrowserSyncSemanticProjection.operations(
                        from: previous ?? BrowserTabSessionSnapshot(tabs: []), to: normalized
                    )
                    for operation in operations {
                        switch operation {
                        case .deleteSpace(let id): baseline.deletedKeys.insert(BrowserSyncOutboxProjection.key(
                                type: .space,
                                id: id
                            ))
                        case .deleteTab(let id): baseline.deletedKeys.insert(BrowserSyncOutboxProjection.key(
                                type: .tab,
                                id: id
                            ))
                        default: break
                        }
                    }
                    try appendSemanticSyncMutations(operations, to: db)
                default: throw BrowserSyncQueueError.unsupportedProtocolVersion(version)
                }
                try writeSyncBaseline(baseline, to: db)
            }
        } catch {
            Self.logger.error("Failed to save SQLite session snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveRemoteProjectionSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        do {
            try dbQueue.write { db in try writeSnapshot(snapshot, to: db) }
        } catch {
            Self.logger.error("Failed to save remote projection: \(error.localizedDescription, privacy: .public)")
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

    func enableSemanticSyncMutations(for owner: BrowserSyncOwner) throws {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            try db.execute(sql: "UPDATE browser_sync_state SET new_mutation_version = 3 WHERE id = 1")
        }
    }

    func acknowledgeSyncMutation(
        id: String, protocolVersion: Int = 2, events: [BrowserSyncEvent], for owner: BrowserSyncOwner
    ) throws -> BrowserTabSessionSnapshot {
        try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            guard let storedVersion = try Int.fetchOne(
                db, sql: "SELECT protocol_version FROM browser_sync_outbox WHERE mutation_id = ?", arguments: [id]
            ) else {
                // Duplicate ACKs cannot introduce unproven events after their row is gone.
                return try readSnapshot(db) ?? BrowserTabSessionSnapshot(tabs: [])
            }
            guard storedVersion == protocolVersion else { throw BrowserSyncQueueError.protocolVersionMismatch }
            var baseline = try readSyncBaseline(db)
            try baseline.apply(events)
            try db.execute(sql: "DELETE FROM browser_sync_outbox WHERE mutation_id = ?", arguments: [id])
            return try writeSyncProjection(baseline, in: db)
        }
    }

    func applyRemoteSyncEvents(
        _ events: [BrowserSyncEvent], cursor: Int, for owner: BrowserSyncOwner, enableSemanticMutations: Bool = false
    ) throws -> BrowserTabSessionSnapshot {
        guard cursor >= 0 else { throw BrowserSyncStoreError.invalidCursor }
        return try dbQueue.write { db in
            try requireSyncOwner(owner, in: db)
            var baseline = try readSyncBaseline(db)
            try baseline.apply(events)
            let snapshot = try writeSyncProjection(baseline, in: db)
            try db.execute(
                sql: "UPDATE browser_sync_state SET cursor = MAX(cursor, ?) WHERE id = 1", arguments: [cursor]
            )
            if enableSemanticMutations {
                try db.execute(sql: "UPDATE browser_sync_state SET new_mutation_version = 3 WHERE id = 1")
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
                    arguments: [cursor]
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
                    arguments: [Key.syncCursor, String(cursor)]
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
            if let existingOwner = try storedSyncOwner(db) {
                guard existingOwner == owner else { throw BrowserSyncStoreError.ownerMismatch }
                try initializeSyncOutbox(in: db)
                return
            }
            try db.execute(
                sql: "INSERT INTO browser_sync_state (id, base_url, user_id, cursor, paused) VALUES (1, ?, ?, 0, 0)",
                arguments: [owner.baseURL.absoluteString, owner.userID]
            )
            // A v1 cursor has no proven server/account. Never assign it to a new owner.
            try db.execute(
                sql: "UPDATE browser_preferences SET value = '0' WHERE key = ?",
                arguments: [Key.syncCursor]
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
                arguments: [cursor]
            )
        }
    }

    func pauseSync() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE browser_sync_state SET paused = 1 WHERE id = 1")
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
            try db.execute(sql: "UPDATE browser_sync_state SET paused = 0 WHERE id = 1")
        }
    }

    // MARK: Private

    private enum Key {
        static let selectedTabIndex = "browser.session.selectedTabIndex"
        static let selectedSpaceIndex = "browser.session.selectedSpaceIndex"
        static let sidebarWidth = "browser.session.sidebarWidth"
        static let temporaryTabLifetime = "browser.settings.temporaryTabLifetime"
        static let syncCursor = "browser.sync.cursor"
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        category: "SQLiteSession"
    )

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
                    sql: "ALTER TABLE browser_sync_outbox ADD COLUMN protocol_version INTEGER NOT NULL DEFAULT 2 CHECK (protocol_version IN (2, 3))"
                )
            try db
                .execute(
                    sql: "ALTER TABLE browser_sync_state ADD COLUMN new_mutation_version INTEGER NOT NULL DEFAULT 2 CHECK (new_mutation_version IN (2, 3))"
                )
        }
        return migrator
    }

    private let dbQueue: DatabaseQueue

    private func readSnapshot(_ db: Database) throws -> BrowserTabSessionSnapshot? {
        let tabs = try Row.fetchAll(
            db,
            sql: """
            SELECT id, url_string, pinned_url_string, user_title_override, placement, space_id,
                   pinned_folder_id, last_activity_timestamp
            FROM browser_tabs
            ORDER BY position ASC
            """
        )
        let hasSpaces = try hasStoredSpaces(db)
        guard !tabs.isEmpty || hasSpaces else {
            return nil
        }

        let spaces = try Row.fetchAll(
            db,
            sql: """
            SELECT id, title, system_image_name, is_pinned_section_collapsed, selected_tab_index
            FROM browser_spaces
            ORDER BY position ASC
            """
        )
        .map { row in
            BrowserSpaceSessionSnapshot(
                id: row["id"],
                title: row["title"],
                systemImageName: row["system_image_name"],
                isPinnedSectionCollapsed: row["is_pinned_section_collapsed"],
                selectedTabIndex: row["selected_tab_index"]
            )
        }
        let pinnedTabFolders = try Row.fetchAll(
            db,
            sql: """
            SELECT id, space_id, parent_folder_id, title, system_image_name, is_expanded
            FROM browser_pinned_tab_folders
            ORDER BY position ASC
            """
        )
        .map { row in
            BrowserPinnedTabFolderSessionSnapshot(
                id: row["id"],
                spaceID: row["space_id"],
                parentFolderID: row["parent_folder_id"],
                title: row["title"],
                systemImageName: row["system_image_name"],
                isExpanded: row["is_expanded"]
            )
        }

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
                    lastActivityTimestamp: row["last_activity_timestamp"]
                )
            }
        )
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
            arguments: [JSONEncoder().encode(baseline)]
        )
    }

    private func appendSyncMutations(_ changes: [BrowserSyncChange], to db: Database) throws {
        for chunk in try syncChunks(changes) {
            let mutation = BrowserSyncMutation(id: UUID().uuidString, changes: chunk)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 2)",
                arguments: [mutation.id, JSONEncoder().encode(mutation)]
            )
        }
    }

    private func appendSemanticSyncMutations(_ operations: [BrowserSyncSemanticOperation], to db: Database) throws {
        for chunk in try syncChunks(operations) {
            let mutation = BrowserSyncSemanticMutation(id: UUID().uuidString, operations: chunk)
            try db.execute(
                sql: "INSERT INTO browser_sync_outbox (mutation_id, payload, protocol_version) VALUES (?, ?, 3)",
                arguments: [mutation.id, JSONEncoder().encode(mutation)]
            )
        }
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
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position ASC LIMIT ?",
            arguments: [limit ?? -1]
        )
        return try rows.map { row in
            let version: Int = row["protocol_version"]
            let mutation: BrowserSyncQueuedMutation
            switch version {
            case 2: mutation = try .legacy(JSONDecoder().decode(BrowserSyncMutation.self, from: row["payload"] as Data))
            case 3: mutation = try .semantic(JSONDecoder().decode(
                    BrowserSyncSemanticMutation.self,
                    from: row["payload"] as Data
                ))
            default: throw BrowserSyncQueueError.unsupportedProtocolVersion(version)
            }
            guard mutation.id == row["mutation_id"] as String
            else { throw BrowserSyncQueueError.invalidMutationIdentity }
            return mutation
        }
    }

    private func writeSyncProjection(
        _ baseline: BrowserSyncOutboxBaseline,
        in db: Database
    ) throws -> BrowserTabSessionSnapshot {
        let snapshot = try BrowserSyncOutboxProjection.snapshot(
            baseline: baseline, pending: readSyncQueue(db), local: readSnapshot(db)
        )
        try writeSyncBaseline(baseline, to: db)
        try writeSnapshot(snapshot, to: db)
        return snapshot
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
                ]
            )
        }

        for (index, folder) in (snapshot.pinnedTabFolders ?? []).enumerated() {
            try db.execute(
                sql: """
                INSERT INTO browser_pinned_tab_folders (
                  id, space_id, parent_folder_id, title, system_image_name, is_expanded, position
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    folder.id,
                    folder.spaceID,
                    folder.parentFolderID,
                    folder.title,
                    folder.systemImageName,
                    folder.isExpanded,
                    index,
                ]
            )
        }

        for (index, tab) in snapshot.tabs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO browser_tabs (
                  id, url_string, pinned_url_string, user_title_override, placement, space_id,
                  pinned_folder_id, last_activity_timestamp, position
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    tab.id ?? UUID().uuidString,
                    tab.urlString,
                    tab.pinnedURLString,
                    tab.userTitleOverride,
                    tab.placement.rawValue,
                    tab.spaceID,
                    tab.pinnedFolderID,
                    tab.lastActivityTimestamp,
                    index,
                ]
            )
        }
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
                    arguments: [key, value]
                )
            }
        } catch {
            Self.logger.error("Failed to save SQLite preference: \(error.localizedDescription, privacy: .public)")
        }
    }
}
