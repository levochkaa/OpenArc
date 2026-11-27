// BrowserSyncMobileTabTests.swift

import Foundation
import GRDB
import Testing

// MARK: - Wire format

@Test func mobileTabOperationsEncodeTheWireShapeAndRejectOtherEntities() throws {
    let created = Date(timeIntervalSince1970: 1_800_000_000.75)
    let record = BrowserSyncMobileTabRecord(urlString: "https://example.com/a", title: "A", createdAt: created)
    let data = try JSONEncoder().encode(BrowserSyncMobileTabOperation.upsert(id: "t1", record: record))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["kind"] as? String == "upsert")
    #expect(object["entityType"] as? String == "mobileTab")
    #expect(object["entityID"] as? String == "t1")
    let payload = try #require(object["data"] as? [String: Any])
    #expect(payload["urlString"] as? String == "https://example.com/a")
    #expect(payload["title"] as? String == "A")
    #expect(payload["createdAt"] as? String == "2027-01-15T08:00:00Z", "Dates go out in whole seconds, UTC")
    #expect(payload["lastActivityAt"] == nil, "An absent activity is omitted, never null")

    let decoded = try JSONDecoder().decode(BrowserSyncMobileTabOperation.self, from: data)
    #expect(decoded == .upsert(id: "t1", record: record))
    let boost = Data(#"{"kind":"delete","entityType":"boost","entityID":"t1"}"#.utf8)
    #expect(throws: BrowserSyncMobileTabError.invalidOperation) {
        try JSONDecoder().decode(BrowserSyncMobileTabOperation.self, from: boost)
    }
    // A blank tab stays on its device.
    let blank = BrowserSyncMobileTabOperation.upsert(
        id: "t2",
        record: .init(urlString: "about:blank", createdAt: created),
    )
    #expect(throws: BrowserSyncMobileTabError.invalidOperation) { try blank.validate() }
}

@Test func mobileTabEventsDecodeTheServersSixFractionalDigits() throws {
    let json = Data(#"""
    {"serverSeq":4,"deviceID":"d","entityType":"mobileTab","entityID":"t1","op":"upsert",
     "data":{"id":"t1","urlString":"https://example.com","createdAt":"2027-01-15T08:00:00.000000Z",
             "lastActivityAt":"2027-01-15T08:05:00.000000Z"},
     "createdAt":"2027-01-15T08:05:00Z"}
    """#.utf8)
    let event = try JSONDecoder().decode(BrowserSyncEvent.self, from: json)
    guard case .mobileTab(let data) = event.data else {
        Issue.record("The envelope decides the payload")
        return
    }
    let record = try #require(data.record)
    #expect(record.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(record.lastActivityAt == Date(timeIntervalSince1970: 1_800_000_300))
    #expect(record.title == nil)
    #expect(!event.belongsToSpaces)

    // Stored without an envelope, a mobile tab is still told apart from a Space tab.
    let untagged = try JSONDecoder().decode(BrowserSyncEventData.self, from: JSONEncoder().encode(event.data))
    #expect(untagged == event.data)
}

@Test func mobileTabReceiptsMustAnswerTheirOwnMutationWithMobileTabEvents() throws {
    let mutation = BrowserSyncMobileTabMutation(id: UUID().uuidString, operations: [.delete(id: "t1")])
    let event = MobileTabSyncServer.event(seq: 3, id: "t1", record: nil)
    let outcome = BrowserSyncBoostOutcome(operationIndex: 0, status: .applied, reason: nil)
    let valid = BrowserSyncMobileTabPushResponse(
        protocolVersion: 7, mutationID: mutation.id, cursor: 3, events: [event], outcomes: [outcome],
    )
    try valid.validate(for: mutation)
    let otherVersion = BrowserSyncMobileTabPushResponse(
        protocolVersion: 6, mutationID: mutation.id, cursor: 3, events: [event], outcomes: [outcome],
    )
    #expect(throws: BrowserRemoteSyncError.self) { try otherVersion.validate(for: mutation) }
    let otherEntity = BrowserSyncMobileTabPushResponse(
        protocolVersion: 7, mutationID: mutation.id, cursor: 3,
        events: [BoostSyncServer.event(seq: 3, id: "t1", record: nil)], outcomes: [outcome],
    )
    #expect(throws: BrowserRemoteSyncError.self) { try otherEntity.validate(for: mutation) }
}

// MARK: - Baseline and state

@Test func mobileTabDeletionsArePermanentAndQueuedActivityOnlyMovesForward() throws {
    var baseline = BrowserSyncMobileTabBaseline()
    let early = MobileTabSyncServer.record("https://a.example", activity: 100)
    try baseline.apply([
        MobileTabSyncServer.event(seq: 1, id: "a", record: early),
        MobileTabSyncServer.event(seq: 2, id: "b", record: MobileTabSyncServer.record("https://b.example")),
        MobileTabSyncServer.event(seq: 3, id: "b", record: nil),
    ])
    // An older event or a later upsert never brings a deletion back.
    try baseline.apply([MobileTabSyncServer.event(seq: 4, id: "b", record: early)])
    #expect(baseline.entries["b"]?.record == nil)
    #expect(baseline.tombstones.entries.keys.sorted() == ["b"])

    var stale = early
    stale.lastActivityAt = Date(timeIntervalSince1970: 50)
    let pending: [BrowserSyncQueuedMutation] = [
        .mobileTabs(.init(id: UUID().uuidString, operations: [
            .upsert(id: "a", record: stale),
            .upsert(id: "b", record: early),
            .upsert(id: "c", record: MobileTabSyncServer.record("https://c.example")),
        ])),
    ]
    let state = BrowserSyncMobileTabState(baseline: baseline, pending: pending)
    #expect(state.live["a"]?.lastActivityAt == Date(timeIntervalSince1970: 100))
    #expect(state.live["b"] == nil && state.deleted == ["b"])
    #expect(state.entries.map(\.id) == ["a", "c"])
    let local = [
        BrowserSyncMobileTabEntry(id: "a", record: early),
        BrowserSyncMobileTabEntry(id: "b", record: early),
        BrowserSyncMobileTabEntry(id: "d", record: MobileTabSyncServer.record("https://d.example")),
        BrowserSyncMobileTabEntry(id: "e", record: MobileTabSyncServer.record("about:blank")),
    ]
    #expect(state.adoptionOperations(for: local).map(\.entityID) == ["d"])
}

// MARK: - Store

@Test @MainActor func mobileTabWritesWaitForMobileTabSyncThenQueueAsVersion7Rows() throws {
    let device = try MobileTabSyncDevice(server: MobileTabSyncServer(), name: "a")
    defer { device.close() }
    let tab = BrowserSyncMobileTabEntry(id: "t1", record: MobileTabSyncServer.record("https://example.com"))
    #expect(try device.store.loadMobileTabs() == nil)
    #expect(try device.store.saveMobileTabs([tab], operations: [.upsert(id: "t1", record: tab.record)]) == false)
    #expect(try device.store.loadMobileTabs() == [tab], "The list saves without sync")
    #expect(try device.store.loadSyncMobileTabState() == nil)
    #expect(try device.store.pendingSyncQueue(for: device.owner).isEmpty)

    _ = try device.store.completeMobileTabSyncBootstrap(
        events: device.server.log, cursor: device.server.seq, for: device.owner, localBoosts: [],
        localMobileTabs: [tab],
    )
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 7)
    let queue = try device.store.pendingSyncQueue(for: device.owner)
    #expect(queue.map(\.protocolVersion) == [7])
    guard case .mobileTabs(let adoption) = queue.first else {
        Issue.record("Adoption queues a mobile tab row")
        return
    }
    #expect(adoption.operations == [.upsert(id: "t1", record: tab.record)])
    #expect(try device.store.loadSyncMobileTabState()?.entries == [tab], "Queued writes show before the server answers")

    let reopened = try BrowserSQLiteSessionStore(databaseURL: device.databaseURL)
    #expect(try reopened.pendingSyncQueue(for: device.owner) == queue)
    let revision = try reopened.syncMobileTabRevision(for: device.owner)
    _ = try reopened.acknowledgeSyncMutation(
        id: adoption.id, protocolVersion: 7,
        events: [MobileTabSyncServer.event(seq: device.server.seq + 1, id: "t1", record: tab.record)],
        for: device.owner,
    )
    #expect(try reopened.pendingSyncQueue(for: device.owner).isEmpty)
    #expect(try reopened.loadSyncMobileTabState()?.entries == [tab])
    #expect(try reopened.syncMobileTabRevision(for: device.owner) > revision)
    #expect(try reopened.loadSnapshotStrict() == device.snapshotBefore, "Mobile tabs never touch Spaces")

    // Signing out forgets the synced copy and keeps the device's own tabs.
    try reopened.forgetSyncAccount()
    #expect(try reopened.loadMobileTabs() == [tab])
}

@Test @MainActor func closingAMobileTabArchivesItAndRestoringConsumesTheEntry() throws {
    let device = try MobileTabSyncDevice(server: MobileTabSyncServer(), name: "a")
    defer { device.close() }
    let tab = BrowserSyncMobileTabEntry(id: "t1", record: MobileTabSyncServer.record("https://example.com"))
    try device.store.saveMobileTabs([tab])
    let entry = BrowserTabArchiveEntry(
        id: "archive-1", tab: .init(id: "t1", urlString: tab.record.urlString, placement: .temporary),
        archivedAt: 10, title: "Example",
    )
    try device.store.saveMobileTabs([], archiving: entry)
    #expect(try device.store.loadArchiveEntry(id: "archive-1") == entry)
    let restored = BrowserSyncMobileTabEntry(id: "t2", record: tab.record)
    try device.store.saveMobileTabs([restored], restoringArchiveID: "archive-1")
    #expect(try device.store.loadArchiveEntry(id: "archive-1") == nil)
    #expect(try device.store.loadMobileTabs() == [restored])
    #expect(throws: BrowserTabArchiveError.entryMissing) {
        try device.store.saveMobileTabs([restored], restoringArchiveID: "archive-1")
    }
}

// MARK: - Devices through the coordinator

@Test @MainActor func mobileTabsConvergeAcrossDevicesAndAComputerOnlyReadsThem() async throws {
    let server = MobileTabSyncServer()
    let phone = try MobileTabSyncDevice(server: server, name: "phone")
    let tablet = try MobileTabSyncDevice(server: server, name: "tablet")
    let mac = try MobileTabSyncDevice(server: server, name: "mac")
    defer {
        phone.close()
        tablet.close()
        mac.close()
    }
    // The phone had tabs before sync carried mobile tabs; its blank tab stays local.
    phone.applier.local = [
        .init(id: "a", record: MobileTabSyncServer.record("https://a.example", activity: 10)),
        .init(id: "blank", record: MobileTabSyncServer.record("about:blank")),
    ]
    await phone.start()
    #expect(server.calls(of: "phone").starts(with: ["pull:5:1", "pull:6:0", "pull:7:0"]))
    #expect(server.live.keys.sorted() == ["a"])

    await tablet.start()
    #expect(tablet.applier.state?.entries.map(\.id) == ["a"])

    let feed = BrowserMobileTabsFeed { try mac.store.loadSyncMobileTabState() }
    mac.applier.onChange = { feed.syncMobileTabsDidChange() }
    await mac.start()
    #expect(feed.tabs.map(\.record.urlString) == ["https://a.example"])

    // The tablet opens a newer tab; the computer lists it first.
    tablet.applier.queue([.upsert(id: "b", record: MobileTabSyncServer.record("https://b.example", activity: 20))])
    await tablet.service.waitForPendingOperations()
    await mac.pull()
    #expect(feed.tabs.map(\.id) == ["b", "a"])

    // The phone closes A while the tablet, offline, still writes it: the close wins.
    tablet.service.setRuntimeActive(false)
    phone.applier.queue([.delete(id: "a")])
    await phone.service.waitForPendingOperations()
    tablet.applier.queue([.upsert(id: "a", record: MobileTabSyncServer.record("https://a.example/late"))])
    tablet.service.setRuntimeActive(true)
    await tablet.service.waitForPendingOperations()
    #expect(server.outcomes.last == .init(operationIndex: 0, status: .rejected, reason: "deleted"))
    #expect(tablet.applier.state?.entries.map(\.id) == ["b"], "A late write does not bring the tab back")
    await mac.pull()
    #expect(feed.tabs.map(\.id) == ["b"])
    #expect(server.calls(of: "mac").allSatisfy { !$0.hasPrefix("push") }, "A computer never writes mobile tabs")
}

@Test @MainActor func aServerWithoutMobileTabsKeepsEverythingElseAndMobileTabsReturnWithIt() async throws {
    let server = MobileTabSyncServer()
    let device = try MobileTabSyncDevice(server: server, name: "a")
    defer { device.close() }
    device.applier.local = [.init(id: "a", record: MobileTabSyncServer.record("https://a.example"))]
    await device.start()
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 7)
    let cursor = try device.store.syncCursor(for: device.owner)

    server.capabilities = [2, 3, 4, 5, 6]
    await device.pull()
    #expect(server.calls(of: "a").suffix(2) == ["pull:7:\(cursor)", "pull:6:\(cursor)"])
    #expect(try device.store.syncPullProtocolVersion(for: device.owner) == 6)
    #expect(try device.store.loadSyncMobileTabState() == nil)

    server.capabilities = [2, 3, 4, 5, 6, 7]
    await device.pull()
    #expect(server.calls(of: "a").suffix(2) == ["pull:6:\(cursor)", "pull:7:0"])
    #expect(try device.store.loadSyncMobileTabState()?.entries.map(\.id) == ["a"])
    #expect(try device.store.pendingSyncQueue(for: device.owner).isEmpty, "A tab the server has is not sent again")
}

// MARK: - MobileTabSyncServer

/// Keeps mobile tabs the way the real server does: whole records with the
/// latest activity, permanent deletions, and only v7 readers see them.
@MainActor final class MobileTabSyncServer: BrowserSyncRemoteServing {
    // MARK: Internal

    let baseURL = URL(string: "https://mobile-tab-sync.example")!
    private(set) var log = [BrowserSyncEvent]()
    private(set) var seq = 0
    private(set) var live = [String: BrowserSyncMobileTabRecord]()
    private(set) var outcomes = [BrowserSyncBoostOutcome]()
    var capabilities = [2, 3, 4, 5, 6, 7]

    private var callLog = [(device: String, call: String)]()
    private var readers = [Int: Set<String>]()

    init() {
        append(.init(
            serverSeq: 0, deviceID: "remote", entityType: "space", entityID: "work", op: "upsert",
            data: .space(.init(
                id: "work", title: "Work", systemImageName: "globe", rank: 0,
                isPinnedSectionCollapsed: false, selectedTabID: nil,
            )), createdAt: "2026-11-27T00:00:00Z",
        ))
    }

    nonisolated static func record(_ url: String, activity: TimeInterval? = nil) -> BrowserSyncMobileTabRecord {
        .init(
            urlString: url, createdAt: Date(timeIntervalSince1970: 1000),
            lastActivityAt: activity.map { Date(timeIntervalSince1970: $0) },
        )
    }

    nonisolated static func event(seq: Int, id: String, record: BrowserSyncMobileTabRecord?) -> BrowserSyncEvent {
        let data: BrowserSyncEventData = record.map { .mobileTab(.init(id: id, record: $0)) } ?? .deleted(id: id)
        return .init(
            serverSeq: seq, deviceID: "remote", entityType: "mobileTab", entityID: id,
            op: record == nil ? "delete" : "upsert", data: data, createdAt: "2026-11-27T00:00:00Z",
        )
    }

    func calls(of device: String) -> [String] {
        callLog.filter { $0.device == device }.map(\.call)
    }

    func pull(cursor: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        try pull(cursor: cursor, protocolVersion: 2, authSession: authSession)
    }

    func pull(cursor: Int, protocolVersion: Int, authSession: BrowserAuthSession) throws -> BrowserSyncPullResponse {
        let device = authSession.deviceID
        callLog.append((device, "pull:\(protocolVersion):\(cursor)"))
        for version in [6, 7] {
            if protocolVersion >= version {
                guard cursor == 0 || readers[version, default: []].contains(device) else {
                    throw version == 6
                        ? BrowserRemoteSyncError.boostBootstrapRequired
                        : BrowserRemoteSyncError.mobileTabBootstrapRequired
                }
                readers[version, default: []].insert(device)
            } else {
                readers[version]?.remove(device)
            }
        }
        let events = log.filter {
            $0.serverSeq > cursor && (protocolVersion == 7 || $0.entityType != "mobileTab")
                && (protocolVersion >= 6 || $0.entityType != "boost")
        }
        return .init(
            cursor: events.last?.serverSeq ?? cursor, events: events,
            protocolVersion: protocolVersion, supportedPushVersions: capabilities,
        )
    }

    func push(mutation: BrowserSyncMutation, authSession _: BrowserAuthSession) throws -> BrowserSyncPushResponse {
        Issue.record("Mobile tab tests write no Space tabs: \(mutation.id)")
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }

    func push(
        mutation: BrowserSyncSemanticMutation, authSession _: BrowserAuthSession,
    ) throws -> BrowserSyncSemanticPushResponse {
        Issue.record("Mobile tab tests write no Space tabs: \(mutation.id)")
        throw BrowserRemoteSyncError.unsupportedSyncProtocol
    }

    func push(
        mutation: BrowserSyncMobileTabMutation, authSession: BrowserAuthSession,
    ) -> BrowserSyncMobileTabPushResponse {
        callLog.append((authSession.deviceID, "push:7"))
        var events = [BrowserSyncEvent]()
        var results = [BrowserSyncBoostOutcome]()
        for (index, operation) in mutation.operations.enumerated() {
            let id = operation.entityID
            let tombstone = log.last { $0.entityID == id && $0.op == "delete" }
            switch operation {
            case .upsert(_, var record):
                if let tombstone {
                    events.append(tombstone)
                    results.append(.init(operationIndex: index, status: .rejected, reason: "deleted"))
                } else {
                    record.lastActivityAt = BrowserSyncMobileTabRecord.latest(
                        record.lastActivityAt, live[id]?.lastActivityAt,
                    )
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
                    events.append(append(Self.event(seq: 0, id: id, record: nil)))
                    results.append(.init(operationIndex: index, status: .applied, reason: nil))
                }
            }
        }
        outcomes += results
        return .init(protocolVersion: 7, mutationID: mutation.id, cursor: seq, events: events, outcomes: results)
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

// MARK: - MobileTabSyncApplier

/// A device's own list stand-in: it uploads `local` at bootstrap and queues
/// writes through the store, as a phone's profile document does.
@MainActor final class MobileTabSyncApplier: BrowserSyncMobileTabApplying {
    let store: BrowserSQLiteSessionStore
    var local = [BrowserSyncMobileTabEntry]()
    var onChange: (() -> Void)?
    weak var service: BrowserSyncService?

    var state: BrowserSyncMobileTabState? { try? store.loadSyncMobileTabState() }

    init(store: BrowserSQLiteSessionStore) { self.store = store }

    func localSyncMobileTabs() -> [BrowserSyncMobileTabEntry] { local }

    func syncMobileTabsDidChange() { onChange?() }

    func queue(_ operations: [BrowserSyncMobileTabOperation]) {
        if (try? store.saveMobileTabs(local, operations: operations)) == true {
            service?.scheduleQueuedPush()
        }
    }
}

// MARK: - MobileTabSyncDevice

/// One device whose profile store is already at protocol 5.
@MainActor final class MobileTabSyncDevice: BrowserSyncAuthSessionReading {
    // MARK: Internal

    let server: MobileTabSyncServer
    let directory: URL
    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let owner: BrowserSyncOwner
    let snapshotBefore: BrowserTabSessionSnapshot?
    let session: BrowserAuthSession
    let applier: MobileTabSyncApplier
    private(set) var service: BrowserSyncService!

    init(server: MobileTabSyncServer, name: String) throws {
        self.server = server
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileTabSync-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.applier = MobileTabSyncApplier(store: store)
        self.session = .init(
            accessToken: "fixture-only", userID: "owner", userEmail: nil, deviceID: name, serverURL: server.baseURL,
        )
        self.owner = .init(baseURL: server.baseURL, userID: session.userID)
        try store.bindSyncOwner(owner)
        let history = server.log.filter(\.belongsToSpaces)
        let cursor = history.last?.serverSeq ?? 0
        _ = try store.completeFolderSyncBootstrap(events: history, cursor: cursor, for: owner)
        self.snapshotBefore = try store.completeExpirySyncBootstrap(events: history, cursor: cursor, for: owner)
    }

    func loadSession() -> BrowserAuthSession? { session }

    func start() async {
        let service = BrowserSyncService(
            localStore: store, remoteClient: server, authSessionStore: self,
            pushDebounce: .zero, pollInterval: nil, retryDelay: nil, waitForInputPause: {},
        )
        service.setMobileTabApplier(applier)
        applier.service = service
        self.service = service
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
}
