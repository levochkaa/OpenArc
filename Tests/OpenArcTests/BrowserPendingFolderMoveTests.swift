// BrowserPendingFolderMoveTests.swift

import Foundation
import Testing

// MARK: - BrowserPendingFolderMoveTests

@Suite(.serialized)
@MainActor struct BrowserPendingFolderMoveTests {
    @Test(arguments: [0, 1]) func folderMoveKeepsPendingDescendantsAndJournalsOnlyRoot(deliveredChildren: Int) throws {
        let f = try PendingFolderFixture()
        defer { f.cleanup() }
        try f.receive(f.folderSnapshot())
        let children = Array(f.driver.createdTabRequests.suffix(2))
        for child in children.prefix(deliveredChildren) {
            f.deliver(child)
        }
        let selected = f.model.selectedTabID
        f.model.movePinnedTabFolder(withID: "folder", toRootSectionIndex: 0, targetSpaceID: "target")
        let saved = try #require(f.store.loadSnapshot())
        for id in ["child", "nested-child"] {
            #expect(saved.tabs.first { $0.id == id }?.spaceID == "target")
            #expect(saved.tabs.first { $0.id == id }?.pinnedFolderID == (id == "child" ? "folder" : "nested"))
        }
        #expect(f.model.tabs.count(where: { ["child", "nested-child"].contains($0.syncID) }) == deliveredChildren)
        #expect(try f.operations() == [.move(
            items: [.init(entityType: .folder, entityID: "folder")],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil),
        )])
        let frozen = try f.store.pendingSyncQueue(for: f.owner)
        for child in children.dropFirst(deliveredChildren) {
            f.deliver(child)
        }
        #expect(f.model.tabs.filter { ["child", "nested-child"].contains($0.syncID) }.allSatisfy {
            $0.spaceID == "target" && $0.pinnedFolderID != nil
        })
        #expect(f.model.selectedTabID == selected)
        #expect(try f.store.pendingSyncQueue(for: f.owner) == frozen)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.pendingSyncQueue(for: f.owner) == frozen)
        #expect(reopened.loadSnapshot()?.tabs.first { $0.id == "nested-child" }?.spaceID == "target")
    }

    @Test func folderMoveThenDeleteCancelsOnlyCurrentPendingSubtree() throws {
        let f = try PendingFolderFixture()
        defer { f.cleanup() }
        try f.receive(f.folderSnapshot())
        let requests = Array(f.driver.createdTabRequests.suffix(2))
        // Another device moves one still-pending child out before the local move.
        var escaped = try #require(f.store.loadSnapshot())
        escaped = .init(spaces: escaped.spaces, pinnedTabFolders: escaped.pinnedTabFolders, tabs: escaped.tabs.map {
            guard $0.id == "child" else { return $0 }
            return f.tab("child", space: "source", rank: 2)
        })
        try f.receive(escaped)
        f.model.movePinnedTabFolder(withID: "folder", toRootSectionIndex: 0, targetSpaceID: "target")
        #expect(f.model.deletePinnedTabFolder(id: "folder"))
        let beforeCallbacks = try #require(f.store.loadSnapshot())
        #expect(beforeCallbacks.tabs
            .contains { $0.id == "child" && $0.spaceID == "source" && $0.pinnedFolderID == nil })
        #expect(!beforeCallbacks.tabs.contains { $0.id == "nested-child" })
        #expect(beforeCallbacks.tabs.contains { $0.id == "favorite" })
        #expect(try f.operations()
            .count(where: {
                if case .deleteFolder(id: "folder") = $0 {
                    true
                } else {
                    false
                }
            })
            == 1)
        #expect(try !f.operations().contains {
            if case .deleteTab = $0 {
                true
            } else {
                false
            }
        })
        let frozen = try f.store.pendingSyncQueue(for: f.owner)
        for request in requests {
            let canceled = request.urlString.hasSuffix("/nested-child")
            if canceled {
                f.driver.emitClose(id: request.id)
            }
            f.deliver(request)
            if canceled {
                f.driver.emitClose(id: request.id)
            }
        }
        #expect(f.store.loadSnapshot()?.tabs.contains { $0.id == "nested-child" } == false)
        #expect(f.model.tabs.contains { $0.syncID == "child" && $0.spaceID == "source" && $0.pinnedFolderID == nil })
        #expect(f.model.pinnedTabFolders.isEmpty)
        #expect(try f.store.pendingSyncQueue(for: f.owner) == frozen)
    }

    @Test func dragUsesPendingSiblingRankInsteadOfMovingTheWrongNeighbor() throws {
        let f = try PendingFolderFixture()
        defer { f.cleanup() }
        let initial = try #require(f.store.loadSnapshot())
        try f.receive(.init(spaces: initial.spaces, tabs: [
            f.tab("favorite", placement: .app), f.tab("p", rank: 0), f.tab("a", rank: 1), f.tab("b", rank: 2),
        ]))
        let request = try #require(f.driver.createdTabRequests.last)
        let a = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(f.model.commitSidebarDrop(
            payload: .init(primary: .tab(a.id), tabIDs: [a.id]), destination: .init(container: .pinned("source")),
        ))
        let moves = try f.operations().filter {
            if case .move = $0 {
                true
            } else {
                false
            }
        }
        #expect(moves == [.move(
            items: [.init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: nil),
            after: .init(entityType: .tab, entityID: "b"),
        )])
        let saved = try #require(f.store.loadSnapshot())
        #expect(BrowserSyncFolderProjection.canonicalChanges(saved)
            .filter { $0.tabData?.placement == .spacePinned }
            .map(\.entityID) == ["p", "b", "a"])
        let frozen = try f.store.pendingSyncQueue(for: f.owner)
        f.deliver(request)
        #expect(try f.store.pendingSyncQueue(for: f.owner) == frozen)
        #expect(f.model.tabs.first { $0.syncID == "p" }?.pinnedSiblingRank == 0)
    }

    @Test func folderMovePreservesAbsentPendingActivityWithoutMetadataEcho() throws {
        let f = try PendingFolderFixture()
        defer { f.cleanup() }
        let incoming = f.folderSnapshot()
        let pendingIDs: Set = ["child", "nested-child", "unrelated"]
        let allTabs = incoming.tabs + [f.tab("unrelated", placement: .temporary)]
        let noActivity = allTabs.map { tab in
            guard pendingIDs.contains(tab.id ?? "") else { return tab }
            return BrowserTabSessionSnapshotTab(
                id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: nil,
                pinnedSiblingRank: tab.pinnedSiblingRank,
            )
        }
        try f.receive(.init(spaces: incoming.spaces, pinnedTabFolders: incoming.pinnedTabFolders, tabs: noActivity))
        let requests = Array(f.driver.createdTabRequests.suffix(3))
        f.model.movePinnedTabFolder(withID: "folder", toRootSectionIndex: 0, targetSpaceID: "target")
        let saved = try #require(f.store.loadSnapshot())
        #expect(saved.tabs.count(where: { pendingIDs.contains($0.id ?? "") }) == 3)
        #expect(saved.tabs.filter { pendingIDs.contains($0.id ?? "") }.allSatisfy { $0.lastActivityTimestamp == nil })
        #expect(saved.tabs.first { $0.id == "unrelated" }?.spaceID == "source")
        #expect(try f.operations() == [.move(
            items: [.init(entityType: .folder, entityID: "folder")],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil),
        )])
        let frozen = try f.store.pendingSyncQueue(for: f.owner)
        for request in requests {
            f.deliver(request)
        }
        #expect(try f.store.pendingSyncQueue(for: f.owner) == frozen)
    }

    @Test func deletingFolderCancelsOrdinaryEagerPlaceholderBeforeItsCallback() throws {
        let f = try PendingFolderFixture()
        defer { f.cleanup() }
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/ordinary")))
        let request = try #require(f.driver.createdTabRequests.last)
        let tab = try #require(f.model.tabs.first { $0.id == request.id })
        let folder = try #require(f.model.createPinnedTabFolder(containingTabIDs: [tab.id]))
        #expect(f.model.deletePinnedTabFolder(id: folder))
        let frozen = try f.store.pendingSyncQueue(for: f.owner)
        f.driver.emitClose(id: request.id)
        f.deliver(request)
        f.driver.emitClose(id: request.id)
        #expect(!f.model.tabs.contains { $0.id == request.id })
        #expect(f.store.loadSnapshot()?.tabs.contains { $0.id == tab.syncID } == false)
        #expect(try f.store.pendingSyncQueue(for: f.owner) == frozen)
    }
}

// MARK: - PendingFolderFixture

@MainActor private final class PendingFolderFixture {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PendingFolder-\(UUID())")
    let suite = "PendingFolder.\(UUID())"
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "owner")
    let store: BrowserSQLiteSessionStore
    let driver = FakeBrowserTabDriver()
    let model: BrowserChromeModel

    // MARK: Private

    private var sequence = 100

    var databaseURL: URL { directory.appendingPathComponent("Browser.sqlite") }

    init() throws {
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Browser.sqlite"))
        let initial = BrowserTabSessionSnapshot(spaces: [
            .init(id: "source", title: "Source", systemImageName: "globe"),
            .init(id: "target", title: "Target", systemImageName: "star"),
        ], tabs: [
            Self.tab("favorite", placement: .app), Self.tab("a", rank: 0), Self.tab("b", rank: 1),
        ])
        try store.bindSyncOwner(owner)
        _ = try store.completeFolderSyncBootstrap(events: Self.events(initial, start: 1), cursor: 5, for: owner)
        let defaults = try #require(UserDefaults(suiteName: suite))
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) }, windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        model.selectSpace(id: "source")
    }

    private static func tab(
        _ id: String,
        space: String = "source",
        folder: String? = nil,
        placement: BrowserTabPlacement = .spacePinned,
        rank: Double = 0,
    ) -> BrowserTabSessionSnapshotTab {
        .init(
            id: id,
            urlString: "https://example.com/\(id)",
            pinnedURLString: placement == .spacePinned
                ? "https://example.com/\(id)"
                : nil,
            userTitleOverride: id,
            placement: placement,
            spaceID: space,
            pinnedFolderID: folder,
            lastActivityTimestamp: 1_800_000_000,
            pinnedSiblingRank: placement == .spacePinned ? rank : nil,
        )
    }

    private static func events(_ snapshot: BrowserTabSessionSnapshot, start: Int) throws -> [BrowserSyncEvent] {
        try BrowserSyncFolderProjection.canonicalChanges(snapshot).enumerated().map { offset, change in
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
            var data = object["data"] as! [String: Any]
            data["id"] = change.entityID
            let envelope: [String: Any] = [
                "serverSeq": start + offset, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
                "entityID": change.entityID, "op": "upsert", "data": data, "createdAt": "2026-10-03T00:00:00Z",
            ]
            return try JSONDecoder().decode(
                BrowserSyncEvent.self,
                from: JSONSerialization.data(withJSONObject: envelope),
            )
        }
    }

    func cleanup() {
        model.prepareForTermination()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func tab(
        _ id: String,
        space: String = "source",
        folder: String? = nil,
        placement: BrowserTabPlacement = .spacePinned,
        rank: Double = 0,
    ) -> BrowserTabSessionSnapshotTab {
        Self.tab(id, space: space, folder: folder, placement: placement, rank: rank)
    }

    func folderSnapshot() -> BrowserTabSessionSnapshot {
        let current = store.loadSnapshot()!
        return .init(spaces: current.spaces, pinnedTabFolders: [
            .init(id: "folder", spaceID: "source", title: "Folder", pinnedSiblingRank: 2),
            .init(id: "nested", spaceID: "source", parentFolderID: "folder", title: "Nested", pinnedSiblingRank: 1),
        ], tabs: current.tabs + [tab("child", folder: "folder"), tab("nested-child", folder: "nested")])
    }

    func receive(_ snapshot: BrowserTabSessionSnapshot) throws {
        let events = try Self.events(snapshot, start: sequence)
        sequence += events.count
        let projected = try store.applyRemoteSyncEvents(events, cursor: sequence - 1, for: owner)
        model.applyRemoteSyncSnapshot(projected)
    }

    func deliver(_ request: FakeBrowserTabDriver.CreatedTabRequest) {
        driver.emitCreatedTab(id: request.id, urlString: request.urlString, isActive: request.isActive)
    }

    func operations() throws -> [BrowserSyncFolderOperation] {
        try store.pendingSyncQueue(for: owner).flatMap { row in
            guard case .folders(let mutation) = row else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return mutation.operations
        }
    }
}
