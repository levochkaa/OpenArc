import Foundation
import GRDB
import Testing

@Test func syncOwnerNormalizesServerIdentityWithoutCombiningDistinctBackends() {
    let owner = BrowserSyncOwner(
        baseURL: syncOwnerFixtureURL("HTTPS://SYNC.Example:443/api///#settings"),
        userID: "user-1"
    )
    #expect(owner.baseURL.absoluteString == "https://sync.example/api")
    #expect(owner == BrowserSyncOwner(baseURL: syncOwnerFixtureURL("https://sync.example/api"), userID: "user-1"))
    #expect(BrowserSyncOwner(baseURL: syncOwnerFixtureURL("http://sync.example:80/"), userID: "user-1")
        .baseURL
        .absoluteString == "http://sync.example")

    for url in [
        "http://sync.example/api",
        "https://sync.example:8443/api",
        "https://sync.example/API",
        "https://sync.example/api?tenant=second",
        "https://other.example/api",
    ] {
        #expect(owner != BrowserSyncOwner(baseURL: syncOwnerFixtureURL(url), userID: "user-1"))
    }
    #expect(owner != BrowserSyncOwner(baseURL: owner.baseURL, userID: "USER-1"))
}

@Test func syncOwnerCodableNormalizationAndCredentialRotationPreserveIdentity() throws {
    let url = syncOwnerFixtureURL("https://sync.example/")
    let original = BrowserAuthSession(
        accessToken: "first-secret",
        userID: "user-1",
        userEmail: "old@example.test",
        deviceID: "device-1"
    )
    let refreshed = BrowserAuthSession(
        accessToken: "rotated-secret",
        userID: "user-1",
        userEmail: "new@example.test",
        deviceID: "device-2"
    )
    let owner = BrowserSyncOwner(baseURL: url, userID: original.userID)
    #expect(owner == BrowserSyncOwner(baseURL: url, userID: refreshed.userID))
    #expect(try JSONDecoder().decode(BrowserSyncOwner.self, from: JSONEncoder().encode(owner)) == owner)
    let oldRepresentation = Data(#"{"baseURL":"HTTPS://SYNC.EXAMPLE:443/#ignored","userID":"user-1"}"#.utf8)
    #expect(try JSONDecoder().decode(BrowserSyncOwner.self, from: oldRepresentation) == owner)
}

@Test func sqliteSyncFirstBindingDoesNotAdoptLegacyCursorOrDeleteLocalData() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    // Seed a pre-owner database before the production migrator has created tables.
    let legacy = try DatabaseQueue(path: harness.databaseURL.path)
    try legacy.write { db in
        try db.execute(sql: "CREATE TABLE browser_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute(sql: "INSERT INTO browser_preferences VALUES ('browser.sync.cursor', '9999')")
    }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    let snapshot = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "local-tab",
        urlString: "https://local.example"
    )])
    store.saveSnapshot(snapshot)
    #expect(try store.syncOwner() == nil)
    #expect(store.syncCursor() == 9999)

    try store.bindSyncOwner(harness.owner)
    #expect(try store.syncOwner() == harness.owner)
    #expect(try store.syncCursor(for: harness.owner) == 0)
    #expect(store.syncCursor() == 0)
    #expect(store.loadSnapshot() == snapshot)
    #expect(try !store.isSyncPaused(for: harness.owner))
}

@Test func sqliteSyncOwnerAndCursorSurviveReopeningAndRepeatBinding() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    do {
        let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
        try store.bindSyncOwner(harness.owner)
        try store.saveSyncCursor(42, for: harness.owner)
    }
    let reopened = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    #expect(try reopened.syncOwner() == harness.owner)
    #expect(try reopened.syncCursor(for: harness.owner) == 42)
    let equivalentOwner = BrowserSyncOwner(
        baseURL: syncOwnerFixtureURL("HTTPS://SYNC.EXAMPLE:443/"),
        userID: harness.owner.userID
    )
    try reopened.bindSyncOwner(equivalentOwner)
    #expect(try reopened.syncCursor(for: equivalentOwner) == 42)
    try reopened.saveSyncCursor(21, for: equivalentOwner)
    #expect(try reopened.syncCursor(for: equivalentOwner) == 42)
    reopened.saveSyncCursor(1000)
    #expect(try reopened.syncCursor(for: harness.owner) == 42)
}

@Test func sqliteSyncRejectsAccountAndServerMismatchWithoutMutatingOwnership() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    try store.bindSyncOwner(harness.owner)
    try store.saveSyncCursor(21, for: harness.owner)
    try store.pauseSync()
    let others = [
        BrowserSyncOwner(baseURL: harness.owner.baseURL, userID: "other-user"),
        BrowserSyncOwner(
            baseURL: syncOwnerFixtureURL("https://another-server.example"),
            userID: harness.owner.userID
        ),
    ]
    for owner in others {
        #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.bindSyncOwner(owner) }
        #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.syncCursor(for: owner) }
        #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.saveSyncCursor(99, for: owner) }
        #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.isSyncPaused(for: owner) }
        #expect(throws: BrowserSyncStoreError.ownerMismatch) { try store.resumeSync(for: owner) }
    }
    #expect(try store.syncOwner() == harness.owner)
    #expect(try store.syncCursor(for: harness.owner) == 21)
    #expect(try store.isSyncPaused(for: harness.owner))
}

@Test func sqliteSyncPauseSurvivesReopeningAndOnlyExplicitResumeClearsIt() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    do {
        let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
        try store.bindSyncOwner(harness.owner)
        try store.saveSyncCursor(42, for: harness.owner)
        try store.pauseSync()
    }
    do {
        let reopened = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
        try reopened.bindSyncOwner(harness.owner)
        #expect(try reopened.isSyncPaused(for: harness.owner))
        #expect(try reopened.syncCursor(for: harness.owner) == 42)
        try reopened.resumeSync(for: harness.owner)
    }
    let resumed = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    #expect(try !resumed.isSyncPaused(for: harness.owner))
    #expect(try resumed.syncCursor(for: harness.owner) == 42)
}

@Test func sqliteSyncRequiresBindingAndRejectsNegativeCursors() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    try store.pauseSync()
    #expect(try store.syncOwner() == nil)
    #expect(throws: BrowserSyncStoreError.ownerNotBound) { try store.syncCursor(for: harness.owner) }
    #expect(throws: BrowserSyncStoreError.ownerNotBound) { try store.saveSyncCursor(1, for: harness.owner) }
    #expect(throws: BrowserSyncStoreError.ownerNotBound) { try store.isSyncPaused(for: harness.owner) }
    #expect(throws: BrowserSyncStoreError.ownerNotBound) { try store.resumeSync(for: harness.owner) }
    try store.bindSyncOwner(harness.owner)
    try store.saveSyncCursor(21, for: harness.owner)
    #expect(throws: BrowserSyncStoreError.invalidCursor) { try store.saveSyncCursor(-1, for: harness.owner) }
    #expect(try store.syncCursor(for: harness.owner) == 21)
}

@Test func sqliteSyncBindingAndLegacyCursorResetAreOneTransaction() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    store.saveSyncCursor(1234)
    let database = try DatabaseQueue(path: harness.databaseURL.path)
    try database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_cursor_reset BEFORE UPDATE ON browser_preferences
        WHEN OLD.key = 'browser.sync.cursor'
        BEGIN SELECT RAISE(ABORT, 'injected cursor failure'); END
        """)
    }
    #expect(throws: DatabaseError.self) { try store.bindSyncOwner(harness.owner) }
    #expect(try store.syncOwner() == nil)
    #expect(store.syncCursor() == 1234)
    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_cursor_reset") }
    try store.bindSyncOwner(harness.owner)
    #expect(try store.syncCursor(for: harness.owner) == 0)
}

@Test func sqliteSyncOtherConnectionCannotReplaceAlreadyClaimedProfile() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let first = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    let second = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    #expect(try first.syncOwner() == nil)
    #expect(try second.syncOwner() == nil)
    try first.bindSyncOwner(harness.owner)
    let other = BrowserSyncOwner(baseURL: harness.owner.baseURL, userID: "other-user")
    #expect(throws: BrowserSyncStoreError.ownerMismatch) { try second.bindSyncOwner(other) }
    #expect(try second.syncOwner() == harness.owner)
}

@Test func sqliteSyncSnapshotAndCursorCommitAtomicallyAndSurfaceWriteFailure() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    let original = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "original", urlString: "https://original.example"
    )])
    let replacement = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "replacement", urlString: "https://replacement.example"
    )])
    try store.bindSyncOwner(harness.owner)
    try store.saveSyncSnapshot(original, cursor: 42, for: harness.owner)
    let database = try DatabaseQueue(path: harness.databaseURL.path)
    try database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_remote_snapshot BEFORE INSERT ON browser_tabs
        WHEN NEW.id = 'replacement'
        BEGIN SELECT RAISE(ABORT, 'injected remote snapshot failure'); END
        """)
    }
    #expect(throws: DatabaseError.self) {
        try store.saveSyncSnapshot(replacement, cursor: 99, for: harness.owner)
    }
    #expect(store.loadSnapshot() == original)
    #expect(try store.syncCursor(for: harness.owner) == 42)
    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_remote_snapshot") }
    try store.saveSyncSnapshot(replacement, cursor: 99, for: harness.owner)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    #expect(reopened.loadSnapshot() == replacement)
    #expect(try reopened.syncCursor(for: harness.owner) == 99)
}

@Test func sqliteSyncSnapshotRejectsForeignOwnerAndInvalidCursorBeforeAnyWrite() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    let original = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "original", urlString: "https://original.example"
    )])
    let replacement = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "replacement", urlString: "https://replacement.example"
    )])
    try store.bindSyncOwner(harness.owner)
    try store.saveSyncSnapshot(original, cursor: 42, for: harness.owner)
    let other = BrowserSyncOwner(baseURL: harness.owner.baseURL, userID: "other-user")
    #expect(throws: BrowserSyncStoreError.ownerMismatch) {
        try store.saveSyncSnapshot(replacement, cursor: 99, for: other)
    }
    #expect(throws: BrowserSyncStoreError.invalidCursor) {
        try store.saveSyncSnapshot(replacement, cursor: -1, for: harness.owner)
    }
    #expect(store.loadSnapshot() == original)
    #expect(try store.syncCursor(for: harness.owner) == 42)
}

@Test func sqliteSyncSnapshotKeepsCursorMonotonicAndReceiptsDoNotAdvanceIt() throws {
    let harness = try SQLiteSyncOwnerHarness()
    defer { harness.cleanup() }
    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    try store.bindSyncOwner(harness.owner)
    let original = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "original", urlString: "https://original.example"
    )])
    let replacement = BrowserTabSessionSnapshot(tabs: [BrowserTabSessionSnapshotTab(
        id: "replacement", urlString: "https://replacement.example"
    )])
    try store.saveSyncSnapshot(original, cursor: 42, for: harness.owner)
    try store.saveSyncSnapshot(replacement, cursor: 21, for: harness.owner)
    #expect(store.loadSnapshot() == replacement)
    #expect(try store.syncCursor(for: harness.owner) == 42)
    try store.saveSyncSnapshot(original, cursor: nil, for: harness.owner)
    #expect(store.loadSnapshot() == original)
    #expect(try store.syncCursor(for: harness.owner) == 42)
}

// MARK: - SQLiteSyncOwnerHarness

private struct SQLiteSyncOwnerHarness {
    // MARK: Lifecycle

    init() throws {
        self.directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenArcSyncOwnerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.databaseURL = directoryURL.appendingPathComponent("Browser.sqlite")
        self.owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "user-1")
    }

    // MARK: Internal

    let databaseURL: URL
    let owner: BrowserSyncOwner

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: Private

    private let directoryURL: URL
}

private func syncOwnerFixtureURL(_ string: String) -> URL {
    URL(string: string)!
}
