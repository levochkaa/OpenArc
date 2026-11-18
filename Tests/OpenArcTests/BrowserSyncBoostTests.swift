// BrowserSyncBoostTests.swift

import Foundation
import GRDB
import Testing

// MARK: - Wire format

@Test func boostOperationsEncodeTheWireShapeAndRejectOtherEntities() throws {
    let record = BrowserSyncBoostRecord(
        host: "example.com", isEnabled: false, css: "a {}", javaScript: "run()", zappedSelectors: ["#ad"],
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let upsert = try String(
        decoding: encoder.encode(BrowserSyncBoostOperation.upsert(id: "b", record: record)),
        as: UTF8.self,
    )
    #expect(upsert ==
        ##"{"data":{"css":"a {}","host":"example.com","isEnabled":false,"javaScript":"run()","zappedSelectors":["#ad"]},"entityID":"b","entityType":"boost","kind":"upsert"}"##)
    let delete = try String(decoding: encoder.encode(BrowserSyncBoostOperation.delete(id: "b")), as: UTF8.self)
    #expect(delete == #"{"entityID":"b","entityType":"boost","kind":"delete"}"#)
    #expect(try JSONDecoder().decode(BrowserSyncBoostOperation.self, from: Data(upsert.utf8)) == .upsert(
        id: "b",
        record: record,
    ))

    let tab = Data(#"{"kind":"delete","entityType":"tab","entityID":"b"}"#.utf8)
    #expect(throws: BrowserSyncBoostError.self) { try JSONDecoder().decode(BrowserSyncBoostOperation.self, from: tab) }
    let patch = Data(#"{"kind":"patch","entityType":"boost","entityID":"b"}"#.utf8)
    #expect(throws: BrowserSyncBoostError.self) { try JSONDecoder().decode(BrowserSyncBoostOperation.self, from: patch)
    }

    var huge = record
    huge.css = String(repeating: "a", count: BrowserSyncBoostRecord.codeLimit + 1)
    #expect(!huge.isSyncable)
    #expect(throws: BrowserSyncBoostError.self) { try encoder.encode(BrowserSyncBoostOperation.upsert(
        id: "b",
        record: huge,
    )) }
    var noHost = record
    noHost.host = ""
    #expect(!noHost.isSyncable)

    let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSyncBoostPushRequest(
        mutationID: "m", deviceID: "d", operations: [.delete(id: "b")],
    ))) as? [String: Any]
    #expect(request?["protocolVersion"] as? Int == 6)
}

@Test func boostEventsDecodeByTheirEnvelope() throws {
    let json = Data(#"""
    [{"serverSeq":4,"deviceID":null,"entityType":"boost","entityID":"b","op":"upsert","createdAt":"2026-11-19T00:00:00Z",
      "data":{"id":"b","host":"example.com","isEnabled":true,"css":"","javaScript":"","zappedSelectors":[]}},
     {"serverSeq":5,"deviceID":null,"entityType":"boost","entityID":"b","op":"delete","createdAt":"2026-11-19T00:00:00Z",
      "data":{"id":"b"}}]
    """#.utf8)
    let events = try JSONDecoder().decode([BrowserSyncEvent].self, from: json)
    guard case .boost(let data) = events[0].data else {
        Issue.record("A boost upsert decodes as a boost")
        return
    }
    #expect(data.record == .init(host: "example.com", isEnabled: true, css: "", javaScript: "", zappedSelectors: []))
    #expect(events[1].data == .deleted(id: "b"))
    // Stored events round-trip through the single-value fallback too.
    let reencoded = try JSONDecoder().decode(BrowserSyncEventData.self, from: JSONEncoder().encode(events[0].data))
    #expect(reencoded == events[0].data)
}

@Test func boostReceiptsMustAnswerTheirOwnMutationWithBoostEvents() throws {
    let mutation = BrowserSyncBoostMutation(id: UUID().uuidString, operations: [.delete(id: "b")])
    let event = BoostSyncServer.event(seq: 3, id: "b", record: nil)
    let valid = BrowserSyncBoostPushResponse(
        protocolVersion: 6, mutationID: mutation.id, cursor: 3, events: [event],
        outcomes: [.init(operationIndex: 0, status: .applied, reason: nil)],
    )
    try valid.validate(for: mutation)
    let other = BrowserSyncBoostPushResponse(
        protocolVersion: 6, mutationID: UUID().uuidString, cursor: 3, events: [event], outcomes: valid.outcomes,
    )
    #expect(throws: BrowserRemoteSyncError.self) { try other.validate(for: mutation) }
    let missingOutcome = BrowserSyncBoostPushResponse(
        protocolVersion: 6, mutationID: mutation.id, cursor: 3, events: [event], outcomes: [],
    )
    #expect(throws: BrowserRemoteSyncError.self) { try missingOutcome.validate(for: mutation) }
    let tabEvent = BrowserSyncEvent(
        serverSeq: 3, deviceID: nil, entityType: "tab", entityID: "b", op: "delete", data: .deleted(id: "b"),
        createdAt: "2026-11-19T00:00:00Z",
    )
    let foreign = BrowserSyncBoostPushResponse(
        protocolVersion: 6, mutationID: mutation.id, cursor: 3, events: [tabEvent], outcomes: valid.outcomes,
    )
    #expect(throws: BrowserRemoteSyncError.self) { try foreign.validate(for: mutation) }
}

// MARK: - Merge and conflict rules

@Test func boostDeletionsArePermanentAndOlderEventsNeverWin() throws {
    let red = BoostSyncServer.record("example.com", css: "red")
    let blue = BoostSyncServer.record("example.com", css: "blue")
    var baseline = BrowserSyncBoostBaseline()
    try baseline.apply([BoostSyncServer.event(seq: 2, id: "b", record: blue)])
    try baseline.apply([BoostSyncServer.event(seq: 1, id: "b", record: red)])
    #expect(baseline.entries["b"]?.record == blue, "A replayed older event does not win")
    try baseline.apply([BoostSyncServer.event(seq: 3, id: "b", record: nil)])
    try baseline.apply([BoostSyncServer.event(seq: 4, id: "b", record: red)])
    #expect(baseline.entries["b"]?.record == nil, "A tombstone is permanent")
    #expect(baseline.tombstones.entries.keys.sorted() == ["b"])
    #expect(throws: BrowserSyncOutboxError.self) {
        try baseline.apply([.init(
            serverSeq: 9, deviceID: nil, entityType: "boost", entityID: "c", op: "upsert",
            data: .boost(.init(id: "c", host: nil, isEnabled: nil, css: nil, javaScript: nil, zappedSelectors: nil)),
            createdAt: "2026-11-19T00:00:00Z",
        )])
    }
}

@Test func theNewestWriteOfAHostWinsAndQueuedWritesOverlayTheServer() throws {
    var baseline = BrowserSyncBoostBaseline()
    try baseline.apply([
        BoostSyncServer.event(seq: 1, id: "a", record: BoostSyncServer.record("example.com", css: "a")),
        BoostSyncServer.event(seq: 2, id: "b", record: BoostSyncServer.record("example.com", css: "b")),
        BoostSyncServer.event(seq: 3, id: "c", record: BoostSyncServer.record("other.org", css: "c")),
        BoostSyncServer.event(seq: 4, id: "gone", record: nil),
    ])
    let server = BrowserSyncBoostState(baseline: baseline, pending: [])
    #expect(server.winners.map(\.id) == ["b", "c"], "Two devices made a boost for one host: the later write shows")
    #expect(server.liveIDs(forHost: "example.com") == ["a", "b"])

    let queued = BrowserSyncBoostState(baseline: baseline, pending: [
        .boosts(.init(id: UUID().uuidString, operations: [
            .upsert(id: "a", record: BoostSyncServer.record("example.com", css: "edited")),
            .delete(id: "c"),
            .upsert(id: "gone", record: BoostSyncServer.record("gone.org")),
        ])),
    ])
    #expect(queued.winners.map(\.id) == ["a"], "A queued edit is the newest write")
    #expect(queued.winners.first?.record.css == "edited")
    #expect(queued.deleted == ["c", "gone"], "A queued write never revives a deleted boost")
    #expect(queued.knows("c") && !queued.knows("new"))
}

@Test func enablingSyncUploadsUnknownLocalBoostsAndTakesOverTheServersBoostOfTheSameHost() throws {
    var baseline = BrowserSyncBoostBaseline()
    try baseline.apply([
        BoostSyncServer.event(seq: 1, id: "server", record: BoostSyncServer.record("example.com", css: "server")),
        BoostSyncServer.event(seq: 2, id: "deleted", record: nil),
    ])
    let state = BrowserSyncBoostState(baseline: baseline, pending: [])
    let local = [
        BrowserSyncBoostEntry(id: "mine", record: BoostSyncServer.record("example.com", css: "mine")),
        BrowserSyncBoostEntry(id: "new", record: BoostSyncServer.record("new.org")),
        BrowserSyncBoostEntry(id: "deleted", record: BoostSyncServer.record("deleted.org")),
        BrowserSyncBoostEntry(id: "server", record: BoostSyncServer.record("example.com", css: "server")),
    ]
    #expect(state.adoptionOperations(for: local) == [
        .upsert(id: "server", record: BoostSyncServer.record("example.com", css: "mine")),
        .upsert(id: "new", record: BoostSyncServer.record("new.org")),
    ])
}

@Test func localEditsReplaceTheirBoostRetireDuplicatesAndNeverReviveADeletion() throws {
    var baseline = BrowserSyncBoostBaseline()
    try baseline.apply([
        BoostSyncServer.event(seq: 1, id: "old", record: BoostSyncServer.record("example.com", css: "old")),
        BoostSyncServer.event(seq: 2, id: "kept", record: BoostSyncServer.record("example.com", css: "kept")),
        BoostSyncServer.event(seq: 3, id: "news", record: BoostSyncServer.record("news.org")),
        BoostSyncServer.event(seq: 4, id: "gone", record: nil),
    ])
    let state = BrowserSyncBoostState(baseline: baseline, pending: [])
    let edited = BrowserBoost(host: "example.com", css: "edited", syncID: "kept")
    let revived = BrowserBoost(host: "gone.org", css: "x", syncID: "gone")
    let operations = BrowserBoostSyncMerge.operations(
        changedIDs: ["kept", "gone"], removed: ["news": "news.org"], local: [edited, revived], state: state,
    )
    #expect(operations == [
        .upsert(id: "kept", record: edited.syncRecord),
        .delete(id: "old"),
        .delete(id: "news"),
    ])
    // Removing a host deletes its hidden duplicates too, so none of them shows up afterwards.
    #expect(BrowserBoostSyncMerge.operations(
        changedIDs: [], removed: ["kept": "example.com"], local: [], state: state,
    ) == [.delete(id: "kept"), .delete(id: "old")])
    // An unchanged boost needs no write.
    let unchanged = BrowserBoost(host: "news.org", css: "a {}", syncID: "news")
    #expect(BrowserBoostSyncMerge.operations(
        changedIDs: ["news"], removed: [:], local: [unchanged], state: state,
    )
    .isEmpty)
}

@Test func syncedBoostsReplaceLocalOnesInPlaceAndKeepBoostsSyncHasNotSeen() throws {
    var baseline = BrowserSyncBoostBaseline()
    try baseline.apply([
        BoostSyncServer.event(seq: 1, id: "a", record: BoostSyncServer.record("example.com", css: "remote")),
        BoostSyncServer.event(seq: 2, id: "z", record: BoostSyncServer.record("added.org")),
        BoostSyncServer.event(seq: 3, id: "gone", record: nil),
    ])
    let state = BrowserSyncBoostState(baseline: baseline, pending: [])
    let local = [
        BrowserBoost(host: "local.org", css: "x", syncID: "local"),
        BrowserBoost(host: "example.com", css: "stale", syncID: "a"),
        BrowserBoost(host: "gone.org", css: "x", syncID: "gone"),
    ]
    let merged = BrowserBoostSyncMerge.merged(local: local, state: state)
    #expect(merged.map(\.syncID) == ["local", "a", "z"])
    #expect(merged[1].css == "remote")
    #expect(BrowserBoostSyncMerge.merged(local: merged, state: state) == merged, "Merging is stable")
}

// MARK: - Outbox and projection

@Test @MainActor func boostWritesWaitForBoostSyncThenQueueAsVersion6Rows() throws {
    let device = try BoostSyncDevice(server: BoostSyncServer(), name: "a")
    defer { device.close() }
    #expect(try device.store.loadSyncBoostState() == nil)
    #expect(try device.store.enqueueSyncBoosts([.delete(id: "b")]) == false)
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 5)

    let local = [BrowserSyncBoostEntry(id: "b", record: BoostSyncServer.record("example.com"))]
    _ = try device.store.completeBoostSyncBootstrap(
        events: device.server.log, cursor: device.server.seq, for: device.owner, localBoosts: local,
    )
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 6)
    let queue = try device.store.pendingSyncQueue(for: device.owner)
    #expect(queue.map(\.protocolVersion) == [6])
    guard case .boosts(let adoption) = queue.first else {
        Issue.record("Adoption queues a boost row")
        return
    }
    #expect(adoption.operations == [.upsert(id: "b", record: local[0].record)])
    #expect(try device.store.loadSyncBoostState()?.winners == local, "Queued writes show before the server answers")

    // Rows survive a reopen with their identity and bytes.
    let bytes = try device.outboxBytes()
    let reopened = try BrowserSQLiteSessionStore(databaseURL: device.databaseURL)
    #expect(try reopened.pendingSyncQueue(for: device.owner) == queue)
    #expect(try device.outboxBytes() == bytes)

    // A receipt moves the write into the baseline and drops the row.
    let revision = try reopened.syncBoostRevision(for: device.owner)
    let receipt = BoostSyncServer.event(seq: device.server.seq + 1, id: "b", record: local[0].record)
    _ = try reopened.acknowledgeSyncMutation(
        id: adoption.id, protocolVersion: 6, events: [receipt], for: device.owner,
    )
    #expect(try reopened.pendingSyncQueue(for: device.owner).isEmpty)
    #expect(try reopened.loadSyncBoostState()?.winners == local)
    #expect(try reopened.syncBoostRevision(for: device.owner) > revision)
    #expect(try reopened.loadSnapshotStrict() == device.snapshotBefore, "Boosts never touch Spaces or tabs")
}

@Test @MainActor func aTombstoneSurvivesARebootstrapFromCursorZero() throws {
    let device = try BoostSyncDevice(server: BoostSyncServer(), name: "a")
    defer { device.close() }
    let deletion = BoostSyncServer.event(seq: 10, id: "b", record: nil)
    _ = try device.store.completeBoostSyncBootstrap(
        events: device.server.log + [deletion], cursor: 10, for: device.owner, localBoosts: [],
    )
    // A replacement device replays a history that has not reached this deletion yet.
    let stale = BoostSyncServer.event(seq: 5, id: "b", record: BoostSyncServer.record("example.com"))
    _ = try device.store.completeBoostSyncBootstrap(
        events: device.server.log + [stale], cursor: 10, for: device.owner,
        localBoosts: [.init(id: "b", record: BoostSyncServer.record("example.com"))],
    )
    #expect(try device.store.loadSyncBoostState()?.winners == [])
    #expect(try device.store.pendingSyncQueue(for: device.owner).isEmpty, "A deleted boost is not uploaded again")
}

// MARK: - Two devices through the coordinator

@Test @MainActor func boostsConvergeAcrossTwoDevicesAndDeletionsStayDeleted() async throws {
    let server = BoostSyncServer()
    let a = try BoostSyncDevice(server: server, name: "a")
    let b = try BoostSyncDevice(server: server, name: "b")
    defer {
        a.close()
        b.close()
    }
    // Device A had a boost before sync carried boosts.
    a.preferences.boosts.updateBoost(host: "example.com") { $0.css = "body { color: red }" }
    let identity = try #require(a.preferences.boosts.first?.syncID)
    await a.start()
    #expect(server.calls(of: "a").starts(with: ["pull:5:1", "pull:6:0"]), "Upgrading replays history from zero")
    #expect(server.live[identity]?.css == "body { color: red }")

    await b.start()
    #expect(b.preferences.boosts.map(\.syncID) == [identity])
    #expect(b.preferences.boosts.first?.css == "body { color: red }")

    // An edit and a switch on B show up on A.
    b.preferences.boosts.updateBoost(host: "example.com") { boost in
        boost.isEnabled = false
        boost.zappedSelectors = ["#ad"]
    }
    b.bridge.flush()
    await b.service.waitForPendingOperations()
    await a.pull()
    #expect(a.preferences.boosts.map(\.syncRecord) == b.preferences.boosts.map(\.syncRecord))
    #expect(a.preferences.boosts.first?.isEnabled == false)

    // A deletes it while B, offline, still edits it: the deletion wins on both.
    b.service.setRuntimeActive(false)
    a.preferences.boosts.removeBoost(host: "example.com")
    a.bridge.flush()
    await a.service.waitForPendingOperations()
    #expect(server.deleted.contains(identity))
    b.preferences.boosts.updateBoost(host: "example.com") { $0.css = "late" }
    b.bridge.flush()
    b.service.setRuntimeActive(true)
    await b.service.waitForPendingOperations()
    #expect(server.outcomes.last == .init(operationIndex: 0, status: .rejected, reason: "deleted"))
    #expect(b.preferences.boosts.isEmpty, "A late edit does not bring the boost back")
    await a.pull()
    #expect(a.preferences.boosts.isEmpty)

    // Making it again takes a fresh identity, which syncs as usual.
    b.preferences.boosts.updateBoost(host: "example.com") { $0.css = "again" }
    b.bridge.flush()
    await b.service.waitForPendingOperations()
    await a.pull()
    let again = try #require(a.preferences.boosts.first)
    #expect(again.syncID != identity && again.css == "again")
}

@Test @MainActor func concurrentBoostsForOneHostSettleOnTheLaterWrite() async throws {
    let server = BoostSyncServer()
    let a = try BoostSyncDevice(server: server, name: "a")
    let b = try BoostSyncDevice(server: server, name: "b")
    defer {
        a.close()
        b.close()
    }
    await a.start()
    await b.start()
    a.preferences.boosts.updateBoost(host: "example.com") { $0.css = "from a" }
    b.preferences.boosts.updateBoost(host: "example.com") { $0.css = "from b" }
    a.bridge.flush()
    await a.service.waitForPendingOperations()
    b.bridge.flush()
    await b.service.waitForPendingOperations()
    await a.pull()
    #expect(a.preferences.boosts.map(\.css) == ["from b"])
    #expect(b.preferences.boosts.map(\.css) == ["from b"])
    #expect(server.live.count == 2, "Both writes reached the server")

    // The next edit of the host retires the hidden duplicate.
    a.preferences.boosts.updateBoost(host: "example.com") { $0.css = "settled" }
    a.bridge.flush()
    await a.service.waitForPendingOperations()
    #expect(server.live.values.map(\.css) == ["settled"])
    await b.pull()
    #expect(b.preferences.boosts.map(\.css) == ["settled"])
}

@Test @MainActor func aServerWithoutBoostsKeepsTabSyncAndBoostsReturnWithIt() async throws {
    let server = BoostSyncServer()
    let device = try BoostSyncDevice(server: server, name: "a")
    defer { device.close() }
    device.preferences.boosts.updateBoost(host: "example.com") { $0.css = "kept" }
    await device.start()
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 6)
    let cursor = try device.store.syncCursor(for: device.owner)

    server.capabilities = [2, 3, 4, 5]
    await device.pull()
    #expect(server.calls(of: "a").suffix(2) == ["pull:6:\(cursor)", "pull:5:\(cursor)"])
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 5)
    #expect(try device.store.loadSyncBoostState() == nil)
    #expect(device.preferences.boosts.map(\.css) == ["kept"], "This Mac keeps its boosts meanwhile")

    server.capabilities = [2, 3, 4, 5, 6]
    await device.pull()
    #expect(server.calls(of: "a").suffix(2) == ["pull:5:\(cursor)", "pull:6:0"])
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 6)
    #expect(try device.store.loadSyncBoostState()?.winners.map(\.record.css) == ["kept"])
    #expect(try device.store.pendingSyncQueue(for: device.owner).isEmpty, "A boost the server has is not sent again")
}

// MARK: - BoostSyncServer

/// A server that keeps boosts the way the real one does: whole records, the
/// last committed write wins, deletions are permanent, and only v6 readers see boosts.
@MainActor final class BoostSyncServer: BrowserSyncRemoteServing {
    // MARK: Internal

    let baseURL = URL(string: "https://boost-sync.example")!
    private(set) var log = [BrowserSyncEvent]()
    private(set) var seq = 0
    private(set) var live = [String: BrowserSyncBoostRecord]()
    private(set) var deleted = Set<String>()
    private(set) var outcomes = [BrowserSyncBoostOutcome]()
    /// What pulls advertise; dropping 6 acts as a server that stopped carrying boosts.
    var capabilities = [2, 3, 4, 5, 6]

    private var callLog = [(device: String, call: String)]()
    private var boostReaders = Set<String>()

    init() {
        append(.init(
            serverSeq: 0, deviceID: "remote", entityType: "space", entityID: "work", op: "upsert",
            data: .space(.init(
                id: "work", title: "Work", systemImageName: "globe", rank: 0,
                isPinnedSectionCollapsed: false, selectedTabID: nil,
            )), createdAt: "2026-11-19T00:00:00Z",
        ))
    }

    nonisolated static func record(_ host: String, css: String = "a {}") -> BrowserSyncBoostRecord {
        .init(host: host, isEnabled: true, css: css, javaScript: "", zappedSelectors: [])
    }

    nonisolated static func event(seq: Int, id: String, record: BrowserSyncBoostRecord?) -> BrowserSyncEvent {
        let data: BrowserSyncEventData = record.map {
            .boost(.init(
                id: id, host: $0.host, isEnabled: $0.isEnabled, css: $0.css, javaScript: $0.javaScript,
                zappedSelectors: $0.zappedSelectors,
            ))
        } ?? .deleted(id: id)
        return .init(
            serverSeq: seq, deviceID: "remote", entityType: "boost", entityID: id,
            op: record == nil ? "delete" : "upsert", data: data, createdAt: "2026-11-19T00:00:00Z",
        )
    }

    func calls(of device: String) -> [String] {
        callLog.filter { $0.device == device }.map(\.call)
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        try pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        callLog.append((authSession.deviceID, "pull:\(protocolVersion):\(cursor)"))
        if protocolVersion == 6 {
            guard cursor == 0 || boostReaders.contains(authSession.deviceID) else {
                throw BrowserRemoteSyncError.boostBootstrapRequired
            }
            boostReaders.insert(authSession.deviceID)
        } else {
            boostReaders.remove(authSession.deviceID)
        }
        let events = log.filter { $0.serverSeq > cursor && (protocolVersion == 6 || $0.entityType != "boost") }
        return .init(
            cursor: events.last?.serverSeq ?? cursor, events: events,
            protocolVersion: protocolVersion == 2 ? 2 : protocolVersion, supportedPushVersions: capabilities,
        )
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        Issue.record("Boost tests write no tabs: \(mutation.id)")
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }

    func push(
        mutation: BrowserSyncSemanticMutation, authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncSemanticPushResponse {
        Issue.record("Boost tests write no tabs: \(mutation.id)")
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }

    func push(
        mutation: BrowserSyncBoostMutation, authSession: BrowserAuthSession,
    ) -> BrowserSyncBoostPushResponse {
        callLog.append((authSession.deviceID, "push:6"))
        var events = [BrowserSyncEvent]()
        var results = [BrowserSyncBoostOutcome]()
        for (index, operation) in mutation.operations.enumerated() {
            let id = operation.entityID
            let tombstone = log.last { $0.entityID == id && $0.op == "delete" }
            switch operation {
            case .upsert(_, let record):
                if let tombstone {
                    events.append(tombstone)
                    results.append(.init(operationIndex: index, status: .rejected, reason: "deleted"))
                } else {
                    live[id] = record
                    events.append(append(Self.event(seq: 0, id: id, record: record)))
                    results.append(.init(operationIndex: index, status: .applied, reason: nil))
                }
            case .delete:
                if let tombstone {
                    events.append(tombstone)
                    results.append(.init(operationIndex: index, status: .deleted, reason: nil))
                } else {
                    live[id] = nil
                    deleted.insert(id)
                    events.append(append(Self.event(seq: 0, id: id, record: nil)))
                    results.append(.init(operationIndex: index, status: .applied, reason: nil))
                }
            }
        }
        outcomes += results
        return .init(protocolVersion: 6, mutationID: mutation.id, cursor: seq, events: events, outcomes: results)
    }

    // MARK: Private

    @discardableResult private func append(_ event: BrowserSyncEvent) -> BrowserSyncEvent {
        seq += 1
        let stored = BrowserSyncEvent(
            serverSeq: seq, deviceID: event.deviceID, entityType: event.entityType, entityID: event.entityID,
            op: event.op, data: event.data, createdAt: event.createdAt,
        )
        log.append(stored)
        return stored
    }
}

// MARK: - BoostSyncDevice

/// One Mac: a profile store already at protocol 5, its coordinator and the
/// bridge to its own preferences.
@MainActor final class BoostSyncDevice: BrowserSyncAuthSessionReading {
    // MARK: Internal

    let server: BoostSyncServer
    let directory: URL
    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let owner: BrowserSyncOwner
    let preferences: BrowserUserPreferencesStore
    let snapshotBefore: BrowserTabSessionSnapshot?
    let session: BrowserAuthSession
    private(set) var service: BrowserSyncService!
    private(set) var bridge: BrowserBoostSyncBridge!

    init(server: BoostSyncServer, name: String) throws {
        self.server = server
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoostSync-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.session = .init(
            accessToken: "fixture-only", userID: "owner", userEmail: nil, deviceID: name, serverURL: server.baseURL,
        )
        self.owner = .init(baseURL: server.baseURL, userID: session.userID)
        let defaults = try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("BoostSync-\(name)")))
        self.preferences = BrowserUserPreferencesStore(userDefaults: defaults)
        try store.bindSyncOwner(owner)
        let history = server.log.filter { $0.entityType != "boost" }
        let cursor = history.last?.serverSeq ?? 0
        _ = try store.completeFolderSyncBootstrap(events: history, cursor: cursor, for: owner)
        self.snapshotBefore = try store.completeExpirySyncBootstrap(events: history, cursor: cursor, for: owner)
    }

    func loadSession() -> BrowserAuthSession? { session }

    /// Starts the coordinator and bridge, then waits for the first pull and pushes.
    func start() async {
        let service = BrowserSyncService(
            localStore: store, remoteClient: server, authSessionStore: self,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil, waitForInputPause: {},
        )
        let bridge = BrowserBoostSyncBridge(store: store, preferences: preferences, debounce: .seconds(3600)) {
            [weak service] in service?.scheduleQueuedPush()
        }
        service.setBoostApplier(bridge)
        self.service = service
        self.bridge = bridge
        service.accountSessionDidChange(session)
        await service.waitForPendingOperations()
    }

    func pull() async {
        service.schedulePull()
        await service.waitForPendingOperations()
    }

    func close() {
        service?.accountSessionDidChange(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    func outboxBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }
}
