// BrowserSessionWriteTests.swift

import Foundation
import GRDB
import Testing

@Test func sessionBatchSecondWriteFailureRollsBackSnapshotTombstoneAndImmutableOutbox() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let original = batchSnapshot(["a", "b", "c"])
    let store = try harness.seed(original)
    let rows = try harness.rows()
    let baseline = try harness.baseline()
    let writes = [
        BrowserSessionWrite(snapshot: batchSnapshot(["b", "a"]), origin: .local(syncMove: .init(tabIDs: ["a"]))),
        BrowserSessionWrite(snapshot: batchSnapshot(["b", "a"], title: "Failure"), origin: .local(syncMove: nil)),
    ]
    try harness.database().write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_second_session_write BEFORE INSERT ON browser_spaces
        WHEN NEW.title = 'Failure' BEGIN SELECT RAISE(ABORT, 'injected second write failure'); END
        """)
    }
    #expect(throws: DatabaseError.self) { try store.writeSessionBatch(writes) }
    #expect(store.loadSnapshot() == original)
    #expect(try harness.rows() == rows)
    #expect(try harness.baseline() == baseline)
    #expect(try store.syncCursor(for: harness.owner) == 37)

    try harness.database().write { db in try db.execute(sql: "DROP TRIGGER fail_second_session_write") }
    try store.writeSessionBatch(writes)
    #expect(store.loadSnapshot() == writes.last?.snapshot)
    #expect(try Array(harness.rows().prefix(rows.count)) == rows)
    let queue = try store.pendingSyncQueue(for: harness.owner)
    #expect(queue.map(\.protocolVersion) == [2, 3, 3])
    guard case .semantic(let first) = queue[1], case .semantic(let second) = queue[2] else {
        Issue.record("Expected ordered semantic writes after the legacy seed")
        return
    }
    #expect(first.operations == [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "space", placement: .temporary), afterID: "b"),
        .deleteTab(id: "c"),
    ])
    #expect(second.operations == [.patchSpace(id: "space", fields: .init(title: "Failure"))])
    let reopened = try harness.store()
    #expect(try reopened.pendingSyncQueue(for: harness.owner) == queue)
    #expect(reopened.loadSnapshot() == writes.last?.snapshot)
}

@Test func sessionBatchRetainsTwoOpposingMoveIntentsInsteadOfCollapsingFinalSnapshot() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let original = batchSnapshot(["a", "b", "c"])
    let store = try harness.seed(original)
    let rows = try harness.rows()
    try store.writeSessionBatch([
        .init(snapshot: batchSnapshot(["b", "a", "c"]), origin: .local(syncMove: .init(tabIDs: ["a"]))),
        .init(snapshot: original, origin: .local(syncMove: .init(tabIDs: ["a"]))),
    ])
    #expect(store.loadSnapshot() == original)
    let queue = try store.pendingSyncQueue(for: harness.owner)
    #expect(queue.count == 3)
    guard case .semantic(let first) = queue[1], case .semantic(let second) = queue[2] else {
        Issue.record("Expected two durable semantic actions")
        return
    }
    #expect(first.id != second.id)
    #expect(first.operations == [.moveTabs(
        ids: ["a"], destination: .init(spaceID: "space", placement: .temporary), beforeID: "c", afterID: "b",
    )])
    #expect(second.operations == [.moveTabs(
        ids: ["a"], destination: .init(spaceID: "space", placement: .temporary), beforeID: "b",
    )])
    #expect(try Array(harness.rows().prefix(rows.count)) == rows)
}

@Test func sessionBatchRemoteProjectionDoesNotEchoAndFollowingLocalDiffUsesIt() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let store = try harness.seed(batchSnapshot(["a", "b", "c"]))
    let rows = try harness.rows()
    let baseline = try harness.baseline()
    let remote = batchSnapshot(["c", "a", "b"], title: "Remote")
    try store.writeSessionBatch([.init(snapshot: remote, origin: .remoteProjection)])
    #expect(try harness.rows() == rows)
    #expect(try harness.baseline() == baseline)
    #expect(store.loadSnapshot() == remote)
    let local = batchSnapshot(["c", "b", "a"], title: "Remote")
    try store.writeSessionBatch([
        .init(snapshot: remote, origin: .remoteProjection),
        .init(snapshot: local, origin: .local(syncMove: .init(tabIDs: ["a"]))),
        .init(snapshot: local, origin: .remoteProjection),
    ])
    let queue = try store.pendingSyncQueue(for: harness.owner)
    #expect(queue.count == 2)
    guard case .semantic(let mutation) = queue[1] else { Issue.record("Expected one local mutation")
        return
    }
    #expect(mutation.operations == [.moveTabs(
        ids: ["a"], destination: .init(spaceID: "space", placement: .temporary), afterID: "b",
    )])
    #expect(try Array(harness.rows().prefix(rows.count)) == rows)
    #expect(store.loadSnapshot() == local)
}

@Test func sessionBatchOversizeSecondActionRollsBackEarlierMove() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let original = batchSnapshot(["a", "b"])
    let store = try harness.seed(original)
    let rows = try harness.rows()
    let baseline = try harness.baseline()
    let moved = batchSnapshot(["b", "a"])
    let oversized = batchSnapshot(["b", "a"], title: String(repeating: "x", count: 8 * 1024 * 1024))
    #expect(throws: BrowserSyncQueueError.mutationTooLarge) {
        try store.writeSessionBatch([
            .init(snapshot: moved, origin: .local(syncMove: .init(tabIDs: ["a"]))),
            .init(snapshot: oversized, origin: .local(syncMove: nil)),
        ])
    }
    #expect(store.loadSnapshot() == original)
    #expect(try harness.rows() == rows)
    #expect(try harness.baseline() == baseline)
}

@Test func sessionBatchDuplicateMoveIDsThrowAndEmptyBatchHasNoWrites() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let original = batchSnapshot(["a", "b"])
    let store = try harness.seed(original)
    let rows = try harness.rows()
    let baseline = try harness.baseline()
    #expect(throws: BrowserSessionWriteError.duplicateMoveIDs) {
        try store.writeSessionBatch([
            .init(snapshot: batchSnapshot(["b", "a"]), origin: .local(syncMove: .init(tabIDs: ["a"]))),
            .init(snapshot: original, origin: .local(syncMove: .init(tabIDs: ["a", "a"]))),
        ])
    }
    try store.writeSessionBatch([])
    #expect(store.loadSnapshot() == original)
    #expect(try harness.rows() == rows)
    #expect(try harness.baseline() == baseline)
}

@Test func sessionBatchJSONValidatesIntermediateActionsBeforeReplacingFile() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)
    let original = batchSnapshot(["a", "b"])
    try store.writeSessionBatch([.init(snapshot: original, origin: .local(syncMove: nil))])
    let originalBytes = try Data(contentsOf: harness.snapshotURL)
    let invalid = BrowserTabSessionSnapshot(tabs: [
        BrowserTabSessionSnapshotTab(id: "bad", urlString: "https://bad.example", lastActivityTimestamp: .nan),
    ])
    #expect(throws: EncodingError.self) {
        try store.writeSessionBatch([
            .init(snapshot: batchSnapshot(["b", "a"]), origin: .local(syncMove: nil)),
            .init(snapshot: invalid, origin: .remoteProjection),
            .init(snapshot: batchSnapshot(["c"]), origin: .local(syncMove: nil)),
        ])
    }
    #expect(try Data(contentsOf: harness.snapshotURL) == originalBytes)
    #expect(store.loadSnapshot() == original)
    #expect(throws: BrowserSessionWriteError.duplicateMoveIDs) {
        try store.writeSessionBatch([.init(snapshot: original, origin: .local(syncMove: .init(tabIDs: ["a", "a"])))])
    }
    #expect(try Data(contentsOf: harness.snapshotURL) == originalBytes)
    let final = batchSnapshot(["b", "a"])
    try store.writeSessionBatch([
        .init(snapshot: batchSnapshot(["new"]), origin: .local(syncMove: nil)),
        .init(snapshot: final, origin: .remoteProjection),
    ])
    #expect(store.loadSnapshot() == final)
}

@Test func sessionBatchJSONPropagatesFilesystemAndMissingURLFailures() throws {
    let harness = try SessionWriteHarness()
    defer { harness.cleanup() }
    let write = BrowserSessionWrite(snapshot: batchSnapshot(["a"]), origin: .local(syncMove: nil))
    let missing = BrowserTabSessionSnapshotStore(snapshotURL: nil)
    #expect(throws: BrowserSessionWriteError.missingSnapshotURL) { try missing.writeSessionBatch([write]) }
    try missing.writeSessionBatch([])

    // A file where a parent directory is required produces a real filesystem
    // failure without relying on permissions or a mocked Foundation writer.
    let blocked = harness.directory.appendingPathComponent("not-a-directory")
    let marker = Data("preserve existing file".utf8)
    try marker.write(to: blocked)
    let store = BrowserTabSessionSnapshotStore(snapshotURL: blocked.appendingPathComponent("tabs.json"))
    #expect(throws: (any Error).self) { try store.writeSessionBatch([write]) }
    #expect(try Data(contentsOf: blocked) == marker)
}

@Test func sessionBatchEphemeralIsAnExplicitSuccessfulNoOp() throws {
    let store: any BrowserTabSessionSnapshotStoring = BrowserEphemeralSessionStore()
    try store.writeSessionBatch([
        .init(snapshot: batchSnapshot(["private"]), origin: .local(syncMove: nil)),
        .init(snapshot: batchSnapshot(["remote"]), origin: .remoteProjection),
    ])
    #expect(store.loadSnapshot() == nil)
}

// MARK: - SessionWriteHarness

private struct SessionWriteHarness {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-write-\(UUID().uuidString)")
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://session-write.example")!, userID: "owner")

    var databaseURL: URL { directory.appendingPathComponent("session.sqlite") }
    var snapshotURL: URL { directory.appendingPathComponent("tabs.json") }

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    func store() throws -> BrowserSQLiteSessionStore { try BrowserSQLiteSessionStore(databaseURL: databaseURL) }
    func database() throws -> DatabaseQueue { try DatabaseQueue(path: databaseURL.path) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func seed(_ snapshot: BrowserTabSessionSnapshot) throws -> BrowserSQLiteSessionStore {
        let store = try store()
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        try store.bindSyncOwner(owner)
        try store.enableSemanticSyncMutations(for: owner)
        try store.saveSyncCursor(37, for: owner)
        return store
    }

    func rows() throws -> [SessionWriteRow] {
        try database().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT position, mutation_id, protocol_version, payload FROM browser_sync_outbox ORDER BY position",
            )
            .map {
                SessionWriteRow(
                    position: $0["position"],
                    id: $0["mutation_id"],
                    version: $0["protocol_version"],
                    payload: $0["payload"],
                )
            }
        }
    }

    func baseline() throws -> Data? {
        try database()
            .read { db in try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1") }
    }
}

// MARK: - SessionWriteRow

private struct SessionWriteRow: Equatable {
    let position: Int
    let id: String
    let version: Int
    let payload: Data
}

private func batchSnapshot(_ ids: [String], title: String = "Work") -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(
        spaces: [.init(id: "space", title: title, systemImageName: "briefcase")],
        tabs: ids.map { .init(id: $0, urlString: "https://\($0).example", spaceID: "space") },
    )
}
