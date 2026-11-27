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

    @Test func selectingRecordsMobileTabActivityForBothTabsOnlyWhileTheWindowIsActive() async throws {
        try await withMobileActivityFixture { f in
            let (workspace, engine) = await f.workspace("first")
            workspace.setSceneAttached(true)
            workspace.selectTab(id: "ma")
            #expect(f.mobileActivity("ma") == 100, "An inactive window records nothing")
            f.clock.now = 200
            workspace.setActivityActive(true)
            #expect(f.mobileActivity("ma") == 200)
            let runtimes = workspace.tabs.map(\.runtimeID)
            f.clock.now = 210.9
            workspace.selectTab(id: "mb")
            #expect(f.mobileActivity("ma") == 210 && f.mobileActivity("mb") == 210)
            #expect(workspace.tabs.map(\.runtimeID) == runtimes && engine.closed.isEmpty)
            let saved = try f.store.loadMobileTabs()
            workspace.selectTab(id: "mb")
            workspace.setActivityActive(true)
            #expect(
                try f.store.loadMobileTabs() == saved,
                "Same-second selection and duplicate lifecycle delivery do not write",
            )
            f.clock.now = 230
            workspace.setActivityActive(false)
            #expect(f.mobileActivity("mb") == 230)
            f.clock.now = 240
            workspace.selectTab(id: "mc")
            #expect(f.mobileActivity("mc") == 80, "An inactive window records nothing")
            #expect(try f.store.loadMobileTabs()?.first { $0.id == "mb" }?.record.lastActivityAt == f.moment(230))
            #expect(f.document.protectedTabIDs.isEmpty, "Mobile tabs never hold Space tabs back from the Archive")
            #expect(try f.queue().isEmpty, "Mobile tabs never write Spaces")
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
            if disconnectBeforeRestore {
                scenes.disconnect(connection)
            }
            f.clock.now = 600
            gate.release()
            await scenes.waitForPendingOperations()
            #expect(connection.workspace.isReady)
            let selected = try #require(connection.workspace.selectedTabID)
            if disconnectBeforeRestore {
                #expect(f.mobileActivity(selected) != 600)
                let replacement = try await scenes.connect(sessionID: "delayed")
                scenes.setActive(true, for: connection)
                #expect(f.mobileActivity(selected) != 600, "A stale connection records nothing")
                scenes.setActive(true, for: replacement)
            }
            #expect(f.mobileActivity(selected) == 600)
            #expect(try f.queue().isEmpty)
            scenes.discard(sessionIDs: ["delayed"])
            await scenes.waitForPendingOperations()
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
        let created = Date(timeIntervalSince1970: 10)
        try store.saveMobileTabs([("ma", 100.0), ("mb", 50), ("mc", 80)].map { id, activity in
            .init(id: id, record: .init(
                urlString: "https://activity.example/mobile-" + id, createdAt: created,
                lastActivityAt: Date(timeIntervalSince1970: activity),
            ))
        })
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
    func mobileActivity(_ id: String) -> TimeInterval? {
        document.mobileTab(id: id)?.record.lastActivityAt?.timeIntervalSince1970
    }

    func moment(_ timestamp: TimeInterval) -> Date { Date(timeIntervalSince1970: timestamp) }
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
