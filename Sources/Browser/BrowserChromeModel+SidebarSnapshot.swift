// BrowserChromeModel+SidebarSnapshot.swift

import AppKit

extension BrowserChromeModel {
    var sidebarSnapshot: BrowserSidebarSnapshot { makeSidebarSnapshot(leaving: []) }

    /// What the sidebar shows: without the rows of tabs on their way out.
    var presentedSidebarSnapshot: BrowserSidebarSnapshot { makeSidebarSnapshot(leaving: tabsLeavingSidebar) }

    private func makeSidebarSnapshot(leaving: Set<String>) -> BrowserSidebarSnapshot {
        var snapshot = BrowserSidebarSnapshot(
            spaces: spaces,
            selectedSpaceID: selectedSpaceID,
            activeSpace: activeSpace,
            isActiveSpacePinnedSectionCollapsed: isActiveSpacePinnedSectionCollapsed,
            allTabs: leaving.isEmpty ? tabs : tabs.filter { !leaving.contains($0.id) },
            pinnedTabFolders: pinnedTabFolders,
            appTabs: appTabs,
            spacePinnedTabs: spacePinnedTabs,
            temporaryTabs: leaving.isEmpty ? temporaryTabs : temporaryTabs.filter { !leaving.contains($0.id) },
            selectedTabID: leaving.isEmpty ? selectedTabID : sidebarSelectedTabID,
            archivableTabIDs: Set((spacePinnedTabs + temporaryTabs).dropLast().map(\.id)),
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canStopLoading: canStopLoading,
            canReload: canReload,
            splitGroups: validatedSplitGroups().map { splitPaneTabIDs(of: $0) }.filter { $0.count > 1 },
            mutedTabIDs: Set(tabs.filter { mutedTabSyncIDs.contains($0.syncID) }.map(\.id)),
        )
        snapshot.audibleTabIDs = audibleTabIDs
        snapshot.recordingTabIDs = recordingTabIDs
        snapshot.peekPagesByTabID = peekPagesByTabID.filter { id, _ in tabs.contains { $0.id == id } }
        snapshot.miniPlayers = miniPlayerItems
        snapshot.tabIcons = Dictionary(
            tabs.compactMap { tab in tabIconsBySyncID[tab.syncID].map { (tab.id, $0) } },
            uniquingKeysWith: { first, _ in first },
        )
        snapshot.splitNames = Dictionary(
            validatedSplitGroups().compactMap { group in
                group.title.map { (
                    splitPaneTabIDs(of: group),
                    BrowserSidebarSplitName(title: $0, systemImageName: group.systemImageName),
                ) }
            },
            uniquingKeysWith: { first, _ in first },
        )
        return snapshot
    }
}

extension BrowserChromeModel {
    /// View menu and command bar title that moves the sidebar to the other window edge.
    var sidebarPositionToggleTitle: String {
        if userPreferencesStore.sidebarPosition == .left {
            BrowserStrings.menuMoveSidebarRight
        } else {
            BrowserStrings.menuMoveSidebarLeft
        }
    }
}
