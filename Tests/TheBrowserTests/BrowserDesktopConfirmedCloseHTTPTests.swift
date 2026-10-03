import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func confirmedDesktopCloseArchivesAndHistoryRetriesConvergeWithFreshIdentities() async throws {
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
        #expect(!live.model.undoManager.canUndo)
        #expect(live.model.hasUncommittedSessionWrites)
        #expect(first.store.loadSnapshot() == initial)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        live.model.setUserTitleOverride("Edited while close was blocked", forTabID: anchor.id)
        #expect(live.model.hasUncommittedSessionWrites)
        #expect(first.store.loadSnapshot() == initial)
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
        try #require(deletionQueue.count == 2)
        guard case .folders(let deletion) = deletionQueue[0] else {
            Issue.record("Confirmed close must atomically capture one v4 delete")
            return
        }
        #expect(deletion.operations == [.deleteTab(id: "closed")])
        let firstArchivePage = try first.store.loadArchivePage()
        try #require(firstArchivePage.entries.count == 1)
        let firstEntry = try #require(firstArchivePage.entries.first)
        #expect(firstEntry.tab == initial.tabs.first { $0.id == "closed" })
        #expect(firstEntry.title == "Latest live page title")
        #expect(live.model.undoManager.canUndo && !live.model.undoManager.canRedo)
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "anchor" }?.userTitleOverride ==
            "Edited while close was blocked")
        let deletionBytes = try confirmedCloseHTTPOutbox(databaseURL)
        await first.service.waitForPendingOperations()
        await second.pull()
        let closed = try await fixture.inspect(account)
        let lost = try #require(closed.attempts.last { $0.mutationID == deletion.id })
        #expect(lost.status == 201 && lost.protocolVersion == 4)
        #expect(closed.tabs.first { $0.id == "closed" }?.tombstoned == true)
        #expect(second.store.loadSnapshot()?.tabs.compactMap(\.id) == ["anchor"])
        #expect(try second.store.loadArchivePage().entries.isEmpty, "Manual Archive content is profile-local")
        #expect(try first.store.pendingSyncQueue(for: first.owner) == deletionQueue)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == deletionBytes)

        // Undo commits fresh creation and Archive consumption together. A failed
        // history command retains its chosen ID while ordinary edits continue.
        let closedSnapshot = first.store.loadSnapshot()
        let createdBeforeUndo = live.driver.createdTabRequests
        let syncIDsBeforeUndo = live.syncIDs.values
        try confirmedCloseHTTPSQL(databaseURL, """
        CREATE TRIGGER fail_confirmed_undo BEFORE INSERT ON browser_sync_outbox
        BEGIN SELECT RAISE(ABORT,'injected Undo failure'); END
        """)
        live.model.undoManager.undo()
        #expect(live.model.hasUncommittedSessionWrites && live.model.sessionPersistenceFailure != nil)
        #expect(!live.model.undoManager.canUndo && !live.model.undoManager.canRedo)
        #expect(live.model.tabs.map(\.syncID) == ["anchor"])
        #expect(live.driver.createdTabRequests == createdBeforeUndo)
        #expect(first.store.loadSnapshot() == closedSnapshot)
        #expect(try first.store.loadArchiveEntry(id: firstEntry.id) == firstEntry)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == deletionBytes)
        let chosenIDs = Array(live.syncIDs.values.dropFirst(syncIDsBeforeUndo.count))
        try #require(chosenIDs.count == 1)
        #expect(!live.model.retrySessionPersistence())
        #expect(Array(live.syncIDs.values.dropFirst(syncIDsBeforeUndo.count)) == chosenIDs)
        live.model.setUserTitleOverride("Latest edit during Undo retry", forTabID: anchor.id)
        #expect(first.store.loadSnapshot() == closedSnapshot)
        #expect(try first.store.loadArchiveEntry(id: firstEntry.id) == firstEntry)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == deletionBytes)
        try confirmedCloseHTTPSQL(databaseURL, "DROP TRIGGER fail_confirmed_undo")
        #expect(live.model.retrySessionPersistence())
        let undone = try #require(live.model.tabs.first { $0.syncID != "anchor" })
        #expect(undone.syncID == chosenIDs[0])
        #expect(undone.syncID != "closed" && undone.id != closing.id)
        #expect(undone.urlString == closing.urlString && undone.userTitleOverride == "Saved close title")
        #expect(live.model.selectedTabID == undone.id)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.id == anchor.id)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.canGoBack == true)
        #expect(live.model.tabs.first { $0.syncID == "anchor" }?.userTitleOverride == "Latest edit during Undo retry")
        #expect(first.store.loadSnapshot()?.tabs.first { $0.id == "anchor" }?.userTitleOverride ==
            "Latest edit during Undo retry")
        #expect(try first.store.loadArchiveEntry(id: firstEntry.id) == nil)
        #expect(live.model.undoManager.canRedo)
        live.driver.flushPendingCreateEvents()
        let restoredQueue = try first.store.pendingSyncQueue(for: first.owner)
        let restoration = try confirmedCloseHTTPCreation(undone.syncID, in: restoredQueue)
        let restoredBytes = try confirmedCloseHTTPOutbox(databaseURL)
        #expect(Array(restoredBytes.prefix(deletionBytes.count)) == deletionBytes)
        #expect(try first.store.loadArchivePage().entries.isEmpty)

        // Redo is asynchronous too: Cancel preserves both the live incarnation
        // and the redo command. A later confirmed Redo owns a new Archive entry.
        let restoredSnapshot = first.store.loadSnapshot()
        live.model.undoManager.redo()
        let cancelledRedo = try #require(live.driver.confirmedCloseRequests.last)
        #expect(cancelledRedo.id == undone.id)
        #expect(first.store.loadSnapshot() == restoredSnapshot)
        live.driver.emitCloseRequestOutcome(
            id: cancelledRedo.id, requestID: cancelledRedo.requestID, outcome: .cancelled
        )
        #expect(live.model.undoManager.canRedo)
        #expect(first.store.loadSnapshot() == restoredSnapshot)
        #expect(try confirmedCloseHTTPOutbox(databaseURL) == restoredBytes)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        live.model.undoManager.redo()
        let confirmedRedo = try #require(live.driver.confirmedCloseRequests.last)
        #expect(confirmedRedo.id == undone.id && confirmedRedo.requestID != cancelledRedo.requestID)
        live.driver.emitCloseRequestOutcome(
            id: confirmedRedo.id, requestID: confirmedRedo.requestID, outcome: .closed
        )
        let secondArchivePage = try first.store.loadArchivePage()
        try #require(secondArchivePage.entries.count == 1)
        let secondEntry = try #require(secondArchivePage.entries.first)
        #expect(secondEntry.id != firstEntry.id && secondEntry.tab.id == undone.syncID)
        #expect(secondEntry.tab.urlString == closing.urlString && secondEntry.tab
            .userTitleOverride == "Saved close title")
        #expect(live.model.tabs.map(\.syncID) == ["anchor"] && live.model.undoManager.canUndo)
        let redoQueue = try first.store.pendingSyncQueue(for: first.owner)
        let redoDeletion = try confirmedCloseHTTPDeletion(undone.syncID, in: redoQueue)
        #expect(try Array(confirmedCloseHTTPOutbox(databaseURL).prefix(restoredBytes.count)) == restoredBytes)
        live.model.undoManager.undo()
        let finalTab = try #require(live.model.tabs.first { $0.syncID != "anchor" })
        #expect(finalTab.syncID != undone.syncID && finalTab.syncID != "closed")
        #expect(finalTab.urlString == closing.urlString && finalTab.userTitleOverride == "Saved close title")
        #expect(live.model.selectedTabID == finalTab.id)
        #expect(try first.store.loadArchiveEntry(id: secondEntry.id) == nil)
        live.driver.flushPendingCreateEvents()
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        let finalRestoration = try confirmedCloseHTTPCreation(finalTab.syncID, in: pending)
        let bytes = try confirmedCloseHTTPOutbox(databaseURL)
        #expect(Array(bytes.prefix(restoredBytes.count)) == restoredBytes)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        #expect(try confirmedCloseHTTPConsumedEntries(databaseURL) == [
            firstEntry.id: undone.syncID, secondEntry.id: finalTab.syncID,
        ])
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
        #expect(converged.attempts.contains { $0.mutationID == redoDeletion.id && $0.status == 201 })
        #expect(converged.attempts.contains { $0.mutationID == finalRestoration.id && $0.status == 201 })
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner).isEmpty)
        for profile in [reopened, second] {
            #expect(profile.store.loadSnapshot()?.tabs.first { $0.id == finalTab.syncID }?.urlString == closing
                .urlString)
            #expect(profile.store
                .loadSnapshot()?
                .tabs
                .first { $0.id == finalTab.syncID }?
                .userTitleOverride == "Saved close title")
            #expect(profile.store.loadSnapshot()?.tabs.contains { $0.id == "closed" } == false)
            #expect(profile.store.loadSnapshot()?.tabs.contains { $0.id == undone.syncID } == false)
            #expect(profile.store.loadSnapshot()?.tabs.first { $0.id == "anchor" }?.userTitleOverride ==
                "Latest edit during Undo retry")
            #expect(try profile.store.loadArchivePage().entries.isEmpty)
        }
        #expect(rehydrated.model.tabs.first { $0.id == rehydrated.model.selectedTabID }?.syncID == finalTab.syncID)

        let receipt = try await remote.push(mutation: deletion, authSession: auth[1])
        #expect(receipt.events.contains { $0.entityID == "closed" && $0.op == "delete" })
        let redoReceipt = try await remote.push(mutation: redoDeletion, authSession: auth[1])
        #expect(redoReceipt.events.contains { $0.entityID == undone.syncID && $0.op == "delete" })
        let stale = try await remote.push(mutation: BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .patchTab(id: "closed", fields: .init(urlString: "https://confirmed-close.example/stale")),
            .patchTab(id: undone.syncID, fields: .init(urlString: "https://confirmed-close.example/stale-undo")),
        ]), authSession: auth[1])
        #expect(stale.outcomes == [
            .init(operationIndex: 0, status: .deleted, reason: nil),
            .init(operationIndex: 1, status: .deleted, reason: nil),
        ])
        #expect(stale.events.contains { $0.entityID == "closed" && $0.op == "delete" })
        #expect(stale.events.contains { $0.entityID == undone.syncID && $0.op == "delete" })
        await reopened.pull()
        await second.pull()
        let final = try await fixture.inspect(account)
        #expect(final.eventCount == converged.eventCount, "Old delete replay and stale edits must append no live event")
        #expect(final.tabs.first { $0.id == "closed" }?.tombstoned == true)
        #expect(final.tabs.first { $0.id == undone.syncID }?.tombstoned == true)
        #expect(Set(final.tabs.filter { !$0.deleted }.map(\.id)) == ["anchor", finalTab.syncID])
        #expect(try reopened.store.loadArchivePage().entries.isEmpty)
        await reopened.disconnect()
        await second.disconnect()
        rehydrated.close()
        let finalStore = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(finalStore.loadSnapshot()?.tabs.filter { $0.id == finalTab.syncID }.count == 1)
        #expect(finalStore.loadSnapshot()?.tabs.contains { $0.id == "closed" } == false)
        #expect(finalStore.loadSnapshot()?.tabs.contains { $0.id == undone.syncID } == false)
        #expect(try finalStore.loadArchivePage().entries.isEmpty)
        #expect(try confirmedCloseHTTPConsumedEntries(databaseURL) == [
            firstEntry.id: undone.syncID, secondEntry.id: finalTab.syncID,
        ])
        try await fixture.complete(account)
    }
}

// MARK: - ConfirmedCloseHTTPModel

@MainActor private final class ConfirmedCloseHTTPModel {
    // MARK: Lifecycle

    init(profile: SyncHTTPProfile, now: Date) throws {
        self.profile = profile
        self.defaults = try #require(UserDefaults(suiteName: suite))
        let syncIDs = ConfirmedCloseHTTPSyncIDs()
        self.syncIDs = syncIDs
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: profile.store, sessionPreferencesStore: profile.store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: profile.service,
            dateProvider: { now }, tabSyncIDProvider: syncIDs.next,
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
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
    let syncIDs: ConfirmedCloseHTTPSyncIDs

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

// MARK: - ConfirmedCloseHTTPSyncIDs

@MainActor private final class ConfirmedCloseHTTPSyncIDs {
    private(set) var values = [String]()

    func next() -> String {
        let id = UUID().uuidString
        values.append(id)
        return id
    }
}

@MainActor private func confirmedCloseHTTPSQL(_ url: URL, _ sql: String) throws {
    try DatabaseQueue(path: url.path).write { try $0.execute(sql: sql) }
}

@MainActor private func confirmedCloseHTTPOutbox(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read {
        try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}

@MainActor private func confirmedCloseHTTPConsumedEntries(_ url: URL) throws -> [String: String] {
    try DatabaseQueue(path: url.path).read { db in
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, restored_tab_id FROM browser_tab_archive_receipts WHERE restored_tab_id IS NOT NULL"
        )
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let id: String = row["id"]
            let restoredID: String = row["restored_tab_id"]
            return (id, restoredID)
        })
    }
}

@MainActor private func confirmedCloseHTTPCreation(
    _ id: String, in queue: [BrowserSyncQueuedMutation]
) throws -> BrowserSyncFolderMutation {
    let matches = queue.compactMap { mutation -> BrowserSyncFolderMutation? in
        guard case .folders(let folders) = mutation else { return nil }
        return folders.operations.contains { operation in
            if case .createTab(let tabID, _, _, _) = operation {
                return tabID == id
            }
            return false
        } ? folders : nil
    }
    try #require(matches.count == 1)
    return try #require(matches.first)
}

@MainActor private func confirmedCloseHTTPDeletion(
    _ id: String, in queue: [BrowserSyncQueuedMutation]
) throws -> BrowserSyncFolderMutation {
    let matches = queue.compactMap { mutation -> BrowserSyncFolderMutation? in
        guard case .folders(let folders) = mutation else { return nil }
        return folders.operations.contains(.deleteTab(id: id)) ? folders : nil
    }
    try #require(matches.count == 1)
    return try #require(matches.first)
}
