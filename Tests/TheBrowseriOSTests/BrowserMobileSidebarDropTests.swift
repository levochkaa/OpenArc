import Foundation
import Testing

// MARK: - BrowserMobileSidebarDropTests

struct BrowserMobileSidebarDropTests {
    // MARK: Internal

    @Test func mixedSiblingMoveKeepsTypedAnchorAndFolderRootOnly() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(item: folder("folder"), in: snapshot))
        let target = try #require(Drop.target(relativeTo: tab("loose"), position: .after, in: snapshot))
        let plan = try #require(Drop.plan(source: source, target: target, in: snapshot))
        #expect(plan.items == [folder("folder")])
        #expect(plan.before == nil && plan.after == tab("loose"))
        #expect(plan.destination == .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: nil))
        let changed = apply(plan, to: snapshot)
        #expect(pinnedOrder(changed, parent: nil) == [tab("loose"), folder("folder"), folder("empty")])
        #expect(changed.tabs.first { $0.id == "child" }?.pinnedFolderID == "folder")
        #expect(changed.pinnedTabFolders?.first { $0.id == "nested" }?.parentFolderID == "folder")

        let collision = try #require(Drop.source(item: tab("folder"), in: snapshot))
        let intoFolder = try #require(Drop.target(relativeTo: folder("folder"), position: .inside, in: snapshot))
        #expect(Drop.plan(source: collision, target: intoFolder, in: snapshot)?.items == [tab("folder")])
    }

    @Test func emptyAndCollapsedFoldersAcceptAppendWithoutExpandingThem() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(item: tab("today"), in: snapshot))
        for id in ["empty", "nested"] {
            let target = try #require(Drop.target(relativeTo: folder(id), position: .inside, in: snapshot))
            let plan = try #require(Drop.plan(source: source, target: target, in: snapshot))
            #expect(plan.before == nil && plan.after == nil)
            let changed = apply(plan, to: snapshot)
            #expect(changed.tabs.first { $0.id == "today" }?.pinnedFolderID == id)
            #expect(changed.tabs.first { $0.id == "today" }?.placement == .spacePinned)
            #expect(changed.pinnedTabFolders?.first { $0.id == id }?.isExpanded == false)
        }
        let root = Drop.rootTarget(spaceID: "target", placement: .temporary)
        let plan = try #require(Drop.plan(source: source, target: root, in: snapshot))
        #expect(apply(plan, to: snapshot).tabs.first { $0.id == "today" }?.spaceID == "target")
    }

    @Test func invalidCyclesPlacementsAndMissingTargetsNeverProducePlans() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(item: folder("folder"), in: snapshot))
        for target in try [
            #require(Drop.target(relativeTo: folder("folder"), position: .inside, in: snapshot)),
            #require(Drop.target(relativeTo: folder("nested"), position: .inside, in: snapshot)),
            #require(Drop.target(relativeTo: tab("child"), position: .before, in: snapshot)),
            Drop.rootTarget(spaceID: "source", placement: .temporary),
            Drop.rootTarget(spaceID: "source", placement: .app),
            Drop.rootTarget(spaceID: "removed-space", placement: .spacePinned),
        ] {
            #expect(Drop.plan(source: source, target: target, in: snapshot) == nil)
        }
        #expect(Drop.target(relativeTo: tab("child"), position: .inside, in: snapshot) == nil)
        #expect(Drop.target(relativeTo: folder("missing"), position: .after, in: snapshot) == nil)
        #expect(Drop.source(item: .init(entityType: .space, entityID: "source"), in: snapshot) == nil)
    }

    @Test func capturedTargetsTolerateRenameAndInsertionButRejectRemovalAndReparenting() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(item: tab("today"), in: snapshot))
        let target = try #require(Drop.target(relativeTo: folder("empty"), position: .before, in: snapshot))
        let renamed = apply([
            .patchFolder(id: "empty", fields: .init(title: "Changed title")),
            .createTab(
                id: "inserted",
                data: .init(
                    spaceID: "source",
                    placement: .spacePinned,
                    pinnedFolderID: nil,
                    urlString: "about:blank"
                ),
                before: folder("empty")
            ),
        ], to: snapshot)
        let plan = try #require(Drop.plan(source: source, target: target, in: renamed))
        #expect(plan.before == folder("empty"))
        #expect(pinnedOrder(apply(plan, to: renamed), parent: nil) == [
            folder("folder"), tab("loose"), tab("inserted"), tab("today"), folder("empty"),
        ])
        let deleted = apply([.deleteFolder(id: "empty")], to: snapshot)
        #expect(Drop.plan(source: source, target: target, in: deleted) == nil)
        let moved = apply([.move(items: [folder("empty")], destination: .tabs(
            spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder"
        ))], to: snapshot)
        #expect(Drop.plan(source: source, target: target, in: moved) == nil)
        let inside = try #require(Drop.target(relativeTo: folder("empty"), position: .inside, in: snapshot))
        #expect(Drop.plan(source: source, target: inside, in: moved) == nil)
    }

    @Test func capturedSourceRejectsNewContainerButUsesCurrentFolderDescendants() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(item: folder("folder"), in: snapshot))
        let target = Drop.rootTarget(spaceID: "target", placement: .spacePinned)
        let relocated = apply([.move(items: source.items, destination: .tabs(
            spaceID: "source", placement: .spacePinned, pinnedFolderID: "empty"
        ))], to: snapshot)
        #expect(Drop.plan(source: source, target: target, in: relocated) == nil)
        let changed = apply([
            .move(
                items: [tab("child")],
                destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: nil)
            ),
            .move(
                items: [tab("today")],
                destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder")
            ),
            .move(
                items: [folder("folder")],
                destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: nil),
                after: folder("empty")
            ),
        ], to: snapshot)
        let plan = try #require(Drop.plan(source: source, target: target, in: changed))
        let moved = apply(plan, to: changed)
        #expect(plan.items == [folder("folder")])
        #expect(moved.tabs.first { $0.id == "today" }?.spaceID == "target")
        #expect(moved.tabs.first { $0.id == "child" }?.spaceID == "source")
        #expect(moved.pinnedTabFolders?.first { $0.id == "nested" }?.spaceID == "target")
        let deleted = apply([.deleteFolder(id: "folder")], to: snapshot)
        #expect(Drop.plan(source: source, target: target, in: deleted) == nil)
    }

    @Test func semanticNoOpIgnoresSparseFractionalRanks() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(item: tab("loose"), in: snapshot))
        for target in try [
            #require(Drop.target(relativeTo: folder("folder"), position: .after, in: snapshot)),
            #require(Drop.target(relativeTo: folder("empty"), position: .before, in: snapshot)),
            #require(Drop.target(relativeTo: tab("loose"), position: .after, in: snapshot)),
        ] {
            #expect(Drop.plan(source: source, target: target, in: snapshot) == nil)
        }
        let favorite = try #require(Drop.source(item: tab("favorite"), in: snapshot))
        let globalAppend = Drop.rootTarget(spaceID: "target", placement: .app)
        #expect(Drop.plan(source: favorite, target: globalAppend, in: snapshot) == nil)
    }

    @Test func globalFavoritesReorderWithoutLiveSpacesOrStableHistoricalSpaceIDs() throws {
        let snapshot = favoriteSnapshot(firstSpace: "deleted-a", secondSpace: "deleted-b")
        let source = try #require(Drop.source(item: tab("first"), in: snapshot))
        let target = try #require(Drop.target(relativeTo: tab("second"), position: .after, in: snapshot))
        let latest = favoriteSnapshot(firstSpace: "different-a", secondSpace: "different-b")
        let plan = try #require(Drop.plan(source: source, target: target, in: latest))
        #expect(plan.items == [tab("first")])
        #expect(plan.after == tab("second"))
        let moved = apply(plan, to: latest)
        #expect(moved.tabs.map(\.id) == ["second", "first"])
        #expect(moved.spaces?.isEmpty != false)
        let alreadyLast = try #require(Drop.source(item: tab("first"), in: moved))
        #expect(Drop.plan(
            source: alreadyLast,
            target: Drop.rootTarget(spaceID: "another-deleted-space", placement: .app),
            in: moved
        ) == nil)
    }

    @Test func groupMovePreservesSuppliedRootOrderAcrossNoncontiguousSelection() throws {
        let snapshot = groupTabSnapshot()
        let source = try #require(Drop.source(items: [tab("a"), tab("c")], in: snapshot))
        let target = try #require(Drop.target(relativeTo: tab("d"), position: .before, in: snapshot))
        let plan = try #require(Drop.plan(source: source, target: target, in: snapshot))
        #expect(source.items == [tab("a"), tab("c")])
        #expect(plan.items == source.items && plan.before == tab("d"))
        #expect(apply(plan, to: snapshot).tabs.compactMap(\.id) == ["b", "a", "c", "d"])

        // The caller supplies sidebar order; capture must not replace it with
        // dictionary, ID, or gesture-addition ordering.
        let reverse = try #require(Drop.source(items: [tab("c"), tab("a")], in: snapshot))
        let append = Drop.rootTarget(spaceID: "source", placement: .temporary)
        let reversePlan = try #require(Drop.plan(source: reverse, target: append, in: snapshot))
        #expect(apply(reversePlan, to: snapshot).tabs.compactMap(\.id) == ["b", "d", "c", "a"])
    }

    @Test func groupCaptureNormalizesSelectedAncestorsAndRejectsInvalidReferences() throws {
        let snapshot = dropSnapshot()
        let selected = [tab("child"), tab("loose"), folder("nested"), folder("folder"), tab("today")]
        let source = try #require(Drop.source(items: selected, in: snapshot))
        #expect(source.items == [tab("loose"), folder("folder"), tab("today")])
        let collision = try #require(Drop.source(items: [tab("folder"), folder("folder")], in: snapshot))
        #expect(collision.items == [tab("folder"), folder("folder")])
        #expect(Drop.source(items: [], in: snapshot) == nil)
        #expect(Drop.source(items: [tab("today"), tab("today")], in: snapshot) == nil)
        #expect(Drop.source(items: [folder("folder"), tab("child"), tab("child")], in: snapshot) == nil)
        #expect(Drop.source(items: [tab("today"), tab("unknown")], in: snapshot) == nil)
        #expect(Drop.source(items: [.init(entityType: .space, entityID: "source"), tab("today")], in: snapshot) == nil)
        #expect(Drop.source(item: tab("today"), in: snapshot)?.items == [tab("today")])
    }

    @Test func oneStaleGroupRootRejectsEntireMoveWhileMetadataAndSiblingInsertionRemainSafe() throws {
        let snapshot = groupTabSnapshot()
        let source = try #require(Drop.source(items: [tab("a"), tab("c")], in: snapshot))
        let target = try #require(Drop.target(relativeTo: tab("d"), position: .before, in: snapshot))
        let invalidSnapshots = [
            apply([.deleteTab(id: "c")], to: snapshot),
            apply([.move(items: [tab("c")], destination: .tabs(
                spaceID: "target", placement: .temporary, pinnedFolderID: nil
            ))], to: snapshot),
            apply([.move(items: [tab("a")], destination: .tabs(
                spaceID: "source", placement: .spacePinned, pinnedFolderID: nil
            ))], to: snapshot),
        ]
        for latest in invalidSnapshots {
            #expect(Drop.plan(source: source, target: target, in: latest) == nil)
        }
        let latest = apply([
            .patchTab(id: "c", fields: .init(userTitleOverride: .set("Remote title"))),
            .createTab(id: "inserted", data: .init(
                spaceID: "source", placement: .temporary, pinnedFolderID: nil, urlString: "about:blank"
            ), before: tab("d")),
        ], to: snapshot)
        let plan = try #require(Drop.plan(source: source, target: target, in: latest))
        let moved = apply(plan, to: latest)
        #expect(moved.tabs.compactMap(\.id) == ["b", "inserted", "a", "c", "d"])
        #expect(moved.tabs.first { $0.id == "c" }?.userTitleOverride == "Remote title")
    }

    @Test func mixedGroupUsesCurrentSubtreeAndRejectsInvalidDestinationsOrMovingAnchors() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(items: [folder("folder"), tab("loose")], in: snapshot))
        let forbidden = try [
            #require(Drop.target(relativeTo: tab("loose"), position: .before, in: snapshot)),
            #require(Drop.target(relativeTo: folder("folder"), position: .inside, in: snapshot)),
            #require(Drop.target(relativeTo: folder("nested"), position: .inside, in: snapshot)),
            #require(Drop.target(relativeTo: tab("child"), position: .after, in: snapshot)),
            Drop.rootTarget(spaceID: "source", placement: .temporary),
            Drop.rootTarget(spaceID: "source", placement: .app),
        ]
        for target in forbidden {
            #expect(Drop.plan(source: source, target: target, in: snapshot) == nil)
        }
        let latest = apply([
            .move(items: [tab("child")], destination: .tabs(
                spaceID: "source", placement: .spacePinned, pinnedFolderID: nil
            )),
            .move(items: [tab("today")], destination: .tabs(
                spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder"
            )),
        ], to: snapshot)
        let plan = try #require(Drop.plan(
            source: source, target: Drop.rootTarget(spaceID: "target", placement: .spacePinned), in: latest
        ))
        let moved = apply(plan, to: latest)
        #expect(plan.items == [folder("folder"), tab("loose")])
        #expect(moved.tabs.first { $0.id == "child" }?.spaceID == "source")
        #expect(moved.tabs.first { $0.id == "today" }?.spaceID == "target")
        #expect(moved.tabs.first { $0.id == "loose" }?.spaceID == "target")
        #expect(moved.pinnedTabFolders?.first { $0.id == "nested" }?.spaceID == "target")
    }

    @Test func groupNoOpIgnoresSparseRanksAndRankNormalization() throws {
        let snapshot = dropSnapshot()
        let source = try #require(Drop.source(items: [folder("folder"), tab("loose")], in: snapshot))
        let target = try #require(Drop.target(relativeTo: folder("empty"), position: .before, in: snapshot))
        #expect(Drop.plan(source: source, target: target, in: snapshot) == nil)
        let allRoots = try #require(Drop.source(items: [folder("folder"), tab("loose"), folder("empty")], in: snapshot))
        #expect(Drop.plan(
            source: allRoots, target: Drop.rootTarget(spaceID: "source", placement: .spacePinned), in: snapshot
        ) == nil)
    }

    @Test func groupLimitCountsNormalizedRootsAndAcceptsExactlyOneThousand() throws {
        let tabs = (0...1000).map {
            BrowserTabSessionSnapshotTab(id: "tab-\($0)", urlString: "about:blank", spaceID: "source")
        }
        let snapshot = BrowserTabSessionSnapshot(spaces: [
            .init(id: "source", title: "Source", systemImageName: "globe"),
            .init(id: "target", title: "Target", systemImageName: "globe"),
        ], tabs: tabs)
        let references = tabs.compactMap(\.id).map(tab)
        let source = try #require(Drop.source(items: Array(references.prefix(1000)), in: snapshot))
        #expect(source.items.count == 1000)
        let plan = try #require(Drop.plan(
            source: source, target: Drop.rootTarget(spaceID: "target", placement: .temporary), in: snapshot
        ))
        #expect(plan.items == source.items)
        #expect(Drop.source(items: references, in: snapshot) == nil)

        let descendants = BrowserTabSessionSnapshot(spaces: snapshot.spaces, pinnedTabFolders: [
            .init(id: "parent", spaceID: "source", title: "Parent"),
        ], tabs: tabs.map { .init(
            id: $0.id, urlString: $0.urlString, placement: .spacePinned, spaceID: "source", pinnedFolderID: "parent"
        ) })
        let collapsed = try #require(Drop.source(items: references + [folder("parent")], in: descendants))
        #expect(collapsed.items == [folder("parent")])
    }

    // MARK: Private

    private typealias Drop = BrowserMobileSidebarDrop
}

private func tab(_ id: String) -> BrowserSyncEntityReference { .init(entityType: .tab, entityID: id) }
private func folder(_ id: String) -> BrowserSyncEntityReference { .init(entityType: .folder, entityID: id) }

private func apply(
    _ plan: BrowserMobileSidebarDrop.Plan,
    to snapshot: BrowserTabSessionSnapshot
) -> BrowserTabSessionSnapshot {
    apply(
        [.move(items: plan.items, destination: plan.destination, before: plan.before, after: plan.after)],
        to: snapshot
    )
}

private func apply(
    _ operations: [BrowserSyncFolderOperation],
    to snapshot: BrowserTabSessionSnapshot
) -> BrowserTabSessionSnapshot {
    var values = Dictionary(uniqueKeysWithValues: BrowserSyncFolderProjection.canonicalChanges(snapshot).map {
        (BrowserSyncOutboxProjection.key($0), $0)
    })
    var deleted = Set<String>()
    BrowserSyncFolderProjection.apply(operations, to: &values, deleted: &deleted)
    values = values.filter { $0.value.op == .upsert && !deleted.contains($0.key) }
    return BrowserSyncFolderProjection.snapshot(values: values, local: snapshot)
}

private func pinnedOrder(_ snapshot: BrowserTabSessionSnapshot, parent: String?) -> [BrowserSyncEntityReference] {
    BrowserSyncFolderProjection.canonicalChanges(snapshot).compactMap { change in
        if let folder = change.folderData, folder.spaceID == "source", folder.parentFolderID == parent {
            return .init(entityType: .folder, entityID: change.entityID)
        }
        if let tab = change.tabData, tab.spaceID == "source", tab.placement == .spacePinned,
           tab.pinnedFolderID == parent
        {
            return .init(entityType: .tab, entityID: change.entityID)
        }
        return nil
    }
}

private func dropSnapshot() -> BrowserTabSessionSnapshot {
    .init(spaces: [
        .init(id: "source", title: "Source", systemImageName: "globe"),
        .init(id: "target", title: "Target", systemImageName: "globe"),
    ], pinnedTabFolders: [
        .init(id: "folder", spaceID: "source", title: "Folder", pinnedSiblingRank: 100.5),
        .init(
            id: "nested",
            spaceID: "source",
            parentFolderID: "folder",
            title: "Nested",
            isExpanded: false,
            pinnedSiblingRank: 200.25
        ),
        .init(id: "empty", spaceID: "source", title: "Empty", isExpanded: false, pinnedSiblingRank: 300.75),
    ], tabs: [
        .init(id: "favorite", urlString: "https://example.com/favorite", placement: .app, spaceID: "historical"),
        .init(
            id: "child",
            urlString: "https://example.com/child",
            placement: .spacePinned,
            spaceID: "source",
            pinnedFolderID: "folder",
            pinnedSiblingRank: 100.5
        ),
        .init(
            id: "loose",
            urlString: "https://example.com/loose",
            placement: .spacePinned,
            spaceID: "source",
            pinnedSiblingRank: 200.25
        ),
        .init(id: "today", urlString: "https://example.com/today", spaceID: "source"),
        .init(id: "folder", urlString: "https://example.com/same-raw-id", spaceID: "source"),
    ])
}

private func favoriteSnapshot(firstSpace: String, secondSpace: String) -> BrowserTabSessionSnapshot {
    .init(spaces: [], tabs: [
        .init(id: "first", urlString: "about:blank", placement: .app, spaceID: firstSpace),
        .init(id: "second", urlString: "about:blank", placement: .app, spaceID: secondSpace),
    ])
}

private func groupTabSnapshot() -> BrowserTabSessionSnapshot {
    .init(spaces: [
        .init(id: "source", title: "Source", systemImageName: "globe"),
        .init(id: "target", title: "Target", systemImageName: "globe"),
    ], tabs: ["a", "b", "c", "d"].map {
        .init(id: $0, urlString: "about:blank", spaceID: "source")
    })
}
