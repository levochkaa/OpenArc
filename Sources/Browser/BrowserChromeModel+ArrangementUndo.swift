// BrowserChromeModel+ArrangementUndo.swift

import Foundation

// MARK: - Arrangement Undo

/// Undo for edits that rearrange or rename what is already in the sidebar:
/// moving rows and Spaces, pinning, renaming, and Split View. An edit records
/// the arrangement before and after it. Undo and Redo touch only what that
/// edit changed and move rows through the ordinary drop path, so the session
/// and sync see plain moves.
extension BrowserChromeModel {
    struct SidebarArrangement: Equatable {
        enum Item: Hashable {
            case tab(syncID: String)
            case folder(String)
        }

        var children: [BrowserSidebarDropContainer: [Item]]
        var tabTitles: [String: String]
        var folderTitles: [String: String]
        var spaceTitles: [String: String]
        var spaceOrder: [String]
        var splitGroups: [SplitGroup]

        var containers: [Item: BrowserSidebarDropContainer] {
            var result = [Item: BrowserSidebarDropContainer]()
            for (container, items) in children {
                for item in items {
                    result[item] = container
                }
            }
            return result
        }
    }

    /// Runs a user edit and registers its Undo when it changed the arrangement.
    /// Nested edits belong to the outermost one. An edit made while Undo or
    /// Redo is still finishing registers nothing, so it keeps its other branch.
    @discardableResult func withArrangementUndo<T>(_ actionName: String, _ edit: () -> T) -> T {
        let records = arrangementUndoDepth == 0 && !isApplyingArrangementUndo && canRegisterTabUndo
            && undoManager.isUndoRegistrationEnabled && !undoManager.isTabTransitionPending
        let before = records ? sidebarArrangement() : nil
        arrangementUndoDepth += 1
        let result = edit()
        arrangementUndoDepth -= 1
        if let before {
            let after = sidebarArrangement()
            if after != before {
                undoManager.registerTabAction(arrangementAction(actionName, from: after, to: before))
            }
        }
        return result
    }

    func sidebarArrangement() -> SidebarArrangement {
        let tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
        let syncIDs = Dictionary(tabs.map { ($0.id, $0.syncID) }, uniquingKeysWith: { first, _ in first })
        var children = [BrowserSidebarDropContainer: [SidebarArrangement.Item]]()
        for (container, items) in tree.children {
            children[container] = items.compactMap { item in
                switch item {
                case .tab(let id): syncIDs[id].map { .tab(syncID: $0) }
                case .folder(let id): .folder(id)
                }
            }
        }
        return SidebarArrangement(
            children: children,
            tabTitles: Dictionary(
                tabs.map { ($0.syncID, $0.userTitleOverride ?? "") },
                uniquingKeysWith: { first, _ in first },
            ),
            folderTitles: Dictionary(uniqueKeysWithValues: pinnedTabFolders.map { ($0.id, $0.title) }),
            spaceTitles: Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.title) }),
            spaceOrder: spaces.map(\.id),
            splitGroups: validatedSplitGroups(),
        )
    }

    /// Items an edit moved from `before` to `after`: those that changed
    /// container, plus the fewest whose order changed within one.
    nonisolated static func movedItems(
        from before: SidebarArrangement,
        to after: SidebarArrangement,
    ) -> Set<SidebarArrangement.Item> {
        let beforeContainers = before.containers
        var moved = Set<SidebarArrangement.Item>()
        for (container, items) in after.children {
            let beforeIndices = Dictionary(
                (before.children[container] ?? []).enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first },
            )
            var stayed = [SidebarArrangement.Item]()
            for item in items {
                guard let beforeContainer = beforeContainers[item] else { continue }
                if beforeContainer == container {
                    stayed.append(item)
                } else {
                    moved.insert(item)
                }
            }
            let kept = longestIncreasingSubsequence(stayed.map { beforeIndices[$0] ?? 0 })
            for (index, item) in stayed.enumerated() where !kept.contains(index) {
                moved.insert(item)
            }
        }
        return moved
    }

    /// Positions of the longest strictly increasing run of `values`.
    nonisolated static func longestIncreasingSubsequence(_ values: [Int]) -> Set<Int> {
        var tails = [Int]()
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value {
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
        var result = Set<Int>()
        var index = tails.last ?? -1
        while index >= 0 {
            result.insert(index)
            index = previous[index]
        }
        return result
    }

    private func arrangementAction(
        _ actionName: String,
        from current: SidebarArrangement,
        to target: SidebarArrangement,
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self else {
                completion(.cancelled)
                return
            }
            applySidebarArrangement(target, changedFrom: current)
            completion(.committed(inverse: arrangementAction(actionName, from: target, to: current)))
        }
    }

    /// Restores what differs between `changed` and `target`, leaving later,
    /// unrelated edits alone.
    private func applySidebarArrangement(_ target: SidebarArrangement, changedFrom changed: SidebarArrangement) {
        isApplyingArrangementUndo = true
        defer { isApplyingArrangementUndo = false }

        restoreSpaceOrder(target.spaceOrder, changedFrom: changed.spaceOrder)
        restoreSidebarPositions(
            of: Self.movedItems(from: target, to: changed).union(Self.movedItems(from: changed, to: target)),
            to: target,
        )

        for (syncID, title) in target.tabTitles where changed.tabTitles[syncID] != title {
            guard let id = tabs.first(where: { $0.syncID == syncID })?.id else { continue }
            setUserTitleOverride(title.isEmpty ? nil : title, forTabID: id)
        }
        for (id, title) in target.folderTitles where changed.folderTitles[id].map({ $0 != title }) == true {
            setTitle(title, forPinnedTabFolderID: id)
        }
        for (id, title) in target.spaceTitles where changed.spaceTitles[id].map({ $0 != title }) == true {
            setTitle(title, forSpaceID: id)
        }
        restoreSplitGroups(target.splitGroups, changedFrom: changed.splitGroups)
    }

    private func restoreSpaceOrder(_ target: [String], changedFrom changed: [String]) {
        guard target != changed else { return }
        let order = target.filter { id in spaces.contains { $0.id == id } }
        for (index, id) in order.enumerated() where spaces.firstIndex(where: { $0.id == id }) != index {
            moveSpace(id: id, toIndex: index)
        }
    }

    /// Moves each item back before the item that follows it in `target`,
    /// last first, so every anchor is already in place.
    private func restoreSidebarPositions(of items: Set<SidebarArrangement.Item>, to target: SidebarArrangement) {
        guard !items.isEmpty else { return }
        for (container, targetItems) in target.children {
            for (index, item) in targetItems.enumerated().reversed() where items.contains(item) {
                let tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
                guard let current = runtimeItem(item), container.spaceID.map(spaceExists) != false,
                      container.folderID.map({ tree.folders[$0] != nil }) != false
                else { continue }
                let present = Set(tree.items(in: container))
                let anchor = targetItems[(index + 1)...]
                    .lazy
                    .compactMap { self.runtimeItem($0) }
                    .first { present.contains($0) && $0 != current }
                let siblings = tree.items(in: container)
                if let position = siblings.firstIndex(of: current) {
                    let next = siblings.indices.contains(position + 1) ? siblings[position + 1] : nil
                    if next == anchor { continue }
                }
                let payload: BrowserSidebarDragPayload
                switch current {
                case .tab(let id):
                    payload = .init(primary: current, tabIDs: [id])
                case .folder(let id):
                    guard let folder = tree.folders[id] else { continue }
                    payload = .init(
                        primary: current,
                        tabIDs: Set(tree.tabIDs(in: .pinned(folder.spaceID, folderID: id))),
                    )
                }
                commitSidebarDrop(payload: payload, destination: .init(container: container, beforeItem: anchor))
            }
        }
    }

    private func restoreSplitGroups(_ target: [SplitGroup], changedFrom changed: [SplitGroup]) {
        let targetByID = Dictionary(target.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changedByID = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let edited = Set(targetByID.keys).union(changedByID.keys).filter { targetByID[$0] != changedByID[$0] }
        guard !edited.isEmpty else { return }
        let restored = target.filter { edited.contains($0.id) }
        let restoredMembers = Set(restored.flatMap(\.tabSyncIDs))
        let groups = splitGroups.filter { !edited.contains($0.id) }.compactMap { group -> SplitGroup? in
            var group = group
            let members = group.tabSyncIDs.filter { !restoredMembers.contains($0) }
            if members != group.tabSyncIDs {
                group.tabSyncIDs = members
                group.fractions = nil
            }
            return members.count >= 2 ? group : nil
        } + restored
        guard groups != splitGroups else { return }
        splitGroups = groups
        persistSplitGroupChange()
    }

    private func runtimeItem(_ item: SidebarArrangement.Item) -> BrowserSidebarItemID? {
        switch item {
        case .tab(let syncID): tabs.first { $0.syncID == syncID }.map { .tab($0.id) }
        case .folder(let id): pinnedTabFolders.contains { $0.id == id } ? .folder(id) : nil
        }
    }

    private func spaceExists(_ id: String) -> Bool {
        spaces.contains { $0.id == id }
    }
}
