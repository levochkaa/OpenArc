import Foundation
import Testing

@Test @MainActor func syncServiceDebounceOnlyCoalescesWakesNotDurableEdits() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.persist(syncServiceSnapshot(tabID: "first"))
    h.persist(syncServiceSnapshot(tabID: "second"))
    let queued = try h.store.pendingSyncMutations(for: h.owner)
    #expect(queued.count == 2)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.map(\.mutation) == queued)
    #expect(try h.store.pendingSyncMutations(for: h.owner).isEmpty)
    #expect(h.store.loadSnapshot()?.tabs.map(\.id) == ["second"])
}

@Test @MainActor func syncServicePushReceiptDoesNotSkipUnreadRemoteEvents() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.pushCursorOverride = 999
    h.persist(syncServiceSnapshot(tabID: "local"))
    await h.service.waitForPendingOperations()
    #expect(!h.remote.pullCursors.contains(999))
    #expect(try h.store.syncCursor(for: h.owner) == h.remote.events.last?.serverSeq)
}

@Test @MainActor func syncServiceSerializesRequestsAndPreservesLaterLocalEdits() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    let gate = SyncServiceGate()
    h.remote.pushGate = gate
    defer { gate.open() }
    h.persist(syncServiceSnapshot(tabID: "tab", title: "first"))
    await h.remote.pushStarted.wait()
    h.persist(syncServiceSnapshot(tabID: "tab", title: "edited during request"))
    h.service.schedulePull()
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(h.remote.maximumConcurrentRequests == 1)
    #expect(h.remote.pushes.count == 2)
    #expect(h.store.loadSnapshot()?.tabs.first?.userTitleOverride == "edited during request")
    #expect(try h.store.pendingSyncMutations(for: h.owner).isEmpty)
}

@Test @MainActor func syncServiceDoesNotSendDebouncedWorkUnderAnotherAccount() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.persist(syncServiceSnapshot(tabID: "private"))
    h.auth.session = syncServiceSession(userID: "account-b")
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty)
    #expect(try h.store.pendingSyncMutations(for: h.owner).count == 1)
}

@Test @MainActor func syncServiceRejectsAnotherAccountEvenAfterExplicitActivation() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    let local = syncServiceSnapshot(tabID: "account-a")
    h.store.saveSnapshot(local)
    try h.service.suspendSync()
    let b = syncServiceSession(userID: "account-b")
    h.auth.session = b
    h.service.accountSessionDidChange(b)
    h.service.schedulePush(snapshot: local)
    #expect(throws: BrowserSyncAccountError.differentAccount) { try h.service.enableSync(for: b) }
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty && h.remote.pullCursors.isEmpty)
    #expect(h.store.loadSnapshot() == local)
    #expect(try h.store.isSyncPaused(for: h.owner))
}

@Test @MainActor func syncServiceLogoutAndReloginRejectsEarlierGenerationAcknowledgement() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    let gate = SyncServiceGate()
    h.remote.pushGate = gate
    defer { gate.open() }
    h.persist(syncServiceSnapshot(tabID: "local"))
    await h.remote.pushStarted.wait()
    let sent = try #require(h.remote.pushes.first?.mutation)
    try h.service.suspendSync()
    let session = try #require(h.auth.session)
    try h.service.resumeSync(for: session)
    h.service.accountSessionDidChange(session)
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.map(\.mutation) == [sent, sent])
    #expect(h.remote.events.count == sent.changes.count, "Server deduplicates the original committed batch")
    #expect(h.remote.maximumConcurrentRequests == 1)
    #expect(try h.store.pendingSyncMutations(for: h.owner).isEmpty)
}

@Test(arguments: [false, true])
@MainActor func syncServiceIgnoresPullResponseAfterSessionChanges(signOut: Bool) async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    h.persist(local)
    await h.service.waitForPendingOperations()
    h.applier.snapshots.removeAll()
    h.remote.pullStarted = SyncServiceGate()
    let before = try h.store.syncCursor(for: h.owner)
    h.remote.responsePages[before] = BrowserSyncPullResponse(cursor: before + 1, events: [
        syncServiceDelete(id: "local", sequence: before + 1),
    ])
    let gate = SyncServiceGate()
    h.remote.pullGate = gate
    defer { gate.open() }
    h.service.schedulePull()
    await h.remote.pullStarted.wait()
    h.auth.session = signOut ? nil : syncServiceSession(userID: "account-b")
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(h.store.loadSnapshot() == local)
    #expect(try h.store.syncCursor(for: h.owner) == before)
    #expect(h.applier.snapshots.isEmpty)
}

@Test @MainActor func syncServiceRequiresConsentAndUploadsOnlyPersistedLocalMutations() async throws {
    let h = try await SyncServiceHarness(bindOwner: false)
    defer { h.cleanup() }
    let local = syncServiceSnapshot(tabID: "local")
    h.persist(local)
    h.store.saveSyncCursor(400)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty && h.remote.pullCursors.isEmpty)
    let session = try #require(h.auth.session)
    try h.service.enableSync(for: session)
    h.service.accountSessionDidChange(session)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pullCursors.first == 0)
    #expect(h.remote.pushes.count == 1)
    #expect(h.remote.pushes[0].mutation.changes.contains { $0.entityID == "local" })
    #expect(h.store.loadSnapshot() == local)
}

@Test @MainActor func syncServiceDrainsHistoricalPagesBeforePublishingOneProjection() async throws {
    let h = try await SyncServiceHarness(bindOwner: false)
    defer { h.cleanup() }
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "local"))
    var first = [syncServiceSpace(sequence: 1)]
    first.append(contentsOf: (2...500).map { syncServiceUpsert(id: "remote", title: "historical", sequence: $0) })
    h.remote.responsePages = [
        0: BrowserSyncPullResponse(cursor: 500, events: first),
        500: BrowserSyncPullResponse(
            cursor: 501,
            events: [syncServiceUpsert(id: "remote", title: "latest", sequence: 501)]
        ),
    ]
    let session = try #require(h.auth.session)
    try h.service.enableSync(for: session)
    h.service.accountSessionDidChange(session)
    await h.service.waitForPendingOperations()
    #expect(Array(h.remote.pullCursors.prefix(2)) == [0, 500])
    #expect(h.applier.snapshots.first?.tabs.first { $0.id == "remote" }?.userTitleOverride == "latest")
    #expect(!h.applier.snapshots.contains { $0.tabs.contains { $0.userTitleOverride == "historical" } })
    #expect(!h.remote.pushes.flatMap(\.mutation.changes).contains { $0.entityID == "remote" })
    #expect(try h.store.syncCursor(for: h.owner) == 501)
}

@Test @MainActor func syncServiceFailedOrLegacyBootstrapCannotUploadUntilV2PullSucceeds() async throws {
    let h = try await SyncServiceHarness(bindOwner: false)
    defer { h.cleanup() }
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "local"))
    let session = try #require(h.auth.session)
    try h.service.enableSync(for: session)
    h.remote.pullError = BrowserRemoteSyncError.unexpectedOpenAPIResponse
    h.service.accountSessionDidChange(session)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty)
    h.remote.pullError = nil
    h.remote.protocolVersion = nil
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty)
    #expect(try h.store.pendingSyncMutations(for: h.owner).count == 1)
    h.remote.protocolVersion = 2
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.count == 1)
}

@Test @MainActor func syncServiceInvalidReceiptDoesNotDiscardDurableMutation() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.receiptIDOverride = UUID().uuidString
    h.persist(syncServiceSnapshot(tabID: "local"))
    let original = try h.store.pendingSyncMutations(for: h.owner)
    await h.service.waitForPendingOperations()
    #expect(try h.store.pendingSyncMutations(for: h.owner) == original)
    h.remote.receiptIDOverride = nil
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.map(\.mutation) == original + original)
    #expect(try h.store.pendingSyncMutations(for: h.owner).isEmpty)
}

@Test @MainActor func syncServiceLostReceiptAndOfflineDeletionSurviveCoordinatorRestart() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.failPushesAfterCommit = 1
    h.persist(syncServiceSnapshot(tabID: "deleted"))
    await h.service.waitForPendingOperations()
    let original = try #require(h.remote.pushes.first?.mutation)
    h.service.accountSessionDidChange(nil)
    let empty = syncServiceSnapshot()
    h.store.saveSnapshot(empty)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let service = h.makeService(store: reopened)
    service.accountSessionDidChange(h.auth.session)
    await service.waitForPendingOperations()
    #expect(h.remote.pushes[1].mutation == original)
    #expect(reopened.loadSnapshot()?.tabs.isEmpty == true)
    #expect(try reopened.pendingSyncMutations(for: h.owner).isEmpty)
    #expect(h.remote.events.last?.op == "delete")
}

@Test @MainActor func syncServiceOverlaysLocalMutationMadeWhilePullIsInFlight() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.persist(syncServiceSnapshot(tabID: "local", title: "old"))
    await h.service.waitForPendingOperations()
    let before = try h.store.syncCursor(for: h.owner)
    h.remote.events.append(syncServiceUpsert(id: "local", title: "remote", sequence: before + 1))
    let gate = SyncServiceGate()
    h.remote.pullGate = gate
    h.remote.pullStarted = SyncServiceGate()
    defer { gate.open() }
    h.service.schedulePull()
    await h.remote.pullStarted.wait()
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "local", title: "new local"))
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(h.store.loadSnapshot()?.tabs.first?.userTitleOverride == "new local")
    #expect(try h.store.pendingSyncMutations(for: h.owner).isEmpty)
}

@Test @MainActor func syncServicePausedProfileStaysPausedWhenReopenedWithRetainedCredentials() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    try h.service.suspendSync()
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "offline"))
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    let service = h.makeService(store: reopened)
    let session = try #require(h.auth.session)
    service.accountSessionDidChange(session)
    await service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty && h.remote.pullCursors.isEmpty)
    try service.resumeSync(for: session)
    service.accountSessionDidChange(session)
    await service.waitForPendingOperations()
    #expect(h.remote.pushes.count == 1)
}

@Test @MainActor func syncServiceQuarantinesCredentialsWhenServerChanges() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.baseURL = syncServiceURL("https://another-server.example")
    h.service.accountSessionDidChange(h.auth.session)
    h.persist(syncServiceSnapshot(tabID: "private"))
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty && h.remote.pullCursors.isEmpty)
    #expect(try h.store.pendingSyncMutations(for: h.owner).count == 1)
}

@Test @MainActor func syncServiceRetriesCommittedMutationAutomaticallyAfterTransientFailure() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.service.accountSessionDidChange(nil)
    let service = h.makeService(store: h.store, retryDelay: .milliseconds(1))
    service.accountSessionDidChange(h.auth.session)
    await service.waitForPendingOperations()
    h.remote.failPushesAfterCommit = 1
    let retryStarted = SyncServiceGate()
    h.remote.onPush = {
        count in if count == 2 {
            retryStarted.open()
        }
    }
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "retry"))
    service.schedulePush(snapshot: syncServiceSnapshot(tabID: "retry"))
    await retryStarted.wait()
    await service.waitForPendingOperations()
    service.accountSessionDidChange(nil)
    #expect(h.remote.pushes.count == 2)
    #expect(h.remote.pushes[0].mutation == h.remote.pushes[1].mutation)
    #expect(try h.store.pendingSyncMutations(for: h.owner).isEmpty)
}

// MARK: - SyncServiceHarness

@MainActor private final class SyncServiceHarness {
    // MARK: Lifecycle

    init(bindOwner: Bool = true) async throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SyncService-\(UUID().uuidString)")
        self.store = try BrowserSQLiteSessionStore(databaseURL: directoryURL.appendingPathComponent("Browser.sqlite"))
        if bindOwner {
            try store.bindSyncOwner(owner)
        }
        self.service = makeService(store: store)
        service.setSnapshotApplier(applier)
        service.accountSessionDidChange(auth.session)
        await service.waitForPendingOperations()
        remote.pullCursors.removeAll()
        remote.pullStarted = SyncServiceGate()
        applier.snapshots.removeAll()
    }

    // MARK: Internal

    let directoryURL: URL
    let owner = BrowserSyncOwner(baseURL: syncServiceURL("https://sync.example"), userID: "account-a")
    let store: BrowserSQLiteSessionStore
    let remote = SyncServiceRemote()
    let auth = SyncServiceAuthStore()
    let applier = SyncServiceSnapshotApplier()
    var service: BrowserSyncService!

    var databaseURL: URL { directoryURL.appendingPathComponent("Browser.sqlite") }

    func makeService(store: BrowserSQLiteSessionStore, retryDelay: Duration? = nil) -> BrowserSyncService {
        BrowserSyncService(
            localStore: store,
            remoteClient: remote,
            authSessionStore: auth,
            pushDebounce: .zero,
            pollInterval: nil,
            retryDelay: retryDelay
        )
    }

    func persist(_ snapshot: BrowserTabSessionSnapshot) {
        store.saveSnapshot(snapshot)
        service.schedulePush(snapshot: snapshot)
    }

    func cleanup() {
        service.accountSessionDidChange(nil)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

// MARK: - SyncServiceRemote

@MainActor private final class SyncServiceRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    struct Push { let mutation: BrowserSyncMutation
        let authSession: BrowserAuthSession
    }

    var baseURL = syncServiceURL("https://sync.example")
    var protocolVersion: Int? = 2
    var pushes = [Push]()
    var pullCursors = [Int]()
    var events = [BrowserSyncEvent]()
    var pushCursorOverride: Int?
    var receiptIDOverride: String?
    var responsePages = [Int: BrowserSyncPullResponse]()
    var pullError: Error?
    var failPushesAfterCommit = 0
    var pushGate: SyncServiceGate?
    var pullGate: SyncServiceGate?
    let pushStarted = SyncServiceGate()
    var pullStarted = SyncServiceGate()
    var onPush: (Int) -> Void = { _ in }
    private(set) var maximumConcurrentRequests = 0

    func push(mutation: BrowserSyncMutation, authSession: BrowserAuthSession) async throws -> BrowserSyncPushResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pushes.append(Push(mutation: mutation, authSession: authSession))
        let receipt: BrowserSyncPushResponse
        if let existing = receipts[mutation.id] {
            receipt = existing
        } else {
            let start = events.count
            for change in mutation.changes {
                try events.append(syncServiceEvent(change, sequence: events.count + 1))
            }
            receipt = BrowserSyncPushResponse(
                cursor: pushCursorOverride ?? events.count,
                events: Array(events.dropFirst(start)),
                mutationID: mutation.id
            )
            receipts[mutation.id] = receipt
        }
        onPush(pushes.count)
        pushStarted.open()
        await pushGate?.wait()
        if failPushesAfterCommit > 0 {
            failPushesAfterCommit -= 1
            throw URLError(.networkConnectionLost)
        }
        return BrowserSyncPushResponse(
            cursor: receipt.cursor,
            events: receipt.events,
            mutationID: receiptIDOverride ?? mutation.id
        )
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pullCursors.append(cursor)
        let page = Array(events.filter { $0.serverSeq > cursor }.prefix(500))
        let response = responsePages[cursor] ?? BrowserSyncPullResponse(
            cursor: page.last?.serverSeq ?? cursor, events: page, protocolVersion: protocolVersion
        )
        pullStarted.open()
        await pullGate?.wait()
        if let pullError {
            throw pullError
        }
        return response
    }

    // MARK: Private

    private var activeRequests = 0
    private var receipts = [String: BrowserSyncPushResponse]()

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

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) { snapshots.append(snapshot) }
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

private func syncServiceURL(_ value: String) -> URL { URL(string: value)! }
private func syncServiceSession(userID: String) -> BrowserAuthSession {
    BrowserAuthSession(
        accessToken: "token-\(userID)",
        userID: userID,
        userEmail: nil,
        deviceID: "device-\(userID)",
        serverURL: syncServiceURL("https://sync.example")
    )
}

private func syncServiceSnapshot(tabID: String? = nil, title: String? = nil) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: tabID.map { [BrowserTabSessionSnapshotTab(
            id: $0,
            urlString: "https://example.com/\($0)",
            userTitleOverride: title,
            spaceID: "space"
        )] } ?? []
    )
}

private func syncServiceDelete(id: String, sequence: Int) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence,
        deviceID: "remote",
        entityType: "tab",
        entityID: id,
        op: "delete",
        data: .deleted(id: id),
        createdAt: "2026-10-03T00:00:00Z"
    )
}

private func syncServiceSpace(sequence: Int) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence,
        deviceID: "remote",
        entityType: "space",
        entityID: "space",
        op: "upsert",
        data: .space(BrowserSyncEventSpaceData(
            id: "space",
            title: "Work",
            systemImageName: "briefcase",
            rank: 0,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil
        )),
        createdAt: "2026-10-03T00:00:00Z"
    )
}

private func syncServiceUpsert(id: String, title: String, sequence: Int) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence,
        deviceID: "remote",
        entityType: "tab",
        entityID: id,
        op: "upsert",
        data: .tab(BrowserSyncEventTabData(
            id: id,
            spaceID: "space",
            placement: .temporary,
            rank: 1,
            urlString: "https://example.com/\(id)",
            pinnedURLString: nil,
            title: nil,
            userTitleOverride: title,
            faviconURLString: nil,
            lastActivityAt: nil
        )),
        createdAt: "2026-10-03T00:00:00Z"
    )
}

private func syncServiceEvent(_ change: BrowserSyncChange, sequence: Int) throws -> BrowserSyncEvent {
    let data: BrowserSyncEventData
    if change.op == .delete {
        data = .deleted(id: change.entityID)
    } else if let space = change.spaceData {
        data = .space(BrowserSyncEventSpaceData(
            id: change.entityID,
            title: space.title,
            systemImageName: space.systemImageName,
            rank: space.rank,
            isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
            selectedTabID: space.selectedTabID
        ))
    } else if let tab = change.tabData {
        data = .tab(BrowserSyncEventTabData(
            id: change.entityID,
            spaceID: tab.spaceID,
            placement: tab.placement,
            rank: tab.rank,
            urlString: tab.urlString,
            pinnedURLString: tab.pinnedURLString,
            title: tab.title,
            userTitleOverride: tab.userTitleOverride,
            faviconURLString: tab.faviconURLString,
            lastActivityAt: tab.lastActivityAt
        ))
    } else {
        throw BrowserRemoteSyncError.invalidMutationReceipt
    }
    return BrowserSyncEvent(
        serverSeq: sequence,
        deviceID: "device-account-a",
        entityType: change.entityType.rawValue,
        entityID: change.entityID,
        op: change.op.rawValue,
        data: data,
        createdAt: "2026-10-03T00:00:00Z"
    )
}
