// BrowserDesktopPersistentRemovalHTTPTests.swift

import Foundation
import GRDB
import Testing

extension BrowserSyncHTTPIntegrationTests {
    @Test func persistentLogicalRemovalUndoAndRedoConvergeWithoutArchiveOrResurrection() async throws {
        let fixture = try SyncHTTPFixture.load()
        let account = try fixture.account("desktop-persistent-removal")
        let directory = SyncHTTPProfile.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        let second = try SyncHTTPProfile(fixture: fixture, device: account.devices[1], directory: directory)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let activity = ISO8601DateFormatter().string(from: now)
        let home = "https://persistent-removal.example/home"
        let away = "https://persistent-removal.example/current"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let configuration = try #require(BrowserSyncConfiguration(baseURL: fixture.baseURL))
        let remote = BrowserRemoteSyncClient(configuration: configuration, session: session)
        let auth = account.devices.map { device in
            BrowserAuthSession(
                accessToken: device.accessToken, userID: device.userID, userEmail: nil,
                deviceID: device.deviceID, serverURL: fixture.baseURL,
            )
        }
        let original = BrowserSyncFolderTabCreate(
            spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder",
            urlString: away, pinnedURLString: home, userTitleOverride: "Saved pinned title", lastActivityAt: activity,
        )
        _ = try await remote.push(mutation: BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createSpace(id: "source", data: .init(title: "Persistent Removal", systemImageName: "globe")),
            .createFolder(id: "folder", data: .init(spaceID: "source", title: "Folder")),
            .createTab(id: "left", data: .init(
                spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder",
                urlString: "https://persistent-removal.example/left", lastActivityAt: activity,
            )),
            .createTab(id: "pinned", data: original),
            .createTab(id: "right", data: .init(
                spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder",
                urlString: "https://persistent-removal.example/right", lastActivityAt: activity,
            )),
            .createTab(id: "anchor", data: .init(
                spaceID: "source", placement: .temporary, urlString: "https://persistent-removal.example/anchor",
                lastActivityAt: activity,
            )),
        ]), authSession: auth[0])
        await first.activate()
        await second.activate()
        let live = try PersistentRemovalHTTPModel(profile: first, now: now)
        defer { live.close() }
        // Pinned tabs restore unloaded. Show this one first so it has a page
        // whose close needs the engine's confirmation.
        let unloaded = try #require(live.model.tabs.first { $0.syncID == "pinned" })
        live.model.selectTab(id: unloaded.id)
        live.driver.flushPendingCreateEvents()
        let pinned = try #require(live.model.tabs.first { $0.syncID == "pinned" })
        live.driver.emitTabCreationState(id: pinned.id, state: .ready)
        let anchor = try #require(live.model.tabs.first { $0.syncID == "anchor" })
        live.model.selectTab(id: anchor.id)
        live.driver.emitNavigationStateChange(id: anchor.id, canGoBack: true, canGoForward: true)
        await first.service.waitForPendingOperations()
        await second.pull()
        live.model.undoManager.removeAllActions()
        let before = try #require(try first.store.loadSnapshotStrict())
        let initial = try await fixture.inspect(account)
        let created = live.driver.createdTabRequests
        #expect(before.tabs.filter { $0.pinnedFolderID == "folder" }.compactMap(\.id) == ["left", "pinned", "right"])

        // The sidebar's unselected-tab Close action is logical removal. It must
        // neither perform selected-pin unload/reset nor mutate before confirmation.
        #expect(live.model.closeTab(id: pinned.id))
        let cancelled = try #require(live.driver.confirmedCloseRequests.last)
        #expect(cancelled.id == pinned.id)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(try first.store.pendingSyncQueue(for: first.owner).isEmpty)
        #expect(!live.model.undoManager.canUndo)
        live.driver.emitCloseRequestOutcome(id: pinned.id, requestID: cancelled.requestID, outcome: .cancelled)
        await first.service.waitForPendingOperations()
        await second.pull()
        let afterCancel = try await fixture.inspect(account)
        #expect(afterCancel.eventCount == initial.eventCount && afterCancel.receiptCount == initial.receiptCount)
        #expect(afterCancel.attempts.count == initial.attempts.count)
        #expect(try first.store.loadSnapshotStrict() == before)
        #expect(second.store.loadSnapshot()?.tabs == before.tabs)
        #expect(live.model.selectedTabID == anchor.id && live.driver.createdTabRequests == created)

        try await fixture.command("drop", deviceID: account.devices[0].deviceID)
        #expect(live.model.closeTab(id: pinned.id))
        let confirmed = try #require(live.driver.confirmedCloseRequests.last)
        #expect(confirmed.requestID != cancelled.requestID)
        live.driver.emitCloseRequestOutcome(id: pinned.id, requestID: confirmed.requestID, outcome: .closed)
        #expect(!live.model.tabs.contains { $0.syncID == "pinned" })
        #expect(live.model.selectedTabID == anchor.id && live.model.canGoBack && live.model.canGoForward)
        #expect(live.driver.createdTabRequests == created)
        #expect(live.model.undoManager.canUndo && !live.model.undoManager.canRedo)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        let initialQueue = try first.store.pendingSyncQueue(for: first.owner)
        try #require(initialQueue.count == 1)
        guard case .folders(let removal) = initialQueue[0] else {
            Issue.record("Confirmed pinned removal must capture one ordinary v4 delete")
            return
        }
        #expect(removal.operations == [.deleteTab(id: "pinned")])
        let databaseURL = directory.appendingPathComponent(account.devices[0].deviceID + ".sqlite")
        let removalBytes = try persistentRemovalHTTPOutbox(databaseURL)
        await first.service.waitForPendingOperations()
        await second.pull()
        let deleted = try await fixture.inspect(account)
        let lost = try #require(deleted.attempts.last { $0.mutationID == removal.id })
        #expect(lost.status == 201 && deleted.tabs.first { $0.id == "pinned" }?.tombstoned == true)
        #expect(second.store.loadSnapshot()?.tabs.contains { $0.id == "pinned" } == false)
        #expect(try first.store.pendingSyncQueue(for: first.owner) == initialQueue)
        #expect(try persistentRemovalHTTPOutbox(databaseURL) == removalBytes)
        #expect(try second.store.loadArchivePage().entries.isEmpty)

        live.model.undoManager.undo()
        let restored = try #require(live.model.tabs.first { !["left", "right", "anchor"].contains($0.syncID) })
        #expect(restored.syncID != pinned.syncID && restored.id != pinned.id)
        #expect(restored.placement == .spacePinned && restored.pinnedFolderID == "folder")
        #expect(restored.urlString == away && restored.pinnedURLString == home)
        #expect(restored.userTitleOverride == "Saved pinned title")
        #expect(live.model.tabs.filter { $0.pinnedFolderID == "folder" }.map(\.syncID) == [
            "left",
            restored.syncID,
            "right",
        ])
        #expect(live.model.selectedTabID == anchor.id && live.model.undoManager.canRedo)
        live.driver.flushPendingCreateEvents()
        live.driver.emitTabCreationState(id: restored.id, state: .ready)
        let restoredSnapshot = try #require(try first.store.loadSnapshotStrict())
        let restoredBytes = try persistentRemovalHTTPOutbox(databaseURL)
        #expect(Array(restoredBytes.prefix(removalBytes.count)) == removalBytes)
        #expect(try first.store.loadArchivePage().entries.isEmpty)

        live.model.undoManager.redo()
        let cancelledRedo = try #require(live.driver.confirmedCloseRequests.last)
        #expect(cancelledRedo.id == restored.id)
        #expect(try first.store.loadSnapshotStrict() == restoredSnapshot)
        live.driver.emitCloseRequestOutcome(id: restored.id, requestID: cancelledRedo.requestID, outcome: .cancelled)
        #expect(live.model.undoManager.canRedo && live.model.tabs.contains { $0.syncID == restored.syncID })
        #expect(try persistentRemovalHTTPOutbox(databaseURL) == restoredBytes)
        live.model.undoManager.redo()
        let confirmedRedo = try #require(live.driver.confirmedCloseRequests.last)
        #expect(confirmedRedo.id == restored.id && confirmedRedo.requestID != cancelledRedo.requestID)
        live.driver.emitCloseRequestOutcome(id: restored.id, requestID: confirmedRedo.requestID, outcome: .closed)
        #expect(!live.model.tabs.contains { $0.syncID == restored.syncID })
        #expect(live.model.undoManager.canUndo && live.model.selectedTabID == anchor.id)
        #expect(try first.store.loadArchivePage().entries.isEmpty)
        live.model.undoManager.undo()
        let finalTab = try #require(live.model.tabs.first { !["left", "right", "anchor"].contains($0.syncID) })
        #expect(finalTab.syncID != restored.syncID && finalTab.syncID != pinned.syncID)
        #expect(finalTab.pinnedFolderID == "folder" && finalTab.placement == .spacePinned)
        #expect(finalTab.urlString == away && finalTab.pinnedURLString == home)
        #expect(live.model.tabs.filter { $0.pinnedFolderID == "folder" }.map(\.syncID) == [
            "left",
            finalTab.syncID,
            "right",
        ])
        #expect(live.model.selectedTabID == anchor.id && live.model.tabs.first { $0.syncID == "anchor" }?.id == anchor
            .id)
        #expect(live.model.canGoBack && live.model.canGoForward)
        live.driver.flushPendingCreateEvents()
        let pending = try first.store.pendingSyncQueue(for: first.owner)
        try #require(pending.count == 4)
        guard case .folders(let redo) = pending[2] else {
            Issue.record("Confirmed Redo must preserve the logical removal intent")
            return
        }
        #expect(redo.operations == [.deleteTab(id: restored.syncID)])
        let bytes = try persistentRemovalHTTPOutbox(databaseURL)
        #expect(Array(bytes.prefix(restoredBytes.count)) == restoredBytes)
        await first.service.waitForPendingOperations()
        #expect(try first.store.pendingSyncQueue(for: first.owner) == pending)
        #expect(try persistentRemovalHTTPOutbox(databaseURL) == bytes)
        #expect(try first.store.loadArchivePage().entries.isEmpty)

        await first.disconnect()
        live.close()
        try await fixture.command("release", deviceID: account.devices[0].deviceID)
        let reopened = try SyncHTTPProfile(fixture: fixture, device: account.devices[0], directory: directory)
        #expect(try reopened.store.pendingSyncQueue(for: reopened.owner) == pending)
        #expect(try persistentRemovalHTTPOutbox(databaseURL) == bytes)
        await reopened.activate()
        await second.pull()
        let converged = try await fixture.inspect(account)
        let retries = converged.attempts.filter { $0.mutationID == removal.id }
        #expect(retries.count >= 2 && Set(retries.map(\.digest)) == [lost.digest])
        #expect(converged.tabs.first { $0.id == "pinned" }?.tombstoned == true)
        #expect(converged.tabs.first { $0.id == restored.syncID }?.tombstoned == true)
        #expect(Set(converged.tabs.filter { !$0.deleted }.map(\.id)) == ["left", "right", "anchor", finalTab.syncID])
        let stale = try await remote.push(mutation: BrowserSyncFolderMutation(id: UUID().uuidString, operations: [
            .createTab(id: "pinned", data: original),
            .createTab(id: restored.syncID, data: original),
        ]), authSession: auth[1])
        #expect(stale.outcomes == [
            .init(operationIndex: 0, status: .deleted, reason: nil),
            .init(operationIndex: 1, status: .deleted, reason: nil),
        ])
        #expect(Set(stale.events.filter { $0.op == "delete" }.map(\.entityID)) == ["pinned", restored.syncID])
        let afterReplay = try await fixture.inspect(account)
        #expect(afterReplay.eventCount == converged.eventCount)
        await reopened.disconnect()
        await second.disconnect()

        // Both devices replay history into empty real SQLite stores. Neither old
        // incarnation nor any Archive content may appear during full bootstrap.
        for device in account.devices {
            let fresh = try SyncHTTPProfile(
                fixture: fixture, device: device, directory: directory, databaseID: "fresh-" + device.deviceID,
            )
            await fresh.activate()
            let snapshot = try #require(try fresh.store.loadSnapshotStrict())
            #expect(snapshot.tabs.filter { $0.pinnedFolderID == "folder" }.compactMap(\.id) == [
                "left",
                finalTab.syncID,
                "right",
            ])
            let recovered = try #require(snapshot.tabs.first { $0.id == finalTab.syncID })
            #expect(recovered.placement == .spacePinned && recovered.spaceID == "source")
            #expect(recovered.urlString == away && recovered.pinnedURLString == home)
            #expect(recovered.userTitleOverride == "Saved pinned title")
            #expect(!snapshot.tabs.contains { $0.id == "pinned" || $0.id == restored.syncID })
            #expect(snapshot.pinnedTabFolders?.map(\.id) == ["folder"])
            #expect(try fresh.store.pendingSyncQueue(for: fresh.owner).isEmpty)
            #expect(try fresh.store.loadArchivePage().entries.isEmpty)
            #expect(try fresh.store.syncPullProtocolVersion(for: fresh.owner) == 6)
            await fresh.disconnect()
        }
        let finalDisk = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try finalDisk.loadSnapshotStrict()?.tabs.filter { $0.pinnedFolderID == "folder" }.compactMap(\.id) == [
            "left",
            finalTab.syncID,
            "right",
        ])
        #expect(try finalDisk.loadArchivePage().entries.isEmpty)
        try await fixture.complete(account)
    }
}

// MARK: - PersistentRemovalHTTPModel

@MainActor private final class PersistentRemovalHTTPModel {
    // MARK: Internal

    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()

    // MARK: Private

    private let profile: SyncHTTPProfile
    private let defaults: UserDefaults
    private let suite = BrowserTestDefaults.suiteName("PersistentRemovalHTTPModel")
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

@MainActor private func persistentRemovalHTTPOutbox(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read {
        try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}
