import Foundation
import Testing

struct BrowserSyncFolderProjectionTests {
    // MARK: Internal

    @Test func v4WireUsesTypedReferencesAndRequiredNullableMembershipWithoutChangingV3() throws {
        let operations: [BrowserSyncFolderOperation] = [
            .createFolder(id: "same", data: .init(spaceID: "s", title: "Folder")),
            .createTab(
                id: "same",
                data: .init(spaceID: "s", placement: .spacePinned, urlString: "https://example.test")
            ),
            .move(
                items: [r(.folder, "same"), r(.tab, "same")],
                destination: .tabs(spaceID: "s", placement: .spacePinned, pinnedFolderID: nil),
                before: r(.tab, "anchor")
            ),
            .patchFolder(id: "same", fields: .init(title: "Renamed")),
            .patchFolder(id: "same", fields: .init(systemImageName: .clear)),
            .patchTab(id: "same", fields: .init(userTitleOverride: .set("Custom"))),
        ]
        let request = BrowserSyncFolderPushRequest(
            mutationID: UUID().uuidString,
            deviceID: UUID().uuidString,
            operations: operations
        )
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(BrowserSyncFolderPushRequest.self, from: encoded) == request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["protocolVersion"] as? Int == 4)
        let rows = try #require(object["operations"] as? [[String: Any]])
        #expect((rows[0]["data"] as? [String: Any])?["parentFolderID"] is NSNull)
        #expect((rows[1]["data"] as? [String: Any])?["pinnedFolderID"] is NSNull)
        #expect(rows[2]["entityType"] == nil)
        #expect((rows[2]["items"] as? [[String: String]])?.map { $0["entityType"] } == ["folder", "tab"])
        #expect((rows[3]["fields"] as? [String: Any])?["systemImageName"] == nil)
        #expect((rows[4]["fields"] as? [String: Any])?["systemImageName"] is NSNull)
        let legacyFolder = Data(#"{"kind":"delete","entityType":"folder","entityID":"f"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(
            BrowserSyncSemanticOperation.self,
            from: legacyFolder
        ) }
        let missingMembership = Data(#"{"spaceID":"s","placement":"spacePinned","urlString":"https://example.test"}"#
            .utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(
            BrowserSyncFolderTabCreate.self,
            from: missingMembership
        ) }
    }

    @Test func canonicalMixedOrderPreservesEmptyFoldersTypedCollisionsAndLocalExpansion() {
        let local = BrowserTabSessionSnapshot(spaces: [space("s")], pinnedTabFolders: [
            .init(id: "same", spaceID: "s", title: "Empty", isExpanded: false, pinnedSiblingRank: 1),
        ], tabs: [
            .init(
                id: "same",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedSiblingRank: 0
            ),
            .init(
                id: "last",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedSiblingRank: 2
            ),
        ])
        let canonical = BrowserSyncFolderProjection.canonicalChanges(local)
        #expect(canonical.map { r($0.entityType, $0.entityID) } == [
            r(.space, "s"),
            r(.tab, "same"),
            r(.folder, "same"),
            r(.tab, "last"),
        ])
        let restored = BrowserSyncFolderProjection.snapshot(values: keyed(canonical), local: local)
        #expect(restored.pinnedTabFolders?.first?.isExpanded == false)
        #expect(restored.pinnedTabFolders?.first?.pinnedSiblingRank == 1)
        #expect(restored.tabs.map(\.pinnedSiblingRank) == [0, 2])
        #expect(BrowserSyncFolderProjection.operations(from: local, to: restored).isEmpty)
    }

    @Test func missingLegacyRanksInferFirstDescendantPositionAndAppendEmptyFolders() {
        let local = BrowserTabSessionSnapshot(spaces: [space("s")], pinnedTabFolders: [
            .init(id: "empty", spaceID: "s", title: "Empty"),
            .init(id: "parent", spaceID: "s", title: "Parent"),
            .init(id: "nested", spaceID: "s", parentFolderID: "parent", title: "Nested"),
        ], tabs: [
            .init(
                id: "child",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedFolderID: "nested"
            ),
            .init(id: "root", urlString: "https://example.test", placement: .spacePinned, spaceID: "s"),
        ])
        let changes = BrowserSyncFolderProjection.canonicalChanges(local)
        #expect(changes.map(\.entityID) == ["s", "parent", "nested", "child", "root", "empty"])
        let folderChanges = changes.filter { $0.folderData != nil }
        #expect(folderChanges.first { $0.entityID == "parent" }?.folderData?.rank == 0)
        #expect(folderChanges.first { $0.entityID == "empty" }?.folderData?.rank == 2)
    }

    @Test func explicitFolderMoveCarriesCurrentCanonicalSubtreeAndKeepsConcurrentMetadata() {
        var base = seeded(), deleted = Set<String>()
        let before = BrowserSyncFolderProjection.snapshot(values: base, local: nil)
        let move = BrowserSyncFolderOperation.move(
            items: [r(.folder, "f")],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil)
        )
        var moved = base
        BrowserSyncFolderProjection.apply([move], to: &moved, deleted: &deleted)
        let after = BrowserSyncFolderProjection.snapshot(values: moved, local: before)
        let captured = BrowserSyncFolderProjection.operations(
            from: before,
            to: after,
            moveIntent: .init(items: [r(.folder, "f")])
        )
        #expect(captured == [move])
        BrowserSyncFolderProjection.apply([
            .patchTab(id: "child", fields: .init(userTitleOverride: .set("Remote rename"))),
            .createTab(
                id: "unseen",
                data: .init(
                    spaceID: "s",
                    placement: .spacePinned,
                    pinnedFolderID: "nested",
                    urlString: "https://new.test"
                )
            ),
            .move(
                items: [r(.tab, "escaped")],
                destination: .tabs(spaceID: "s", placement: .spacePinned, pinnedFolderID: nil)
            ),
        ], to: &base, deleted: &deleted)
        BrowserSyncFolderProjection.apply(captured, to: &base, deleted: &deleted)
        #expect(base["tab:child"]?.tabData?.userTitleOverride == "Remote rename")
        #expect(base["tab:child"]?.tabData?.spaceID == "target")
        #expect(base["tab:unseen"]?.tabData?.spaceID == "target")
        #expect(base["tab:unseen"]?.tabData?.pinnedFolderID == "nested")
        #expect(base["tab:escaped"]?.tabData?.spaceID == "s")
        #expect(base["tab:escaped"]?.tabData?.pinnedFolderID == nil)
        #expect(base["folder:nested"]?.folderData?.parentFolderID == "f")
        #expect(base["folder:nested"]?.folderData?.spaceID == "target")
    }

    @Test func snapshotInferenceAlsoMovesOnlyFolderRootAndMetadataPatchPreservesRemoteMove() {
        let initial = seeded()
        let before = BrowserSyncFolderProjection.snapshot(values: initial, local: nil)
        var changed = initial, deleted = Set<String>()
        let move = BrowserSyncFolderOperation.move(
            items: [r(.folder, "f")],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil)
        )
        BrowserSyncFolderProjection.apply([move], to: &changed, deleted: &deleted)
        let afterMove = BrowserSyncFolderProjection.snapshot(values: changed, local: nil)
        #expect(BrowserSyncFolderProjection.operations(from: before, to: afterMove) == [move])
        var renamed = initial
        BrowserSyncFolderProjection.apply(
            [.patchFolder(id: "f", fields: .init(title: "Local rename", systemImageName: .clear))],
            to: &renamed,
            deleted: &deleted
        )
        let rename = BrowserSyncFolderProjection.operations(
            from: before,
            to: BrowserSyncFolderProjection.snapshot(values: renamed, local: nil)
        )
        #expect(rename == [.patchFolder(id: "f", fields: .init(title: "Local rename"))])
        BrowserSyncFolderProjection.apply(rename, to: &changed, deleted: &deleted)
        #expect(changed["folder:f"]?.folderData?.title == "Local rename")
        #expect(changed["folder:f"]?.folderData?.spaceID == "target")
    }

    @Test func parentDeleteEmitsNoStaleChildDeletesAndMovedOutChildSurvivesBothReplayOrders() {
        let initial = seeded(), before = BrowserSyncFolderProjection.snapshot(values: initial, local: nil)
        var removed = initial, deleted = Set<String>()
        BrowserSyncFolderProjection.apply([.deleteFolder(id: "f")], to: &removed, deleted: &deleted)
        let operations = BrowserSyncFolderProjection.operations(
            from: before,
            to: BrowserSyncFolderProjection.snapshot(values: removed, local: nil)
        )
        #expect(operations == [.deleteFolder(id: "f")])
        let escape = BrowserSyncFolderOperation.move(
            items: [r(.tab, "child")],
            destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil)
        )
        var live = initial, liveDeleted = Set<String>()
        BrowserSyncFolderProjection.apply([escape] + operations, to: &live, deleted: &liveDeleted)
        #expect(live["tab:child"]?.op == .upsert)
        #expect(live["tab:child"]?.tabData?.spaceID == "target")
        BrowserSyncFolderProjection.apply([escape], to: &removed, deleted: &deleted)
        #expect(removed["tab:child"]?.op == .delete)
        #expect(deleted.contains("tab:child"))
    }

    @Test func cycleOverlapAndDeadParentRejectEntireMixedMoveWhileFavoriteEscapesLifetime() {
        let initial = seeded()
        for operation: BrowserSyncFolderOperation in [
            .move(
                items: [r(.folder, "f"), r(.tab, "peer")],
                destination: .tabs(spaceID: "s", placement: .spacePinned, pinnedFolderID: "nested")
            ),
            .move(
                items: [r(.folder, "f"), r(.tab, "child")],
                destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: nil)
            ),
            .move(
                items: [r(.folder, "f"), r(.tab, "peer")],
                destination: .tabs(spaceID: "target", placement: .spacePinned, pinnedFolderID: "missing")
            ),
        ] {
            var values = initial, deleted = Set<String>()
            BrowserSyncFolderProjection.apply([operation], to: &values, deleted: &deleted)
            #expect(values == initial)
            #expect(deleted.isEmpty)
        }
        var values = initial, deleted = Set<String>()
        BrowserSyncFolderProjection.apply([
            .move(items: [r(.tab, "child")], destination: .tabs(spaceID: "s", placement: .app, pinnedFolderID: nil)),
            .deleteSpace(id: "s"),
        ], to: &values, deleted: &deleted)
        #expect(values["tab:child"]?.tabData?.placement == .app)
        #expect(values["tab:child"]?.tabData?.pinnedFolderID == nil)
        #expect(values["tab:child"]?.tabData?.pinnedURLString == nil)
        #expect(!deleted.contains("tab:child"))
    }

    @Test func mixedMoveIntentUsesActedOnIdentityAndChunksOnlyAtWireLimit() {
        let local = BrowserTabSessionSnapshot(spaces: [space("s")], pinnedTabFolders: [
            .init(id: "f", spaceID: "s", title: "Folder", pinnedSiblingRank: 0),
        ], tabs: [.init(
            id: "t",
            urlString: "https://example.test",
            placement: .spacePinned,
            spaceID: "s",
            pinnedSiblingRank: 1
        )])
        let swapped = BrowserTabSessionSnapshot(spaces: local.spaces, pinnedTabFolders: [
            .init(id: "f", spaceID: "s", title: "Folder", pinnedSiblingRank: 1),
        ], tabs: [.init(
            id: "t",
            urlString: "https://example.test",
            placement: .spacePinned,
            spaceID: "s",
            pinnedSiblingRank: 0
        )])
        #expect(BrowserSyncFolderProjection.operations(
            from: local,
            to: swapped,
            moveIntent: .init(items: [r(.folder, "f")])
        ) == [
            .move(
                items: [r(.folder, "f")],
                destination: .tabs(spaceID: "s", placement: .spacePinned, pinnedFolderID: nil),
                after: r(.tab, "t")
            ),
        ])
        let many = BrowserTabSessionSnapshot(spaces: [space("s"), space("target")], tabs: (0..<1001).map {
            .init(id: "tab-\($0)", urlString: "https://example.test", placement: .temporary, spaceID: "s")
        })
        let moved = BrowserTabSessionSnapshot(spaces: many.spaces, tabs: many.tabs.map {
            .init(id: $0.id, urlString: $0.urlString, placement: .temporary, spaceID: "target")
        })
        let ops = BrowserSyncFolderProjection.operations(from: many, to: moved)
        let sizes = ops
            .compactMap {
                operation -> Int? in if case .move(let items, _, _, _) = operation {
                    return items.count
                }
                return nil
            }
        #expect(sizes == [1000, 1])
    }

    @Test func adoptionIsParentFirstIdempotentAndPreservesAuthoritativeMetadataMembershipAndTombstones() {
        var canonical = [String: BrowserSyncChange](), deleted = Set<String>()
        BrowserSyncFolderProjection.apply([
            .createSpace(id: "s", data: .init(title: "Space", systemImageName: "globe")),
            .createFolder(id: "remote", data: .init(spaceID: "s", title: "Canonical")),
            .createTab(
                id: "root",
                data: .init(spaceID: "s", placement: .spacePinned, urlString: "https://example.test")
            ),
            .createTab(
                id: "member",
                data: .init(
                    spaceID: "s",
                    placement: .spacePinned,
                    pinnedFolderID: "remote",
                    urlString: "https://example.test"
                )
            ),
            .deleteFolder(id: "dead"),
        ], to: &canonical, deleted: &deleted)
        let local = BrowserTabSessionSnapshot(spaces: [space("s")], pinnedTabFolders: [
            .init(id: "new", spaceID: "s", title: "Local"),
            .init(id: "nested", spaceID: "s", parentFolderID: "new", title: "Empty"),
            .init(id: "remote", spaceID: "s", title: "Stale title"),
            .init(id: "dead", spaceID: "s", title: "Deleted"),
        ], tabs: [
            .init(
                id: "root",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedFolderID: "new"
            ),
            .init(
                id: "member",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedFolderID: "new"
            ),
        ])
        let adopted = BrowserSyncFolderProjection.adoptionOperations(local: local, values: canonical, deleted: deleted)
        BrowserSyncFolderProjection.apply(adopted, to: &canonical, deleted: &deleted)
        #expect(canonical["folder:new"]?.folderData?.title == "Local")
        #expect(canonical["folder:nested"]?.folderData?.parentFolderID == "new")
        #expect(canonical["folder:remote"]?.folderData?.title == "Canonical")
        #expect(canonical["tab:root"]?.tabData?.pinnedFolderID == "new")
        #expect(canonical["tab:member"]?.tabData?.pinnedFolderID == "remote")
        #expect(canonical["folder:dead"]?.op == .delete)
        #expect(BrowserSyncFolderProjection.adoptionOperations(local: local, values: canonical, deleted: deleted)
            .isEmpty)
    }

    @Test func adoptionUsesMixedNeighborsInsteadOfLegacyFlatRanks() {
        let local = BrowserTabSessionSnapshot(spaces: [space("s")], pinnedTabFolders: [
            .init(id: "f", spaceID: "s", title: "Folder", pinnedSiblingRank: 0),
            .init(id: "nested", spaceID: "s", parentFolderID: "f", title: "Nested empty", pinnedSiblingRank: 1),
            .init(id: "g", spaceID: "s", title: "Root empty", pinnedSiblingRank: 2),
        ], tabs: [
            .init(
                id: "a",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedFolderID: "f",
                pinnedSiblingRank: 0
            ),
            .init(
                id: "b",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedFolderID: "f",
                pinnedSiblingRank: 2
            ),
            .init(
                id: "loose",
                urlString: "https://example.test",
                placement: .spacePinned,
                spaceID: "s",
                pinnedSiblingRank: 1
            ),
        ])
        var canonical = keyed(BrowserSyncOutboxProjection.canonicalChanges(local)), deleted = Set<String>()
        let operations = BrowserSyncFolderProjection.adoptionOperations(
            local: local,
            values: canonical,
            deleted: deleted
        )
        BrowserSyncFolderProjection.apply(operations, to: &canonical, deleted: &deleted)
        let result = BrowserSyncFolderProjection.snapshot(values: canonical, local: local)
        let order = BrowserSyncFolderProjection.canonicalChanges(result).map { r($0.entityType, $0.entityID) }
        #expect(order == [
            r(.space, "s"),
            r(.folder, "f"),
            r(.tab, "a"),
            r(.folder, "nested"),
            r(.tab, "b"),
            r(.tab, "loose"),
            r(.folder, "g"),
        ])
        #expect(BrowserSyncFolderProjection.adoptionOperations(local: local, values: canonical, deleted: deleted)
            .isEmpty)
    }

    // MARK: Private

    private func seeded() -> [String: BrowserSyncChange] {
        var values = [String: BrowserSyncChange](), deleted = Set<String>()
        BrowserSyncFolderProjection.apply([
            .createSpace(id: "s", data: .init(title: "Source", systemImageName: "globe")),
            .createSpace(id: "target", data: .init(title: "Target", systemImageName: "globe")),
            .createFolder(id: "f", data: .init(spaceID: "s", title: "Folder")),
            .createFolder(id: "nested", data: .init(spaceID: "s", parentFolderID: "f", title: "Nested")),
            .createTab(
                id: "child",
                data: .init(
                    spaceID: "s",
                    placement: .spacePinned,
                    pinnedFolderID: "nested",
                    urlString: "https://example.test"
                )
            ),
            .createTab(
                id: "escaped",
                data: .init(
                    spaceID: "s",
                    placement: .spacePinned,
                    pinnedFolderID: "f",
                    urlString: "https://example.test"
                )
            ),
            .createTab(
                id: "peer",
                data: .init(spaceID: "s", placement: .spacePinned, urlString: "https://example.test")
            ),
        ], to: &values, deleted: &deleted)
        return values
    }

    private func space(_ id: String) -> BrowserSpaceSessionSnapshot { .init(
        id: id,
        title: "Space",
        systemImageName: "globe"
    ) }
    private func r(_ type: BrowserSyncChange.EntityType, _ id: String) -> BrowserSyncEntityReference { .init(
        entityType: type,
        entityID: id
    ) }
    private func keyed(_ changes: [BrowserSyncChange]) -> [String: BrowserSyncChange] {
        Dictionary(changes.map { (BrowserSyncOutboxProjection.key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }
}
