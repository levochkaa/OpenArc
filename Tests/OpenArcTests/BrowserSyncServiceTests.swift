// BrowserSyncServiceTests.swift

import Foundation
import Testing

@Test @MainActor func runtimeGateKeepsCachedAuthorizationAndDurableQueueWithoutStartingRequests() async throws {
    var successes = [BrowserSyncFailurePhase]()
    let h = try await SyncServiceHarness(runtimeActive: false, operationDidSucceed: { successes.append($0) })
    defer { h.cleanup() }
    let session = try #require(h.auth.session)
    let local = syncServiceSnapshot(tabID: "offline")
    h.persist(local)
    let queued = try h.store.pendingSyncQueue(for: h.owner)
    let cursor = try h.store.syncCursor(for: h.owner)
    h.service.setLocalPersistenceBlocked(true)
    h.service.setLocalPersistenceBlocked(false)
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.isEmpty && h.remote.pullCursors.isEmpty && successes.isEmpty)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == queued)
    #expect(try h.store.syncOwner() == h.owner)
    #expect(try h.store.syncCursor(for: h.owner) == cursor)
    #expect(try h.service.bindingState(for: session) == .enabled)

    h.service.setRuntimeActive(true)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.count == 1)
    #expect(successes == [.pull, .push, .pull])
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    #expect(h.store.loadSnapshot() == local)
    #expect(h.auth.session == session)
    try h.service.suspendSync()
    h.service.accountSessionDidChange(session)
    h.service.setRuntimeActive(false)
    h.service.setRuntimeActive(true)
    let requests = h.remote.pullCursors.count
    await h.service.waitForPendingOperations()
    #expect(h.remote.pullCursors.count == requests)
    #expect(try h.store.isSyncPaused(for: h.owner))
}

@Test(arguments: [false, true])
@MainActor func inactiveRuntimeDiscardsInFlightPullAndBothKindsOfStatusCallbacks(fails: Bool) async throws {
    var successes = [BrowserSyncFailurePhase]()
    var failures = [BrowserSyncFailurePhase]()
    let h = try await SyncServiceHarness(
        errorReporter: { _, phase in failures.append(phase) },
        operationDidSucceed: { successes.append($0) },
    )
    defer { h.cleanup() }
    h.persist(syncServiceSnapshot(tabID: "retained"))
    await h.service.waitForPendingOperations()
    successes.removeAll()
    h.applier.snapshots.removeAll()
    let cursor = try h.store.syncCursor(for: h.owner)
    let snapshot = h.store.loadSnapshot()
    h.remote.responsePages[cursor] = .init(cursor: cursor + 1, events: [
        syncServiceDelete(id: "retained", sequence: cursor + 1),
    ])
    let gate = SyncServiceGate()
    defer { gate.open() }
    h.remote.pullGate = gate
    h.remote.pullStarted = SyncServiceGate()
    h.remote.pullError = fails ? URLError(.notConnectedToInternet) : nil
    h.service.schedulePull()
    await h.remote.pullStarted.wait()
    h.service.setRuntimeActive(false)
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(successes.isEmpty && failures.isEmpty && h.applier.snapshots.isEmpty)
    #expect(h.store.loadSnapshot() == snapshot)
    #expect(try h.store.syncCursor(for: h.owner) == cursor)
    #expect(try h.store.syncOwner() == h.owner)
    #expect(try !h.store.isSyncPaused(for: h.owner))

    h.remote.pullError = nil
    h.remote.pullGate = nil
    h.service.setRuntimeActive(true)
    await h.service.waitForPendingOperations()
    #expect(successes == [.pull] && failures.isEmpty)
    #expect(h.store.loadSnapshot()?.tabs.isEmpty == true)
    #expect(try h.store.syncCursor(for: h.owner) == cursor + 1)
}

@Test @MainActor func runtimeReactivationReplaysUnacknowledgedPushWithoutClearingItsRow() async throws {
    var successes = [BrowserSyncFailurePhase]()
    let h = try await SyncServiceHarness(operationDidSucceed: { successes.append($0) })
    defer { h.cleanup() }
    successes.removeAll()
    let gate = SyncServiceGate()
    defer { gate.open() }
    h.remote.pushGate = gate
    h.persist(syncServiceSnapshot(tabID: "pending"))
    await h.remote.pushStarted.wait()
    let queued = try h.store.pendingSyncQueue(for: h.owner)
    h.service.setRuntimeActive(false)
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(successes.isEmpty)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == queued)
    #expect(try h.store.syncCursor(for: h.owner) == 0)
    #expect(try !h.store.isSyncPaused(for: h.owner))

    h.remote.pushGate = nil
    h.service.setRuntimeActive(true)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.count == 2)
    #expect(h.remote.pushes.first?.mutation == h.remote.pushes.last?.mutation)
    #expect(h.remote.maximumConcurrentRequests == 1)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    #expect(successes == [.pull, .push, .pull])
}

@Test @MainActor func syncServiceReportsFailurePhaseThroughInjectedReporter() async throws {
    var phases = [BrowserSyncFailurePhase]()
    var errorCodes = [Int]()
    let h = try await SyncServiceHarness(errorReporter: { error, phase in
        phases.append(phase)
        errorCodes.append((error as NSError).code)
    })
    defer { h.cleanup() }
    h.remote.pullError = URLError(.notConnectedToInternet)
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(phases == [.pull])
    #expect(errorCodes == [URLError.notConnectedToInternet.rawValue])
    h.remote.pullError = nil
    h.remote.failPushesAfterCommit = 1
    h.persist(syncServiceSnapshot(tabID: "retained"))
    await h.service.waitForPendingOperations()
    #expect(phases == [.pull, .push])
    #expect(errorCodes == [URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue])
    #expect(try h.store.pendingSyncQueue(for: h.owner).count == 1)
}

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

@Test @MainActor func ownAcknowledgedEditsAreNotAppliedAgainOverLocalSplitViews() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    let tabs = ["left", "right"].map {
        BrowserTabSessionSnapshotTab(id: $0, urlString: "https://example.com/\($0)", spaceID: "space")
    }
    let space = BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")
    h.persist(BrowserTabSessionSnapshot(
        spaces: [space], tabs: tabs, splitGroups: [.init(id: "split", tabIDs: ["left", "right"])],
    ))
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.count == 1)
    #expect(h.applier.snapshots.isEmpty, "The model already shows its own edit")
    #expect(h.store.loadSnapshot()?.splitGroups?.map(\.id) == ["split"])

    h.remote.events.append(syncServiceDelete(id: "right", sequence: (h.remote.events.last?.serverSeq ?? 0) + 1))
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.applier.snapshots.last?.tabs.map(\.id) == ["left"], "A change from elsewhere still reaches the model")
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
            events: [syncServiceUpsert(id: "remote", title: "latest", sequence: 501)],
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

@Test @MainActor func syncServiceCapabilityUpgradeKeepsLegacyFIFOAndSendsNewSemanticEdits() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "tab", title: "legacy"))
    let legacy = try #require(h.store.pendingSyncMutations(for: h.owner).first)
    h.remote.supportedPushVersions = [2, 3]
    h.remote.onPush = { count in
        if count == 1 {
            h.persist(syncServiceSnapshot(tabID: "tab", title: "semantic"))
        }
    }
    h.remote.semanticReceipt = { mutation in
        BrowserSyncSemanticPushResponse(
            protocolVersion: 3, mutationID: mutation.id, cursor: 999,
            events: [syncServiceUpsert(id: "tab", title: "semantic", sequence: 3)],
            outcomes: mutation.operations.indices.map {
                BrowserSyncSemanticOutcome(operationIndex: $0, status: .applied, reason: nil)
            },
        )
    }
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.map(\.mutation) == [legacy])
    #expect(h.remote.pushedVersions == [2, 3])
    #expect(h.remote.semanticPushes.first?.operations == [
        .patchTab(id: "tab", fields: BrowserSyncSemanticTabPatch(userTitleOverride: .set("semantic"))),
    ])
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    #expect(h.store.loadSnapshot()?.tabs.first?.userTitleOverride == "semantic")
    #expect(try h.store.syncCursor(for: h.owner) == 3)
    #expect(!h.remote.pullCursors.contains(999))
}

@Test @MainActor func syncServiceDowngradeRetainsSemanticRowsAndTheirVersionAfterRestart() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3]
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    let snapshot = syncServiceSnapshot(tabID: "offline", title: "retained")
    h.store.saveSnapshot(snapshot)
    let pending = try h.store.pendingSyncQueue(for: h.owner)
    #expect(!pending.isEmpty && pending.allSatisfy { $0.protocolVersion == 3 })
    h.remote.supportedPushVersions = [2]
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushedVersions.isEmpty)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == pending)
    #expect(h.store.loadSnapshot() == snapshot)
    h.service.accountSessionDidChange(nil)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    reopened.saveSnapshot(syncServiceSnapshot(tabID: "offline", title: "new offline edit"))
    let afterRestart = try reopened.pendingSyncQueue(for: h.owner)
    #expect(Array(afterRestart.prefix(pending.count)) == pending)
    #expect(afterRestart.count > pending.count)
    #expect(afterRestart.allSatisfy { $0.protocolVersion == 3 })
}

@Test(arguments: ["id", "version", "outcomes"])
@MainActor func syncServiceRejectsMalformedSemanticReceiptWithoutLosingQueue(defect: String) async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3]
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    h.remote.semanticReceipt = { mutation in
        BrowserSyncSemanticPushResponse(
            protocolVersion: defect == "version" ? 2 : 3,
            mutationID: defect == "id" ? "wrong" : mutation.id,
            cursor: 1, events: [syncServiceDelete(id: "tab", sequence: 1)],
            outcomes: defect == "outcomes"
                ? []
                : mutation.operations.indices.map {
                    BrowserSyncSemanticOutcome(operationIndex: $0, status: .applied, reason: nil)
                },
        )
    }
    let snapshot = syncServiceSnapshot(tabID: "tab", title: "pending")
    h.persist(snapshot)
    let pending = try h.store.pendingSyncQueue(for: h.owner)
    await h.service.waitForPendingOperations()
    #expect(h.remote.semanticPushes.count == 1)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == pending)
    #expect(h.store.loadSnapshot() == snapshot)
    #expect(try h.store.syncCursor(for: h.owner) == 0)
}

@Test @MainActor func syncServiceSemanticRejectionAppliesCanonicalStateAndTerminatesOverlay() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.persist(syncServiceSnapshot(tabID: "tab", title: "original"))
    await h.service.waitForPendingOperations()
    h.remote.supportedPushVersions = [2, 3]
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    h.remote.semanticReceipt = { mutation in
        BrowserSyncSemanticPushResponse(
            protocolVersion: 3, mutationID: mutation.id, cursor: 3,
            events: [syncServiceUpsert(id: "tab", title: "canonical", sequence: 3)],
            outcomes: mutation.operations.indices.map {
                BrowserSyncSemanticOutcome(operationIndex: $0, status: .rejected, reason: "missing")
            },
        )
    }
    h.persist(syncServiceSnapshot(tabID: "tab", title: "rejected local edit"))
    await h.service.waitForPendingOperations()
    #expect(h.remote.semanticPushes.count == 1)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    #expect(h.store.loadSnapshot()?.tabs.first?.userTitleOverride == "canonical")
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.semanticPushes.count == 1)
}

@Test @MainActor func syncServiceRequiresCapabilityAcrossEveryBootstrapPage() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.responsePages[0] = BrowserSyncPullResponse(
        cursor: 500, events: (1...500).map { syncServiceSpace(sequence: $0) }, supportedPushVersions: [2, 3],
    )
    h.remote.responsePages[500] = BrowserSyncPullResponse(cursor: 500, events: [], supportedPushVersions: [2])
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "tab"))
    let pending = try h.store.pendingSyncQueue(for: h.owner)
    #expect(!pending.isEmpty && pending.allSatisfy { $0.protocolVersion == 2 })
}

// MARK: - SyncServiceHarness

@Test @MainActor func syncServiceDrainsFrozenLegacyRowsBeforeFolderAdoption() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3, 4]
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "legacy"))
    let frozen = try h.store.pendingSyncQueue(for: h.owner)
    #expect(frozen.map(\.protocolVersion) == [2])
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.map(\.mutation.id) == frozen.map(\.id))
    #expect(h.remote.folderPullCursors == [0])
    #expect(try h.store.syncPullProtocolVersion(for: h.owner) == 4)
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "legacy", title: "v4 edit"))
    #expect(try h.store.pendingSyncQueue(for: h.owner).map(\.protocolVersion) == [4])
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    #expect(try reopened.syncPullProtocolVersion(for: h.owner) == 4)
    #expect(h.remote.maximumConcurrentRequests == 1)
}

@Test @MainActor func syncServiceFolderBootstrapPublishesOnlyAfterAllPages() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3, 4]
    h.remote.folderResponsePages[0] = BrowserSyncPullResponse(
        cursor: 500, events: [syncServiceSpace(sequence: 1)] + (2...500).map {
            syncServiceFolder(sequence: $0, title: "historical")
        }, protocolVersion: 4, supportedPushVersions: [2, 3, 4],
    )
    h.remote.folderResponsePages[500] = BrowserSyncPullResponse(
        cursor: 501, events: [syncServiceFolder(sequence: 501, title: "latest")],
        protocolVersion: 4, supportedPushVersions: [2, 3, 4],
    )
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.folderPullCursors == [0, 500])
    #expect(h.applier.snapshots.count == 1)
    #expect(h.applier.snapshots.first?.pinnedTabFolders?.first?.title == "latest")
    #expect(try h.store.syncCursor(for: h.owner) == 501)
    #expect(try h.store.syncPullProtocolVersion(for: h.owner) == 4)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
}

@Test @MainActor func syncServiceNewLegacyEditDuringFolderBootstrapDefersAdoption() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3, 4]
    let gate = SyncServiceGate()
    h.remote.folderPullGate = gate
    defer { gate.open() }
    h.service.schedulePull()
    await h.remote.folderPullStarted.wait()
    h.store.saveSnapshot(syncServiceSnapshot(tabID: "during-upgrade"))
    let pending = try h.store.pendingSyncQueue(for: h.owner)
    gate.open()
    await h.service.waitForPendingOperations()
    #expect(try h.store.syncPullProtocolVersion(for: h.owner) == 2)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == pending)
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes.map(\.mutation.id) == pending.map(\.id))
    #expect(try h.store.syncPullProtocolVersion(for: h.owner) == 4)
    #expect(h.store.loadSnapshot()?.tabs.first?.id == "during-upgrade")
}

@Test @MainActor func syncServiceDeviceReRegistrationRebuildsV4BaselineFromZero() async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3, 4]
    h.remote.events = [syncServiceSpace(sequence: 1), syncServiceFolder(sequence: 2, title: "Folder")]
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(try h.store.syncPullProtocolVersion(for: h.owner) == 4)
    h.remote.folderPullCursors.removeAll()
    h.remote.folderRequiresBootstrap = true
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.folderPullCursors == [2, 0])
    #expect(h.store.loadSnapshot()?.pinnedTabFolders?.map(\.id) == ["folder"])
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
}

@Test(arguments: ["version", "identity", "outcomes"])
@MainActor func syncServiceInvalidFolderReceiptPreservesImmutableRow(defect: String) async throws {
    let h = try await SyncServiceHarness()
    defer { h.cleanup() }
    h.remote.supportedPushVersions = [2, 3, 4]
    h.remote.events = [syncServiceSpace(sequence: 1)]
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    h.remote.folderReceipt = { mutation in
        BrowserSyncFolderPushResponse(
            protocolVersion: defect == "version" ? 3 : 4,
            mutationID: defect == "identity" ? UUID().uuidString : mutation.id,
            cursor: 999, events: [],
            outcomes: defect == "outcomes"
                ? []
                : mutation.operations.indices.map {
                    BrowserSyncSemanticOutcome(operationIndex: $0, status: .applied, reason: nil)
                },
        )
    }
    let snapshot = syncServiceSnapshot(tabID: "pending")
    h.persist(snapshot)
    let pending = try h.store.pendingSyncQueue(for: h.owner)
    await h.service.waitForPendingOperations()
    #expect(pending.map(\.protocolVersion) == [4])
    #expect(h.remote.folderPushes.count == 1)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == pending)
    #expect(h.store.loadSnapshot() == snapshot)
    #expect(try h.store.syncCursor(for: h.owner) == 1)
}

private func syncServiceFolder(sequence: Int, title: String) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence, deviceID: "remote", entityType: "folder", entityID: "folder", op: "upsert",
        data: .folder(BrowserSyncEventFolderData(
            id: "folder", spaceID: "space", parentFolderID: nil, title: title, systemImageName: nil, rank: 0,
        )), createdAt: "2026-10-03T00:00:00Z",
    )
}

// MARK: - SyncServiceHarness

@MainActor private final class SyncServiceHarness {
    // MARK: Internal

    let directoryURL: URL
    let owner = BrowserSyncOwner(baseURL: syncServiceURL("https://sync.example"), userID: "account-a")
    let store: BrowserSQLiteSessionStore
    let remote = SyncServiceRemote()
    let auth = SyncServiceAuthStore()
    let applier = SyncServiceSnapshotApplier()
    var service: BrowserSyncService!
    let errorReporter: BrowserSyncErrorReporter
    let operationDidSucceed: @MainActor (BrowserSyncFailurePhase) -> Void

    var databaseURL: URL { directoryURL.appendingPathComponent("Browser.sqlite") }

    init(
        bindOwner: Bool = true, runtimeActive: Bool = true,
        errorReporter: @escaping BrowserSyncErrorReporter = { _, _ in },
        operationDidSucceed: @escaping @MainActor (BrowserSyncFailurePhase) -> Void = { _ in },
    ) async throws {
        self.errorReporter = errorReporter
        self.operationDidSucceed = operationDidSucceed
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SyncService-\(UUID().uuidString)")
        self.store = try BrowserSQLiteSessionStore(databaseURL: directoryURL.appendingPathComponent("Browser.sqlite"))
        if bindOwner {
            try store.bindSyncOwner(owner)
        }
        self.service = makeService(store: store, runtimeActive: runtimeActive)
        service.setSnapshotApplier(applier)
        service.accountSessionDidChange(auth.session)
        await service.waitForPendingOperations()
        remote.pullCursors.removeAll()
        remote.pullStarted = SyncServiceGate()
        applier.snapshots.removeAll()
    }

    func makeService(
        store: BrowserSQLiteSessionStore, retryDelay: Duration? = nil, runtimeActive: Bool = true,
    ) -> BrowserSyncService {
        BrowserSyncService(
            localStore: store,
            remoteClient: remote,
            authSessionStore: auth,
            pushDebounce: .zero,
            pollInterval: nil,
            retryDelay: retryDelay,
            runtimeActive: runtimeActive,
            errorReporter: errorReporter,
            operationDidSucceed: operationDidSucceed,
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
    var supportedPushVersions: [Int]?
    var pushes = [Push]()
    var semanticPushes = [BrowserSyncSemanticMutation]()
    var pushedVersions = [Int]()
    var semanticReceipt: ((BrowserSyncSemanticMutation) throws -> BrowserSyncSemanticPushResponse)?
    var folderReceipt: ((BrowserSyncFolderMutation) throws -> BrowserSyncFolderPushResponse)?
    var folderPushes = [BrowserSyncFolderMutation]()
    var folderPullCursors = [Int]()
    var folderResponsePages = [Int: BrowserSyncPullResponse]()
    var folderPullGate: SyncServiceGate?
    var folderPullStarted = SyncServiceGate()
    var folderRequiresBootstrap = false
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

    // MARK: Private

    private var activeRequests = 0
    private var receipts = [String: BrowserSyncPushResponse]()

    func push(mutation: BrowserSyncMutation, authSession: BrowserAuthSession) async throws -> BrowserSyncPushResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pushes.append(Push(mutation: mutation, authSession: authSession))
        pushedVersions.append(2)
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
                mutationID: mutation.id,
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
            mutationID: receiptIDOverride ?? mutation.id,
        )
    }

    func push(
        mutation: BrowserSyncSemanticMutation,
        authSession _: BrowserAuthSession,
    ) async throws -> BrowserSyncSemanticPushResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        semanticPushes.append(mutation)
        pushedVersions.append(3)
        pushStarted.open()
        await pushGate?.wait()
        guard let semanticReceipt else { throw BrowserRemoteSyncError.unsupportedSyncProtocol }
        let response = try semanticReceipt(mutation)
        events += response.events
        return response
    }

    func pull(cursor: Int, authSession _: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        pullCursors.append(cursor)
        let page = Array(events.filter { $0.serverSeq > cursor }.prefix(500))
        let response = responsePages[cursor] ?? BrowserSyncPullResponse(
            cursor: page.last?.serverSeq ?? cursor, events: page, protocolVersion: protocolVersion,
            supportedPushVersions: supportedPushVersions,
        )
        pullStarted.open()
        await pullGate?.wait()
        if let pullError {
            throw pullError
        }
        return response
    }

    func pull(
        cursor: Int,
        protocolVersion: Int,
        authSession: BrowserAuthSession,
    ) async throws -> BrowserSyncPullResponse {
        guard protocolVersion == 4 else { return try await pull(cursor: cursor, authSession: authSession) }
        beginRequest()
        defer { activeRequests -= 1 }
        folderPullCursors.append(cursor)
        if folderRequiresBootstrap, cursor != 0 {
            throw BrowserRemoteSyncError.folderBootstrapRequired
        }
        folderRequiresBootstrap = false
        let page = Array(events.filter { $0.serverSeq > cursor }.prefix(500))
        let response = folderResponsePages[cursor] ?? BrowserSyncPullResponse(
            cursor: page.last?.serverSeq ?? cursor, events: page, protocolVersion: 4,
            supportedPushVersions: supportedPushVersions,
        )
        folderPullStarted.open()
        await folderPullGate?.wait()
        return response
    }

    func push(
        mutation: BrowserSyncFolderMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncFolderPushResponse {
        beginRequest()
        defer { activeRequests -= 1 }
        folderPushes.append(mutation)
        pushedVersions.append(4)
        guard let folderReceipt else { throw BrowserRemoteSyncError.unsupportedSyncProtocol }
        let response = try folderReceipt(mutation)
        events += response.events
        return response
    }

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
    // MARK: Private

    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

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
}

private func syncServiceURL(_ value: String) -> URL { URL(string: value)! }
private func syncServiceSession(userID: String) -> BrowserAuthSession {
    BrowserAuthSession(
        accessToken: "token-\(userID)",
        userID: userID,
        userEmail: nil,
        deviceID: "device-\(userID)",
        serverURL: syncServiceURL("https://sync.example"),
    )
}

private func syncServiceSnapshot(tabID: String? = nil, title: String? = nil) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [BrowserSpaceSessionSnapshot(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: tabID.map { [BrowserTabSessionSnapshotTab(
            id: $0,
            urlString: "https://example.com/\($0)",
            userTitleOverride: title,
            spaceID: "space",
        )] } ?? [],
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
        createdAt: "2026-10-03T00:00:00Z",
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
            selectedTabID: nil,
        )),
        createdAt: "2026-10-03T00:00:00Z",
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
            lastActivityAt: nil,
        )),
        createdAt: "2026-10-03T00:00:00Z",
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
            selectedTabID: space.selectedTabID,
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
            lastActivityAt: tab.lastActivityAt,
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
        createdAt: "2026-10-03T00:00:00Z",
    )
}
