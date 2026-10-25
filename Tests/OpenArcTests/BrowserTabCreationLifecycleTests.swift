// BrowserTabCreationLifecycleTests.swift

import Foundation
import GRDB
import Testing

@Test(arguments: ["direct", "reload", "force-reload"])
@MainActor func failedTabCreationRetriesSameIdentityWithoutChangingDurableIntent(action: String) throws {
    let h = try TabCreationLifecycleHarness()
    defer { h.cleanup() }
    let original = try #require(h.model.tabs.first { $0.syncID == "pinned" })
    h.model.selectTab(id: original.id)
    h.model.setUserTitleOverride("Queued local name", forTabID: original.id)
    let before = try h.diskState()
    try #require(before.queue.count == 1)
    let order = h.model.tabs.map(\.id)
    let selected = h.model.selectedTabID
    let creationCount = h.driver.createdTabRequests.count

    #expect(h.model.tabs.first { $0.id == original.id }?.creationState == .creating)
    #expect(!h.model.retrySelectedTabCreation())
    h.driver.emitTabCreationState(id: original.id, state: .failed)
    #expect(h.model.tabs.first { $0.id == original.id }?.creationState == .failed)
    switch action {
    case "reload": h.model.reloadCurrentTab()
    case "force-reload": h.model.forceReloadCurrentTab()
    default: #expect(h.model.retrySelectedTabCreation())
    }
    #expect(h.driver.retryCreationRequests == [.init(id: original.id, urlString: original.urlString)])
    #expect(h.driver.reloadCount == 0 && h.driver.forceReloadCount == 0)
    #expect(h.model.tabs.first { $0.id == original.id }?.creationState == .creating)
    #expect(!h.model.retrySelectedTabCreation(), "An admitted retry cannot start another simultaneous attempt")
    h.driver.emitTabCreationState(id: original.id, state: .ready)
    #expect(h.model.tabs.first { $0.id == original.id }?.creationState == .ready)
    h.driver.emitTabCreationState(id: original.id, state: .failed)
    #expect(
        h.model.tabs.first { $0.id == original.id }?.creationState == .ready,
        "Late refusal cannot regress readiness",
    )
    #expect(!h.model.retrySelectedTabCreation())
    let after = try #require(h.model.tabs.first { $0.id == original.id })
    #expect(after.syncID == original.syncID && after.placement == .spacePinned)
    #expect(after.pinnedURLString == "https://pinned.example/home")
    #expect(after.urlString == "https://pinned.example/current" && after.userTitleOverride == "Queued local name")
    #expect(after.spaceID == original.spaceID && after.lastActivityAt == original.lastActivityAt)
    #expect(h.model.tabs.map(\.id) == order && h.model.selectedTabID == selected)
    #expect(h.driver.createdTabRequests.count == creationCount)
    #expect(try h.diskState() == before, "Runtime creation state must not rewrite snapshot or immutable outbox")

    h.model.reloadCurrentTab()
    h.model.forceReloadCurrentTab()
    #expect(h.driver.reloadCount == 1 && h.driver.forceReloadCount == 1)
    #expect(h.driver.retryCreationRequests.count == 1)
}

@Test @MainActor func repeatedTabCreationRefusalRemainsFailedAndAdmittedRetryCanFailAgain() throws {
    let h = try TabCreationLifecycleHarness()
    defer { h.cleanup() }
    let tab = try #require(h.model.tabs.first { $0.syncID == "pinned" })
    h.model.selectTab(id: tab.id)
    let before = try h.diskState()
    h.driver.emitTabCreationState(id: tab.id, state: .failed)
    h.driver.retryTabCreationAdmissionResult = false
    #expect(!h.model.retrySelectedTabCreation())
    #expect(h.model.tabs.first { $0.id == tab.id }?.creationState == .failed)
    #expect(!h.model.retrySelectedTabCreation())
    #expect(h.model.tabs.first { $0.id == tab.id }?.creationState == .failed)
    h.driver.retryTabCreationAdmissionResult = true
    #expect(h.model.retrySelectedTabCreation())
    #expect(h.model.tabs.first { $0.id == tab.id }?.creationState == .creating)
    h.driver.emitTabCreationState(id: tab.id, state: .failed)
    #expect(h.model.tabs.first { $0.id == tab.id }?.creationState == .failed)
    #expect(h.driver.retryCreationRequests.map(\.id) == [tab.id, tab.id, tab.id])
    #expect(h.driver.createdTabRequests.count == 2)
    #expect(try h.diskState() == before)
}

@Test(arguments: [false, true])
@MainActor func lateCreationOutcomesCannotRestoreClosedTabOrDeletedSpace(deleteSpace: Bool) throws {
    let h = try TabCreationLifecycleHarness()
    defer { h.cleanup() }
    let tab = try #require(h.model.tabs.first { $0.syncID == "pinned" })
    if deleteSpace {
        #expect(h.model.deleteSpace(id: "first"))
    } else {
        #expect(h.model.closeTab(id: tab.id, registersUndo: false))
    }
    let before = try h.diskState()
    let order = h.model.tabs.map(\.id)
    let selected = h.model.selectedTabID
    for state in [BrowserTabCreationState.creating, .failed, .ready] {
        h.driver.emitTabCreationState(id: tab.id, state: state)
        h.driver.emitTabCreationState(id: "unknown-engine-id", state: state)
    }
    #expect(h.model.tabs.map(\.id) == order && h.model.selectedTabID == selected)
    #expect(!h.model.tabs.contains { $0.syncID == "pinned" || $0.id == tab.id })
    #expect(h.driver.retryCreationRequests.isEmpty)
    #expect(try h.diskState() == before)
}

@Test @MainActor func failedRemoteTabRemainsDurableAndDoesNotStallProjectionOrEchoOnRetry() throws {
    let h = try TabCreationLifecycleHarness()
    defer { h.cleanup() }
    let remoteTab = BrowserTabSessionSnapshotTab(
        id: "remote", urlString: "https://remote.example/current", pinnedURLString: "https://remote.example/home",
        userTitleOverride: "Remote label", placement: .spacePinned, spaceID: "second",
        lastActivityTimestamp: tabCreationLifecycleDate.timeIntervalSince1970,
    )
    let remote = try h.store.applyRemoteSyncEvents(
        tabCreationLifecycleEvents(.init(tabs: [remoteTab]), startingAt: 10), cursor: 10, for: h.owner,
    )
    let pushesBefore = h.sync.pushedSnapshots.count
    h.model.applyRemoteSyncSnapshot(remote)
    let request = try #require(h.driver.createdTabRequests.last { $0.urlString == remoteTab.urlString })
    h.driver.flushPendingCreateEvents()
    h.driver.emitTabCreationState(id: request.id, state: .failed)
    let failed = try #require(h.model.tabs.first { $0.syncID == "remote" })
    #expect(failed.id == request.id && failed.creationState == .failed)
    #expect(failed.userTitleOverride == "Remote label" && failed.pinnedURLString == remoteTab.pinnedURLString)
    #expect(h.store.loadSnapshot()?.tabs.contains { $0.id == "remote" } == true)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    #expect(h.sync.pushedSnapshots.count == pushesBefore, "Engine failure is not a local sync mutation")
    h.model.selectTab(id: request.id)
    let beforeRetry = try h.diskState()
    #expect(h.model.retrySelectedTabCreation())
    h.driver.emitTabCreationState(id: request.id, state: .failed)
    #expect(h.model.tabs.first { $0.syncID == "remote" }?.id == request.id)
    #expect(h.model.tabs.first { $0.syncID == "remote" }?.creationState == .failed)
    #expect(try h.diskState() == beforeRetry)

    // Completion of the logical projection must not wait for engine readiness:
    // a later local rename can be persisted and scheduled normally.
    let pushesBeforeRename = h.sync.pushedSnapshots.count
    h.model.setUserTitleOverride("Local edit while failed", forTabID: request.id)
    #expect(h.sync.pushedSnapshots.count == pushesBeforeRename + 1)
    let queue = try h.store.pendingSyncQueue(for: h.owner)
    try #require(queue.count == 1)
    guard case .semantic(let mutation) = queue[0] else { Issue.record("Expected semantic metadata edit")
        return
    }
    #expect(mutation.operations == [.patchTab(
        id: "remote", fields: .init(userTitleOverride: .set("Local edit while failed")),
    )])
    let outboxBytes = try h.outboxBytes()
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let nextDriver = FakeBrowserTabDriver()
    let nextModel = h.makeModel(store: reopened, driver: nextDriver)
    defer { h.close(nextModel) }
    nextModel.handleContextReady()
    let restored = try #require(nextModel.tabs.first { $0.syncID == "remote" })
    #expect(restored.creationState == .creating, "Failed runtime state must not poison a new browser process")
    #expect(restored.userTitleOverride == "Local edit while failed" && restored.pinnedURLString == remoteTab
        .pinnedURLString)
    nextDriver.flushPendingCreateEvents()
    #expect(nextModel.tabs.first { $0.syncID == "remote" }?.id == restored.id)
    #expect(try reopened.pendingSyncQueue(for: h.owner) == queue)
    #expect(try h.outboxBytes() == outboxBytes)
}

@Test(arguments: [false, true])
@MainActor func lateReadinessAfterTerminationClosesRecordBeforeDriverAcknowledges(pendingRemote: Bool) throws {
    let h = try TabCreationLifecycleHarness()
    defer { h.cleanup() }
    let id: String
    if pendingRemote {
        let remoteTab = BrowserTabSessionSnapshotTab(
            id: "late-remote", urlString: "https://late.example/", spaceID: "second",
            lastActivityTimestamp: tabCreationLifecycleDate.timeIntervalSince1970,
        )
        let remote = try h.store.applyRemoteSyncEvents(
            tabCreationLifecycleEvents(.init(tabs: [remoteTab]), startingAt: 10), cursor: 10, for: h.owner,
        )
        h.model.applyRemoteSyncSnapshot(remote)
        id = try #require(h.driver.createdTabRequests.last { $0.urlString == remoteTab.urlString }).id
        #expect(!h.model.tabs.contains { $0.id == id })
    } else {
        id = try #require(h.model.tabs.first { $0.syncID == "pinned" }).id
    }
    h.model.prepareForTermination()
    let before = try h.diskState()
    let closeCount = h.driver.closedTabRequests.count
    h.driver.emitTabCreationState(id: id, state: .ready)
    // The bridge marks a force-closed record closing synchronously, so the
    // driver's following ACK cannot enable the initial navigation.
    #expect(Array(h.driver.closedTabRequests.dropFirst(closeCount)) == [.init(id: id, forceClose: true)])
    #expect(h.model.tabs.first { $0.id == id }?.creationState != .ready)
    #expect(try h.diskState() == before)
}

// MARK: - TabCreationLifecycleHarness

@MainActor private final class TabCreationLifecycleHarness {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-creation-\(UUID())")
    let suiteName = "BrowserTabCreationLifecycleTests.\(UUID())"
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://tab-creation.example")!, userID: "owner")
    let defaults: UserDefaults
    let store: BrowserSQLiteSessionStore
    let driver = FakeBrowserTabDriver()
    let sync = TabCreationLifecycleSyncRecorder()
    private(set) var model: BrowserChromeModel!

    var databaseURL: URL { directory.appendingPathComponent("session.sqlite") }

    init() throws {
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("session.sqlite"))
        try store.bindSyncOwner(owner)
        let initial = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "first", title: "First", systemImageName: "globe", selectedTabIndex: 0),
                .init(id: "second", title: "Second", systemImageName: "star", selectedTabIndex: 0),
            ], tabs: [
                .init(
                    id: "pinned", urlString: "https://pinned.example/current",
                    pinnedURLString: "https://pinned.example/home",
                    userTitleOverride: "Pinned label", placement: .spacePinned, spaceID: "first",
                    lastActivityTimestamp: tabCreationLifecycleDate.timeIntervalSince1970,
                ),
                .init(
                    id: "anchor", urlString: "https://anchor.example", spaceID: "second",
                    lastActivityTimestamp: tabCreationLifecycleDate.timeIntervalSince1970,
                ),
            ],
        )
        _ = try store.applyRemoteSyncEvents(
            tabCreationLifecycleEvents(initial, startingAt: 1), cursor: 4, for: owner, enableSemanticMutations: true,
        )
        self.model = makeModel(store: store, driver: driver)
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        try #require(store.pendingSyncQueue(for: owner).isEmpty)
    }

    func diskState() throws -> TabCreationLifecycleDiskState {
        let database = try DatabaseQueue(path: databaseURL.path)
        return try TabCreationLifecycleDiskState(
            snapshot: store.loadSnapshotForSync(for: owner), queue: store.pendingSyncQueue(for: owner),
            outboxBytes: outboxBytes(), baseline: database.read { db in
                try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1")
            }, cursor: store.syncCursor(for: owner),
        )
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
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            dateProvider: { tabCreationLifecycleDate }, windowTitleHandler: { _ in }, allTabsClosedHandler: {},
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

// MARK: - TabCreationLifecycleDiskState

private struct TabCreationLifecycleDiskState: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [BrowserSyncQueuedMutation]
    let outboxBytes: [Data]
    let baseline: Data?
    let cursor: Int
}

// MARK: - TabCreationLifecycleSyncRecorder

@MainActor private final class TabCreationLifecycleSyncRecorder: BrowserSyncCoordinating {
    var pushedSnapshots = [BrowserTabSessionSnapshot]()

    func schedulePush(snapshot: BrowserTabSessionSnapshot) { pushedSnapshots.append(snapshot) }
    func schedulePull() {}
}

private let tabCreationLifecycleDate = Date(timeIntervalSince1970: 1_800_000_000)

private func tabCreationLifecycleEvents(
    _ snapshot: BrowserTabSessionSnapshot, startingAt sequence: Int,
) -> [BrowserSyncEvent] {
    BrowserSyncOutboxProjection.canonicalChanges(snapshot).enumerated().map { index, change in
        let data: BrowserSyncEventData =
            if let space = change.spaceData {
                .space(.init(
                    id: change.entityID, title: space.title, systemImageName: space.systemImageName, rank: space.rank,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed, selectedTabID: space.selectedTabID,
                ))
            } else if let tab = change.tabData {
                .tab(.init(
                    id: change.entityID, spaceID: tab.spaceID, placement: tab.placement, rank: tab.rank,
                    urlString: tab.urlString, pinnedURLString: tab.pinnedURLString, title: tab.title,
                    userTitleOverride: tab.userTitleOverride, faviconURLString: tab.faviconURLString,
                    lastActivityAt: tab.lastActivityAt,
                ))
            } else {
                .deleted(id: change.entityID)
            }
        return BrowserSyncEvent(
            serverSeq: sequence + index, deviceID: "remote", entityType: change.entityType.rawValue,
            entityID: change.entityID, op: change.op.rawValue, data: data, createdAt: "2027-01-15T08:00:00Z",
        )
    }
}
