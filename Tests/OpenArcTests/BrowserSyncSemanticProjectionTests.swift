// BrowserSyncSemanticProjectionTests.swift

import Foundation
import Testing

@Test func semanticProjectionRenameCapturesOnlyChangedMetadataAndExplicitClear() {
    let before = semanticSnapshot([semanticTab("a", title: "Before")])
    let renamed = semanticSnapshot([semanticTab("a", title: "After")])
    #expect(BrowserSyncSemanticProjection.operations(from: before, to: renamed) == [
        .patchTab(id: "a", fields: .init(userTitleOverride: .set("After"))),
    ])
    let cleared = semanticSnapshot([semanticTab("a")])
    #expect(BrowserSyncSemanticProjection.operations(from: renamed, to: cleared) == [
        .patchTab(id: "a", fields: .init(userTitleOverride: .clear)),
    ])
}

@Test func semanticProjectionPendingRenamePreservesRemoteMoveAndNavigation() throws {
    let before = semanticSnapshot([semanticTab("a", title: "Before")], spaces: ["one", "two"])
    let renamed = semanticSnapshot([semanticTab("a", title: "After")], spaces: ["one", "two"])
    let operations = BrowserSyncSemanticProjection.operations(from: before, to: renamed)
    let remote = semanticSnapshot([
        semanticTab("a", space: "two", url: "https://remote.example/", title: "Before", placement: .spacePinned),
    ], spaces: ["one", "two"])
    let result = semanticReplay(remote, operations: operations)
    let tab = try #require(result.tabs.first)
    #expect(tab.spaceID == "two")
    #expect(tab.placement == .spacePinned)
    #expect(tab.urlString == "https://remote.example/")
    #expect(tab.userTitleOverride == "After")
}

@Test func semanticProjectionPendingMoveUsesCanonicalRemoteMetadataAndPinHome() throws {
    let before = semanticSnapshot([semanticTab("a")], spaces: ["one", "two"])
    let moved = semanticSnapshot([
        semanticTab("a", space: "two", placement: .spacePinned, home: "https://a.example/"),
    ], spaces: ["one", "two"])
    let operations = BrowserSyncSemanticProjection.operations(from: before, to: moved)
    #expect(operations == [.moveTabs(ids: ["a"], destination: .init(spaceID: "two", placement: .spacePinned))])
    let remote = semanticSnapshot([
        semanticTab("a", url: "https://new.example/", title: "Remote rename"),
    ], spaces: ["one", "two"])
    let tab = try #require(semanticReplay(remote, operations: operations).tabs.first)
    #expect(tab.userTitleOverride == "Remote rename")
    #expect(tab.urlString == "https://new.example/")
    #expect(tab.pinnedURLString == "https://new.example/")
    #expect(tab.spaceID == "two")
}

@Test func semanticProjectionInsertionDeletionAndRotationDoNotMoveShiftedPeers() {
    let before = semanticSnapshot(["a", "b", "c"].map { semanticTab($0) })
    let inserted = semanticSnapshot(["a", "new", "b", "c"].map { semanticTab($0) })
    let insertion = BrowserSyncSemanticProjection.operations(from: before, to: inserted)
    #expect(insertion.count == 1)
    #expect(insertion.first == .createTab(id: "new", data: .init(
        spaceID: "one", placement: .temporary, urlString: "https://new.example/",
    ), beforeID: "b", afterID: "a"))
    #expect(BrowserSyncSemanticProjection.operations(from: before, to: semanticSnapshot([
        semanticTab("a"), semanticTab("c"),
    ])) == [.deleteTab(id: "b")])
    let rotated = semanticSnapshot(["b", "c", "a"].map { semanticTab($0) })
    #expect(BrowserSyncSemanticProjection.operations(from: before, to: rotated) == [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "one", placement: .temporary), afterID: "c"),
    ])
}

@Test func semanticProjectionNewEntitiesAndMovesResolveToDesiredOrder() {
    // Exercise inserts next to a neighbor that also moves. Anchoring a create to
    // that old neighbor can strand it when the later move removes the anchor.
    let before = semanticSnapshot(["a", "b", "c", "d"].map { semanticTab($0) })
    for permutation in semanticPermutations(["a", "b", "c", "d"]) {
        for insertionIndex in 0...permutation.count {
            var desired = permutation
            desired.insert("new", at: insertionIndex)
            let after = semanticSnapshot(desired.map { semanticTab($0) })
            let operations = BrowserSyncSemanticProjection.operations(from: before, to: after)
            #expect(semanticReplay(before, operations: operations).tabs.compactMap(\.id) == desired)
        }
    }
}

@Test func semanticProjectionScopedListsAndGlobalFavoritesIgnoreFlatteningAndRememberedSpace() {
    let before = semanticSnapshot([
        semanticTab("ordinary-one"), semanticTab("favorite", placement: .app),
        semanticTab("pin", placement: .spacePinned), semanticTab("ordinary-two", space: "two"),
    ], spaces: ["one", "two"])
    let regrouped = semanticSnapshot([
        semanticTab("favorite", space: "two", placement: .app), semanticTab("pin", placement: .spacePinned),
        semanticTab("ordinary-one"), semanticTab("ordinary-two", space: "two"),
    ], spaces: ["one", "two"])
    #expect(BrowserSyncSemanticProjection.operations(from: before, to: regrouped).isEmpty)
    let projected = BrowserSyncOutboxProjection.snapshot(
        baseline: semanticBaseline(before), pending: [BrowserSyncQueuedMutation](), local: before,
    )
    #expect(projected.tabs.compactMap(\.id) == ["favorite", "pin", "ordinary-one", "ordinary-two"])
}

@Test func semanticProjectionMoveOutPrecedesParentDeletionAndRetainsFavorite() throws {
    let before = semanticSnapshot([
        semanticTab("move"), semanticTab("discard"), semanticTab("favorite", placement: .app),
    ], spaces: ["one", "two"])
    let after = semanticSnapshot([
        semanticTab("move", space: "two"), semanticTab("favorite", space: "two", placement: .app),
    ], spaces: ["two"])
    let operations = BrowserSyncSemanticProjection.operations(from: before, to: after)
    let moveIndex = try #require(operations.firstIndex {
        if case .moveTabs = $0 {
            return true
        }
        return false
    })
    let deleteIndex = try #require(operations.firstIndex(of: .deleteSpace(id: "one")))
    #expect(moveIndex < deleteIndex)
    var baseline = semanticBaseline(before)
    baseline.deletedKeys = ["space:one", "tab:discard"]
    let result = BrowserSyncOutboxProjection.snapshot(
        baseline: baseline, pending: [.semantic(.init(id: "move-delete", operations: operations))], local: after,
    )
    #expect(Set(result.tabs.compactMap(\.id)) == ["move", "favorite"])
    #expect(result.tabs.first { $0.id == "move" }?.spaceID == "two")
    #expect(result.spaces?.map(\.id) == ["two"])
}

@Test func semanticProjectionFutureLocalDeleteDoesNotEraseEarlierPendingCreateAndMoveOut() {
    var baseline = BrowserSyncOutboxBaseline()
    baseline.deletedKeys = ["space:one", "tab:discard"]
    let queue: [BrowserSyncQueuedMutation] = [
        .semantic(.init(id: "create", operations: [
            .createSpace(id: "one", data: .init(title: "One", systemImageName: "circle")),
            .createTab(
                id: "keep",
                data: .init(spaceID: "one", placement: .temporary, urlString: "https://keep.example/"),
            ),
            .createTab(
                id: "discard",
                data: .init(spaceID: "one", placement: .temporary, urlString: "https://discard.example/"),
            ),
        ])),
        .semantic(.init(id: "move-delete", operations: [
            .createSpace(id: "two", data: .init(title: "Two", systemImageName: "circle")),
            .moveTabs(ids: ["keep"], destination: .init(spaceID: "two", placement: .temporary)),
            .deleteTab(id: "discard"), .deleteSpace(id: "one"),
        ])),
    ]
    let result = BrowserSyncOutboxProjection.snapshot(baseline: baseline, pending: queue, local: nil)
    #expect(result.tabs.compactMap(\.id) == ["keep"])
    #expect(result.tabs.first?.spaceID == "two")
    #expect(result.spaces?.map(\.id) == ["two"])
}

@Test func semanticProjectionParentDeletePreservesConcurrentMoveOutAndDeletesCurrentChildren() {
    let before = semanticSnapshot([semanticTab("a")], spaces: ["one", "two"])
    let after = semanticSnapshot([], spaces: ["two"])
    let operations = BrowserSyncSemanticProjection.operations(from: before, to: after)
    #expect(operations == [.deleteSpace(id: "one")])
    let movedRemotely = semanticSnapshot([semanticTab("a", space: "two", title: "Remote")], spaces: ["one", "two"])
    let preserved = semanticReplay(movedRemotely, operations: operations)
    #expect(preserved.tabs.first?.id == "a")
    #expect(preserved.tabs.first?.userTitleOverride == "Remote")
    #expect(preserved.spaces?.map(\.id) == ["two"])
    let deletedFirst = semanticReplay(before, operations: operations + [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "two", placement: .temporary)),
    ])
    #expect(deletedFirst.tabs.isEmpty)
}

@Test func semanticProjectionAcknowledgedParentRemainsAvailableUntilFutureQueuedMoveOut() throws {
    var baseline = BrowserSyncOutboxBaseline()
    baseline.deletedKeys.insert("space:one")
    // An earlier create-Space row has just been acknowledged and removed. Its
    // canonical parent is still needed by a separate pending child-create row.
    try baseline.apply([BrowserSyncEvent(
        serverSeq: 1, deviceID: nil, entityType: "space", entityID: "one", op: "upsert",
        data: .space(.init(
            id: "one",
            title: "One",
            systemImageName: "circle",
            rank: 0,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil,
        )), createdAt: "2026-10-03T12:00:00Z",
    )])
    let queue: [BrowserSyncQueuedMutation] = [
        .semantic(.init(id: "create-child", operations: [
            .createTab(
                id: "keep",
                data: .init(spaceID: "one", placement: .temporary, urlString: "https://keep.example/"),
            ),
        ])),
        .semantic(.init(id: "move-delete", operations: [
            .createSpace(id: "two", data: .init(title: "Two", systemImageName: "circle")),
            .moveTabs(ids: ["keep"], destination: .init(spaceID: "two", placement: .temporary)),
            .deleteSpace(id: "one"),
        ])),
    ]
    let result = BrowserSyncOutboxProjection.snapshot(baseline: baseline, pending: queue, local: nil)
    #expect(result.tabs.first?.id == "keep")
    #expect(result.tabs.first?.spaceID == "two")
    #expect(result.spaces?.map(\.id) == ["two"])
}

@Test func semanticProjectionLegacyParentCascadeDefeatsLaterSemanticMoveButPreservesEarlierMoveOut() {
    let before = semanticSnapshot([semanticTab("a")], spaces: ["one", "two"])
    let parentDelete = BrowserSyncChange(entityType: .space, entityID: "one", op: .delete, spaceData: nil, tabData: nil)
    let lateMove = BrowserSyncSemanticMutation(id: "late-move", operations: [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "two", placement: .temporary)),
    ])
    let queue: [BrowserSyncQueuedMutation] = [
        .legacy(.init(id: "delete-parent", changes: [parentDelete])), .semantic(lateMove),
    ]
    let removed = BrowserSyncOutboxProjection.snapshot(
        baseline: semanticBaseline(before),
        pending: queue,
        local: before,
    )
    #expect(removed.tabs.isEmpty)

    let moved = semanticSnapshot([semanticTab("a", space: "two")], spaces: ["one", "two"])
    let moveChange = BrowserSyncOutboxProjection.canonicalChanges(moved).filter { $0.entityType == .tab }
    // Legacy requests execute upserts before deletes even if the serialized order
    // was inherited from an older client. The queued bytes themselves stay intact.
    let moveThenDelete: [BrowserSyncQueuedMutation] = [
        .legacy(.init(id: "legacy-move-delete", changes: [parentDelete] + moveChange)),
    ]
    let preserved = BrowserSyncOutboxProjection.snapshot(
        baseline: semanticBaseline(before), pending: moveThenDelete, local: moved,
    )
    #expect(preserved.tabs.first?.spaceID == "two")
}

@Test func semanticProjectionAuthoritativeDeleteDefeatsPendingCreatePatchAndMove() {
    let before = semanticSnapshot([semanticTab("a")], spaces: ["one", "two"])
    var baseline = semanticBaseline(before)
    baseline.entities["tab:a"] = .init(serverSeq: 100, change: .init(
        entityType: .tab, entityID: "a", op: .delete, spaceData: nil, tabData: nil,
    ))
    baseline.deletedKeys.insert("tab:a")
    let result = BrowserSyncOutboxProjection.snapshot(
        baseline: baseline,
        pending: [.semantic(.init(id: "stale", operations: [
            .createTab(
                id: "a",
                data: .init(spaceID: "one", placement: .temporary, urlString: "https://stale.example/"),
            ),
            .patchTab(id: "a", fields: .init(userTitleOverride: .set("Stale"))),
            .moveTabs(ids: ["a"], destination: .init(spaceID: "two", placement: .temporary)),
            .deleteTab(id: "a"),
        ]))],
        local: before,
    )
    #expect(result.tabs.isEmpty)
}

@Test func semanticProjectionRejectedMoveKeepsSourceAndMissingPatchDoesNotInventEntity() {
    let before = semanticSnapshot([semanticTab("a", title: "Canonical"), semanticTab("b")])
    let result = semanticReplay(before, operations: [
        .moveTabs(ids: ["a"], destination: .init(spaceID: "missing", placement: .temporary)),
        .patchTab(id: "missing", fields: .init(userTitleOverride: .set("Invented"))),
    ])
    #expect(result.tabs == before.tabs)
}

@Test func semanticProjectionAnchorsUseBeforeThenAfterThenAppendAndSkipMissingMembers() {
    let before = semanticSnapshot(["a", "b", "c", "d"].map { semanticTab($0) })
    let destination = BrowserSyncSemanticTabDestination(spaceID: "one", placement: .temporary)
    #expect(semanticReplay(before, operations: [
        .moveTabs(ids: ["d", "missing"], destination: destination, beforeID: "b", afterID: "c"),
    ])
    .tabs
    .compactMap(\.id) == ["a", "d", "b", "c"])
    #expect(semanticReplay(before, operations: [
        .moveTabs(ids: ["d"], destination: destination, beforeID: "missing", afterID: "a"),
    ])
    .tabs
    .compactMap(\.id) == ["a", "d", "b", "c"])
    #expect(semanticReplay(before, operations: [
        .moveTabs(ids: ["a"], destination: destination, beforeID: "missing", afterID: "also-missing"),
    ])
    .tabs
    .compactMap(\.id) == ["b", "c", "d", "a"])
}

@Test func semanticProjectionGlobalFavoriteNeedsNoParentAndExplicitDeleteWins() {
    let empty = BrowserTabSessionSnapshot(tabs: [])
    let operations: [BrowserSyncSemanticOperation] = [
        .createTab(
            id: "favorite",
            data: .init(spaceID: "historical", placement: .app, urlString: "https://favorite.example/"),
        ),
        .deleteSpace(id: "historical"),
        .patchTab(id: "favorite", fields: .init(userTitleOverride: .set("Favorite"))),
    ]
    let projected = semanticReplay(empty, operations: operations)
    #expect(projected.spaces == nil)
    #expect(projected.tabs.first?.userTitleOverride == "Favorite")
    #expect(semanticReplay(empty, operations: operations + [.deleteTab(id: "favorite")]).tabs.isEmpty)
}

@Test func semanticProjectionMixedQueueReplaysLegacyThenSemanticWithoutRewritingLegacyFields() {
    let before = semanticSnapshot([semanticTab("a")], spaces: ["one", "two"])
    let legacy = semanticSnapshot([semanticTab("a", title: "Legacy")], spaces: ["one", "two"])
    let changes = BrowserSyncOutboxProjection.changes(from: before, to: legacy)
    let queue: [BrowserSyncQueuedMutation] = [
        .legacy(.init(id: "v2", changes: changes)),
        .semantic(.init(id: "v3", operations: [
            .moveTabs(ids: ["a"], destination: .init(spaceID: "two", placement: .temporary)),
            .patchTab(id: "a", fields: .init(urlString: "https://semantic.example/")),
        ])),
    ]
    let result = BrowserSyncOutboxProjection.snapshot(baseline: semanticBaseline(before), pending: queue, local: before)
    #expect(result.tabs.first?.spaceID == "two")
    #expect(result.tabs.first?.userTitleOverride == "Legacy")
    #expect(result.tabs.first?.urlString == "https://semantic.example/")
}

@Test func semanticProjectionSpacesReorderWithoutEchoingRemoteMetadata() {
    let before = semanticSnapshot([], spaces: ["one", "two", "three"])
    let after = semanticSnapshot([], spaces: ["three", "one", "two"])
    let operations = BrowserSyncSemanticProjection.operations(from: before, to: after)
    #expect(operations == [.moveSpaces(ids: ["three"], beforeID: "one")])
    let remote = BrowserTabSessionSnapshot(spaces: [
        .init(id: "one", title: "Renamed", systemImageName: "star", isPinnedSectionCollapsed: true),
        .init(id: "two", title: "two", systemImageName: "circle"),
        .init(id: "three", title: "three", systemImageName: "circle"),
    ], tabs: [])
    let result = semanticReplay(remote, operations: operations)
    #expect(result.spaces?.map(\.id) == ["three", "one", "two"])
    #expect(result.spaces?[1].title == "Renamed")
    #expect(result.spaces?[1].isPinnedSectionCollapsed == true)
}

@Test func semanticProjectionSplitsLargeMoveGroupsBeforeDurableCapture() {
    let ids = (0..<2001).map { "tab-\($0)" }
    let before = semanticSnapshot(ids.map { semanticTab($0) }, spaces: ["one", "two"])
    let after = semanticSnapshot(ids.map { semanticTab($0, space: "two") }, spaces: ["one", "two"])
    let operations = BrowserSyncSemanticProjection.operations(from: before, to: after)
    let groups = operations.compactMap { operation -> [String]? in
        guard case .moveTabs(let ids, _, _, _) = operation else { return nil }
        return ids
    }
    #expect(groups.map(\.count) == [1000, 1000, 1])
    #expect(groups.flatMap(\.self) == ids)
    let result = semanticReplay(before, operations: operations)
    #expect(result.tabs.compactMap(\.id) == ids)
    #expect(result.tabs.allSatisfy { $0.spaceID == "two" })
}

@Test func semanticProjectionSeedCreatesParentsFirstAndPinHomeClearRemainsExplicit() {
    let snapshot = semanticSnapshot([semanticTab("a", placement: .spacePinned, home: "https://home.example/")])
    let operations = BrowserSyncSemanticProjection.operations(from: nil, to: snapshot)
    #expect(operations.count == 2)
    #expect(operations.first == .createSpace(id: "one", data: .init(title: "one", systemImageName: "circle")))
    let cleared = semanticSnapshot([semanticTab("a", placement: .spacePinned)])
    let clear = BrowserSyncSemanticProjection.operations(from: snapshot, to: cleared)
    #expect(clear == [.patchTab(id: "a", fields: .init(pinnedURLString: .clear))])
    #expect(semanticReplay(snapshot, operations: clear).tabs.first?.pinnedURLString == nil)
}

private func semanticTab(
    _ id: String, space: String = "one", url: String? = nil, title: String? = nil,
    placement: BrowserTabPlacement = .temporary, home: String? = nil,
) -> BrowserTabSessionSnapshotTab {
    .init(
        id: id,
        urlString: url ?? "https://\(id).example/",
        pinnedURLString: home,
        userTitleOverride: title,
        placement: placement,
        spaceID: space,
    )
}

private func semanticSnapshot(
    _ tabs: [BrowserTabSessionSnapshotTab], spaces: [String] = ["one"],
) -> BrowserTabSessionSnapshot {
    .init(spaces: spaces.map { .init(id: $0, title: $0, systemImageName: "circle") }, tabs: tabs)
}

private func semanticBaseline(_ snapshot: BrowserTabSessionSnapshot) -> BrowserSyncOutboxBaseline {
    var baseline = BrowserSyncOutboxBaseline()
    for (index, change) in BrowserSyncOutboxProjection.canonicalChanges(snapshot).enumerated() {
        baseline.entities[BrowserSyncOutboxProjection.key(change)] = .init(serverSeq: index + 1, change: change)
    }
    return baseline
}

private func semanticReplay(
    _ snapshot: BrowserTabSessionSnapshot, operations: [BrowserSyncSemanticOperation],
) -> BrowserTabSessionSnapshot {
    BrowserSyncOutboxProjection.snapshot(
        baseline: semanticBaseline(snapshot),
        pending: [.semantic(.init(id: "projection", operations: operations))], local: snapshot,
    )
}

private func semanticPermutations(_ ids: [String]) -> [[String]] {
    guard let first = ids.first else { return [[]] }
    return semanticPermutations(Array(ids.dropFirst())).flatMap { rest in
        (0...rest.count).map { index in
            var result = rest
            result.insert(first, at: index)
            return result
        }
    }
}
