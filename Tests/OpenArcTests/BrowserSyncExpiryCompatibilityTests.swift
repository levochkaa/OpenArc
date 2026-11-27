// BrowserSyncExpiryCompatibilityTests.swift

import Foundation
import GRDB
import Testing

@Test func additiveExpiryRecoveryMetadataDecodesAsATerminalDeleteInExistingResponses() throws {
    let wire = ExpiryCompatibilityWire()
    for version in [2, 4, 5] {
        let response = try JSONDecoder().decode(
            BrowserSyncPullResponse.self, from: wire.pull(cursor: 4, protocolVersion: version),
        )
        #expect(response.protocolVersion == version)
        #expect(response.supportedPushVersions == [2, 3, 4, 5])
        let event = try #require(response.events.first)
        #expect(event.serverSeq == 100 && event.entityID == "expired" && event.op == "delete")
        guard case .deleted(let id, let recovery?) = event.data else {
            Issue.record("Expiry deletion must retain typed recovery")
            return
        }
        #expect(id == "expired" && recovery.tab.id == id && recovery.sourceServerSeq == 4)
        #expect(try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONEncoder().encode(event)) == event)
        var baseline = BrowserSyncOutboxBaseline()
        try baseline.apply(response.events)
        #expect(baseline.entities["tab:expired"]?.change.op == .delete)
        #expect(baseline.deletedKeys.contains("tab:expired"))
    }
    for version in [2, 3, 4] {
        let data = try wire.receipt(version: version, id: "original-request", operationCount: 2, expiry: true)
        let events: [BrowserSyncEvent] =
            switch version {
            case 2: try JSONDecoder().decode(BrowserSyncPushResponse.self, from: data).events
            case 3: try JSONDecoder().decode(BrowserSyncSemanticPushResponse.self, from: data).events
            default: try JSONDecoder().decode(BrowserSyncFolderPushResponse.self, from: data).events
            }
        #expect(events.count == 1)
        guard case .deleted(let id, let recovery?) = events.first?.data else {
            Issue.record("Old receipt envelopes must retain recovery")
            return
        }
        #expect(id == "expired" && recovery.tab.id == id)
    }
}

@Test(arguments: [2, 3, 4]) @MainActor
func expiryDeleteSurvivesOldPendingMutationsLostACKAndCoordinatorReopen(protocolVersion: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExpiryCompatibility-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runExpiryCompatibility(directory: directory, protocolVersion: protocolVersion)
}

@MainActor private func runExpiryCompatibility(directory: URL, protocolVersion: Int) async throws {
    let databaseURL = directory.appendingPathComponent("Profile.sqlite")
    let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    let remote = ExpiryCompatibilityRemote()
    let auth = ExpiryCompatibilityAuth()
    let owner = BrowserSyncOwner(baseURL: remote.baseURL, userID: auth.session.userID)
    try store.bindSyncOwner(owner)
    let seed = try JSONDecoder().decode([BrowserSyncEvent].self, from: remote.wire.seed())
    _ =
        if protocolVersion == 4 {
            try store.completeFolderSyncBootstrap(events: seed, cursor: 3, for: owner)
        } else {
            try store.applyRemoteSyncEvents(seed, cursor: 3, for: owner, enableSemanticMutations: protocolVersion == 3)
        }
    let oldSnapshot = try #require(try store.loadSnapshotStrict())
    #expect(oldSnapshot.tabs.first?.spaceID == "source")
    let staleSnapshot = BrowserTabSessionSnapshot(spaces: oldSnapshot.spaces, tabs: [.init(
        id: "expired", urlString: "https://expiry.example/offline", userTitleOverride: "Offline rename",
        spaceID: "target", lastActivityTimestamp: 1_800_000_000,
    )])
    try store.writeSessionBatch([.init(snapshot: staleSnapshot, origin: .local(syncMove: nil))])
    let queued = try store.pendingSyncQueue(for: owner)
    let pending = try #require(queued.first)
    #expect(queued.count == 1 && pending.protocolVersion == protocolVersion)
    switch pending {
    case .legacy(let mutation):
        let change = try #require(mutation.changes.first { $0.entityType == .tab && $0.entityID == "expired" })
        #expect(change.tabData?.spaceID == "target")
        #expect(change.tabData?.userTitleOverride == "Offline rename")
    case .semantic(let mutation):
        #expect(mutation.operations.contains { operation in
            if case .moveTabs(let ids, let destination, _, _) = operation {
                return ids == ["expired"] && destination.spaceID == "target"
            }
            return false
        })
    case .folders(let mutation):
        #expect(mutation.operations.contains { operation in
            if case .move(let items, let destination, _, _) = operation {
                return items == [.init(entityType: .tab, entityID: "expired")]
                    && destination == .tabs(spaceID: "target", placement: .temporary, pinnedFolderID: nil)
            }
            return false
        })
    case .boosts,
         .expiry,
         .mobileTabs:
        Issue.record("This fixture must capture an ordinary local edit")
    }
    let frozenRows = try expiryStoredRows(databaseURL)
    let applier = ExpiryCompatibilityApplier()
    var failures = [BrowserSyncFailurePhase]()
    let first = BrowserSyncService(
        localStore: store, remoteClient: remote, authSessionStore: auth,
        pushDebounce: .zero, pollInterval: nil, retryDelay: nil, runtimeActive: false,
        errorReporter: { _, phase in failures.append(phase) },
    )
    defer { first.accountSessionDidChange(nil) }
    first.setSnapshotApplier(applier)
    first.accountSessionDidChange(auth.session)
    first.setRuntimeActive(true)
    await first.waitForPendingOperations()

    #expect(failures == [.push], "The scripted lost ACK is the only failure; additive metadata must decode")
    #expect(try store.syncCursor(for: owner) == 100)
    #expect(store.loadSnapshot()?.tabs.isEmpty == true)
    #expect(applier.snapshots.count == 1 && applier.snapshots.first?.tabs.isEmpty == true)
    #expect(try store.pendingSyncQueue(for: owner) == queued)
    #expect(try expiryStoredRows(databaseURL) == frozenRows)
    #expect(remote.sent == [pending])
    let recovered = try store.loadArchivePage().entries
    #expect(recovered.count == 2)
    #expect(Set(recovered.map(\.tab.urlString)) == ["https://expiry.example/prior", "https://expiry.example/offline"])
    #expect(applier.archiveChanges == 1)
    let deletedBaseline = try expiryBaseline(databaseURL)
    #expect(deletedBaseline.entities["tab:expired"]?.serverSeq == 100)
    #expect(deletedBaseline.entities["tab:expired"]?.change.op == .delete)

    // A stale engine/model projection also cannot turn the additive delete into
    // a surviving tab or append a replacement upsert to the immutable queue.
    try store.writeSessionBatch([.init(snapshot: staleSnapshot, origin: .local(syncMove: nil))])
    #expect(store.loadSnapshot()?.tabs.isEmpty == true)
    #expect(try expiryStoredRows(databaseURL) == frozenRows)
    first.setRuntimeActive(false)
    first.accountSessionDidChange(nil)

    let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    #expect(try reopened.pendingSyncQueue(for: owner) == queued)
    #expect(try expiryStoredRows(databaseURL) == frozenRows)
    #expect(reopened.loadSnapshot()?.tabs.isEmpty == true)
    let secondApplier = ExpiryCompatibilityApplier()
    let second = BrowserSyncService(
        localStore: reopened, remoteClient: remote, authSessionStore: auth,
        pushDebounce: .zero, pollInterval: nil, retryDelay: nil, runtimeActive: false,
        errorReporter: { _, phase in failures.append(phase) },
    )
    defer { second.accountSessionDidChange(nil) }
    second.setSnapshotApplier(secondApplier)
    second.accountSessionDidChange(auth.session)
    second.setRuntimeActive(true)
    await second.waitForPendingOperations()

    #expect(failures == [.push])
    #expect(remote.sent == [pending, pending])
    #expect(remote.receipts.count == 1, "Retry returns the same old pre-expiry receipt")
    #expect(remote.pullVersions.allSatisfy { [2, 4, 5].contains($0) })
    #expect(
        remote.sent.allSatisfy { [2, 3, 4].contains($0.protocolVersion) },
        "Advertising v5 does not schedule expiry in an existing coordinator",
    )
    #expect(try reopened.pendingSyncQueue(for: owner).isEmpty)
    #expect(try reopened.syncCursor(for: owner) == 100, "Old ACK cursor must not replace the pull cursor")
    #expect(reopened.loadSnapshot()?.tabs.isEmpty == true)
    let onlyDeletedTabsWereApplied = secondApplier.snapshots.allSatisfy(\.tabs.isEmpty)
    #expect(onlyDeletedTabsWereApplied)
    #expect(try reopened.loadArchivePage().entries == recovered)
    #expect(secondApplier.archiveChanges == 0)
    #expect(try reopened.syncPullProtocolVersion(for: owner) == 5)
    let finalBaseline = try expiryBaseline(databaseURL)
    #expect(finalBaseline.deletedKeys.contains("tab:expired"))
    #expect(finalBaseline.entities["tab:expired"]?.serverSeq == 100)

    // Unknown/replayed ACKs and even a later upsert cannot revive this permanent identity.
    let oldReceipt = try JSONDecoder().decode(BrowserSyncPushResponse.self, from: remote.wire.receipt(
        version: 2, id: pending.id, operationCount: 1, expiry: false,
    ))
    _ = try reopened.acknowledgeSyncMutation(
        id: pending.id,
        protocolVersion: protocolVersion,
        events: oldReceipt.events,
        for: owner,
    )
    let impossibleUpsert = try JSONDecoder().decode([BrowserSyncEvent].self, from: remote.wire.laterUpsert())
    _ = try reopened.applyRemoteSyncEvents(impossibleUpsert, cursor: 101, for: owner)
    #expect(reopened.loadSnapshot()?.tabs.isEmpty == true)
    #expect(try reopened.pendingSyncQueue(for: owner).isEmpty)
    let finalOpen = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    #expect(finalOpen.loadSnapshot()?.tabs.isEmpty == true)
    #expect(try finalOpen.loadArchivePage().entries == recovered)
}

// MARK: - ExpiryCompatibilityWire

/// Fixed wire history, not a sync implementation: the old request committed at
/// sequence4, expiry committed at100, and its recovery metadata is additive.
private struct ExpiryCompatibilityWire {
    // MARK: Private

    private var priorTab: [String: Any] {
        [
            "id": "expired",
            "spaceID": "target",
            "placement": "temporary",
            "rank": 0,
            "urlString": "https://expiry.example/prior",
            "pinnedURLString": NSNull(),
            "pinnedFolderID": NSNull(),
            "title": "Loaded page before expiry",
            "userTitleOverride": "Canonical rename",
            "faviconURLString": "https://expiry.example/favicon.ico",
            "lastActivityAt": "2026-10-01T00:00:00.123456Z",
        ]
    }

    // MARK: Internal

    func seed() throws -> Data {
        var data = priorTab
        data["spaceID"] = "source"
        return try encode([
            space("source", sequence: 1), space("target", sequence: 2),
            event(sequence: 3, type: "tab", id: "expired", op: "upsert", data: data),
        ])
    }

    func laterUpsert() throws -> Data { try encode([tab(sequence: 101)]) }

    func pull(cursor: Int, protocolVersion: Int) throws -> Data {
        let history = [space("source", sequence: 1), space("target", sequence: 2), tab(sequence: 4), expiryEvent()]
        return try encode([
            "protocolVersion": protocolVersion, "supportedPushVersions": [2, 3, 4, 5], "cursor": max(cursor, 100),
            "events": history.filter { ($0["serverSeq"] as! Int) > cursor },
        ])
    }

    func receipt(version: Int, id: String, operationCount: Int, expiry: Bool) throws -> Data {
        try encode([
            "protocolVersion": version, "mutationID": id, "cursor": expiry ? 100 : 4,
            "events": [expiry ? expiryEvent() : tab(sequence: 4)],
            "outcomes": (0..<operationCount).map { ["operationIndex": $0, "status": expiry ? "deleted" : "applied"] },
        ])
    }

    private func space(_ id: String, sequence: Int) -> [String: Any] {
        event(sequence: sequence, type: "space", id: id, op: "upsert", data: [
            "id": id, "title": id, "systemImageName": "globe", "rank": sequence - 1,
            "isPinnedSectionCollapsed": false, "selectedTabID": NSNull(),
        ])
    }

    private func tab(sequence: Int) -> [String: Any] {
        event(sequence: sequence, type: "tab", id: "expired", op: "upsert", data: priorTab)
    }

    private func expiryEvent() -> [String: Any] {
        event(sequence: 100, type: "tab", id: "expired", op: "delete", data: [
            "id": "expired", "autoArchive": [
                "archivedAt": "2026-10-03T00:00:00.654321Z", "sourceServerSeq": 4, "tab": priorTab,
            ],
        ])
    }

    private func event(sequence: Int, type: String, id: String, op: String, data: [String: Any]) -> [String: Any] {
        [
            "serverSeq": sequence,
            "deviceID": "other-device",
            "entityType": type,
            "entityID": id,
            "op": op,
            "data": data,
            "createdAt": "2026-10-03T00:00:00Z",
        ]
    }

    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - ExpiryCompatibilityRemote

@MainActor private final class ExpiryCompatibilityRemote: BrowserSyncRemoteServing {
    // MARK: Internal

    let baseURL = URL(string: "https://expiry.example")!
    let wire = ExpiryCompatibilityWire()
    var sent = [BrowserSyncQueuedMutation]()
    var pullVersions = [Int]()
    var receipts = [String: Data]()
    var loseNextReceipt = true

    func pull(cursor: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        try pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession _: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        pullVersions.append(protocolVersion)
        return try JSONDecoder().decode(
            BrowserSyncPullResponse.self,
            from: wire.pull(cursor: cursor, protocolVersion: protocolVersion),
        )
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        try JSONDecoder().decode(
            BrowserSyncPushResponse.self,
            from: receive(.legacy(mutation), count: mutation.changes.count),
        )
    }

    func push(
        mutation: BrowserSyncSemanticMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncSemanticPushResponse {
        try JSONDecoder().decode(
            BrowserSyncSemanticPushResponse.self,
            from: receive(.semantic(mutation), count: mutation.operations.count),
        )
    }

    func push(
        mutation: BrowserSyncFolderMutation,
        authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncFolderPushResponse {
        try JSONDecoder().decode(
            BrowserSyncFolderPushResponse.self,
            from: receive(.folders(mutation), count: mutation.operations.count),
        )
    }

    // MARK: Private

    private func receive(_ mutation: BrowserSyncQueuedMutation, count: Int) throws -> Data {
        sent.append(mutation)
        if receipts[mutation.id] == nil {
            receipts[mutation.id] = try wire.receipt(
                version: mutation.protocolVersion,
                id: mutation.id,
                operationCount: count,
                expiry: false,
            )
        }
        if loseNextReceipt {
            loseNextReceipt = false
            throw URLError(.networkConnectionLost)
        }
        return try #require(receipts[mutation.id])
    }
}

// MARK: - ExpiryCompatibilityAuth

@MainActor private final class ExpiryCompatibilityAuth: BrowserSyncAuthSessionReading {
    let session = BrowserAuthSession(
        accessToken: "fixture-only",
        userID: "owner",
        userEmail: nil,
        deviceID: "old-client",
        serverURL: URL(string: "https://expiry.example")!,
    )

    func loadSession() -> BrowserAuthSession? { session }
}

// MARK: - ExpiryCompatibilityApplier

@MainActor private final class ExpiryCompatibilityApplier: BrowserSyncSnapshotApplying {
    var snapshots = [BrowserTabSessionSnapshot]()
    var archiveChanges = 0

    func syncArchiveDidChange() { archiveChanges += 1 }

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) { snapshots.append(snapshot) }
}

// MARK: - ExpiryStoredRow

private struct ExpiryStoredRow: Equatable {
    let position: Int
    let id: String
    let version: Int
    let bytes: Data
}

private func expiryStoredRows(_ url: URL) throws -> [ExpiryStoredRow] {
    try DatabaseQueue(path: url.path).read { db in
        try Row.fetchAll(
            db,
            sql: "SELECT position, mutation_id, protocol_version, payload FROM browser_sync_outbox ORDER BY position",
        )
        .map {
            .init(
                position: $0["position"],
                id: $0["mutation_id"],
                version: $0["protocol_version"],
                bytes: $0["payload"],
            )
        }
    }
}

private func expiryBaseline(_ url: URL) throws -> BrowserSyncOutboxBaseline {
    let data = try DatabaseQueue(path: url.path).read { try Data.fetchOne(
        $0,
        sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1",
    ) }
    let payload = try #require(data)
    return try JSONDecoder().decode(BrowserSyncOutboxBaseline.self, from: payload)
}
