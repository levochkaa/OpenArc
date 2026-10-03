import Foundation
import GRDB
import Testing

@Test @MainActor func localPendingNavigationPersistsEveryAcceptedURLBeforeCallbacksAndRestart() async throws {
    let h = try PendingNavigationHarness()
    defer { h.cleanup() }
    let tab = try #require(h.selectedTab)
    #expect(tab.creationState == .creating)
    h.model.openBookmark(urlString: "https://example.com/pending-navigation/b")
    h.model.presentCurrentPageCommandBar()
    h.model.currentPageCommandBarModel.query = "https://example.com/pending-navigation/c"
    await h.model.currentPageCommandBarModel.waitForPendingSuggestionLoad()
    try #require(h.model.currentPageCommandBarModel.selectedSuggestion?.kind == .url)
    h.model.currentPageCommandBarModel.submitSelection()
    #expect(!h.model.currentPageCommandBarModel.isPresented)
    #expect(h.selectedTab?.id == tab.id && h.selectedTab?.syncID == tab.syncID)
    #expect(h.selectedTab?.urlString == "https://example.com/pending-navigation/c")
    #expect(h.selectedTab?.pinnedURLString == "https://pinned.example/home")
    #expect(h.driver.targetedNavigationRequests == [
        .init(id: tab.id, urlString: "https://example.com/pending-navigation/b"),
        .init(id: tab.id, urlString: "https://example.com/pending-navigation/c"),
    ])
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    #expect(try h.operations(queue) == [
        .patchTab(id: "pinned", fields: .init(urlString: "https://example.com/pending-navigation/b")),
        .patchTab(id: "pinned", fields: .init(urlString: "https://example.com/pending-navigation/c")),
    ])
    let bytes = try h.outboxBytes()
    h.driver.flushPendingCreateEvents()
    #expect(
        h.selectedTab?.urlString == "https://example.com/pending-navigation/c",
        "Old allocation URL cannot replace intent"
    )
    #expect(try h.outboxBytes() == bytes)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let driver = FakeBrowserTabDriver()
    let model = h.makeModel(store: reopened, driver: driver)
    defer { h.close(model) }
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    #expect(model.tabs.first { $0.syncID == "pinned" }?.urlString == "https://example.com/pending-navigation/c")
    #expect(try reopened.pendingSyncQueue(for: h.owner) == queue)
    #expect(try h.outboxBytes() == bytes)
}

@Test @MainActor func ordinaryNewTabOwnsDurableIdentityBeforeItsPlaceholderAndCanNavigateOrClose() throws {
    let h = try PendingNavigationHarness()
    defer { h.cleanup() }
    h.driver.flushPendingCreateEvents()
    try h.model.openURLInNewTab(#require(URL(string: "https://new.example/a")))
    let tab = try #require(h.selectedTab)
    #expect(tab.urlString == "https://new.example/a" && tab.syncID != "pinned")
    #expect(h.store.loadSnapshot()?.tabs.contains { $0.id == tab.syncID } == true)
    h.model.openBookmark(urlString: "https://new.example/b")
    let beforeCallback = try h.store.pendingSyncQueue(for: h.owner)
    h.driver.flushPendingCreateEvents()
    #expect(h.selectedTab?.id == tab.id && h.selectedTab?.syncID == tab.syncID)
    #expect(h.selectedTab?.urlString == "https://new.example/b")
    #expect(try h.store.pendingSyncQueue(for: h.owner) == beforeCallback)

    try h.model.openURLInNewTab(#require(URL(string: "https://cancel.example/")))
    let canceled = try #require(h.selectedTab)
    #expect(h.model.closeTab(id: canceled.id, registersUndo: false))
    let afterClose = try h.store.pendingSyncQueue(for: h.owner)
    h.driver.flushPendingCreateEvents()
    #expect(!h.model.tabs.contains { $0.id == canceled.id || $0.syncID == canceled.syncID })
    #expect(h.store.loadSnapshot()?.tabs.contains { $0.id == canceled.syncID } == false)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == afterClose)
}

@Test(arguments: [BrowserTabPlacement.spacePinned, .app])
@MainActor func reopenedPersistentTabKeepsExplicitNavigationWhenOldPlaceholderArrives(
    placement: BrowserTabPlacement
) throws {
    let h = try PendingNavigationHarness(placement: placement)
    defer { h.cleanup() }
    h.driver.flushPendingCreateEvents()
    let target = try #require(h.model.tabs.first { $0.syncID == "pinned" })
    h.model.selectTab(id: target.id)
    let original = try #require(h.selectedTab)
    #expect(h.model.archiveSelectedTab())
    try #require(h.driver.closedTabRequests.contains { $0.id == original.id })
    h.driver.emitClose(id: original.id)
    h.model.selectTab(id: original.id)
    let reopened = try #require(h.selectedTab)
    #expect(reopened.id != original.id && reopened.syncID == original.syncID)
    h.model.openBookmark(urlString: "https://reopened.example/new")
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    h.driver.flushPendingCreateEvents()
    #expect(h.selectedTab?.id == reopened.id && h.selectedTab?.syncID == original.syncID)
    #expect(h.selectedTab?.urlString == "https://reopened.example/new")
    #expect(h.selectedTab?.userTitleOverride == "Pinned label")
    #expect(h.selectedTab?.pinnedURLString == (placement == .spacePinned ? "https://pinned.example/home" : nil))
    #expect(try h.store.pendingSyncQueue(for: h.owner) == queue)
}

@Test(arguments: [false, true])
@MainActor func latestRemotePendingURLTargetsBackgroundIdentityWithoutEchoOrChangingReadyPage(
    placeholderDelivered: Bool
) throws {
    let h = try PendingNavigationHarness()
    defer { h.cleanup() }
    h.driver.flushPendingCreateEvents()
    let selected = h.model.selectedTabID
    let first = try h.receiveRemote(url: "https://remote.example/a", sequence: 10)
    h.model.applyRemoteSyncSnapshot(first)
    let request = try #require(h.driver.createdTabRequests.last { $0.urlString == "https://remote.example/a" })
    if placeholderDelivered {
        h.driver.flushPendingCreateEvents()
    }
    let latest = try h.receiveRemote(url: "https://remote.example/b", sequence: 11)
    h.model.applyRemoteSyncSnapshot(latest)
    h.driver.flushPendingCreateEvents()
    #expect(h.model.tabs.first { $0.syncID == "remote" }?.urlString == "https://remote.example/b")
    #expect(h.store.loadSnapshot()?.tabs.first { $0.id == "remote" }?.urlString == "https://remote.example/b")
    #expect(h.driver.targetedNavigationRequests.contains(.init(id: request.id, urlString: "https://remote.example/b")))
    #expect(h.model.selectedTabID == selected)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)

    h.driver.emitTabCreationState(id: request.id, state: .ready)
    let count = h.driver.targetedNavigationRequests.count
    try h.model.applyRemoteSyncSnapshot(h.receiveRemote(url: "https://remote.example/c", sequence: 12))
    #expect(h.model.tabs.first { $0.syncID == "remote" }?.urlString == "https://remote.example/b")
    #expect(h.driver.targetedNavigationRequests.count == count, "A ready page keeps its live navigation")
    h.driver.emitUpdate(id: request.id, urlString: "https://redirect.example/final")
    #expect(h.model.tabs.first { $0.syncID == "remote" }?.urlString == "https://redirect.example/final")
    #expect(h.store.loadSnapshot()?.tabs.first { $0.id == "remote" }?.urlString == "https://redirect.example/final")
}

@Test @MainActor func acceptedLocalPendingURLWinsOverRemoteInitializationAndFailedSubmissionRetriesIt() throws {
    let h = try PendingNavigationHarness()
    defer { h.cleanup() }
    h.driver.flushPendingCreateEvents()
    try h.model.applyRemoteSyncSnapshot(h.receiveRemote(url: "https://remote.example/a", sequence: 10))
    h.driver.flushPendingCreateEvents()
    let remote = try #require(h.model.tabs.first { $0.syncID == "remote" })
    h.model.selectTab(id: remote.id)
    h.model.openBookmark(urlString: "https://local.example/wins")
    let queued = try h.store.pendingSyncQueue(for: h.owner)
    try #require(queued.count == 1)
    // Even after the local operation is acknowledged, an engine still creating
    // must initialize at the explicitly submitted URL rather than a remote edit.
    let ownEvent = pendingNavigationTabEvent(id: "remote", url: "https://local.example/wins", sequence: 11)
    _ = try h.store.acknowledgeSyncMutation(id: queued[0].id, protocolVersion: 3, events: [ownEvent], for: h.owner)
    try h.model.applyRemoteSyncSnapshot(h.receiveRemote(url: "https://remote.example/newer", sequence: 12))
    #expect(h.model.tabs.first { $0.id == remote.id }?.urlString == "https://local.example/wins")
    #expect(h.driver.targetedNavigationRequests.last?.urlString == "https://local.example/wins")
    h.driver.emitTabCreationState(id: remote.id, state: .failed)
    h.model.openBookmark(urlString: "https://local.example/retry")
    #expect(h.driver.retryCreationRequests == [.init(id: remote.id, urlString: "https://local.example/retry")])
    #expect(h.model.tabs.first { $0.id == remote.id }?.creationState == .creating)
    #expect(h.store.loadSnapshot()?.tabs.first { $0.id == "remote" }?.urlString == "https://local.example/retry")
}

@Test @MainActor func pendingPinResetPersistsHomeAndRefusedOrShutdownNavigationLeavesNoIntent() throws {
    let h = try PendingNavigationHarness()
    defer { h.cleanup() }
    let tab = try #require(h.selectedTab)
    let snapshot = h.store.loadSnapshot()
    h.driver.targetedNavigationAdmissionResult = false
    h.model.openBookmark(urlString: "https://refused.example/")
    #expect(h.selectedTab?.urlString == tab.urlString && h.store.loadSnapshot() == snapshot)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    h.driver.targetedNavigationAdmissionResult = true
    #expect(h.model.resetPinnedTabToPinnedURL(id: tab.id))
    #expect(h.selectedTab?.urlString == "https://pinned.example/home")
    #expect(h.selectedTab?.pinnedURLString == "https://pinned.example/home")
    #expect(try h.operations(h.store.pendingSyncQueue(for: h.owner)) == [
        .patchTab(id: "pinned", fields: .init(urlString: "https://pinned.example/home")),
    ])
    h.driver.flushPendingCreateEvents()
    #expect(h.selectedTab?.urlString == "https://pinned.example/home")
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    let count = h.driver.targetedNavigationRequests.count
    h.close(h.model)
    h.model.openBookmark(urlString: "https://after-shutdown.example/")
    #expect(h.driver.targetedNavigationRequests.count == count)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == queue)
}

// MARK: - PendingNavigationHarness

@MainActor private final class PendingNavigationHarness {
    // MARK: Lifecycle

    init(placement: BrowserTabPlacement = .spacePinned) throws {
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("session.sqlite"))
        try store.bindSyncOwner(owner)
        _ = try store.applyRemoteSyncEvents([
            BrowserSyncEvent(
                serverSeq: 1, deviceID: "remote", entityType: "space", entityID: "space", op: "upsert",
                data: .space(.init(
                    id: "space",
                    title: "Space",
                    systemImageName: "globe",
                    rank: 0,
                    isPinnedSectionCollapsed: false,
                    selectedTabID: nil
                )),
                createdAt: "2027-01-15T08:00:00Z"
            ),
            pendingNavigationTabEvent(
                id: "pinned",
                url: "https://pinned.example/current",
                sequence: 2,
                placement: placement
            ),
        ], cursor: 2, for: owner, enableSemanticMutations: true)
        self.model = makeModel(store: store, driver: driver)
        model.handleContextReady()
        try #require(store.pendingSyncQueue(for: owner).isEmpty)
    }

    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pending-navigation-\(UUID())")
    let suiteName = "BrowserPendingNavigationTests.\(UUID())"
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://pending-navigation.example")!, userID: "owner")
    let defaults: UserDefaults
    let store: BrowserSQLiteSessionStore
    let driver = FakeBrowserTabDriver()
    private(set) var model: BrowserChromeModel!

    var databaseURL: URL { directory.appendingPathComponent("session.sqlite") }
    var selectedTab: BrowserChromeModel.Tab? { model.tabs.first { $0.id == model.selectedTabID } }

    func receiveRemote(url: String, sequence: Int) throws -> BrowserTabSessionSnapshot {
        try store.applyRemoteSyncEvents(
            [pendingNavigationTabEvent(id: "remote", url: url, sequence: sequence)], cursor: sequence, for: owner
        )
    }

    func operations(_ queue: [BrowserSyncQueuedMutation]) throws -> [BrowserSyncSemanticOperation] {
        try queue.flatMap {
            guard case .semantic(let mutation) = $0 else {
                throw PendingNavigationTestError.expectedSemanticMutation
            }
            return mutation.operations
        }
    }

    func outboxBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }

    func makeModel(store: BrowserSQLiteSessionStore, driver: FakeBrowserTabDriver) -> BrowserChromeModel {
        BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
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
}

// MARK: - PendingNavigationTestError

private enum PendingNavigationTestError: Error { case expectedSemanticMutation }

private func pendingNavigationTabEvent(
    id: String, url: String, sequence: Int, placement: BrowserTabPlacement = .temporary
) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence, deviceID: "remote", entityType: "tab", entityID: id, op: "upsert",
        data: .tab(.init(
            id: id, spaceID: "space", placement: placement, rank: 0, urlString: url,
            pinnedURLString: placement == .spacePinned ? "https://pinned.example/home" : nil,
            title: nil, userTitleOverride: id == "pinned" ? "Pinned label" : "Remote label", faviconURLString: nil,
            lastActivityAt: "2027-01-15T08:00:00Z"
        )), createdAt: "2027-01-15T08:00:00Z"
    )
}
