import Foundation

/// V4 projection uses typed sibling lists and current canonical subtrees. A
/// supplied move intent identifies the acted-on roots; snapshot-only callers
/// retain a deterministic minimal-order fallback.
enum BrowserSyncFolderProjection {
    // MARK: Internal

    /// Uses the same validation as reduction, including valid semantic no-ops.
    static func canMove(
        items: [BrowserSyncEntityReference], destination: BrowserSyncFolderDestination,
        values: [String: BrowserSyncChange], deleted: Set<String> = []
    ) -> Bool {
        moveContext(items, destination: destination, values: values, deleted: deleted) != nil
    }

    static func canonicalChanges(_ snapshot: BrowserTabSessionSnapshot) -> [BrowserSyncChange] {
        let base = BrowserSyncOutboxProjection.canonicalChanges(snapshot)
        let localTabs = Dictionary(
            snapshot.tabs.compactMap { tab in tab.id.map { ($0, tab) } },
            uniquingKeysWith: { first, _ in first }
        )
        let folders = Dictionary(
            (snapshot.pinnedTabFolders ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var values = Dictionary(base.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for folder in snapshot.pinnedTabFolders ?? [] {
            values[key(.init(entityType: .folder, entityID: folder.id))] = Change(
                entityType: .folder, entityID: folder.id, op: .upsert, spaceData: nil, tabData: nil,
                folderData: .init(
                    spaceID: folder.spaceID,
                    parentFolderID: folder.parentFolderID,
                    title: folder.title,
                    systemImageName: folder.systemImageName,
                    rank: folder.pinnedSiblingRank ?? 0
                )
            )
        }
        for change in base {
            guard let data = change.tabData, let tab = localTabs[change.entityID] else { continue }
            values[key(change)] = replacing(change, tab: .init(
                spaceID: data.spaceID, placement: data.placement, rank: data.rank, urlString: data.urlString,
                pinnedURLString: data.pinnedURLString, title: data.title, userTitleOverride: data.userTitleOverride,
                faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt,
                pinnedFolderID: data.placement == .spacePinned ? tab.pinnedFolderID : nil
            ))
        }
        // Legacy snapshots encode folder position by their first descendant tab.
        // Empty folders have no such position and append in saved folder order.
        var inferred = [Container: [Ref]](), seen = Set<Ref>()
        func append(_ reference: Ref) {
            guard seen.insert(reference).inserted, let change = values[key(reference)] else { return }
            inferred[container(change), default: []].append(reference)
        }
        func appendAncestors(_ id: String?) {
            var path = [String](), visited = Set<String>(), current = id
            while let folderID = current, visited.insert(folderID).inserted, let folder = folders[folderID] {
                path.append(folderID)
                current = folder.parentFolderID
            }
            for folderID in path.reversed() {
                append(.init(entityType: .folder, entityID: folderID))
            }
        }
        for tab in snapshot.tabs where tab.placement == .spacePinned {
            appendAncestors(tab.pinnedFolderID)
            if let id = tab.id {
                append(.init(entityType: .tab, entityID: id))
            }
        }
        for folder in snapshot.pinnedTabFolders ?? [] {
            appendAncestors(folder.id)
        }
        for references in inferred.values {
            for (index, reference) in references.enumerated() {
                guard let change = values[key(reference)] else { continue }
                let explicit = reference.entityType == .folder
                    ? folders[reference.entityID]?.pinnedSiblingRank
                    : localTabs[reference.entityID]?.pinnedSiblingRank
                values[key(reference)] = ranked(change, explicit ?? Double(index))
            }
        }
        return orderedValues(values)
    }

    static func operations(
        from previous: BrowserTabSessionSnapshot?, to snapshot: BrowserTabSessionSnapshot,
        moveIntent: BrowserSyncMoveIntent? = nil
    ) -> [BrowserSyncFolderOperation] {
        let before = canonicalChanges(previous ?? .init(tabs: [])), after = canonicalChanges(snapshot)
        let old = Dictionary(before.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let next = Dictionary(after.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let oldGroups = Dictionary(grouping: before, by: container), groups = Dictionary(grouping: after, by: container)
        let hints = moveIntent.map { previous == snapshot ? Set<Ref>() : Set($0.items) }
        var plans = [Plan](), visited = Set<Container>()
        for change in after {
            let list = container(change)
            guard visited.insert(list).inserted else { continue }
            let items = groups[list, default: []].map(ref)
            let previousPositions = Dictionary(
                oldGroups[list, default: []].enumerated().map { (ref($1), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let candidates = items.compactMap { item in previousPositions[item].map { (item, $0) } }
            let kept = hints.map { hints in Set(items.filter { !hints.contains($0) && old[key($0)] != nil }) }
                ?? increasing(candidates)
            plans.append(.init(
                list: list,
                items: items,
                kept: kept,
                created: Set(items.filter { old[key($0)] == nil })
            ))
        }
        let folderMoves = Set(plans.flatMap { plan in plan.items.filter {
            $0.entityType == .folder && !plan.kept.contains($0) && !plan.created.contains($0)
        }}
        .map(\.entityID))
        // A cross-Space folder action changes every descendant's saved Space ID,
        // but the server must move its current subtree, including unseen children.
        let carried = Set(after.compactMap { change -> Ref? in
            guard let previous = old[key(change)] else { return nil }
            let parent = change.folderData?.parentFolderID ?? change.tabData?.pinnedFolderID
            let previousParent = previous.folderData?.parentFolderID ?? previous.tabData?.pinnedFolderID
            guard parent == previousParent, let parent else { return nil }
            return ancestors(parent, values: next).contains(where: folderMoves.contains) ? ref(change) : nil
        })
        for index in plans.indices {
            plans[index].kept.formUnion(carried)
        }
        var operations = [Operation](), homePatches = [Operation]()
        // Parent lists appear before child lists in the canonical traversal.
        for plan in plans {
            let following = followingAnchors(plan.items, kept: plan.kept)
            var preceding: Ref?
            for (index, item) in plan.items.enumerated() {
                if plan.created.contains(item), let change = next[key(item)] {
                    operations.append(create(change, before: following[index], after: preceding))
                }
                if plan.kept.contains(item) || plan.created.contains(item) {
                    preceding = item
                }
            }
        }
        for change in after {
            guard let previous = old[key(change)] else { continue }
            if let data = change.spaceData, let was = previous.spaceData {
                let fields = BrowserSyncSemanticSpacePatch(
                    title: data.title == was.title ? nil : data.title,
                    systemImageName: data.systemImageName == was.systemImageName ? nil : data.systemImageName,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed == was.isPinnedSectionCollapsed
                        ? nil
                        : data.isPinnedSectionCollapsed
                )
                if fields != .init() {
                    operations.append(.patchSpace(id: change.entityID, fields: fields))
                }
            } else if let data = change.folderData, let was = previous.folderData {
                let fields = BrowserSyncFolderPatch(
                    title: data.title == was.title ? nil : data.title,
                    systemImageName: patch(was.systemImageName, data.systemImageName)
                )
                if fields != .init() {
                    operations.append(.patchFolder(id: change.entityID, fields: fields))
                }
            } else if let data = change.tabData, let was = previous.tabData {
                let fields = BrowserSyncSemanticTabPatch(
                    urlString: data.urlString == was.urlString ? nil : data.urlString,
                    userTitleOverride: patch(was.userTitleOverride, data.userTitleOverride),
                    lastActivityAt: patch(was.lastActivityAt, data.lastActivityAt)
                )
                if fields != .init() {
                    operations.append(.patchTab(id: change.entityID, fields: fields))
                }
                if data.placement == .spacePinned {
                    let home = was.placement == .spacePinned
                        ? patch(was.pinnedURLString, data.pinnedURLString)
                        : data.pinnedURLString.flatMap { $0 == data.urlString ? nil : BrowserSyncPatchValue.set($0) }
                            ?? .unchanged
                    if home != .unchanged {
                        homePatches.append(.patchTab(
                            id: change.entityID,
                            fields: .init(pinnedURLString: home)
                        ))
                    }
                }
            }
        }
        for plan in plans {
            let anchors = plan.kept.union(plan.created), following = followingAnchors(plan.items, kept: anchors)
            var index = 0
            while index < plan.items.count {
                guard !anchors.contains(plan.items[index]) else { index += 1
                    continue
                }
                let start = index
                guard let first = next[key(plan.items[index])] else { index += 1
                    continue
                }
                let destination = destination(first)
                while index < plan.items.count, !anchors.contains(plan.items[index]), index - start < 1000,
                      let item = next[key(plan.items[index])], self.destination(item) == destination
                {
                    index += 1
                }
                operations.append(.move(
                    items: Array(plan.items[start..<index]),
                    destination: destination,
                    before: following[index - 1],
                    after: start > 0 ? plan.items[start - 1] : nil
                ))
            }
        }
        operations += homePatches
        let removed = Set(before.filter { next[key($0)] == nil }.map(ref))
        for change in before where removed.contains(ref(change)) {
            if let data = change.folderData {
                guard !removed.contains(.init(entityType: .space, entityID: data.spaceID)),
                      !ancestors(data.parentFolderID, values: old).contains(where: {
                          removed.contains(.init(entityType: .folder, entityID: $0))
                      }) else { continue }
                operations.append(.deleteFolder(id: change.entityID))
            } else if let data = change.tabData {
                if data.placement != .app {
                    guard !removed.contains(.init(entityType: .space, entityID: data.spaceID)),
                          !ancestors(data.pinnedFolderID, values: old).contains(where: {
                              removed.contains(.init(entityType: .folder, entityID: $0))
                          }) else { continue }
                }
                operations.append(.deleteTab(id: change.entityID))
            }
        }
        for change in before where change.entityType == .space && removed.contains(ref(change)) {
            operations.append(.deleteSpace(id: change.entityID))
        }
        return operations
    }

    static func apply(
        _ operations: [BrowserSyncFolderOperation], to values: inout [String: BrowserSyncChange],
        deleted: inout Set<String>
    ) {
        let activityDates = BrowserSyncActivityDates()
        for operation in operations {
            switch operation {
            case .createSpace(let id, let data, let before, let after):
                let change = Change(entityType: .space, entityID: id, op: .upsert, spaceData: .init(
                    title: data.title, systemImageName: data.systemImageName, rank: 0,
                    isPinnedSectionCollapsed: data.isPinnedSectionCollapsed, selectedTabID: data.selectedTabID
                ), tabData: nil)
                create(change, before: before, after: after, values: &values, deleted: deleted)
            case .createFolder(let id, let data, let before, let after):
                let change = Change(
                    entityType: .folder,
                    entityID: id,
                    op: .upsert,
                    spaceData: nil,
                    tabData: nil,
                    folderData: .init(
                        spaceID: data.spaceID,
                        parentFolderID: data.parentFolderID,
                        title: data.title,
                        systemImageName: data.systemImageName,
                        rank: 0
                    )
                )
                create(change, before: before, after: after, values: &values, deleted: deleted)
            case .createTab(let id, let creation, let before, let after):
                let data = creation.base
                let change = Change(entityType: .tab, entityID: id, op: .upsert, spaceData: nil, tabData: .init(
                    spaceID: data.spaceID, placement: data.placement, rank: 0, urlString: data.urlString,
                    pinnedURLString: data.placement == .spacePinned ? data.pinnedURLString ?? data.urlString : nil,
                    title: data.title, userTitleOverride: data.userTitleOverride,
                    faviconURLString: data.faviconURLString, lastActivityAt: data.lastActivityAt,
                    pinnedFolderID: creation.pinnedFolderID
                ))
                create(change, before: before, after: after, values: &values, deleted: deleted)
            case .patchSpace(let id, let fields):
                guard let old = live(.init(entityType: .space, entityID: id), values, deleted),
                      let data = old.spaceData else { continue }
                values[key(old)] = Change(entityType: .space, entityID: id, op: .upsert, spaceData: .init(
                    title: fields.title ?? data.title, systemImageName: fields.systemImageName ?? data.systemImageName,
                    rank: data.rank,
                    isPinnedSectionCollapsed: fields.isPinnedSectionCollapsed ?? data.isPinnedSectionCollapsed,
                    selectedTabID: applying(fields.selectedTabID, data.selectedTabID)
                ), tabData: nil)
            case .patchFolder(let id, let fields):
                guard let old = live(.init(entityType: .folder, entityID: id), values, deleted),
                      let data = old.folderData else { continue }
                values[key(old)] = replacing(
                    old,
                    folder: .init(
                        spaceID: data.spaceID,
                        parentFolderID: data.parentFolderID,
                        title: fields.title ?? data.title,
                        systemImageName: applying(
                            fields.systemImageName,
                            data.systemImageName
                        ),
                        rank: data.rank
                    )
                )
            case .patchTab(let id, let fields):
                guard let old = live(.init(entityType: .tab, entityID: id), values, deleted),
                      let data = old.tabData else { continue }
                values[key(old)] = replacing(old, tab: .init(
                    spaceID: data.spaceID, placement: data.placement, rank: data.rank,
                    urlString: fields.urlString ?? data.urlString,
                    pinnedURLString: data.placement == .spacePinned
                        ? applying(fields.pinnedURLString, data.pinnedURLString)
                        : nil,
                    title: applying(fields.title, data.title), userTitleOverride: applying(
                        fields.userTitleOverride,
                        data.userTitleOverride
                    ),
                    faviconURLString: applying(fields.faviconURLString, data.faviconURLString),
                    lastActivityAt: activityDates.latest(
                        data.lastActivityAt, applying(fields.lastActivityAt, data.lastActivityAt)
                    ),
                    pinnedFolderID: data.pinnedFolderID
                ))
            case .move(let items, let destination, let before, let after):
                move(items, to: destination, before: before, after: after, values: &values, deleted: deleted)
            case .deleteSpace(let id): remove(
                    .init(entityType: .space, entityID: id),
                    values: &values,
                    deleted: &deleted
                )
            case .deleteTab(let id): remove(.init(entityType: .tab, entityID: id), values: &values, deleted: &deleted)
            case .deleteFolder(let id): remove(
                    .init(entityType: .folder, entityID: id),
                    values: &values,
                    deleted: &deleted
                )
            }
        }
    }

    static func snapshot(
        values: [String: BrowserSyncChange], local: BrowserTabSessionSnapshot?
    ) -> BrowserTabSessionSnapshot {
        let ordered = orderedValues(values)
        let oldTabs = Dictionary(
            (local?.tabs ?? []).compactMap { tab in tab.id.map { ($0, tab) } },
            uniquingKeysWith: { first, _ in first }
        )
        let oldFolders = Dictionary(
            (local?.pinnedTabFolders ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldSpaces = Dictionary((local?.spaces ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activityDates = BrowserSyncActivityDates()
        let tabs = ordered.compactMap { change -> BrowserTabSessionSnapshotTab? in
            guard let data = change.tabData else { return nil }
            return .init(
                id: change.entityID,
                urlString: data.urlString,
                pinnedURLString: data.pinnedURLString,
                userTitleOverride: data.userTitleOverride,
                placement: data.placement,
                spaceID: data.spaceID,
                pinnedFolderID: data.pinnedFolderID,
                lastActivityTimestamp: activityDates.projectedTimestamp(
                    data.lastActivityAt, local: oldTabs[change.entityID]?.lastActivityTimestamp
                ),
                pinnedSiblingRank: data.placement == .spacePinned ? data.rank : nil,
                // Titles are local; keep this device's last one.
                pageTitle: oldTabs[change.entityID]?.pageTitle
            )
        }
        let folders = ordered.compactMap { change -> BrowserPinnedTabFolderSessionSnapshot? in
            guard let data = change.folderData else { return nil }
            return .init(
                id: change.entityID,
                spaceID: data.spaceID,
                parentFolderID: data.parentFolderID,
                title: data.title,
                systemImageName: data.systemImageName,
                isExpanded: oldFolders[change.entityID]?.isExpanded ?? true,
                pinnedSiblingRank: data.rank
            )
        }
        let oldIDs = sidebarIDs(local?.tabs ?? []), newIDs = sidebarIDs(tabs)
        let spaces = ordered.compactMap { change -> BrowserSpaceSessionSnapshot? in
            guard let data = change.spaceData else { return nil }
            let previousIDs = oldIDs[change.entityID, default: []]
            let selected = oldSpaces[change.entityID]?.selectedTabIndex.flatMap { index in
                previousIDs.indices.contains(index) ? previousIDs[index] : nil
            }
            return .init(
                id: change.entityID,
                title: data.title,
                systemImageName: data.systemImageName,
                isPinnedSectionCollapsed: data.isPinnedSectionCollapsed,
                selectedTabIndex: selected
                    .flatMap { id in newIDs[change.entityID, default: []].firstIndex { $0 == id } }
            )
        }
        return .init(
            spaces: spaces.isEmpty ? nil : spaces,
            pinnedTabFolders: folders.isEmpty ? nil : folders,
            tabs: tabs
        )
    }

    static func adoptionOperations(
        local: BrowserTabSessionSnapshot, values: [String: BrowserSyncChange], deleted: Set<String>
    ) -> [BrowserSyncFolderOperation] {
        var current = values.filter { $0.value.op == .upsert && !deleted.contains($0.key) }
        var tombstones = deleted
        let localChanges = canonicalChanges(local)
        let groups = Dictionary(grouping: localChanges, by: container)
        var containers = [Container](), seen = Set<Container>()
        for change in localChanges where seen.insert(container(change)).inserted {
            containers.append(container(change))
        }
        var result = [Operation]()
        func append(_ operation: Operation) {
            result.append(operation)
            apply([operation], to: &current, deleted: &tombstones)
        }
        // Legacy tab ranks describe a flat list. They cannot be compared with
        // local mixed sibling ranks. Adopt through typed neighbors instead.
        // Canonical folders and existing memberships always retain authority.
        for list in containers {
            let siblings = groups[list, default: []]
            let references = siblings.map(ref)
            let anchors = Set(references.filter {
                live($0, current, tombstones).map { container($0) == list } == true
            })
            let following = followingAnchors(references, kept: anchors)
            var preceding: Ref?
            for (index, change) in siblings.enumerated() {
                if change.folderData != nil, current[key(change)] == nil, !tombstones.contains(key(change)),
                   valid(destination(change), current, tombstones)
                {
                    append(create(change, before: following[index], after: preceding))
                }
                if live(ref(change), current, tombstones).map({ container($0) == list }) == true {
                    preceding = ref(change)
                }
            }
        }
        let adoptedTabs = Set(localChanges.compactMap { change -> Ref? in
            guard let localTab = change.tabData, localTab.placement == .spacePinned,
                  let parent = localTab.pinnedFolderID,
                  let tab = live(ref(change), current, tombstones)?.tabData,
                  tab.placement == .spacePinned, tab.pinnedFolderID == nil,
                  let folder = live(.init(entityType: .folder, entityID: parent), current, tombstones)?.folderData,
                  folder.spaceID == tab.spaceID else { return nil }
            return ref(change)
        })
        for list in containers {
            let siblings = groups[list, default: []], references = siblings.map(ref)
            let anchors = Set(references.filter {
                !adoptedTabs.contains($0)
                    && live($0, current, tombstones).map { container($0) == list } == true
            })
            let following = followingAnchors(references, kept: anchors)
            var preceding: Ref?, index = 0
            while index < siblings.count {
                guard adoptedTabs.contains(references[index]) else {
                    if anchors.contains(references[index]) {
                        preceding = references[index]
                    }
                    index += 1
                    continue
                }
                let start = index
                while index < siblings.count, adoptedTabs.contains(references[index]), index - start < 1000 {
                    index += 1
                }
                append(.move(
                    items: Array(references[start..<index]), destination: destination(siblings[start]),
                    before: following[index - 1], after: preceding
                ))
                preceding = references[index - 1]
            }
        }
        return result
    }

    // MARK: Private

    private typealias Ref = BrowserSyncEntityReference
    private typealias Change = BrowserSyncChange
    private typealias Operation = BrowserSyncFolderOperation

    private enum Container: Hashable { case spaces, apps, temporary(String), pinned(String, String?) }
    private struct Plan { let list: Container
        let items: [Ref]
        var kept: Set<Ref>
        let created: Set<Ref>
    }

    private static func ref(_ change: Change) -> Ref { .init(entityType: change.entityType, entityID: change.entityID) }
    private static func key(_ reference: Ref) -> String { BrowserSyncOutboxProjection.key(
        type: reference.entityType,
        id: reference.entityID
    ) }
    private static func key(_ change: Change) -> String { key(ref(change)) }
    private static func rank(_ change: Change) -> Double { change.spaceData?.rank ?? change.tabData?.rank ?? change
        .folderData?.rank ?? 0
    }

    private static func container(_ change: Change) -> Container { container(destination(change)) }
    private static func container(_ destination: BrowserSyncFolderDestination) -> Container {
        switch destination {
        case .spaces: .spaces
        case .tabs(_, .app, _): .apps
        case .tabs(let space, .temporary, _): .temporary(space)
        case .tabs(let space, .spacePinned, let folder): .pinned(space, folder)
        }
    }

    private static func destination(_ change: Change) -> BrowserSyncFolderDestination {
        if let folder = change.folderData {
            return .tabs(
                spaceID: folder.spaceID,
                placement: .spacePinned,
                pinnedFolderID: folder.parentFolderID
            )
        }
        if let tab = change.tabData {
            return .tabs(
                spaceID: tab.spaceID,
                placement: tab.placement,
                pinnedFolderID: tab.pinnedFolderID
            )
        }
        return .spaces
    }

    private static func live(_ reference: Ref, _ values: [String: Change], _ deleted: Set<String>) -> Change? {
        guard !deleted.contains(key(reference)), let value = values[key(reference)],
              value.op == .upsert else { return nil }
        return value
    }

    private static func valid(
        _ destination: BrowserSyncFolderDestination,
        _ values: [String: Change],
        _ deleted: Set<String>
    ) -> Bool {
        guard case .tabs(let space, let placement, let folder) = destination else { return true }
        guard placement == .spacePinned || folder == nil else { return false }
        if placement == .app {
            return true
        }
        guard live(.init(entityType: .space, entityID: space), values, deleted)?.spaceData != nil else { return false }
        var current = folder, seen = Set<String>()
        while let id = current {
            guard seen.insert(id).inserted,
                  let parent = live(.init(entityType: .folder, entityID: id), values, deleted)?.folderData,
                  parent.spaceID == space else { return false }
            current = parent.parentFolderID
        }
        return true
    }

    private static func list(
        _ container: Container,
        _ values: [String: Change],
        _ deleted: Set<String> = []
    ) -> [Change] {
        values.values
            .filter { $0.op == .upsert && !deleted.contains(key($0)) && self.container($0) == container }
            .sorted {
                rank($0) == rank($1) ? key($0).utf16.lexicographicallyPrecedes(key($1).utf16) : rank($0) < rank($1)
            }
    }

    private static func orderedValues(_ values: [String: Change]) -> [Change] {
        let spaces = list(.spaces, values), groups = Dictionary(
            grouping: values.values.filter { $0.op == .upsert },
            by: container
        )
        var output = spaces + list(.apps, values), seen = Set<Ref>()
        func appendPinned(_ space: String, _ parent: String?) {
            for item in (groups[.pinned(space, parent)] ?? []).sorted(by: {
                rank($0) == rank($1) ? key($0).utf16.lexicographicallyPrecedes(key($1).utf16) : rank($0) < rank($1)
            }) where seen.insert(ref(item)).inserted {
                output.append(item)
                if item.folderData != nil {
                    appendPinned(space, item.entityID)
                }
            }
        }
        for space in spaces {
            appendPinned(space.entityID, nil)
            output += list(.temporary(space.entityID), values)
        }
        return output
    }

    private static func ancestors(_ id: String?, values: [String: Change]) -> [String] {
        var result = [String](), current = id, seen = Set<String>()
        while let parent = current, seen.insert(parent).inserted {
            result.append(parent)
            current = values[key(.init(entityType: .folder, entityID: parent))]?.folderData?.parentFolderID
        }
        return result
    }

    private static func subtree(
        _ roots: Set<String>,
        _ values: [String: Change],
        _ deleted: Set<String>
    ) -> Set<String> {
        let folders = values.values.filter { $0.folderData != nil && $0.op == .upsert && !deleted.contains(key($0)) }
        let children = Dictionary(grouping: folders, by: { $0.folderData!.parentFolderID })
        var result = roots, queue = Array(roots), index = 0
        while index < queue.count {
            for child in children[queue[index], default: []]
                where result.insert(child.entityID).inserted
            {
                queue.append(child.entityID)
            }
            index += 1
        }
        return result
    }

    private static func moveContext(
        _ items: [Ref], destination: BrowserSyncFolderDestination,
        values: [String: Change], deleted: Set<String>
    ) -> (survivors: [Change], folders: Set<String>)? {
        guard valid(destination, values, deleted), Set(items).count == items.count else { return nil }
        let survivors = items.compactMap { live($0, values, deleted) }
        guard !survivors.isEmpty, survivors.allSatisfy({ change in
            switch destination {
            case .spaces: change.entityType == .space
            case .tabs(_, let placement, _): change
                .entityType != .space && (change.entityType != .folder || placement == .spacePinned)
            }
        }) else { return nil }
        let folders = subtree(Set(survivors.filter { $0.folderData != nil }.map(\.entityID)), values, deleted)
        guard !survivors.contains(where: { change in
            (change.folderData?.parentFolderID ?? change.tabData?.pinnedFolderID).map(folders.contains) == true
        }) else { return nil }
        if case .tabs(_, _, let parent) = destination, parent.map(folders.contains) == true {
            return nil
        }
        return (survivors, folders)
    }

    private static func move(
        _ items: [Ref],
        to destination: BrowserSyncFolderDestination,
        before: Ref?,
        after: Ref?,
        values: inout [String: Change],
        deleted: Set<String>
    ) {
        guard let context = moveContext(items, destination: destination, values: values, deleted: deleted)
        else { return }
        let survivors = context.survivors
        let folders = context.folders
        let moved = Set(survivors.map(ref))
        for source in Set(survivors.map(container)) where source != container(destination) {
            publish(list(source, values, deleted).filter { !moved.contains(ref($0)) }, values: &values)
        }
        let group = survivors.map { relocated($0, to: destination) }
        if case .tabs(let space, _, _) = destination {
            for change in Array(values.values) where !moved.contains(ref(change)) && change.op == .upsert {
                if let folder = change.folderData, folders.contains(change.entityID) {
                    values[key(change)] = replacing(
                        change,
                        folder: .init(
                            spaceID: space,
                            parentFolderID: folder.parentFolderID,
                            title: folder.title,
                            systemImageName: folder.systemImageName,
                            rank: folder.rank
                        )
                    )
                } else if let tab = change.tabData, tab.placement == .spacePinned,
                          tab.pinnedFolderID.map(folders.contains) == true
                {
                    values[key(change)] = relocated(
                        change,
                        to: .tabs(spaceID: space, placement: .spacePinned, pinnedFolderID: tab.pinnedFolderID)
                    )
                }
            }
        }
        insert(
            group,
            destination: container(destination),
            before: before,
            after: after,
            values: &values,
            deleted: deleted
        )
    }

    private static func create(
        _ change: Change,
        before: Ref?,
        after: Ref?,
        values: inout [String: Change],
        deleted: Set<String>
    ) {
        guard !deleted.contains(key(change)), live(ref(change), values, deleted) == nil,
              valid(destination(change), values, deleted) else { return }
        insert(
            [change],
            destination: container(change),
            before: before,
            after: after,
            values: &values,
            deleted: deleted
        )
    }

    private static func insert(
        _ group: [Change],
        destination: Container,
        before: Ref?,
        after: Ref?,
        values: inout [String: Change],
        deleted: Set<String>
    ) {
        let moving = Set(group.map(ref))
        var siblings = list(destination, values, deleted).filter { !moving.contains(ref($0)) }
        let beforeIndex = before.flatMap { anchor in siblings.firstIndex { ref($0) == anchor } }
        let afterIndex = after.flatMap { anchor in siblings.firstIndex { ref($0) == anchor }.map { $0 + 1 } }
        siblings.insert(contentsOf: group, at: beforeIndex ?? afterIndex ?? siblings.count)
        publish(siblings, values: &values)
    }

    private static func publish(_ items: [Change], values: inout [String: Change]) {
        for (index, item) in items.enumerated() {
            values[key(item)] = ranked(item, Double(index))
        }
    }

    private static func remove(_ reference: Ref, values: inout [String: Change], deleted: inout Set<String>) {
        let old = values[key(reference)]
        let folders = reference.entityType == .folder ? subtree([reference.entityID], values, deleted) : []
        var targets = [reference]
        for value in values.values where value.op == .upsert {
            if reference.entityType == .space {
                if value.folderData?.spaceID == reference
                    .entityID ||
                    (value.tabData?.spaceID == reference.entityID && value.tabData?.placement != .app)
                {
                    targets.append(ref(value))
                }
            } else if reference.entityType == .folder {
                if value.entityType == .folder && folders.contains(value.entityID)
                    ||
                    (value.tabData?.placement == .spacePinned && value.tabData?
                        .pinnedFolderID
                        .map(folders.contains) == true)
                {
                    targets.append(ref(value))
                }
            }
        }
        for target in targets {
            deleted.insert(key(target))
            values[key(target)] = .init(
                entityType: target.entityType,
                entityID: target.entityID,
                op: .delete,
                spaceData: nil,
                tabData: nil
            )
        }
        if let old {
            publish(list(container(old), values, deleted), values: &values)
        }
    }

    private static func ranked(_ change: Change, _ rank: Double) -> Change {
        if let data = change.spaceData {
            return Change(
                entityType: .space,
                entityID: change.entityID,
                op: change.op,
                spaceData: .init(
                    title: data.title,
                    systemImageName: data.systemImageName,
                    rank: rank,
                    isPinnedSectionCollapsed: data
                        .isPinnedSectionCollapsed,
                    selectedTabID: data.selectedTabID
                ),
                tabData: nil
            )
        }
        if let data = change.folderData {
            return replacing(
                change,
                folder: .init(
                    spaceID: data.spaceID,
                    parentFolderID: data.parentFolderID,
                    title: data.title,
                    systemImageName: data.systemImageName,
                    rank: rank
                )
            )
        }
        guard let data = change.tabData else { return change }
        return replacing(change, tab: .init(
            spaceID: data.spaceID,
            placement: data.placement,
            rank: rank,
            urlString: data.urlString,
            pinnedURLString: data.pinnedURLString,
            title: data.title,
            userTitleOverride: data.userTitleOverride,
            faviconURLString: data.faviconURLString,
            lastActivityAt: data.lastActivityAt,
            pinnedFolderID: data.pinnedFolderID
        ))
    }

    private static func relocated(_ change: Change, to destination: BrowserSyncFolderDestination) -> Change {
        guard case .tabs(let space, let placement, let parent) = destination else { return change }
        if let folder = change.folderData {
            return replacing(
                change,
                folder: .init(
                    spaceID: space,
                    parentFolderID: parent,
                    title: folder.title,
                    systemImageName: folder
                        .systemImageName,
                    rank: folder.rank
                )
            )
        }
        guard let tab = change.tabData else { return change }
        return replacing(
            change,
            tab: .init(
                spaceID: space,
                placement: placement,
                rank: tab.rank,
                urlString: tab.urlString,
                pinnedURLString: placement == .spacePinned
                    ? (tab.placement == .spacePinned ? tab.pinnedURLString : tab.urlString)
                    : nil,
                title: tab.title,
                userTitleOverride: tab.userTitleOverride,
                faviconURLString: tab.faviconURLString,
                lastActivityAt: tab.lastActivityAt,
                pinnedFolderID: parent
            )
        )
    }

    private static func replacing(_ old: Change, tab: BrowserSyncTabPayload) -> Change {
        .init(entityType: .tab, entityID: old.entityID, op: old.op, spaceData: nil, tabData: tab)
    }

    private static func replacing(_ old: Change, folder: BrowserSyncFolderPayload) -> Change {
        .init(entityType: .folder, entityID: old.entityID, op: old.op, spaceData: nil, tabData: nil, folderData: folder)
    }

    private static func create(_ change: Change, before: Ref?, after: Ref?) -> Operation {
        if let data = change.spaceData {
            return .createSpace(
                id: change.entityID,
                data: .init(
                    title: data.title,
                    systemImageName: data
                        .systemImageName,
                    isPinnedSectionCollapsed: data
                        .isPinnedSectionCollapsed,
                    selectedTabID: data
                        .selectedTabID
                ),
                before: before,
                after: after
            )
        }
        if let data = change.folderData {
            return .createFolder(
                id: change.entityID,
                data: .init(
                    spaceID: data.spaceID,
                    parentFolderID: data
                        .parentFolderID,
                    title: data.title,
                    systemImageName: data
                        .systemImageName
                ),
                before: before,
                after: after
            )
        }
        let data = change.tabData!
        return .createTab(
            id: change.entityID,
            data: .init(
                spaceID: data.spaceID,
                placement: data.placement,
                pinnedFolderID: data.pinnedFolderID,
                urlString: data.urlString,
                pinnedURLString: data.pinnedURLString,
                title: data.title,
                userTitleOverride: data.userTitleOverride,
                faviconURLString: data.faviconURLString,
                lastActivityAt: data.lastActivityAt
            ),
            before: before,
            after: after
        )
    }

    private static func patch(_ old: String?, _ next: String?) -> BrowserSyncPatchValue<String> {
        old == next ? .unchanged : next.map(BrowserSyncPatchValue.set) ?? .clear
    }

    private static func applying<T>(_ patch: BrowserSyncPatchValue<T>, _ value: T?) -> T? {
        switch patch { case .unchanged: value
        case .set(let next): next
        case .clear: nil }
    }

    private static func followingAnchors(_ items: [Ref], kept: Set<Ref>) -> [Ref?] {
        var following: Ref?, result = [Ref?](repeating: nil, count: items.count)
        for index in items.indices.reversed() {
            result[index] = following
            if kept.contains(items[index]) {
                following = items[index]
            }
        }
        return result
    }

    private static func increasing(_ candidates: [(Ref, Int)]) -> Set<Ref> {
        var tails = [Int](), previous = [Int](repeating: -1, count: candidates.count)
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
                previous[index] = tails[low - 1]
            }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }
        var result = Set<Ref>(), index = tails.last ?? -1
        while index >= 0 {
            result.insert(candidates[index].0)
            index = previous[index]
        }
        return result
    }

    private static func sidebarIDs(_ tabs: [BrowserTabSessionSnapshotTab]) -> [String: [String?]] {
        var result = [String: [String?]]()
        for placement in [BrowserTabPlacement.spacePinned, .temporary] {
            for tab in tabs where tab.placement == placement {
                result[
                    tab.spaceID ?? BrowserSessionDefaults.defaultSpaceID,
                    default: []
                ].append(tab.id)
            }
        }
        return result
    }
}
