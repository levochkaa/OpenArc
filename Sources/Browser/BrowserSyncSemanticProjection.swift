import Foundation

/// Direct moves retain the identities the user moved. Snapshot-only callers infer
/// a minimal move set from relative order for compatibility.
enum BrowserSyncSemanticProjection {
    // MARK: Internal

    static func operations(
        from previous: BrowserTabSessionSnapshot?,
        to snapshot: BrowserTabSessionSnapshot,
        syncMove: BrowserSyncMoveIntent? = nil
    ) -> [BrowserSyncSemanticOperation] {
        let before = BrowserSyncOutboxProjection.canonicalChanges(previous ?? .init(tabs: []))
        let after = BrowserSyncOutboxProjection.canonicalChanges(snapshot)
        let previousByKey = Dictionary(uniqueKeysWithValues: before.map { (key($0), $0) })
        let nextByKey = Dictionary(uniqueKeysWithValues: after.map { (key($0), $0) })
        // The store rejects duplicate IDs. Deduplicate defensively for pure callers
        // too, so no generated move can violate the wire's unique-ID constraint.
        var seen = Set<String>()
        let explicitOrder = syncMove.map { move in
            previous == snapshot ? [] : move.tabIDs.filter { seen.insert($0).inserted }
        }
        let plans = orderPlans(before: before, after: after, explicitTabIDs: explicitOrder.map(Set.init))
        var result = [BrowserSyncSemanticOperation]()
        var homePatches = [BrowserSyncSemanticOperation]()

        // Parents precede child creates. New entities anchor to unchanged survivors,
        // not to an old neighbor that a later operation will move away.
        for plan in plans {
            var previousAnchor: String?
            let nextKept = followingAnchors(ids: plan.ids, anchors: plan.kept)
            for (index, id) in plan.ids.enumerated() {
                if plan.created.contains(id), let change = nextByKey[plan.container.key(id)] {
                    let beforeID = nextKept[index]
                    if let data = change.spaceData {
                        result.append(.createSpace(id: id, data: .init(
                            title: data.title, systemImageName: data.systemImageName,
                            isPinnedSectionCollapsed: data.isPinnedSectionCollapsed, selectedTabID: data.selectedTabID
                        ), beforeID: beforeID, afterID: previousAnchor))
                    } else if let data = change.tabData {
                        result.append(.createTab(id: id, data: .init(
                            spaceID: data.spaceID, placement: data.placement, urlString: data.urlString,
                            pinnedURLString: data.pinnedURLString, title: data.title,
                            userTitleOverride: data.userTitleOverride, faviconURLString: data.faviconURLString,
                            lastActivityAt: data.lastActivityAt
                        ), beforeID: beforeID, afterID: previousAnchor))
                    }
                }
                if plan.kept.contains(id) || plan.created.contains(id) {
                    previousAnchor = id
                }
            }
        }

        for change in after {
            guard let old = previousByKey[key(change)] else { continue }
            if let data = change.spaceData, let previous = old.spaceData {
                let fields = BrowserSyncSemanticSpacePatch(
                    title: data.title == previous.title ? nil : data.title,
                    systemImageName: data.systemImageName == previous.systemImageName ? nil : data.systemImageName,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed == previous.isPinnedSectionCollapsed
                        ? nil
                        : data.isPinnedSectionCollapsed
                )
                if fields != .init() {
                    result.append(.patchSpace(id: change.entityID, fields: fields))
                }
            } else if let data = change.tabData, let previous = old.tabData {
                // Page titles/favicon are not represented by the session snapshot.
                // Never synthesize clears for metadata the model does not own here.
                let fields = BrowserSyncSemanticTabPatch(
                    urlString: data.urlString == previous.urlString ? nil : data.urlString,
                    userTitleOverride: patch(from: previous.userTitleOverride, to: data.userTitleOverride),
                    lastActivityAt: patch(from: previous.lastActivityAt, to: data.lastActivityAt)
                )
                if fields != .init() {
                    result.append(.patchTab(id: change.entityID, fields: fields))
                }
                if data.placement == .spacePinned {
                    // A newly pinned tab takes its current canonical URL at move time.
                    // Do not overwrite a concurrent navigation with the stale local URL.
                    let home: BrowserSyncPatchValue<String> = previous.placement == .spacePinned
                        ? patch(from: previous.pinnedURLString, to: data.pinnedURLString)
                        : data.pinnedURLString.flatMap { $0 == data.urlString ? nil : .set($0) } ?? .unchanged
                    if home != .unchanged {
                        homePatches.append(.patchTab(id: change.entityID, fields: .init(pinnedURLString: home)))
                    }
                }
            }
        }

        for plan in plans {
            if let explicitOrder, plan.container != .spaces {
                result += explicitTabMoves(plan, orderedIDs: explicitOrder, nextByKey: nextByKey)
                continue
            }
            let anchors = plan.kept.union(plan.created)
            let nextAnchors = followingAnchors(ids: plan.ids, anchors: anchors)
            var index = 0
            while index < plan.ids.count {
                guard !anchors.contains(plan.ids[index]) else { index += 1
                    continue
                }
                let start = index
                while index < plan.ids.count, !anchors.contains(plan.ids[index]), index - start < 1000 {
                    index += 1
                }
                let ids = Array(plan.ids[start..<index])
                let beforeID = nextAnchors[index - 1]
                let afterID = start > 0 ? plan.ids[start - 1] : nil
                switch plan.container {
                case .spaces:
                    result.append(.moveSpaces(ids: ids, beforeID: beforeID, afterID: afterID))
                case .apps, .tabs:
                    guard let data = nextByKey[plan.container.key(ids[0])]?.tabData else { continue }
                    result.append(.moveTabs(
                        ids: ids,
                        destination: .init(spaceID: data.spaceID, placement: data.placement),
                        beforeID: beforeID,
                        afterID: afterID
                    ))
                }
            }
        }
        result += homePatches
        // Move-outs must reach the server before deleting their former parent.
        let removedSpaces = Set(before.filter {
            $0.entityType == .space && nextByKey[key($0)] == nil
        }
        .map(\.entityID))
        for change in before where nextByKey[key(change)] == nil && change.entityType == .tab {
            // Delete only current canonical children. Explicit stale child deletes
            // would destroy tabs concurrently moved away by another device.
            if let data = change.tabData, data.placement != .app, removedSpaces.contains(data.spaceID) {
                continue
            }
            result.append(.deleteTab(id: change.entityID))
        }
        for change in before where nextByKey[key(change)] == nil && change.entityType == .space {
            result.append(.deleteSpace(id: change.entityID))
        }
        return result
    }

    static func apply(
        _ operations: [BrowserSyncSemanticOperation],
        to values: inout [String: BrowserSyncChange],
        deleted: inout Set<String>
    ) {
        for operation in operations {
            switch operation {
            case .createSpace(let id, let data, let beforeID, let afterID):
                let entityKey = Container.spaces.key(id)
                guard !deleted.contains(entityKey),
                      live(entityKey, values: values, deleted: deleted) == nil else { continue }
                let change = BrowserSyncChange(entityType: .space, entityID: id, op: .upsert, spaceData: .init(
                    title: data.title, systemImageName: data.systemImageName, rank: 0,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed, selectedTabID: data.selectedTabID
                ), tabData: nil)
                insert([change], into: .spaces, beforeID: beforeID, afterID: afterID, values: &values, deleted: deleted)
            case .createTab(let id, let data, let beforeID, let afterID):
                let entityKey = BrowserSyncOutboxProjection.key(type: .tab, id: id)
                let destination = Container.tab(spaceID: data.spaceID, placement: data.placement)
                guard !deleted.contains(entityKey), live(entityKey, values: values, deleted: deleted) == nil,
                      valid(destination, values: values, deleted: deleted) else { continue }
                let change = BrowserSyncChange(
                    entityType: .tab,
                    entityID: id,
                    op: .upsert,
                    spaceData: nil,
                    tabData: .init(
                        spaceID: data.spaceID, placement: data.placement, rank: 0, urlString: data.urlString,
                        pinnedURLString: data.placement == .spacePinned ? data.pinnedURLString ?? data.urlString : nil,
                        title: data.title, userTitleOverride: data.userTitleOverride,
                        faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt
                    )
                )
                insert(
                    [change],
                    into: destination,
                    beforeID: beforeID,
                    afterID: afterID,
                    values: &values,
                    deleted: deleted
                )
            case .patchSpace(let id, let fields):
                let entityKey = Container.spaces.key(id)
                guard let old = live(entityKey, values: values, deleted: deleted),
                      let data = old.spaceData else { continue }
                values[entityKey] = BrowserSyncChange(entityType: .space, entityID: id, op: .upsert, spaceData: .init(
                    title: fields.title ?? data.title, systemImageName: fields.systemImageName ?? data.systemImageName,
                    rank: data.rank,
                    isPinnedSectionCollapsed: fields.isPinnedSectionCollapsed ?? data.isPinnedSectionCollapsed,
                    selectedTabID: applying(fields.selectedTabID, to: data.selectedTabID)
                ), tabData: nil)
            case .patchTab(let id, let fields):
                let entityKey = BrowserSyncOutboxProjection.key(type: .tab, id: id)
                guard let old = live(entityKey, values: values, deleted: deleted),
                      let data = old.tabData else { continue }
                values[entityKey] = BrowserSyncChange(
                    entityType: .tab,
                    entityID: id,
                    op: .upsert,
                    spaceData: nil,
                    tabData: .init(
                        spaceID: data.spaceID, placement: data.placement, rank: data.rank,
                        urlString: fields.urlString ?? data.urlString,
                        pinnedURLString: data.placement == .spacePinned
                            ? applying(fields.pinnedURLString, to: data.pinnedURLString)
                            : nil,
                        title: applying(fields.title, to: data.title),
                        userTitleOverride: applying(fields.userTitleOverride, to: data.userTitleOverride),
                        faviconURLString: applying(fields.faviconURLString, to: data.faviconURLString),
                        lastActivityAt: applying(fields.lastActivityAt, to: data.lastActivityAt)
                    )
                )
            case .moveSpaces(let ids, let beforeID, let afterID):
                move(
                    ids,
                    destination: .spaces,
                    tabDestination: nil,
                    beforeID: beforeID,
                    afterID: afterID,
                    values: &values,
                    deleted: deleted
                )
            case .moveTabs(let ids, let destination, let beforeID, let afterID):
                move(
                    ids,
                    destination: .tab(spaceID: destination.spaceID, placement: destination.placement),
                    tabDestination: destination,
                    beforeID: beforeID,
                    afterID: afterID,
                    values: &values,
                    deleted: deleted
                )
            case .deleteSpace(let id):
                remove(type: .space, id: id, values: &values, deleted: &deleted)
            case .deleteTab(let id):
                remove(type: .tab, id: id, values: &values, deleted: &deleted)
            }
        }
    }

    // MARK: Private

    // MARK: - Snapshot ordering

    private enum Container: Hashable {
        case spaces
        case apps
        case tabs(spaceID: String, pinned: Bool)

        // MARK: Internal

        static func tab(spaceID: String, placement: BrowserTabPlacement) -> Container {
            placement == .app ? .apps : .tabs(spaceID: spaceID, pinned: placement == .spacePinned)
        }

        func key(_ id: String) -> String {
            BrowserSyncOutboxProjection.key(type: self == .spaces ? .space : .tab, id: id)
        }
    }

    private struct OrderPlan {
        let container: Container
        let ids: [String]
        let kept: Set<String>
        let created: Set<String>
    }

    private static func container(_ change: BrowserSyncChange) -> Container {
        guard let data = change.tabData else { return .spaces }
        return .tab(spaceID: data.spaceID, placement: data.placement)
    }

    private static func orderPlans(
        before: [BrowserSyncChange], after: [BrowserSyncChange], explicitTabIDs: Set<String>? = nil
    ) -> [OrderPlan] {
        let oldKeys = Set(before.map(key))
        let oldGroups = Dictionary(grouping: before, by: container)
        let newGroups = Dictionary(grouping: after, by: container)
        var seen = Set<Container>()
        return after.compactMap { change in
            let list = container(change)
            guard seen.insert(list).inserted else { return nil }
            let ids = newGroups[list, default: []].map(\.entityID)
            let oldIndices = Dictionary(uniqueKeysWithValues: oldGroups[list, default: []].enumerated().map { (
                $1.entityID,
                $0
            ) })
            let candidates = ids.compactMap { id in oldIndices[id].map { (id, $0) } }
            let kept: Set<String> =
                if let explicitTabIDs, list != .spaces {
                    Set(ids.filter { !explicitTabIDs.contains($0) && oldKeys.contains(list.key($0)) })
                } else {
                    longestIncreasingSubsequence(candidates)
                }
            return OrderPlan(
                container: list,
                ids: ids,
                kept: kept,
                created: Set(ids.filter { !oldKeys.contains(list.key($0)) })
            )
        }
    }

    private static func explicitTabMoves(
        _ plan: OrderPlan, orderedIDs: [String], nextByKey: [String: BrowserSyncChange]
    ) -> [BrowserSyncSemanticOperation] {
        let anchors = plan.kept.union(plan.created)
        let nextAnchors = followingAnchors(ids: plan.ids, anchors: anchors)
        let intentPositions = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        var operations = [BrowserSyncSemanticOperation]()
        var index = 0
        while index < plan.ids.count {
            guard !anchors.contains(plan.ids[index]) else { index += 1
                continue
            }
            let start = index
            while index < plan.ids.count, !anchors.contains(plan.ids[index]) {
                index += 1
            }
            // A new hinted identity is a create/anchor, not a redundant move.
            // Missing hinted IDs never occur in the final normalized plan.
            let group = plan.ids[start..<index].sorted {
                intentPositions[$0, default: Int.max] < intentPositions[$1, default: Int.max]
            }
            let beforeID = nextAnchors[index - 1]
            var afterID = start > 0 ? plan.ids[start - 1] : nil
            var offset = 0
            while offset < group.count {
                guard let first = nextByKey[plan.container.key(group[offset])]?.tabData else { break }
                let destination = BrowserSyncSemanticTabDestination(spaceID: first.spaceID, placement: first.placement)
                let chunkStart = offset
                // Global Favorites share rank order but may retain different
                // historical Space IDs; avoid rewriting those IDs during reorder.
                while offset < group.count, offset - chunkStart < 1000,
                      let data = nextByKey[plan.container.key(group[offset])]?.tabData,
                      data.spaceID == destination.spaceID, data.placement == destination.placement
                {
                    offset += 1
                }
                let chunk = Array(group[chunkStart..<offset])
                operations.append(.moveTabs(ids: chunk, destination: destination, beforeID: beforeID, afterID: afterID))
                afterID = chunk.last
            }
        }
        return operations
    }

    /// Unique identities reduce LCS to O(n log n) LIS with linear storage.
    private static func longestIncreasingSubsequence(_ candidates: [(String, Int)]) -> Set<String> {
        var tails = [Int]()
        var predecessors = Array(repeating: -1, count: candidates.count)
        for index in candidates.indices {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if candidates[tails[middle]].1 < candidates[index].1 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 {
                predecessors[index] = tails[low - 1]
            }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }
        var result = Set<String>(), index = tails.last ?? -1
        while index >= 0 {
            result.insert(candidates[index].0)
            index = predecessors[index]
        }
        return result
    }

    private static func followingAnchors(ids: [String], anchors: Set<String>) -> [String?] {
        var result = [String?](repeating: nil, count: ids.count)
        var following: String?
        for index in ids.indices.reversed() {
            result[index] = following
            if anchors.contains(ids[index]) {
                following = ids[index]
            }
        }
        return result
    }

    private static func patch(from previous: String?, to next: String?) -> BrowserSyncPatchValue<String> {
        previous == next ? .unchanged : next.map { .set($0) } ?? .clear
    }

    // MARK: - Canonical overlay

    private static func key(_ change: BrowserSyncChange) -> String { BrowserSyncOutboxProjection.key(change) }

    private static func live(
        _ key: String, values: [String: BrowserSyncChange], deleted: Set<String>
    ) -> BrowserSyncChange? {
        guard !deleted.contains(key), let value = values[key], value.op == .upsert else { return nil }
        return value
    }

    private static func valid(
        _ destination: Container, values: [String: BrowserSyncChange], deleted: Set<String>
    ) -> Bool {
        guard case .tabs(let spaceID, _) = destination else { return true }
        return live(Container.spaces.key(spaceID), values: values, deleted: deleted)?.spaceData != nil
    }

    private static func list(
        _ container: Container, values: [String: BrowserSyncChange], deleted: Set<String>
    ) -> [BrowserSyncChange] {
        values.values
            .filter { change in
                change.op == .upsert && !deleted.contains(key(change)) && self.container(change) == container
            }
            .sorted { left, right in
                let leftRank = left.spaceData?.rank ?? left.tabData?.rank ?? 0
                let rightRank = right.spaceData?.rank ?? right.tabData?.rank ?? 0
                return leftRank == rightRank ? left.entityID < right.entityID : leftRank < rightRank
            }
    }

    private static func publish(_ ordered: [BrowserSyncChange], values: inout [String: BrowserSyncChange]) {
        for (rank, change) in ordered.enumerated() {
            values[key(change)] = BrowserSyncOutboxProjection.replacingRank(of: change, with: Double(rank))
        }
    }

    private static func insert(
        _ group: [BrowserSyncChange], into destination: Container, beforeID: String?, afterID: String?,
        values: inout [String: BrowserSyncChange], deleted: Set<String>
    ) {
        let movedKeys = Set(group.map(key))
        var siblings = list(destination, values: values, deleted: deleted).filter { !movedKeys.contains(key($0)) }
        let before = beforeID.flatMap { id in siblings.firstIndex { $0.entityID == id } }
        let after = afterID.flatMap { id in siblings.firstIndex { $0.entityID == id }.map { $0 + 1 } }
        siblings.insert(contentsOf: group, at: before ?? after ?? siblings.count)
        publish(siblings, values: &values)
    }

    private static func move(
        _ ids: [String], destination: Container, tabDestination: BrowserSyncSemanticTabDestination?,
        beforeID: String?, afterID: String?, values: inout [String: BrowserSyncChange], deleted: Set<String>
    ) {
        guard valid(destination, values: values, deleted: deleted) else { return }
        var seen = Set<String>()
        let survivors = ids.compactMap { id -> BrowserSyncChange? in
            guard seen.insert(id).inserted else { return nil }
            return live(destination.key(id), values: values, deleted: deleted)
        }
        guard !survivors.isEmpty else { return }
        let movedKeys = Set(survivors.map(key))
        let sourceContainers = Set(survivors.map(container))
        for source in sourceContainers where source != destination {
            publish(
                list(source, values: values, deleted: deleted).filter { !movedKeys.contains(key($0)) },
                values: &values
            )
        }
        let moved = survivors.map { change -> BrowserSyncChange in
            guard let target = tabDestination, let data = change.tabData else { return change }
            let home = target.placement == .spacePinned
                ? (data.placement == .spacePinned ? data.pinnedURLString : data.urlString)
                : nil
            return BrowserSyncChange(
                entityType: .tab,
                entityID: change.entityID,
                op: .upsert,
                spaceData: nil,
                tabData: .init(
                    spaceID: target.spaceID, placement: target.placement, rank: data.rank,
                    urlString: data.urlString, pinnedURLString: home, title: data.title,
                    userTitleOverride: data.userTitleOverride, faviconURLString: data.faviconURLString,
                    lastActivityAt: data.lastActivityAt
                )
            )
        }
        insert(moved, into: destination, beforeID: beforeID, afterID: afterID, values: &values, deleted: deleted)
    }

    private static func remove(
        type: BrowserSyncChange.EntityType, id: String,
        values: inout [String: BrowserSyncChange], deleted: inout Set<String>
    ) {
        let entityKey = BrowserSyncOutboxProjection.key(type: type, id: id)
        let old = values[entityKey]
        deleted.insert(entityKey)
        values[entityKey] = BrowserSyncChange(entityType: type, entityID: id, op: .delete, spaceData: nil, tabData: nil)
        if type == .space {
            // Membership is inspected now, after earlier queued move-outs. Favorites
            // are global and never participate in a Space's cascade.
            for change in Array(values.values) where change.op == .upsert {
                guard let data = change.tabData, data.spaceID == id, data.placement != .app else { continue }
                deleted.insert(key(change))
                values[key(change)] = BrowserSyncChange(
                    entityType: .tab,
                    entityID: change.entityID,
                    op: .delete,
                    spaceData: nil,
                    tabData: nil
                )
            }
        }
        if let old, old.op == .upsert {
            publish(list(container(old), values: values, deleted: deleted), values: &values)
        }
    }

    private static func applying<Value>(_ patch: BrowserSyncPatchValue<Value>, to value: Value?) -> Value? {
        switch patch {
        case .unchanged: value
        case .set(let update): update
        case .clear: nil
        }
    }
}
