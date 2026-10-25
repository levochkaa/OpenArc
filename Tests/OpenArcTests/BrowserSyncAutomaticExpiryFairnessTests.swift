// BrowserSyncAutomaticExpiryFairnessTests.swift

import Foundation
import Testing

@Test @MainActor func automaticExpiryRotatesPastRejectedPrefixAndValidatesTheWholeRotatedBatch() async throws {
    let seed = expiryFairnessSeed(count: 101)
    let f = try ExpiryQueueFixture(seed: seed)
    defer { f.close() }
    let remote = ExpiryFairnessRemote(events: seed)
    let scheduler = ExpiryFairnessScheduler()
    let service = expiryFairnessService(f, remote: remote, scheduler: scheduler)
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(f.auth.session)
    await service.waitForPendingOperations()
    let first = try #require(remote.pushes.first)
    #expect(first.operations.map(\.entityID) == (0..<100).map(expiryFairnessID))
    #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)

    // All original candidates remain unchanged and are eligible again. The
    // next batch must start beyond them, including the previously starved tab.
    scheduler.now += 60
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(remote.pushes.count == 2)
    let second = try #require(remote.pushes.last)
    #expect(second.id != first.id)
    #expect(second.operations.map(\.entityID) == [expiryFairnessID(100)] + (0..<99).map(expiryFairnessID))
    #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)

    // Cooldown filtering precedes the limit, so the one remaining candidate
    // is reachable even though the preceding hundred are cooling down.
    scheduler.now += 1
    service.requestExpirySweep()
    await service.waitForPendingOperations()
    #expect(remote.pushes.count == 3)
    #expect(remote.pushes.last?.operations.map(\.entityID) == [expiryFairnessID(99)])
    #expect(try f.snapshot().tabs.count == 101)
    #expect(try f.store.loadArchivePage().entries.isEmpty)
}

@Test @MainActor func automaticExpiryBackoffUsesCanonicalIdentityAndHandlesClockRollback() async throws {
    let seed = expiryFairnessSeed(count: 1)
    let f = try ExpiryQueueFixture(seed: seed)
    defer { f.close() }
    let remote = ExpiryFairnessRemote(events: seed)
    let scheduler = ExpiryFairnessScheduler()
    let start = scheduler.now
    let service = expiryFairnessService(f, remote: remote, scheduler: scheduler)
    defer { service.accountSessionDidChange(nil) }
    service.accountSessionDidChange(f.auth.session)
    await service.waitForPendingOperations()
    #expect(remote.pushes.count == 1)

    func sweep(at seconds: TimeInterval, expectedPushes: Int) async {
        scheduler.now = start.addingTimeInterval(seconds)
        service.requestExpirySweep()
        await service.waitForPendingOperations()
        #expect(remote.pushes.count == expectedPushes)
    }
    await sweep(at: 59, expectedPushes: 1)
    await sweep(at: 60, expectedPushes: 2)
    await sweep(at: 179, expectedPushes: 2)
    await sweep(at: 180, expectedPushes: 3)
    // Third rejection has a 240-second delay. A backwards clock rebases that
    // bounded delay instead of retrying immediately or waiting for the old clock.
    await sweep(at: 100, expectedPushes: 3)
    await sweep(at: 339, expectedPushes: 3)
    await sweep(at: 340, expectedPushes: 4)

    let previous = try #require(seed.last)
    remote.events.append(.init(
        serverSeq: 3, deviceID: "other-device", entityType: "tab", entityID: previous.entityID,
        op: "upsert", data: previous.data, createdAt: "2026-10-03T12:00:00Z",
    ))
    // A new canonical sequence is a new candidate, even for the same tab.
    await sweep(at: 341, expectedPushes: 5)
    #expect(remote.pushes.last?.operations.first?.expectedServerSeq == 3)
    #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try f.store.loadArchivePage().entries.isEmpty)
}

@Test @MainActor func rotatedAutomaticExpiryKeepsAttemptedBytesAcrossRestartAndOff() async throws {
    let seed = expiryFairnessSeed(count: 101)
    let f = try ExpiryQueueFixture(seed: seed)
    defer { f.close() }
    let remote = ExpiryFairnessRemote(events: seed)
    let scheduler = ExpiryFairnessScheduler()
    let first = expiryFairnessService(f, remote: remote, scheduler: scheduler)
    first.accountSessionDidChange(f.auth.session)
    await first.waitForPendingOperations()
    scheduler.now += 60
    remote.failPush = true
    first.schedulePull()
    await first.waitForPendingOperations()
    let attempted = try #require(remote.pushes.last)
    #expect(remote.pushes.count == 2)
    #expect(attempted.operations.first?.entityID == expiryFairnessID(100))
    #expect(try !f.store.automaticExpiryNeedsValidation(id: attempted.id, for: f.owner))
    let bytes = try f.outboxBytes()
    #expect(bytes.count == 1)
    first.accountSessionDidChange(nil)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
    #expect(try f.outboxBytes() == bytes)
    #expect(try reopened.pendingSyncQueue(for: f.owner) == [.expiry(attempted)])
    scheduler.state = .init(inactiveForSeconds: nil, protectedTabIDs: Set(attempted.operations.map(\.entityID)))
    remote.failPush = false
    let retry = expiryFairnessService(f, remote: remote, scheduler: scheduler, store: reopened)
    defer { retry.accountSessionDidChange(nil) }
    retry.accountSessionDidChange(f.auth.session)
    await retry.waitForPendingOperations()
    #expect(remote.pushes.count == 3)
    #expect(Array(remote.pushes.suffix(2)) == [attempted, attempted])
    #expect(try reopened.pendingSyncQueue(for: f.owner).isEmpty)
    #expect(try reopened.loadArchivePage().entries.isEmpty)
    #expect(try reopened.loadSnapshotStrict()?.tabs.count == 101)
}

@MainActor private func expiryFairnessService(
    _ fixture: ExpiryQueueFixture, remote: ExpiryFairnessRemote, scheduler: ExpiryFairnessScheduler,
    store: BrowserSQLiteSessionStore? = nil,
) -> BrowserSyncService {
    let service = BrowserSyncService(
        localStore: store ?? fixture.store, remoteClient: remote, authSessionStore: fixture.auth,
        pushDebounce: .zero, pollInterval: nil, retryDelay: nil,
        dateProvider: { scheduler.now }, errorReporter: { _, _ in },
    )
    service.setExpiryScheduler(scheduler)
    return service
}

private func expiryFairnessID(_ index: Int) -> String { String(format: "tab-%03d", index) }

private func expiryFairnessSeed(count: Int) -> [BrowserSyncEvent] {
    let space = BrowserSyncEvent(
        serverSeq: 1, deviceID: "remote", entityType: "space", entityID: "work", op: "upsert",
        data: .space(.init(
            id: "work", title: "Work", systemImageName: "globe", rank: 0,
            isPinnedSectionCollapsed: false, selectedTabID: nil,
        )), createdAt: "2026-10-03T11:00:00Z",
    )
    return [space] + (0..<count).map { index in
        let id = expiryFairnessID(index)
        return .init(
            serverSeq: index + 2, deviceID: "remote", entityType: "tab", entityID: id, op: "upsert",
            data: .tab(.init(
                id: id, spaceID: "work", placement: .temporary, rank: Double(index),
                urlString: "https://example.com/\(id)", pinnedURLString: nil, title: id,
                userTitleOverride: nil, faviconURLString: nil, lastActivityAt: "2000-01-01T00:00:00Z",
                pinnedFolderID: nil,
            )), createdAt: "2026-10-03T11:00:00Z",
        )
    }
}

// MARK: - ExpiryFairnessScheduler

@MainActor private final class ExpiryFairnessScheduler: BrowserSyncExpiryScheduling {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var state = BrowserSyncExpirySchedulingState(inactiveForSeconds: 43200, protectedTabIDs: [])

    func expirySchedulingState() -> BrowserSyncExpirySchedulingState? { state }
    func refreshExpiryActivity() -> Bool { true }
}

// MARK: - ExpiryFairnessRemote

@MainActor private final class ExpiryFairnessRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    let baseURL = URL(string: "https://expiry-queue.example")!
    var events: [BrowserSyncEvent]
    var pushes = [BrowserSyncExpiryMutation]()
    var failPush = false

    init(events: [BrowserSyncEvent]) { self.events = events }

    func pull(cursor: Int, authSession: BrowserAuthSession) -> BrowserSyncPullResponse {
        pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession _: BrowserAuthSession) -> BrowserSyncPullResponse {
        .init(
            cursor: max(cursor, events.map(\.serverSeq).max() ?? 0), events: events.filter { $0.serverSeq > cursor },
            protocolVersion: protocolVersion, supportedPushVersions: [2, 3, 4, 5],
        )
    }

    func push(
        mutation: BrowserSyncExpiryMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncExpiryPushResponse {
        pushes.append(mutation)
        if failPush {
            throw URLError(.networkConnectionLost)
        }
        return .init(
            protocolVersion: 5, mutationID: mutation.id, cursor: events.map(\.serverSeq).max() ?? 0,
            events: [], outcomes: mutation.operations.indices.map {
                .init(operationIndex: $0, status: .rejected, reason: .responseLimit)
            },
        )
    }

    func push(mutation _: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        throw URLError(.unsupportedURL)
    }
}
