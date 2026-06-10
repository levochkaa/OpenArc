import AppKit
import QuartzCore
import SwiftUI

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

    var selectedTab: BrowserChromeModel.Tab? {
        guard let selectedTabID else {
            return nil
        }

        return tab(withID: selectedTabID)
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
        revealedTabIDByFolderID: [String: String] = [:]
    ) -> [BrowserSidebarPinnedRow] {
        let pinnedTabs = spacePinnedTabs(in: spaceID)
        let foldersByID = Dictionary(uniqueKeysWithValues: pinnedTabFolders(in: spaceID).map { ($0.id, $0) })
        let selectedTab = selectedTab
        var seenFolderIDs = Set<String>()
        var rows = [BrowserSidebarPinnedRow]()

        func appendRows(parentFolderID: String?, depth: Int) {
            for (sectionIndex, tab) in pinnedTabs.enumerated() {
                if let tabFolderID = tab.pinnedFolderID {
                    guard let folder = foldersByID[tabFolderID],
                          folder.parentFolderID == parentFolderID
                    else {
                        if tabFolderID == parentFolderID {
                            appendTab(tab, sectionIndex: sectionIndex, folderID: parentFolderID, depth: depth)
                        }
                        continue
                    }

                    appendFolder(
                        folder,
                        firstSectionIndex: sectionIndex,
                        depth: depth
                    )
                    continue
                }

                if parentFolderID == nil {
                    appendTab(tab, sectionIndex: sectionIndex, folderID: nil, depth: depth)
                }
            }
        }

        func appendFolder(
            _ folder: BrowserChromeModel.PinnedTabFolder,
            firstSectionIndex: Int,
            depth: Int
        ) {
            guard !seenFolderIDs.contains(folder.id) else {
                return
            }

            seenFolderIDs.insert(folder.id)
            let childTabs = pinnedTabs.filter { $0.pinnedFolderID == folder.id }
            let descendantTabCount = descendantTabCount(
                forFolderID: folder.id,
                in: pinnedTabs,
                foldersByID: foldersByID
            )
            rows.append(
                .folder(
                    BrowserSidebarPinnedFolderRow(
                        folder: folder,
                        childCount: childTabs.count,
                        firstSectionIndex: firstSectionIndex,
                        afterSectionIndex: firstSectionIndex + descendantTabCount,
                        depth: depth
                    )
                )
            )

            if folder.isExpanded {
                appendRows(parentFolderID: folder.id, depth: depth + 1)
            } else if let visibleChildTab = collapsedVisibleChildTab(for: folder, childTabs: childTabs) {
                let childSectionIndex = pinnedTabs.firstIndex { $0.id == visibleChildTab.id } ?? firstSectionIndex
                let childIndex = childTabs.firstIndex { $0.id == visibleChildTab.id } ?? 0
                appendTab(
                    visibleChildTab,
                    sectionIndex: childSectionIndex,
                    folderID: folder.id,
                    folderChildIndex: childIndex,
                    depth: depth + 1
                )
            }
        }

        func appendTab(
            _ tab: BrowserChromeModel.Tab,
            sectionIndex: Int,
            folderID: String?,
            folderChildIndex: Int? = nil,
            depth: Int
        ) {
            rows.append(
                .tab(
                    BrowserSidebarPinnedTabRow(
                        tab: tab,
                        sectionIndex: sectionIndex,
                        pinnedFolderID: folderID,
                        folderChildIndex: folderChildIndex,
                        depth: depth
                    )
                )
            )
        }

        func collapsedVisibleChildTab(
            for folder: BrowserChromeModel.PinnedTabFolder,
            childTabs: [BrowserChromeModel.Tab]
        ) -> BrowserChromeModel.Tab? {
            if selectedTab?.pinnedFolderID == folder.id {
                return childTabs.first { $0.id == selectedTab?.id }
            }

            if let revealedTabID = revealedTabIDByFolderID[folder.id] {
                return childTabs.first { $0.id == revealedTabID }
            }

            return nil
        }

        appendRows(parentFolderID: nil, depth: 0)
        return rows
    }

    func replacingTabs(_ tabs: [BrowserChromeModel.Tab]) -> BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            spaces: spaces,
            selectedSpaceID: selectedSpaceID,
            activeSpace: activeSpace,
            isActiveSpacePinnedSectionCollapsed: isActiveSpacePinnedSectionCollapsed,
            allTabs: tabs,
            pinnedTabFolders: pinnedTabFolders,
            appTabs: tabs.filter { $0.placement == .app },
            spacePinnedTabs: tabs.filter { $0.spaceID == selectedSpaceID && $0.placement == .spacePinned },
            temporaryTabs: tabs.filter { $0.spaceID == selectedSpaceID && $0.placement == .temporary },
            selectedTabID: selectedTabID,
            archivableTabIDs: archivableTabIDs,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canStopLoading: canStopLoading,
            canReload: canReload
        )
    }

    // MARK: Private

    private func descendantTabCount(
        forFolderID folderID: String,
        in pinnedTabs: [BrowserChromeModel.Tab],
        foldersByID: [String: BrowserChromeModel.PinnedTabFolder]
    ) -> Int {
        descendantTabCount(
            forFolderID: folderID,
            in: pinnedTabs,
            foldersByID: foldersByID,
            visitedFolderIDs: []
        )
    }

    private func descendantTabCount(
        forFolderID folderID: String,
        in pinnedTabs: [BrowserChromeModel.Tab],
        foldersByID: [String: BrowserChromeModel.PinnedTabFolder],
        visitedFolderIDs: Set<String>
    ) -> Int {
        guard !visitedFolderIDs.contains(folderID) else {
            return 0
        }

        let visitedFolderIDs = visitedFolderIDs.union([folderID])
        let childFolderIDs = foldersByID.values
            .filter { $0.parentFolderID == folderID }
            .map(\.id)
        let directTabCount = pinnedTabs.filter { $0.pinnedFolderID == folderID }.count
        return directTabCount + childFolderIDs.reduce(0) { count, childFolderID in
            count + descendantTabCount(
                forFolderID: childFolderID,
                in: pinnedTabs,
                foldersByID: foldersByID,
                visitedFolderIDs: visitedFolderIDs
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
