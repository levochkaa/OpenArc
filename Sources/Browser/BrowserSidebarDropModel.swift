import Foundation

// MARK: - BrowserSidebarItemID

/// Drop addresses name siblings, never an index in an unrelated flattened list.
enum BrowserSidebarItemID: Hashable {
    case tab(String)
    case folder(String)

    // MARK: Internal

    var rawID: String { switch self { case .tab(let id), .folder(let id): id } }
}

// MARK: - BrowserSidebarDropContainer

struct BrowserSidebarDropContainer: Hashable {
    static let app = BrowserSidebarDropContainer(section: .app)

    let section: BrowserSidebarTabSection
    var spaceID: String?
    var folderID: String?

    static func pinned(_ spaceID: String, folderID: String? = nil) -> Self {
        Self(section: .spacePinned, spaceID: spaceID, folderID: folderID)
    }

    static func temporary(_ spaceID: String) -> Self { Self(section: .temporary, spaceID: spaceID) }
}

// MARK: - BrowserSidebarDropDestination

struct BrowserSidebarDropDestination: Hashable {
    let container: BrowserSidebarDropContainer
    /// nil means after the last sibling in this container.
    var beforeItem: BrowserSidebarItemID?
}

// MARK: - BrowserSidebarDragPayload

struct BrowserSidebarDragPayload: Equatable {
    let primary: BrowserSidebarItemID
    let tabIDs: Set<String>
}

// MARK: - BrowserSidebarTabTree

/// The same tree supplies visible rows and the order used to commit a drop.
/// In particular, a parent containing only nested folders still has a root item.
struct BrowserSidebarTabTree {
    // MARK: Lifecycle

    init(snapshot: BrowserSidebarSnapshot) {
        self.snapshot = snapshot
        self.folders = Dictionary(uniqueKeysWithValues: snapshot.pinnedTabFolders.map { ($0.id, $0) })
        children[.app] = snapshot.appTabs.map { .tab($0.id) }
        for space in snapshot.spaces {
            children[.pinned(space.id)] = []
            children[.temporary(space.id)] = snapshot.temporaryTabs(in: space.id).map { .tab($0.id) }
        }
        for folder in snapshot.pinnedTabFolders {
            children[.pinned(folder.spaceID, folderID: folder.id)] = []
        }
        for tab in snapshot.allTabs where tab.placement == .spacePinned {
            var container = BrowserSidebarDropContainer.pinned(tab.spaceID, folderID: tab.pinnedFolderID)
            if let id = container.folderID, folders[id]?.spaceID != tab.spaceID {
                container.folderID = nil
            }
            append(.tab(tab.id), to: container)
            var visited = Set<String>()
            while let id = container.folderID, let folder = folders[id], visited.insert(id).inserted {
                let parentID = folder.parentFolderID.flatMap { folders[$0]?.spaceID == tab.spaceID ? $0 : nil }
                let parent = BrowserSidebarDropContainer.pinned(tab.spaceID, folderID: parentID)
                append(.folder(id), to: parent)
                container = parent
            }
        }
        for (container, items) in children {
            for item in items {
                parents[item] = container
            }
        }
    }

    // MARK: Internal

    let snapshot: BrowserSidebarSnapshot
    var children = [BrowserSidebarDropContainer: [BrowserSidebarItemID]]()
    var folders: [String: BrowserChromeModel.PinnedTabFolder]

    func items(in container: BrowserSidebarDropContainer) -> [BrowserSidebarItemID] { children[container] ?? [] }
    func container(of item: BrowserSidebarItemID) -> BrowserSidebarDropContainer? { parents[item] }

    func tabIDs(in container: BrowserSidebarDropContainer) -> [String] {
        var visited = Set<String>()
        func collect(_ container: BrowserSidebarDropContainer) -> [String] {
            items(in: container).flatMap { item -> [String] in
                switch item {
                case .tab(let id): return [id]
                case .folder(let id):
                    guard visited.insert(id).inserted, let folder = folders[id] else { return [] }
                    return collect(.pinned(folder.spaceID, folderID: id))
                }
            }
        }
        return collect(container)
    }

    func descendantFolderIDs(including folderID: String) -> Set<String> {
        var result = Set<String>()
        func collect(_ id: String) {
            guard result.insert(id).inserted, let folder = folders[id] else { return }
            for item in items(in: .pinned(folder.spaceID, folderID: id)) {
                if case .folder(let child) = item {
                    collect(child)
                }
            }
        }
        collect(folderID)
        return result
    }

    func orderedTabIDs() -> [String] {
        var ids = tabIDs(in: .app)
        for space in snapshot.spaces {
            ids += tabIDs(in: .pinned(space.id))
            ids += tabIDs(in: .temporary(space.id))
        }
        let seen = Set(ids)
        ids += snapshot.allTabs.filter { !seen.contains($0.id) }.map(\.id)
        return ids
    }

    // MARK: Private

    private var parents = [BrowserSidebarItemID: BrowserSidebarDropContainer]()

    private mutating func append(_ item: BrowserSidebarItemID, to container: BrowserSidebarDropContainer) {
        if children[container]?.contains(item) != true {
            children[container, default: []].append(item)
        }
    }
}

// MARK: - BrowserSidebarMovePlan

@MainActor struct BrowserSidebarMovePlan {
    let payload: BrowserSidebarDragPayload
    let destination: BrowserSidebarDropDestination
    let tabs: [BrowserChromeModel.Tab]
    let folders: [BrowserChromeModel.PinnedTabFolder]

    static func make(
        snapshot: BrowserSidebarSnapshot,
        payload: BrowserSidebarDragPayload,
        destination: BrowserSidebarDropDestination,
        transformTab: (BrowserChromeModel.Tab, BrowserSidebarDropContainer) -> BrowserChromeModel.Tab?
    ) -> Self? {
        var tree = BrowserSidebarTabTree(snapshot: snapshot)
        let originalOrder = tree.orderedTabIDs()
        let originalFolders = tree.folders
        let target = destination.container
        guard target.section == .app || snapshot.spaces.contains(where: { $0.id == target.spaceID }) else { return nil }
        if let folderID = target.folderID {
            guard target.section == .spacePinned, tree.folders[folderID]?.spaceID == target.spaceID else { return nil }
        }
        let siblings = tree.items(in: target)
        guard destination.beforeItem == nil || siblings.contains(destination.beforeItem!) else { return nil }
        let originalIndex = destination.beforeItem.flatMap { siblings.firstIndex(of: $0) } ?? siblings.count
        let movingItems: [BrowserSidebarItemID]
        let originalTabs = Dictionary(uniqueKeysWithValues: snapshot.allTabs.map { ($0.id, $0) })
        var updatedTabs = originalTabs
        switch payload.primary {
        case .tab(let primary):
            guard payload.tabIDs.contains(primary), !payload.tabIDs.isEmpty,
                  payload.tabIDs.count == 1 || target.section == .spacePinned else { return nil }
            movingItems = tree.orderedTabIDs().filter { payload.tabIDs.contains($0) }.map { .tab($0) }
            guard movingItems.count == payload.tabIDs.count else { return nil }
            for id in payload.tabIDs {
                guard let old = updatedTabs[id], let transformed = transformTab(old, target) else { return nil }
                updatedTabs[id] = transformed
            }
        case .folder(let id):
            guard target.section == .spacePinned, let folder = tree.folders[id] else { return nil }
            let descendants = tree.descendantFolderIDs(including: id)
            guard target.folderID.map({ !descendants.contains($0) }) ?? true,
                  Set(tree.tabIDs(in: .pinned(folder.spaceID, folderID: id))) == payload.tabIDs,
                  !payload.tabIDs.isEmpty else { return nil }
            movingItems = [.folder(id)]
            let spaceID = target.spaceID!
            for descendant in descendants {
                guard var value = tree.folders[descendant] else { continue }
                let oldContainer = BrowserSidebarDropContainer.pinned(value.spaceID, folderID: descendant)
                value.spaceID = spaceID
                if descendant == id {
                    value.parentFolderID = target.folderID
                }
                if target.folderID != nil, descendant == id {
                    value.isExpanded = true
                }
                tree.folders[descendant] = value
                let contents = tree.children.removeValue(forKey: oldContainer) ?? []
                tree.children[.pinned(spaceID, folderID: descendant)] = contents
            }
            for tabID in payload.tabIDs {
                updatedTabs[tabID]?.spaceID = spaceID
            }
        }
        let moving = Set(movingItems)
        let index = siblings.prefix(originalIndex).filter { !moving.contains($0) }.count
        for container in Array(tree.children.keys) {
            tree.children[container]?.removeAll { moving.contains($0) }
        }
        tree.children[target, default: []].insert(contentsOf: movingItems, at: min(index, tree.items(in: target).count))
        let orderedIDs = tree.orderedTabIDs()
        guard Set(orderedIDs).count == snapshot.allTabs.count,
              orderedIDs.count == snapshot.allTabs.count else { return nil }
        let tabs = orderedIDs.compactMap { updatedTabs[$0] }
        let folders = snapshot.pinnedTabFolders.compactMap { tree.folders[$0.id] }
        let folderContainerChanged = folders.contains {
            $0.spaceID != originalFolders[$0.id]?.spaceID || $0.parentFolderID != originalFolders[$0.id]?.parentFolderID
        }
        // Auto-expanding a moved folder is presentation metadata, not a reason
        // to turn dropping it back at its own position into an actual move.
        guard orderedIDs != originalOrder || updatedTabs != originalTabs || folderContainerChanged else { return nil }
        return Self(payload: payload, destination: destination, tabs: tabs, folders: folders)
    }
}
