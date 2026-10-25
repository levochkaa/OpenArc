import Foundation
import GRDB
import Testing

@Test @MainActor func automaticExpiryCadenceWaitsForReadinessAndDoesNotLoopOnRejection() async throws {
    let f = try ExpiryQueueFixture()
    defer { f.close() }
    let scheduler = AutomaticExpiryTestScheduler()
    scheduler.state = nil
    let service = f.service(dateProvider: { scheduler.now })
    service.setExpiryScheduler(scheduler)
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(f.auth.session)
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.isEmpty && scheduler.refreshes == 0)
    scheduler.state = .init(inactiveForSeconds: 43200, protectedTabIDs: [])
    scheduler.refreshSucceeds = false
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.isEmpty && scheduler.refreshes == 1)
    scheduler.refreshSucceeds = true
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.count == 1 && scheduler.refreshes == 2)
    #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try f.store.loadArchivePage().entries.isEmpty)
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.count == 1 && scheduler.refreshes == 2)
    scheduler.now += 60
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.count == 2)
    #expect(Set(f.remote.pushes.map(\.id)).count == 2)
    scheduler.state = .init(inactiveForSeconds: nil, protectedTabIDs: [])
    scheduler.now += 300
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.count == 2 && scheduler.refreshes == 3)
    service.setRuntimeActive(false)
    scheduler.now += 300
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.count == 2 && scheduler.refreshes == 3)
}

// MARK: - AutomaticExpiryInvalidation

enum AutomaticExpiryInvalidation: CaseIterable {
    case unhydrated, off, selected, longerLifetime
}

@Test(arguments: AutomaticExpiryInvalidation.allCases)
@MainActor func unsentAutomaticExpiryIsCancelledWhenItsLiveLeaseChanges(
    _ invalidation: AutomaticExpiryInvalidation
) async throws {
    let f = try ExpiryQueueFixture()
    defer { f.close() }
    let scheduler = AutomaticExpiryTestScheduler()
    let batch = try await f.store.syncExpiryCandidates(for: f.owner, state: scheduler.readyState, now: scheduler.now)
    let mutation = BrowserSyncExpiryMutation(id: UUID().uuidString, operations: batch.operations)
    try f.store.enqueueSyncExpiry(mutation, for: f.owner, automaticBaseline: batch.baseline)
    let before = try f.snapshot()
    scheduler.state =
        switch invalidation {
        case .unhydrated: nil
        case .off: .init(inactiveForSeconds: nil, protectedTabIDs: [])
        case .selected: .init(inactiveForSeconds: 43200, protectedTabIDs: ["tab"])
        case .longerLifetime: .init(inactiveForSeconds: 86400, protectedTabIDs: [])
        }
    let service = f.service(dateProvider: { scheduler.now })
    service.setExpiryScheduler(scheduler)
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(f.auth.session)
    await service.waitForPendingOperations()
    if invalidation == .longerLifetime {
        #expect(f.remote
            .pushes
            .allSatisfy { $0.id != mutation.id && $0.operations.allSatisfy { $0.inactiveForSeconds == 86400 } })
    } else {
        #expect(f.remote.pushes.isEmpty)
    }
    #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try f.snapshot() == before)
    #expect(try f.store.loadArchivePage().entries.isEmpty)
    #expect(try automaticExpiryMetadataCount(f) == 0)
}

@Test @MainActor func possiblyCommittedAutomaticExpiryRetainsItsIdentityAcrossRestartAndOff() async throws {
    let f = try ExpiryQueueFixture()
    defer { f.close() }
    let scheduler = AutomaticExpiryTestScheduler()
    f.remote.failPush = true
    let first = f.service(dateProvider: { scheduler.now })
    first.setExpiryScheduler(scheduler)
    first.accountSessionDidChange(f.auth.session)
    await first.waitForPendingOperations()
    let sent = try #require(f.remote.pushes.first)
    #expect(try !f.store.automaticExpiryNeedsValidation(id: sent.id, for: f.owner))
    let bytes = try f.outboxBytes()
    first.accountSessionDidChange(nil)
    let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    #expect(try !reopened.automaticExpiryNeedsValidation(id: sent.id, for: f.owner))
    #expect(try f.outboxBytes() == bytes)
    scheduler.state = .init(inactiveForSeconds: nil, protectedTabIDs: ["tab"])
    f.remote.failPush = false
    let retry = f.service(store: reopened, dateProvider: { scheduler.now })
    retry.setExpiryScheduler(scheduler)
    defer { retry.accountSessionDidChange(nil) }
    retry.accountSessionDidChange(f.auth.session)
    await retry.waitForPendingOperations()
    #expect(f.remote.pushes == [sent, sent])
    #expect(try reopened.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try automaticExpiryMetadataCount(f) == 0)
}

@Test @MainActor func automaticAttemptMarkerFailurePreventsSendingAndRemainsCancellable() async throws {
    let f = try ExpiryQueueFixture()
    defer { f.close() }
    let scheduler = AutomaticExpiryTestScheduler()
    try automaticExpirySQL(f, """
    CREATE TRIGGER fail_attempt BEFORE UPDATE ON browser_sync_automatic_expiry
    BEGIN SELECT RAISE(ABORT,'injected'); END
    """)
    let service = f.service(dateProvider: { scheduler.now })
    service.setExpiryScheduler(scheduler)
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(f.auth.session)
    await service.waitForPendingOperations()
    let queued = try #require(try f.store.pendingSyncQueue(for: f.owner).first)
    #expect(f.remote.pushes.isEmpty)
    #expect(try f.store.automaticExpiryNeedsValidation(id: queued.id, for: f.owner))
    try automaticExpirySQL(f, "DROP TRIGGER fail_attempt")
    scheduler.state = .init(inactiveForSeconds: nil, protectedTabIDs: [])
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(f.remote.pushes.isEmpty)
    #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try automaticExpiryMetadataCount(f) == 0)
}

@Test @MainActor func automaticCandidateCaptureAndFirstAttemptRejectInterveningLocalWrites() async throws {
    let f = try ExpiryQueueFixture()
    defer { f.close() }
    let scheduler = AutomaticExpiryTestScheduler()
    let batch = try await f.store.syncExpiryCandidates(for: f.owner, state: scheduler.readyState, now: scheduler.now)
    let mutation = BrowserSyncExpiryMutation(id: UUID().uuidString, operations: batch.operations)
    try f.store.enqueueSyncExpiry(mutation, for: f.owner, automaticBaseline: batch.baseline)
    let snapshot = try f.snapshot()
    let changed = BrowserTabSessionSnapshot(
        spaces: snapshot.spaces,
        pinnedTabFolders: snapshot.pinnedTabFolders,
        tabs: snapshot.tabs.map {
            .init(
                id: $0.id,
                urlString: "https://example.com/current",
                pinnedURLString: $0.pinnedURLString,
                userTitleOverride: $0.userTitleOverride,
                placement: $0.placement,
                spaceID: $0.spaceID,
                pinnedFolderID: $0.pinnedFolderID,
                lastActivityTimestamp: $0.lastActivityTimestamp,
                pinnedSiblingRank: $0.pinnedSiblingRank
            )
        }
    )
    try f.store.writeSessionBatch([.init(snapshot: changed, origin: .local(syncMove: nil))])
    let before = try f.store.pendingSyncQueue(for: f.owner)
    #expect(before.count == 2 && before.first?.id == mutation.id)
    #expect(throws: BrowserSyncExpiryError.candidatesChanged) {
        try f.store.enqueueSyncExpiry(
            .init(id: UUID().uuidString, operations: batch.operations),
            for: f.owner,
            automaticBaseline: batch.baseline
        )
    }
    #expect(try !f.store.prepareAutomaticExpiry(id: mutation.id, baseline: batch.baseline, for: f.owner))
    #expect(try f.store.pendingSyncQueue(for: f.owner) == Array(before.dropFirst()))
    #expect(try f.snapshot() == changed)
    #expect(try f.store.loadArchivePage().entries.isEmpty)
}

@Test @MainActor func automaticCandidateActivityMustBeKnownOldTemporaryAndUnprotectedInBothViews() async throws {
    let f = try ExpiryQueueFixture()
    defer { f.close() }
    let scheduler = AutomaticExpiryTestScheduler()
    func candidates() async throws -> [BrowserSyncExpiryOperation] {
        try await f.store.syncExpiryCandidates(for: f.owner, state: scheduler.readyState, now: scheduler.now).operations
    }
    #expect(try await candidates() == f.operations)
    for sql in [
        "UPDATE browser_tabs SET last_activity_timestamp=NULL",
        "UPDATE browser_tabs SET last_activity_timestamp=9999999999",
        "UPDATE browser_tabs SET last_activity_timestamp=1, placement='pinned'",
    ] {
        try automaticExpirySQL(f, sql)
        #expect(try await candidates().isEmpty)
    }
    try automaticExpirySQL(f, "UPDATE browser_tabs SET last_activity_timestamp=1, placement='temporary'")
    #expect(try await candidates() == f.operations)
    let protected = BrowserSyncExpirySchedulingState(inactiveForSeconds: 43200, protectedTabIDs: ["tab"])
    #expect(try await f.store
        .syncExpiryCandidates(for: f.owner, state: protected, now: scheduler.now)
        .operations
        .isEmpty)
}

// MARK: - AutomaticExpiryTestScheduler

@MainActor private final class AutomaticExpiryTestScheduler: BrowserSyncExpiryScheduling {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var state: BrowserSyncExpirySchedulingState? = .init(inactiveForSeconds: 43200, protectedTabIDs: [])
    var refreshes = 0
    var refreshSucceeds = true

    var readyState: BrowserSyncExpirySchedulingState { .init(inactiveForSeconds: 43200, protectedTabIDs: []) }

    func expirySchedulingState() -> BrowserSyncExpirySchedulingState? { state }
    func refreshExpiryActivity() -> Bool {
        refreshes += 1
        return refreshSucceeds
    }
}

@MainActor private func automaticExpirySQL(_ f: ExpiryQueueFixture, _ sql: String) throws {
    try DatabaseQueue(path: f.databaseURL.path).write { try $0.execute(sql: sql) }
}

@MainActor private func automaticExpiryMetadataCount(_ f: ExpiryQueueFixture) throws -> Int {
    try DatabaseQueue(path: f.databaseURL.path).read {
        try #require(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM browser_sync_automatic_expiry"))
    }
}
