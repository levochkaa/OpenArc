import Foundation
import GRDB
import Testing

// MARK: - BrowserMobileProfileDocumentTests

@Suite(.serialized)
@MainActor struct BrowserMobileProfileDocumentTests {
    @Test func twoSubscribersEditLatestCompleteDocumentWithoutDeletingEachOthersTabs() throws {
        let f = try MobileDocumentFixture()
        defer { f.cleanup() }
        var first = [BrowserTabSessionSnapshot](), second = [BrowserTabSessionSnapshot]()
        let one = f.document.observe { first.append($0) }
        let two = f.document.observe { second.append($0) }
        let staleSecondScene = try #require(second.last)
        let created = try #require(f.document.createTab(urlString: "https://example.com/new", spaceID: "source"))
        #expect(f.document.renameTab(id: "a", title: "From second scene"))
        #expect(f.document.snapshot.tabs.contains { $0.id == created })
        #expect(!staleSecondScene.tabs.contains { $0.id == created })
        #expect(first.last == second.last && first.last == f.document.snapshot)
        #expect(try f.store.loadSnapshotStrict() == f.document.snapshot)
        #expect(f.document.updateURL(tabID: created, urlString: "https://example.com/latest"))
        let queue = try f.store.pendingSyncQueue(for: f.owner)
        #expect(queue.count == 3 && queue.allSatisfy { $0.protocolVersion == 4 })
        #expect(try !f.operations().contains {
            if case .deleteTab = $0 {
                true
            } else {
                false
            }
        })
        f.document.removeObserver(two)
        let count = second.count
        #expect(f.document.renameSpace(id: "source", title: "Shared title"))
        #expect(second.count == count && first.last == f.document.snapshot)
        f.document.removeObserver(one)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        let restored = try BrowserMobileProfileDocument(
            store: reopened,
            loadSnapshot: { try reopened.loadSnapshotStrict() }
        )
        #expect(restored.snapshot == f.document.snapshot)
        #expect(try reopened.pendingSyncQueue(for: f.owner).prefix(queue.count) == queue[...])
    }

    @Test func folderActionsUseRootIntentAndDeleteOnlyCurrentMembership() throws {
        let f = try MobileDocumentFixture()
        defer { f.cleanup() }
        #expect(f.document.setPlacement(tabID: "a", placement: .spacePinned))
        let folder = try #require(f.document.createFolder(spaceID: "source", title: "Folder"))
        let nested = try #require(f.document.createFolder(spaceID: "source", parentFolderID: folder, title: "Nested"))
        #expect(f.document.setPlacement(tabID: "a", placement: .spacePinned, pinnedFolderID: nested))
        #expect(f.document.setPlacement(tabID: "b", placement: .spacePinned, pinnedFolderID: folder))
        let before = try f.store.pendingSyncQueue(for: f.owner).count
        #expect(f.document.move(items: [.init(entityType: .folder, entityID: folder)], destination: .tabs(
            spaceID: "target", placement: .spacePinned, pinnedFolderID: nil
        )))
        let moveRow = try #require(f.store.pendingSyncQueue(for: f.owner).last)
        guard case .folders(let moved) = moveRow else { Issue.record("Expected v4 row")
            return
        }
        #expect(moved.operations == [.move(
            items: [.init(entityType: .folder, entityID: folder)],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil)
        )])
        #expect(try f.store.pendingSyncQueue(for: f.owner).count == before + 1)
        #expect(f.document.snapshot.tabs.first { $0.id == "a" }?.spaceID == "target")
        #expect(f.document.snapshot.pinnedTabFolders?.first { $0.id == nested }?.spaceID == "target")
        #expect(!f.document.move(items: [.init(entityType: .folder, entityID: folder)], destination: .tabs(
            spaceID: "target", placement: .spacePinned, pinnedFolderID: nested
        )))
        #expect(f.document.setPlacement(tabID: "a", placement: .spacePinned, spaceID: "source"))
        #expect(f.document.delete(entity: .init(entityType: .folder, entityID: folder)))
        #expect(f.document.snapshot.tabs.contains { $0.id == "a" && $0.spaceID == "source" })
        #expect(!f.document.snapshot.tabs.contains { $0.id == "b" })
        #expect(f.document.snapshot.tabs.contains { $0.id == "favorite" })
        #expect(f.document.snapshot.pinnedTabFolders?.isEmpty != false)
        guard case .folders(let deletion) = try #require(f.store.pendingSyncQueue(for: f.owner).last) else {
            Issue.record("Expected v4 deletion")
            return
        }
        #expect(deletion.operations == [.deleteFolder(id: folder)])
    }

    @Test func failedWritesRetainMoveThenRenameAndBlockRemoteUntilRetry() throws {
        let f = try MobileDocumentFixture()
        defer { f.cleanup() }
        let db = try DatabaseQueue(path: f.databaseURL.path)
        try db
            .write { db in
                try db
                    .execute(
                        sql: "CREATE TRIGGER fail_mobile_write BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT, 'injected'); END"
                    )
            }
        let durable = try f.store.loadSnapshotStrict()
        #expect(f.document.setPlacement(tabID: "a", placement: .spacePinned, spaceID: "target"))
        #expect(f.document.renameTab(id: "a", title: "Offline rename"))
        #expect(f.document.hasUncommittedWrites && f.document.persistenceFailure?.isRetryable == true)
        #expect(f.coordinator.blocks.last == true)
        #expect(try f.store.loadSnapshotStrict() == durable)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        let admitted = f.document.snapshot
        f.document.applyRemoteSyncSnapshot(.init(tabs: []))
        #expect(f.document.snapshot == admitted)
        let attempts = f.recording.attempts
        #expect(attempts.last?.count == 2)
        guard case .local(let move?) = try #require(attempts.last?.first).origin else {
            Issue.record("Failed move must retain its typed origin")
            return
        }
        #expect(move.items == [.init(entityType: .tab, entityID: "a")])
        try db.write { db in try db.execute(sql: "DROP TRIGGER fail_mobile_write") }
        #expect(f.document.retryPersistence())
        #expect(!f.document.hasUncommittedWrites && f.document.persistenceFailure == nil)
        #expect(f.recording.attempts.last == attempts.last)
        #expect(try f.store.loadSnapshotStrict() == admitted)
        #expect(f.coordinator.blocks.last == false && f.coordinator.pulls == 1)
        let rows = try f.store.pendingSyncQueue(for: f.owner)
        #expect(rows.count == 2)
        #expect(f.document.snapshot.tabs.first { $0.id == "a" }?.spaceID == "target")
        #expect(f.document.snapshot.tabs.first { $0.id == "a" }?.userTitleOverride == "Offline rename")
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.pendingSyncQueue(for: f.owner) == rows)
    }

    @Test func remoteEmptyDoesNotCreateBlankAndUnsupportedAddressesRemainDurable() throws {
        let f = try MobileDocumentFixture()
        defer { f.cleanup() }
        var notifications = 0
        _ = f.document.observe { _ in notifications += 1 }
        let incoming = BrowserTabSessionSnapshot(spaces: f.document.snapshot.spaces, tabs: [
            .init(
                id: "desktop",
                urlString: "openarc://settings",
                placement: .spacePinned,
                spaceID: "source",
                pinnedSiblingRank: 0
            ),
            .init(id: "favorite", urlString: "https://example.com/favorite", placement: .app, spaceID: "source"),
        ])
        let projected = try f.remoteReplace(incoming)
        let attempts = f.recording.attempts.count
        f.document.applyRemoteSyncSnapshot(projected)
        #expect(f.document.snapshot.tabs.first { $0.id == "desktop" }?.urlString == "openarc://settings")
        #expect(f.recording.attempts.count == attempts && f.coordinator.pushes.isEmpty)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        #expect(f.document.renameTab(id: "desktop", title: "Preserved internal page"))
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "desktop" }?.urlString == "openarc://settings")
        // Complete the local row before delivering a later authoritative empty tree.
        for row in try f.store.pendingSyncQueue(for: f.owner) {
            _ = try f.store.acknowledgeSyncMutation(id: row.id, protocolVersion: 4, events: [], for: f.owner)
        }
        let empty = try f.remoteReplace(.init(tabs: []))
        let pushes = f.coordinator.pushes.count
        f.document.applyRemoteSyncSnapshot(empty)
        #expect(f.document.snapshot.tabs.isEmpty && f.document.snapshot.spaces?.isEmpty != false)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        #expect(f.coordinator.pushes.count == pushes && notifications >= 3)
        #expect(!f.document.updateURL(tabID: "desktop", urlString: "https://example.com/stale"))
        #expect(!f.document.removeTab(id: "desktop"))
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
    }

    @Test func boundedFailureBufferRejectsTailWithoutReplacingAdmittedState() throws {
        let f = try MobileDocumentFixture(maximumBufferedWrites: 2)
        defer { f.cleanup() }
        f.recording.failure = MobileDocumentFailure.injected
        #expect(f.document.renameTab(id: "a", title: "One"))
        #expect(f.document.renameTab(id: "b", title: "Two"))
        let admitted = f.document.snapshot
        #expect(!f.document.renameTab(id: "a", title: "Uncaptured tail"))
        #expect(f.document.snapshot == admitted)
        #expect(f.document.persistenceFailure?.reason == .bufferLimitExceeded)
        #expect(f.document.hasUncommittedWrites && !f.document.canEdit)
        f.recording.failure = nil
        #expect(!f.document.retryPersistence())
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        f.document.applyRemoteSyncSnapshot(.init(tabs: []))
        #expect(f.document.snapshot == admitted)
    }

    @Test func throwingLoadAndInvalidTreeCannotBecomeAnEditableEmptyProfile() throws {
        let f = try MobileDocumentFixture()
        defer { f.cleanup() }
        let attempts = f.recording.attempts.count
        #expect(throws: MobileDocumentFailure.injected) {
            try BrowserMobileProfileDocument(store: f.recording, loadSnapshot: { throw MobileDocumentFailure.injected })
        }
        #expect(throws: BrowserMobileProfileDocumentError.invalidSnapshot) {
            try BrowserMobileProfileDocument(store: f.recording, initialSnapshot: .init(tabs: [
                .init(id: "orphan", urlString: "https://example.com", spaceID: "missing"),
            ]))
        }
        #expect(f.recording.attempts.count == attempts)
        let empty = try BrowserMobileProfileDocument(store: f.recording, initialSnapshot: nil)
        #expect(empty.snapshot.tabs.isEmpty && empty.snapshot.spaces == nil)
        #expect(f.recording.attempts.count == attempts)
    }
}

// MARK: - MobileDocumentFixture

@MainActor private final class MobileDocumentFixture {
    // MARK: Lifecycle

    init(maximumBufferedWrites: Int = 32) throws {
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        try store.bindSyncOwner(owner)
        let seed = BrowserTabSessionSnapshot(spaces: [
            .init(id: "source", title: "Source", systemImageName: "globe"),
            .init(id: "target", title: "Target", systemImageName: "star"),
        ], tabs: [
            .init(id: "a", urlString: "https://example.com/a", spaceID: "source", lastActivityTimestamp: 1_800_000_000),
            .init(id: "b", urlString: "https://example.com/b", spaceID: "source", lastActivityTimestamp: 1_800_000_000),
            .init(
                id: "favorite",
                urlString: "https://example.com/favorite",
                placement: .app,
                spaceID: "source",
                lastActivityTimestamp: 1_800_000_000
            ),
        ])
        let events = try Self.events(BrowserSyncFolderProjection.canonicalChanges(seed), startingAt: 1)
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        self.recording = MobileDocumentRecordingStore(store)
        var nextID = 0
        self.document = try BrowserMobileProfileDocument(
            store: recording, initialSnapshot: store.loadSnapshotStrict(), syncCoordinator: coordinator,
            idProvider: { nextID += 1
                return "new-\(nextID)"
            },
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) }, maximumBufferedWrites: maximumBufferedWrites
        )
    }

    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileDocument-\(UUID())")
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "owner")
    let store: BrowserSQLiteSessionStore
    let recording: MobileDocumentRecordingStore
    let coordinator = MobileDocumentCoordinator()
    let document: BrowserMobileProfileDocument

    var databaseURL: URL { directory.appendingPathComponent("Profile.sqlite") }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func operations() throws -> [BrowserSyncFolderOperation] {
        try store.pendingSyncQueue(for: owner).flatMap { row in
            guard case .folders(let mutation) = row else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return mutation.operations
        }
    }

    func remoteReplace(_ snapshot: BrowserTabSessionSnapshot) throws -> BrowserTabSessionSnapshot {
        let old = try BrowserSyncFolderProjection.canonicalChanges(store.loadSnapshotStrict() ?? .init(tabs: []))
        let next = BrowserSyncFolderProjection.canonicalChanges(snapshot)
        let keys = Set(next.map(BrowserSyncOutboxProjection.key))
        let deletes = old.filter { !keys.contains(BrowserSyncOutboxProjection.key($0)) }.map {
            BrowserSyncChange(
                entityType: $0.entityType,
                entityID: $0.entityID,
                op: .delete,
                spaceData: nil,
                tabData: nil
            )
        }
        let events = try Self.events(next + deletes, startingAt: sequence)
        sequence += events.count
        return try store.applyRemoteSyncEvents(events, cursor: sequence - 1, for: owner)
    }

    // MARK: Private

    private var sequence = 100

    private static func events(_ changes: [BrowserSyncChange], startingAt sequence: Int) throws -> [BrowserSyncEvent] {
        try changes.enumerated().map { offset, change in
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
            var payload = object["data"] as? [String: Any] ?? [:]
            payload["id"] = change.entityID
            let wire: [String: Any] = [
                "serverSeq": sequence + offset, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
                "entityID": change.entityID, "op": change.op.rawValue, "data": payload,
                "createdAt": "2026-10-03T00:00:00Z",
            ]
            return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        }
    }
}

// MARK: - MobileDocumentRecordingStore

private final class MobileDocumentRecordingStore: BrowserTabSessionSnapshotStoring {
    // MARK: Lifecycle

    init(_ underlying: BrowserSQLiteSessionStore) { self.underlying = underlying }

    // MARK: Internal

    let underlying: BrowserSQLiteSessionStore
    var failure: Error?
    var attempts = [[BrowserSessionWrite]]()

    func loadSnapshot() -> BrowserTabSessionSnapshot? { underlying.loadSnapshot() }
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) { underlying.saveSnapshot(snapshot) }
    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws {
        attempts.append(writes)
        if let failure {
            throw failure
        }
        try underlying.writeSessionBatch(writes)
    }
}

// MARK: - MobileDocumentCoordinator

@MainActor private final class MobileDocumentCoordinator: BrowserSyncCoordinating {
    var pushes = [BrowserTabSessionSnapshot]()
    var pulls = 0
    var blocks = [Bool]()

    func schedulePush(snapshot: BrowserTabSessionSnapshot) { pushes.append(snapshot) }
    func schedulePull() { pulls += 1 }
    func setLocalPersistenceBlocked(_ blocked: Bool) { blocks.append(blocked) }
}

// MARK: - MobileDocumentFailure

private enum MobileDocumentFailure: Error, Equatable { case injected }
