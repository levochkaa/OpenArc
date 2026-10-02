import Foundation
import Testing

@Test
@MainActor func syncServiceCancelsSupersededPushDebounce() async throws {
    let harness = try await SyncServiceHarness()
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
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    try harness.store.saveSyncCursor(3, for: harness.owner)
    harness.remote.pushResponse = BrowserSyncPushResponse(cursor: 99, events: [])
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 10, events: [])

    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "local"))
    await harness.service.waitForPendingOperations()
    #expect(try harness.store.syncCursor(for: harness.owner) == 3)

    harness.service.schedulePull()
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pullCursors == [3])
    #expect(try harness.store.syncCursor(for: harness.owner) == 10)
}

@Test
@MainActor func syncServiceDoesNotSendDebouncedSnapshotUnderAnotherAccount() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }

    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-a"))
    harness.auth.session = syncServiceSession(userID: "account-b")
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pushes.isEmpty)
}

@Test
@MainActor func syncServiceAppliesOldDeleteReceiptWithoutOverwritingLaterLocalEdits() async throws {
    let harness = try await SyncServiceHarness()
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
    try harness.store.saveSyncCursor(100, for: harness.owner)
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
    #expect(try harness.store.syncCursor(for: harness.owner) == 100)
    #expect(harness.applier.snapshots == [expected])

    harness.remote.pushResponse = BrowserSyncPushResponse(cursor: 201, events: [])
    harness.service.schedulePush(snapshot: expected)
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.last?.previousSnapshot?.tabs == [sentSurvivor])
    #expect(harness.applier.snapshots == [expected])
}

@Test
@MainActor func syncServiceDoesNotReapplyDeleteReceiptWhenLocalStateAlreadyMatches() async throws {
    let harness = try await SyncServiceHarness()
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
    let harness = try await SyncServiceHarness()
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
    let harness = try await SyncServiceHarness()
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
@MainActor func syncServiceNeverUploadsBoundProfileToAnotherAccount() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-a"))
    await harness.service.waitForPendingOperations()

    harness.auth.session = syncServiceSession(userID: "account-b")
    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "account-b"))
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pushes.count == 1)
    #expect(try harness.service.bindingState(for: syncServiceSession(userID: "account-b")) == .differentAccount)
}

@Test(arguments: [false, true])
@MainActor func syncServiceIgnoresPullResponseAfterSessionChanges(signOut: Bool) async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    harness.store.saveSnapshot(local)
    try harness.store.saveSyncCursor(3, for: harness.owner)
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
    #expect(try harness.store.syncCursor(for: harness.owner) == 3)
    #expect(harness.applier.snapshots.isEmpty)
}

@Test
@MainActor func syncServiceCoalescesQueuedPullsBehindInFlightRequest() async throws {
    let harness = try await SyncServiceHarness()
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

@Test
@MainActor func syncServiceRequiresExplicitOwnerAdoptionAndCombinesInitialData() async throws {
    let harness = try await SyncServiceHarness(bindOwner: false)
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    harness.store.saveSnapshot(local)
    harness.store.saveSyncCursor(400)
    harness.service.schedulePush(snapshot: local)
    harness.service.schedulePull()
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.isEmpty)
    #expect(harness.remote.pullCursors.isEmpty)
    #expect(try harness.store.syncOwner() == nil)

    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 10, events: [BrowserSyncEvent(
        serverSeq: 10, deviceID: "other-device", entityType: "tab", entityID: "remote", op: "upsert",
        data: .tab(BrowserSyncEventTabData(
            id: "remote", spaceID: "space", placement: .temporary, rank: 1,
            urlString: "https://remote.example", pinnedURLString: nil, title: nil,
            userTitleOverride: nil, faviconURLString: nil, lastActivityAt: nil
        )), createdAt: "2026-10-03T00:00:00Z"
    )])
    let session = try #require(harness.auth.session)
    try harness.service.enableSync(for: session)
    harness.service.accountSessionDidChange(session)
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pullCursors == [0], "Legacy cursor is never assigned to this account")
    #expect(harness.remote.pushes.count == 1)
    #expect(Set(harness.remote.pushes[0].snapshot.tabs.compactMap(\.id)) == ["local", "remote"])
    #expect(try harness.store.syncCursor(for: harness.owner) == 10)
}

@Test
@MainActor func syncServiceRejectsAnotherAccountEvenAfterExplicitActivation() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "account-a-data")
    harness.store.saveSnapshot(local)
    try harness.store.saveSyncCursor(30, for: harness.owner)
    try harness.service.suspendSync()
    let accountB = syncServiceSession(userID: "account-b")
    harness.auth.session = accountB
    harness.service.accountSessionDidChange(accountB)
    harness.service.schedulePush(snapshot: local)
    harness.service.schedulePull()
    #expect(throws: BrowserSyncAccountError.differentAccount) {
        try harness.service.enableSync(for: accountB)
    }
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.isEmpty)
    #expect(harness.remote.pullCursors.isEmpty)
    #expect(harness.store.loadSnapshot() == local)
    #expect(try harness.store.syncCursor(for: harness.owner) == 30)
    #expect(try harness.store.isSyncPaused(for: harness.owner))
}

@Test
@MainActor func syncServiceLogoutAndReloginRejectsResponseFromEarlierGeneration() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    harness.store.saveSnapshot(local)
    let gate = SyncServiceGate()
    harness.remote.pullGate = gate
    defer { gate.open() }
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 99, events: [BrowserSyncEvent(
        serverSeq: 99, deviceID: "remote", entityType: "tab", entityID: "local", op: "delete",
        data: .deleted(id: "local"), createdAt: "2026-10-03T00:00:00Z"
    )])
    harness.service.schedulePull()
    await harness.remote.pullStarted.wait()
    try harness.service.suspendSync()
    let sameCredentials = try #require(harness.auth.session)
    try harness.service.resumeSync(for: sameCredentials)
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 7, events: [])
    harness.service.accountSessionDidChange(sameCredentials)
    gate.open()
    await harness.service.waitForPendingOperations()

    #expect(harness.store.loadSnapshot() == local)
    #expect(harness.applier.snapshots.isEmpty)
    #expect(harness.remote.pullCursors == [0, 0])
    #expect(try harness.store.syncCursor(for: harness.owner) == 7)
    #expect(harness.remote.maximumConcurrentRequests == 1)
}

@Test
@MainActor func syncServicePausedProfileStaysPausedAfterReopeningWithRetainedCredentials() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    try harness.store.saveSyncCursor(19, for: harness.owner)
    try harness.service.suspendSync()
    let reopened = try BrowserSQLiteSessionStore(databaseURL: harness.directoryURL
        .appendingPathComponent("Browser.sqlite"))
    let service = BrowserSyncService(
        localStore: reopened,
        remoteClient: harness.remote,
        authSessionStore: harness.auth,
        pushDebounce: .zero
    )
    let session = try #require(harness.auth.session)
    service.accountSessionDidChange(session)
    service.schedulePush(snapshot: syncServiceSnapshot(tabID: "private"))
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(harness.remote.pushes.isEmpty)
    #expect(harness.remote.pullCursors.isEmpty)

    try service.resumeSync(for: session)
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 19, events: [])
    service.accountSessionDidChange(session)
    await service.waitForPendingOperations()
    #expect(harness.remote.pullCursors == [19])
    #expect(try reopened.syncOwner() == harness.owner)
}

@Test
@MainActor func syncServiceQuarantinesCredentialsWhenServerChanges() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    harness.remote.baseURL = try #require(URL(string: "https://another-server.example"))
    harness.service.accountSessionDidChange(harness.auth.session)
    harness.service.schedulePull()
    harness.service.schedulePush(snapshot: syncServiceSnapshot(tabID: "private"))
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.isEmpty)
    #expect(harness.remote.pullCursors.isEmpty)
    #expect(try harness.store.syncOwner() == harness.owner)
}

@Test
@MainActor func syncServiceDrainsInitialHistoryBeforeUploadingTheLatestProjection() async throws {
    let harness = try await SyncServiceHarness(bindOwner: false)
    defer { harness.cleanup() }
    harness.store.saveSnapshot(syncServiceSnapshot(tabID: "local"))
    func event(sequence: Int, title: String) -> BrowserSyncEvent {
        BrowserSyncEvent(
            serverSeq: sequence, deviceID: "remote", entityType: "tab", entityID: "remote", op: "upsert",
            data: .tab(BrowserSyncEventTabData(
                id: "remote", spaceID: "space", placement: .temporary, rank: 1,
                urlString: "https://remote.example", pinnedURLString: nil, title: nil,
                userTitleOverride: title, faviconURLString: nil, lastActivityAt: nil
            )), createdAt: "2026-10-03T00:00:00Z"
        )
    }
    harness.remote.pullResponses = [
        BrowserSyncPullResponse(cursor: 500, events: (1...500).map { event(sequence: $0, title: "Historical") }),
        BrowserSyncPullResponse(cursor: 501, events: [event(sequence: 501, title: "Latest")]),
    ]
    let session = try #require(harness.auth.session)
    try harness.service.enableSync(for: session)
    harness.service.accountSessionDidChange(session)
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pullCursors == [0, 500])
    #expect(harness.remote.pushes.count == 1)
    #expect(harness.applier.snapshots.count == 1)
    #expect(harness.applier.snapshots[0].tabs.first { $0.id == "remote" }?.userTitleOverride == "Latest")
    #expect(harness.remote.pushes[0].snapshot.tabs.first { $0.id == "remote" }?.userTitleOverride == "Latest")
    #expect(harness.remote.pushes[0].snapshot.tabs.contains { $0.id == "local" })
    #expect(try harness.store.syncCursor(for: harness.owner) == 501)
}

@Test
@MainActor func syncServiceFailedInitialPullBlocksOrdinaryPersistenceUploadsUntilRetry() async throws {
    let harness = try await SyncServiceHarness(bindOwner: false)
    defer { harness.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    harness.store.saveSnapshot(local)
    let gate = SyncServiceGate()
    harness.remote.pullGate = gate
    harness.remote.pullError = BrowserRemoteSyncError.unexpectedOpenAPIResponse
    defer { gate.open() }
    let session = try #require(harness.auth.session)
    try harness.service.enableSync(for: session)
    harness.service.accountSessionDidChange(session)
    await harness.remote.pullStarted.wait()
    harness.service.schedulePush(snapshot: local)
    gate.open()
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.isEmpty)
    #expect(try harness.store.syncCursor(for: harness.owner) == 0)

    harness.remote.pullError = nil
    harness.service.schedulePull()
    await harness.service.waitForPendingOperations()
    #expect(harness.remote.pushes.map(\.snapshot) == [local])
}

@Test
@MainActor func syncServiceRetriesPullIfLocalSnapshotChangesDuringNetworkAwait() async throws {
    let harness = try await SyncServiceHarness()
    defer { harness.cleanup() }
    harness.store.saveSnapshot(syncServiceSnapshot(tabID: "old"))
    let gate = SyncServiceGate()
    harness.remote.pullGate = gate
    harness.remote.pullResponse = BrowserSyncPullResponse(cursor: 9, events: [BrowserSyncEvent(
        serverSeq: 9, deviceID: "remote", entityType: "tab", entityID: "unrelated", op: "delete",
        data: .deleted(id: "unrelated"), createdAt: "2026-10-03T00:00:00Z"
    )])
    defer { gate.open() }
    harness.service.schedulePull()
    await harness.remote.pullStarted.wait()
    let edited = syncServiceSnapshot(tabID: "new-local")
    harness.store.saveSnapshot(edited)
    gate.open()
    await harness.service.waitForPendingOperations()

    #expect(harness.remote.pullCursors == [0, 0])
    #expect(harness.store.loadSnapshot() == edited)
    #expect(harness.applier.snapshots == [edited])
    #expect(try harness.store.syncCursor(for: harness.owner) == 9)
}

// MARK: - SyncServiceHarness

@MainActor private struct SyncServiceHarness {
    // MARK: Lifecycle

    init(bindOwner: Bool = true) async throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("BrowserSyncServiceTests-\(UUID().uuidString)", isDirectory: true)
        self.store = try BrowserSQLiteSessionStore(databaseURL: directoryURL.appendingPathComponent("Browser.sqlite"))
        if bindOwner {
            try store.bindSyncOwner(owner)
        }
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
        service.accountSessionDidChange(auth.session)
        await service.waitForPendingOperations()
        remote.pullCursors.removeAll()
        remote.pullStarted = SyncServiceGate()
    }

    // MARK: Internal

    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "account-a")
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

    var baseURL = URL(string: "https://sync.example")!
    var pushes = [Push]()
    var pullCursors = [Int]()
    var pushResponse = BrowserSyncPushResponse(cursor: 0, events: [])
    var pullResponse = BrowserSyncPullResponse(cursor: 0, events: [])
    var pullResponses = [BrowserSyncPullResponse]()
    var pullError: Error?
    var pushGate: SyncServiceGate?
    var pullGate: SyncServiceGate?
    let pushStarted = SyncServiceGate()
    var pullStarted = SyncServiceGate()
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

    func pull(cursor: Int, authSession _: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pullCursors.append(cursor)
        pullStarted.open()
        let response = pullResponses.isEmpty ? pullResponse : pullResponses.removeFirst()
        await pullGate?.wait()
        if let pullError {
            throw pullError
        }
        return response
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
    BrowserAuthSession(
        accessToken: "token-\(userID)",
        userID: userID,
        userEmail: nil,
        deviceID: "device-\(userID)",
        serverURL: URL(string: "https://sync.example")!
    )
}

private func syncServiceSnapshot(tabID: String) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: [BrowserTabSessionSnapshotTab(id: tabID, urlString: "https://example.com/\(tabID)", spaceID: "space")]
    )
}
