import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func confirmedDesktopCloseRetriesDeletionAndUndoConvergesWithFreshIdentity() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("desktop-confirmed-close")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let remote = try BrowserRemoteSyncClient(
            configuration: #require(BrowserSyncConfiguration(baseURL: fixture.baseURL)), session: session
        )
        let auth = account.devices.map { device in
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL
            )
        }
        _ = try await remote.push(mutation: BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Confirmed Close", systemImageName: "globe")),
            .createTab(id: "anchor", data: .init(
                spaceID: "source", placement: .spacePinned, urlString: "https://confirmed-close.example/anchor",
                pinnedURLString: "https://confirmed-close.example/home"
            )),
            .createTab(id: "closed", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://confirmed-close.example/closed",
                userTitleOverride: "Saved close title"
            )),
        ]), authSession: auth[0])
        await first.activate()
        await second.activate()
        let live = try ConfirmedCloseHTTPModel(profile: first, now: now)
        defer { live.close() }
        let closing = try #require(live.model.tabs.first { $0.syncID == "closed" })
        let anchor = try #require(live.model.tabs.first { $0.syncID == "anchor" })
        live.model.selectTab(id: closing.id)
        live.driver.emitUpdate(id: closing.id, title: "Latest live page title")
        live.driver.emitNavigationStateChange(id: anchor.id, canGoBack: true, canGoForward: true)
        await first.service.waitForPendingOperations()
        await second.pull()
        live.model.undoManager.removeAllActions()
        let initial = try #require(first.store.loadSnapshot())
        let before = try await fixture.inspect(account)
        let created = live.driver.createdTabRequests

        #expect(live.model.archiveSelectedTab())
        let cancelled = try #require(live.driver.confirmedCloseRequests.last)
        #expect(cancelled.id == closing.id)
        #expect(first.store.loadSnapshot() == initial)
        #expect(live.model.selectedTabID == closing.id)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(!live.model.undoManager.canUndo)
        live.driver.emitCloseRequestOutcome(id: cancelled.id, requestID: cancelled.requestID, outcome: .cancelled)
        await first.service.waitForPendingOperations()
        await second.pull()
        let afterCancel = try await fixture.inspect(account)
        #expect(afterCancel.eventCount == before.eventCount && afterCancel.receiptCount == before.receiptCount)
        #expect(afterCancel.attempts.count == before.attempts.count)
        #expect(first.store.loadSnapshot() == initial && second.store.loadSnapshot()?.tabs == initial.tabs)
        #expect(live.model.selectedTabID == closing.id && live.driver.createdTabRequests == created)
        #expect(!live.model.undoManager.canUndo && !live.model.undoManager.canRedo)

        #expect(live.model.archiveSelectedTab())
        let confirmed = try #require(live.driver.confirmedCloseRequests.last)
        #expect(confirmed.requestID != cancelled.requestID)
        let databaseURL = directory.appendingPathComponent(account.devices[0].deviceID + ".sqlite")
        try confirmedCloseHTTPSQL(databaseURL, """
        CREATE TRIGGER fail_confirmed_close BEFORE INSERT ON browser_sync_outbox
        BEGIN SELECT RAISE(ABORT,'injected close failure'); END
        """)
        live.driver.emitCloseRequestOutcome(id: confirmed.id, requestID: confirmed.requestID, outcome: .closed)
        #expect(live.model.tabs.map(\.syncID) == ["anchor"] && live.model.selectedTabID == anchor.id)
        #expect(live.model.canGoBack && live.model.canGoForward)
        #expect(live.driver.createdTabRequests == created)
        #expect(live.model.undoManager.canUndo)
        #expect(live.model.hasUncommittedSessionWrites)
        #expect(first.store.loadSnapshot() == initial)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        live.driver.emitCloseRequestOutcome(id: confirmed.id, requestID: confirmed.requestID, outcome: .closed)
        #expect(first.store.loadSnapshot() == initial)
        await first.service.waitForPendingOperations()
        await second.pull()
        let failed = try await fixture.inspect(account)
        #expect(failed.eventCount == before.eventCount && failed.receiptCount == before.receiptCount)
        #expect(failed.attempts.count == before.attempts.count)
        #expect(second.store.loadSnapshot()?.tabs == initial.tabs)

        try confirmedCloseHTTPSQL(databaseURL, "DROP TRIGGER fail_confirmed_close")
        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        #expect(live.model.retrySessionPersistence())
        let deletionQueue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(deletionQueue.count == 1)
        guard case .folders(let deletion) = deletionQueue[0] else {
            Issue.record("Confirmed close must atomically capture one v4 delete")
            return
        }
        #expect(deletion.operations == [.deleteTab(id: "closed")])
        let deletionBytes = try confirmedCloseHTTPOutbox(databaseURL)
        await first.service.waitForPendingOperations()
        await second.pull()
        let closed = try await fixture.inspect(account)
        let lost = try #require(closed.attempts.last { $0.mutationID == deletion.id })
        #expect(lost.status == 201 && lost.protocolVersion == 4)
        #expect(closed.tabs.first { $0.id == "closed" }?.tombstoned == true)
        #expect(second.store.loadSnapshot()?.tabs.compactMap(\.id) == ["anchor"])
        #expect(try first.store.pendingSyncQueue(for: first.owner) == deletionQueue)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == deletionBytes)

        // This stage keeps the existing Undo implementation. It restores a new
        // incarnation behind the possibly committed delete, without rewriting
        // that immutable head or inventing a durable Archive entry.
        live.model.undoManager.undo()
        let undone = try #require(live.model.tabs.first { $0.syncID != "anchor" })
        #expect(undone.syncID != "closed" && undone.id != closing.id)
        #expect(undone.urlString == closing.urlString && undone.userTitleOverride == "Saved close title")
        #expect(live.model.selectedTabID == undone.id)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.id == anchor.id)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.canGoBack == true)
        live.driver.flushPendingCreateEvents()
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        try #require(pending.count == 2 && pending.first == deletionQueue.first)
        guard case .folders(let restoration) = pending[1] else {
            Issue.record("Undo must append an ordinary fresh-ID creation after the frozen delete")
            return
        }
        #expect(restoration.operations.contains { operation in
            if case .createTab(let id, let data, _, _) = operation {
                return id == undone.syncID && data.base.urlString == closing.urlString
            }
            return false
        })
        let bytes = try confirmedCloseHTTPOutbox(databaseURL)
        #expect(Array(bytes.prefix(1)) == deletionBytes)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        await first.service.waitForPendingOperations()
        #expect(try first.store.pendingSyncQueue(for: first.owner) == pending)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == bytes)

        await first.disconnect()
        live.close()
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == pending)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == bytes)
        let rehydrated = try ConfirmedCloseHTTPModel(profile: reopened, now: now)
        defer { rehydrated.close() }
        await reopened.activate()
        await second.pull()
        let converged = try await fixture.inspect(account)
        let retries = converged.attempts.filter { $0.mutationID == deletion.id }
        #expect(retries.count >= 2 && Set(retries.map(\.digest)) == [lost.digest])
        #expect(converged.attempts.contains { $0.mutationID == restoration.id && $0.status == 201 })
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        for profile in [reopened, second] {
            #expect(profile.store.loadSnapshot()?.tabs.first { $0.id == undone.syncID }?.urlString == closing.urlString)
            #expect(profile.store
                .loadSnapshot()?
                .tabs
                .first { $0.id == undone.syncID }?
                .userTitleOverride == "Saved close title")
            #expect(profile.store.loadSnapshot()?.tabs.contains { $0.id == "closed" } == false)
            #expect(try profile.store.loadArchivePage().entries.isEmpty)
        }
        #expect(rehydrated.model.tabs.first { $0.id == rehydrated.model.selectedTabID }?.syncID == undone.syncID)

        let receipt = try await remote.push(mutation: deletion, authSession: auth[1])
        #expect(receipt.events.contains { $0.entityID == "closed" && $0.op == "delete" })
        let stale = try await remote.push(mutation: BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .patchTab(id: "closed", fields: .init(urlString: "https://confirmed-close.example/stale")),
        ]), authSession: auth[1])
        #expect(stale.outcomes == [.init(operationIndex: 0, status: .deleted, reason: nil)])
        #expect(stale.events.contains { $0.entityID == "closed" && $0.op == "delete" })
        await reopened.pull()
        await second.pull()
        let final = try await fixture.inspect(account)
        #expect(final.eventCount == converged.eventCount, "Old delete replay and stale edits must append no live event")
        #expect(final.tabs.first { $0.id == "closed" }?.tombstoned == true)
        #expect(Set(final.tabs.filter { !$0.deleted }.map(\.id)) == ["anchor", undone.syncID])
        #expect(try reopened.store.loadArchivePage().entries.isEmpty)
        await reopened.disconnect()
        await second.disconnect()
        rehydrated.close()
        let finalStore = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(finalStore.loadSnapshot()?.tabs.filter { $0.id == undone.syncID }.count == 1)
        #expect(finalStore.loadSnapshot()?.tabs.contains { $0.id == "closed" } == false)
        #expect(try finalStore.loadArchivePage().entries.isEmpty)
        try await fixture.complete(account)
    }
}

// MARK: - ConfirmedCloseHTTPModel

@MainActor private final class ConfirmedCloseHTTPModel {
    // MARK: Lifecycle

    init(profile: SyncHTTPProfile, now: Date) throws {
        self.profile = profile
        self.defaults = try #require(UserDefaults(suiteName: suite))
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: profile.service,
            dateProvider: { now }, windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        driver.automaticallyConfirmsCloseRequests = false
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        profile.service.setSnapshotApplier(model)
    }

    // MARK: Internal

    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()

    func close() {
        guard !closed else { return }
        closed = true
        profile.service.setSnapshotApplier(nil)
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Private

    private let profile: SyncHTTPProfile
    private let defaults: UserDefaults
    private let suite = "ConfirmedCloseHTTPModel.\(UUID())"
    private var closed = false
}

@MainActor private func confirmedCloseHTTPSQL(_ url: URL, _ sql: String) throws {
    try DatabaseQueue(path: url.path).write { try $0.execute(sql: sql) }
}

@MainActor private func confirmedCloseHTTPOutbox(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read {
        try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}
