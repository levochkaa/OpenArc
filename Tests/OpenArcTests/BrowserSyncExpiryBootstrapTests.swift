// BrowserSyncExpiryBootstrapTests.swift

import Foundation
import GRDB
import Testing

@Test @MainActor func interruptedExpiryBootstrapCommitsNoPageUntilTheCompleteRetrySucceeds() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExpiryBootstrap-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runInterruptedExpiryBootstrap(directory: directory)
}

@MainActor private func runInterruptedExpiryBootstrap(directory: URL) async throws {
    let databaseURL = directory.appendingPathComponent("Profile.sqlite")
    let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    let remote = ExpiryBootstrapRemote()
    let auth = ExpiryBootstrapAuth()
    let owner = BrowserSyncOwner(baseURL: remote.baseURL, userID: auth.session.userID)
    try store.bindSyncOwner(owner)
    var known = remote.firstPage
    known[499] = .init(
        serverSeq: 500, deviceID: "remote", entityType: "tab", entityID: "expired", op: "delete",
        data: .deleted(id: "expired"), createdAt: "2026-10-03T12:00:00Z",
    )
    let seed = try store.completeFolderSyncBootstrap(events: known, cursor: 500, for: owner)
    let local = BrowserTabSessionSnapshot(
        spaces: seed.spaces?.map { space in
            .init(
                id: space.id,
                title: space.id == "work" ? "Pending local name" : space.title,
                systemImageName: space.systemImageName,
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                selectedTabIndex: space.selectedTabIndex,
            )
        }, pinnedTabFolders: seed.pinnedTabFolders, tabs: seed.tabs,
    )
    try store.writeSessionBatch([.init(snapshot: local, origin: .local(syncMove: nil))])
    let before = try #require(try store.loadSnapshotStrict())
    let queued = try store.pendingSyncQueue(for: owner)
    #expect(queued.count == 1 && queued.first?.protocolVersion == 4)
    let bytes = try expiryBootstrapOutboxBytes(databaseURL)
    let applier = ExpiryBootstrapApplier()
    var failures = [BrowserSyncFailurePhase]()
    let service = BrowserSyncService(
        localStore: store, remoteClient: remote, authSessionStore: auth,
        pushDebounce: .zero, pollInterval: nil, retryDelay: nil, runtimeActive: false,
        errorReporter: { _, phase in failures.append(phase) },
    )
    defer {
        service.setSnapshotApplier(nil)
        service.accountSessionDidChange(nil)
    }
    service.setSnapshotApplier(applier)
    service.accountSessionDidChange(auth.session)
    service.setRuntimeActive(true)
    await service.waitForPendingOperations()

    #expect(remote.firstPage.count == 500)
    #expect(remote.requests == [
        .init(version: 4, cursor: 500),
        .init(version: 5, cursor: 0),
        .init(version: 5, cursor: 500),
    ])
    #expect(failures == [.pull])
    #expect(try store.loadSnapshotStrict() == before)
    #expect(try store.loadArchivePage().entries.isEmpty)
    #expect(try store.syncCursor(for: owner) == 500)
    #expect(try store.syncPullProtocolVersion(for: owner) == 4)
    #expect(try store.syncArchiveRevision(for: owner) == 0)
    #expect(try store.pendingSyncQueue(for: owner) == queued)
    #expect(try expiryBootstrapOutboxBytes(databaseURL) == bytes)
    #expect(applier.snapshots.isEmpty && applier.archiveChanges == 0 && remote.pushes == 0)

    // Stop at the committed recovery callback so the unrelated pending sender
    // cannot drain the row whose bytes this bootstrap test inspects.
    applier.onArchiveChange = { [weak service] in service?.setRuntimeActive(false) }
    service.schedulePull()
    await service.waitForPendingOperations()
    #expect(Array(remote.requests.suffix(3)) == [
        .init(version: 4, cursor: 500),
        .init(version: 5, cursor: 0),
        .init(version: 5, cursor: 500),
    ])
    #expect(failures == [.pull] && remote.pushes == 0)
    #expect(try store.syncCursor(for: owner) == 501)
    #expect(try store.syncPullProtocolVersion(for: owner) == 5)
    #expect(try store.syncArchiveRevision(for: owner) == 1)
    let after = try #require(try store.loadSnapshotStrict())
    #expect(after.tabs.compactMap(\.id) == ["live"])
    #expect(after.tabs.first?.urlString == "https://example.com/after-final-page")
    #expect(after.spaces?.first { $0.id == "work" }?.title == "Pending local name")
    #expect(applier.snapshots == [after] && applier.archiveChanges == 1)
    let archive = try store.loadArchivePage()
    #expect(archive.entries.count == 1 && archive.entries.first?.tab.id == "expired")
    #expect(archive.entries.first?.tab.urlString == "https://example.com/recoverable")
    #expect(try store.pendingSyncQueue(for: owner) == queued)
    #expect(try expiryBootstrapOutboxBytes(databaseURL) == bytes)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    #expect(try reopened.loadSnapshotStrict() == after)
    #expect(try reopened.loadArchivePage() == archive)
    #expect(try reopened.syncCursor(for: owner) == 501)
    #expect(try reopened.syncPullProtocolVersion(for: owner) == 5)
    #expect(try reopened.pendingSyncQueue(for: owner) == queued)
}

// MARK: - ExpiryBootstrapRemote

@MainActor private final class ExpiryBootstrapRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    struct Request: Equatable { let version: Int
        let cursor: Int
    }

    let baseURL = URL(string: "https://expiry-bootstrap.example")!
    var requests = [Request]()
    var failNextSecondPage = true
    var pushes = 0

    var firstPage: [BrowserSyncEvent] {
        let canonical = tab(id: "expired", url: "https://example.com/recoverable", rank: 0)
        return [
            space(id: "work", sequence: 1),
            upsert(id: "expired", sequence: 2, data: .tab(canonical)),
            upsert(id: "live", sequence: 3, data: .tab(tab(id: "live", url: "https://example.com/before", rank: 1))),
        ] + (4...499).map { space(id: "space-\($0)", sequence: $0) } + [
            .init(
                serverSeq: 500,
                deviceID: "remote",
                entityType: "tab",
                entityID: "expired",
                op: "delete",
                data: .deleted(id: "expired", autoArchive: .init(
                    archivedAt: "2026-10-03T12:00:00.123456Z", sourceServerSeq: 2, tab: canonical,
                )),
                createdAt: "2026-10-03T12:00:00Z",
            ),
        ]
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        try pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession _: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        requests.append(.init(version: protocolVersion, cursor: cursor))
        if protocolVersion == 4 {
            return .init(cursor: cursor, events: [], protocolVersion: 4, supportedPushVersions: [2, 3, 4, 5])
        }
        guard protocolVersion == 5 else { throw BrowserRemoteSyncError.unsupportedSyncProtocol }
        if cursor == 0 {
            return .init(cursor: 500, events: firstPage, protocolVersion: 5, supportedPushVersions: [2, 3, 4, 5])
        }
        if failNextSecondPage {
            failNextSecondPage = false
            throw URLError(.networkConnectionLost)
        }
        return .init(cursor: 501, events: [upsert(
            id: "live", sequence: 501,
            data: .tab(tab(id: "live", url: "https://example.com/after-final-page", rank: 1)),
        )], protocolVersion: 5, supportedPushVersions: [2, 3, 4, 5])
    }

    func push(mutation _: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        pushes += 1
        throw URLError(.unsupportedURL)
    }

    func push(
        mutation _: BrowserSyncSemanticMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncSemanticPushResponse {
        pushes += 1
        throw URLError(.unsupportedURL)
    }

    func push(
        mutation _: BrowserSyncFolderMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncFolderPushResponse {
        pushes += 1
        throw URLError(.unsupportedURL)
    }

    // MARK: Private

    private func tab(id: String, url: String, rank: Double) -> BrowserSyncEventTabData {
        .init(
            id: id,
            spaceID: "work",
            placement: .temporary,
            rank: rank,
            urlString: url,
            pinnedURLString: nil,
            title: id,
            userTitleOverride: nil,
            faviconURLString: nil,
            lastActivityAt: "2000-01-01T00:00:00.123456Z",
            pinnedFolderID: nil,
        )
    }

    private func space(id: String, sequence: Int) -> BrowserSyncEvent {
        .init(
            serverSeq: sequence,
            deviceID: "remote",
            entityType: "space",
            entityID: id,
            op: "upsert",
            data: .space(.init(
                id: id,
                title: id,
                systemImageName: "globe",
                rank: Double(sequence),
                isPinnedSectionCollapsed: false,
                selectedTabID: nil,
            )),
            createdAt: "2026-10-03T11:00:00Z",
        )
    }

    private func upsert(id: String, sequence: Int, data: BrowserSyncEventData) -> BrowserSyncEvent {
        .init(
            serverSeq: sequence,
            deviceID: "remote",
            entityType: "tab",
            entityID: id,
            op: "upsert",
            data: data,
            createdAt: "2026-10-03T11:00:00Z",
        )
    }
}

// MARK: - ExpiryBootstrapAuth

@MainActor private final class ExpiryBootstrapAuth: BrowserSyncAuthSessionReading {
    let session = BrowserAuthSession(
        accessToken: "fixture-only",
        userID: "owner",
        userEmail: nil,
        deviceID: "device",
        serverURL: URL(string: "https://expiry-bootstrap.example")!,
    )

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - ExpiryBootstrapApplier

@MainActor private final class ExpiryBootstrapApplier: BrowserSyncSnapshotApplying {
    var snapshots = [BrowserTabSessionSnapshot]()
    var archiveChanges = 0
    var onArchiveChange: (() -> Void)?

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) { snapshots.append(snapshot) }
    func syncArchiveDidChange() {
        archiveChanges += 1
        onArchiveChange?()
    }
}

private func expiryBootstrapOutboxBytes(_ url: URL) throws -> [Data] {
    try DatabaseQueue(path: url.path).read { db in
        try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
    }
}
