// BrowserMobileActivityTests.swift

import Foundation
import GRDB
import Testing
import UIKit

// MARK: - BrowserMobileActivityTests

@Suite(.serialized) @MainActor struct BrowserMobileActivityTests {
    @Test func activityUsesWholeSecondMonotonicChangesWithoutRoundingExistingPrecision() async throws {
        try await withMobileActivityFixture { f in
            f.clock.now = 100.9
            #expect(f.document.recordActivity(tabIDs: ["a", "b", "missing"]))
            #expect(f.activity("a") == 100.75 && f.activity("b") == 100)
            #expect(try f.operations() == [.patchTab(id: "b", fields: .init(lastActivityAt: .set(f.date(100))))])
            let unchanged = try f.queue()
            #expect(!f.document.recordActivity(tabIDs: ["a", "b", "missing"]))
            f.clock.now = 99
            #expect(!f.document.recordActivity(tabIDs: ["a", "b"]))
            #expect(!f.document.recordActivity(tabIDs: []))
            #expect(!f.document.recordActivity(tabIDs: ["missing"]))
            #expect(try f.queue() == unchanged)

            #expect(f.document.updateURL(tabID: "a", urlString: "https://activity.example/new"))
            #expect(f.activity("a") == 100.75)
            #expect(try f.lastOperations() == [.patchTab(
                id: "a",
                fields: .init(urlString: "https://activity.example/new"),
            )])
            #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "a" }?.lastActivityTimestamp == 100.75)
            f.clock.now = 101.8
            #expect(f.document.recordActivity(tabIDs: ["b", "a"]))
            let touchedIDs = f.document.snapshot.tabs.compactMap { ["a", "b"].contains($0.id ?? "") ? $0.id : nil }
            #expect(try f.lastOperations() == touchedIDs.map {
                .patchTab(id: $0, fields: .init(lastActivityAt: .set(f.date(101))))
            })
            #expect(f.activity("a") == 101 && f.activity("b") == 101)
            #expect(f.document.removeTab(id: "a"))
            let removed = try f.queue()
            f.clock.now = 200
            #expect(!f.document.recordActivity(tabIDs: ["a"]))
            #expect(try f.queue() == removed)
            #expect(!f.document.snapshot.tabs.contains { $0.id == "a" })
        }
    }

    @Test(arguments: ["pin", "favorite"]) func enteringTodayRecordsActivityInTheSameMoveWrite(id: String) async throws {
        try await withMobileActivityFixture { f in
            f.clock.now = 300.9
            let item = BrowserSyncEntityReference(entityType: .tab, entityID: id)
            let target = BrowserSyncFolderDestination.tabs(
                spaceID: "source",
                placement: .temporary,
                pinnedFolderID: nil,
            )
            #expect(f.document.move(items: [item], destination: target))
            #expect(try f.queue().count == 1)
            let operations = try f.lastOperations()
            #expect(operations.contains(.patchTab(id: id, fields: .init(lastActivityAt: .set(f.date(300))))))
            #expect(operations.count(where: {
                if case .move = $0 {
                    true
                } else {
                    false
                }
            })
                 == 1)
            #expect(f.activity(id) == 300 && f.activity("a") == 100.75)
            f.clock.now = 400
            let previous = try f.queue()
            #expect(!f.document.move(items: [item], destination: target))
            #expect(!f.document.move(
                items: [item],
                destination: .tabs(spaceID: "missing", placement: .temporary, pinnedFolderID: nil),
            ))
            #expect(try f.queue() == previous && f.activity(id) == 300)
            #expect(f.document.move(items: [item], destination: target, before: .init(entityType: .tab, entityID: "a")))
            #expect(f.activity(id) == 300, "Reordering Today is not a new transition into Today")
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try reopened.loadSnapshotStrict() == f.document.snapshot)
        }
    }

    @Test func activeSelectionTouchesOutgoingAndIncomingWhileInactiveSelectionOnlyRenewsLease() async throws {
        try await withMobileActivityFixture { f in
            let (workspace, engine) = await f.workspace("first")
            workspace.setSceneAttached(true)
            workspace.selectTab(id: "a")
            #expect(try f.document.protectedTabIDs == ["a"] && f.queue().isEmpty)
            f.clock.now = 200
            workspace.setActivityActive(true)
            #expect(f.activity("a") == 200)
            let runtimes = workspace.tabs.map(\.runtimeID)
            f.clock.now = 210
            workspace.selectTab(id: "b")
            #expect(f.activity("a") == 210 && f.activity("b") == 210)
            #expect(f.document.protectedTabIDs == ["b"])
            #expect(workspace.tabs.map(\.runtimeID) == runtimes && engine.closed.isEmpty)
            let selectedQueue = try f.queue()
            f.clock.now = 220
            workspace.selectTab(id: "b")
            #expect(try f.queue().count == selectedQueue.count + 1)
            #expect(try f.lastOperations() == [.patchTab(id: "b", fields: .init(lastActivityAt: .set(f.date(220))))])
            let repeatedSelection = try f.queue()
            workspace.selectTab(id: "b")
            workspace.setActivityActive(true)
            #expect(
                try f.queue() == repeatedSelection,
                "Same-second selection and duplicate lifecycle delivery do not write",
            )
            f.clock.now = 230
            workspace.setActivityActive(false)
            #expect(f.activity("b") == 230 && f.document.protectedTabIDs == ["b"])
            let inactiveQueue = try f.queue()
            f.clock.now = 240
            workspace.setActivityActive(false)
            workspace.selectTab(id: "c")
            #expect(workspace.selectedSpaceID == "target" && f.document.protectedTabIDs == ["c"])
            #expect(try f.queue() == inactiveQueue && f.activity("c") == 80)
            workspace.setSceneAttached(false)
            #expect(try f.document.protectedTabIDs.isEmpty && f.queue() == inactiveQueue)
        }
    }

    @Test func loadedDocumentAndRemoteProjectionRenewLeasesWithoutActivityEcho() async throws {
        try await withMobileActivityFixture { f in
            let (workspace, engine) = await f.workspace("first")
            workspace.setSceneAttached(true)
            workspace.selectTab(id: "a")
            f.clock.now = 100
            workspace.setActivityActive(true)
            let runtime = try #require(workspace.selectedTab?.runtimeID)
            f.clock.now = 900
            engine.onEvent?(.state(
                id: runtime,
                .init(
                    url: URL(string: "https://activity.example/a"),
                    title: "Loaded title",
                    isLoading: false,
                    progress: 1,
                    canGoBack: true,
                ),
            ))
            #expect(try f.queue().isEmpty)
            let old = try #require(f.document.snapshot.tabs.first { $0.id == "a" })
            let changed = activityTab(old, url: "https://activity.example/remote", timestamp: 20)
            let changes = BrowserSyncFolderProjection.canonicalChanges(.init(
                spaces: f.document.snapshot.spaces,
                tabs: [changed],
            ))
            .filter { $0.entityType == .tab }
            let remote = try f.store.applyRemoteSyncEvents(
                activityEvents(changes, startingAt: 100),
                cursor: 100,
                for: f.owner,
            )
            f.document.applyRemoteSyncSnapshot(remote)
            #expect(workspace.selectedTab?.runtimeID == runtime)
            #expect(workspace.selectedTab?.urlString == changed.urlString && f.activity("a") == 20)
            #expect(try f.document.protectedTabIDs == ["a"] && f.queue().isEmpty)
            let deletion = BrowserSyncChange(entityType: .tab, entityID: "a", op: .delete, spaceData: nil, tabData: nil)
            let deleted = try f.store.applyRemoteSyncEvents(
                activityEvents([deletion], startingAt: 101),
                cursor: 101,
                for: f.owner,
            )
            f.document.applyRemoteSyncSnapshot(deleted)
            #expect(!workspace.tabs.contains { $0.id == "a" } && engine.closed.contains(runtime))
            #expect(f.document.protectedTabIDs == Set([workspace.selectedTabID].compactMap(\.self)))
            #expect(try f.queue().isEmpty, "Remote URL, activity and fallback selection do not echo local touches")
        }
    }

    @Test func sceneLeasesSurviveInactivityButRejectStaleConnectionsAndReleaseOnDisconnect() async throws {
        try await withMobileActivityFixture { f in
            let scenes = f.scenes()
            var first = try await scenes.connect(sessionID: "first")
            let second = try await scenes.connect(sessionID: "second")
            await scenes.waitForPendingOperations()
            first.workspace.selectTab(id: "a")
            second.workspace.selectTab(id: "a")
            #expect(f.document.protectedTabIDs == ["a"])
            scenes.disconnect(first)
            #expect(f.document.protectedTabIDs == ["a"], "Releasing one owner keeps another window's lease")
            first = try await scenes.connect(sessionID: "first")
            second.workspace.selectTab(id: "b")
            let staleOwner = UUID()
            f.document.updateSelectionLease(owner: staleOwner, selectedTabID: "missing")
            #expect(try f.document.protectedTabIDs == ["a", "b"] && f.queue().isEmpty)
            f.document.removeSelectionLease(owner: staleOwner)
            f.clock.now = 500
            scenes.setActive(true, for: first)
            scenes.setActive(true, for: second)
            f.clock.now = 510
            scenes.setActive(false, for: first)
            #expect(f.document.protectedTabIDs == ["a", "b"])
            scenes.disconnect(first)
            #expect(f.document.protectedTabIDs == ["b"])
            let replacement = try await scenes.connect(sessionID: "second")
            #expect(replacement.workspace === second.workspace && f.document.protectedTabIDs == ["b"])
            let beforeStale = try f.queue()
            f.clock.now = 520
            scenes.setActive(true, for: second)
            scenes.setActive(false, for: second)
            scenes.disconnect(second)
            #expect(try f.queue() == beforeStale && f.document.protectedTabIDs == ["b"])
            scenes.setActive(true, for: replacement)
            #expect(f.activity("b") == 520)
            #expect(f.document.removeTab(id: "b"))
            #expect(!f.document.protectedTabIDs.contains("b"))
            #expect(f.document.protectedTabIDs == Set([replacement.workspace.selectedTabID].compactMap(\.self)))
            scenes.discard(sessionIDs: ["first", "second"])
            await scenes.waitForPendingOperations()
            #expect(f.document.protectedTabIDs.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func activityBeforeAsyncRestoreUsesOnlyTheCurrentAttachedScene(disconnectBeforeRestore: Bool) async throws {
        try await withMobileActivityFixture { f in
            let gate = MobileActivityLoadGate(document: f.document)
            let scenes = f.scenes(loader: { await gate.load() })
            let connection = try await scenes.connect(sessionID: "delayed")
            scenes.setActive(true, for: connection)
            await gate.waitUntilHeld()
            #expect(try f.document.protectedTabIDs.isEmpty && f.queue().isEmpty)
            if disconnectBeforeRestore {
                scenes.disconnect(connection)
            }
            f.clock.now = 600
            gate.release()
            await scenes.waitForPendingOperations()
            #expect(connection.workspace.isReady)
            let selected = try #require(connection.workspace.selectedTabID)
            if disconnectBeforeRestore {
                #expect(try f.document.protectedTabIDs.isEmpty && f.queue().isEmpty)
                let replacement = try await scenes.connect(sessionID: "delayed")
                #expect(f.document.protectedTabIDs == [selected])
                scenes.setActive(true, for: connection)
                #expect(try f.queue().isEmpty)
                scenes.setActive(true, for: replacement)
            }
            #expect(f.document.protectedTabIDs == [selected] && f.activity(selected) == 600)
            #expect(try f.queue().count == 1)
            scenes.discard(sessionIDs: ["delayed"])
            await scenes.waitForPendingOperations()
            #expect(f.document.protectedTabIDs.isEmpty)
        }
    }

    @Test func failedActivityWriteRetainsOrderedEditsAndRetryReopensWithoutLostTimestamps() async throws {
        try await withMobileActivityFixture { f in
            let (workspace, _) = await f.workspace("first")
            workspace.setSceneAttached(true)
            workspace.selectTab(id: "a")
            f.clock.now = 1000
            workspace.setActivityActive(true)
            let durable = try f.store.loadSnapshotStrict()
            let queue = try f.queue()
            let bytes = try f.queueBytes()
            try f
                .sql(
                    "CREATE TRIGGER fail_activity BEFORE INSERT ON browser_sync_outbox BEGIN SELECT RAISE(ABORT, 'injected'); END",
                )
            f.clock.now = 1100
            workspace.selectTab(id: "b")
            #expect(f.document.hasUncommittedWrites && f.document.persistenceFailure?.isRetryable == true)
            #expect(f.activity("a") == 1100 && f.activity("b") == 1100)
            #expect(f.document.protectedTabIDs == ["b"])
            #expect(f.document.renameTab(id: "b", title: "After failed activity"))
            f.clock.now = 1200
            workspace.setActivityActive(false)
            let optimistic = f.document.snapshot
            #expect(f.activity("b") == 1200)
            #expect(try f.store.loadSnapshotStrict() == durable && f.queue() == queue && f.queueBytes() == bytes)
            f.document.applyRemoteSyncSnapshot(.init(tabs: []))
            #expect(f.document.snapshot == optimistic)
            #expect(!f.document.retryPersistence())
            try f.sql("DROP TRIGGER fail_activity")
            #expect(f.document.retryPersistence() && !f.document.hasUncommittedWrites)
            let batches = try f.batches().dropFirst(queue.count)
            let ids = optimistic.tabs.compactMap { ["a", "b"].contains($0.id ?? "") ? $0.id : nil }
            #expect(Array(batches) == [
                ids.map { .patchTab(id: $0, fields: .init(lastActivityAt: .set(f.date(1100)))) },
                [.patchTab(id: "b", fields: .init(userTitleOverride: .set("After failed activity")))],
                [.patchTab(id: "b", fields: .init(lastActivityAt: .set(f.date(1200))))],
            ])
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try reopened.loadSnapshotStrict() == optimistic)
            #expect(try reopened.pendingSyncQueue(for: f.owner) == f.queue())
            #expect(try f.queueBytes().prefix(bytes.count) == bytes[...])
        }
    }
}

// MARK: - MobileActivityClock

@MainActor private final class MobileActivityClock { var now: TimeInterval = 100 }

// MARK: - MobileActivityFixture

@MainActor private final class MobileActivityFixture {
    // MARK: Internal

    let databaseURL: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://activity.example")!, userID: "activity-tests")
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let clock = MobileActivityClock()
    let preferencesName = "MobileActivity." + UUID().uuidString
    let preferences: UserDefaults
    var workspaces = [BrowserMobileWorkspace]()
    var sceneRegistries = [BrowserMobileSceneSessions]()

    init(directory: URL) throws {
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        try store.bindSyncOwner(owner)
        let snapshot = BrowserTabSessionSnapshot(spaces: [
            .init(id: "source", title: "Source", systemImageName: "globe"),
            .init(id: "target", title: "Target", systemImageName: "star"),
        ], tabs: [
            .init(id: "a", urlString: "https://activity.example/a", spaceID: "source", lastActivityTimestamp: 100.75),
            .init(id: "b", urlString: "https://activity.example/b", spaceID: "source", lastActivityTimestamp: 50),
            .init(id: "c", urlString: "https://activity.example/c", spaceID: "target", lastActivityTimestamp: 80),
            .init(
                id: "pin",
                urlString: "https://activity.example/pin",
                pinnedURLString: "https://activity.example/pin",
                placement: .spacePinned,
                spaceID: "source",
                lastActivityTimestamp: 60,
            ),
            .init(
                id: "favorite",
                urlString: "https://activity.example/favorite",
                placement: .app,
                spaceID: "source",
                lastActivityTimestamp: 70,
            ),
        ])
        let events = try activityEvents(BrowserSyncFolderProjection.canonicalChanges(snapshot))
        let canonical = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        // A legacy local snapshot may retain subsecond precision even though the wire uses seconds.
        let precise = BrowserTabSessionSnapshot(
            spaces: canonical.spaces,
            pinnedTabFolders: canonical.pinnedTabFolders,
            tabs: canonical.tabs.map {
                $0.id == "a" ? activityTab($0, timestamp: 100.75) : $0
            },
        )
        try store.writeSessionBatch([.init(snapshot: precise, origin: .remoteProjection)])
        let clock = clock
        self.document = try BrowserMobileProfileDocument(
            store: store,
            initialSnapshot: precise,
            dateProvider: { Date(timeIntervalSince1970: clock.now) },
        )
    }

    func makeWorkspace(
        _ id: String,
        loader: (@MainActor () async throws -> BrowserMobileProfileDocument)? = nil,
    )
    -> (BrowserMobileWorkspace, MobileActivityEngine) {
        let engine = MobileActivityEngine()
        let document = document
        let workspace = BrowserMobileWorkspace(
            engine: engine,
            sceneID: id,
            profileLoader: loader ?? { document },
            preferences: preferences,
        )
        workspaces.append(workspace)
        return (workspace, engine)
    }

    func workspace(_ id: String) async -> (BrowserMobileWorkspace, MobileActivityEngine) {
        let pair = makeWorkspace(id)
        await pair.0.restore()
        #expect(pair.0.isReady)
        return pair
    }

    func scenes(loader: (@MainActor () async throws -> BrowserMobileProfileDocument)? = nil)
    -> BrowserMobileSceneSessions {
        let scenes = BrowserMobileSceneSessions { [unowned self] id in
            let (workspace, engine) = makeWorkspace(id, loader: loader)
            return .init(workspace: workspace, contentView: engine.hostView)
        }
        sceneRegistries.append(scenes)
        return scenes
    }

    func activity(_ id: String) -> TimeInterval? { document.snapshot.tabs.first { $0.id == id }?.lastActivityTimestamp }
    func date(_ timestamp: TimeInterval) -> String { ISO8601DateFormatter()
        .string(from: Date(timeIntervalSince1970: timestamp))
    }

    func queue() throws -> [BrowserSyncQueuedMutation] { try store.pendingSyncQueue(for: owner) }
    func batches() throws -> [[BrowserSyncFolderOperation]] {
        try queue().map {
            guard case .folders(let mutation) = $0 else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return mutation.operations
        }
    }

    func operations() throws -> [BrowserSyncFolderOperation] { try batches().flatMap(\.self) }
    func lastOperations() throws -> [BrowserSyncFolderOperation] { try #require(try batches().last) }
    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func queueBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { try Data.fetchAll(
            $0,
            sql: "SELECT payload FROM browser_sync_outbox ORDER BY position",
        ) }
    }

    func stop() async {
        for workspace in workspaces {
            _ = await workspace.shutdown()
        }
        for scenes in sceneRegistries {
            await scenes.waitForPendingOperations()
        }
        sceneRegistries.removeAll()
        workspaces.removeAll()
        preferences.removePersistentDomain(forName: preferencesName)
    }
}

// MARK: - MobileActivityEngine

@MainActor private final class MobileActivityEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var closed = [String]()

    func createTab(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func navigate(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func selectTab(id _: String?) {}
    func closeTab(id: String) { closed.append(id)
        onEvent?(.closed(id: id))
    }

    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() {}
}

// MARK: - MobileActivityLoadGate

@MainActor private final class MobileActivityLoadGate {
    // MARK: Internal

    let document: BrowserMobileProfileDocument
    var continuation: CheckedContinuation<BrowserMobileProfileDocument, Never>?
    var waiter: CheckedContinuation<Void, Never>?

    init(document: BrowserMobileProfileDocument) { self.document = document }

    func load() async -> BrowserMobileProfileDocument {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilHeld() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() { let pending = continuation
        continuation = nil
        pending?.resume(returning: document)
    }
}

private func activityTab(
    _ tab: BrowserTabSessionSnapshotTab,
    url: String? = nil,
    timestamp: TimeInterval,
) -> BrowserTabSessionSnapshotTab {
    .init(
        id: tab.id,
        urlString: url ?? tab.urlString,
        pinnedURLString: tab.pinnedURLString,
        userTitleOverride: tab.userTitleOverride,
        placement: tab.placement,
        spaceID: tab.spaceID,
        pinnedFolderID: tab.pinnedFolderID,
        lastActivityTimestamp: timestamp,
        pinnedSiblingRank: tab.pinnedSiblingRank,
    )
}

private func activityEvents(_ changes: [BrowserSyncChange], startingAt: Int = 1) throws -> [BrowserSyncEvent] {
    try changes.enumerated().map { offset, change in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
        var payload = object["data"] as? [String: Any] ?? [:]
        payload["id"] = change.entityID
        let wire: [String: Any] = [
            "serverSeq": startingAt + offset,
            "deviceID": NSNull(),
            "entityType": change.entityType.rawValue,
            "entityID": change.entityID,
            "op": change.op.rawValue,
            "data": payload,
            "createdAt": "2026-10-03T00:00:00Z",
        ]
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
    }
}

@MainActor private func withMobileActivityFixture(_ body: (MobileActivityFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileActivity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runMobileActivityFixture(directory: directory, body)
}

@MainActor private func runMobileActivityFixture(
    directory: URL,
    _ body: (MobileActivityFixture) async throws -> Void,
) async throws {
    let fixture = try MobileActivityFixture(directory: directory)
    do {
        try await body(fixture)
    } catch {
        await fixture.stop()
        throw error
    }
    await fixture.stop()
}
