// BrowserSidebarSnapshot.swift

import AppKit
import QuartzCore

// MARK: - BrowserSidebarSnapshot

struct BrowserSidebarSnapshot: Equatable {
    // MARK: Internal

    let spaces: [BrowserChromeModel.Space]
    let selectedSpaceID: String?
    let activeSpace: BrowserChromeModel.Space?
    let isActiveSpacePinnedSectionCollapsed: Bool
    let allTabs: [BrowserChromeModel.Tab]
    let pinnedTabFolders: [BrowserChromeModel.PinnedTabFolder]
    let appTabs: [BrowserChromeModel.Tab]
    let spacePinnedTabs: [BrowserChromeModel.Tab]
    let temporaryTabs: [BrowserChromeModel.Tab]
    let selectedTabID: String?
    let archivableTabIDs: Set<String>
    let canGoBack: Bool
    let canGoForward: Bool
    let canStopLoading: Bool
    let canReload: Bool
    /// Runtime tab IDs of each Split View in pane order. The sidebar shows a
    /// split as one row in place of its first member.
    var splitGroups = [[String]]()
    /// Custom names of splits, by their pane IDs in pane order.
    var splitNames = [[String]: BrowserSidebarSplitName]()
    /// Runtime IDs of muted tabs; their rows show a speaker that unmutes.
    var mutedTabIDs = Set<String>()
    /// Runtime IDs of tabs with sound; their rows show a speaker that mutes.
    var audibleTabIDs = Set<String>()
    /// Mini players for media in tabs off screen, newest first.
    var miniPlayers = [BrowserMiniPlayerItem]()
    /// Symbols chosen in place of favicons, by runtime tab ID.
    var tabIcons = [String: String]()

    var selectedTab: BrowserChromeModel.Tab? {
        guard let selectedTabID else {
            return nil
        }

        return tab(withID: selectedTabID)
    }

    /// The panes of the split that contains a tab, in pane order.
    func splitMembers(ofTabID tabID: String) -> [String]? {
        splitGroups.first { $0.contains(tabID) }
    }

    func containsTab(withID tabID: String) -> Bool {
        allTabs.contains { $0.id == tabID }
    }

    func tab(withID tabID: String) -> BrowserChromeModel.Tab? {
        allTabs.first { $0.id == tabID }
    }

    func isPinnedSectionCollapsed(in spaceID: String) -> Bool {
        spaces.first { $0.id == spaceID }?.isPinnedSectionCollapsed ?? false
    }

    func spacePinnedTabs(in spaceID: String) -> [BrowserChromeModel.Tab] {
        allTabs.filter { $0.spaceID == spaceID && $0.placement == .spacePinned }
    }

    func temporaryTabs(in spaceID: String) -> [BrowserChromeModel.Tab] {
        allTabs.filter { $0.spaceID == spaceID && $0.placement == .temporary }
    }

    func pinnedTabFolders(in spaceID: String) -> [BrowserChromeModel.PinnedTabFolder] {
        pinnedTabFolders.filter { $0.spaceID == spaceID }
    }

    func pinnedTabFolder(withID folderID: String) -> BrowserChromeModel.PinnedTabFolder? {
        pinnedTabFolders.first { $0.id == folderID }
    }

    func visiblePinnedRows(
        in spaceID: String,
        revealedTabIDsByFolderID: [String: Set<String>] = [:],
    ) -> [BrowserSidebarPinnedRow] {
        let tree = BrowserSidebarTabTree(snapshot: self)
        let pinned = spacePinnedTabs(in: spaceID)
        let indices = Dictionary(uniqueKeysWithValues: pinned.enumerated().map { ($0.element.id, $0.offset) })
        let tabsByID = Dictionary(uniqueKeysWithValues: pinned.map { ($0.id, $0) })
        var result = [BrowserSidebarPinnedRow]()
        var visited = Set<String>()
        func append(_ container: BrowserSidebarDropContainer, depth: Int) {
            let items = tree.items(in: container)
            let directTabs = items.compactMap {
                item -> String? in if case .tab(let id) = item {
                    id
                } else {
                    nil
                }
            }
            for item in items {
                switch item {
                case .tab(let id):
                    guard let tab = tabsByID[id], let index = indices[id] else { continue }
                    result.append(.tab(.init(
                        tab: tab,
                        sectionIndex: index,
                        pinnedFolderID: container.folderID,
                        folderChildIndex: container.folderID == nil
                            ? nil
                            : directTabs.firstIndex(of: id),
                        depth: depth,
                    )))
                case .folder(let id):
                    guard visited.insert(id).inserted, let folder = tree.folders[id] else { continue }
                    let childContainer = BrowserSidebarDropContainer.pinned(spaceID, folderID: id)
                    let allChildren = tree.tabIDs(in: childContainer)
                    let childIndices = allChildren.compactMap { indices[$0] }
                    let first = childIndices.min() ?? 0
                    let after = (childIndices.max() ?? (first - 1)) + 1
                    let directChildren = tree.items(in: childContainer).compactMap { item -> String? in
                        if case .tab(let id) = item {
                            id
                        } else {
                            nil
                        }
                    }
                    result.append(.folder(.init(
                        folder: folder,
                        childCount: directChildren.count,
                        firstSectionIndex: first,
                        afterSectionIndex: after,
                        depth: depth,
                    )))
                    if folder.isExpanded {
                        append(childContainer, depth: depth + 1)
                    } else {
                        var revealed = revealedTabIDsByFolderID[id] ?? []
                        if let selected = selectedTab, selected.pinnedFolderID == id {
                            revealed.insert(selected.id)
                        }
                        for (childIndex, childID) in directChildren.enumerated() where revealed.contains(childID) {
                            guard let tab = tabsByID[childID], let index = indices[childID] else { continue }
                            result.append(.tab(.init(
                                tab: tab,
                                sectionIndex: index,
                                pinnedFolderID: id,
                                folderChildIndex: childIndex,
                                depth: depth + 1,
                            )))
                        }
                    }
                }
            }
        }
        append(.pinned(spaceID), depth: 0)
        return result
    }

    func replacingTabs(
        _ tabs: [BrowserChromeModel.Tab],
        pinnedTabFolders folders: [BrowserChromeModel.PinnedTabFolder]? = nil,
    ) -> BrowserSidebarSnapshot {
        let tabIDs = Set(tabs.map(\.id))
        return BrowserSidebarSnapshot(
            spaces: spaces,
            selectedSpaceID: selectedSpaceID,
            activeSpace: activeSpace,
            isActiveSpacePinnedSectionCollapsed: isActiveSpacePinnedSectionCollapsed,
            allTabs: tabs,
            pinnedTabFolders: folders ?? pinnedTabFolders,
            appTabs: tabs.filter { $0.placement == .app },
            spacePinnedTabs: tabs.filter { $0.spaceID == selectedSpaceID && $0.placement == .spacePinned },
            temporaryTabs: tabs.filter { $0.spaceID == selectedSpaceID && $0.placement == .temporary },
            selectedTabID: selectedTabID,
            archivableTabIDs: archivableTabIDs,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canStopLoading: canStopLoading,
            canReload: canReload,
            splitGroups: splitGroups.map { $0.filter(tabIDs.contains) }.filter { $0.count > 1 },
        )
    }

    // MARK: Private

    private func descendantTabCount(
        forFolderID folderID: String,
        in pinnedTabs: [BrowserChromeModel.Tab],
        foldersByID: [String: BrowserChromeModel.PinnedTabFolder],
    ) -> Int {
        descendantTabCount(
            forFolderID: folderID,
            in: pinnedTabs,
            foldersByID: foldersByID,
            visitedFolderIDs: [],
        )
    }

    private func descendantTabCount(
        forFolderID folderID: String,
        in pinnedTabs: [BrowserChromeModel.Tab],
        foldersByID: [String: BrowserChromeModel.PinnedTabFolder],
        visitedFolderIDs: Set<String>,
    ) -> Int {
        guard !visitedFolderIDs.contains(folderID) else {
            return 0
        }

        let visitedFolderIDs = visitedFolderIDs.union([folderID])
        let childFolderIDs = foldersByID.values
            .filter { $0.parentFolderID == folderID }
            .map(\.id)
        let directTabCount = pinnedTabs.count(where: { $0.pinnedFolderID == folderID })
        return directTabCount + childFolderIDs.reduce(0) { count, childFolderID in
            count + descendantTabCount(
                forFolderID: childFolderID,
                in: pinnedTabs,
                foldersByID: foldersByID,
                visitedFolderIDs: visitedFolderIDs,
            )
        }
    }
}

// MARK: - BrowserSidebarPinnedRow

enum BrowserSidebarPinnedRow: Identifiable, Equatable {
    case folder(BrowserSidebarPinnedFolderRow)
    case tab(BrowserSidebarPinnedTabRow)

    // MARK: Internal

    var id: String {
        switch self {
        case .folder(let row):
            "folder-\(row.folder.id)"
        case .tab(let row):
            "tab-\(row.tab.id)"
        }
    }
}

// MARK: - BrowserSidebarPinnedFolderRow

struct BrowserSidebarPinnedFolderRow: Equatable {
    let folder: BrowserChromeModel.PinnedTabFolder
    let childCount: Int
    let firstSectionIndex: Int
    let afterSectionIndex: Int
    var depth = 0
}

// MARK: - BrowserSidebarPinnedTabRow

struct BrowserSidebarPinnedTabRow: Equatable {
    let tab: BrowserChromeModel.Tab
    let sectionIndex: Int
    var pinnedFolderID: String?
    var folderChildIndex: Int?
    var depth = 0
}

// MARK: - BrowserSidebarPinnedTabFolderCreationSelection

struct BrowserSidebarPinnedTabFolderCreationSelection: Equatable {
    let clickedTabID: String
    let activeTabID: String?
    let selectedTabIDs: Set<String>
    let listTabIDs: Set<String>

    var tabIDs: Set<String> {
        var tabIDs = selectedTabIDs.intersection(listTabIDs)
        if let activeTabID, listTabIDs.contains(activeTabID) {
            tabIDs.insert(activeTabID)
        }
        if listTabIDs.contains(clickedTabID) {
            tabIDs.insert(clickedTabID)
        }

        return tabIDs
    }
}

// MARK: - BrowserSidebarSplitName

struct BrowserSidebarSplitName: Equatable {
    var title: String
    var systemImageName: String?
}
