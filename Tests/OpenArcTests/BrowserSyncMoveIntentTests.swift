import Foundation
import GRDB
import Testing

@Test func explicitMovePersistsActualDraggedTabAndRebasesItAcrossRemoteMove() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let original = moveSnapshot(["a", "b", "c"].map { moveTab($0) })
    let store = try harness.seed(original)
    let desired = moveSnapshot(["b", "a", "c"].map { moveTab($0) })
    store.saveSnapshot(desired, syncMove: .init(tabIDs: ["a"]))
    let mutation = try harness.firstMutation(store)
    #expect(mutation.operations == [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "one", placement: .temporary), beforeID: "c", afterID: "b"),
    ])
    let frozen = try harness.payloads()
    // The other device moved A to another Space and navigated it. Replaying the
    // user's intent moves A back, preserving the new URL; B is never moved.
    let remote = moveSnapshot([
        moveTab("b"), moveTab("c"), moveTab("a", space: "two", url: "https://remote.example"),
    ])
    let rebased = try store.applyRemoteSyncEvents(moveEvents(remote, sequence: 100), cursor: 104, for: harness.owner)
    #expect(rebased.tabs.filter { $0.spaceID == "one" }.map(\.id) == ["b", "a", "c"])
    #expect(rebased.tabs.first { $0.id == "a" }?.urlString == "https://remote.example")
    #expect(try harness.payloads() == frozen)
    let reopened = try harness.store()
    #expect(try harness.firstMutation(reopened) == mutation)
    #expect(try harness.payloads() == frozen)
    // A lost ACK survives reopen with the same identity, payload and move target.
    let accepted = moveSnapshot([moveTab("b"), moveTab("a", url: "https://remote.example"), moveTab("c")])
    _ = try reopened.acknowledgeSyncMutation(
        id: mutation.id, protocolVersion: 3, events: moveEvents(accepted, sequence: 200), for: harness.owner
    )
    #expect(try reopened.pendingSyncQueue(for: harness.owner).isEmpty)
    #expect(reopened.loadSnapshot()?.tabs.map(\.id) == ["b", "a", "c"])
}

@Test func explicitMoveGroupsOnlyActedOnTabsAndKeepsMetadataCreatesAndDeletes() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let store = try harness.seed(moveSnapshot(["a", "b", "c", "d", "removed"].map { moveTab($0) }))
    let desired = moveSnapshot([
        moveTab("b", title: "Renamed"), moveTab("d"), moveTab("a"), moveTab("new"), moveTab("c"),
    ])
    store.saveSnapshot(desired, syncMove: .init(tabIDs: ["d", "a", "new", "missing"]))
    let operations = try harness.firstMutation(store).operations
    #expect(moveOperations(operations) == [
        .moveTabs(
            ids: ["d", "a"],
            destination: .init(spaceID: "one", placement: .temporary),
            beforeID: "new",
            afterID: "b"
        ),
    ])
    #expect(operations.contains(.patchTab(id: "b", fields: .init(userTitleOverride: .set("Renamed")))))
    #expect(operations.contains(.deleteTab(id: "removed")))
    #expect(operations.contains { operation in
        if case .createTab(id: "new", data: _, beforeID: _, afterID: _) = operation {
            return true
        }
        return false
    })
    let projected = try store.applyRemoteSyncEvents([], cursor: 0, for: harness.owner)
    #expect(projected.tabs.map(\.id) == desired.tabs.map(\.id))
    #expect(projected.tabs.first?.userTitleOverride == "Renamed")
}

@Test func explicitMoveSplitsFinalContiguousBlocksAndPinDestinations() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let original = moveSnapshot(["a", "b", "c", "d", "e"].map { moveTab($0) })
    let store = try harness.seed(original)
    let desired = moveSnapshot([
        moveTab("b"), moveTab("a"), moveTab("c"), moveTab("d"),
        moveTab("e", space: "two", placement: .spacePinned, home: "https://e.example"),
    ])
    store.saveSnapshot(desired, syncMove: .init(tabIDs: ["a", "d", "e"]))
    let moves = try moveOperations(harness.firstMutation(store).operations)
    #expect(moves == [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "one", placement: .temporary), beforeID: "c", afterID: "b"),
        .moveTabs(ids: ["d"], destination: .init(spaceID: "one", placement: .temporary), afterID: "c"),
        .moveTabs(ids: ["e"], destination: .init(spaceID: "two", placement: .spacePinned)),
    ])
    let remote = moveSnapshot([
        moveTab("a"), moveTab("b"), moveTab("c"), moveTab("d"), moveTab("e", url: "https://latest.example"),
    ])
    let projected = try store.applyRemoteSyncEvents(moveEvents(remote, sequence: 100), cursor: 106, for: harness.owner)
    let pin = try #require(projected.tabs.first { $0.id == "e" })
    #expect(pin.placement == .spacePinned)
    #expect(pin.pinnedURLString == "https://latest.example")
}

@Test func explicitMoveGlobalFavoritesKeepPerTabHistoricalSpaceAndGlobalAnchors() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let original = moveSnapshot([
        moveTab("a", placement: .app), moveTab("b", space: "two", placement: .app), moveTab("c", placement: .app),
    ])
    let store = try harness.seed(original)
    let desired = moveSnapshot([
        moveTab("c", placement: .app), moveTab("a", placement: .app), moveTab("b", space: "two", placement: .app),
    ])
    store.saveSnapshot(desired, syncMove: .init(tabIDs: ["a", "b"]))
    #expect(try moveOperations(harness.firstMutation(store).operations) == [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "one", placement: .app), afterID: "c"),
        .moveTabs(ids: ["b"], destination: .init(spaceID: "two", placement: .app), afterID: "a"),
    ])
    let projected = try store.applyRemoteSyncEvents([], cursor: 0, for: harness.owner)
    #expect(projected.tabs.map(\.id) == ["c", "a", "b"])
    #expect(projected.tabs.first { $0.id == "b" }?.spaceID == "two")
}

@Test func explicitMoveFolderOnlyActionRetainsIntentButIdenticalSnapshotIsNoOp() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let folders = [BrowserPinnedTabFolderSessionSnapshot(id: "folder", spaceID: "one", title: "Folder")]
    let original = moveSnapshot([
        moveTab("a", placement: .spacePinned, home: "https://a.example"),
        moveTab("b", placement: .spacePinned, home: "https://b.example"),
    ], folders: folders)
    let store = try harness.seed(original)
    store.saveSnapshot(original, syncMove: .init(tabIDs: ["a"]))
    #expect(try store.pendingSyncQueue(for: harness.owner).isEmpty)
    let grouped = moveSnapshot([
        moveTab("a", placement: .spacePinned, home: "https://a.example", folder: "folder"),
        moveTab("b", placement: .spacePinned, home: "https://b.example"),
    ], folders: folders)
    store.saveSnapshot(grouped, syncMove: .init(tabIDs: ["a"]))
    #expect(try harness.firstMutation(store).operations == [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "one", placement: .spacePinned), beforeID: "b"),
    ])
    let projected = try store.applyRemoteSyncEvents([], cursor: 0, for: harness.owner)
    #expect(projected.tabs.first?.pinnedFolderID == "folder")
    #expect(projected.pinnedTabFolders == folders)
}

@Test func explicitMoveDropsDeletedAndAbsentIDsAndRejectsDuplicatesAtomically() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let store = try harness.seed(moveSnapshot(["a", "b", "c"].map { moveTab($0) }))
    _ = try store.applyRemoteSyncEvents([
        BrowserSyncEvent(
            serverSeq: 100,
            deviceID: nil,
            entityType: "tab",
            entityID: "a",
            op: "delete",
            data: .deleted(id: "a"),
            createdAt: ""
        ),
    ], cursor: 100, for: harness.owner)
    let surviving = try #require(store.loadSnapshot())
    store.saveSnapshot(
        moveSnapshot(["c", "a", "b"].map { moveTab($0) }),
        syncMove: .init(tabIDs: ["a", "c", "missing"])
    )
    let pending = try harness.firstMutation(store)
    #expect(moveOperations(pending.operations) == [
        .moveTabs(ids: ["c"], destination: .init(spaceID: "one", placement: .temporary), beforeID: "b"),
    ])
    #expect(store.loadSnapshot()?.tabs.map(\.id) == ["c", "b"])
    let before = try harness.payloads()
    store.saveSnapshot(surviving, syncMove: .init(tabIDs: ["b", "b"]))
    #expect(try harness.payloads() == before)
    #expect(store.loadSnapshot()?.tabs.map(\.id) == ["c", "b"])
}

@Test func explicitMoveLegacyFallbackAndStorageFailurePreserveFrozenRows() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let original = moveSnapshot(["a", "b", "c"].map { moveTab($0) })
    let store = try harness.seed(original, semantic: false)
    let desired = moveSnapshot(["b", "a", "c"].map { moveTab($0) })
    store.saveSnapshot(desired, syncMove: .init(tabIDs: ["a"]))
    let legacy = try store.pendingSyncQueue(for: harness.owner)
    #expect(legacy.count == 1)
    #expect(legacy.first?.protocolVersion == 2)
    let frozen = try harness.payloads()
    try store.enableSemanticSyncMutations(for: harness.owner)
    try harness.database().write { db in
        try db
            .execute(
                sql: "CREATE TRIGGER fail_intent BEFORE INSERT ON browser_sync_outbox BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
    }
    store.saveSnapshot(original, syncMove: .init(tabIDs: ["a"]))
    #expect(store.loadSnapshot() == desired)
    #expect(try store.pendingSyncQueue(for: harness.owner) == legacy)
    #expect(try harness.payloads() == frozen)
}

@Test func explicitMoveChunksLargeGroupsWithoutReversingOrderOrUsingOwnAnchors() throws {
    let harness = try MoveIntentHarness()
    defer { harness.cleanup() }
    let group = (0..<1001).map { "tab-\($0)" }
    let original = moveSnapshot((group + ["anchor"]).map { moveTab($0) })
    let store = try harness.seed(original)
    let desired = moveSnapshot((["anchor"] + group).map { moveTab($0) })
    store.saveSnapshot(desired, syncMove: .init(tabIDs: group))
    let moves = try moveOperations(harness.firstMutation(store).operations)
    #expect(moves == [
        .moveTabs(
            ids: Array(group.prefix(1000)),
            destination: .init(spaceID: "one", placement: .temporary),
            afterID: "anchor"
        ),
        .moveTabs(ids: [group[1000]], destination: .init(spaceID: "one", placement: .temporary), afterID: group[999]),
    ])
    let projected = try store.applyRemoteSyncEvents([], cursor: 0, for: harness.owner)
    #expect(projected.tabs.map(\.id) == desired.tabs.map(\.id))
}

// MARK: - MoveIntentHarness

private struct MoveIntentHarness {
    // MARK: Lifecycle

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("move-intent-\(UUID().uuidString)")
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "owner")

    var databaseURL: URL { directory.appendingPathComponent("test.sqlite") }

    func store() throws -> BrowserSQLiteSessionStore { try BrowserSQLiteSessionStore(databaseURL: databaseURL) }
    func database() throws -> DatabaseQueue { try DatabaseQueue(path: databaseURL.path) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func seed(_ snapshot: BrowserTabSessionSnapshot, semantic: Bool = true) throws -> BrowserSQLiteSessionStore {
        let store = try store()
        try store.bindSyncOwner(owner)
        _ = try store.applyRemoteSyncEvents(
            moveEvents(snapshot, sequence: 1),
            cursor: snapshot.tabs.count + 2,
            for: owner,
            enableSemanticMutations: semantic
        )
        // Local folders are absent from the server event schema.
        store.saveRemoteProjectionSnapshot(snapshot)
        return store
    }

    func firstMutation(_ store: BrowserSQLiteSessionStore) throws -> BrowserSyncSemanticMutation {
        let first = try #require(store.pendingSyncQueue(for: owner).first)
        guard case .semantic(let mutation) = first else { throw MoveIntentTestError.expectedSemantic }
        return mutation
    }

    func payloads() throws -> [Data] {
        try database().read { db in try Data.fetchAll(
            db,
            sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"
        ) }
    }
}

// MARK: - MoveIntentTestError

private enum MoveIntentTestError: Error { case expectedSemantic }

private func moveOperations(_ operations: [BrowserSyncSemanticOperation]) -> [BrowserSyncSemanticOperation] {
    operations.filter {
        if case .moveTabs = $0 {
            return true
        }
        return false
    }
}

private func moveSnapshot(
    _ tabs: [BrowserTabSessionSnapshotTab],
    folders: [BrowserPinnedTabFolderSessionSnapshot]? = nil
) -> BrowserTabSessionSnapshot {
    BrowserTabSessionSnapshot(spaces: ["one", "two"].map {
        BrowserSpaceSessionSnapshot(id: $0, title: $0, systemImageName: "circle")
    }, pinnedTabFolders: folders, tabs: tabs)
}

private func moveTab(
    _ id: String, space: String = "one", url: String? = nil, title: String? = nil,
    placement: BrowserTabPlacement = .temporary, home: String? = nil, folder: String? = nil
) -> BrowserTabSessionSnapshotTab {
    BrowserTabSessionSnapshotTab(
        id: id,
        urlString: url ?? "https://\(id).example",
        pinnedURLString: home,
        userTitleOverride: title,
        placement: placement,
        spaceID: space,
        pinnedFolderID: folder
    )
}

private func moveEvents(_ snapshot: BrowserTabSessionSnapshot, sequence: Int) -> [BrowserSyncEvent] {
    BrowserSyncOutboxProjection.canonicalChanges(snapshot).enumerated().map { index, change in
        let data: BrowserSyncEventData =
            if let space = change.spaceData {
                .space(.init(
                    id: change.entityID,
                    title: space.title,
                    systemImageName: space.systemImageName,
                    rank: space.rank,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                    selectedTabID: space.selectedTabID
                ))
            } else if let tab = change.tabData {
                .tab(.init(
                    id: change.entityID,
                    spaceID: tab.spaceID,
                    placement: tab.placement,
                    rank: tab.rank,
                    urlString: tab.urlString,
                    pinnedURLString: tab.pinnedURLString,
                    title: tab.title,
                    userTitleOverride: tab.userTitleOverride,
                    faviconURLString: tab.faviconURLString,
                    lastActivityAt: tab.lastActivityAt
                ))
            } else {
                .unknown
            }
        return BrowserSyncEvent(
            serverSeq: sequence + index,
            deviceID: "remote",
            entityType: change.entityType.rawValue,
            entityID: change.entityID,
            op: change.op.rawValue,
            data: data,
            createdAt: ""
        )
    }
}
