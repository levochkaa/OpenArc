// BrowserMobileMobileTabsTests.swift

import Foundation
import Testing
import UIKit

// MARK: - BrowserMobileMobileTabsTests

@Suite(.serialized)
@MainActor struct BrowserMobileMobileTabsTests {
    @Test func aFreshProfileStartsWithOneBlankTabThatStaysOnTheDevice() async throws {
        let f = try MobileTabsFixture(spaces: false)
        defer { f.cleanup() }
        let scene = f.workspace("scene")
        await scene.workspace.restore()
        #expect(scene.workspace.spaces.isEmpty, "A fresh profile has no Space")
        #expect(scene.workspace.tabs.count == 1)
        #expect(scene.workspace.selectedTab?.urlString == "about:blank")
        #expect(f.document.mobileTabs.map(\.record.urlString) == ["about:blank"])
        f.document.flushMobileTabSync()
        #expect(try f.queuedOperations().isEmpty, "A blank tab never syncs")
        #expect(await scene.workspace.shutdown())
    }

    @Test func editsSaveAtOnceAndQueueOneWriteAfterThePause() throws {
        let f = try MobileTabsFixture()
        defer { f.cleanup() }
        let id = try #require(f.document.createMobileTab(urlString: "https://example.com/a"))
        #expect(try f.sqlite.loadMobileTabs()?.map(\.id) == [id], "The list saves before sync hears of it")
        #expect(try f.queuedOperations().isEmpty, "Writes wait for a pause")
        #expect(f.document.setMobileTabTitle(id: id, title: "A"))
        #expect(f.document.updateMobileTab(id: id, urlString: "https://example.com/b"))
        f.document.flushMobileTabSync()
        let operations = try f.queuedOperations()
        #expect(operations.count == 1)
        guard case .upsert(id, let record) = operations.first else {
            Issue.record("The pause queues one upsert")
            return
        }
        #expect(record.urlString == "https://example.com/b")
        #expect(record.title == nil, "A new address drops the old page's title")
        f.document.flushMobileTabSync()
        #expect(try f.queuedOperations().count == 1, "Nothing changed since")

        let reopened = try BrowserMobileProfileDocument(store: f.sqlite, initialSnapshot: f.sqlite.loadSnapshotStrict())
        #expect(reopened.mobileTabs == f.document.mobileTabs)
    }

    @Test func syncedTabsJoinChangeAndLeaveTheList() throws {
        let f = try MobileTabsFixture()
        defer { f.cleanup() }
        let local = try #require(f.document.createMobileTab(urlString: "https://example.com/local"))
        f.document.flushMobileTabSync()
        try f.acknowledgeQueue()
        let remote = MobileTabsFixture.record("https://example.com/remote", created: 1_800_000_100)
        try f.applyRemote([MobileTabsFixture.event(seq: f.nextSeq(), id: "remote", record: remote)])
        #expect(f.document.mobileTabs.map(\.id) == [local, "remote"], "A tab from another device joins the end")

        let renamed = MobileTabsFixture.record("https://example.com/moved", created: 1_800_000_000)
        try f.applyRemote([
            MobileTabsFixture.event(seq: f.nextSeq(), id: local, record: renamed),
            MobileTabsFixture.event(seq: f.nextSeq(), id: "remote", record: nil),
        ])
        #expect(f.document.mobileTabs.map(\.id) == [local])
        #expect(f.document.mobileTab(id: local)?.record.urlString == "https://example.com/moved")
        #expect(try f.queuedOperations().isEmpty, "Synced changes are not sent back")
    }

    @Test func closingArchivesTheTabEverywhereAndRestoringOpensANewOne() throws {
        let f = try MobileTabsFixture()
        defer { f.cleanup() }
        let id = try #require(f.document.createMobileTab(urlString: "https://example.com/a", title: "A"))
        f.document.flushMobileTabSync()
        try f.acknowledgeQueue()
        let archiveID = try #require(f.document.closeMobileTab(id: id))
        #expect(f.document.mobileTab(id: id) == nil)
        #expect(try f.queuedOperations() == [.delete(id: id)])
        let restored = try #require(f.document.restoreArchivedMobileTab(archiveID: archiveID))
        #expect(restored != id, "A deleted identity never comes back")
        #expect(f.document.mobileTab(id: restored)?.record.urlString == "https://example.com/a")
        #expect(f.document.restoreArchivedMobileTab(archiveID: archiveID) == nil, "Restoring consumes the entry")

        let blank = try #require(f.document.createMobileTab())
        #expect(f.document.closeMobileTab(id: blank) == nil, "A blank tab leaves no archive entry")
        #expect(f.document.mobileTab(id: blank) == nil)
    }

    @Test func spaceTabsOpenAsMobileTabsAndStayOutOfTheSwitcher() async throws {
        let f = try MobileTabsFixture()
        defer { f.cleanup() }
        let scene = f.workspace("scene")
        await scene.workspace.restore()
        let spaceIDs = Set(scene.workspace.spaceTabs.map(\.id))
        #expect(spaceIDs == ["space-tab", "favorite"])
        let tabIDs = Set(scene.workspace.tabs.map(\.id))
        #expect(tabIDs.isDisjoint(with: spaceIDs))
        let runtimes = scene.workspace.spaceTabs.map(\.runtimeID)
        #expect(runtimes == ["", ""], "Space tabs get no page")
        let writes = try f.sqlite.loadSnapshotStrict()

        let opened = try #require(scene.workspace.openSpaceTab(id: "space-tab"))
        #expect(scene.workspace.selectedTabID == opened)
        #expect(f.document.mobileTab(id: opened)?.record.urlString == "https://example.com/space")
        #expect(scene.workspace.switcherTabs.contains { $0.id == opened })
        #expect(scene.workspace.openSpaceTab(id: "space-tab") == opened, "The open tab is selected again")
        let spaceURLs = f.document.mobileTabs.map(\.record.urlString).filter { $0 == "https://example.com/space" }
        #expect(spaceURLs.count == 1)
        #expect(try f.sqlite.loadSnapshotStrict() == writes, "Opening a Space tab leaves Spaces alone")
        // Space tabs never load here: the open page names the ones at its address, on this device only.
        let runtime = try #require(scene.workspace.selectedTab?.runtimeID)
        scene.engine.onEvent?(.state(
            id: runtime,
            .init(url: URL(string: "https://example.com/space"), title: "Space page"),
        ))
        #expect(scene.workspace.spaceTabs.first { $0.id == "space-tab" }?.title == "Space page")
        #expect(f.document.mobileTab(id: opened)?.record.title == "Space page")
        #expect(try f.sqlite.pendingSyncQueue(for: f.owner).isEmpty, "A page title never syncs with Spaces")
        #expect(await scene.workspace.shutdown())
    }

    @Test func pinCopiesThePageIntoASpaceAndTheMobileTabStays() async throws {
        let f = try MobileTabsFixture()
        defer { f.cleanup() }
        let scene = f.workspace("scene")
        await scene.workspace.restore()
        let id = try #require(f.document.createMobileTab(urlString: "https://example.com/pin"))
        scene.workspace.selectTab(id: id)
        let runtime = try #require(scene.workspace.selectedTab?.runtimeID)
        scene.engine.onEvent?(.state(
            id: runtime,
            .init(url: URL(string: "https://example.com/pin"), title: "Pinned page"),
        ))
        #expect(scene.workspace.pinnedSpaceTabID(urlString: "https://example.com/pin") == nil)
        let pinned = try #require(scene.workspace.pinSelectedTab(spaceID: "space"))
        #expect(f.document.snapshot.tabs.first { $0.id == pinned }?.pageTitle == "Pinned page")
        #expect(scene.workspace.pinnedSpaceTabID(urlString: "https://example.com/pin") == pinned)
        #expect(f.document.snapshot.tabs.first { $0.id == pinned }?.spaceID == "space")
        #expect(scene.workspace.selectedTabID == id, "The mobile tab stays selected")
        #expect(await scene.workspace.shutdown())
    }

    @Test func theTabletSidebarListsTheMobileTabsOnly() async throws {
        let f = try MobileTabsFixture()
        defer { f.cleanup() }
        let scene = f.workspace("scene")
        await scene.workspace.restore()
        let second = try #require(f.document.createMobileTab(urlString: "https://example.com/second"))
        let controller = BrowserMobileOpenTabsViewController(workspace: scene.workspace)
        controller.loadViewIfNeeded()
        controller.render()
        let rows = controller.tableView.numberOfRows(inSection: 0)
        #expect(rows == scene.workspace.tabs.count)
        #expect(scene.workspace.tabs.contains { $0.id == second })
        var selected = false
        controller.didSelectTab = { selected = true }
        let index = try #require(scene.workspace.tabs.firstIndex { $0.id == second })
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: index, section: 0))
        #expect(selected && scene.workspace.selectedTabID == second)
        #expect(await scene.workspace.shutdown())
    }
}

// MARK: - MobileTabsFixture

@MainActor private final class MobileTabsFixture {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileTabs-\(UUID())")
    let suite = "MobileTabs.\(UUID())"
    let preferences: UserDefaults
    let sqlite: BrowserSQLiteSessionStore
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.invalid")!, userID: "owner")
    let document: BrowserMobileProfileDocument

    // MARK: Private

    private var seq = 0

    init(spaces: Bool = true) throws {
        self.preferences = try #require(UserDefaults(suiteName: suite))
        self.sqlite = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        var history = [BrowserSyncEvent]()
        if spaces {
            let snapshot = BrowserTabSessionSnapshot(spaces: [
                .init(id: "space", title: "Space", systemImageName: "globe"),
            ], tabs: [
                .init(
                    id: "space-tab", urlString: "https://example.com/space", placement: .spacePinned,
                    spaceID: "space", lastActivityTimestamp: 1_800_000_000,
                ),
                .init(
                    id: "favorite", urlString: "https://example.com/favorite", placement: .app, spaceID: "space",
                    lastActivityTimestamp: 1_800_000_000,
                ),
            ])
            history = try Self.events(BrowserSyncFolderProjection.canonicalChanges(snapshot), startingAt: 1)
        }
        self.seq = history.count
        // The Spaces arrive from the server, so nothing is queued for them.
        try sqlite.bindSyncOwner(owner)
        _ = try sqlite.completeFolderSyncBootstrap(events: history, cursor: seq, for: owner)
        _ = try sqlite.completeExpirySyncBootstrap(events: history, cursor: seq, for: owner)
        _ = try sqlite.completeMobileTabSyncBootstrap(
            events: history, cursor: seq, for: owner, localBoosts: [], localMobileTabs: [],
        )
        var nextID = 0
        self.document = try BrowserMobileProfileDocument(
            store: sqlite, initialSnapshot: sqlite.loadSnapshotStrict(),
            idProvider: {
                nextID += 1
                return "new-\(nextID)"
            },
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) }, mobileTabDebounce: .seconds(3600),
        )
    }

    static func events(_ changes: [BrowserSyncChange], startingAt sequence: Int) throws -> [BrowserSyncEvent] {
        try changes.enumerated().map { offset, change in
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
            var payload = object["data"] as? [String: Any] ?? [:]
            payload["id"] = change.entityID
            let wire: [String: Any] = [
                "serverSeq": sequence + offset, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
                "entityID": change.entityID, "op": change.op.rawValue, "data": payload,
                "createdAt": "2026-11-28T00:00:00Z",
            ]
            return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        }
    }

    static func record(_ url: String, created: TimeInterval) -> BrowserSyncMobileTabRecord {
        .init(urlString: url, createdAt: Date(timeIntervalSince1970: created))
    }

    static func event(seq: Int, id: String, record: BrowserSyncMobileTabRecord?) -> BrowserSyncEvent {
        var wire: [String: Any] = [
            "serverSeq": seq, "deviceID": NSNull(), "entityType": BrowserSyncMobileTabOperation.entityType,
            "entityID": id, "op": record == nil ? "delete" : "upsert", "createdAt": "2026-11-28T00:00:00Z",
        ]
        if let record {
            let data = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(
                BrowserSyncEventMobileTabData(id: id, record: record),
            ))
            wire["data"] = data
        } else {
            wire["data"] = ["id": id]
        }
        return try! JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
    }

    func nextSeq() -> Int {
        seq += 1
        return seq
    }

    func workspace(_ scene: String) -> (workspace: BrowserMobileWorkspace, engine: MobileTabsEngine) {
        let engine = MobileTabsEngine()
        return (
            BrowserMobileWorkspace(engine: engine, sceneID: scene, profileLoader: { [document] in
                document
            }, preferences: preferences),
            engine,
        )
    }

    func queuedOperations() throws -> [BrowserSyncMobileTabOperation] {
        try sqlite.pendingSyncQueue(for: owner).flatMap { row -> [BrowserSyncMobileTabOperation] in
            guard case .mobileTabs(let mutation) = row else { return [] }
            return mutation.operations
        }
    }

    /// Answers every queued mobile tab write as the server would.
    func acknowledgeQueue() throws {
        for row in try sqlite.pendingSyncQueue(for: owner) {
            guard case .mobileTabs(let mutation) = row else { continue }
            let events = mutation.operations.map { operation in
                switch operation {
                case .upsert(let id, let record): Self.event(seq: nextSeq(), id: id, record: record)
                case .delete(let id): Self.event(seq: nextSeq(), id: id, record: nil)
                }
            }
            _ = try sqlite.acknowledgeSyncMutation(id: mutation.id, protocolVersion: 7, events: events, for: owner)
        }
    }

    func applyRemote(_ events: [BrowserSyncEvent]) throws {
        _ = try sqlite.applyRemoteSyncEvents(events, cursor: seq, for: owner)
        document.syncMobileTabsDidChange()
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - MobileTabsEngine

@MainActor private final class MobileTabsEngine: BrowserMobileEngine {
    // MARK: Internal

    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var created = [String]()

    // MARK: Private

    private var records = [String: URL]()

    func createTab(id: String, url: URL) {
        created.append(id)
        records[id] = url
        onEvent?(.state(id: id, .init(url: url)))
    }

    func selectTab(id _: String?) {}
    func navigate(id: String, url: URL) {
        records[id] = url
        onEvent?(.state(id: id, .init(url: url)))
    }

    func closeTab(id: String) {
        records.removeValue(forKey: id)
        onEvent?(.closed(id: id))
    }

    func adoptPopup(id: String, url: URL) {
        records[id] = url
        onPopupCreated?(id, url)
    }

    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() { records.removeAll() }
}
