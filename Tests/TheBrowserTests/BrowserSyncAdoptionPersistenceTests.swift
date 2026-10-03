import Foundation
import GRDB
import Testing

// MARK: - BrowserSyncAdoptionPersistenceTests

@MainActor @Suite(.serialized) struct BrowserSyncAdoptionPersistenceTests {
    @Test func failedLocalArchiveCannotAcquireSyncOwnerUntilRetryCommits() async throws {
        let f = try SyncAdoptionFixture()
        defer { f.close() }
        let closing = try #require(f.model.tabs.first { $0.syncID == "local-tab" })
        f.model.selectTab(id: closing.id)
        let before = try f.evidence()
        try f.sql("""
        CREATE TRIGGER fail_local_archive BEFORE INSERT ON browser_tab_archive
        BEGIN SELECT RAISE(ABORT, 'injected local Archive failure'); END
        """)
        #expect(f.model.archiveSelectedTab())
        #expect(f.model.hasUncommittedSessionWrites && f.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(!f.model.tabs.contains { $0.syncID == "local-tab" })
        #expect(try f.evidence() == before)

        let session = try #require(f.credentials.session)
        #expect(throws: BrowserSyncAccountError.localPersistenceBlocked) {
            try f.service.enableSync(for: session)
        }
        f.account.enableSync()
        f.account.enableSync()
        #expect(f.account.bindingState == .needsConsent)
        #expect(f.account.lastError == BrowserStrings.sessionRecoveryRetryMessage)
        #expect(f.account.session == f.credentials.session)
        #expect(try f.evidence() == before)
        f.service.schedulePull()
        await f.service.waitForPendingOperations()
        #expect(f.remote.pulls == 0 && f.remote.pushes.isEmpty)
        #expect(!f.model.retrySessionPersistence())
        #expect(try f.evidence() == before)

        try f.sql("DROP TRIGGER fail_local_archive")
        #expect(f.model.retrySessionPersistence())
        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(try f.store.syncOwner() == nil)
        #expect(try f.store.loadSnapshotStrict()?.tabs.compactMap(\.id) == ["anchor"])
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["local-tab"])
        let recovered = try f.evidence()
        #expect(recovered.outbox.isEmpty)

        f.account.enableSync()
        #expect(f.account.bindingState == .enabled && f.account.lastError == nil)
        #expect(try f.store.syncOwner() == f.owner)
        let seeded = try f.store.pendingSyncMutations(for: f.owner)
        try #require(!seeded.isEmpty)
        let changes = seeded.flatMap(\.changes)
        #expect(changes.contains { $0.entityType == .tab && $0.entityID == "anchor" && $0.op == .upsert })
        #expect(!changes.contains { $0.entityID == "local-tab" || $0.op == .delete })
        #expect(try f.store.loadSnapshotStrict() == recovered.snapshot)
        await f.service.waitForPendingOperations()
        #expect(f.remote.pulls > 0 && f.remote.pushes == Array(seeded.prefix(1)))
        #expect(try f.store.pendingSyncMutations(for: f.owner) == seeded, "Lost fake ACK keeps the new seed immutable")
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.syncOwner() == f.owner)
        #expect(try reopened.loadSnapshotStrict() == recovered.snapshot)
        #expect(try reopened.loadArchivePage().entries.map(\.tab.id) == ["local-tab"])
    }

    @Test func blockedAlreadyOwnedProfileCanResumeWithoutRewritingItsQueueOrSending() async throws {
        let f = try SyncAdoptionFixture()
        defer { f.close() }
        f.service.setRuntimeActive(false)
        let session = try #require(f.credentials.session)
        try f.service.enableSync(for: session)
        try f.store.saveSyncCursor(42, for: f.owner)
        f.service.setLocalPersistenceBlocked(true)
        try f.service.suspendSync()
        #expect(try f.service.bindingState(for: session) == .paused)
        let before = try f.evidence()
        let queued = try f.store.pendingSyncMutations(for: f.owner)

        // Enable on an existing owner is idempotent adoption; Resume remains a
        // durable preference change, while the transport's write guard still wins.
        try f.service.enableSync(for: session)
        #expect(try f.service.bindingState(for: session) == .enabled)
        try f.service.suspendSync()
        try f.service.resumeSync(for: session)
        #expect(try f.service.bindingState(for: session) == .enabled)
        #expect(try f.evidence() == before)
        f.service.accountSessionDidChange(session)
        f.service.setRuntimeActive(true)
        f.service.schedulePull()
        await f.service.waitForPendingOperations()
        #expect(f.remote.pulls == 0 && f.remote.pushes.isEmpty)
        #expect(try f.store.syncCursor(for: f.owner) == 42)
        #expect(try f.evidence() == before)

        f.service.setLocalPersistenceBlocked(false)
        await f.service.waitForPendingOperations()
        #expect(f.remote.pulls > 0 && f.remote.pushes == Array(queued.prefix(1)))
        #expect(try f.store.pendingSyncMutations(for: f.owner) == queued)
        #expect(try f.evidence().outbox == before.outbox)
        #expect(try f.store.syncCursor(for: f.owner) == 42)
        #expect(try f.store.syncOwner() == f.owner)
    }
}

// MARK: - SyncAdoptionFixture

@MainActor private final class SyncAdoptionFixture {
    // MARK: Lifecycle

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncAdoption-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try store.writeSessionBatch([.init(snapshot: .init(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe", selectedTabIndex: 1)],
            tabs: [
                .init(
                    id: "anchor",
                    urlString: "https://example.com/anchor",
                    placement: .spacePinned,
                    spaceID: "space",
                    lastActivityTimestamp: 100
                ),
                .init(
                    id: "local-tab",
                    urlString: "https://example.com/local",
                    spaceID: "space",
                    lastActivityTimestamp: 100
                ),
            ]
        ), origin: .local(syncMove: nil))])
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(1)
        let session = BrowserAuthSession(
            accessToken: "fixture-token", userID: owner.userID, userEmail: nil,
            deviceID: "fixture-device", serverURL: owner.baseURL
        )
        self.credentials = SyncAdoptionCredentials(session: session)
        self.service = BrowserSyncService(
            localStore: store, remoteClient: remote, authSessionStore: credentials,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil
        )
        self.defaults = UserDefaults(suiteName: suite)!
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: service,
            dateProvider: { Date(timeIntervalSince1970: 100) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        self.account = BrowserAccountStore(
            syncClient: remote, authSessionStore: credentials, syncCoordinator: service,
            appleSignInService: SyncAdoptionIdentity(), deviceIdentity: .init(name: "Fixture", platform: "macOS")
        )
    }

    // MARK: Internal

    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync-adoption.example")!, userID: "owner")
    let directory: URL
    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let service: BrowserSyncService
    let account: BrowserAccountStore
    let model: BrowserChromeModel
    let credentials: SyncAdoptionCredentials
    let remote = SyncAdoptionRemote()
    let driver = FakeBrowserTabDriver()

    func sql(_ sql: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) }
    }

    func evidence() throws -> SyncAdoptionEvidence {
        let owner = try store.syncOwner()
        let snapshot = try store.loadSnapshotStrict()
        return try DatabaseQueue(path: databaseURL.path).read { db in
            try .init(
                owner: owner, snapshot: snapshot,
                outbox: String.fetchAll(
                    db,
                    sql: "SELECT mutation_id || ':' || hex(payload) FROM browser_sync_outbox ORDER BY position"
                ),
                baseline: Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                archive: Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                receipts: String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id, '') FROM browser_tab_archive_receipts ORDER BY id"
                )
            )
        }
    }

    func close() {
        service.accountSessionDidChange(nil)
        service.setRuntimeActive(false)
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Private

    private let suite = "SyncAdoption.\(UUID())"
    private let defaults: UserDefaults
}

// MARK: - SyncAdoptionEvidence

private struct SyncAdoptionEvidence: Equatable {
    let owner: BrowserSyncOwner?
    let snapshot: BrowserTabSessionSnapshot?
    let outbox: [String]
    let baseline: [Data]
    let archive: [Data]
    let receipts: [String]
}

// MARK: - SyncAdoptionCredentials

@MainActor private final class SyncAdoptionCredentials: BrowserSyncAuthSessionStoring {
    // MARK: Lifecycle

    init(session: BrowserAuthSession) { self.session = session }

    // MARK: Internal

    var session: BrowserAuthSession?

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() { session = nil }
}

// MARK: - SyncAdoptionIdentity

@MainActor private final class SyncAdoptionIdentity: BrowserAppleIdentityProviding {
    func requestIdentityToken() throws -> String { throw URLError(.userAuthenticationRequired) }
}

// MARK: - SyncAdoptionRemote

@MainActor private final class SyncAdoptionRemote: BrowserSyncRemoteServing, BrowserAppleAuthenticating {
    let baseURL = URL(string: "https://sync-adoption.example")!
    var pulls = 0
    var pushes = [BrowserSyncMutation]()

    func authenticateWithApple(
        identityToken _: String,
        deviceName _: String,
        devicePlatform _: String
    ) throws -> BrowserAuthSession {
        throw URLError(.userAuthenticationRequired)
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) -> BrowserSyncPullResponse {
        pulls += 1
        return .init(cursor: cursor, events: [], protocolVersion: 2, supportedPushVersions: [2])
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        pushes.append(mutation)
        throw URLError(.networkConnectionLost)
    }
}
