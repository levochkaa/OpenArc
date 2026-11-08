// BrowserSyncIncrementalReplayTests.swift

import Foundation
import GRDB
import Testing

// MARK: - Randomized drains

@Test(arguments: ReplayQueueKind.allCases)
func incrementalReplayMatchesFullReplayAcrossRandomDrains(kind: ReplayQueueKind) throws {
    var exactAcks = 0
    var reuses = 0
    for seed in 1...60 {
        var random = ReplayRandom(seed: UInt64(seed) &* 0x9E37 &+ UInt64(kind.seed))
        var drain = ReplayDrain(baseline: replayBaseline(&random, kind: kind))
        for index in 0..<random.int(6...24) {
            drain.append(replayRow(&random, kind: kind, index: index))
        }
        drain.project(expectReuse: false)
        var appended = 100
        while !drain.queue.isEmpty {
            switch random.int(0...19) {
            case 0...1:
                // A pull between ACKs changes the baseline under the whole queue.
                try drain.pull(drain.remoteEvents(&random))
                drain.project(expectReuse: false)
            case 2:
                // A capture during the drain appends a row.
                drain.append(replayRow(&random, kind: kind, index: appended))
                appended += 1
                drain.project(expectReuse: false)
            case 3...4:
                try drain.acknowledge(drain.divergentReceipt(&random))
                drain.project(expectReuse: nil)
            case 5:
                var events = drain.receipt()
                events += drain.remoteEvents(&random)
                try drain.acknowledge(events)
                drain.project(expectReuse: nil)
            default:
                let legacyHead =
                    if case .legacy = drain.queue[0] {
                        true
                    } else {
                        false
                    }
                try drain.acknowledge(drain.receipt())
                // A legacy row hides entities without a tombstone value, so the
                // server's delete events make a different start state.
                if !legacyHead {
                    exactAcks += 1
                }
                drain.project(expectReuse: legacyHead ? nil : true)
            }
        }
        reuses += drain.memo.reuses
    }
    #expect(exactAcks > 100)
    #expect(reuses >= exactAcks)
}

// MARK: - Deletion dominance

/// S01: deleted IDs never reappear, through stale re-creates, later patches and
/// moves, stale remote upserts, and a delete queued after its create.
@Test func incrementalReplayKeepsDeletedTabsDeletedAcrossDrain() throws {
    var drain = ReplayDrain(baseline: replayCanonicalBaseline(
        spaces: ["one"], tabs: [("a", "one", .temporary), ("b", "one", .temporary), ("c", "one", .temporary)],
    ))
    let destination = BrowserSyncSemanticTabDestination(spaceID: "one", placement: .temporary)
    drain.append(.semantic(.init(id: "delete", operations: [.deleteTab(id: "a"), .deleteTab(id: "b")])))
    drain.append(.semantic(.init(id: "stale-create", operations: [
        .createTab(id: "a", data: .init(spaceID: "one", placement: .temporary, urlString: "https://stale.example/")),
    ])))
    drain.append(.semantic(.init(id: "late-edits", operations: [
        .patchTab(id: "b", fields: .init(userTitleOverride: .set("Stale"))),
        .moveTabs(ids: ["a", "b", "c"], destination: destination),
    ])))
    drain.append(.semantic(.init(id: "create", operations: [
        .createTab(id: "d", data: .init(spaceID: "one", placement: .temporary, urlString: "https://d.example/")),
    ])))
    drain.append(.semantic(.init(id: "delete-new", operations: [.deleteTab(id: "d")])))
    let expected: Set = ["space:one", "tab:c"]
    #expect(Set(drain.project(expectReuse: false).keys) == expected)
    var acknowledged = 0
    while !drain.queue.isEmpty {
        try drain.acknowledge(drain.receipt())
        acknowledged += 1
        #expect(Set(drain.project(expectReuse: true).keys) == expected)
        if acknowledged == 1 {
            // Stale upserts after the authoritative delete, older and newer.
            for sequence in [1, 1_000_000] {
                try drain.pull([replayEvent(
                    .init(entityType: .tab, entityID: "a", op: .upsert, spaceData: nil, tabData: .init(
                        spaceID: "one", placement: .temporary, rank: 0, urlString: "https://stale.example/",
                        pinnedURLString: nil, title: nil, userTitleOverride: nil, faviconURLString: nil,
                        lastActivityAt: nil,
                    )),
                    serverSeq: sequence,
                )])
                #expect(Set(drain.project(expectReuse: false).keys) == expected)
            }
        }
    }
    #expect(drain.memo.reuses == acknowledged)
}

/// S02: deleting a Space keeps a child moved out earlier, in its own row or in
/// the same row, and deletes the rest; a later stale move cannot save them.
@Test(arguments: [false, true]) func incrementalReplayKeepsMovedOutChildAndDeletesRestOfSpace(sameRow: Bool) throws {
    var drain = ReplayDrain(baseline: replayCanonicalBaseline(
        spaces: ["one", "two"],
        tabs: [("move", "one", .temporary), ("discard", "one", .temporary), ("pin", "one", .spacePinned)],
    ))
    let moveOut = BrowserSyncSemanticOperation.moveTabs(
        ids: ["move"], destination: .init(spaceID: "two", placement: .temporary),
    )
    if sameRow {
        drain.append(.semantic(.init(id: "move-delete", operations: [moveOut, .deleteSpace(id: "one")])))
    } else {
        drain.append(.semantic(.init(id: "move", operations: [moveOut])))
        drain.append(.semantic(.init(id: "delete", operations: [.deleteSpace(id: "one")])))
    }
    drain.append(.semantic(.init(id: "stale-move", operations: [
        .moveTabs(ids: ["discard", "pin"], destination: .init(spaceID: "two", placement: .temporary)),
        .patchTab(id: "discard", fields: .init(userTitleOverride: .set("Stale"))),
    ])))
    let expected: Set = ["space:two", "tab:move"]
    let projected = drain.project(expectReuse: false)
    #expect(Set(projected.keys) == expected)
    #expect(projected["tab:move"]?.tabData?.spaceID == "two")
    var acknowledged = 0
    while !drain.queue.isEmpty {
        try drain.acknowledge(drain.receipt())
        acknowledged += 1
        let values = drain.project(expectReuse: true)
        #expect(Set(values.keys) == expected)
        #expect(values["tab:move"]?.tabData?.spaceID == "two")
    }
    #expect(drain.memo.reuses == acknowledged)
    #expect(["space:one", "tab:discard", "tab:pin"].allSatisfy { drain.baseline.entities[$0]?.change.op == .delete })
}

/// S12: a Space delete keeps a global Favorite; an explicit Favorite delete is
/// terminal, through a later re-create, patch and stale remote upsert.
@Test func incrementalReplayKeepsFavoriteThroughSpaceDeleteAndHonorsItsDelete() throws {
    let tabs: [(String, String, BrowserTabPlacement)] = [("favorite", "one", .app), ("x", "one", .temporary)]
    var kept = ReplayDrain(baseline: replayCanonicalBaseline(spaces: ["one", "two"], tabs: tabs))
    kept.append(.semantic(.init(id: "delete-space", operations: [.deleteSpace(id: "one")])))
    kept.append(.semantic(.init(id: "rename", operations: [
        .patchTab(id: "favorite", fields: .init(userTitleOverride: .set("Kept"))),
    ])))
    #expect(Set(kept.project(expectReuse: false).keys) == ["space:two", "tab:favorite"])
    while !kept.queue.isEmpty {
        try kept.acknowledge(kept.receipt())
        let values = kept.project(expectReuse: true)
        #expect(Set(values.keys) == ["space:two", "tab:favorite"])
        #expect(values["tab:favorite"]?.tabData?.userTitleOverride == "Kept")
    }
    #expect(kept.memo.reuses == 2)

    var removed = ReplayDrain(baseline: replayCanonicalBaseline(spaces: ["one", "two"], tabs: tabs))
    removed.append(.semantic(.init(id: "delete-favorite", operations: [.deleteTab(id: "favorite")])))
    removed.append(.semantic(.init(id: "re-create", operations: [
        .createTab(id: "favorite", data: .init(
            spaceID: "two", placement: .app, urlString: "https://favorite.example/",
        )),
        .patchTab(id: "favorite", fields: .init(userTitleOverride: .set("Back"))),
    ])))
    removed.append(.semantic(.init(id: "delete-space", operations: [.deleteSpace(id: "one")])))
    #expect(Set(removed.project(expectReuse: false).keys) == ["space:two"])
    while !removed.queue.isEmpty {
        try removed.acknowledge(removed.receipt())
        #expect(Set(removed.project(expectReuse: true).keys) == ["space:two"])
    }
    try removed.pull([replayEvent(
        .init(entityType: .tab, entityID: "favorite", op: .upsert, spaceData: nil, tabData: .init(
            spaceID: "two", placement: .app, rank: 0, urlString: "https://favorite.example/",
            pinnedURLString: nil, title: nil, userTitleOverride: nil, faviconURLString: nil, lastActivityAt: nil,
        )),
        serverSeq: 1_000_000,
    )])
    #expect(Set(removed.project(expectReuse: false).keys) == ["space:two"])
    #expect(removed.memo.reuses == 3)
}

// MARK: - Store

/// The store's ACKs reuse the replay and still write what a fresh store, which
/// replays the whole queue, writes. A rolled-back ACK leaves the memo ahead of
/// the database; the retry replays again and stays exact.
@Test func incrementalReplayStoreDrainMatchesFreshStoresAndSurvivesRolledBackAck() throws {
    let directory = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("sync-incremental-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = try BrowserSyncOwner(baseURL: #require(URL(string: "https://sync.example")), userID: "owner")
    let primaryURL = directory.appendingPathComponent("primary.sqlite")
    let referenceURL = directory.appendingPathComponent("reference.sqlite")
    do {
        let store = try BrowserSQLiteSessionStore(databaseURL: primaryURL)
        try store.bindSyncOwner(owner)
        try store.enableSemanticSyncMutations(for: owner)
        for snapshot in replayStoreEdits() {
            store.saveSnapshot(snapshot)
        }
    }
    for suffix in ["", "-wal", "-shm"] {
        let source = URL(fileURLWithPath: primaryURL.path + suffix)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: referenceURL.path + suffix))
        }
    }
    let primary = try BrowserSQLiteSessionStore(databaseURL: primaryURL)
    let queue = try primary.pendingSyncQueue(for: owner)
    #expect(queue.count >= 8)
    #expect(queue.allSatisfy { $0.protocolVersion == 3 })
    var serverSeq = 1
    for (index, head) in queue.enumerated() {
        let pending = try primary.pendingSyncQueue(for: owner)
        #expect(pending.first == head)
        let events = try replayReceipt(
            baseline: replayStoredBaseline(primaryURL), queue: pending, serverSeq: &serverSeq,
        )
        if index == 2 {
            let database = try DatabaseQueue(path: primaryURL.path)
            try database.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_projection BEFORE INSERT ON browser_sync_baseline
                BEGIN SELECT RAISE(ABORT, 'injected projection failure'); END
                """)
            }
            #expect(throws: DatabaseError.self) {
                try primary.acknowledgeSyncMutation(id: head.id, protocolVersion: 3, events: events, for: owner)
            }
            #expect(try primary.pendingSyncQueue(for: owner) == pending)
            try database.write { db in try db.execute(sql: "DROP TRIGGER fail_projection") }
        }
        let projected = try primary.acknowledgeSyncMutation(
            id: head.id, protocolVersion: 3, events: events, for: owner,
        )
        let reference = try BrowserSQLiteSessionStore(databaseURL: referenceURL)
        let expected = try reference.acknowledgeSyncMutation(
            id: head.id, protocolVersion: 3, events: events, for: owner,
        )
        #expect(try reference.syncReplayReuses() == 0)
        #expect(projected == expected)
        #expect(primary.loadSnapshot() == reference.loadSnapshot())
        #expect(try replayStoredTables(primaryURL) == replayStoredTables(referenceURL))
    }
    #expect(try primary.pendingSyncQueue(for: owner).isEmpty)
    // The first ACK and the retry after the rollback replay the queue; the
    // other ACKs and the rolled-back attempt reuse it.
    #expect(try primary.syncReplayReuses() == queue.count - 1)
}

// MARK: - ReplayQueueKind

enum ReplayQueueKind: String, CaseIterable {
    case semantic
    case folders
    case mixed

    // MARK: Internal

    var seed: Int {
        switch self {
        case .semantic: 1
        case .folders: 2
        case .mixed: 3
        }
    }
}

// MARK: - ReplayDrain

/// A queue drained ACK by ACK, projected after every step both by full replay
/// and through one memo, the way the store projects.
private struct ReplayDrain {
    // MARK: Internal

    var baseline: BrowserSyncOutboxBaseline
    var queue = [BrowserSyncQueuedMutation]()
    let memo = BrowserSyncOutboxReplayMemo()
    var serverSeq = 10000

    /// Capture records local tombstones in the baseline when it queues them.
    mutating func append(_ row: BrowserSyncQueuedMutation) {
        for key in replayDeleteKeys(row) {
            baseline.deletedKeys.insert(key)
        }
        queue.append(row)
    }

    /// `expectReuse` nil accepts either path.
    @discardableResult mutating func project(expectReuse: Bool?) -> [String: BrowserSyncChange] {
        let full = BrowserSyncOutboxProjection.effectiveChanges(baseline: baseline, pending: queue)
        let reusesBefore = memo.reuses
        let incremental = BrowserSyncOutboxProjection.effectiveChanges(
            baseline: baseline, pending: queue, rows: queue.map(replayIdentity), memo: memo,
        )
        if let expectReuse {
            #expect(memo.reuses - reusesBefore == (expectReuse ? 1 : 0))
        }
        #expect(incremental == full)
        #expect(BrowserSyncOutboxReplayState(values: incremental, deleted: [])
            .isIdentical(to: .init(values: full, deleted: [])))
        // No tombstone, local or authoritative, is ever visible.
        #expect(incremental.keys.allSatisfy { !baseline.deletedKeys.contains($0) })
        #expect(incremental.keys.allSatisfy { baseline.entities[$0]?.change.op != .delete })
        return incremental
    }

    mutating func receipt() -> [BrowserSyncEvent] {
        replayEvents(replayReceiptChanges(baseline: baseline, queue: queue), serverSeq: &serverSeq)
    }

    /// What a server that disagreed with the head row would answer: a dropped
    /// event, another rank, or a rejection.
    mutating func divergentReceipt(_ random: inout ReplayRandom) -> [BrowserSyncEvent] {
        var changes = replayReceiptChanges(baseline: baseline, queue: queue)
        switch random.int(0...2) {
        case 0: changes = Array(changes.dropLast())
        case 1:
            if let index = changes.firstIndex(where: { $0.op == .upsert }) {
                let rank = changes[index].spaceData?.rank ?? changes[index].tabData?.rank ?? 0
                changes[index] = BrowserSyncOutboxProjection.replacingRank(of: changes[index], with: rank + 0.5)
            }
        default: changes = []
        }
        return replayEvents(changes, serverSeq: &serverSeq)
    }

    /// A concurrent change from another device: a rename, a delete or a new tab.
    mutating func remoteEvents(_ random: inout ReplayRandom) -> [BrowserSyncEvent] {
        let live = baseline.entities
            .values
            .map(\.change)
            .filter { $0.op == .upsert }
            .sorted { BrowserSyncOutboxProjection.key($0) < BrowserSyncOutboxProjection.key($1) }
        let choice = random.int(0...2)
        if choice == 2 || live.isEmpty {
            let spaces = live.filter { $0.entityType == .space }.map(\.entityID)
            guard let space = spaces.isEmpty ? nil : random.pick(spaces) else { return [] }
            let id = "remote-\(serverSeq)"
            return replayEvents([.init(entityType: .tab, entityID: id, op: .upsert, spaceData: nil, tabData: .init(
                spaceID: space, placement: .temporary, rank: 0, urlString: "https://\(id).example/",
                pinnedURLString: nil, title: nil, userTitleOverride: nil, faviconURLString: nil, lastActivityAt: nil,
            ))], serverSeq: &serverSeq)
        }
        let target = random.pick(live)
        if choice == 1 {
            return replayEvents([.init(
                entityType: target.entityType, entityID: target.entityID, op: .delete, spaceData: nil, tabData: nil,
            )], serverSeq: &serverSeq)
        }
        let renamed: BrowserSyncChange =
            if let data = target.spaceData {
                .init(entityType: .space, entityID: target.entityID, op: .upsert, spaceData: .init(
                    title: "Remote \(serverSeq)", systemImageName: data.systemImageName, rank: data.rank,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed, selectedTabID: data.selectedTabID,
                ), tabData: nil)
            } else if let data = target.tabData {
                .init(entityType: .tab, entityID: target.entityID, op: .upsert, spaceData: nil, tabData: .init(
                    spaceID: data.spaceID, placement: data.placement, rank: data.rank,
                    urlString: "https://remote.example/\(serverSeq)", pinnedURLString: data.pinnedURLString,
                    title: data.title, userTitleOverride: data.userTitleOverride,
                    faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt,
                    pinnedFolderID: data.pinnedFolderID,
                ))
            } else if let data = target.folderData {
                .init(
                    entityType: .folder,
                    entityID: target.entityID,
                    op: .upsert,
                    spaceData: nil,
                    tabData: nil,
                    folderData: .init(
                        spaceID: data.spaceID, parentFolderID: data.parentFolderID, title: "Remote \(serverSeq)",
                        systemImageName: data.systemImageName, rank: data.rank,
                    ),
                )
            } else {
                target
            }
        return replayEvents([renamed], serverSeq: &serverSeq)
    }

    mutating func acknowledge(_ events: [BrowserSyncEvent]) throws {
        try baseline.apply(events)
        queue.removeFirst()
    }

    mutating func pull(_ events: [BrowserSyncEvent]) throws {
        try baseline.apply(events)
    }
}

// MARK: - ReplayRandom

/// SplitMix64, so every run replays the same queues.
struct ReplayRandom: RandomNumberGenerator {
    // MARK: Private

    private var state: UInt64

    // MARK: Internal

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
    mutating func pick<Element>(_ items: [Element]) -> Element { items[int(0...(items.count - 1))] }

    mutating func subset(_ items: [String], count: ClosedRange<Int>) -> [String] {
        var result = [String]()
        for _ in 0..<int(count) {
            let item = pick(items)
            // Moves may repeat an ID; replay skips the repeat.
            result.append(item)
        }
        return result
    }
}

// MARK: - Generators

private let replaySpaces = ["s0", "s1", "s2", "s3"]
private let replayTabs = (0..<12).map { "t\($0)" }
private let replayFolders = ["f0", "f1", "f2"]

private func replayPlacement(_ random: inout ReplayRandom) -> BrowserTabPlacement {
    switch random.int(0...9) {
    case 0...4: .temporary
    case 5...7: .spacePinned
    default: .app
    }
}

private func replayActivity(_ random: inout ReplayRandom) -> String? {
    let day = random.int(1...9)
    let second = random.int(0...5)
    return random.chance(30) ? nil : "2026-11-0\(day)T00:00:0\(second)Z"
}

private func replayAnchor(_ random: inout ReplayRandom, _ pool: [String]) -> String? {
    let id = random.pick(pool)
    return random.chance(35) ? nil : id
}

private func replayReference(
    _ random: inout ReplayRandom, folders: Bool = true,
) -> BrowserSyncEntityReference? {
    let tab = random.pick(replayTabs)
    let folder = random.pick(replayFolders)
    switch random.int(0...9) {
    case 0...3: return nil
    case 4...6: return .init(entityType: .tab, entityID: tab)
    default: return folders ? .init(entityType: .folder, entityID: folder) : .init(entityType: .tab, entityID: tab)
    }
}

private func replaySemanticOperation(_ random: inout ReplayRandom) -> BrowserSyncSemanticOperation {
    let tab = random.pick(replayTabs)
    let space = random.pick(replaySpaces)
    let placement = replayPlacement(&random)
    let activity = replayActivity(&random)
    let version = random.int(0...9)
    let beforeTab = replayAnchor(&random, replayTabs)
    let afterTab = replayAnchor(&random, replayTabs)
    switch random.int(0...14) {
    case 0...2:
        let title: String? = random.chance(30) ? "Title \(version)" : nil
        return .createTab(id: tab, data: .init(
            spaceID: space, placement: placement, urlString: "https://\(tab).example/\(version)",
            userTitleOverride: title, lastActivityAt: activity,
        ), beforeID: beforeTab, afterID: afterTab)
    case 3:
        let beforeSpace = replayAnchor(&random, replaySpaces)
        let afterSpace = replayAnchor(&random, replaySpaces)
        return .createSpace(
            id: space, data: .init(title: "Space \(version)", systemImageName: "circle"),
            beforeID: beforeSpace, afterID: afterSpace,
        )
    case 4...5:
        let url: String? = random.chance(50) ? "https://\(tab).example/p\(version)" : nil
        let title: BrowserSyncPatchValue<String> = random.pick([.unchanged, .clear, .set("Title \(version)")])
        return .patchTab(id: tab, fields: .init(
            urlString: url, userTitleOverride: title, lastActivityAt: activity.map { .set($0) } ?? .unchanged,
        ))
    case 6:
        let collapsed: Bool? = random.chance(50) ? random.chance(50) : nil
        return .patchSpace(id: space, fields: .init(title: "Renamed \(version)", isPinnedSectionCollapsed: collapsed))
    case 7...9:
        let ids = random.subset(replayTabs, count: 1...3)
        return .moveTabs(
            ids: ids, destination: .init(spaceID: space, placement: placement), beforeID: beforeTab, afterID: afterTab,
        )
    case 10:
        let ids = random.subset(replaySpaces, count: 1...2)
        let beforeSpace = replayAnchor(&random, replaySpaces)
        let afterSpace = replayAnchor(&random, replaySpaces)
        return .moveSpaces(ids: ids, beforeID: beforeSpace, afterID: afterSpace)
    case 11...12: return .deleteTab(id: tab)
    default: return .deleteSpace(id: space)
    }
}

private func replayFolderOperation(_ random: inout ReplayRandom) -> BrowserSyncFolderOperation {
    let tab = random.pick(replayTabs)
    let space = random.pick(replaySpaces)
    let folder = random.pick(replayFolders)
    let placement = replayPlacement(&random)
    let version = random.int(0...9)
    let inFolder = placement == .spacePinned && random.chance(50)
    let before = replayReference(&random)
    let after = replayReference(&random)
    switch random.int(0...16) {
    case 0...2:
        return .createTab(id: tab, data: .init(
            spaceID: space, placement: placement, pinnedFolderID: inFolder ? folder : nil,
            urlString: "https://\(tab).example/\(version)", lastActivityAt: replayActivity(&random),
        ), before: before, after: after)
    case 3...4:
        let parent = random.chance(30) ? random.pick(replayFolders) : nil
        return .createFolder(
            id: folder, data: .init(spaceID: space, parentFolderID: parent, title: "Folder \(version)"),
            before: before, after: after,
        )
    case 5:
        return .createSpace(id: space, data: .init(title: "Space \(version)", systemImageName: "circle"))
    case 6: return .patchFolder(id: folder, fields: .init(title: "Folder \(version)"))
    case 7: return .patchTab(id: tab, fields: .init(userTitleOverride: .set("Title \(version)")))
    case 8: return .patchSpace(id: space, fields: .init(title: "Renamed \(version)"))
    case 9...11:
        var items = random.subset(replayTabs, count: 1...2).map {
            BrowserSyncEntityReference(entityType: .tab, entityID: $0)
        }
        if placement == .spacePinned, random.chance(40) {
            items.append(.init(entityType: .folder, entityID: random.pick(replayFolders)))
        }
        return .move(
            items: items,
            destination: .tabs(spaceID: space, placement: placement, pinnedFolderID: inFolder ? folder : nil),
            before: before, after: after,
        )
    case 12:
        let items = random.subset(replaySpaces, count: 1...2).map {
            BrowserSyncEntityReference(entityType: .space, entityID: $0)
        }
        return .move(items: items, destination: .spaces)
    case 13: return .deleteFolder(id: folder)
    case 14...15: return .deleteTab(id: tab)
    default: return .deleteSpace(id: space)
    }
}

private func replayLegacyChange(_ random: inout ReplayRandom) -> BrowserSyncChange {
    let tab = random.pick(replayTabs)
    let space = random.pick(replaySpaces)
    let placement = replayPlacement(&random)
    let rank = Double(random.int(0...9))
    let activity = replayActivity(&random)
    switch random.int(0...9) {
    case 0...5:
        return .init(entityType: .tab, entityID: tab, op: .upsert, spaceData: nil, tabData: .init(
            spaceID: space, placement: placement, rank: rank, urlString: "https://\(tab).example/legacy",
            pinnedURLString: placement == .spacePinned ? "https://\(tab).example/" : nil, title: nil,
            userTitleOverride: nil, faviconURLString: nil, lastActivityAt: activity,
        ))
    case 6:
        return .init(entityType: .space, entityID: space, op: .upsert, spaceData: .init(
            title: "Legacy", systemImageName: "circle", rank: rank, isPinnedSectionCollapsed: false,
            selectedTabID: nil,
        ), tabData: nil)
    case 7...8: return .init(entityType: .tab, entityID: tab, op: .delete, spaceData: nil, tabData: nil)
    default: return .init(entityType: .space, entityID: space, op: .delete, spaceData: nil, tabData: nil)
    }
}

private func replayRow(_ random: inout ReplayRandom, kind: ReplayQueueKind, index: Int) -> BrowserSyncQueuedMutation {
    let id = "row-\(index)"
    let count = random.int(1...3)
    let form: Int =
        switch kind {
        case .semantic: 0
        case .folders: 1
        case .mixed: random.pick([0, 0, 0, 1, 1, 1, 2, 3])
        }
    switch form {
    case 0: return .semantic(.init(id: id, operations: (0..<count).map { _ in replaySemanticOperation(&random) }))
    case 1: return .folders(.init(id: id, operations: (0..<count).map { _ in replayFolderOperation(&random) }))
    case 2: return .legacy(.init(id: id, changes: (0..<count).map { _ in replayLegacyChange(&random) }))
    default:
        return .expiry(.init(
            id: String(format: "00000000-0000-4000-8000-%012d", index),
            operations: [.init(id: random.pick(replayTabs), expectedServerSeq: 1, inactiveForSeconds: 86400)],
        ))
    }
}

/// Canonical state from creates over an empty baseline, plus permanent server
/// and acknowledged local tombstones.
private func replayBaseline(_ random: inout ReplayRandom, kind: ReplayQueueKind) -> BrowserSyncOutboxBaseline {
    let spaces = Array(replaySpaces.prefix(random.int(2...3)))
    var seed: BrowserSyncQueuedMutation
    if kind == .semantic {
        var operations = spaces.map {
            BrowserSyncSemanticOperation.createSpace(id: $0, data: .init(title: $0, systemImageName: "circle"))
        }
        for tab in replayTabs.prefix(random.int(4...9)) {
            let space = random.pick(spaces)
            let placement = replayPlacement(&random)
            operations.append(.createTab(id: tab, data: .init(
                spaceID: space, placement: placement, urlString: "https://\(tab).example/",
                lastActivityAt: replayActivity(&random),
            )))
        }
        seed = .semantic(.init(id: "seed", operations: operations))
    } else {
        var operations = spaces.map {
            BrowserSyncFolderOperation.createSpace(id: $0, data: .init(title: $0, systemImageName: "circle"))
        }
        let folders = Array(replayFolders.prefix(random.int(0...2)))
        for folder in folders {
            operations.append(.createFolder(id: folder, data: .init(spaceID: random.pick(spaces), title: folder)))
        }
        for tab in replayTabs.prefix(random.int(4...9)) {
            let space = random.pick(spaces)
            let placement = replayPlacement(&random)
            let folder: String? = placement == .spacePinned && !folders.isEmpty && random.chance(50)
                ? random.pick(folders)
                : nil
            operations.append(.createTab(id: tab, data: .init(
                spaceID: space, placement: placement, pinnedFolderID: folder,
                urlString: "https://\(tab).example/", lastActivityAt: replayActivity(&random),
            )))
        }
        seed = .folders(.init(id: "seed", operations: operations))
    }
    var state = BrowserSyncOutboxProjection.replayStart(baseline: .init(), pending: [])
    BrowserSyncOutboxProjection.replay(seed, into: &state)
    var baseline = BrowserSyncOutboxBaseline()
    var sequence = 1
    for (key, change) in state.values.sorted(by: { $0.key < $1.key }) where change.op == .upsert {
        baseline.entities[key] = .init(serverSeq: sequence, change: change)
        sequence += 1
    }
    for tab in replayTabs.suffix(3) where random.chance(40) {
        let key = BrowserSyncOutboxProjection.key(type: .tab, id: tab)
        if random.chance(50) {
            baseline.entities[key] = .init(serverSeq: sequence, change: .init(
                entityType: .tab, entityID: tab, op: .delete, spaceData: nil, tabData: nil,
            ))
            sequence += 1
        }
        baseline.deletedKeys.insert(key)
    }
    return baseline
}

private func replayCanonicalBaseline(
    spaces: [String], tabs: [(String, String, BrowserTabPlacement)],
) -> BrowserSyncOutboxBaseline {
    var operations = spaces.map {
        BrowserSyncSemanticOperation.createSpace(id: $0, data: .init(title: $0, systemImageName: "circle"))
    }
    for (id, space, placement) in tabs {
        operations.append(.createTab(
            id: id, data: .init(spaceID: space, placement: placement, urlString: "https://\(id).example/"),
        ))
    }
    var state = BrowserSyncOutboxProjection.replayStart(baseline: .init(), pending: [])
    BrowserSyncOutboxProjection.replay(.semantic(.init(id: "seed", operations: operations)), into: &state)
    var baseline = BrowserSyncOutboxBaseline()
    for (index, entry) in state.values.sorted(by: { $0.key < $1.key }).enumerated() {
        baseline.entities[entry.key] = .init(serverSeq: index + 1, change: entry.value)
    }
    return baseline
}

private func replayStoreEdits() -> [BrowserTabSessionSnapshot] {
    func tab(
        _ id: String, _ space: String, _ placement: BrowserTabPlacement = .temporary, title: String? = nil,
    ) -> BrowserTabSessionSnapshotTab {
        .init(
            id: id,
            urlString: "https://\(id).example/",
            userTitleOverride: title,
            placement: placement,
            spaceID: space,
        )
    }
    func snapshot(_ spaces: [String], _ tabs: [BrowserTabSessionSnapshotTab]) -> BrowserTabSessionSnapshot {
        .init(spaces: spaces.map { .init(id: $0, title: $0, systemImageName: "circle") }, tabs: tabs)
    }
    return [
        snapshot(["one", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("a", "one"), tab("b", "one"),
            tab("c", "one"), tab("d", "two"),
        ]),
        snapshot(["one", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("a", "one"),
            tab("b", "one", title: "Renamed"), tab("c", "one"), tab("d", "two"),
        ]),
        snapshot(["one", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("b", "one", title: "Renamed"),
            tab("c", "one"), tab("a", "one"), tab("d", "two"),
        ]),
        snapshot(["one", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("b", "one", title: "Renamed"),
            tab("a", "one"), tab("c", "two"), tab("d", "two"),
        ]),
        snapshot(["one", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("a", "one"), tab("c", "two"),
            tab("d", "two"),
        ]),
        snapshot(["one", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("e", "one"), tab("a", "one"),
            tab("c", "two"), tab("d", "two"),
        ]),
        snapshot(["one", "three", "two"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("e", "one"), tab("a", "one"),
            tab("d", "three"), tab("c", "two"),
        ]),
        snapshot(["one", "three"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("e", "one"), tab("a", "one"),
            tab("d", "three"),
        ]),
        snapshot(["one", "three"], [
            tab("fav", "one", .app), tab("pin", "one", .spacePinned), tab("e", "one", .spacePinned),
            tab("a", "one"), tab("b", "one"), tab("d", "three"),
        ]),
        snapshot(["three"], [tab("fav", "one", .app), tab("d", "three"), tab("a", "three")]),
    ]
}

// MARK: - Simulated server

private func replayDeleteKeys(_ row: BrowserSyncQueuedMutation) -> [String] {
    switch row {
    case .legacy(let mutation):
        mutation.changes.filter { $0.op == .delete }.map(BrowserSyncOutboxProjection.key)
    case .semantic(let mutation):
        mutation.operations.compactMap {
            switch $0 {
            case .deleteSpace(let id): BrowserSyncOutboxProjection.key(type: .space, id: id)
            case .deleteTab(let id): BrowserSyncOutboxProjection.key(type: .tab, id: id)
            default: nil
            }
        }
    case .folders(let mutation):
        mutation.operations.compactMap {
            switch $0 {
            case .deleteSpace(let id): BrowserSyncOutboxProjection.key(type: .space, id: id)
            case .deleteTab(let id): BrowserSyncOutboxProjection.key(type: .tab, id: id)
            case .deleteFolder(let id): BrowserSyncOutboxProjection.key(type: .folder, id: id)
            default: nil
            }
        }
    case .expiry: []
    }
}

/// Every entity the head row changed, at the value the client replayed for it,
/// as the server's renumbering publishes it.
private func replayReceiptChanges(
    baseline: BrowserSyncOutboxBaseline, queue: [BrowserSyncQueuedMutation],
) -> [BrowserSyncChange] {
    let start = BrowserSyncOutboxProjection.replayStart(baseline: baseline, pending: queue)
    var after = start
    BrowserSyncOutboxProjection.replay(queue[0], into: &after)
    var changes = after.values
        .filter { start.values[$0.key] != $0.value }
        .sorted { $0.key < $1.key }
        .map(\.value)
    for key in after.deleted.subtracting(start.deleted).sorted() where after.values[key]?.op != .delete {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard let type = BrowserSyncChange.EntityType(rawValue: parts[0]) else { continue }
        changes.append(.init(entityType: type, entityID: parts[1], op: .delete, spaceData: nil, tabData: nil))
    }
    return changes
}

private func replayReceipt(
    baseline: BrowserSyncOutboxBaseline, queue: [BrowserSyncQueuedMutation], serverSeq: inout Int,
) -> [BrowserSyncEvent] {
    replayEvents(replayReceiptChanges(baseline: baseline, queue: queue), serverSeq: &serverSeq)
}

private func replayEvents(_ changes: [BrowserSyncChange], serverSeq: inout Int) -> [BrowserSyncEvent] {
    changes.map { change in
        serverSeq += 1
        return replayEvent(change, serverSeq: serverSeq)
    }
}

private func replayEvent(_ change: BrowserSyncChange, serverSeq: Int) -> BrowserSyncEvent {
    let data: BrowserSyncEventData =
        if change.op == .delete {
            .deleted(id: change.entityID)
        } else if let space = change.spaceData {
            .space(.init(
                id: change.entityID, title: space.title, systemImageName: space.systemImageName, rank: space.rank,
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed, selectedTabID: space.selectedTabID,
            ))
        } else if let tab = change.tabData {
            .tab(.init(
                id: change.entityID, spaceID: tab.spaceID, placement: tab.placement, rank: tab.rank,
                urlString: tab.urlString, pinnedURLString: tab.pinnedURLString, title: tab.title,
                userTitleOverride: tab.userTitleOverride, faviconURLString: tab.faviconURLString,
                lastActivityAt: tab.lastActivityAt, pinnedFolderID: tab.pinnedFolderID,
            ))
        } else if let folder = change.folderData {
            .folder(.init(
                id: change.entityID, spaceID: folder.spaceID, parentFolderID: folder.parentFolderID,
                title: folder.title, systemImageName: folder.systemImageName, rank: folder.rank,
            ))
        } else {
            .deleted(id: change.entityID)
        }
    return BrowserSyncEvent(
        serverSeq: serverSeq, deviceID: nil, entityType: change.entityType.rawValue, entityID: change.entityID,
        op: change.op.rawValue, data: data, createdAt: "2026-11-08T00:00:00Z",
    )
}

private func replayIdentity(_ row: BrowserSyncQueuedMutation) -> BrowserSyncQueuedRowIdentity {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload: Data? =
        switch row {
        case .legacy(let mutation): try? encoder.encode(mutation)
        case .semantic(let mutation): try? encoder.encode(mutation)
        case .folders(let mutation): try? encoder.encode(mutation)
        case .expiry(let mutation): try? encoder.encode(mutation)
        }
    return .init(protocolVersion: row.protocolVersion, payload: payload ?? Data())
}

private func replayStoredBaseline(_ url: URL) throws -> BrowserSyncOutboxBaseline {
    let payload = try DatabaseQueue(path: url.path).read { db in
        try Data.fetchOne(db, sql: "SELECT payload FROM browser_sync_baseline WHERE id = 1")
    }
    return try JSONDecoder().decode(BrowserSyncOutboxBaseline.self, from: #require(payload))
}

/// The baseline and every projected row, in stored order. JSON key order of a
/// dictionary or set varies between instances, so the baseline is compared
/// decoded, in sorted order.
private func replayStoredTables(_ url: URL) throws -> [String] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let baseline = try replayStoredBaseline(url)
    var rows = try baseline.entities.sorted { $0.key < $1.key }.map { key, entity in
        try "\(key) \(entity.serverSeq) " + String(decoding: encoder.encode(entity.change), as: UTF8.self)
    }
    rows += baseline.deletedKeys.sorted()
    try DatabaseQueue(path: url.path).read { db in
        for table in ["browser_spaces", "browser_tabs", "browser_pinned_tab_folders", "browser_sync_outbox"] {
            rows += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
        }
    }
    return rows
}
