// BrowserSyncExpiryQueueCoordinatorTests.swift

import Foundation
import GRDB
import Testing

@Test @MainActor func expiryAdmissionRequiresAnActiveNegotiatedReaderAndNeverHidesLocally() async throws {
    let fixture = try ExpiryQueueFixture()
    defer { fixture.close() }
    let service = fixture.service()
    defer { service.accountSessionDidChange(nil) }
    #expect(try service.enqueueExpiry(operations: []) == nil)
    #expect(throws: BrowserRemoteSyncError.self) { try service.enqueueExpiry(operations: fixture.operations) }
    service.accountSessionDidChange(fixture.auth.session)
    #expect(throws: BrowserRemoteSyncError.self) { try service.enqueueExpiry(operations: fixture.operations) }
    await service.waitForPendingOperations()
    let before = try fixture.snapshot()
    fixture.remote.failPush = true
    let id = try #require(try service.enqueueExpiry(operations: fixture.operations))
    #expect(try fixture.snapshot() == before)
    #expect(try fixture.store.loadArchivePage().entries.isEmpty)
    #expect(try fixture.store.pendingSyncQueue(for: fixture.owner) == [
        .expiry(.init(id: id, operations: fixture.operations)),
    ])
    let bytes = try fixture.outboxBytes()
    await service.waitForPendingOperations()
    #expect(fixture.remote.pushes.map(\.id) == [id])
    #expect(try fixture.outboxBytes() == bytes)
    #expect(try fixture.snapshot() == before)
    #expect(try fixture.store.syncCursor(for: fixture.owner) == 2)
    #expect(try fixture.store.syncArchiveRevision(for: fixture.owner) == 0)
    service.setRuntimeActive(false)
    #expect(throws: BrowserRemoteSyncError.self) { try service.enqueueExpiry(operations: fixture.operations) }
}

@Test(arguments: [BrowserSyncExpiryOutcome.Reason.stateChanged, .responseLimit])
@MainActor func terminalExpiryRejectionDrainsIntentWithoutDeletingOrArchiving(
    _ reason: BrowserSyncExpiryOutcome.Reason,
) async throws {
    let fixture = try ExpiryQueueFixture()
    defer { fixture.close() }
    fixture.remote.reason = reason
    let applier = ExpiryQueueApplier()
    let service = fixture.service()
    defer { service.accountSessionDidChange(nil) }
    service.setSnapshotApplier(applier)
    service.accountSessionDidChange(fixture.auth.session)
    await service.waitForPendingOperations()
    let before = try fixture.snapshot()
    let id = try #require(try service.enqueueExpiry(operations: fixture.operations))
    let queued = try fixture.store.pendingSyncQueue(for: fixture.owner)
    #expect(queued.map(\.id) == [id])
    #expect(try fixture.snapshot() == before)
    await service.waitForPendingOperations()
    #expect(fixture.remote.pushes.map(\.id) == [id])
    #expect(try fixture.store.pendingSyncQueue(for: fixture.owner).isEmpty)
    #expect(try fixture.snapshot() == before)
    #expect(try fixture.store.loadArchivePage().entries.isEmpty)
    #expect(try fixture.store.syncArchiveRevision(for: fixture.owner) == 0)
    // ACK high-water is deliberately much larger than the consumed pull cursor.
    #expect(try fixture.store.syncCursor(for: fixture.owner) == 2)
    #expect(applier.snapshots.isEmpty && applier.archiveChanges == 0)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: fixture.databaseURL)
    #expect(try reopened.loadSnapshotStrict() == before)
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
    #expect(try reopened.loadArchivePage().entries.isEmpty)
}

@Test(arguments: ExpiryQueueInvalidReceipt.allCases)
@MainActor func injectedTransportCannotConsumeExpiryUsingAnInvalidReceipt(
    _ defect: ExpiryQueueInvalidReceipt,
) async throws {
    let fixture = try ExpiryQueueFixture()
    defer { fixture.close() }
    fixture.remote.invalidReceipt = defect
    var failures = [BrowserSyncFailurePhase]()
    let service = fixture.service(errorReporter: { _, phase in failures.append(phase) })
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(fixture.auth.session)
    await service.waitForPendingOperations()
    let before = try fixture.snapshot()
    let id = try #require(try service.enqueueExpiry(operations: fixture.operations))
    let bytes = try fixture.outboxBytes()
    await service.waitForPendingOperations()
    #expect(failures == [.push])
    #expect(fixture.remote.pushes.map(\.id) == [id])
    #expect(try fixture.store.pendingSyncQueue(for: fixture.owner).map(\.id) == [id])
    #expect(try fixture.outboxBytes() == bytes)
    #expect(try fixture.snapshot() == before)
    #expect(try fixture.store.syncCursor(for: fixture.owner) == 2)
    #expect(try fixture.store.loadArchivePage().entries.isEmpty)
    #expect(try fixture.store.syncArchiveRevision(for: fixture.owner) == 0)
}

// MARK: - ExpiryQueueInvalidReceipt

enum ExpiryQueueInvalidReceipt: CaseIterable {
    case wrongIdentity, missingRecovery, rejectionDeletes
}

@Test @MainActor func expiryDowngradePreservesImmutableQueueUntilReaderCapabilityReturns() async throws {
    let fixture = try ExpiryQueueFixture()
    defer { fixture.close() }
    let mutation = fixture.mutation()
    try fixture.store.enqueueSyncExpiry(mutation, for: fixture.owner)
    let bytes = try fixture.outboxBytes()
    let before = try fixture.snapshot()
    let reopened = try BrowserSQLiteSessionStore(databaseURL: fixture.databaseURL)
    fixture.remote.capabilities = [2, 3, 4]
    var failures = [BrowserSyncFailurePhase]()
    let service = fixture.service(store: reopened, errorReporter: { _, phase in failures.append(phase) })
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(fixture.auth.session)
    await service.waitForPendingOperations()
    #expect(failures == [.pull])
    #expect(fixture.remote.pushes.isEmpty)
    #expect(try fixture.outboxBytes() == bytes)
    #expect(try reopened.loadSnapshotStrict() == before)
    #expect(try reopened.syncPullProtocolVersion(for: fixture.owner) == 5)
    #expect(throws: BrowserRemoteSyncError.self) { try service.enqueueExpiry(operations: fixture.operations) }
    fixture.remote.capabilities = [2, 3, 4, 5]
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(fixture.remote.pushes == [mutation])
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
    #expect(try reopened.loadSnapshotStrict() == before)
    #expect(try reopened.loadArchivePage().entries.isEmpty)
}

@Test @MainActor func replacementDeviceCompletesCursorZeroBootstrapBeforeSendingExpiry() async throws {
    let fixture = try ExpiryQueueFixture()
    defer { fixture.close() }
    let mutation = fixture.mutation()
    try fixture.store.enqueueSyncExpiry(mutation, for: fixture.owner)
    let bytes = try fixture.outboxBytes()
    let before = try fixture.snapshot()
    fixture.auth.session = .init(
        accessToken: "replacement-token", userID: fixture.owner.userID, userEmail: nil,
        deviceID: "replacement-device", serverURL: fixture.remote.baseURL,
    )
    fixture.remote.requiresBootstrap = true
    fixture.remote.failBootstrapOnce = true
    let reopened = try BrowserSQLiteSessionStore(databaseURL: fixture.databaseURL)
    let service = fixture.service(store: reopened)
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(fixture.auth.session)
    await service.waitForPendingOperations()
    #expect(fixture.remote.calls == ["pull:5:2", "pull:5:0"])
    #expect(fixture.remote.pushes.isEmpty)
    #expect(try fixture.outboxBytes() == bytes)
    #expect(try reopened.loadSnapshotStrict() == before)
    #expect(try reopened.syncCursor(for: fixture.owner) == 2)
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(fixture.remote.calls == [
        "pull:5:2", "pull:5:0", "pull:5:2", "pull:5:0", "push:5", "pull:5:2",
    ])
    #expect(fixture.remote.pushes == [mutation])
    #expect(Set(fixture.remote.deviceIDs) == ["replacement-device"])
    #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
    #expect(try reopened.loadSnapshotStrict() == before)
    #expect(try reopened.loadArchivePage().entries.isEmpty)
}

// MARK: - ExpiryQueueFixture

@MainActor final class ExpiryQueueFixture {
    // MARK: Internal

    let directory: URL
    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let remote = ExpiryQueueRemote()
    let auth = ExpiryQueueAuth()
    let owner: BrowserSyncOwner
    let operations = [BrowserSyncExpiryOperation(id: "tab", expectedServerSeq: 2, inactiveForSeconds: 43200)]

    init(seed: [BrowserSyncEvent]? = nil) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExpiryQueue-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.owner = .init(baseURL: remote.baseURL, userID: auth.session.userID)
        remote.seedOverride = seed
        try store.bindSyncOwner(owner)
        let cursor = remote.seed.map(\.serverSeq).max() ?? 0
        _ = try store.completeFolderSyncBootstrap(events: remote.seed, cursor: cursor, for: owner)
        _ = try store.completeExpirySyncBootstrap(events: remote.seed, cursor: cursor, for: owner)
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
    func snapshot() throws -> BrowserTabSessionSnapshot { try #require(try store.loadSnapshotStrict()) }
    func mutation() -> BrowserSyncExpiryMutation { .init(id: UUID().uuidString, operations: operations) }

    func outboxBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }

    func service(
        store: BrowserSQLiteSessionStore? = nil,
        dateProvider: @escaping @MainActor () -> Date = Date.init,
        errorReporter: @escaping BrowserSyncErrorReporter = { _, _ in },
    ) -> BrowserSyncService {
        .init(
            localStore: store ?? self.store, remoteClient: remote, authSessionStore: auth,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil,
            dateProvider: dateProvider, errorReporter: errorReporter,
        )
    }
}

// MARK: - ExpiryQueueRemote

@MainActor final class ExpiryQueueRemote: BrowserSyncRemoteServing {
    let baseURL = URL(string: "https://expiry-queue.example")!
    var capabilities = [2, 3, 4, 5]
    var calls = [String]()
    var deviceIDs = [String]()
    var pushes = [BrowserSyncExpiryMutation]()
    var reason = BrowserSyncExpiryOutcome.Reason.responseLimit
    var failPush = false
    var requiresBootstrap = false
    var failBootstrapOnce = false
    var invalidReceipt: ExpiryQueueInvalidReceipt?
    var seedOverride: [BrowserSyncEvent]?

    var seed: [BrowserSyncEvent] {
        seedOverride ?? [
            .init(
                serverSeq: 1, deviceID: "remote", entityType: "space", entityID: "work", op: "upsert",
                data: .space(.init(
                    id: "work", title: "Work", systemImageName: "globe", rank: 0,
                    isPinnedSectionCollapsed: false, selectedTabID: nil,
                )), createdAt: "2026-10-03T11:00:00Z",
            ),
            .init(
                serverSeq: 2, deviceID: "remote", entityType: "tab", entityID: "tab", op: "upsert",
                data: .tab(.init(
                    id: "tab", spaceID: "work", placement: .temporary, rank: 0,
                    urlString: "https://example.com/expired", pinnedURLString: nil, title: "Expired",
                    userTitleOverride: nil, faviconURLString: nil, lastActivityAt: "2000-01-01T00:00:00Z",
                    pinnedFolderID: nil,
                )), createdAt: "2026-10-03T11:00:00Z",
            ),
        ]
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        try pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        calls.append("pull:\(protocolVersion):\(cursor)")
        deviceIDs.append(authSession.deviceID)
        if requiresBootstrap {
            guard cursor == 0 else { throw BrowserRemoteSyncError.expiryBootstrapRequired }
            if failBootstrapOnce {
                failBootstrapOnce = false
                throw URLError(.networkConnectionLost)
            }
            requiresBootstrap = false
            return .init(cursor: 2, events: seed, protocolVersion: 5, supportedPushVersions: capabilities)
        }
        return .init(cursor: cursor, events: [], protocolVersion: protocolVersion, supportedPushVersions: capabilities)
    }

    func push(
        mutation: BrowserSyncExpiryMutation, authSession: BrowserAuthSession,
    ) throws -> BrowserSyncExpiryPushResponse {
        calls.append("push:5")
        deviceIDs.append(authSession.deviceID)
        pushes.append(mutation)
        if failPush {
            throw URLError(.networkConnectionLost)
        }
        let deletion = BrowserSyncEvent(
            serverSeq: 3, deviceID: "remote", entityType: "tab", entityID: "tab", op: "delete",
            data: .deleted(id: "tab"), createdAt: "2026-10-03T12:00:00Z",
        )
        switch invalidReceipt {
        case .wrongIdentity:
            return .init(
                protocolVersion: 5, mutationID: UUID().uuidString, cursor: 9999, events: [],
                outcomes: [.init(operationIndex: 0, status: .rejected, reason: .responseLimit)],
            )
        case .missingRecovery:
            return .init(
                protocolVersion: 5, mutationID: mutation.id, cursor: 9999, events: [deletion],
                outcomes: [.init(operationIndex: 0, status: .applied, reason: nil)],
            )
        case .rejectionDeletes:
            return .init(
                protocolVersion: 5, mutationID: mutation.id, cursor: 9999, events: [deletion],
                outcomes: [.init(operationIndex: 0, status: .rejected, reason: .stateChanged)],
            )
        case nil:
            return .init(
                protocolVersion: 5, mutationID: mutation.id, cursor: 9999,
                events: reason == .stateChanged ? [seed[1]] : [],
                outcomes: [.init(operationIndex: 0, status: .rejected, reason: reason)],
            )
        }
    }

    func push(mutation _: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        throw URLError(.unsupportedURL)
    }
}

// MARK: - ExpiryQueueAuth

@MainActor final class ExpiryQueueAuth: BrowserSyncAuthSessionReading {
    var session = BrowserAuthSession(
        accessToken: "fixture-only", userID: "owner", userEmail: nil,
        deviceID: "device", serverURL: URL(string: "https://expiry-queue.example")!,
    )

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - ExpiryQueueApplier

@MainActor private final class ExpiryQueueApplier: BrowserSyncSnapshotApplying {
    var snapshots = [BrowserTabSessionSnapshot]()
    var archiveChanges = 0

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) { snapshots.append(snapshot) }
    func syncArchiveDidChange() { archiveChanges += 1 }
}
