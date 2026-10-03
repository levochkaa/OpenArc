import Foundation
import GRDB
import Testing

@Test(arguments: [2, 3, 4])
func pendingActivityUsesDateMaximumWhileOtherPendingMetadataStillApplies(protocolVersion: Int) throws {
    let known = "2026-10-03T01:00:00.123456+01:00"
    let newer = "2026-10-03T00:00:00.123789Z"
    let cases: [(incoming: BrowserSyncPatchValue<String>, expected: String)] = [
        (.set("2026-10-03T00:00:00.123100Z"), known),
        (.set("2026-10-03T00:00:00Z"), known),
        (.set("2026-10-03T00:00:00.123456Z"), known),
        (.set(newer), newer),
        (.clear, known),
        (.unchanged, known),
        (.set("invalid"), known),
    ]
    for value in cases {
        let baseline = try syncActivityBaseline(activity: known)
        let pending = syncActivityMutation(version: protocolVersion, activity: value.incoming, title: "Pending")
        let original = pending
        let effective = BrowserSyncOutboxProjection.effectiveChanges(baseline: baseline, pending: [pending])
        let tab = try #require(effective["tab:a"]?.tabData)
        #expect(tab.lastActivityAt == value.expected)
        #expect(tab.userTitleOverride == "Pending")
        #expect(pending == original, "Projection never rewrites queued operations or mutation identity")
        #expect(baseline.entities["tab:a"]?.change.tabData?.lastActivityAt == known)
    }

    for patch in [BrowserSyncPatchValue<String>.unchanged, .clear] {
        let baseline = try syncActivityBaseline(activity: nil)
        let effective = BrowserSyncOutboxProjection.effectiveChanges(baseline: baseline, pending: [
            syncActivityMutation(version: protocolVersion, activity: patch, title: "Still unknown"),
        ])
        #expect(effective["tab:a"]?.tabData?.lastActivityAt == nil)
        #expect(effective["tab:a"]?.tabData?.userTitleOverride == "Still unknown")
    }
}

@Test func mixedPendingActivityKeepsTheMaximumAcrossFIFOAndPermanentDeletesStillDominate() throws {
    let originalDate = "2026-10-03T00:00:00.123456Z"
    let newestDate = "2026-10-03T00:00:00.123789Z"
    let baseline = try syncActivityBaseline(activity: originalDate)
    let pending: [BrowserSyncQueuedMutation] = [
        syncActivityMutation(version: 2, activity: .set("2026-10-02T23:59:59Z"), title: "Legacy"),
        syncActivityMutation(version: 3, activity: .set(newestDate), title: "Semantic"),
        syncActivityMutation(version: 4, activity: .clear, title: "Folder"),
        syncActivityMutation(version: 3, activity: .set(originalDate), title: "Final rename"),
    ]
    let effective = BrowserSyncOutboxProjection.effectiveChanges(baseline: baseline, pending: pending)
    #expect(effective["tab:a"]?.tabData?.lastActivityAt == newestDate)
    #expect(effective["tab:a"]?.tabData?.userTitleOverride == "Final rename")
    let deletion = BrowserSyncQueuedMutation.folders(.init(id: UUID().uuidString, operations: [.deleteTab(id: "a")]))
    let staleCreate = syncActivityMutation(version: 2, activity: .set("2099-01-01T00:00:00Z"), title: "Resurrection")
    #expect(BrowserSyncOutboxProjection.effectiveChanges(baseline: baseline, pending: pending + [
        deletion,
        staleCreate,
    ])["tab:a"] == nil)
    var tombstoned = baseline
    try tombstoned.apply(syncActivityEvents([syncActivityDelete()], startingAt: 20))
    #expect(BrowserSyncOutboxProjection.effectiveChanges(baseline: tombstoned, pending: [staleCreate])["tab:a"] == nil)
}

@Test(arguments: [false, true])
func activityMaterializationPreservesOnlyTheSameCanonicalSecondOfLocalPrecision(folderSyncEnabled: Bool) throws {
    let cases: [(wire: String?, local: TimeInterval?, expected: TimeInterval?)] = [
        ("1970-01-01T00:01:40Z", 100.75, 100.75),
        ("1970-01-01T01:01:40+01:00", 100.75, 100.75),
        ("1970-01-01T00:01:39Z", 100.75, 99),
        ("1970-01-01T00:01:41Z", 100.75, 101),
        ("1970-01-01T00:01:40.125Z", 100.75, 100.125),
        ("1970-01-01T00:01:40.125Z", nil, 100.125),
        (nil, 100.75, 100.75),
        ("invalid", 100.75, 100.75),
        (nil, nil, nil),
    ]
    for value in cases {
        let baseline = try syncActivityBaseline(activity: value.wire)
        let local = syncActivitySnapshot(timestamp: value.local)
        let projected = BrowserSyncOutboxProjection.snapshot(
            baseline: baseline, pending: [BrowserSyncQueuedMutation](), local: local,
            folderSyncEnabled: folderSyncEnabled
        )
        #expect(projected.tabs.first?.lastActivityTimestamp == value.expected)
    }

    let firstDate = "2026-10-03T00:00:00.123456Z", secondDate = "2026-10-03T00:00:00.123789Z"
    let first = try BrowserSyncOutboxProjection.snapshot(
        baseline: syncActivityBaseline(activity: firstDate), pending: [BrowserSyncQueuedMutation](), local: nil,
        folderSyncEnabled: folderSyncEnabled
    )
    let second = try BrowserSyncOutboxProjection.snapshot(
        baseline: syncActivityBaseline(activity: secondDate), pending: [BrowserSyncQueuedMutation](), local: nil,
        folderSyncEnabled: folderSyncEnabled
    )
    let firstTime = try #require(first.tabs.first?.lastActivityTimestamp)
    let secondTime = try #require(second.tabs.first?.lastActivityTimestamp)
    #expect(secondTime > firstTime, "Six-digit dates in the same millisecond remain ordered")
    #expect(abs(secondTime - firstTime - 0.000333) < 0.000001)
}

@Test(arguments: [2, 3, 4])
func durableActivityOverlaySurvivesPullAckAndRestartWithoutRewritingQueuedBytes(protocolVersion: Int) throws {
    try withSyncActivityStore { fixture, store in
        let seed = try syncActivityEvents([
            syncActivitySpace(),
            syncActivityTab(activity: "2026-10-03T00:00:00.123456Z"),
        ])
        try store.bindSyncOwner(fixture.owner)
        _ =
            if protocolVersion == 4 {
                try store.completeFolderSyncBootstrap(events: seed, cursor: 2, for: fixture.owner)
            } else {
                try store.applyRemoteSyncEvents(
                    seed,
                    cursor: 2,
                    for: fixture.owner,
                    enableSemanticMutations: protocolVersion == 3
                )
            }
        // Simulate an already persisted old client request. Projection must not
        // replace these immutable bytes merely to repair its activity overlay.
        let oldTime = try Date.ISO8601FormatStyle().parse("2026-10-02T23:59:59Z").timeIntervalSince1970
        try store.writeSessionBatch([.init(
            snapshot: syncActivitySnapshot(timestamp: oldTime, title: "Offline rename"),
            origin: .local(syncMove: nil)
        )])
        let pending = try #require(try store.pendingSyncQueue(for: fixture.owner).first)
        #expect(pending.protocolVersion == protocolVersion)
        let frozenRows = try fixture.rows()
        let latestDate = "2026-10-03T00:00:00.123789Z"
        let latestEvent = try syncActivityEvents(
            [syncActivityTab(activity: latestDate, title: "Remote rename")],
            startingAt: 10
        )
        let projected = try store.applyRemoteSyncEvents(latestEvent, cursor: 10, for: fixture.owner)
        let expectedTime = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(latestDate)
            .timeIntervalSince1970
        #expect(projected.tabs.first?.lastActivityTimestamp == expectedTime)
        #expect(projected.tabs.first?.userTitleOverride == "Offline rename")
        #expect(try fixture.rows() == frozenRows)

        let reopened = try BrowserSQLiteSessionStore(databaseURL: fixture.databaseURL)
        #expect(try reopened.loadSnapshotStrict() == projected)
        #expect(try reopened.pendingSyncQueue(for: fixture.owner) == [pending])
        let baselineBeforeAck = try fixture.baseline()
        let oldReceipt = try syncActivityEvents(
            [syncActivityTab(activity: "2026-10-02T23:59:59Z", title: "Old receipt")],
            startingAt: 5
        )
        let acknowledged = try reopened.acknowledgeSyncMutation(
            id: pending.id,
            protocolVersion: protocolVersion,
            events: oldReceipt,
            for: fixture.owner
        )
        #expect(acknowledged.tabs.first?.lastActivityTimestamp == expectedTime)
        #expect(acknowledged.tabs.first?.userTitleOverride == "Remote rename")
        #expect(try reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
        #expect(try reopened.syncCursor(for: fixture.owner) == 10)
        #expect(try fixture.baseline().entities["tab:a"]?.serverSeq == baselineBeforeAck.entities["tab:a"]?.serverSeq)
        #expect(try fixture.baseline().entities["tab:a"]?.change == baselineBeforeAck.entities["tab:a"]?.change)

        // Canonical sequence remains authoritative. Do not reject a newer event
        // or keep a different local date forever when no pending activity wins.
        let olderCanonical = try syncActivityEvents(
            [syncActivityTab(activity: "2026-10-02T23:59:58Z", title: "New canonical metadata")],
            startingAt: 11
        )
        let canonical = try reopened.applyRemoteSyncEvents(olderCanonical, cursor: 11, for: fixture.owner)
        #expect(canonical.tabs.first?.userTitleOverride == "New canonical metadata")
        #expect(canonical.tabs.first?.lastActivityTimestamp == oldTime - 1)
        #expect(try fixture.baseline().entities["tab:a"]?.serverSeq == 11)
        #expect(try fixture.baseline().entities["tab:a"]?.change.tabData?.lastActivityAt == "2026-10-02T23:59:58Z")
        _ = try reopened.applyRemoteSyncEvents(
            syncActivityEvents([syncActivityDelete()], startingAt: 12),
            cursor: 12,
            for: fixture.owner
        )
        let afterDelete = try reopened.applyRemoteSyncEvents(
            syncActivityEvents([syncActivityTab(activity: "2099-01-01T00:00:00Z")], startingAt: 13),
            cursor: 13,
            for: fixture.owner
        )
        #expect(try afterDelete.tabs.isEmpty && reopened.pendingSyncQueue(for: fixture.owner).isEmpty)
    }
}

private func syncActivityMutation(
    version: Int,
    activity: BrowserSyncPatchValue<String>,
    title: String
) -> BrowserSyncQueuedMutation {
    let id = UUID().uuidString
    let fields = BrowserSyncSemanticTabPatch(userTitleOverride: .set(title), lastActivityAt: activity)
    switch version {
    case 2:
        let date: String? =
            if case .set(let value) = activity {
                value
            } else {
                nil
            }
        return .legacy(.init(id: id, changes: [syncActivityTab(activity: date, title: title)]))
    case 3: return .semantic(.init(id: id, operations: [.patchTab(id: "a", fields: fields)]))
    default: return .folders(.init(id: id, operations: [.patchTab(id: "a", fields: fields)]))
    }
}

private func syncActivityBaseline(activity: String?) throws -> BrowserSyncOutboxBaseline {
    var baseline = BrowserSyncOutboxBaseline()
    try baseline.apply(syncActivityEvents([syncActivitySpace(), syncActivityTab(activity: activity)]))
    return baseline
}

private func syncActivitySpace() -> BrowserSyncChange {
    .init(
        entityType: .space,
        entityID: "space",
        op: .upsert,
        spaceData: .init(
            title: "Space",
            systemImageName: "globe",
            rank: 0,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil
        ),
        tabData: nil
    )
}

private func syncActivityTab(activity: String?, title: String? = nil) -> BrowserSyncChange {
    .init(
        entityType: .tab,
        entityID: "a",
        op: .upsert,
        spaceData: nil,
        tabData: .init(
            spaceID: "space",
            placement: .temporary,
            rank: 0,
            urlString: "https://activity.example/a",
            pinnedURLString: nil,
            title: nil,
            userTitleOverride: title,
            faviconURLString: nil,
            lastActivityAt: activity
        )
    )
}

private func syncActivityDelete() -> BrowserSyncChange {
    .init(entityType: .tab, entityID: "a", op: .delete, spaceData: nil, tabData: nil)
}

private func syncActivitySnapshot(timestamp: TimeInterval?, title: String? = nil) -> BrowserTabSessionSnapshot {
    .init(
        spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
        tabs: [.init(
            id: "a",
            urlString: "https://activity.example/a",
            userTitleOverride: title,
            spaceID: "space",
            lastActivityTimestamp: timestamp
        )]
    )
}

private func syncActivityEvents(_ changes: [BrowserSyncChange], startingAt: Int = 1) throws -> [BrowserSyncEvent] {
    try changes.enumerated().map { offset, change in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
        var data = object["data"] as? [String: Any] ?? [:]
        data["id"] = change.entityID
        let event: [String: Any] = [
            "serverSeq": startingAt + offset,
            "deviceID": NSNull(),
            "entityType": change.entityType.rawValue,
            "entityID": change.entityID,
            "op": change.op.rawValue,
            "data": data,
            "createdAt": "2026-10-03T00:00:00Z",
        ]
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: event))
    }
}

// MARK: - SyncActivityStoreFixture

private struct SyncActivityStoreFixture {
    struct RowEvidence: Equatable {
        let position: Int
        let id: String
        let payload: Data
        let version: Int
    }

    let databaseURL: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://activity.example")!, userID: "activity")

    func rows() throws -> [RowEvidence] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position"
            )
            .map {
                RowEvidence(
                    position: $0["position"],
                    id: $0["mutation_id"],
                    payload: $0["payload"],
                    version: $0["protocol_version"]
                )
            }
        }
    }

    func baseline() throws -> BrowserSyncOutboxBaseline {
        let data = try DatabaseQueue(path: databaseURL.path).read { try Data.fetchOne(
            $0,
            sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1"
        ) }
        let payload = try #require(data)
        return try JSONDecoder().decode(BrowserSyncOutboxBaseline.self, from: payload)
    }
}

private func withSyncActivityStore(_ body: (SyncActivityStoreFixture, BrowserSQLiteSessionStore) throws
    -> Void) throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncActivity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try runSyncActivityStore(directory: directory, body)
}

private func runSyncActivityStore(
    directory: URL,
    _ body: (SyncActivityStoreFixture, BrowserSQLiteSessionStore) throws -> Void
) throws {
    let fixture = SyncActivityStoreFixture(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
    let store = try BrowserSQLiteSessionStore(databaseURL: fixture.databaseURL)
    try body(fixture, store)
}
