// BrowserSyncProjectionRestartTests.swift

import Foundation
import Testing

@Test(arguments: [0, 1])
@MainActor func committedRemoteProjectionRestoresAfterInterruptedModelCallbacks(deliveredCallbacks: Int) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectionRestart-\(UUID())")
    let suiteName = BrowserTestDefaults.suiteName("ProjectionRestart")
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    let databaseURL = directory.appendingPathComponent("Browser.sqlite")
    let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    let owner = try BrowserSyncOwner(baseURL: #require(URL(string: "https://sync.example")), userID: "owner")
    let initial = projectionRestartSnapshot(ids: ["a", "b", "c"])
    try store.writeSessionBatch([.init(snapshot: initial, origin: .local(syncMove: nil))])
    try store.bindSyncOwner(owner)
    let seed = try #require(store.pendingSyncMutations(for: owner).first)
    let seedEvents = try seed.changes.enumerated().map {
        try projectionRestartEvent($0.element, sequence: $0.offset + 1)
    }
    _ = try store.acknowledgeSyncMutation(id: seed.id, events: seedEvents, for: owner)
    _ = try store.applyRemoteSyncEvents([], cursor: seedEvents.count, for: owner, enableSemanticMutations: true)
    let driver = FakeBrowserTabDriver()
    var model: BrowserChromeModel? = projectionRestartModel(driver: driver, store: store, defaults: defaults)
    model?.handleContextReady()
    driver.flushPendingCreateEvents()
    #expect(model?.tabs.map(\.syncID) == ["a", "b", "c"])
    #expect(try store.pendingSyncQueue(for: owner).isEmpty)

    // Exercise the production storage-to-model handoff: one transaction records
    // a deletion, reordered survivors, two new identities and the pull cursor.
    let desired = projectionRestartSnapshot(ids: ["c", "b", "d", "e"])
    let changes = BrowserSyncOutboxProjection.canonicalChanges(desired) + [BrowserSyncChange(
        entityType: .tab, entityID: "a", op: .delete, spaceData: nil, tabData: nil,
    )]
    let events = try changes.enumerated().map { try projectionRestartEvent($0.element, sequence: 100 + $0.offset) }
    let committedCursor = try #require(events.last?.serverSeq)
    let projected = try store.applyRemoteSyncEvents(events, cursor: committedCursor, for: owner)
    let createsBefore = driver.createdTabRequests.count
    model?.applyRemoteSyncSnapshot(projected)
    let pendingCreates = Array(driver.createdTabRequests.dropFirst(createsBefore))
    #expect(pendingCreates.map(\.urlString) == ["https://d.example/", "https://e.example/"])
    for request in pendingCreates.prefix(deliveredCallbacks) {
        driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: request.isActive)
    }
    #expect(model?.tabs.map(\.syncID) == (deliveredCallbacks == 0 ? ["c", "b"] : ["c", "b", "d"]))
    #expect(store.loadSnapshot() == projected)
    #expect(try store.syncCursor(for: owner) == committedCursor)
    #expect(try store.pendingSyncQueue(for: owner).isEmpty)

    // Drop the model without finish/closure saves, as a process interruption
    // would. No subsequent remote pull or event replay supplies the missing tabs.
    let interruptedModel = { [weak model] in model }
    model = nil
    #expect(interruptedModel() == nil)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    #expect(reopened.loadSnapshot() == projected)
    #expect(try reopened.syncCursor(for: owner) == committedCursor)
    #expect(try reopened.pendingSyncQueue(for: owner).isEmpty)

    let restoredDriver = FakeBrowserTabDriver()
    let restored = projectionRestartModel(driver: restoredDriver, store: reopened, defaults: defaults)
    defer { restored.prepareForTermination() }
    restored.handleContextReady()
    #expect(restoredDriver.createdTabRequests.map(\.urlString) == desired.tabs.map(\.urlString))
    restoredDriver.flushPendingCreateEvents()
    #expect(restored.tabs.map(\.syncID) == ["c", "b", "d", "e"])
    #expect(restored.tabs.map(\.urlString) == desired.tabs.map(\.urlString))
    #expect(restored.tabs.map(\.userTitleOverride) == desired.tabs.map(\.userTitleOverride))
    #expect(restored.tabs.allSatisfy { $0.spaceID == "work" })
    #expect(restored.sessionPersistenceFailure == nil)
    #expect(!restored.hasUncommittedSessionWrites)
    let durable = try #require(reopened.loadSnapshot())
    // Selected indices are local preferences; canonical content and stable
    // identities must match without journaling any restoration echo or delete.
    #expect(BrowserSyncOutboxProjection.canonicalChanges(durable) == changes.filter { $0.op == .upsert })
    #expect(try reopened.syncCursor(for: owner) == committedCursor)
    #expect(try reopened.pendingSyncQueue(for: owner).isEmpty)
}

@MainActor private func projectionRestartModel(
    driver: FakeBrowserTabDriver, store: BrowserSQLiteSessionStore, defaults: UserDefaults,
) -> BrowserChromeModel {
    let preferences = BrowserUserPreferencesStore(userDefaults: defaults)
    preferences.restoreWindowsOnLaunch = true
    return BrowserChromeModel(
        tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
        commandBarSuggestionProvider: FakeSuggestionProvider(), userPreferencesStore: preferences,
        shortcutStore: BrowserShortcutStore(userDefaults: defaults), extensionManager: FakeBrowserExtensionManager(),
        dateProvider: { Date(timeIntervalSince1970: projectionRestartTimestamp) },
        windowTitleHandler: { _ in }, allTabsClosedHandler: {},
    )
}

private let projectionRestartTimestamp: TimeInterval = 1_800_000_000

private func projectionRestartSnapshot(ids: [String]) -> BrowserTabSessionSnapshot {
    .init(
        spaces: [.init(id: "work", title: "Work", systemImageName: "briefcase")],
        tabs: ids.map { id in
            .init(
                id: id, urlString: "https://\(id).example/", userTitleOverride: "Name \(id)", spaceID: "work",
                lastActivityTimestamp: projectionRestartTimestamp,
            )
        },
    )
}

private func projectionRestartEvent(_ change: BrowserSyncChange, sequence: Int) throws -> BrowserSyncEvent {
    let data: BrowserSyncEventData
    if change.op == .delete {
        data = .deleted(id: change.entityID)
    } else if let value = change.spaceData {
        data = .space(.init(
            id: change.entityID, title: value.title, systemImageName: value.systemImageName, rank: value.rank,
            isPinnedSectionCollapsed: value.isPinnedSectionCollapsed, selectedTabID: value.selectedTabID,
        ))
    } else if let value = change.tabData {
        data = .tab(.init(
            id: change.entityID, spaceID: value.spaceID, placement: value.placement, rank: value.rank,
            urlString: value.urlString, pinnedURLString: value.pinnedURLString, title: value.title,
            userTitleOverride: value.userTitleOverride, faviconURLString: value.faviconURLString,
            lastActivityAt: value.lastActivityAt,
        ))
    } else {
        throw BrowserRemoteSyncError.invalidMutationReceipt
    }
    return .init(
        serverSeq: sequence, deviceID: "remote", entityType: change.entityType.rawValue, entityID: change.entityID,
        op: change.op.rawValue, data: data, createdAt: "2026-10-03T00:00:00Z",
    )
}
