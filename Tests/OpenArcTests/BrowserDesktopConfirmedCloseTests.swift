// BrowserDesktopConfirmedCloseTests.swift

import AppKit
import GRDB
import Testing

// MARK: - BrowserDesktopConfirmedCloseTests

@Suite(.serialized) @MainActor struct BrowserDesktopConfirmedCloseTests {
    @Test func cancelledRejectedAndStaleCloseRequestsLeaveTheProfileAndSelectionUntouched() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try f.runtimeID("a")
        let before = try f.evidence()
        let selected = f.model.selectedTabID
        let runtimeIDs = f.model.tabs.map(\.id)
        f.driver.closeRequestAdmissionResult = false
        #expect(!f.model.archiveSelectedTab())
        #expect(f.driver.confirmedCloseRequests.isEmpty)
        #expect(try f.evidence() == before)
        f.driver.closeRequestAdmissionResult = true
        #expect(f.model.archiveSelectedTab())
        let cancelled = try #require(f.driver.confirmedCloseRequests.last)
        #expect(cancelled.id == id)
        #expect(f.model.tabs.map(\.id) == runtimeIDs && f.model.selectedTabID == selected)
        #expect(try f.evidence() == before)
        #expect(!f.model.undoManager.canUndo)
        #expect(!f.model.archiveSelectedTab())
        #expect(f.driver.confirmedCloseRequests.count == 1)
        f.finish(cancelled, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.model.tabs.map(\.id) == runtimeIDs && f.model.selectedTabID == selected)
        #expect(f.model.archiveSelectedTab())
        let current = try #require(f.driver.confirmedCloseRequests.last)
        #expect(current.requestID != cancelled.requestID)
        f.driver.emitCloseRequestOutcome(
            id: id, requestID: cancelled.requestID, outcome: .closed, emitsClosedEvent: false,
        )
        #expect(try f.evidence() == before)
        #expect(f.model.tabs.map(\.id) == runtimeIDs)
        f.finish(current, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.model.selectedTabID == selected && !f.model.undoManager.canUndo)
    }

    @Test func confirmedCloseDeletesLatestLogicalTabExactlyOnceWithoutIntermediatePersistence() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try f.runtimeID("a")
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.setUserTitleOverride("Edited while confirmation was open", forTabID: id)
        f.driver.emitUpdate(id: id, title: "Latest loaded title", urlString: "https://example.com/latest")
        let preclose = try #require(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "a" })
        #expect(preclose.urlString == "https://example.com/latest")
        #expect(preclose.userTitleOverride == "Edited while confirmation was open")
        #expect(f.model.tabs.first { $0.id == id }?.title == "Latest loaded title")
        f.recording.reset()
        f.finish(request, .closed)
        let archived = try #require(try f.store.loadArchivePage().entries.first)
        #expect(archived.tab == preclose && archived.title == "Latest loaded title")
        #expect(f.recording.attempts.count == 1)
        let write = try #require(f.recording.attempts.first?.first)
        #expect(f.recording.attempts.first?.count == 1)
        #expect(write.origin == .local(syncMove: nil) && write.archiveAction == .insert(archived))
        #expect(write.snapshot.tabs.map(\.id) == ["b"])
        #expect(!f.model.tabs.contains { $0.syncID == "a" })
        #expect(f.model.tabs.first { $0.id == f.model.selectedTabID }?.syncID == "b")
        #expect(try f.hasTombstone("a"))
        #expect(try f.operations().count(where: { $0 == .deleteTab(id: "a") }) == 1)
        let committed = try f.evidence()
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: id)
        #expect(try f.evidence() == committed)
        #expect(f.recording.attempts.count == 1)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadArchivePage().entries == [archived])
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "a" } == false)
    }

    @Test(arguments: ["snapshot", "outbox"])
    func failedConfirmedDeleteKeepsItsExactFIFOActionThroughLaterEditAndRetry(failure: String) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let before = try f.evidence()
        let trigger = failure == "snapshot"
            ? "BEFORE DELETE ON browser_tabs"
            : "BEFORE INSERT ON browser_sync_outbox"
        try f.sql("CREATE TRIGGER fail_confirmed_close \(trigger) BEGIN SELECT RAISE(ABORT,'injected'); END")
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(f.sync.blocked.last == true)
        #expect(try f.evidence() == before)
        let firstBatch = try #require(f.recording.attempts.last)
        let deleteWrite = try #require(firstBatch.first)
        let archiveAction = try #require(deleteWrite.archiveAction)
        guard case .insert(let archived) = archiveAction else {
            Issue.record("Confirmed Today Close must atomically insert its Archive entry")
            return
        }
        #expect(firstBatch.count == 1 && archived.tab.id == "a")
        #expect(!f.model.undoManager.canUndo)
        #expect(deleteWrite.origin == .local(syncMove: nil) && deleteWrite.snapshot.tabs.map(\.id) == ["b"])
        f.clock.now += 600
        try f.model.setUserTitleOverride("Later survivor edit", forTabID: f.runtimeID("b"))
        let fifo = try #require(f.recording.attempts.last)
        #expect(fifo.count > firstBatch.count)
        #expect(Array(fifo.prefix(firstBatch.count)) == firstBatch)
        #expect(fifo.compactMap(\.archiveAction) == [archiveAction])
        #expect(try f.evidence() == before)
        #expect(!f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo)
        try f.sql("DROP TRIGGER fail_confirmed_close")
        #expect(f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo)
        #expect(!f.model.hasUncommittedSessionWrites && f.sync.blocked.last == false)
        #expect(f.model.undoManager.canUndo)
        #expect(try f.store.loadArchivePage().entries == [archived])
        #expect(try f.store
            .loadSnapshotStrict()?
            .tabs
            .first { $0.id == "b" }?
            .userTitleOverride == "Later survivor edit")
        #expect(try f.hasTombstone("a"))
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadArchivePage().entries == [archived])
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "a" } == false)
    }

    @Test func confirmedManualCloseRegistersUndoThatRestoresLatestContentWithFreshIdentity() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let originalID = try f.runtimeID("a")
        #expect(f.model.archiveSelectedTab())
        f.model.setUserTitleOverride("Latest undo title", forTabID: originalID)
        f.driver.emitUpdate(id: originalID, title: "Latest loaded title", urlString: "https://example.com/undo-latest")
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        #expect(f.model.undoManager.canUndo)
        let archived = try #require(try f.store.loadArchivePage().entries.first)
        f.recording.reset()
        f.model.undoManager.undo()
        f.flushReady()
        let restored = try #require(f.model.tabs.first { $0.urlString == "https://example.com/undo-latest" })
        #expect(restored.syncID != "a" && restored.id != originalID)
        #expect(restored.userTitleOverride == "Latest undo title")
        #expect(restored.title == "Latest loaded title")
        #expect(f.model.selectedTabID == restored.id)
        #expect(f.model.tabs.map(\.syncID) == [restored.syncID, "b"])
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(f.recording.attempts.flatMap(\.self).compactMap(\.archiveAction).contains(
            .restore(archiveID: archived.id, tabID: restored.syncID),
        ))
        #expect(try f.hasTombstone("a"))
        #expect(f.model.undoManager.canRedo)
        #expect(try f.store.loadSnapshotStrict()?.tabs.map(\.id) == [restored.syncID, "b"])
        #expect(try f.operations().contains { operation in
            if case .createTab(let id, _, _, _) = operation {
                return id == restored.syncID
            }
            return false
        })
    }

    @Test func remoteDeletionSupersedesPendingLocalCloseWithoutArchiveOrMutationEcho() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        let sequence = try f.store.syncCursor(for: f.owner) + 1
        let event = BrowserSyncEvent(
            serverSeq: sequence, deviceID: "other-device", entityType: "tab", entityID: "a", op: "delete",
            data: .deleted(id: "a"), createdAt: "2026-10-03T00:00:00Z",
        )
        let remote = try f.store.applyRemoteSyncEvents([event], cursor: sequence, for: f.owner)
        f.model.applyRemoteSyncSnapshot(remote)
        let committed = try f.evidence()
        #expect(committed.queue.isEmpty && committed.archive.isEmpty)
        #expect(!f.model.tabs.contains { $0.syncID == "a" })
        #expect(f.driver.closedTabRequests.contains(.init(id: request.id, forceClose: true)))
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        #expect(try f.evidence() == committed)
        #expect(!f.model.undoManager.canUndo)
        #expect(try f.hasTombstone("a"))
    }

    @Test(arguments: [BrowserTabPlacement.spacePinned, .app])
    func promotionWhileCloseIsPendingPreservesPersistentIdentityAndLeavesOnlyItsRuntimeDormant(
        placement: BrowserTabPlacement,
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let originalID = try f.runtimeID("a")
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.moveTab(withID: originalID, toPlacement: placement, atSectionIndex: 0)
        let promoted = try #require(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "a" })
        #expect(promoted.placement == placement)
        let promotedQueue = try f.evidence().queue
        let closes = f.driver.closedTabRequests
        let creates = f.driver.createdTabRequests.count
        f.finish(request, .closed)
        let retained = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(retained.id == originalID && retained.placement == placement)
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "a" } == promoted)
        #expect(try f.evidence().queue == promotedQueue)
        #expect(try !f.operations().contains(.deleteTab(id: "a")))
        #expect(try !f.hasTombstone("a"))
        #expect(f.driver.closedTabRequests == closes)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(f.driver.confirmedCloseRequests.count == 1)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        // Selecting the dormant persistent item must allocate one new runtime,
        // retaining its durable identity and avoiding any additional close.
        f.model.selectTab(id: originalID)
        f.flushReady()
        let reopened = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(reopened.id != originalID && reopened.placement == placement)
        #expect(f.model.selectedTabID == reopened.id)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(f.driver.closedTabRequests == closes)
        #expect(try f.evidence().queue == promotedQueue)
        #expect(try !f.hasTombstone("a"))
    }

    @Test(arguments: [BrowserTabCloseOutcome.cancelled, .closed])
    func pendingCloseCompletionPreservesTheUsersNewerSelection(outcome: BrowserTabCloseOutcome) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        let survivorID = try f.runtimeID("b")
        f.clock.now += 60
        f.model.selectTab(id: survivorID)
        f.model.persistPendingSelection()
        let selectedState = try f.evidence()
        let selections = f.driver.selectedTabIDs
        f.finish(request, outcome)
        #expect(f.model.selectedTabID == survivorID)
        #expect(f.model.tabs.first { $0.id == survivorID }?.syncID == "b")
        #expect(f.driver.selectedTabIDs == selections)
        if outcome == .cancelled {
            #expect(try f.evidence() == selectedState)
            #expect(f.model.tabs.contains { $0.syncID == "a" })
        } else {
            #expect(!f.model.tabs.contains { $0.syncID == "a" })
            #expect(try f.operations().count(where: { $0 == .deleteTab(id: "a") }) == 1)
            #expect(try f.hasTombstone("a"))
        }
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == (outcome == .closed ? ["a"] : []))
    }

    @Test func cancellationPreservesReadinessDeliveredWhileTheInitialEngineCloseWasPending() throws {
        let f = try ConfirmedCloseFixture(ready: false)
        defer { f.close() }
        let id = try f.runtimeID("a")
        #expect(f.model.tabs.first { $0.id == id }?.creationState == .creating)
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.driver.emitTabCreationState(id: id, state: .ready)
        #expect(f.model.tabs.first { $0.id == id }?.creationState == .ready)
        f.finish(request, .cancelled)
        let retained = try #require(f.model.tabs.first { $0.id == id })
        #expect(retained.creationState == .ready && retained.syncID == "a")
        #expect(f.model.selectedTabID == id)
        #expect(try f.evidence() == before)
        f.model.selectTab(id: id)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(f.driver.retryCreationRequests.isEmpty)
        #expect(try f.evidence() == before)
    }

    @Test func lastTabCloseCannotDiscardFailedDeletePersistenceDuringWindowClosure() throws {
        let f = try ConfirmedCloseFixture(tabIDs: ["a"])
        defer { f.close() }
        let before = try f.evidence()
        try f
            .sql(
                "CREATE TRIGGER fail_last_close BEFORE DELETE ON browser_tabs BEGIN SELECT RAISE(ABORT,'injected'); END",
            )
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(request, .closed)
        #expect(f.model.tabs.isEmpty && f.model.hasUncommittedSessionWrites)
        #expect(f.lifecycle.allClosed == 0)
        #expect(!f.model.prepareSessionForClosure())
        f.model.prepareForTermination()
        #expect(!f.model.isShuttingDown && f.driver.prepareForCefShutdownCount == 0)
        #expect(try f.evidence() == before)
        let frozen = try #require(f.recording.attempts.last)
        f.finish(request, .closed)
        #expect(f.recording.attempts.last == frozen)
        try f.sql("DROP TRIGGER fail_last_close")
        #expect(f.model.retrySessionPersistence())
        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["a"])
        #expect(try f.store.loadSnapshotStrict()?.tabs.isEmpty == true)
        #expect(f.model.prepareSessionForClosure())
    }
}

// MARK: - ConfirmedCloseFixture

@MainActor final class ConfirmedCloseFixture {
    // MARK: Internal

    let directory: URL
    let databaseURL: URL
    let suite: String
    let defaults: UserDefaults
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://confirmed-close.example")!, userID: "owner")
    let clock = ConfirmedCloseClock()
    let lifecycle = ConfirmedCloseLifecycle()
    let store: BrowserSQLiteSessionStore
    let recording: ConfirmedCloseRecordingStore
    let driver = FakeBrowserTabDriver()
    let sync = ConfirmedCloseCoordinator()
    let model: BrowserChromeModel

    init(tabIDs: [String] = ["a", "b"], ready: Bool = true) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfirmedClose-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.suite = BrowserTestDefaults.suiteName("ConfirmedClose")
        self.defaults = UserDefaults(suiteName: suite)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.recording = ConfirmedCloseRecordingStore(store)
        let fixtureClock = clock
        let fixtureLifecycle = lifecycle
        let seed = BrowserTabSessionSnapshot(
            spaces: [.init(id: "work", title: "Work", systemImageName: "globe", selectedTabIndex: 0)],
            tabs: tabIDs.map { .init(
                id: $0, urlString: "https://example.com/\($0)", userTitleOverride: $0 == "a" ? "Saved title" : nil,
                spaceID: "work", lastActivityTimestamp: fixtureClock.now,
            ) },
        )
        try store.bindSyncOwner(owner)
        let events = try confirmedCloseEvents(seed)
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(0)
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: recording, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            dateProvider: { Date(timeIntervalSince1970: fixtureClock.now) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: { fixtureLifecycle.allClosed += 1 },
        )
        driver.automaticallyConfirmsCloseRequests = false
        model.handleContextReady()
        if ready {
            flushReady()
        } else {
            driver.flushPendingCreateEvents()
        }
        model.undoManager.removeAllActions()
        recording.reset()
    }

    func runtimeID(_ stableID: String) throws -> String {
        try #require(model.tabs.first { $0.syncID == stableID }).id
    }

    func finish(_ request: FakeBrowserTabDriver.ConfirmedCloseRequest, _ outcome: BrowserTabCloseOutcome) {
        driver.emitCloseRequestOutcome(id: request.id, requestID: request.requestID, outcome: outcome)
    }

    func flushReady() {
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
    }

    func sql(_ sql: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) }
    }

    func hasTombstone(_ id: String) throws -> Bool {
        try DatabaseQueue(path: databaseURL.path).read { db in
            let bytes = try #require(try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1"))
            return try JSONDecoder()
                .decode(BrowserSyncOutboxBaseline.self, from: bytes)
                .deletedKeys
                .contains("tab:\(id)")
        }
    }

    func operations() throws -> [BrowserSyncFolderOperation] {
        try store.pendingSyncQueue(for: owner).flatMap { queued in
            guard case .folders(let mutation) = queued else {
                Issue.record("Confirmed Close should use the ordinary v4 queue")
                return [BrowserSyncFolderOperation]()
            }
            return mutation.operations
        }
    }

    func evidence() throws -> ConfirmedCloseEvidence {
        let rows = try DatabaseQueue(path: databaseURL.path).read { db in
            try (
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id,'') FROM browser_tab_archive_receipts ORDER BY id",
                ),
                String.fetchAll(db, sql: "SELECT key || ':' || value FROM browser_preferences ORDER BY key"),
            )
        }
        return try .init(
            snapshot: store.loadSnapshotStrict(),
            queue: rows.0,
            baseline: rows.1,
            archive: rows.2,
            receipts: rows.3,
            preferences: rows.4,
        )
    }

    func close() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - ConfirmedCloseEvidence

struct ConfirmedCloseEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [Data]
    let baseline: [Data]
    let archive: [Data]
    let receipts: [String]
    let preferences: [String]
}

// MARK: - ConfirmedCloseClock

@MainActor final class ConfirmedCloseClock { var now: TimeInterval = 1_800_000_000 }

// MARK: - ConfirmedCloseLifecycle

@MainActor final class ConfirmedCloseLifecycle { var allClosed = 0 }

// MARK: - ConfirmedCloseCoordinator

@MainActor final class ConfirmedCloseCoordinator: BrowserSyncCoordinating {
    var blocked = [Bool]()

    func schedulePush(snapshot _: BrowserTabSessionSnapshot) {}
    func schedulePull() {}
    func setLocalPersistenceBlocked(_ blocked: Bool) { self.blocked.append(blocked) }
}

// MARK: - ConfirmedCloseRecordingStore

final class ConfirmedCloseRecordingStore: BrowserTabSessionSnapshotStoring, BrowserTabArchiveStoring,
BrowserSyncOwnershipReading {
    // MARK: Internal

    let store: BrowserSQLiteSessionStore
    private(set) var attempts = [[BrowserSessionWrite]]()

    init(_ store: BrowserSQLiteSessionStore) { self.store = store }

    func reset() { attempts.removeAll() }
    func loadSnapshot() -> BrowserTabSessionSnapshot? { store.loadSnapshot() }
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) { store.saveSnapshot(snapshot) }
    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws {
        attempts.append(writes)
        try store.writeSessionBatch(writes)
    }

    func syncOwner() throws -> BrowserSyncOwner? { try store.syncOwner() }
    func loadArchiveEntry(id: String) throws -> BrowserTabArchiveEntry? { try store.loadArchiveEntry(id: id) }
    func loadArchivePage(before: BrowserTabArchiveCursor?, limit: Int) throws -> BrowserTabArchivePage {
        try store.loadArchivePage(before: before, limit: limit)
    }

    nonisolated(nonsending) func searchArchivePage(
        query: String,
        before: BrowserTabArchiveCursor?,
        limit: Int,
    ) async throws -> BrowserTabArchivePage {
        try await store.searchArchivePage(query: query, before: before, limit: limit)
    }

    nonisolated(nonsending) func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        try await store.archiveClearBoundary()
    }

    nonisolated(nonsending) func removeArchiveEntry(id: String) async throws -> Bool {
        try await store.removeArchiveEntry(id: id)
    }

    nonisolated(nonsending) func clearArchive(through boundary: BrowserTabArchiveBoundary) async throws -> Int {
        try await store.clearArchive(through: boundary)
    }
}

private func confirmedCloseEvents(_ snapshot: BrowserTabSessionSnapshot) throws -> [BrowserSyncEvent] {
    try BrowserSyncFolderProjection.canonicalChanges(snapshot).enumerated().map { index, change in
        let encoded = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        var data = encoded["data"] as? [String: Any] ?? [:]
        data["id"] = change.entityID
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: [
            "serverSeq": index + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
            "entityID": change.entityID, "op": change.op.rawValue, "data": data, "createdAt": "2026-10-03T00:00:00Z",
        ]))
    }
}
