import Foundation

// MARK: - Sidebar items

/// Keyboard navigation over the sidebar: Go to Sidebar Item 1–8, Go to
/// last Sidebar Item and Next/Previous Tab. Favorites count first
/// (Settings can exclude them; TheBrowser has no such option), then the rows of
/// the current Space.
extension BrowserChromeModel {
    /// Tabs in the order the sidebar shows them: app tiles, the visible pinned
    /// rows, then temporary tabs. A Split View is one item, as it is one row.
    var sidebarItemTabIDs: [String] {
        let snapshot = sidebarSnapshot
        var pinnedIDs = [String]()
        if let spaceID = activeSpace?.id, !(supportsSpaces && snapshot.isPinnedSectionCollapsed(in: spaceID)) {
            pinnedIDs = snapshot.visiblePinnedRows(in: spaceID).compactMap { row in
                if case .tab(let tabRow) = row {
                    tabRow.tab.id
                } else {
                    nil
                }
            }
        }
        var shownSplits = Set<[String]>()
        return (appTabs.map(\.id) + pinnedIDs + temporaryTabs.map(\.id)).filter { id in
            guard let members = snapshot.splitMembers(ofTabID: id) else { return true }
            return shownSplits.insert(members).inserted
        }
    }

    /// Go to Sidebar Item N, counted from 0.
    @discardableResult func selectSidebarItem(at index: Int) -> Bool {
        let ids = sidebarItemTabIDs
        guard ids.indices.contains(index) else { return false }
        return selectSidebarItem(tabID: ids[index])
    }

    /// Go to last Sidebar Item.
    @discardableResult func selectLastSidebarItem() -> Bool {
        guard let id = sidebarItemTabIDs.last else { return false }
        return selectSidebarItem(tabID: id)
    }

    /// Next/Previous Tab: moves one sidebar item and wraps around. Without
    /// a selected item it starts at the first or last one.
    @discardableResult func selectAdjacentSidebarItem(offset: Int) -> Bool {
        let ids = sidebarItemTabIDs
        guard !ids.isEmpty else { return false }
        let current = selectedTabID.flatMap { selected in
            ids.firstIndex { splitPaneTabIDs(forTabID: $0).contains(selected) }
        }
        let index = current.map { ($0 + offset % ids.count + ids.count) % ids.count } ?? (offset > 0 ? 0 : ids.count - 1)
        return selectSidebarItem(tabID: ids[index])
    }

    /// A split item returns to its last focused pane, like a click on its row.
    /// Returns true when the item exists, even if it is already selected.
    private func selectSidebarItem(tabID: String) -> Bool {
        let panes = splitPaneTabIDs(forTabID: tabID)
        if let selectedTabID, panes.contains(selectedTabID) {
            return true
        }
        let focused = splitGroup(containingTabID: tabID)?.focusedTabSyncID.flatMap { syncID in
            tabs.first { $0.syncID == syncID }?.id
        }
        selectTab(id: focused.flatMap { panes.contains($0) ? $0 : nil } ?? tabID)
        return true
    }

    /// View menu and command bar title for the site toolbar toggle.
    var siteToolbarToggleTitle: String {
        userPreferencesStore.siteURLToolbarEnabled ? BrowserStrings.menuHideToolbar : BrowserStrings.menuShowToolbar
    }
}
