// BrowserRemoteSyncProjectionTests.swift

import Foundation
import Testing

@Test(arguments: ["reorder", "delete", "rename"])
@MainActor func localMutationDuringRemoteCreateIsSavedAndSyncedAfterCompletion(operation: String) throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["a", "b"]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()
    let tabA = try #require(harness.model.tabs.first { $0.syncID == "a" })
    let tabB = try #require(harness.model.tabs.first { $0.syncID == "b" })
    let pushesBefore = harness.sync.pushedSnapshots.count
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["a", "b", "c"]))

    switch operation {
    case "reorder":
        harness.model.moveTab(withID: tabB.id, toPlacement: .temporary, atSectionIndex: 0)
    case "delete":
        harness.model.closeTab(id: tabA.id)
    default:
        harness.model.setUserTitleOverride("Local rename", forTabID: tabB.id)
    }
    let expectedIDs = operation == "delete" ? ["b", "c"] : operation == "reorder" ? ["b", "a", "c"] : ["a", "b", "c"]
    #expect(harness.store.savedSnapshots.last?.tabs.compactMap(\.id) == expectedIDs)
    #expect(harness.sync.pushedSnapshots.count == pushesBefore)
    harness.driver.flushPendingCreateEvents()

    #expect(harness.model.tabs.map(\.syncID) == expectedIDs)
    #expect(harness.store.savedSnapshots.last?.tabs.compactMap(\.id) == expectedIDs)
    #expect(harness.sync.pushedSnapshots.count == pushesBefore + 1)
    #expect(harness.sync.pushedSnapshots.last?.tabs.compactMap(\.id) == expectedIDs)
    if operation == "rename" {
        #expect(harness.model.tabs.first { $0.syncID == "b" }?.userTitleOverride == "Local rename")
    }
}

@Test(arguments: [BrowserTabPlacement.app, .spacePinned])
@MainActor func reopenedPersistentTabStillReceivesCreatedCallback(placement: BrowserTabPlacement) throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["a"]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()
    let originalID = try #require(harness.model.tabs.first?.id)
    harness.driver.emitTabCreationState(id: originalID, state: .ready)
    harness.model.moveTab(withID: originalID, toPlacement: placement, atSectionIndex: 0)
    #expect(harness.model.archiveSelectedTab())
    harness.driver.emitClose(id: originalID)
    harness.model.selectTab(id: originalID)
    let reopenedRequest = try #require(harness.driver.createdTabRequests.last)
    let reopenedID = reopenedRequest.id

    harness.driver.emitCreatedTab(
        id: reopenedID,
        title: "Created title",
        urlString: reopenedRequest.urlString,
        isActive: true,
    )

    #expect(harness.model.tabs.count == 1)
    #expect(harness.model.tabs.first?.id == reopenedID)
    #expect(harness.model.tabs.first?.syncID == "a")
    #expect(harness.model.tabs.first?.title == "Created title")
    #expect(harness.model.tabs.first?.urlString == reopenedRequest.urlString)
    #expect(harness.model.tabs.first?.creationState == .creating)
    // Allocation can supply a title; a redirect belongs to the attached engine's
    // address callback and must still update the reopened persistent identity.
    harness.driver.emitTabCreationState(id: reopenedID, state: .ready)
    harness.driver.emitUpdate(id: reopenedID, urlString: "https://redirect.example")
    #expect(harness.model.tabs.first?.id == reopenedID && harness.model.tabs.first?.syncID == "a")
    #expect(harness.model.tabs.first?.title == "Created title")
    #expect(harness.model.tabs.first?.urlString == "https://redirect.example")
    #expect(harness.store.savedSnapshots.last?.tabs.first?.urlString == "https://redirect.example")
}

@Test
@MainActor func remotePlacementChangeRecreatesClosedEnginePlaceholder() throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["a"]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()
    let originalID = try #require(harness.model.tabs.first?.id)
    harness.model.moveTab(withID: originalID, toPlacement: .spacePinned, atSectionIndex: 0)
    #expect(harness.model.archiveSelectedTab())
    harness.driver.emitClose(id: originalID)

    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["a"]))
    harness.driver.flushPendingCreateEvents()

    let tab = try #require(harness.model.tabs.first)
    #expect(tab.id != originalID)
    #expect(tab.syncID == "a")
    #expect(tab.placement == .temporary)
    #expect(harness.driver.createdTabRequests.count == 2)
    #expect(harness.model.selectedTabID == tab.id)
}

@Test
@MainActor func remoteSyncReordersMetadataWithoutReplacingLiveEngines() throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["a", "b"]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()
    let tabA = try #require(harness.model.tabs.first { $0.syncID == "a" })
    let tabB = try #require(harness.model.tabs.first { $0.syncID == "b" })
    harness.driver.emitTabCreationState(id: tabA.id, state: .ready)
    harness.driver.emitTabCreationState(id: tabB.id, state: .ready)
    harness.model.selectTab(id: tabB.id)
    harness.driver.emitUpdate(id: tabB.id, title: "Live title", urlString: "https://live.example/current")
    harness.driver.emitNavigationStateChange(id: tabB.id, canGoBack: true, canGoForward: true)
    harness.driver.emitLoadingStateChange(id: tabB.id, isLoading: true)
    harness.model.presentFindBar()
    harness.model.findQuery = "keep"
    harness.driver.emitFindResult(id: tabB.id, matchCount: 4)
    let selectionCount = harness.driver.selectedTabIDs.count
    let pushesBefore = harness.sync.pushedSnapshots.count

    harness.model.applyRemoteSyncSnapshot(BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "work", title: "Remote space", systemImageName: "star")],
        tabs: [
            BrowserTabSessionSnapshotTab(
                id: "b", urlString: "https://remote.example/stale", userTitleOverride: "Remote name", spaceID: "work",
            ),
            BrowserTabSessionSnapshotTab(id: "a", urlString: "https://a.example", spaceID: "work"),
        ],
    ))

    let survivingB = try #require(harness.model.tabs.first)
    #expect(harness.model.tabs.map(\.id) == [tabB.id, tabA.id])
    #expect(survivingB.userTitleOverride == "Remote name")
    // A remote URL initializes a new identity. A surviving live page keeps its
    // local URL/history, including navigation made after the remote snapshot.
    #expect(survivingB.urlString == "https://live.example/current")
    #expect(survivingB.title == "Live title")
    #expect(survivingB.canGoBack && survivingB.canGoForward && survivingB.isLoading)
    #expect(harness.model.selectedTabID == tabB.id)
    #expect(harness.model.isFindBarPresented)
    #expect(harness.model.findResultMatchCount == 4)
    #expect(harness.driver.createdTabRequests.count == 2)
    #expect(harness.driver.closedTabRequests.isEmpty)
    #expect(harness.driver.activeTabNavigationURLStrings.isEmpty)
    #expect(harness.driver.selectedTabIDs.count == selectionCount)
    #expect(harness.store.savedSnapshots.last?.tabs.map(\.id) == ["b", "a"])
    #expect(harness.store.savedSnapshots.last?.tabs.first?.urlString == "https://live.example/current")
    #expect(harness.sync.pushedSnapshots.count == pushesBefore)
}

@Test
@MainActor func remoteSyncBeforeStartupCallbacksReconcilesHydratedIdentitiesWithoutEcho() throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["a", "b"]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    // Restore now hydrates logical tabs and saves once synchronously. Delayed
    // placeholder callbacks cannot defer remote application or replay old state.
    let savedBefore = harness.store.savedSnapshots.count
    let pushesBefore = harness.sync.pushedSnapshots.count
    let originalB = try #require(harness.driver.createdTabRequests.last?.id)
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["b", "obsolete"]))
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["b", "c"]))

    harness.driver.flushPendingCreateEvents()

    #expect(harness.driver.createdTabRequests.map(\.urlString) == [
        "https://a.example", "https://b.example", "https://obsolete.example", "https://c.example",
    ])

    #expect(harness.model.tabs.map(\.syncID) == ["b", "c"])
    #expect(harness.model.tabs.first?.id == originalB)
    #expect(harness.store.savedSnapshots.count == savedBefore + 1)
    #expect(harness.store.savedSnapshots.last?.tabs.map(\.id) == ["b", "c"])
    #expect(harness.sync.pushedSnapshots.count == pushesBefore)
    for request in harness.driver.closedTabRequests {
        harness.driver.emitClose(id: request.id)
    }
    #expect(harness.sync.pushedSnapshots.count == pushesBefore)
}

@Test
@MainActor func remoteSyncMovesSelectedLiveTabBetweenSpacesWithoutChangingEngine() throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["a"]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()
    let engineID = try #require(harness.model.tabs.first?.id)
    let selectionCount = harness.driver.selectedTabIDs.count

    harness.model.applyRemoteSyncSnapshot(BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(id: "work", title: "Work", systemImageName: "briefcase"),
            BrowserSpaceSessionSnapshot(id: "read", title: "Read", systemImageName: "book"),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(
                id: "a", urlString: "https://remote.example", pinnedURLString: "https://pinned.example",
                placement: .spacePinned, spaceID: "read",
            ),
        ],
    ))

    #expect(harness.model.tabs.first?.id == engineID)
    #expect(harness.model.tabs.first?.spaceID == "read")
    #expect(harness.model.tabs.first?.placement == .spacePinned)
    #expect(harness.model.tabs.first?.pinnedURLString == "https://pinned.example")
    #expect(harness.model.selectedTabID == engineID)
    #expect(harness.model.selectedSpaceID == "read")
    #expect(harness.driver.selectedTabIDs.count == selectionCount)
    #expect(harness.driver.createdTabRequests.count == 1)
    #expect(harness.driver.closedTabRequests.isEmpty)
}

@Test
@MainActor func remoteSyncCreateBindingsSurviveOutOfOrderCallbacksAndOverlappingPulls() throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot([]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    let savedBefore = harness.store.savedSnapshots.count
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["a", "b", "c"]))
    let requests = harness.driver.createdTabRequests
    let requestA = try #require(requests.first { $0.urlString == "https://a.example" })
    let requestB = try #require(requests.first { $0.urlString == "https://b.example" })
    let requestC = try #require(requests.first { $0.urlString == "https://c.example" })
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["c", "b"]))
    #expect(harness.driver.createdTabRequests.count == 3)
    #expect(harness.driver.closedTabRequests.map(\.id) == [requestA.id])

    harness.driver.emitCreatedTab(id: requestC.id, urlString: requestC.urlString, isActive: false)
    harness.driver.emitCreatedTab(id: requestA.id, urlString: requestA.urlString, isActive: true)
    #expect(harness.store.savedSnapshots.count == savedBefore)
    #expect(!harness.model.tabs.contains { $0.syncID == "a" })
    harness.driver.emitCreatedTab(id: requestB.id, urlString: requestB.urlString, isActive: false)

    #expect(harness.model.tabs.map(\.syncID) == ["c", "b"])
    #expect(harness.model.tabs.map(\.id) == [requestC.id, requestB.id])
    #expect(harness.model.tabs.map(\.urlString) == ["https://c.example", "https://b.example"])
    #expect(harness.driver.closedTabRequests.count(where: { $0.id == requestA.id }) == 2)
    #expect(harness.store.savedSnapshots.count == savedBefore + 1)
    #expect(harness.store.savedSnapshots.last?.tabs.map(\.id) == ["c", "b"])
    harness.driver.emitCreatedTab(id: requestB.id, urlString: requestB.urlString, isActive: true)
    #expect(harness.model.tabs.map(\.syncID) == ["c", "b"])
}

@Test
@MainActor func remoteSyncRemovalFinishesWithoutWaitingForObsoleteCreateCallback() throws {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot([]))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["obsolete"]))
    let request = try #require(harness.driver.createdTabRequests.last)
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot([]))

    #expect(harness.store.savedSnapshots.last?.tabs.isEmpty == true)
    #expect(harness.model.tabs.isEmpty)
    harness.driver.emitClose(id: request.id)
    harness.driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: true)
    #expect(harness.model.tabs.isEmpty)
    #expect(harness.driver.closedTabRequests.count(where: { $0.id == request.id }) == 2)
}

@Test
@MainActor func remoteSyncBeforeContextReadyStartsLatestProjectionDirectly() {
    let harness = RemoteProjectionHarness(snapshot: projectionSnapshot(["old"]))
    defer { harness.cleanup() }
    harness.model.applyRemoteSyncSnapshot(projectionSnapshot(["remote"]))
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()

    #expect(harness.driver.createdTabRequests.map(\.urlString) == ["https://remote.example"])
    #expect(harness.model.tabs.map(\.syncID) == ["remote"])
    #expect(harness.sync.pushedSnapshots.isEmpty)
}

@Test
@MainActor func remoteDeletionOfEverySpaceJournalsFreshParentBeforeNewTabs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFallback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Browser.sqlite"))
    let owner = try BrowserSyncOwner(baseURL: #require(URL(string: "https://sync.example")), userID: "owner")
    let initial = BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(
            id: BrowserChromeModel.defaultSpaceID,
            title: "Old",
            systemImageName: "star",
        )],
        tabs: [],
    )
    store.saveSnapshot(initial)
    try store.bindSyncOwner(owner)
    let harness = RemoteProjectionHarness(snapshot: initial)
    defer { harness.cleanup() }
    let model = BrowserChromeModel(
        tabDriver: harness.driver, sessionSnapshotStore: store,
        sessionPreferencesStore: InMemorySessionPreferencesStore(),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: harness.defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: harness.defaults),
        extensionManager: FakeBrowserExtensionManager(), syncCoordinator: harness.sync,
        windowTitleHandler: { _ in }, allTabsClosedHandler: {},
    )
    model.handleContextReady()
    let remote = try store.applyRemoteSyncEvents([BrowserSyncEvent(
        serverSeq: 100, deviceID: "other", entityType: "space", entityID: BrowserChromeModel.defaultSpaceID,
        op: "delete", data: .deleted(id: BrowserChromeModel.defaultSpaceID), createdAt: "2026-10-03T00:00:00Z",
    )], cursor: 100, for: owner)
    model.applyRemoteSyncSnapshot(remote)
    let newSpaceID = try #require(model.spaces.first?.id)
    #expect(newSpaceID != BrowserChromeModel.defaultSpaceID)
    model.createNewTab()
    harness.driver.flushPendingCreateEvents()
    let changes = try store.pendingSyncMutations(for: owner).flatMap(\.changes)
    #expect(changes.contains { $0.entityType == .space && $0.entityID == newSpaceID && $0.op == .upsert })
    #expect(changes.contains { $0.entityType == .tab && $0.tabData?.spaceID == newSpaceID })
    #expect(harness.sync.pushedSnapshots.last?.spaces?.first?.id == newSpaceID)
}

// MARK: - RemoteProjectionHarness

@Test(arguments: [false, true])
@MainActor func remoteSpaceDeletionKeepsFavoriteEngineAndSelection(deleteEverySpace: Bool) throws {
    let firstSpace = BrowserSpaceSessionSnapshot(id: "work", title: "Work", systemImageName: "briefcase")
    let otherSpace = BrowserSpaceSessionSnapshot(id: "other", title: "Other", systemImageName: "star")
    let favorite = BrowserTabSessionSnapshotTab(
        id: "favorite", urlString: "https://favorite.example", placement: .app, spaceID: "work",
    )
    let child = BrowserTabSessionSnapshotTab(id: "child", urlString: "https://child.example", spaceID: "work")
    let survivor = BrowserTabSessionSnapshotTab(id: "survivor", urlString: "https://survivor.example", spaceID: "other")
    let harness = RemoteProjectionHarness(snapshot: BrowserTabSessionSnapshot(
        spaces: [firstSpace, otherSpace], tabs: [favorite, child, survivor],
    ))
    defer { harness.cleanup() }
    harness.model.handleContextReady()
    harness.driver.flushPendingCreateEvents()
    let favoriteEngineID = try #require(harness.model.appTabs.first?.id)
    harness.model.selectTab(id: favoriteEngineID)
    let previousCreates = harness.driver.createdTabRequests.count

    harness.model.applyRemoteSyncSnapshot(BrowserTabSessionSnapshot(
        spaces: deleteEverySpace ? nil : [otherSpace],
        tabs: deleteEverySpace ? [favorite] : [favorite, survivor],
    ))

    #expect(harness.model.appTabs.map(\.id) == [favoriteEngineID])
    #expect(harness.model.selectedTabID == favoriteEngineID)
    #expect(harness.model.spaces.contains { $0.id == harness.model.selectedSpaceID })
    #expect(harness.model.appTabs.first?.spaceID == harness.model.selectedSpaceID)
    #expect(!harness.driver.closedTabRequests.contains { $0.id == favoriteEngineID })
    #expect(harness.driver.createdTabRequests.count == previousCreates)
    #expect(harness.store.savedSnapshots.last?.tabs.contains { $0.id == "favorite" } == true)
}

// MARK: - RemoteProjectionHarness

@MainActor private struct RemoteProjectionHarness {
    // MARK: Internal

    let suiteName: String
    let defaults: UserDefaults
    let driver: FakeBrowserTabDriver
    let store: InMemorySessionSnapshotStore
    let sync: ProjectionSyncRecorder
    let model: BrowserChromeModel

    init(snapshot: BrowserTabSessionSnapshot) {
        self.suiteName = "BrowserRemoteSyncProjectionTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.driver = FakeBrowserTabDriver()
        self.store = InMemorySessionSnapshotStore(loadedSnapshot: snapshot)
        self.sync = ProjectionSyncRecorder()
        self.model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            syncCoordinator: sync,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
    }

    func cleanup() { defaults.removePersistentDomain(forName: suiteName) }
}

// MARK: - ProjectionSyncRecorder

@MainActor private final class ProjectionSyncRecorder: BrowserSyncCoordinating {
    var pushedSnapshots = [BrowserTabSessionSnapshot]()

    func schedulePush(snapshot: BrowserTabSessionSnapshot) { pushedSnapshots.append(snapshot) }
    func schedulePull() {}
}

private func projectionSnapshot(_ ids: [String]) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "work", title: "Work", systemImageName: "briefcase")],
        tabs: ids.map { BrowserTabSessionSnapshotTab(id: $0, urlString: "https://\($0).example", spaceID: "work") },
    )
}
