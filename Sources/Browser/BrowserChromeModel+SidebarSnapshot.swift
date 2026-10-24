import AppKit

extension BrowserChromeModel {
    var sidebarSnapshot: BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
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
            splitGroups: validatedSplitGroups().map { splitPaneTabIDs(of: $0) }.filter { $0.count > 1 }
        )
    }
}
