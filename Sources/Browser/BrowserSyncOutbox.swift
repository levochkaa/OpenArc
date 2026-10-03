import Foundation

// MARK: - BrowserSyncOutboxError

enum BrowserSyncOutboxError: Error, Equatable {
    case invalidLimit
    case invalidEvent
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
                        tabData: nil
                    )
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
                        selectedTabID: data.selectedTabID
                    ),
                    tabData: nil
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
                        faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt
                    )
                )
            default: throw BrowserSyncOutboxError.invalidEvent
            }
            entities[key] = Entity(serverSeq: event.serverSeq, change: change)
        }
    }
}

// MARK: - BrowserSyncOutboxProjection

enum BrowserSyncOutboxProjection {
    // MARK: Internal

    static func key(type: BrowserSyncChange.EntityType, id: String) -> String { "\(type.rawValue):\(id)" }
    static func key(_ change: BrowserSyncChange) -> String { key(type: change.entityType, id: change.entityID) }

    static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot
    ) -> [BrowserSyncChange] {
        delta(
            before: canonicalChanges(previous ?? BrowserTabSessionSnapshot(tabs: [])),
            after: canonicalChanges(snapshot)
        )
    }

    static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncMutation]
    ) -> [BrowserSyncChange] {
        changes(
            from: previous,
            to: snapshot,
            baseline: baseline,
            pending: pending.map(BrowserSyncQueuedMutation.legacy)
        )
    }

    @_disfavoredOverload static func changes(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncQueuedMutation]
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
            }
        )
    }

    static func removingDeletedEntities(
        from snapshot: BrowserTabSessionSnapshot, baseline: BrowserSyncOutboxBaseline
    ) -> BrowserTabSessionSnapshot {
        let deleted = baseline.deletedKeys
        return BrowserTabSessionSnapshot(
            spaces: snapshot.spaces?.filter { !deleted.contains(key(type: .space, id: $0.id)) },
            pinnedTabFolders: snapshot.pinnedTabFolders?
                .filter { !deleted.contains(key(type: .space, id: $0.spaceID)) },
            tabs: snapshot.tabs.filter { tab in
                (tab.placement == .app
                    || !deleted.contains(key(type: .space, id: tab.spaceID ?? BrowserChromeModel.defaultSpaceID)))
                    && tab.id.map { !deleted.contains(key(type: .tab, id: $0)) } != false
            }
        )
    }

    static func snapshot(
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncMutation],
        local: BrowserTabSessionSnapshot?
    ) -> BrowserTabSessionSnapshot {
        snapshot(baseline: baseline, pending: pending.map(BrowserSyncQueuedMutation.legacy), local: local)
    }

    @_disfavoredOverload static func snapshot(
        baseline: BrowserSyncOutboxBaseline,
        pending: [BrowserSyncQueuedMutation],
        local: BrowserTabSessionSnapshot?
    ) -> BrowserTabSessionSnapshot {
        let live = effectiveChanges(baseline: baseline, pending: pending).values
        let spaceChanges = live.filter { $0.entityType == .space && $0.spaceData != nil }.sorted {
            let left = $0.spaceData!.rank, right = $1.spaceData!.rank
            return left == right ? $0.entityID < $1.entityID : left < right
        }
        let spaceIDs = Set(spaceChanges.map(\.entityID))
        let spaceOrder = Dictionary(uniqueKeysWithValues: spaceChanges.enumerated().map { ($1.entityID, $0) })
        let localTabs = Dictionary(uniqueKeysWithValues: (local?.tabs ?? []).compactMap { tab in
            tab.id.map { ($0, tab) }
        })
        let projectedTabs = live.filter {
            $0.entityType == .tab && $0.tabData.map { $0.placement == .app || spaceIDs.contains($0.spaceID) } == true
        }
        .sorted {
            // v3 ranks belong to one sidebar list, never to the flattened tab array.
            let leftData = $0.tabData!, rightData = $1.tabData!
            if (leftData.placement == .app) != (rightData.placement == .app) {
                return leftData.placement == .app
            }
            if leftData.placement != .app {
                let leftSpace = spaceOrder[leftData.spaceID]!, rightSpace = spaceOrder[rightData.spaceID]!
                if leftSpace != rightSpace {
                    return leftSpace < rightSpace
                }
                if leftData.placement != rightData.placement {
                    return leftData.placement == .spacePinned
                }
            }
            let left = $0.tabData!.rank, right = $1.tabData!.rank
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
                lastActivityTimestamp: data.lastActivityAt
                    .flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }
                    ?? previous?.lastActivityTimestamp
            )
        }
        let projectedSpaces = spaceChanges.map { change in
            let data = change.spaceData!
            let previousSpace = local?.spaces?.first { $0.id == change.entityID }
            let previousTabs = sidebarTabs(local?.tabs ?? [], spaceID: change.entityID)
            let selectedID = previousSpace?.selectedTabIndex.flatMap {
                previousTabs.indices.contains($0) ? previousTabs[$0].id : nil
            }
            let currentTabs = sidebarTabs(projectedTabs, spaceID: change.entityID)
            return BrowserSpaceSessionSnapshot(
                id: change.entityID, title: data.title, systemImageName: data.systemImageName,
                isPinnedSectionCollapsed: data.isPinnedSectionCollapsed,
                selectedTabIndex: selectedID.flatMap { id in currentTabs.firstIndex { $0.id == id } }
            )
        }
        return BrowserTabSessionSnapshot(
            spaces: projectedSpaces.isEmpty ? nil : projectedSpaces,
            pinnedTabFolders: local?.pinnedTabFolders?.filter { spaceIDs.contains($0.spaceID) },
            tabs: projectedTabs
        )
    }

    static func effectiveChanges(
        baseline: BrowserSyncOutboxBaseline, pending: [BrowserSyncQueuedMutation]
    ) -> [String: BrowserSyncChange] {
        var values = baseline.entities.mapValues(\.change)
        // Local tombstones are recorded before debounce, including deletes later in
        // this FIFO. Replay their preceding creates/move-outs first. Authoritative
        // server tombstones remain effective from the start.
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
            }
        })
        var deleted = baseline.deletedKeys.subtracting(pendingDeletes)
        deleted.formUnion(values.filter { $0.value.op == .delete }.keys)
        for mutation in pending {
            switch mutation {
            case .legacy(let row):
                for change in row.changes where change.op == .upsert && !deleted.contains(key(change)) {
                    if let tab = change.tabData, tab.placement != .app,
                       deleted.contains(key(type: .space, id: tab.spaceID))
                    {
                        // A stale full record cannot move a canonical survivor back
                        // into a deleted parent. New stale children are deleted.
                        if let current = values[key(change)]?.tabData,
                           current.spaceID != tab.spaceID || current.placement == .app
                        {
                            continue
                        }
                        deleted.insert(key(change))
                        continue
                    }
                    values[key(change)] = change
                }
                // The v2 server applies upserts first, then deletions, without
                // semantic rank normalization. Its parent cascade is permanent.
                for change in row.changes where change.op == .delete {
                    deleted.insert(key(change))
                    if change.entityType == .space {
                        for child in values.values {
                            if let tab = child.tabData, tab.placement != .app, tab.spaceID == change.entityID {
                                deleted.insert(key(child))
                            }
                        }
                    }
                }
            case .semantic(let row):
                BrowserSyncSemanticProjection.apply(row.operations, to: &values, deleted: &deleted)
            }
        }
        deleted.formUnion(baseline.deletedKeys)
        return values.filter { $0.value.op == .upsert && !deleted.contains($0.key) }
    }

    static func replacingRank(of change: BrowserSyncChange, with rank: Double?) -> BrowserSyncChange {
        guard let rank else { return change }
        if let data = change.spaceData {
            return BrowserSyncChange(
                entityType: change.entityType, entityID: change.entityID, op: change.op,
                spaceData: BrowserSyncSpacePayload(
                    title: data.title, systemImageName: data.systemImageName, rank: rank,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed, selectedTabID: data.selectedTabID
                ), tabData: nil
            )
        }
        guard let data = change.tabData else { return change }
        return BrowserSyncChange(
            entityType: change.entityType, entityID: change.entityID, op: change.op, spaceData: nil,
            tabData: BrowserSyncTabPayload(
                spaceID: data.spaceID, placement: data.placement, rank: rank, urlString: data.urlString,
                pinnedURLString: data.pinnedURLString, title: data.title, userTitleOverride: data.userTitleOverride,
                faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt
            )
        )
    }

    static func canonicalChanges(_ snapshot: BrowserTabSessionSnapshot) -> [BrowserSyncChange] {
        var result = [BrowserSyncChange]()
        var spaces = snapshot.spaces ?? []
        // Ordinary legacy tabs need an implicit parent; global app favorites do not.
        if !spaces.contains(where: { $0.id == BrowserChromeModel.defaultSpaceID }),
           snapshot.tabs
               .contains(where: {
                   $0.placement != .app && ($0.spaceID ?? BrowserChromeModel.defaultSpaceID) == BrowserChromeModel
                       .defaultSpaceID
               })
        {
            spaces.append(BrowserSpaceSessionSnapshot(
                id: BrowserChromeModel.defaultSpaceID, title: BrowserStrings.defaultSpaceTitle(index: 1),
                systemImageName: BrowserChromeModel.defaultSpaceIconName
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
                    selectedTabID: nil
                ), tabData: nil
            ))
        }
        for (index, tab) in snapshot.tabs.enumerated() {
            guard let id = tab.id else { continue }
            result.append(BrowserSyncChange(
                entityType: .tab, entityID: id, op: .upsert, spaceData: nil,
                tabData: BrowserSyncTabPayload(
                    spaceID: tab.spaceID ?? BrowserChromeModel.defaultSpaceID, placement: tab.placement,
                    rank: Double(index), urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    title: nil, userTitleOverride: tab.userTitleOverride, faviconURLString: nil,
                    lastActivityAt: tab.lastActivityTimestamp
                        .map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
                )
            ))
        }
        return result
    }

    // MARK: Private

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
                tabData: nil
            )
        }
        return upserts + deletes
    }

    private static func sidebarTabs(
        _ tabs: [BrowserTabSessionSnapshotTab],
        spaceID: String
    ) -> [BrowserTabSessionSnapshotTab] {
        let inSpace = tabs.filter { ($0.spaceID ?? BrowserChromeModel.defaultSpaceID) == spaceID }
        return inSpace.filter { $0.placement == .spacePinned } + inSpace.filter { $0.placement == .temporary }
    }
}
