import Foundation
import GRDB
import Testing

@Test(arguments: [2, 3], [false, true])
@MainActor func syncPersistenceGuardRetainsHeldReceiptAcrossFailureAndRecovery(
    version: Int, recoverBeforeResponse: Bool
) async throws {
    let h = try await PersistenceGuardHarness(version: version)
    defer { h.cleanup() }
    let hold = PersistenceGuardHold()
    h.remote.nextPushHold = hold
    defer { hold.release.open() }
    try h.persist(persistenceGuardSnapshot(title: "first durable edit"))
    await hold.started.wait()
    let sent = try #require(h.remote.pushes.first)
    let beforeFailure = try h.diskState()
    let unsaved = persistenceGuardSnapshot(title: "edit while ACK is held")
    try h.failSaveAndBlock(unsaved)
    h.service.schedulePull()
    h.service.schedulePush(snapshot: unsaved)

    if !recoverBeforeResponse {
        hold.release.open()
        await h.service.waitForPendingOperations()
        #expect(try h.diskState() == beforeFailure)
        #expect(h.applier.snapshots.isEmpty)
    }

    try h.removeFailure()
    try h.write(unsaved)
    let recoveredRows = try h.store.pendingSyncQueue(for: h.owner)
    #expect(recoveredRows.count == 2)
    #expect(recoveredRows.first == sent)
    var firstRecoveryPullRows: [BrowserSyncQueuedMutation]?
    h.remote.onPull = {
        if firstRecoveryPullRows == nil {
            firstRecoveryPullRows = try h.store.pendingSyncQueue(for: h.owner)
        }
    }
    let beforeRecoveryRequests = h.remote.requests.count
    h.service.setLocalPersistenceBlocked(false)
    // Cancellation deliberately does not end this fake transport. This also
    // exercises failure + recovery while the original response is still held.
    hold.release.open()
    await h.service.waitForPendingOperations()

    #expect(firstRecoveryPullRows == recoveredRows)
    #expect(h.remote.requests.dropFirst(beforeRecoveryRequests).first == "pull")
    #expect(h.remote.pushes == [sent] + recoveredRows)
    #expect(h.remote.receiptCount == recoveredRows.count)
    #expect(h.remote.maximumConcurrentRequests == 1)
    #expect(h.store.loadSnapshot() == unsaved)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: h.databaseURL)
    #expect(reopened.loadSnapshot() == unsaved)
    #expect(try reopened.pendingSyncQueue(for: h.owner).isEmpty)
}

@Test @MainActor func syncPersistenceGuardDiscardsEveryPageOfInterruptedPull() async throws {
    let h = try await PersistenceGuardHarness(version: 2)
    defer { h.cleanup() }
    let before = try h.diskState()
    let pageBoundary = before.cursor + 500
    h.remote.pages[before.cursor] = try .init(
        cursor: pageBoundary,
        events: (1...500).map { offset in
            try persistenceGuardEvent(
                persistenceGuardTab(title: "history \(offset)"), sequence: before.cursor + offset
            )
        }, supportedPushVersions: [2, 3]
    )
    h.remote.pages[pageBoundary] = try .init(
        cursor: pageBoundary + 1,
        events: [persistenceGuardEvent(persistenceGuardTab(title: "latest remote"), sequence: pageBoundary + 1)],
        supportedPushVersions: [2, 3]
    )
    let hold = PersistenceGuardHold()
    h.remote.pullHolds[pageBoundary] = hold
    defer { hold.release.open() }
    h.service.schedulePull()
    await hold.started.wait()
    let unsaved = persistenceGuardSnapshot(title: "local recovery")
    try h.failSaveAndBlock(unsaved)
    hold.release.open()
    await h.service.waitForPendingOperations()
    #expect(try h.diskState() == before)
    #expect(h.applier.snapshots.isEmpty)
    #expect(h.remote.pushes.isEmpty)
    #expect(h.remote.pullCursors == [before.cursor, pageBoundary])

    // The interrupted pull must not have advanced the v3 capability on disk.
    try h.removeFailure()
    try h.write(unsaved)
    #expect(try h.store.pendingSyncQueue(for: h.owner).allSatisfy { $0.protocolVersion == 2 })
    h.remote.pullHolds.removeAll()
    h.remote.events += try (1...501).map { offset in
        try persistenceGuardEvent(persistenceGuardTab(title: "remote history"), sequence: before.cursor + offset)
    }
    h.service.setLocalPersistenceBlocked(false)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pullCursors[2] == before.cursor)
    #expect(try h.diskState().newMutationVersion == 3)
    #expect(h.store.loadSnapshot() == unsaved)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
}

@Test @MainActor func syncPersistenceGuardSurvivesAccountChangesAndDoesNotBlockOtherProfiles() async throws {
    let h = try await PersistenceGuardHarness(version: 3)
    let other = try await PersistenceGuardHarness(version: 3)
    defer { h.cleanup()
        other.cleanup()
    }
    let originalSession = try #require(h.auth.session)
    let unsaved = persistenceGuardSnapshot(title: "profile one unsaved")
    try h.failSaveAndBlock(unsaved)
    try h.service.suspendSync()
    try h.service.resumeSync(for: originalSession)
    h.service.accountSessionDidChange(originalSession)
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.requests.isEmpty)

    let foreign = persistenceGuardSession(userID: "other-account")
    h.auth.session = foreign
    h.service.accountSessionDidChange(foreign)
    #expect(throws: BrowserSyncAccountError.differentAccount) { try h.service.enableSync(for: foreign) }
    h.service.schedulePush(snapshot: unsaved)
    await h.service.waitForPendingOperations()
    #expect(h.remote.requests.isEmpty)

    let otherEdit = persistenceGuardSnapshot(title: "independent profile")
    try other.persist(otherEdit)
    await other.service.waitForPendingOperations()
    #expect(other.store.loadSnapshot() == otherEdit)
    #expect(!other.remote.pushes.isEmpty)
    #expect(try other.store.pendingSyncQueue(for: other.owner).isEmpty)

    h.auth.session = originalSession
    h.service.accountSessionDidChange(originalSession)
    try h.failSaveAndBlock(unsaved, installTrigger: false)
    await h.service.waitForPendingOperations()
    #expect(h.remote.requests.isEmpty)
    try h.removeFailure()
    try h.write(unsaved)
    h.service.setLocalPersistenceBlocked(false)
    await h.service.waitForPendingOperations()
    #expect(h.store.loadSnapshot() == unsaved)
    #expect(h.remote.requestUsers.allSatisfy { $0 == originalSession.userID })
    #expect(try h.store.syncOwner() == h.owner)
    #expect(try !h.store.isSyncPaused(for: h.owner))
}

@Test(arguments: [2, 3])
@MainActor func syncPersistenceGuardStopsAfterApplierFailsAndRetriesWithoutEcho(version: Int) async throws {
    let h = try await PersistenceGuardHarness(version: version)
    defer { h.cleanup() }
    try h.write(persistenceGuardSnapshot(title: "first"))
    try h.write(persistenceGuardSnapshot(title: "second"))
    let queued = try h.store.pendingSyncQueue(for: h.owner)
    #expect(queued.count == 2)
    h.remote.extraOnNextPush = persistenceGuardTab(id: "remote-only", title: "remote")
    var failedProjection: BrowserTabSessionSnapshot?
    h.applier.onApply = { snapshot in
        guard failedProjection == nil else { return }
        failedProjection = snapshot
        try h.installFailure()
        let before = try h.diskState()
        #expect(throws: DatabaseError.self) { try h.write(snapshot, origin: .remoteProjection) }
        #expect(try h.diskState() == before)
        h.service.setLocalPersistenceBlocked(true)
    }
    h.service.schedulePush(snapshot: persistenceGuardSnapshot(title: "second"))
    await h.service.waitForPendingOperations()
    let projection = try #require(failedProjection)
    #expect(h.remote.pushes == Array(queued.prefix(1)))
    #expect(try h.store.pendingSyncQueue(for: h.owner) == Array(queued.dropFirst()))
    #expect(h.remote.pullCursors.isEmpty)

    try h.removeFailure()
    try h.write(projection, origin: .remoteProjection)
    #expect(try h.store.pendingSyncQueue(for: h.owner) == Array(queued.dropFirst()))
    h.service.setLocalPersistenceBlocked(false)
    await h.service.waitForPendingOperations()
    #expect(h.remote.pushes == queued)
    #expect(try h.store.pendingSyncQueue(for: h.owner).isEmpty)
    #expect(h.store.loadSnapshot()?.tabs.contains { $0.id == "remote-only" } == true)
    #expect(h.store.loadSnapshot()?.tabs.first { $0.id == "tab" }?.userTitleOverride == "second")
}

@Test @MainActor func syncPersistenceGuardCancelsDebounceBeforeAnyRequest() async throws {
    let h = try await PersistenceGuardHarness(version: 3)
    defer { h.cleanup() }
    try h.persist(persistenceGuardSnapshot(title: "durable pending"))
    let before = try h.diskState()
    let unsaved = persistenceGuardSnapshot(title: "unsaved")
    try h.failSaveAndBlock(unsaved)
    h.service.schedulePush(snapshot: unsaved)
    h.service.schedulePull()
    await h.service.waitForPendingOperations()
    #expect(h.remote.requests.isEmpty)
    #expect(try h.diskState() == before)
    #expect(try h.store.syncOwner() == h.owner)
    #expect(try !h.store.isSyncPaused(for: h.owner))
}

// MARK: - PersistenceGuardHarness

@MainActor private final class PersistenceGuardHarness {
    // MARK: Lifecycle

    init(version: Int) async throws {
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try write(persistenceGuardSnapshot(title: "original"))
        try store.bindSyncOwner(owner)
        let seed = try #require(store.pendingSyncMutations(for: owner).first)
        try remote.seed(seed.changes)
        _ = try store.acknowledgeSyncMutation(id: seed.id, events: remote.events, for: owner)
        remote.supportedVersions = version == 3 ? [2, 3] : [2]
        self.service = BrowserSyncService(
            localStore: store, remoteClient: remote, authSessionStore: auth,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil
        )
        service.setSnapshotApplier(applier)
        service.accountSessionDidChange(auth.session)
        await service.waitForPendingOperations()
        remote.requests.removeAll()
        remote.requestUsers.removeAll()
        remote.pullCursors.removeAll()
        applier.snapshots.removeAll()
    }

    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-persistence-\(UUID())")
    let owner = BrowserSyncOwner(baseURL: persistenceGuardURL, userID: "owner")
    let auth = PersistenceGuardAuth()
    let remote = PersistenceGuardRemote()
    let applier = PersistenceGuardApplier()
    var store: BrowserSQLiteSessionStore!
    var service: BrowserSyncService!

    var databaseURL: URL { directory.appendingPathComponent("Browser.sqlite") }

    func write(
        _ snapshot: BrowserTabSessionSnapshot,
        origin: BrowserSessionWrite.Origin = .local(syncMove: nil)
    ) throws {
        try store.writeSessionBatch([BrowserSessionWrite(snapshot: snapshot, origin: origin)])
    }

    func persist(_ snapshot: BrowserTabSessionSnapshot) throws {
        try write(snapshot)
        service.schedulePush(snapshot: snapshot)
    }

    func installFailure() throws {
        try DatabaseQueue(path: databaseURL.path).write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_guard_save BEFORE INSERT ON browser_tabs
            BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END
            """)
        }
    }

    func removeFailure() throws {
        try DatabaseQueue(path: databaseURL.path).write { db in
            try db.execute(sql: "DROP TRIGGER fail_guard_save")
        }
    }

    func failSaveAndBlock(_ snapshot: BrowserTabSessionSnapshot, installTrigger: Bool = true) throws {
        if installTrigger {
            try installFailure()
        }
        let before = try diskState()
        #expect(throws: DatabaseError.self) { try write(snapshot) }
        #expect(try diskState() == before)
        #expect(store.loadSnapshot() != snapshot)
        service.setLocalPersistenceBlocked(true)
    }

    func diskState() throws -> PersistenceGuardDiskState {
        let snapshot = store.loadSnapshot()
        return try DatabaseQueue(path: databaseURL.path).read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT position, mutation_id, protocol_version, payload FROM browser_sync_outbox ORDER BY position
            """)
            .map { row in
                PersistenceGuardRow(
                    position: row["position"], id: row["mutation_id"], version: row["protocol_version"],
                    payload: row["payload"]
                )
            }
            return try PersistenceGuardDiskState(
                snapshot: snapshot,
                baseline: Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1"),
                rows: rows,
                cursor: Int.fetchOne(db, sql: "SELECT cursor FROM browser_sync_state WHERE id = 1") ?? 0,
                newMutationVersion: Int.fetchOne(
                    db, sql: "SELECT new_mutation_version FROM browser_sync_state WHERE id = 1"
                ) ?? 2
            )
        }
    }

    func cleanup() {
        service.accountSessionDidChange(nil)
        remote.onPull = nil
        applier.onApply = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - PersistenceGuardRow

private struct PersistenceGuardRow: Equatable {
    let position: Int
    let id: String
    let version: Int
    let payload: Data
}

// MARK: - PersistenceGuardDiskState

private struct PersistenceGuardDiskState: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let baseline: Data?
    let rows: [PersistenceGuardRow]
    let cursor: Int
    let newMutationVersion: Int
}

// MARK: - PersistenceGuardRemote

@MainActor private final class PersistenceGuardRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    let baseURL = persistenceGuardURL
    var supportedVersions = [2]
    var events = [BrowserSyncEvent]()
    var pages = [Int: BrowserSyncPullResponse]()
    var pullHolds = [Int: PersistenceGuardHold]()
    var nextPushHold: PersistenceGuardHold?
    var extraOnNextPush: BrowserSyncChange?
    var onPull: (() throws -> Void)?
    var requests = [String]()
    var requestUsers = [String]()
    var pushes = [BrowserSyncQueuedMutation]()
    var pullCursors = [Int]()
    private(set) var maximumConcurrentRequests = 0

    var receiptCount: Int { receipts.count }

    func seed(_ changes: [BrowserSyncChange]) throws {
        for change in changes {
            values[BrowserSyncOutboxProjection.key(change)] = change
        }
        events = try changes.enumerated().map { try persistenceGuardEvent($0.element, sequence: $0.offset + 1) }
    }

    func push(mutation: BrowserSyncMutation, authSession: BrowserAuthSession) async throws -> BrowserSyncPushResponse {
        let events = try await push(.legacy(mutation), session: authSession)
        return .init(cursor: events.last?.serverSeq ?? 0, events: events, mutationID: mutation.id)
    }

    func push(
        mutation: BrowserSyncSemanticMutation, authSession: BrowserAuthSession
    ) async throws -> BrowserSyncSemanticPushResponse {
        let events = try await push(.semantic(mutation), session: authSession)
        return .init(
            protocolVersion: 3, mutationID: mutation.id, cursor: events.last?.serverSeq ?? 0, events: events,
            outcomes: mutation.operations.indices.map { .init(operationIndex: $0, status: .applied, reason: nil) }
        )
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) async throws -> BrowserSyncPullResponse {
        beginRequest("pull", session: authSession)
        defer { activeRequests -= 1 }
        try onPull?()
        pullCursors.append(cursor)
        let page = Array(events.filter { $0.serverSeq > cursor }.prefix(500))
        let response = pages[cursor] ?? .init(
            cursor: page.last?.serverSeq ?? cursor, events: page, supportedPushVersions: supportedVersions
        )
        let hold = pullHolds[cursor]
        hold?.started.open()
        await hold?.release.wait()
        return response
    }

    // MARK: Private

    private var activeRequests = 0
    private var values = [String: BrowserSyncChange]()
    private var deleted = Set<String>()
    private var receipts = [String: [BrowserSyncEvent]]()

    private func push(
        _ mutation: BrowserSyncQueuedMutation, session: BrowserAuthSession
    ) async throws -> [BrowserSyncEvent] {
        beginRequest("push", session: session)
        defer { activeRequests -= 1 }
        pushes.append(mutation)
        let response: [BrowserSyncEvent]
        if let receipt = receipts[mutation.id] {
            response = receipt
        } else {
            switch mutation {
            case .legacy(let batch):
                for change in batch.changes {
                    values[BrowserSyncOutboxProjection.key(change)] = change
                }
            case .semantic(let batch):
                BrowserSyncSemanticProjection.apply(batch.operations, to: &values, deleted: &deleted)
            case .folders(let batch):
                BrowserSyncFolderProjection.apply(batch.operations, to: &values, deleted: &deleted)
            case .expiry:
                throw BrowserRemoteSyncError.unsupportedSyncProtocol
            }
            if let extra = extraOnNextPush {
                values[BrowserSyncOutboxProjection.key(extra)] = extra
                extraOnNextPush = nil
            }
            let start = events.last?.serverSeq ?? 0
            response = try values.values
                .sorted {
                    BrowserSyncOutboxProjection.key($0) < BrowserSyncOutboxProjection.key($1)
                }
                .enumerated()
                .map { try persistenceGuardEvent($0.element, sequence: start + $0.offset + 1) }
            events += response
            receipts[mutation.id] = response
        }
        let hold = nextPushHold
        nextPushHold = nil
        hold?.started.open()
        // Commit precedes the held response, and cancellation is intentionally ignored.
        await hold?.release.wait()
        return response
    }

    private func beginRequest(_ kind: String, session: BrowserAuthSession) {
        requests.append(kind)
        requestUsers.append(session.userID)
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    }
}

// MARK: - PersistenceGuardAuth

@MainActor private final class PersistenceGuardAuth: BrowserSyncAuthSessionReading {
    var session: BrowserAuthSession? = persistenceGuardSession(userID: "owner")

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - PersistenceGuardApplier

@MainActor private final class PersistenceGuardApplier: BrowserSyncSnapshotApplying {
    var snapshots = [BrowserTabSessionSnapshot]()
    var onApply: ((BrowserTabSessionSnapshot) throws -> Void)?

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        snapshots.append(snapshot)
        do { try onApply?(snapshot) } catch { Issue.record(error) }
    }
}

// MARK: - PersistenceGuardHold

@MainActor private final class PersistenceGuardHold {
    let started = PersistenceGuardGate()
    let release = PersistenceGuardGate()
}

// MARK: - PersistenceGuardGate

@MainActor private final class PersistenceGuardGate {
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

private let persistenceGuardURL = URL(string: "https://sync.example")!

private func persistenceGuardSession(userID: String) -> BrowserAuthSession {
    .init(
        accessToken: "token-\(userID)", userID: userID, userEmail: nil, deviceID: "device-\(userID)",
        serverURL: persistenceGuardURL
    )
}

private func persistenceGuardSnapshot(title: String) -> BrowserTabSessionSnapshot {
    .init(
        spaces: [.init(id: "space", title: "Work", systemImageName: "briefcase")],
        tabs: [.init(id: "tab", urlString: "https://example.com/", userTitleOverride: title, spaceID: "space")]
    )
}

private func persistenceGuardTab(id: String = "tab", title: String) -> BrowserSyncChange {
    .init(entityType: .tab, entityID: id, op: .upsert, spaceData: nil, tabData: .init(
        spaceID: "space", placement: .temporary, rank: id == "tab" ? 0 : 1,
        urlString: "https://example.com/", pinnedURLString: nil, title: nil, userTitleOverride: title,
        faviconURLString: nil, lastActivityAt: nil
    ))
}

private func persistenceGuardEvent(_ change: BrowserSyncChange, sequence: Int) throws -> BrowserSyncEvent {
    let data: BrowserSyncEventData
    if change.op == .delete {
        data = .deleted(id: change.entityID)
    } else if let value = change.spaceData {
        data = .space(.init(
            id: change.entityID, title: value.title, systemImageName: value.systemImageName, rank: value.rank,
            isPinnedSectionCollapsed: value.isPinnedSectionCollapsed, selectedTabID: value.selectedTabID
        ))
    } else if let value = change.tabData {
        data = .tab(.init(
            id: change.entityID, spaceID: value.spaceID, placement: value.placement, rank: value.rank,
            urlString: value.urlString, pinnedURLString: value.pinnedURLString, title: value.title,
            userTitleOverride: value.userTitleOverride, faviconURLString: value.faviconURLString,
            lastActivityAt: value.lastActivityAt
        ))
    } else {
        throw BrowserRemoteSyncError.invalidMutationReceipt
    }
    return .init(
        serverSeq: sequence, deviceID: "remote", entityType: change.entityType.rawValue, entityID: change.entityID,
        op: change.op.rawValue, data: data, createdAt: "2026-10-03T00:00:00Z"
    )
}
