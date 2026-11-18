// BrowserDesktopArchiveHTTPIntegrationTests.swift

import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func desktopModelRestoresCanonicalArchiveOnceAndReplaysItsLostAcknowledgement() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("desktop-archive-restore")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let remote = try BrowserRemoteSyncClient(
            configuration: #require(BrowserSyncConfiguration(baseURL: fixture.baseURL)), session: session,
        )
        let auth = account.devices.map { device in
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL,
            )
        }
        let seed = BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Desktop Archive", systemImageName: "globe")),
            .createTab(id: "anchor", data: .init(
                spaceID: "source", placement: .spacePinned, urlString: "https://desktop-archive.example/anchor",
                pinnedURLString: "https://desktop-archive.example/home",
                lastActivityAt: "2030-03-17T17:46:40Z",
            )),
            .createTab(id: "expired", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://desktop-archive.example/saved",
                title: "Canonical page title", userTitleOverride: "Saved title",
                lastActivityAt: "2000-01-01T00:00:00Z",
            )),
        ])
        _ = try await remote.push(mutation: seed, authSession: auth[0])
        await first.activate()
        await second.activate()
        #expect(try first.store.syncPullProtocolVersion(for: first.owner) == 6)
        #expect(try second.store.syncPullProtocolVersion(for: second.owner) == 6)

        let live = try DesktopArchiveHTTPModel(profile: first)
        defer { live.close() }
        let anchor = try #require(live.model.tabs.first { $0.syncID == "anchor" })
        let expired = try #require(live.model.tabs.first { $0.syncID == "expired" })
        live.model.selectTab(id: anchor.id)
        live.driver.emitTabCreationState(id: anchor.id, state: .ready)
        live.driver.emitNavigationStateChange(id: anchor.id, canGoBack: true, canGoForward: true)
        await first.service.waitForPendingOperations()
        let current = try await remote.pull(cursor: 0, protocolVersion: 5, authSession: auth[0])
        let source = try #require(current.events.last { $0.entityID == "expired" && $0.op == "upsert" })
        let expiryID = try #require(try first.service.enqueueExpiry(operations: [
            .init(id: "expired", expectedServerSeq: source.serverSeq, inactiveForSeconds: 43200),
        ]))
        let queuedExpiry = try #require(try first.store.pendingSyncQueue(for: first.owner).first)
        guard case .expiry(let expiry) = queuedExpiry else {
            Issue.record("Canonical recovery must come from the production conditional queue")
            return
        }
        #expect(expiry.id == expiryID)
        await first.service.waitForPendingOperations()
        await second.pull()
        let archive = try #require(try first.store.loadArchivePage().entries.first)
        #expect(archive.tab.id == "expired" && archive.tab.urlString == "https://desktop-archive.example/saved")
        #expect(archive.tab.userTitleOverride == "Saved title" && archive.title == "Canonical page title")
        #expect(try second.store.loadArchivePage().entries == [archive])
        #expect(live.model.tabs.map(\.syncID) == ["anchor"])
        #expect(live.model.selectedTabID == anchor.id)
        #expect(live.driver.closedTabRequests.contains { $0.id == expired.id && $0.forceClose })
        live.driver.emitClose(id: expired.id)
        #expect(live.model.canBrowseArchive && live.model.canRestoreArchivedTab)
        #expect(live.model.canGoBack && live.model.canGoForward)
        let requestsBeforeRestore = live.driver.createdTabRequests
        let revisionBeforeRestore = live.model.archiveRevision
        let databaseURL = directory.appendingPathComponent(account.devices[0].deviceID + ".sqlite")

        // Commit-first restoration must not allocate an engine or consume the
        // Archive entry when the atomic snapshot/create/consume transaction fails.
        try desktopArchiveHTTPSQL(databaseURL, """
        CREATE TRIGGER fail_desktop_archive_restore BEFORE INSERT ON browser_tabs
        WHEN NEW.id != 'anchor' BEGIN SELECT RAISE(ABORT,'injected restore failure'); END
        """)
        #expect(live.model.restoreArchivedTab(id: archive.id) == nil)
        #expect(live.model.archiveError != nil)
        #expect(live.model.tabs.map(\.syncID) == ["anchor"])
        #expect(live.model.selectedTabID == anchor.id)
        #expect(live.driver.createdTabRequests == requestsBeforeRestore)
        #expect(try first.store.loadArchivePage().entries == [archive])
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        try desktopArchiveHTTPSQL(databaseURL, "DROP TRIGGER fail_desktop_archive_restore")

        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        let restoredID = try #require(live.model.restoreArchivedTab(id: archive.id))
        let restored = try #require(live.model.tabs.first { $0.syncID == restoredID })
        #expect(restoredID != "expired" && restored.id != expired.id)
        #expect(live.model.selectedTabID == restored.id)
        #expect(restored.urlString == archive.tab.urlString && restored.userTitleOverride == "Saved title")
        #expect(live.model.archiveRevision > revisionBeforeRestore)
        #expect(live.driver.createdTabRequests.count == requestsBeforeRestore.count + 1)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.id == anchor.id)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.canGoBack == true)
        #expect(live.model
            .tabs
            .first { $0.syncID == "anchor" }?
            .pinnedURLString == "https://desktop-archive.example/home")
        #expect(!live.driver.closedTabRequests.contains { $0.id == anchor.id })
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        let restoreQueue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(restoreQueue.count == 1 && restoreQueue[0].protocolVersion == 4)
        let frozen = try desktopArchiveHTTPOutbox(databaseURL)
        let committedBeforeCallback = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(committedBeforeCallback.loadSnapshot()?.tabs.count(where: { $0.id == restoredID }) == 1)
        #expect(try committedBeforeCallback.loadArchivePage().entries.isEmpty)
        #expect(live.model.restoreArchivedTab(id: archive.id) == nil)
        #expect(live.driver.createdTabRequests.count == requestsBeforeRestore.count + 1)
        live.driver.flushPendingCreateEvents()
        #expect(live.model.tabs.filter { $0.syncID == restoredID }.map(\.id) == [restored.id])
        #expect(try desktopArchiveHTTPOutbox(databaseURL) == frozen)

        await first.service.waitForPendingOperations()
        let lost = try await fixture.inspect(account)
        let restoreAttempt = try #require(lost.attempts.last { $0.mutationID == restoreQueue[0].id })
        #expect(restoreAttempt.status == 201 && restoreAttempt.protocolVersion == 4)
        #expect(try first.store.pendingSyncQueue(for: first.owner) == restoreQueue)
        await second.pull()
        #expect(second.store.loadSnapshot()?.tabs.first { $0.id == restoredID }?.urlString == archive.tab.urlString)
        #expect(second.store.loadSnapshot()?.tabs.first { $0.id == restoredID }?.userTitleOverride == "Saved title")
        #expect(second.store.loadSnapshot()?.tabs.contains { $0.id == "expired" } == false)

        await first.disconnect()
        live.close()
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == restoreQueue)
        #expect(try desktopArchiveHTTPOutbox(databaseURL) == frozen)
        let reopenedModel = try DesktopArchiveHTTPModel(profile: reopened)
        defer { reopenedModel.close() }
        let restarted = try #require(reopenedModel.model.tabs.first { $0.syncID == restoredID })
        #expect(reopenedModel.model.selectedTabID == restarted.id)
        await reopened.activate()
        let afterRetry = try await fixture.inspect(account)
        let retries = afterRetry.attempts.filter { $0.mutationID == restoreQueue[0].id }
        #expect(retries.count >= 2 && Set(retries.map(\.digest)) == [restoreAttempt.digest])
        #expect(afterRetry.eventCount == lost.eventCount && afterRetry.receiptCount == lost.receiptCount)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        #expect(try reopened.store.loadArchivePage().entries.isEmpty)
        #expect(reopenedModel.model.restoreArchivedTab(id: archive.id) == nil)

        let receipt = try await remote.push(mutation: expiry, authSession: auth[0])
        let replay = try await remote.push(mutation: expiry, authSession: auth[1])
        #expect(receipt == replay && receipt.outcomes.first?.status == .applied)
        let full = try await remote.pull(cursor: 0, protocolVersion: 5, authSession: auth[0])
        let projected = try reopened.store.completeExpirySyncBootstrap(
            events: full.events, cursor: full.cursor, for: reopened.owner,
        )
        reopenedModel.model.applyRemoteSyncSnapshot(projected)
        reopenedModel.driver.flushPendingCreateEvents()
        await reopened.service.waitForPendingOperations()
        await second.pull()
        #expect(try reopened.store.loadArchivePage().entries.isEmpty)
        #expect(reopenedModel.model.tabs.count(where: { $0.syncID == restoredID }) == 1)
        #expect(reopenedModel.model.tabs.contains { $0.syncID == "expired" } == false)
        let final = try await fixture.inspect(account)
        #expect(final.eventCount == afterRetry.eventCount && final.receiptCount == afterRetry.receiptCount)
        #expect(final.tabs.first { $0.id == "expired" }?.tombstoned == true)
        #expect(Set(final.tabs.filter { !$0.deleted }.map(\.id)) == ["anchor", restoredID])
        await reopened.disconnect()
        await second.disconnect()
        reopenedModel.close()
        let finalStore = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try finalStore.loadArchivePage().entries.isEmpty)
        #expect(finalStore.loadSnapshot()?.tabs.count(where: { $0.id == restoredID }) == 1)
        #expect(finalStore.loadSnapshot()?.tabs.contains { $0.id == "expired" } == false)
        try await fixture.complete(account)
    }
}

// MARK: - DesktopArchiveHTTPModel

@MainActor private final class DesktopArchiveHTTPModel {
    // MARK: Internal

    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()

    // MARK: Private

    private let profile: SyncHTTPProfile
    private let suite = BrowserTestDefaults.suiteName("DesktopArchiveHTTPModel")
    private let defaults: UserDefaults
    private var closed = false

    init(profile: SyncHTTPProfile) throws {
        self.profile = profile
        self.defaults = try #require(UserDefaults(suiteName: suite))
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: profile.service,
            dateProvider: { Date(timeIntervalSince1970: 1_900_000_000) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
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

@MainActor private func desktopArchiveHTTPSQL(_ url: URL, _ sql: String) throws {
    try DatabaseQueue(path: url.path).write { try $0.execute(sql: sql) }
}

@MainActor private func desktopArchiveHTTPOutbox(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read {
        try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}
