// BrowserPendingRemoteSpaceDeletionTests.swift

import Foundation
import GRDB
import Testing

@Test(arguments: [BrowserTabPlacement.temporary, .spacePinned])
@MainActor func deletingSpaceCancelsPendingOrdinaryChildWithoutResurrectionOrExtraMutation(
    placement: BrowserTabPlacement,
) throws {
    let h = try PendingRemoteSpaceHarness()
    defer { h.cleanup() }
    let remote = try h.receiveChildren(ordinaryPlacement: placement, includesFavorite: false)
    h.model.applyRemoteSyncSnapshot(remote)
    let child = try #require(h.driver.createdTabRequests.last { $0.urlString == "https://child.example" })
    #expect(!h.model.tabs.contains { $0.syncID == "child" })
    let pushesBefore = h.sync.pushedSnapshots.count

    #expect(h.model.deleteSpace(id: "deleted-space"))
    #expect(h.driver.closedTabRequests.contains { $0.id == child.id && $0.forceClose })
    #expect(h.store.loadSnapshot()?.tabs.compactMap(\.id) == ["anchor"])
    #expect(h.sync.pushedSnapshots.count > pushesBefore, "Canceling the last pending child must finish projection")
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    try h.requireOnlyParentDeletion(queue)

    // The engine callback can arrive after cancellation. It must not receive a
    // fallback Space or become a new local tab with a fresh sync identity.
    h.driver.flushPendingCreateEvents()
    #expect(h.model.tabs.map(\.syncID) == ["anchor"])
    #expect(!h.model.tabs.contains { $0.id == child.id || $0.urlString == child.urlString })
    #expect(h.driver.closedTabRequests.count(where: { $0.id == child.id && $0.forceClose }) >= 2)
    #expect(h.store.loadSnapshot()?.tabs.compactMap(\.id) == ["anchor"])
    #expect(try h.store.pendingSyncQueue(for: h.owner) == queue)
    #expect(try h.store.syncCursor(for: h.owner) == 4)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let restoredDriver = FakeBrowserTabDriver()
    let restored = h.makeModel(store: reopened, driver: restoredDriver)
    defer { h.close(restored) }
    restored.handleContextReady()
    restoredDriver.flushPendingCreateEvents()
    #expect(restored.tabs.map(\.syncID) == ["anchor"])
    #expect(restoredDriver.createdTabRequests.map(\.urlString) == ["https://anchor.example"])
    #expect(try reopened.pendingSyncQueue(for: h.owner) == queue)
}

@Test @MainActor func deletingSpaceKeepsPendingGlobalFavoriteAcrossLateCallbackAndOfflineRestart() throws {
    let h = try PendingRemoteSpaceHarness()
    defer { h.cleanup() }
    let remote = try h.receiveChildren(ordinaryPlacement: .temporary, includesFavorite: true)
    h.model.applyRemoteSyncSnapshot(remote)
    let child = try #require(h.driver.createdTabRequests.last { $0.urlString == "https://child.example" })
    let favorite = try #require(h.driver.createdTabRequests.last { $0.urlString == "https://favorite.example" })
    #expect(h.model.deleteSpace(id: "deleted-space"))
    #expect(h.driver.closedTabRequests.contains { $0.id == child.id })
    #expect(!h.driver.closedTabRequests.contains { $0.id == favorite.id })
    let beforeCallback = try #require(h.store.loadSnapshot())
    #expect(beforeCallback.spaces?.map(\.id) == ["surviving-space"])
    #expect(Set(beforeCallback.tabs.compactMap(\.id)) == ["favorite", "anchor"])
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    try h.requireOnlyParentDeletion(queue)

    h.driver.flushPendingCreateEvents()
    let liveFavorite = try #require(h.model.tabs.first { $0.syncID == "favorite" })
    #expect(liveFavorite.id == favorite.id && liveFavorite.placement == .app)
    #expect(liveFavorite.spaceID == "surviving-space")
    #expect(liveFavorite.userTitleOverride == "Global Favorite")
    #expect(!h.model.tabs.contains { $0.syncID == "child" || $0.id == child.id })
    #expect(!h.driver.closedTabRequests.contains { $0.id == favorite.id })
    #expect(try h.store.pendingSyncQueue(for: h.owner) == queue, "Callback normalization must not echo a move")
    #expect(try h.store.syncCursor(for: h.owner) == 5)
    let saved = try #require(h.store.loadSnapshot())
    #expect(saved.tabs.compactMap(\.id) == ["favorite", "anchor"])

    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let restoredDriver = FakeBrowserTabDriver()
    let restored = h.makeModel(store: reopened, driver: restoredDriver)
    defer { h.close(restored) }
    restored.handleContextReady()
    restoredDriver.flushPendingCreateEvents()
    #expect(restored.tabs.map(\.syncID) == ["favorite", "anchor"])
    #expect(restored.appTabs.first?.userTitleOverride == "Global Favorite")
    #expect(restored.appTabs.first?.spaceID == "surviving-space")
    #expect(reopened.loadSnapshot()?.tabs == saved.tabs)
    #expect(try reopened.pendingSyncQueue(for: h.owner) == queue)
}

@Test @MainActor func failedSpaceDeletionBuffersLocalIntentAndRemoteCompletionWithoutRevivingPendingChild() throws {
    let h = try PendingRemoteSpaceHarness()
    defer { h.cleanup() }
    let remote = try h.receiveChildren(ordinaryPlacement: .spacePinned, includesFavorite: false)
    h.model.applyRemoteSyncSnapshot(remote)
    let child = try #require(h.driver.createdTabRequests.last { $0.urlString == "https://child.example" })
    let durableBefore = h.store.loadSnapshot()
    let database = try DatabaseQueue(path: h.databaseURL.path)
    try database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_pending_parent_delete BEFORE INSERT ON browser_spaces
        BEGIN SELECT RAISE(ABORT, 'injected pending parent delete failure'); END
        """)
    }
    #expect(h.model.deleteSpace(id: "deleted-space"))
    #expect(h.model.hasUncommittedSessionWrites && h.model.sessionPersistenceFailure?.isRetryable == true)
    #expect(h.driver.closedTabRequests.contains { $0.id == child.id && $0.forceClose })
    #expect(h.store.loadSnapshot() == durableBefore)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    h.driver.flushPendingCreateEvents()
    #expect(h.model.tabs.map(\.syncID) == ["anchor"])
    #expect(!h.model.tabs.contains { $0.id == child.id })
    #expect(h.store.loadSnapshot() == durableBefore)

    try database.write { db in try db.execute(sql: "DROP TRIGGER fail_pending_parent_delete") }
    #expect(h.model.retrySessionPersistence())
    #expect(!h.model.hasUncommittedSessionWrites && h.model.sessionPersistenceFailure == nil)
    #expect(h.store.loadSnapshot()?.tabs.compactMap(\.id) == ["anchor"])
    #expect(h.store.loadSnapshot()?.spaces?.map(\.id) == ["surviving-space"])
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    try h.requireOnlyParentDeletion(queue)
    #expect(try h.store.syncCursor(for: h.owner) == 4)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let restoredDriver = FakeBrowserTabDriver()
    let restored = h.makeModel(store: reopened, driver: restoredDriver)
    defer { h.close(restored) }
    restored.handleContextReady()
    restoredDriver.flushPendingCreateEvents()
    #expect(restored.tabs.map(\.syncID) == ["anchor"])
    #expect(try reopened.pendingSyncQueue(for: h.owner) == queue)
}

// MARK: - PendingRemoteSpaceHarness

@MainActor private final class PendingRemoteSpaceHarness {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pending-remote-\(UUID())")
    let suiteName = "BrowserPendingRemoteSpaceDeletionTests.\(UUID())"
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://pending-remote.example")!, userID: "owner")
    let defaults: UserDefaults
    let store: BrowserSQLiteSessionStore
    let driver = FakeBrowserTabDriver()
    let sync = PendingRemoteSpaceSyncRecorder()
    private(set) var model: BrowserChromeModel!

    var databaseURL: URL { directory.appendingPathComponent("session.sqlite") }

    init() throws {
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("session.sqlite"))
        try store.bindSyncOwner(owner)
        _ = try store.applyRemoteSyncEvents([
            spaceEvent("deleted-space", rank: 0, sequence: 1),
            spaceEvent("surviving-space", rank: 1, sequence: 2),
            tabEvent("anchor", space: "surviving-space", placement: .temporary, sequence: 3),
        ], cursor: 3, for: owner, enableSemanticMutations: true)
        self.model = makeModel(store: store, driver: driver)
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        try #require(store.pendingSyncQueue(for: owner).isEmpty)
    }

    func receiveChildren(ordinaryPlacement: BrowserTabPlacement, includesFavorite: Bool) throws
        -> BrowserTabSessionSnapshot
    {
        var events = [tabEvent("child", space: "deleted-space", placement: ordinaryPlacement, sequence: 4)]
        if includesFavorite {
            events.append(tabEvent("favorite", space: "deleted-space", placement: .app, sequence: 5))
        }
        return try store.applyRemoteSyncEvents(events, cursor: includesFavorite ? 5 : 4, for: owner)
    }

    func requireOnlyParentDeletion(_ queue: [BrowserSyncQueuedMutation]) throws {
        try #require(queue.count == 1)
        guard case .semantic(let mutation) = queue[0] else {
            Issue.record("Expected one semantic parent delete")
            return
        }
        #expect(mutation.operations == [.deleteSpace(id: "deleted-space")])
    }

    func makeModel(store: BrowserSQLiteSessionStore, driver: FakeBrowserTabDriver) -> BrowserChromeModel {
        BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
    }

    func close(_ model: BrowserChromeModel) {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
    }

    func cleanup() {
        close(model)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Private

    private func spaceEvent(_ id: String, rank: Double, sequence: Int) -> BrowserSyncEvent {
        BrowserSyncEvent(
            serverSeq: sequence, deviceID: "remote", entityType: "space", entityID: id, op: "upsert",
            data: .space(.init(
                id: id, title: id, systemImageName: "globe", rank: rank, isPinnedSectionCollapsed: false,
                selectedTabID: nil,
            )), createdAt: "2027-01-15T08:00:00Z",
        )
    }

    private func tabEvent(
        _ id: String, space: String, placement: BrowserTabPlacement, sequence: Int,
    ) -> BrowserSyncEvent {
        BrowserSyncEvent(
            serverSeq: sequence, deviceID: "remote", entityType: "tab", entityID: id, op: "upsert",
            data: .tab(.init(
                id: id, spaceID: space, placement: placement, rank: 0, urlString: "https://\(id).example",
                pinnedURLString: placement == .spacePinned ? "https://\(id).example/home" : nil,
                title: nil, userTitleOverride: id == "favorite" ? "Global Favorite" : "Remote \(id)",
                faviconURLString: nil, lastActivityAt: "2027-01-15T08:00:00Z",
            )), createdAt: "2027-01-15T08:00:00Z",
        )
    }
}

// MARK: - PendingRemoteSpaceSyncRecorder

@MainActor private final class PendingRemoteSpaceSyncRecorder: BrowserSyncCoordinating {
    var pushedSnapshots = [BrowserTabSessionSnapshot]()

    func schedulePush(snapshot: BrowserTabSessionSnapshot) { pushedSnapshots.append(snapshot) }
    func schedulePull() {}
}
