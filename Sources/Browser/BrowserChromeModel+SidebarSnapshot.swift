import AppKit

extension BrowserChromeModel {
    var sidebarSnapshot: BrowserSidebarSnapshot {
        var snapshot = BrowserSidebarSnapshot(
            spaces: spaces,
            selectedSpaceID: selectedSpaceID,
            activeSpace: activeSpace,
            isActiveSpacePinnedSectionCollapsed: isActiveSpacePinnedSectionCollapsed,
            allTabs: tabs,
            pinnedTabFolders: pinnedTabFolders,
            appTabs: appTabs,
            spacePinnedTabs: spacePinnedTabs,
            temporaryTabs: temporaryTabs,
            selectedTabID: selectedTabID,
            archivableTabIDs: Set((spacePinnedTabs + temporaryTabs).dropLast().map(\.id)),
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canStopLoading: canStopLoading,
            canReload: canReload,
            splitGroups: validatedSplitGroups().map { splitPaneTabIDs(of: $0) }.filter { $0.count > 1 },
            mutedTabIDs: Set(tabs.filter { mutedTabSyncIDs.contains($0.syncID) }.map(\.id))
        )
        snapshot.tabIcons = Dictionary(
            tabs.compactMap { tab in tabIconsBySyncID[tab.syncID].map { (tab.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        snapshot.splitNames = Dictionary(
            validatedSplitGroups().compactMap { group in
                group.title.map { (
                    splitPaneTabIDs(of: group),
                    BrowserSidebarSplitName(title: $0, systemImageName: group.systemImageName)
                ) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return snapshot
    }
}

extension BrowserChromeModel {
    /// View menu and command bar title that moves the sidebar to the other window edge.
    var sidebarPositionToggleTitle: String {
        userPreferencesStore.sidebarPosition == .left
            ? BrowserStrings.menuMoveSidebarRight
            : BrowserStrings.menuMoveSidebarLeft
    }
}
