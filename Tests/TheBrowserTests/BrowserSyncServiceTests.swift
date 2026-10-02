import Foundation
import Testing

@Test
@MainActor func syncServiceCancelsSupersededPushDebounce() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let older = syncServiceSnapshot(tabID: "older")
    let latest = syncServiceSnapshot(tabID: "latest")

    harness.service.schedulePush(snapshot: older)
    harness.service.schedulePush(snapshot: latest)
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pushes.map(\.snapshot) == [latest])
}

@Test
@MainActor func syncServicePushReceiptDoesNotSkipUnreadRemoteEvents() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    harness.store.saveSyncCursor(3)
    harness.remote.pushResponse = BrowserSyncPushResponse(cursor: 99, events: [])
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 10, events: [])

    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "local"))
    await harness.service.waitForPendingOperations()
    #expect(harness.store.syncCursor() == 3)

    harness.service.schedulePull()
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pullCursors == [3])
    #expect(harness.store.syncCursor() == 10)
}

@Test
@MainActor func syncServiceDoesNotSendDebouncedSnapshotUnderAnotherAccount() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }

    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-a"))
    harness.auth.session = syncServiceSession(userID: "account-b")
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pushes.isEmpty)
}

@Test
@MainActor func syncServiceAppliesOldDeleteReceiptWithoutOverwritingLaterLocalEdits() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let deleted = BrowserTabSessionSnapshotTab(id: "deleted", urlString: "https://deleted.example", spaceID: "space")
    let sentSurvivor = BrowserTabSessionSnapshotTab(id: "survivor", urlString: "https://old.example", spaceID: "space")
    let sent = BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: [deleted, sentSurvivor]
    )
    let laterSurvivor = BrowserTabSessionSnapshotTab(
        id: "survivor", urlString: "https://edited.example", userTitleOverride: "Edited", spaceID: "space"
    )
    let laterTab = BrowserTabSessionSnapshotTab(id: "new", urlString: "https://new.example", spaceID: "space")
    let folders = [
        BrowserPinnedTabFolderSessionSnapshot(id: "parent", spaceID: "space", title: "Parent"),
        BrowserPinnedTabFolderSessionSnapshot(id: "child", spaceID: "space", parentFolderID: "parent", title: "Child"),
    ]
    let later = BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(
            id: "space",
            title: "Renamed",
            systemImageName: "star",
            selectedTabIndex: 2
        )],
        pinnedTabFolders: folders,
        tabs: [deleted, laterSurvivor, laterTab]
    )
    let expected = BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(
            id: "space",
            title: "Renamed",
            systemImageName: "star",
            selectedTabIndex: 1
        )],
        pinnedTabFolders: folders,
        tabs: [laterSurvivor, laterTab]
    )
    harness.store.saveSnapshot(sent)
    harness.store.saveSyncCursor(100)
    harness.remote.pushResponse = BrowserSyncPushResponse(
        cursor: 200,
        events: [
            BrowserSyncEvent(
                serverSeq: 2, deviceID: "remote", entityType: "tab", entityID: "deleted", op: "delete",
                data: .deleted(id: "deleted"), createdAt: "2026-10-03T00:00:00Z"
            ),
            BrowserSyncEvent(
                serverSeq: 200, deviceID: "device-account-a", entityType: "tab", entityID: "survivor", op: "upsert",
                data: .tab(BrowserSyncEventTabData(
                    id: "survivor", spaceID: "space", placement: .temporary, rank: 1,
                    urlString: "https://old.example", pinnedURLString: nil, title: nil,
                    userTitleOverride: "Old", faviconURLString: nil, lastActivityAt: nil
                )), createdAt: "2026-10-03T00:00:00Z"
            ),
        ]
    )
    let releasePush = SyncServiceGate()
    harness.remote.pushGate = releasePush
    defer { releasePush.open() }

    harness.service.schedulePush(snapshot: sent)
    await harness.remote.pushStarted.wait()
    harness.store.saveSnapshot(later)
    releasePush.open()
    await harness.service.waitForPendingOperations()

    #expect(harness.store.loadSnapshot() == expected)
    #expect(harness.store.syncCursor() == 100)
    #expect(harness.applier.snapshots == [expected])

    harness.remote.pushResponse = BrowserSyncPushResponse(cursor: 201, events: [])
    harness.service.schedulePush(snapshot: expected)
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.last?.previousSnapshot?.tabs == [sentSurvivor])
    #expect(harness.applier.snapshots == [expected])
}

@Test
@MainActor func syncServiceDoesNotReapplyDeleteReceiptWhenLocalStateAlreadyMatches() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "survivor")
    harness.store.saveSnapshot(local)
    harness.remote.pushResponse = BrowserSyncPushResponse(
        cursor: 20,
        events: [
            BrowserSyncEvent(
                serverSeq: 1, deviceID: "remote", entityType: "tab", entityID: "absent", op: "delete",
                data: .deleted(id: "absent"), createdAt: "2026-10-03T00:00:00Z"
            ),
        ]
    )

    harness.service.schedulePush(snapshot: local)
    await harness.service.waitForPendingOperations()

    #expect(harness.store.loadSnapshot() == local)
    #expect(harness.applier.snapshots.isEmpty)
}

@Test
@MainActor func syncServiceSerializesPushesAndUsesAcknowledgedBaseline() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let first = syncServiceSnapshot(tabID: "first")
    let second = syncServiceSnapshot(tabID: "second")
    let releasePush = SyncServiceGate()
    harness.remote.pushGate = releasePush
    defer { releasePush.open() }

    harness.service.schedulePush(snapshot: first)
    await harness.remote.pushStarted.wait()
    harness.service.schedulePush(snapshot: second)
    harness.service.schedulePull()
    releasePush.open()
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pushes.map(\.snapshot) == [first, second])
    #expect(harness.remote.pushes.first?.previousSnapshot == nil)
    #expect(harness.remote.pushes.last?.previousSnapshot == first)
    #expect(harness.remote.maximumConcurrentRequests == 1)
    #expect(harness.remote.pullCursors.count == 1)
}

@Test
@MainActor func syncServiceIgnoresPushResponseAfterAccountChange() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let releasePush = SyncServiceGate()
    harness.remote.pushGate = releasePush
    defer { releasePush.open() }

    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-a"))
    await harness.remote.pushStarted.wait()
    harness.auth.session = syncServiceSession(userID: "account-b")
    releasePush.open()
    await harness.service.waitForPendingOperations()

    harness.auth.session = syncServiceSession(userID: "account-a")
    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "new-local"))
    await harness.service.waitForPendingOperations()

    let secondPush = try #require(harness.remote.pushes.last)
    #expect(harness.remote.pushes.count == 2)
    #expect(secondPush.authSession.userID == "account-a")
    #expect(secondPush.previousSnapshot == nil)
}

@Test
@MainActor func syncServiceDoesNotReuseAcknowledgedBaselineForAnotherAccount() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-a"))
    await harness.service.waitForPendingOperations()

    harness.auth.session = syncServiceSession(userID: "account-b")
    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-b"))
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pushes.count == 2)
    #expect(harness.remote.pushes.last?.previousSnapshot == nil)
}

@Test(arguments: [false, true])
@MainActor func syncServiceIgnoresPullResponseAfterSessionChanges(signOut: Bool) async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    harness.store.saveSnapshot(local)
    harness.store.saveSyncCursor(3)
    let releasePull = SyncServiceGate()
    harness.remote.pullGate = releasePull
    defer { releasePull.open() }
    harness.remote.pullResponse = BrowserSyncPullResponse(
        cursor: 99,
        events: [
            BrowserSyncEvent(
                serverSeq: 99,
                deviceID: "remote-device",
                entityType: "tab",
                entityID: "local",
                op: "delete",
                data: .deleted(id: "local"),
                createdAt: "2026-10-03T00:00:00Z"
            ),
        ]
    )

    harness.service.schedulePull()
    await harness.remote.pullStarted.wait()
    harness.auth.session = signOut ? nil : syncServiceSession(userID: "account-b")
    releasePull.open()
    await harness.service.waitForPendingOperations()

    #expect(harness.store.loadSnapshot() == local)
    #expect(harness.store.syncCursor() == 3)
    #expect(harness.applier.snapshots.isEmpty)
}

@Test
@MainActor func syncServiceCoalescesQueuedPullsBehindInFlightRequest() async throws {
    let harness = try SyncServiceHarness()
    defer { harness.cleanup() }
    let releasePull = SyncServiceGate()
    harness.remote.pullGate = releasePull
    defer { releasePull.open() }
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 7, events: [])

    harness.service.schedulePull()
    await harness.remote.pullStarted.wait()
    for _ in 0..<20 {
        harness.service.schedulePull()
    }
    releasePull.open()
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pullCursors == [0, 7])
    #expect(harness.remote.maximumConcurrentRequests == 1)
}

// MARK: - SyncServiceHarness

@MainActor private struct SyncServiceHarness {
    // MARK: Lifecycle

    init() throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("BrowserSyncServiceTests-\(UUID().uuidString)", isDirectory: true)
        self.store = try BrowserSQLiteSessionStore(databaseURL: directoryURL.appendingPathComponent("Browser.sqlite"))
        self.remote = SyncServiceRemote()
        self.auth = SyncServiceAuthStore()
        self.applier = SyncServiceSnapshotApplier()
        self.service = BrowserSyncService(
            localStore: store,
            remoteClient: remote,
            authSessionStore: auth,
            pushDebounce: .zero
        )
        service.setSnapshotApplier(applier)
    }

    // MARK: Internal

    let directoryURL: URL
    let store: BrowserSQLiteSessionStore
    let remote: SyncServiceRemote
    let auth: SyncServiceAuthStore
    let applier: SyncServiceSnapshotApplier
    let service: BrowserSyncService

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

// MARK: - SyncServiceRemote

@MainActor private final class SyncServiceRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    struct Push {
        let snapshot: BrowserTabSessionSnapshot
        let previousSnapshot: BrowserTabSessionSnapshot?
        let authSession: BrowserAuthSession
    }

    var pushes = [Push]()
    var pullCursors = [Int]()
    var pushResponse = BrowserSyncPushResponse(cursor: 0, events: [])
    var pullResponse = BrowserSyncPullResponse(cursor: 0, events: [])
    var pushGate: SyncServiceGate?
    var pullGate: SyncServiceGate?
    let pushStarted = SyncServiceGate()
    let pullStarted = SyncServiceGate()
    private(set) var maximumConcurrentRequests = 0

    func push(
        snapshot: BrowserTabSessionSnapshot,
        previousSnapshot: BrowserTabSessionSnapshot?,
        authSession: BrowserAuthSession
    ) async -> BrowserSyncPushResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pushes.append(Push(snapshot: snapshot, previousSnapshot: previousSnapshot, authSession: authSession))
        pushStarted.open()
        await pushGate?.wait()
        return pushResponse
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) async -> BrowserSyncPullResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pullCursors.append(cursor)
        pullStarted.open()
        await pullGate?.wait()
        return pullResponse
    }

    // MARK: Private

    private var activeRequests = 0

    private func beginRequest() {
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    }
}

// MARK: - SyncServiceAuthStore

@MainActor private final class SyncServiceAuthStore: BrowserSyncAuthSessionReading {
    var session: BrowserAuthSession? = syncServiceSession(userID: "account-a")

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - SyncServiceSnapshotApplier

@MainActor private final class SyncServiceSnapshotApplier: BrowserSyncSnapshotApplying {
    var snapshots = [BrowserTabSessionSnapshot]()

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        snapshots.append(snapshot)
    }
}

// MARK: - SyncServiceGate

@MainActor private final class SyncServiceGate {
    // MARK: Internal

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    // MARK: Private

    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()
}

private func syncServiceSession(userID: String) -> BrowserAuthSession {
    BrowserAuthSession(accessToken: "token-\(userID)", userID: userID, userEmail: nil, deviceID: "device-\(userID)")
}

private func syncServiceSnapshot(tabID: String) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: [BrowserTabSessionSnapshotTab(id: tabID, urlString: "https://example.com/\(tabID)", spaceID: "space")]
    )
}
