// BrowserSyncOutbox.swift

import Foundation

// MARK: - BrowserSyncOutboxError

enum BrowserSyncOutboxError: Error, Equatable {
    case invalidLimit
    case invalidEvent
}

// MARK: - BrowserSyncActivityDates

/// Pending activity never decreases a known canonical value. Keep this policy
/// in projections: canonical events and immutable queued requests retain their bytes.
struct BrowserSyncActivityDates {
    // MARK: Private

    private let seconds = Date.ISO8601FormatStyle()
    private let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    // MARK: Internal

    func latest(_ current: String?, _ incoming: String?) -> String? {
        guard let candidate = timestamp(incoming) else {
            return timestamp(current) == nil ? nil : current
        }
        guard let previous = timestamp(current) else { return incoming }
        return candidate > previous ? incoming : current
    }

    func projectedTimestamp(_ incoming: String?, local: TimeInterval?) -> TimeInterval? {
        let previous = local.flatMap { $0.isFinite ? $0 : nil }
        guard let candidate = timestamp(incoming) else { return previous }
        // The wire normally uses seconds. Preserve an existing local fraction of
        // that same value, but never override a different authoritative date.
        if let previous, floor(previous) == candidate {
            return previous
        }
        return candidate
    }

    private func timestamp(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        return ((try? fractional.parse(value)) ?? (try? seconds.parse(value)))?.timeIntervalSince1970
    }
}

// MARK: - BrowserSyncOutboxBaseline

struct BrowserSyncOutboxBaseline: Codable {
    struct Entity: Codable {
        let serverSeq: Int
        let change: BrowserSyncChange
    }

    var entities = [String: Entity]()
    var deletedKeys = Set<String>()

    mutating func recordLocalDeletes(_ changes: [BrowserSyncChange]) {
        for change in changes where change.op == .delete {
            deletedKeys.insert(BrowserSyncOutboxProjection.key(change))
        }
    }

    mutating func apply(_ events: [BrowserSyncEvent]) throws {
        for event in events.sorted(by: { $0.serverSeq < $1.serverSeq }) {
            guard let type = BrowserSyncChange.EntityType(rawValue: event.entityType),
                  let operation = BrowserSyncChange.Operation(rawValue: event.op), event.serverSeq >= 0
            else { throw BrowserSyncOutboxError.invalidEvent }
            let key = BrowserSyncOutboxProjection.key(type: type, id: event.entityID)
            // Replayed receipts may predate the latest v1 survivor of this identity.
            // Check sequence before turning a remote delete into a permanent tombstone.
            guard event.serverSeq > (entities[key]?.serverSeq ?? -1) else { continue }
            if operation == .delete {
                deletedKeys.insert(key)
                entities[key] = Entity(
                    serverSeq: max(event.serverSeq, entities[key]?.serverSeq ?? 0),
                    change: BrowserSyncChange(
                        entityType: type,
                        entityID: event.entityID,
                        op: .delete,
                        spaceData: nil,
                        tabData: nil,
                    ),
                )
                continue
            }
            // A local-only delete may be later than pending creates in the FIFO.
            // Retain acknowledged canonical parents for those earlier operations;
            // projection still hides local deletes after replay. Server tombstones
            // are permanent and can never accept another upsert of this identity.
            guard entities[key]?.change.op != .delete else { continue }
            let change: BrowserSyncChange
            switch (type, event.data) {
            case (.space, .space(let data)):
                guard let title = data.title, let icon = data.systemImageName, let rank = data.rank,
                      let collapsed = data.isPinnedSectionCollapsed
                else { throw BrowserSyncOutboxError.invalidEvent }
                change = BrowserSyncChange(
                    entityType: .space, entityID: event.entityID, op: .upsert,
                    spaceData: BrowserSyncSpacePayload(
                        title: title,
                        systemImageName: icon,
                        rank: rank,
                        isPinnedSectionCollapsed: collapsed,
                        selectedTabID: data.selectedTabID,
                    ),
                    tabData: nil,
                )
            case (.tab, .tab(let data)):
                guard let spaceID = data.spaceID, let placement = data.placement,
                      let rank = data.rank, let url = data.urlString
                else { throw BrowserSyncOutboxError.invalidEvent }
                change = BrowserSyncChange(
                    entityType: .tab, entityID: event.entityID, op: .upsert, spaceData: nil,
                    tabData: BrowserSyncTabPayload(
                        spaceID: spaceID, placement: placement, rank: rank, urlString: url,
                        pinnedURLString: data.pinnedURLString, title: data.title,
                        userTitleOverride: data.userTitleOverride,
                        faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt,
                        pinnedFolderID: data.pinnedFolderID,
                    ),
                )
            case (.folder, .folder(let data)):
                guard let spaceID = data.spaceID, let title = data.title, let rank = data.rank else {
                    throw BrowserSyncOutboxError.invalidEvent
                }
                change = BrowserSyncChange(
                    entityType: .folder, entityID: event.entityID, op: .upsert,
                    spaceData: nil, tabData: nil,
                    folderData: .init(
                        spaceID: spaceID,
                        parentFolderID: data.parentFolderID,
                        title: title,
                        systemImageName: data.systemImageName,
                        rank: rank,
                    ),
                )
            default: throw BrowserSyncOutboxError.invalidEvent
            }
            entities[key] = Entity(serverSeq: event.serverSeq, change: change)
        }
    }
}

// MARK: - BrowserSyncQueuedRowIdentity

/// One stored queue row as bytes. Rows that decode to equal values can still
/// differ in bytes, for example in Unicode normalization.
struct BrowserSyncQueuedRowIdentity: Equatable {
    let protocolVersion: Int
    let payload: Data
}

// MARK: - BrowserSyncOutboxReplayState

/// Queue replay state: canonical values with the replayed rows applied, and the
/// keys hidden so far.
struct BrowserSyncOutboxReplayState {
    var values: [String: BrowserSyncChange]
    var deleted: Set<String>

    /// Equal down to string bytes and rank bits, so replaying the same rows
    /// from either state yields the same bytes. `==` would accept strings that
    /// differ only in Unicode normalization.
    func isIdentical(to other: Self) -> Bool {
        guard values.count == other.values.count, deleted.count == other.deleted.count else { return false }
        for key in deleted {
            guard let index = other.deleted.firstIndex(of: key), identical(other.deleted[index], key) else {
                return false
            }
        }
        for (key, value) in values {
            guard let index = other.values.index(forKey: key) else { return false }
            let entry = other.values[index]
            guard identical(entry.key, key), identical(entry.value, value) else { return false }
        }
        return true
    }
}

// MARK: - BrowserSyncOutboxReplayMemo

/// The last queue replay, kept so an ACK need not replay the rest of the queue.
/// It holds only facts about the pure replay: for the exact rows in `rows`, the
/// state after the first row and the state after all of them, reached from one
/// start. A rolled-back transaction, another account or another writer can
/// make it useless, never wrong: reuse also requires a byte-identical start.
final class BrowserSyncOutboxReplayMemo {
    // MARK: Internal

    /// How many replays this memo skipped.
    fileprivate(set) var reuses = 0

    fileprivate private(set) var rows = [BrowserSyncQueuedRowIdentity]()
    fileprivate private(set) var head: BrowserSyncOutboxReplayState?
    fileprivate private(set) var end: BrowserSyncOutboxReplayState?

    fileprivate func remember(
        rows: [BrowserSyncQueuedRowIdentity], head: BrowserSyncOutboxReplayState?,
        end: BrowserSyncOutboxReplayState,
    ) {
        // An empty queue has nothing to skip; drop the states.
        self.rows = rows
        self.head = rows.isEmpty ? nil : head
        self.end = rows.isEmpty ? nil : end
    }
}

// MARK: - BrowserSyncOutboxProjection

enum BrowserSyncOutboxProjection {
    // MARK: Internal

    static func key(type: BrowserSyncChange.EntityType, id: String) -> String { "\(type.rawValue):\(id)" }
    static func key(_ change: BrowserSyncChange) -> String { key(type: change.entityType, id: change.entityID) }

    static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
    ) -> [BrowserSyncChange] {
        delta(
            before: canonicalChanges(previous ?? BrowserTabSessionSnapshot(tabs: [])),
            after: canonicalChanges(snapshot),
        )
    }

    static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncMutation],
    ) -> [BrowserSyncChange] {
        changes(
            from: previous,
            to: snapshot,
            baseline: baseline,
            pending: pending.map(BrowserSyncQueuedMutation.legacy),
        )
    }

    @_disfavoredOverload static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncQueuedMutation],
    ) -> [BrowserSyncChange] {
        let before = canonicalChanges(previous ?? BrowserTabSessionSnapshot(tabs: []))
        let after = canonicalChanges(snapshot)
        let effective = effectiveChanges(baseline: baseline, pending: pending)
        let ranks = effective.compactMapValues { $0.spaceData?.rank ?? $0.tabData?.rank }
        // v2 has one rank list for spaces and one global list for tabs. This avoids
        // accidental reorder from metadata edits; concurrent reorder conflict resolution
        // still uses the server's existing last-writer behavior (S07).
        var normalizedTypes = Set<String>()
        for type in [BrowserSyncChange.EntityType.space, .tab] {
            let beforeIDs = before.filter { $0.entityType == type }.map(\.entityID)
            let afterIDs = after.filter { $0.entityType == type }.map(\.entityID)
            let afterSet = Set(afterIDs)
            // A deletion leaves surviving relative order intact. Preserve sparse ranks
            // until an insertion or reorder actually requires renumbering the list.
            if beforeIDs.filter({ afterSet.contains($0) }) != afterIDs {
                normalizedTypes.insert(type.rawValue)
            }
        }
        return delta(
            before: before.map { replacingRank(of: $0, with: ranks[key($0)]) },
            after: after.map { change in
                normalizedTypes.contains(change.entityType.rawValue)
                    ? change
                    : replacingRank(of: change, with: ranks[key(change)])
            },
        )
    }

    static func removingDeletedEntities(
        from snapshot: BrowserTabSessionSnapshot, baseline: BrowserSyncOutboxBaseline,
    ) -> BrowserTabSessionSnapshot {
        let deleted = baseline.deletedKeys
        var deletedFolderIDs = Set((snapshot.pinnedTabFolders ?? [])
            .filter {
                deleted.contains(key(type: .folder, id: $0.id)) || deleted.contains(key(type: .space, id: $0.spaceID))
                    || $0.parentFolderID.map { deleted.contains(key(type: .folder, id: $0)) } == true
            }
            .map(\.id))
        var children = [String: [String]]()
        for folder in snapshot.pinnedTabFolders ?? [] {
            if let parent = folder.parentFolderID {
                children[parent, default: []].append(folder.id)
            }
        }
        var queue = Array(deletedFolderIDs)
        var index = 0
        while index < queue.count {
            for child in children[queue[index]] ?? [] where deletedFolderIDs.insert(child).inserted {
                queue.append(child)
            }
            index += 1
        }
        return BrowserTabSessionSnapshot(
            spaces: snapshot.spaces?.filter { !deleted.contains(key(type: .space, id: $0.id)) },
            pinnedTabFolders: snapshot.pinnedTabFolders?
                .filter { !deletedFolderIDs.contains($0.id) },
            tabs: snapshot.tabs.filter { tab in
                (tab.placement == .app
                    || !deleted.contains(key(type: .space, id: tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID)))
                    && tab.id.map { !deleted.contains(key(type: .tab, id: $0)) } != false
                    &&
                    (tab.placement != .spacePinned || tab.pinnedFolderID
                        .map {
                            !deletedFolderIDs.contains($0) && !deleted.contains(key(type: .folder, id: $0))
                        } != false)
            },
            // Local split state follows the local writer; the store prunes
            // members that this filter removed.
            splitGroups: snapshot.splitGroups,
        )
    }

    static func snapshot(
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncMutation],
        local: BrowserTabSessionSnapshot?,
    ) -> BrowserTabSessionSnapshot {
        snapshot(baseline: baseline, pending: pending.map(BrowserSyncQueuedMutation.legacy), local: local)
    }

    @_disfavoredOverload static func snapshot(
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncQueuedMutation],
        local: BrowserTabSessionSnapshot?,
        folderSyncEnabled: Bool = false,
        reusing reuse: (rows: [BrowserSyncQueuedRowIdentity], memo: BrowserSyncOutboxReplayMemo)? = nil,
    ) -> BrowserTabSessionSnapshot {
        let values =
            if let reuse {
                effectiveChanges(baseline: baseline, pending: pending, rows: reuse.rows, memo: reuse.memo)
            } else {
                effectiveChanges(baseline: baseline, pending: pending)
            }
        if folderSyncEnabled {
            return BrowserSyncFolderProjection.snapshot(values: values, local: local)
        }
        let live = values.values
        let spaceChanges = live.filter { $0.entityType == .space && $0.spaceData != nil }.sorted {
            let left = $0.spaceData!.rank
            let right = $1.spaceData!.rank
            return left == right ? $0.entityID < $1.entityID : left < right
        }
        let spaceIDs = Set(spaceChanges.map(\.entityID))
        let spaceOrder = Dictionary(uniqueKeysWithValues: spaceChanges.enumerated().map { ($1.entityID, $0) })
        let localTabs = Dictionary(uniqueKeysWithValues: (local?.tabs ?? []).compactMap { tab in
            tab.id.map { ($0, tab) }
        })
        let activityDates = BrowserSyncActivityDates()
        let projectedTabs = live.filter {
            $0.entityType == .tab && $0.tabData.map { $0.placement == .app || spaceIDs.contains($0.spaceID) } == true
        }
        .sorted {
            // v3 ranks belong to one sidebar list, never to the flattened tab array.
            let leftData = $0.tabData!
            let rightData = $1.tabData!
            if (leftData.placement == .app) != (rightData.placement == .app) {
                return leftData.placement == .app
            }
            if leftData.placement != .app {
                let leftSpace = spaceOrder[leftData.spaceID]!
                let rightSpace = spaceOrder[rightData.spaceID]!
                if leftSpace != rightSpace {
                    return leftSpace < rightSpace
                }
                if leftData.placement != rightData.placement {
                    return leftData.placement == .spacePinned
                }
            }
            let left = $0.tabData!.rank
            let right = $1.tabData!.rank
            return left == right ? $0.entityID < $1.entityID : left < right
        }
        .map { change in
            let data = change.tabData!
            let previous = localTabs[change.entityID]
            return BrowserTabSessionSnapshotTab(
                id: change.entityID, urlString: data.urlString,
                pinnedURLString: data.placement == .spacePinned ? data.pinnedURLString : nil,
                userTitleOverride: data.userTitleOverride, placement: data.placement, spaceID: data.spaceID,
                pinnedFolderID: data.placement == .spacePinned && previous?.spaceID == data.spaceID
                    ? previous?.pinnedFolderID
                    : nil,
                lastActivityTimestamp: activityDates.projectedTimestamp(
                    data.lastActivityAt, local: previous?.lastActivityTimestamp,
                ),
                pinnedSiblingRank: data.placement == .spacePinned && previous?.spaceID == data.spaceID
                    ? previous?.pinnedSiblingRank
                    : nil,
                // Titles and icons are local; keep this device's.
                pageTitle: previous?.pageTitle,
                systemImageName: previous?.systemImageName,
            )
        }
        let localSpaces = Dictionary((local?.spaces ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousTabIDsBySpace = sidebarTabIDsBySpace(local?.tabs ?? [])
        let currentTabIDsBySpace = sidebarTabIDsBySpace(projectedTabs)
        let projectedSpaces = spaceChanges.map { change in
            let data = change.spaceData!
            let previousSpace = localSpaces[change.entityID]
            let previousTabs = previousTabIDsBySpace[change.entityID] ?? []
            let selectedID = previousSpace?.selectedTabIndex.flatMap {
                previousTabs.indices.contains($0) ? previousTabs[$0] : nil
            }
            let currentTabs = currentTabIDsBySpace[change.entityID] ?? []
            return BrowserSpaceSessionSnapshot(
                id: change.entityID, title: data.title, systemImageName: data.systemImageName,
                isPinnedSectionCollapsed: data.isPinnedSectionCollapsed,
                selectedTabIndex: selectedID.flatMap { id in currentTabs.firstIndex { $0 == id } },
                // Colors are local; keep this device's.
                colorName: previousSpace?.colorName,
                profileDirectory: previousSpace?.profileDirectory,
            )
        }
        return BrowserTabSessionSnapshot(
            spaces: projectedSpaces.isEmpty ? nil : projectedSpaces,
            pinnedTabFolders: local?.pinnedTabFolders?.filter { spaceIDs.contains($0.spaceID) },
            tabs: projectedTabs,
        )
    }

    static func effectiveChanges(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation],
    ) -> [String: BrowserSyncChange] {
        var state = replayStart(baseline: baseline, pending: pending)
        for mutation in pending {
            replay(mutation, into: &state)
        }
        return replayResult(state, baseline: baseline)
    }

    /// The same result as `effectiveChanges(baseline:pending:)`. When the start
    /// state equals, byte for byte, the state `memo` reached after the first
    /// row of a queue whose remaining rows are `rows`, the replay of those rows
    /// would repeat the remembered one, so its end state is reused. The start
    /// state already holds the tombstone rule for exactly those rows, so the
    /// comparison covers deletes that are still queued.
    static func effectiveChanges(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation],
        rows: [BrowserSyncQueuedRowIdentity], memo: BrowserSyncOutboxReplayMemo,
    ) -> [String: BrowserSyncChange] {
        precondition(rows.count == pending.count)
        let start = replayStart(baseline: baseline, pending: pending)
        if let head = memo.head, let end = memo.end, memo.rows.count == rows.count + 1,
           memo.rows.dropFirst().elementsEqual(rows), head.isIdentical(to: start)
        {
            memo.reuses += 1
            memo.remember(rows: rows, head: pending.first.map { first in
                var next = start
                replay(first, into: &next)
                return next
            }, end: end)
            return replayResult(end, baseline: baseline)
        }
        var state = start
        var head: BrowserSyncOutboxReplayState?
        for (index, mutation) in pending.enumerated() {
            replay(mutation, into: &state)
            if index == 0 {
                head = state
            }
        }
        memo.remember(rows: rows, head: head, end: state)
        return replayResult(state, baseline: baseline)
    }

    /// Local tombstones are recorded before debounce, including deletes later in
    /// this FIFO. Replay their preceding creates/move-outs first. Authoritative
    /// server tombstones remain effective from the start.
    static func replayStart(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation],
    ) -> BrowserSyncOutboxReplayState {
        let values = baseline.entities.mapValues(\.change)
        let pendingDeletes = Set(pending.flatMap { mutation -> [String] in
            switch mutation {
            case .legacy(let row): row.changes.filter { $0.op == .delete }.map(key)
            case .semantic(let row):
                row.operations.compactMap { operation in
                    switch operation {
                    case .deleteSpace(let id): key(type: .space, id: id)
                    case .deleteTab(let id): key(type: .tab, id: id)
                    default: nil
                    }
                }
            case .folders(let row):
                row.operations.compactMap { operation in
                    switch operation {
                    case .deleteSpace(let id): key(type: .space, id: id)
                    case .deleteTab(let id): key(type: .tab, id: id)
                    case .deleteFolder(let id): key(type: .folder, id: id)
                    default: nil
                    }
                }
            case .boosts,
                 .expiry,
                 .mobileTabs: []
            }
        })
        var deleted = baseline.deletedKeys.subtracting(pendingDeletes)
        deleted.formUnion(values.filter { $0.value.op == .delete }.keys)
        return BrowserSyncOutboxReplayState(values: values, deleted: deleted)
    }

    /// Applies one queued row. The result depends only on `state` and the row.
    static func replay(_ mutation: BrowserSyncQueuedMutation, into state: inout BrowserSyncOutboxReplayState) {
        switch mutation {
        case .legacy(let row):
            let activityDates = BrowserSyncActivityDates()
            for change in row.changes where change.op == .upsert && !state.deleted.contains(key(change)) {
                if let tab = change.tabData, tab.placement != .app,
                   state.deleted.contains(key(type: .space, id: tab.spaceID))
                {
                    // A stale full record cannot move a canonical survivor back
                    // into a deleted parent. New stale children are deleted.
                    if let current = state.values[key(change)]?.tabData,
                       current.spaceID != tab.spaceID || current.placement == .app
                    {
                        continue
                    }
                    state.deleted.insert(key(change))
                    continue
                }
                state.values[key(change)] = preservingActivity(
                    of: change, from: state.values[key(change)], dates: activityDates,
                )
            }
            // The v2 server applies upserts first, then deletions, without
            // semantic rank normalization. Its parent cascade is permanent.
            for change in row.changes where change.op == .delete {
                state.deleted.insert(key(change))
                if change.entityType == .space {
                    for child in state.values.values {
                        if let tab = child.tabData, tab.placement != .app, tab.spaceID == change.entityID {
                            state.deleted.insert(key(child))
                        }
                    }
                }
            }
        case .semantic(let row):
            BrowserSyncSemanticProjection.apply(row.operations, to: &state.values, deleted: &state.deleted)
        case .folders(let row):
            BrowserSyncFolderProjection.apply(row.operations, to: &state.values, deleted: &state.deleted)
        case .expiry:
            // Conditional requests leave live state untouched until the
            // server returns its accepted delete or canonical rejection.
            break
        case .boosts,
             .mobileTabs:
            // Boosts and mobile tabs project separately, outside the Spaces.
            break
        }
    }

    static func replayResult(
        _ state: BrowserSyncOutboxReplayState, baseline: BrowserSyncOutboxBaseline,
    ) -> [String: BrowserSyncChange] {
        let deleted = state.deleted.union(baseline.deletedKeys)
        return state.values.filter { $0.value.op == .upsert && !deleted.contains($0.key) }
    }

    static func replacingRank(of change: BrowserSyncChange, with rank: Double?) -> BrowserSyncChange {
        guard let rank else { return change }
        if let data = change.spaceData {
            return BrowserSyncChange(
                entityType: change.entityType, entityID: change.entityID, op: change.op,
                spaceData: BrowserSyncSpacePayload(
                    title: data.title, systemImageName: data.systemImageName, rank: rank,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed, selectedTabID: data.selectedTabID,
                ), tabData: nil,
            )
        }
        guard let data = change.tabData else { return change }
        return BrowserSyncChange(
            entityType: change.entityType, entityID: change.entityID, op: change.op, spaceData: nil,
            tabData: BrowserSyncTabPayload(
                spaceID: data.spaceID, placement: data.placement, rank: rank, urlString: data.urlString,
                pinnedURLString: data.pinnedURLString, title: data.title, userTitleOverride: data.userTitleOverride,
                faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt,
                pinnedFolderID: data.pinnedFolderID,
            ),
        )
    }

    static func canonicalChanges(_ snapshot: BrowserTabSessionSnapshot) -> [BrowserSyncChange] {
        var result = [BrowserSyncChange]()
        let dateFormatter = ISO8601DateFormatter()
        var spaces = snapshot.spaces ?? []
        // Ordinary legacy tabs need an implicit parent; global app favorites do not.
        if !spaces.contains(where: { $0.id == BrowserSessionDefaults.defaultSpaceID }),
           snapshot.tabs
            .contains(where: {
                $0
                    .placement != .app && ($0.spaceID ?? BrowserSessionDefaults.defaultSpaceID) ==
                    BrowserSessionDefaults
                    .defaultSpaceID
            })
        {
            spaces.append(BrowserSpaceSessionSnapshot(
                id: BrowserSessionDefaults.defaultSpaceID, title: BrowserStrings.defaultSpaceTitle(index: 1),
                systemImageName: BrowserSessionDefaults.defaultSpaceIconName,
            ))
        }
        for (index, space) in spaces.enumerated() {
            result.append(BrowserSyncChange(
                entityType: .space, entityID: space.id, op: .upsert,
                spaceData: BrowserSyncSpacePayload(
                    title: space.title,
                    systemImageName: space.systemImageName,
                    rank: Double(index),
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                    selectedTabID: nil,
                ), tabData: nil,
            ))
        }
        for (index, tab) in snapshot.tabs.enumerated() {
            guard let id = tab.id else { continue }
            result.append(BrowserSyncChange(
                entityType: .tab, entityID: id, op: .upsert, spaceData: nil,
                tabData: BrowserSyncTabPayload(
                    spaceID: tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID, placement: tab.placement,
                    rank: Double(index), urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    title: nil, userTitleOverride: tab.userTitleOverride, faviconURLString: nil,
                    lastActivityAt: tab.lastActivityTimestamp
                        .map { dateFormatter.string(from: Date(timeIntervalSince1970: $0)) },
                ),
            ))
        }
        return result
    }

    // MARK: Private

    private static func preservingActivity(
        of change: BrowserSyncChange, from previous: BrowserSyncChange?, dates: BrowserSyncActivityDates,
    ) -> BrowserSyncChange {
        guard let data = change.tabData else { return change }
        let activity = dates.latest(previous?.tabData?.lastActivityAt, data.lastActivityAt)
        guard activity != data.lastActivityAt else { return change }
        return BrowserSyncChange(
            entityType: change.entityType, entityID: change.entityID, op: change.op, spaceData: nil,
            tabData: BrowserSyncTabPayload(
                spaceID: data.spaceID, placement: data.placement, rank: data.rank, urlString: data.urlString,
                pinnedURLString: data.pinnedURLString, title: data.title, userTitleOverride: data.userTitleOverride,
                faviconURLString: data.faviconURLString, lastActivityAt: activity,
                pinnedFolderID: data.pinnedFolderID,
            ),
        )
    }

    private static func delta(before: [BrowserSyncChange], after: [BrowserSyncChange]) -> [BrowserSyncChange] {
        let beforeByKey = Dictionary(uniqueKeysWithValues: before.map { (key($0), $0) })
        let afterKeys = Set(after.map(key))
        let upserts = after.filter { beforeByKey[key($0)] != $0 }
        let deletes = before.filter { !afterKeys.contains(key($0)) }.map {
            BrowserSyncChange(
                entityType: $0.entityType,
                entityID: $0.entityID,
                op: .delete,
                spaceData: nil,
                tabData: nil,
            )
        }
        return upserts + deletes
    }

    private static func sidebarTabIDsBySpace(_ tabs: [BrowserTabSessionSnapshotTab]) -> [String: [String?]] {
        var result = [String: [String?]]()
        // Preserve nil-ID slots and within-section order when restoring selection.
        // Favorites are global and do not use a Space's selectedTabIndex.
        for placement in [BrowserTabPlacement.spacePinned, .temporary] {
            for tab in tabs where tab.placement == placement {
                result[tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID, default: []].append(tab.id)
            }
        }
        return result
    }
}

// MARK: - Byte identity

private func identical(_ left: String, _ right: String) -> Bool {
    var left = left
    var right = right
    return left.withUTF8 { leftBytes in
        right.withUTF8 { rightBytes in
            leftBytes.count == rightBytes.count
                && (leftBytes.isEmpty || memcmp(leftBytes.baseAddress!, rightBytes.baseAddress!, leftBytes.count) == 0)
        }
    }
}

private func identical(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (nil, nil): true
    case (let left?, let right?): identical(left, right)
    default: false
    }
}

private func identical(_ left: Double, _ right: Double) -> Bool { left.bitPattern == right.bitPattern }

private func identical(_ left: BrowserSyncChange, _ right: BrowserSyncChange) -> Bool {
    guard left.entityType == right.entityType, left.op == right.op, identical(left.entityID, right.entityID)
    else { return false }
    switch (left.spaceData, right.spaceData) {
    case (nil, nil): break
    case (let left?, let right?):
        guard identical(left.title, right.title), identical(left.systemImageName, right.systemImageName),
              identical(left.rank, right.rank), left.isPinnedSectionCollapsed == right.isPinnedSectionCollapsed,
              identical(left.selectedTabID, right.selectedTabID) else { return false }
    default: return false
    }
    switch (left.tabData, right.tabData) {
    case (nil, nil): break
    case (let left?, let right?):
        guard identical(left.spaceID, right.spaceID), left.placement == right.placement,
              identical(left.rank, right.rank), identical(left.urlString, right.urlString),
              identical(left.pinnedURLString, right.pinnedURLString), identical(left.title, right.title),
              identical(left.userTitleOverride, right.userTitleOverride),
              identical(left.faviconURLString, right.faviconURLString),
              identical(left.lastActivityAt, right.lastActivityAt),
              identical(left.pinnedFolderID, right.pinnedFolderID) else { return false }
    default: return false
    }
    switch (left.folderData, right.folderData) {
    case (nil, nil): return true
    case (let left?, let right?):
        return identical(left.spaceID, right.spaceID) && identical(left.parentFolderID, right.parentFolderID)
            && identical(left.title, right.title) && identical(left.systemImageName, right.systemImageName)
            && identical(left.rank, right.rank)
    default: return false
    }
}
