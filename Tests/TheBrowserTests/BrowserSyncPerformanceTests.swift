import CryptoKit
import Foundation
import GRDB
import Testing

// MARK: - BrowserSyncPerformanceTests

@Suite(.serialized, .enabled(
    if: ProcessInfo.processInfo.environment["THEBROWSER_SYNC_PERFORMANCE"] == "1",
    "Run ./script/test_sync_performance.sh for the bounded SQLite probe"
))
@MainActor struct BrowserSyncPerformanceTests {
    @Test func boundedSQLiteProbe() throws {
        let probe = try SyncPerformanceProbe()
        defer { probe.cleanup() }
        try probe.run()
    }
}

// MARK: - SyncPerformanceProbe

@MainActor private final class SyncPerformanceProbe {
    // MARK: Lifecycle

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Internal

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func run() throws {
        // Reach each size without a pending tail before spending time on large
        // replays. Every planned cell gets a record even when the budget expires.
        for pending in [0, 10, 100] {
            for tabs in [100, 1000, 5000] {
                for phase in SyncPerformancePhase.allCases where phase != .drain {
                    try measure(phase, tabs: tabs, pending: pending)
                }
            }
        }
        for pending in [10, 100] {
            try measure(.drain, tabs: 1000, pending: pending)
        }
        #expect(results.count == 29)
        #expect(results.contains { $0.status == "completed" })
        let report = SyncPerformanceReport(
            schemaVersion: 1,
            runID: ProcessInfo.processInfo.environment["THEBROWSER_SYNC_PERFORMANCE_RUN_ID"] ?? UUID().uuidString,
            budgetSeconds: budgetSeconds, elapsedSeconds: elapsed,
            plannedCases: 29, completedCases: results.filter { $0.status == "completed" }.count,
            allCasesAccountedFor: results.count == 29, results: results
        )
        let payload = try Self.encoder.encode(report)
        if let path = ProcessInfo.processInfo.environment["THEBROWSER_SYNC_PERFORMANCE_REPORT"] {
            try payload.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("SYNC_PERFORMANCE_REPORT \(String(decoding: payload, as: UTF8.self))")
    }

    // MARK: Private

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private let directory = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("sync-performance-\(UUID().uuidString)")
    private let clock = ContinuousClock()
    private let started = ContinuousClock.now
    private let budgetSeconds = 60.0
    private var fixtures = [String: SyncPerformanceFixture]()
    private var results = [SyncPerformanceResult]()

    private var elapsed: Double { seconds(started.duration(to: clock.now)) }
    private var exhausted: Bool { elapsed >= budgetSeconds }

    private static func rows(_ databaseURL: URL) throws -> [SyncPerformanceRow] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, payload, protocol_version FROM browser_sync_outbox ORDER BY position"
            )
            .map {
                SyncPerformanceRow(
                    position: $0["position"],
                    id: $0["mutation_id"],
                    payload: $0["payload"],
                    version: $0["protocol_version"]
                )
            }
        }
    }

    private static func fingerprint(_ rows: [SyncPerformanceRow]) -> String {
        var digest = SHA256()
        for row in rows.sorted(by: { $0.id < $1.id }) {
            digest.update(data: Data("\(row.id):\(row.version):\(row.payload.count):".utf8))
            digest.update(data: row.payload)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func measure(_ phase: SyncPerformancePhase, tabs: Int, pending: Int) throws {
        var result = SyncPerformanceResult(phase: phase.rawValue, tabs: tabs, pending: pending)
        if phase == .firstAck, pending == 0 {
            result.status = "not_applicable"
            try finish(result)
            return
        }
        guard !exhausted else { try finish(result)
            return
        }
        let fixture = try fixture(tabs: tabs, pending: pending)
        result.queueFingerprint = Self.fingerprint(fixture.rows)
        for sample in 0..<4 {
            guard !exhausted else { break }
            // Initialization, cloning, queue fingerprints and validation are
            // outside the timed interval. Each sample starts from identical bytes.
            let databaseURL = directory.appendingPathComponent("sample-\(UUID().uuidString).sqlite")
            try FileManager.default.copyItem(at: fixture.databaseURL, to: databaseURL)
            let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            guard !exhausted else { break }
            let start = clock.now
            var acknowledged = 0
            switch phase {
            case .capture:
                store.saveSnapshot(fixture.captureSnapshot, syncMove: .init(tabIDs: ["tab-0"]))
            case .emptyPull:
                _ = try store.applyRemoteSyncEvents([], cursor: fixture.cursor, for: fixture.owner)
            case .firstAck:
                _ = try store.acknowledgeSyncMutation(
                    id: fixture.rows[0].id, protocolVersion: 3, events: fixture.receipts[0], for: fixture.owner
                )
                acknowledged = 1
            case .drain:
                for (index, row) in fixture.rows.enumerated() {
                    // The soft cap cannot interrupt a synchronous SQLite operation,
                    // but it can stop a long drain safely between durable ACKs.
                    guard !exhausted else { break }
                    _ = try store.acknowledgeSyncMutation(
                        id: row.id, protocolVersion: 3, events: fixture.receipts[index], for: fixture.owner
                    )
                    acknowledged += 1
                }
            }
            let milliseconds = seconds(start.duration(to: clock.now)) * 1000
            try validate(store, databaseURL: databaseURL, fixture: fixture, phase: phase, acknowledged: acknowledged)
            if phase == .drain, acknowledged != fixture.rows.count {
                result.partialDrainAcknowledged = acknowledged
                result.partialDrainMilliseconds = milliseconds
                break
            }
            if sample == 0 {
                result.warmupMilliseconds = milliseconds
            } else {
                result.samplesMilliseconds.append(milliseconds)
            }
            // Avoid starting a sample that the previous one shows cannot fit.
            if elapsed + milliseconds / 1000 > budgetSeconds {
                break
            }
        }
        if result.samplesMilliseconds.count == 3 {
            result.status = "completed"
            result.medianMilliseconds = result.samplesMilliseconds.sorted()[1]
            result.maximumMilliseconds = result.samplesMilliseconds.max()
        }
        try finish(result)
    }

    private func validate(
        _ store: BrowserSQLiteSessionStore, databaseURL: URL, fixture: SyncPerformanceFixture,
        phase: SyncPerformancePhase, acknowledged: Int
    ) throws {
        // Full equality covers relative order, URL/title, timestamps, placement,
        // Space identity, and each Space's selected tab index.
        #expect(store.loadSnapshot() == (phase == .capture ? fixture.captureSnapshot : fixture.snapshot))
        #expect(try store.syncCursor(for: fixture.owner) == fixture.cursor)
        let rows = try Self.rows(databaseURL)
        if phase == .capture {
            #expect(rows.count == fixture.rows.count + 1)
            #expect(Array(rows.prefix(fixture.rows.count)) == fixture.rows)
            #expect(Self.fingerprint(Array(rows.prefix(fixture.rows.count))) == Self.fingerprint(fixture.rows))
            let last = try #require(rows.last)
            let mutation = try JSONDecoder().decode(BrowserSyncSemanticMutation.self, from: last.payload)
            #expect(mutation.operations == [.moveTabs(
                ids: ["tab-0"], destination: .init(spaceID: "space-0", placement: .temporary),
                beforeID: "tab-2", afterID: "tab-1"
            )])
        } else {
            let expected = Array(fixture.rows.dropFirst(acknowledged))
            #expect(rows == expected)
            #expect(Self.fingerprint(rows) == Self.fingerprint(expected))
        }
    }

    private func finish(_ result: SyncPerformanceResult) throws {
        results.append(result)
        try print("SYNC_PERFORMANCE \(String(decoding: Self.encoder.encode(result), as: UTF8.self))")
    }

    private func fixture(tabs: Int, pending: Int) throws -> SyncPerformanceFixture {
        let key = "\(tabs)-\(pending)"
        if let existing = fixtures[key] {
            return existing
        }
        let databaseURL = directory.appendingPathComponent("fixture-\(key).sqlite")
        let fixture = try SyncPerformanceFixture(databaseURL: databaseURL, tabs: tabs, pending: pending)
        // Build the schema once. All immutable rows are installed together instead
        // of capturing 100 full local snapshots just to prepare the benchmark.
        let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try store.bindSyncOwner(fixture.owner)
        try store.enableSemanticSyncMutations(for: fixture.owner)
        store.saveRemoteProjectionSnapshot(fixture.snapshot)
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { db in
            try db.execute(
                sql: "UPDATE browser_sync_baseline SET payload = ? WHERE id = 1",
                arguments: [JSONEncoder().encode(fixture.baseline)]
            )
            try db.execute(sql: "UPDATE browser_sync_state SET cursor = ? WHERE id = 1", arguments: [fixture.cursor])
            for row in fixture.rows {
                try db.execute(
                    sql: "INSERT INTO browser_sync_outbox(position, mutation_id, payload, protocol_version) VALUES (?, ?, ?, 3)",
                    arguments: [row.position, row.id, row.payload]
                )
            }
        }
        // Independently verify the synthetic queue's optimistic snapshot through
        // the production reducer, outside measurement and within the soft budget.
        #expect(BrowserSyncOutboxProjection.snapshot(
            baseline: fixture.baseline, pending: fixture.queue, local: fixture.snapshot
        ) == fixture.snapshot)
        try database.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        fixtures[key] = fixture
        return fixture
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

// MARK: - SyncPerformanceFixture

private struct SyncPerformanceFixture {
    // MARK: Lifecycle

    init(databaseURL: URL, tabs count: Int, pending: Int) throws {
        self.databaseURL = databaseURL
        self.cursor = count + 10
        let spaces = (0..<10).map {
            BrowserSpaceSessionSnapshot(
                id: "space-\($0)",
                title: "Space \($0)",
                systemImageName: "circle",
                selectedTabIndex: 2
            )
        }
        let tabs = (0..<count).map { index in
            BrowserTabSessionSnapshotTab(
                id: "tab-\(index)", urlString: "https://example.test/\(index)", userTitleOverride: "Title \(index)",
                spaceID: "space-\(index / (count / 10))", lastActivityTimestamp: 1_780_000_000 + Double(index)
            )
        }
        self.snapshot = BrowserTabSessionSnapshot(spaces: spaces, tabs: tabs)
        var moved = tabs
        moved.swapAt(0, 1)
        self.captureSnapshot = BrowserTabSessionSnapshot(spaces: spaces, tabs: moved)
        var baseline = BrowserSyncOutboxBaseline()
        let formatter = ISO8601DateFormatter()
        var eventsByID = [String: BrowserSyncEventTabData]()
        for (index, space) in spaces.enumerated() {
            let change = BrowserSyncChange(entityType: .space, entityID: space.id, op: .upsert, spaceData: .init(
                title: space.title, systemImageName: space.systemImageName, rank: Double(index),
                isPinnedSectionCollapsed: false, selectedTabID: nil
            ), tabData: nil)
            baseline.entities["space:\(space.id)"] = .init(serverSeq: index + 1, change: change)
        }
        for (index, tab) in tabs.enumerated() {
            let id = "tab-\(index)"
            let rank = Double(index % (count / 10))
            let activity = formatter.string(from: Date(timeIntervalSince1970: tab.lastActivityTimestamp!))
            let data = BrowserSyncTabPayload(
                spaceID: tab.spaceID!, placement: .temporary, rank: rank, urlString: tab.urlString,
                pinnedURLString: nil, title: "Page \(index)", userTitleOverride: tab.userTitleOverride,
                faviconURLString: "https://example.test/icon.png", lastActivityAt: activity
            )
            let change = BrowserSyncChange(entityType: .tab, entityID: id, op: .upsert, spaceData: nil, tabData: data)
            baseline.entities["tab:\(id)"] = .init(serverSeq: index + 11, change: change)
            if index < 2 {
                eventsByID[id] = .init(
                    id: id, spaceID: data.spaceID, placement: .temporary, rank: rank, urlString: data.urlString,
                    pinnedURLString: nil, title: data.title, userTitleOverride: data.userTitleOverride,
                    faviconURLString: data.faviconURLString, lastActivityAt: activity
                )
            }
        }
        self.baseline = baseline
        var queue = [BrowserSyncQueuedMutation](), rows = [SyncPerformanceRow](), receipts = [[BrowserSyncEvent]]()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for index in 0..<pending {
            let after = index.isMultiple(of: 2)
            let mutation = BrowserSyncSemanticMutation(
                id: String(format: "00000000-0000-4000-8000-%012d", index + 1),
                operations: [.moveTabs(
                    ids: ["tab-0"], destination: .init(spaceID: "space-0", placement: .temporary),
                    beforeID: after ? "tab-2" : "tab-1", afterID: after ? "tab-1" : nil
                )]
            )
            queue.append(.semantic(mutation))
            try rows.append(.init(
                position: index + 1,
                id: mutation.id,
                payload: encoder.encode(mutation),
                version: 3
            ))
            receipts.append((0..<2).map { tabIndex in
                let id = "tab-\(tabIndex)", data = eventsByID[id]!
                return BrowserSyncEvent(
                    serverSeq: count + 11 + index * 2 + tabIndex, deviceID: nil, entityType: "tab", entityID: id,
                    op: "upsert",
                    data: .tab(.init(
                        id: id, spaceID: data.spaceID, placement: data.placement,
                        rank: Double(after ? 1 - tabIndex : tabIndex), urlString: data.urlString,
                        pinnedURLString: nil, title: data.title, userTitleOverride: data.userTitleOverride,
                        faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt
                    )), createdAt: "2026-10-03T00:00:00Z"
                )
            })
        }
        self.queue = queue
        self.rows = rows
        self.receipts = receipts
    }

    // MARK: Internal

    let databaseURL: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync-performance.example")!, userID: "probe")
    let snapshot: BrowserTabSessionSnapshot
    let captureSnapshot: BrowserTabSessionSnapshot
    let baseline: BrowserSyncOutboxBaseline
    let queue: [BrowserSyncQueuedMutation]
    let rows: [SyncPerformanceRow]
    let receipts: [[BrowserSyncEvent]]
    let cursor: Int
}

// MARK: - SyncPerformancePhase

private enum SyncPerformancePhase: String, CaseIterable {
    case capture
    case emptyPull = "empty_pull"
    case firstAck = "first_ack"
    case drain
}

// MARK: - SyncPerformanceRow

private struct SyncPerformanceRow: Equatable {
    let position: Int
    let id: String
    let payload: Data
    let version: Int
}

// MARK: - SyncPerformanceResult

private struct SyncPerformanceResult: Encodable {
    let phase: String
    let tabs: Int
    let pending: Int
    var status = "soft_budget"
    var samplesMilliseconds = [Double]()
    var warmupMilliseconds: Double?
    var medianMilliseconds: Double?
    var maximumMilliseconds: Double?
    var partialDrainAcknowledged: Int?
    var partialDrainMilliseconds: Double?
    var queueFingerprint: String?
}

// MARK: - SyncPerformanceReport

private struct SyncPerformanceReport: Encodable {
    let schemaVersion: Int
    let runID: String
    let budgetSeconds: Double
    let elapsedSeconds: Double
    let plannedCases: Int
    let completedCases: Int
    let allCasesAccountedFor: Bool
    let results: [SyncPerformanceResult]
}
