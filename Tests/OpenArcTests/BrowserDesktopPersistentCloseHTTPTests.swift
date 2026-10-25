// BrowserDesktopPersistentCloseHTTPTests.swift

import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func persistentCloseConfirmsHomeResetAndReplaysWithoutDeletingIdentity() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("desktop-persistent-close")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let activity = ISO8601DateFormatter().string(from: now)
        let home = "https://persistent-close.example/home"
        let away = "https://persistent-close.example/away"
        let favoriteURL = "https://persistent-close.example/favorite"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: session)
        let device = account.devices[0]
        let auth = BrowserAuthSession(
            accessToken: device.accessToken, userID: device.userID, userEmail: nil,
            deviceID: device.deviceID, serverURL: fixture.baseURL,
        )
        _ = try await remote.push(mutation: BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Persistent Close", systemImageName: "globe")),
            .createTab(id: "favorite", data: .init(
                spaceID: "source", placement: .app, urlString: favoriteURL,
                userTitleOverride: "Favorite title", lastActivityAt: activity,
            )),
            .createTab(id: "pinned", data: .init(
                spaceID: "source", placement: .spacePinned, urlString: away, pinnedURLString: home,
                userTitleOverride: "Pinned title", lastActivityAt: activity,
            )),
            .createTab(id: "anchor", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://persistent-close.example/anchor",
                lastActivityAt: activity,
            )),
        ]), authSession: auth)
        await first.activate()
        await second.activate()
        let live = try PersistentCloseHTTPModel(profile: first, now: now)
        defer { live.close() }
        let pinned = try #require(live.model.tabs.first { $0.syncID == "pinned" })
        let favorite = try #require(live.model.tabs.first { $0.syncID == "favorite" })
        let anchor = try #require(live.model.tabs.first { $0.syncID == "anchor" })
        live.model.selectTab(id: anchor.id)
        live.driver.emitNavigationStateChange(id: anchor.id, canGoBack: true, canGoForward: true)
        await first.service.waitForPendingOperations()
        await second.pull()
        let before = try #require(try first.store.loadSnapshotStrict())
        let initial = try await fixture.inspect(account)
        let created = live.driver.createdTabRequests
        let ids = live.model.tabs.map(\.syncID)
        let databaseURL = directory.appendingPathComponent(device.deviceID + ".sqlite")

        // A background Favorite avoids unrelated selection/activity writes.
        // Neither Cancel nor confirmed unload changes its logical content.
        #expect(live.model.closeAppTabProcess(id: favorite.id))
        let favoriteCancelled = try #require(live.driver.confirmedCloseRequests.last)
        #expect(favoriteCancelled.id == favorite.id)
        #expect(try first.store.loadSnapshotStrict() == before)
        live.driver.emitCloseRequestOutcome(
            id: favorite.id, requestID: favoriteCancelled.requestID, outcome: .cancelled,
        )
        #expect(live.model.closeAppTabProcess(id: favorite.id))
        let favoriteConfirmed = try #require(live.driver.confirmedCloseRequests.last)
        #expect(favoriteConfirmed.requestID != favoriteCancelled.requestID)
        live.driver.emitCloseRequestOutcome(
            id: favorite.id, requestID: favoriteConfirmed.requestID, outcome: .closed,
        )
        #expect(live.model.tabs.first { $0.syncID == "favorite" }?.id == favorite.id)
        #expect(live.model.tabs.first { $0.syncID == "favorite" }?.urlString == favoriteURL)
        #expect(live.model.selectedTabID == anchor.id && live.model.tabs.map(\.syncID) == ids)
        #expect(live.driver.createdTabRequests == created)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        await first.service.waitForPendingOperations()
        let afterFavorite = try await fixture.inspect(account)
        #expect(afterFavorite.eventCount == initial.eventCount && afterFavorite.attempts.count == initial.attempts
            .count)

        #expect(live.model.closePinnedTabProcessOrReset(id: pinned.id))
        let cancelled = try #require(live.driver.confirmedCloseRequests.last)
        #expect(cancelled.id == pinned.id)
        #expect(live.model.tabs.first { $0.syncID == "pinned" }?.urlString == away)
        #expect(try first.store.loadSnapshotStrict() == before)
        live.driver.emitCloseRequestOutcome(id: pinned.id, requestID: cancelled.requestID, outcome: .cancelled)
        await first.service.waitForPendingOperations()
        await second.pull()
        let afterCancel = try await fixture.inspect(account)
        #expect(afterCancel.eventCount == initial.eventCount && afterCancel.receiptCount == initial.receiptCount)
        #expect(afterCancel.attempts.count == initial.attempts.count)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(second.store.loadSnapshot()?.tabs == before.tabs)
        #expect(live.model.tabs.first { $0.syncID == "pinned" }?.id == pinned.id)
        #expect(live.model.tabs.first { $0.syncID == "pinned" }?.urlString == away)

        #expect(live.model.closePinnedTabProcessOrReset(id: pinned.id))
        let confirmed = try #require(live.driver.confirmedCloseRequests.last)
        #expect(confirmed.id == pinned.id && confirmed.requestID != cancelled.requestID)
        try persistentCloseHTTPSQL(databaseURL, """
        CREATE TRIGGER fail_persistent_home_reset BEFORE INSERT ON browser_sync_outbox
        BEGIN SELECT RAISE(ABORT,'injected persistent reset failure'); END
        """)
        live.driver.emitCloseRequestOutcome(id: pinned.id, requestID: confirmed.requestID, outcome: .closed)
        #expect(live.model.hasUncommittedSessionWrites && live.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(live.model.tabs.first { $0.syncID == "pinned" }?.id == pinned.id)
        #expect(live.model.tabs.first { $0.syncID == "pinned" }?.urlString == home)
        #expect(live.model.tabs.first { $0.syncID == "pinned" }?.pinnedURLString == home)
        #expect(live.model.tabs.map(\.syncID) == ids && live.model.selectedTabID == anchor.id)
        #expect(live.model.canGoBack && live.model.canGoForward)
        #expect(live.driver.createdTabRequests == created)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        live.model.setUserTitleOverride("Later surviving edit", forTabID: anchor.id)
        #expect(!live.model.retrySessionPersistence())
        live.driver.emitCloseRequestOutcome(id: pinned.id, requestID: confirmed.requestID, outcome: .closed)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        await first.service.waitForPendingOperations()
        await second.pull()
        let failed = try await fixture.inspect(account)
        #expect(failed.eventCount == initial.eventCount && failed.attempts.count == initial.attempts.count)
        #expect(second.store.loadSnapshot()?.tabs == before.tabs)

        try persistentCloseHTTPSQL(databaseURL, "DROP TRIGGER fail_persistent_home_reset")
        try await fixture.command("drop", deviceID: device.deviceID)
        #expect(live.model.retrySessionPersistence())
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        try #require(pending.count == 2)
        guard case .folders(let reset) = pending[0], case .folders(let later) = pending[1] else {
            Issue.record("Persistent reset and its later edit must retain ordinary v4 FIFO mutations")
            return
        }
        #expect(reset.operations == [.patchTab(id: "pinned", fields: .init(urlString: home))])
        #expect(later.operations == [.patchTab(
            id: "anchor",
            fields: .init(userTitleOverride: .set("Later surviving edit")),
        )])
        let bytes = try persistentCloseHTTPOutbox(databaseURL)
        #expect(try first.store.loadSnapshotStrict()?.tabs.first { $0.id == "pinned" }?.urlString == home)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        await first.service.waitForPendingOperations()
        await second.pull()
        let sent = try await fixture.inspect(account)
        let lost = try #require(sent.attempts.last { $0.mutationID == reset.id })
        #expect(lost.status == 201 && lost.protocolVersion == 4)
        #expect(sent.tabs.allSatisfy { !$0.deleted && !$0.tombstoned })
        #expect(second.store.loadSnapshot()?.tabs.first { $0.id == "pinned" }?.urlString == home)
        #expect(second.store.loadSnapshot()?.tabs.first { $0.id == "favorite" }?.urlString == favoriteURL)
        #expect(try first.store.pendingSyncQueue(for: first.owner) == pending)
        #expect(try persistentCloseHTTPOutbox(databaseURL) == bytes)
        #expect(try second.store.loadArchivePage().entries.isEmpty)

        await first.disconnect()
        live.close()
        try await fixture.command("release", deviceID: device.deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: device, directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == pending)
        #expect(try persistentCloseHTTPOutbox(databaseURL) == bytes)
        let rehydrated = try PersistentCloseHTTPModel(profile: reopened, now: now)
        defer { rehydrated.close() }
        await reopened.activate()
        await second.pull()
        let final = try await fixture.inspect(account)
        let retries = final.attempts.filter { $0.mutationID == reset.id }
        #expect(retries.count >= 2 && Set(retries.map(\.digest)) == [lost.digest])
        #expect(final.attempts.contains { $0.mutationID == later.id && $0.status == 201 })
        #expect(final.tabs.map(\.id).sorted() == ["anchor", "favorite", "pinned"])
        #expect(final.tabs.allSatisfy { !$0.deleted && !$0.tombstoned })
        for profile in [reopened, second] {
            let snapshot = try #require(try profile.store.loadSnapshotStrict())
            #expect(snapshot.tabs.compactMap(\.id) == ids)
            #expect(snapshot.tabs.first { $0.id == "pinned" }?.urlString == home)
            #expect(snapshot.tabs.first { $0.id == "pinned" }?.pinnedURLString == home)
            #expect(snapshot.tabs.first { $0.id == "pinned" }?.userTitleOverride == "Pinned title")
            #expect(snapshot.tabs.first { $0.id == "favorite" }?.urlString == favoriteURL)
            #expect(snapshot.tabs.first { $0.id == "favorite" }?.placement == .app)
            #expect(snapshot.tabs.first { $0.id == "anchor" }?.userTitleOverride == "Later surviving edit")
            #expect(try profile.store.pendingSyncQueue(for: profile.owner).isEmpty)
            #expect(try profile.store.loadArchivePage().entries.isEmpty)
        }
        #expect(rehydrated.model.tabs.map(\.syncID) == ids)
        #expect(rehydrated.model.tabs.first { $0.id == rehydrated.model.selectedTabID }?.syncID == "anchor")
        await reopened.disconnect()
        await second.disconnect()
        try await fixture.complete(account)
    }
}

// MARK: - PersistentCloseHTTPModel

@MainActor private final class PersistentCloseHTTPModel {
    // MARK: Internal

    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()

    // MARK: Private

    private let profile: SyncHTTPProfile
    private let defaults: UserDefaults
    private let suite = "PersistentCloseHTTPModel.\(UUID())"
    private var closed = false

    init(profile: SyncHTTPProfile, now: Date) throws {
        self.profile = profile
        self.defaults = try #require(UserDefaults(suiteName: suite))
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: profile.service,
            dateProvider: { now }, windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
        driver.automaticallyConfirmsCloseRequests = false
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        profile.service.setSnapshotApplier(model)
    }

    func close() {
        guard !closed else { return }
        closed = true
        profile.service.setSnapshotApplier(nil)
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor private func persistentCloseHTTPSQL(_ url: URL, _ sql: String) throws {
    try DatabaseQueue(path: url.path).write { try $0.execute(sql: sql) }
}

@MainActor private func persistentCloseHTTPOutbox(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read {
        try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}
