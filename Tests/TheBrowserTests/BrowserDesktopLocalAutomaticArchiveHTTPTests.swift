import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func failedLocalAutomaticArchiveMustRecoverBeforeFirstSyncAdoption() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("desktop-local-auto-archive")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LocalAutomaticArchiveHTTPProfile(
            fixture: fixture, device: account.devices[0], directory: directory
        )
        defer { first.close() }
        let selected = try #require(first.model.tabs.first { $0.syncID == "active" })
        let expiring = try #require(first.model.tabs.first { $0.syncID == "expired" })
        let before = try #require(try first.store.loadSnapshotStrict())
        let created = first.driver.createdTabRequests
        #expect(first.model.selectedTabID == selected.id)
        #expect(first.model.temporaryTabLifetime == .thirtyDays)
        #expect(try first.store.syncOwner() == nil)
        #expect(try first.outboxBytes().isEmpty)

        // Use the actual local timer entry point, with one deferred engine
        // outcome. Before confirmation the tab is still a live logical row.
        first.clock.now += 30 * 24 * 60 * 60
        first.model.archiveExpiredTemporaryTabs()
        let request = try #require(first.driver.confirmedCloseRequests.last)
        #expect(request.id == expiring.id && first.driver.confirmedCloseRequests.count == 1)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(first.model.tabs.contains { $0.syncID == "expired" })
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        try first.sql("""
        CREATE TRIGGER fail_local_automatic_archive BEFORE INSERT ON browser_tab_archive
        BEGIN SELECT RAISE(ABORT,'injected local automatic Archive failure'); END
        """)
        first.driver.emitCloseRequestOutcome(id: request.id, requestID: request.requestID, outcome: .closed)
        #expect(first.model.hasUncommittedSessionWrites && first.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(!first.model.tabs.contains { $0.syncID == "expired" })
        #expect(first.model.selectedTabID == selected.id && first.driver.createdTabRequests == created)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(try first.store.loadArchivePage().entries.isEmpty)

        first.model.setUserTitleOverride("Survivor edited during local recovery", forTabID: selected.id)
        #expect(throws: BrowserSyncAccountError.localPersistenceBlocked) {
            try first.service.enableSync(for: first.auth.session)
        }
        first.account.enableSync()
        #expect(first.account.bindingState == .needsConsent)
        #expect(first.account.lastError == BrowserStrings.sessionRecoveryRetryMessage)
        first.model.archiveExpiredTemporaryTabs()
        #expect(first.driver.confirmedCloseRequests.count == 1)
        #expect(!first.model.retrySessionPersistence())
        #expect(try first.store.syncOwner() == nil)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(try first.outboxBytes().isEmpty)
        first.service.schedulePull()
        await first.service.waitForPendingOperations()
        let blocked = try await fixture.inspect(account)
        #expect(blocked.attempts.isEmpty && blocked.tabs.isEmpty)
        #expect(blocked.eventCount == 0 && blocked.receiptCount == 0)
        #expect(blocked.observedPulls.isEmpty)

        try first.sql("DROP TRIGGER fail_local_automatic_archive")
        #expect(first.model.retrySessionPersistence())
        #expect(!first.model.hasUncommittedSessionWrites && !first.model.undoManager.canUndo)
        #expect(try first.store.syncOwner() == nil)
        #expect(try first.outboxBytes().isEmpty)
        let recovered = try #require(try first.store.loadSnapshotStrict())
        #expect(recovered.tabs.compactMap(\.id) == ["pinned", "active"])
        #expect(recovered.tabs.first { $0.id == "active" }?.userTitleOverride ==
            "Survivor edited during local recovery")
        let entry = try #require(try first.store.loadArchivePage().entries.first)
        #expect(entry.tab == before.tabs.first { $0.id == "expired" })
        #expect(entry.archivedAt == first.clock.now)
        let recoveredOnDisk = try BrowserSQLiteSessionStore(databaseURL: first.databaseURL)
        #expect(try recoveredOnDisk.syncOwner() == nil)
        #expect(try recoveredOnDisk.loadSnapshotStrict() == recovered)
        #expect(try recoveredOnDisk.loadArchivePage().entries == [entry])

        // The first binding can now seed only the committed surviving tabs.
        // Losing that seed's ACK must not reintroduce the old local identity.
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        first.account.enableSync()
        #expect(first.account.bindingState == .enabled && first.account.lastError == nil)
        #expect(try first.store.syncOwner() == first.owner)
        let seed = try first.store.pendingSyncMutations(for: first.owner)
        try #require(seed.count == 1)
        #expect(seed.flatMap(\.changes).filter { $0.entityType == .tab }.map(\.entityID) == ["pinned", "active"])
        #expect(!seed.flatMap(\.changes).contains { $0.entityID == "expired" || $0.op == .delete })
        let seedBytes = try first.outboxBytes()
        await first.service.waitForPendingOperations()
        let sent = try await fixture.inspect(account)
        let lost = try #require(sent.attempts.last { $0.mutationID == seed[0].id })
        #expect(lost.status == 201 && lost.protocolVersion == 2)
        #expect(try first.store.pendingSyncMutations(for: first.owner) == seed)
        #expect(try first.outboxBytes() == seedBytes)
        #expect(first.model.tabs.first { $0.syncID == "active" }?.id == selected.id)
        #expect(first.model.selectedTabID == selected.id && first.driver.createdTabRequests == created)

        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        await second.activate()
        #expect(second.store.loadSnapshot()?.tabs.compactMap(\.id) == ["pinned", "active"])
        #expect(try second.store.loadArchivePage().entries.isEmpty)
        first.close()
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncMutations(for: reopened.owner) == seed)
        #expect(try first.outboxBytes() == seedBytes)
        #expect(try reopened.store.loadArchivePage().entries == [entry])
        await reopened.activate()
        await second.pull()
        let final = try await fixture.inspect(account)
        let retries = final.attempts.filter { $0.mutationID == seed[0].id }
        #expect(retries.count >= 2 && Set(retries.map(\.digest)) == [lost.digest])
        #expect(final.tabs.map(\.id).sorted() == ["active", "pinned"])
        #expect(final.tabs.allSatisfy { !$0.deleted && !$0.tombstoned })
        for profile in [reopened, second] {
            #expect(try profile.store.syncPullProtocolVersion(for: profile.owner) == 5)
            #expect(try profile.store.pendingSyncQueue(for: profile.owner).isEmpty)
            #expect(profile.store.loadSnapshot()?.tabs.compactMap(\.id) == ["pinned", "active"])
            #expect(profile.store.loadSnapshot()?.tabs.first { $0.id == "active" }?.userTitleOverride ==
                "Survivor edited during local recovery")
        }
        #expect(try reopened.store.loadArchivePage().entries == [entry])
        #expect(try second.store.loadArchivePage().entries.isEmpty)
        await reopened.disconnect()
        await second.disconnect()
        let finalDisk = try BrowserSQLiteSessionStore(databaseURL: first.databaseURL)
        #expect(try finalDisk.loadArchivePage().entries == [entry])
        #expect(try finalDisk.loadSnapshotStrict()?.tabs.compactMap(\.id) == ["pinned", "active"])
        try await fixture.complete(account)
    }
}

// MARK: - LocalAutomaticArchiveHTTPProfile

@MainActor private final class LocalAutomaticArchiveHTTPProfile {
    // MARK: Lifecycle

    init(fixture: SyncHTTPFixture, device: SyncHTTPFixture.Device, directory: URL) throws {
        self.databaseURL = directory.appendingPathComponent(device.deviceID + ".sqlite")
        self.owner = BrowserSyncOwner(baseURL: fixture.baseURL, userID: device.userID)
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try store.writeSessionBatch([.init(snapshot: .init(
            spaces: [.init(id: "source", title: "Local", systemImageName: "globe", selectedTabIndex: 1)],
            tabs: [
                .init(
                    id: "pinned",
                    urlString: "https://local-expiry.example/pinned",
                    placement: .spacePinned,
                    spaceID: "source",
                    lastActivityTimestamp: clock.now
                ),
                .init(
                    id: "active",
                    urlString: "https://local-expiry.example/active",
                    spaceID: "source",
                    lastActivityTimestamp: clock.now
                ),
                .init(
                    id: "expired",
                    urlString: "https://local-expiry.example/expired",
                    userTitleOverride: "Local expired title",
                    spaceID: "source",
                    lastActivityTimestamp: clock.now
                ),
            ]
        ), origin: .local(syncMove: nil))])
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(1)
        self.auth = LocalAutomaticArchiveHTTPAuth(session: .init(
            accessToken: device.accessToken, userID: device.userID, userEmail: nil,
            deviceID: device.deviceID, serverURL: fixture.baseURL
        ))
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let network = URLSessionConfiguration.ephemeral
        network.timeoutIntervalForRequest = 15
        network.timeoutIntervalForResource = 20
        self.urlSession = URLSession(configuration: network)
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: urlSession)
        self.service = BrowserSyncService(
            localStore: store, remoteClient: remote, authSessionStore: auth,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil
        )
        self.defaults = try #require(UserDefaults(suiteName: suite))
        let clock = clock
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: service,
            dateProvider: { Date(timeIntervalSince1970: clock.now) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        driver.automaticallyConfirmsCloseRequests = false
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        service.setSnapshotApplier(model)
        self.account = BrowserAccountStore(
            syncClient: remote, authSessionStore: auth, syncCoordinator: service,
            appleSignInService: LocalAutomaticArchiveHTTPIdentity(),
            deviceIdentity: .init(name: "Local Archive HTTP", platform: "macOS")
        )
    }

    // MARK: Internal

    let databaseURL: URL
    let owner: BrowserSyncOwner
    let store: BrowserSQLiteSessionStore
    let service: BrowserSyncService
    let account: BrowserAccountStore
    let auth: LocalAutomaticArchiveHTTPAuth
    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()
    let clock = LocalAutomaticArchiveHTTPClock()

    func sql(_ sql: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) }
    }

    func outboxBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read {
            try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        service.accountSessionDidChange(nil)
        service.setRuntimeActive(false)
        service.setSnapshotApplier(nil)
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        urlSession.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Private

    private let suite = "LocalAutomaticArchiveHTTP.\(UUID())"
    private let defaults: UserDefaults
    private let urlSession: URLSession
    private var closed = false
}

// MARK: - LocalAutomaticArchiveHTTPClock

@MainActor private final class LocalAutomaticArchiveHTTPClock {
    var now: TimeInterval = 2_000_000
}

// MARK: - LocalAutomaticArchiveHTTPAuth

@MainActor private final class LocalAutomaticArchiveHTTPAuth: BrowserSyncAuthSessionStoring {
    // MARK: Lifecycle

    init(session: BrowserAuthSession) { self.session = session }

    // MARK: Internal

    var session: BrowserAuthSession

    func loadSession() -> BrowserAuthSession? { session }
    func saveSession(_ session: BrowserAuthSession) { self.session = session }
    func clearSession() {}
}

// MARK: - LocalAutomaticArchiveHTTPIdentity

@MainActor private final class LocalAutomaticArchiveHTTPIdentity: BrowserAppleIdentityProviding {
    func requestIdentityToken() throws -> String { throw URLError(.userAuthenticationRequired) }
}
