// BrowserSyncProjectionIndexTests.swift

import Foundation
import Testing

@Test func projectionIndexPreservesSelectionAcrossInterleavedListsAndDefaultSpace() throws {
    let defaultID = BrowserChromeModel.defaultSpaceID
    let local = BrowserTabSessionSnapshot(spaces: [
        .init(id: defaultID, title: "Default", systemImageName: "circle", selectedTabIndex: 2),
        .init(id: "other", title: "Other", systemImageName: "square", selectedTabIndex: 1),
    ], tabs: [
        indexLocalTab("default-temp-a", space: nil),
        indexLocalTab("other-temp", space: "other"),
        indexLocalTab("favorite", space: nil, placement: .app),
        indexLocalTab("default-pin", space: nil, placement: .spacePinned),
        indexLocalTab("other-pin", space: "other", placement: .spacePinned),
        indexLocalTab("default-temp-b", space: nil),
    ])
    let projected = indexProject([
        indexSpace(defaultID, rank: 0), indexSpace("other", rank: 1),
        indexTab("default-temp-b", space: defaultID, rank: 0),
        indexTab("other-temp", space: "other", rank: 0),
        indexTab("default-temp-a", space: defaultID, rank: 1),
        indexTab("favorite", space: "missing-historical-parent", placement: .app, rank: 0),
        indexTab("other-pin", space: "other", placement: .spacePinned, rank: 9),
        indexTab("default-pin", space: defaultID, placement: .spacePinned, rank: 9),
    ], local: local)
    #expect(projected.tabs.compactMap(\.id) == [
        "favorite", "default-pin", "default-temp-b", "default-temp-a", "other-pin", "other-temp",
    ])
    let spaces = try #require(projected.spaces)
    // Local sidebar order is pins then temporaries. Global Favorites never use
    // a Space's selectedTabIndex, even with a nil/default remembered Space.
    #expect(spaces[0].selectedTabIndex == 1)
    #expect(spaces[1].selectedTabIndex == 1)
}

@Test func projectionIndexRetainsNilIdentitySlotsAndRejectsInvalidSelectionIndices() throws {
    let changes = [indexSpace("s"), indexTab("named", space: "s", placement: .spacePinned)]
    for (selected, expected): (Int?, Int?) in [(0, nil), (1, 0), (-1, nil), (2, nil), (nil, nil)] {
        let local = BrowserTabSessionSnapshot(spaces: [
            .init(id: "s", title: "Space", systemImageName: "circle", selectedTabIndex: selected),
        ], tabs: [
            indexLocalTab(nil, space: "s", placement: .spacePinned),
            indexLocalTab("named", space: "s", placement: .spacePinned),
        ])
        let projected = indexProject(changes, local: local)
        let space = try #require(projected.spaces?.first)
        #expect(space.selectedTabIndex == expected)
    }
}

@Test func projectionIndexClearsSelectionWhenSelectedIdentityIsDeletedOrMovesToAnotherSpace() throws {
    let local = BrowserTabSessionSnapshot(spaces: [
        .init(id: "s", title: "Source", systemImageName: "circle", selectedTabIndex: 1),
        .init(id: "t", title: "Target", systemImageName: "square", selectedTabIndex: 0),
    ], tabs: [
        indexLocalTab("selected", space: "s"),
        indexLocalTab("source-pin", space: "s", placement: .spacePinned),
        indexLocalTab("target", space: "t"),
    ])
    let common = [
        indexSpace("s"), indexSpace("t", rank: 1),
        indexTab("source-pin", space: "s", placement: .spacePinned),
        indexTab("target", space: "t", rank: 1),
    ]
    let deleted = indexProject(common + [.init(
        entityType: .tab, entityID: "selected", op: .delete, spaceData: nil, tabData: nil,
    )], local: local)
    #expect(try #require(deleted.spaces?.first).selectedTabIndex == nil)
    let moved = indexProject(common + [indexTab("selected", space: "t", rank: 0)], local: local)
    let spaces = try #require(moved.spaces)
    #expect(spaces[0].selectedTabIndex == nil)
    #expect(spaces[1].selectedTabIndex == 1)
    let becameFavorite = indexProject(common + [indexTab("selected", space: "s", placement: .app)], local: local)
    #expect(try #require(becameFavorite.spaces?.first).selectedTabIndex == nil)
}

@Test func projectionIndexUsesIdentityForRankTiesAndFirstDuplicateLocalSpace() throws {
    let local = BrowserTabSessionSnapshot(spaces: [
        .init(id: "a-space", title: "First", systemImageName: "circle", selectedTabIndex: 1),
        .init(id: "a-space", title: "Duplicate", systemImageName: "square", selectedTabIndex: 0),
        .init(id: "z-space", title: "Last", systemImageName: "star", selectedTabIndex: 0),
    ], tabs: [
        indexLocalTab("z-tab", space: "a-space"), indexLocalTab("a-tab", space: "a-space"),
        indexLocalTab("other", space: "z-space"),
    ])
    let projected = indexProject([
        indexSpace("z-space", rank: 10), indexSpace("a-space", rank: 10),
        indexTab("z-tab", space: "a-space", rank: 7), indexTab("a-tab", space: "a-space", rank: 7),
        indexTab("other", space: "z-space", rank: -20),
    ], local: local)
    #expect(projected.spaces?.map(\.id) == ["a-space", "z-space"])
    #expect(projected.tabs.compactMap(\.id) == ["a-tab", "z-tab", "other"])
    #expect(try #require(projected.spaces?.first).selectedTabIndex == 0)
}

@Test func projectionIndexDateParsingPreservesSecondOffsetAndFallbackBehavior() throws {
    let cases: [(id: String, remote: String?, local: TimeInterval?, expected: TimeInterval?)] = [
        ("absent", nil, 41.25, 41.25),
        ("invalid", "not-a-date", 42.5, 42.5),
        ("seconds", "1970-01-01T00:00:10Z", 99, 10),
        ("offset", "1970-01-01T01:30:15+01:30", 99, 15),
        ("epoch", "1970-01-01T00:00:00Z", 99, 0),
        ("fractional", "1970-01-01T00:00:20.125Z", 43.75, 20.125),
        ("fractional-no-local", "1970-01-01T00:00:20.125Z", nil, 20.125),
        ("invalid-no-local", "invalid", nil, nil),
        ("absent-no-local", nil, nil, nil),
    ]
    let local = BrowserTabSessionSnapshot(tabs: cases.map { value in
        .init(id: value.id, urlString: "https://example.com/", spaceID: "s", lastActivityTimestamp: value.local)
    })
    let projected = indexProject([indexSpace("s")] + cases.enumerated().map { index, value in
        indexTab(value.id, space: "s", rank: Double(index), activity: value.remote)
    }, local: local)
    for value in cases {
        let tab = try #require(projected.tabs.first { $0.id == value.id })
        #expect(tab.lastActivityTimestamp == value.expected)
    }
}

@Test func projectionIndexCanonicalDatesKeepExactUTCSecondPrecisionAndSkipNilIdentity() throws {
    let values: [(String, TimeInterval?, String?)] = [
        ("epoch", 0, "1970-01-01T00:00:00Z"),
        ("subsecond", 123.125, "1970-01-01T00:02:03Z"),
        ("pre-epoch", -1.125, "1969-12-31T23:59:58Z"),
        ("missing", nil, nil),
    ]
    let snapshot = BrowserTabSessionSnapshot(tabs: [
        .init(urlString: "https://no-identity.example/", lastActivityTimestamp: 600),
    ] + values.map { id, timestamp, _ in
        .init(id: id, urlString: "https://example.com/", lastActivityTimestamp: timestamp)
    })
    let changes = BrowserSyncOutboxProjection.canonicalChanges(snapshot)
    #expect(changes.filter { $0.entityType == .space }.map(\.entityID) == [BrowserChromeModel.defaultSpaceID])
    #expect(changes.filter { $0.entityType == .tab }.map(\.entityID) == values.map(\.0))
    for (index, value) in values.enumerated() {
        let data = try #require(changes.first { $0.entityID == value.0 }?.tabData)
        #expect(data.lastActivityAt == value.2)
        #expect(data.spaceID == BrowserChromeModel.defaultSpaceID)
        // Skipping an anonymous legacy row does not renumber the remaining v2 ranks.
        #expect(data.rank == Double(index + 1))
    }
}

private func indexLocalTab(
    _ id: String?, space: String?, placement: BrowserTabPlacement = .temporary,
) -> BrowserTabSessionSnapshotTab {
    .init(id: id, urlString: "https://example.com/", placement: placement, spaceID: space)
}

private func indexSpace(_ id: String, rank: Double = 0) -> BrowserSyncChange {
    .init(entityType: .space, entityID: id, op: .upsert, spaceData: .init(
        title: id, systemImageName: "circle", rank: rank, isPinnedSectionCollapsed: false, selectedTabID: nil,
    ), tabData: nil)
}

private func indexTab(
    _ id: String, space: String, placement: BrowserTabPlacement = .temporary, rank: Double = 0, activity: String? = nil,
) -> BrowserSyncChange {
    .init(entityType: .tab, entityID: id, op: .upsert, spaceData: nil, tabData: .init(
        spaceID: space, placement: placement, rank: rank, urlString: "https://example.com/",
        pinnedURLString: nil, title: nil, userTitleOverride: nil, faviconURLString: nil, lastActivityAt: activity,
    ))
}

private func indexProject(
    _ changes: [BrowserSyncChange], local: BrowserTabSessionSnapshot,
) -> BrowserTabSessionSnapshot {
    var baseline = BrowserSyncOutboxBaseline()
    for (sequence, change) in changes.enumerated() {
        baseline.entities[BrowserSyncOutboxProjection.key(change)] = .init(serverSeq: sequence + 1, change: change)
    }
    return BrowserSyncOutboxProjection.snapshot(
        baseline: baseline,
        pending: [BrowserSyncQueuedMutation](),
        local: local,
    )
}
