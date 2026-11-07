// BrowserChromeModel+TabActions.swift

import Foundation

// MARK: - Tab row actions

/// Tab menu actions beyond Close: Duplicate, Move to another Space and
/// archiving the other temporary tabs or those above. The temporary-only
/// actions never touch pinned tabs or app tiles.
extension BrowserChromeModel {
    /// A new temporary tab with the same page, right below a temporary
    /// original or at the top of the temporary tabs. Only tabs of the selected
    /// Space and app tiles can be duplicated, since new tabs open there.
    @discardableResult func duplicateTab(id: String) -> String? {
        guard canDuplicateTab(id: id), let tab = tabs.first(where: { $0.id == id }),
              let url = URL(string: tab.urlString)
        else { return nil }
        openURLInNewTab(url)
        guard let newID = selectedTabID, newID != id else { return nil }
        let siblings = temporaryTabs.map(\.id).filter { $0 != newID }
        let index = tab.placement == .temporary ? siblings.firstIndex(of: id).map { $0 + 1 } ?? 0 : 0
        moveTab(withID: newID, toPlacement: .temporary, atSectionIndex: index)
        return newID
    }

    /// Tabs dropped outside every window open in a new window of their own,
    /// outside the Spaces. Temporary tabs move there with their live pages;
    /// pinned tabs and Favorites stay and their pages are copied, loading anew.
    /// Incognito tabs never leave their window.
    @discardableResult func moveTabsToNewWindow(ids: Set<String>, at screenPoint: CGPoint) -> Bool {
        guard windowMode != .incognito, let onMoveTabsToNewWindow else { return false }
        let moving = tabs.filter { ids.contains($0.id) && URL(string: $0.urlString) != nil }
        guard !moving.isEmpty else { return false }
        let urls = moving.compactMap { URL(string: $0.urlString) }
        // Today tabs take their live pages along; the others' pages load there anew.
        let pages = moving.map { tab in
            tab.placement == .temporary
                ? removeTabKeepingPage(id: tab.id, undoActionName: BrowserStrings.tabMoveToNewWindowAction)
                : nil
        }
        onMoveTabsToNewWindow(urls, pages, screenPoint)
        for (tab, page) in zip(moving, pages) where tab.placement == .temporary && page == nil {
            closeTab(id: tab.id, forceClose: true, undoActionName: BrowserStrings.tabMoveToNewWindowAction)
        }
        return true
    }

    /// Tabs dropped on another window. A window of the same profile lists the
    /// same tabs, so it shows the first of them. Any other window takes the
    /// pages as new tabs, the first one selected, and temporary tabs leave
    /// this one. Incognito windows neither give nor take tabs.
    @discardableResult func moveTabs(ids: Set<String>, toWindowOf target: BrowserChromeModel) -> Bool {
        guard target !== self, windowMode != .incognito, target.windowMode != .incognito else { return false }
        let moving = tabs.filter { ids.contains($0.id) && URL(string: $0.urlString) != nil }
        guard let first = moving.first else { return false }
        if let windowGroup, target.windowGroup === windowGroup {
            target.selectTab(syncID: first.syncID)
            return true
        }
        let opened = moving.compactMap { tab in
            URL(string: tab.urlString).flatMap { target.openURLInBackgroundTab($0) }
        }
        guard let selected = opened.first else { return false }
        target.selectTab(id: selected)
        for tab in moving where tab.placement == .temporary {
            closeTab(id: tab.id, forceClose: true, undoActionName: BrowserStrings.tabMoveToNewWindowAction)
        }
        return true
    }

    /// Command-click on the icon of a pinned tab away from its page: the
    /// page moves to the top of the temporary tabs and the pinned tab goes back
    /// to its pinned page, staying selected. The moved page loads anew.
    @discardableResult func separateFromPinnedTab(id: String) -> String? {
        guard canCreateTab, let tab = tabs.first(where: { $0.id == id }), tab.canResetToPinnedURL,
              tab.spaceID == selectedSpaceID, let url = URL(string: tab.urlString)
        else { return nil }
        openURLInNewTab(url)
        guard let newID = selectedTabID, newID != id else { return nil }
        moveTab(withID: newID, toPlacement: .temporary, atSectionIndex: 0)
        guard resetPinnedTabToPinnedURL(id: id) else { return nil }
        return newID
    }

    private var selectedTabValue: Tab? { selectedTabID.flatMap { id in tabs.first { $0.id == id } } }

    /// Pin/Unpin Tab for the selected tab of the selected Space.
    var canTogglePinSelectedTab: Bool {
        guard let tab = selectedTabValue else { return false }
        return tab.placement != .app && tab.spaceID == selectedSpaceID
    }

    var pinToggleTitle: String {
        selectedTabValue?.placement == .spacePinned ? BrowserStrings.menuUnpinTab : BrowserStrings.menuPinTab
    }

    @discardableResult func togglePinSelectedTab() -> Bool {
        guard canTogglePinSelectedTab, let selectedTabID else { return false }
        togglePinned(forTabID: selectedTabID)
        return true
    }

    func canDuplicateTab(id: String) -> Bool {
        guard canCreateTab, let tab = tabs.first(where: { $0.id == id }), URL(string: tab.urlString) != nil else {
            return false
        }
        return tab.placement == .app || tab.spaceID == selectedSpaceID
    }

    @discardableResult func duplicateSelectedTab() -> Bool {
        selectedTabID.flatMap { duplicateTab(id: $0) } != nil
    }

    /// Rename Tab edits the selected row in place; app tiles and split panes
    /// have no title field there.
    var canRenameSelectedTab: Bool {
        guard let tab = selectedTabValue, tab.placement != .app else { return false }
        return splitGroup(containingTabID: tab.id) == nil
    }

    @discardableResult func renameSelectedTab() -> Bool {
        guard canRenameSelectedTab else { return false }
        revealSelectedTabInSidebar()
        sidebarRenameRequestID &+= 1
        return true
    }

    var canResetSelectedTabToPinnedURL: Bool { selectedTabValue?.canResetToPinnedURL == true }

    @discardableResult func resetSelectedTabToPinnedURL() -> Bool {
        guard canResetSelectedTabToPinnedURL, let selectedTabID else { return false }
        return resetPinnedTabToPinnedURL(id: selectedTabID)
    }

    /// New Folder puts the selected tab of the selected Space into a new
    /// pinned folder; split panes keep their split instead.
    var canCreateFolder: Bool { supportsSpaces && selectedSpaceID != nil }

    /// New Folder: empty, after the Space's pinned rows, with its name ready to type over.
    @discardableResult func createFolderInSelectedSpace() -> String? {
        guard canCreateFolder, let selectedSpaceID,
              let folderID = createEmptyPinnedFolder(
                  title: BrowserStrings.pinnedTabFolderDefaultTitle,
                  inSpaceID: selectedSpaceID,
              )
        else { return nil }
        movePinnedTabFolder(withID: folderID, toRootSectionIndex: .max, targetSpaceID: selectedSpaceID)
        folderToRename = folderID
        return folderID
    }

    /// Collapse/Expand All Folders for the selected Space.
    func canSetActiveSpaceFoldersExpanded(_ expanded: Bool) -> Bool {
        pinnedTabFolders.contains { $0.spaceID == selectedSpaceID && $0.isExpanded != expanded }
    }

    @discardableResult func setActiveSpaceFoldersExpanded(_ expanded: Bool) -> Bool {
        let ids = pinnedTabFolders.filter { $0.spaceID == selectedSpaceID && $0.isExpanded != expanded }.map(\.id)
        for id in ids {
            togglePinnedTabFolderExpanded(id: id)
        }
        return !ids.isEmpty
    }

    /// Restore Last Closed Tab: Undo, when the latest undoable action is
    /// closing a tab, so the restore keeps Undo's fresh sync identity.
    /// The latest closed tab, or a closed Peek card or small window.
    var canRestoreLastClosedTab: Bool {
        undoManager.canUndo
            && [BrowserStrings.tabArchiveAction, BrowserStrings.peekCloseAction].contains(undoManager.undoTabActionName)
    }

    @discardableResult func restoreLastClosedTab() -> Bool {
        guard canRestoreLastClosedTab else { return false }
        undoManager.undo()
        return true
    }

    func isTabMuted(id: String) -> Bool {
        tabs.first { $0.id == id }.map { mutedTabSyncIDs.contains($0.syncID) } ?? false
    }

    /// Spaces a tab can move to with Move to.
    func spacesForMovingTab(id: String) -> [Space] {
        guard supportsSpaces, let tab = tabs.first(where: { $0.id == id }), tab.placement != .app else { return [] }
        return spaces.filter { $0.id != tab.spaceID }
    }

    /// Move to: the tab goes to the top of the same section in another Space.
    @discardableResult func moveTabToSpace(id: String, spaceID: String) -> Bool {
        moveToTopOfSpace(tabIDs: [id], primaryID: id, spaceID: spaceID)
    }

    /// Move to on a Split View row: every pane moves together, so the
    /// split stays whole in the other Space.
    @discardableResult func moveSplitToSpace(containingTabID tabID: String, spaceID: String) -> Bool {
        let panes = splitPaneTabIDs(forTabID: tabID)
        guard panes.count > 1 else { return false }
        return moveToTopOfSpace(tabIDs: Set(panes), primaryID: tabID, spaceID: spaceID)
    }

    /// Archive Item on a Split View row: temporary panes archive, pinned
    /// panes unload and keep their rows, like Close Tab on each.
    func closeSplit(containingTabID tabID: String) {
        for id in splitPaneTabIDs(forTabID: tabID) {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            if tab.placement == .spacePinned {
                closePinnedTabProcessOrReset(id: id)
            } else {
                closeTab(id: id)
            }
        }
    }

    /// Temporary tabs of the row's Space above it; its own split counts as itself.
    func temporaryTabIDsAbove(id: String) -> [String] {
        let ids = temporaryTabIDs(inSpaceOf: id)
        guard let index = ids.firstIndex(of: id) else { return [] }
        let own = Set(splitPaneTabIDs(forTabID: id))
        return ids[..<index].filter { !own.contains($0) }
    }

    /// Every other temporary tab of the row's Space, keeping its own split.
    func otherTemporaryTabIDs(id: String) -> [String] {
        let own = Set(splitPaneTabIDs(forTabID: id))
        return temporaryTabIDs(inSpaceOf: id).filter { !own.contains($0) }
    }

    func closeTemporaryTabsAbove(id: String) {
        for tabID in temporaryTabIDsAbove(id: id) {
            closeTab(id: tabID)
        }
    }

    func closeOtherTemporaryTabs(id: String) {
        for tabID in otherTemporaryTabIDs(id: id) {
            closeTab(id: tabID)
        }
    }

    /// Drop on a Space's dock icon, like Move to: dragged tabs or a
    /// pinned folder go to the top of the same section in that Space. Favorites
    /// belong to no Space, and items already in it stay where they are.
    @discardableResult func moveSidebarItems(
        _ payload: BrowserSidebarDragPayload,
        toTopOfSpace spaceID: String,
    ) -> Bool {
        guard supportsSpaces, spaces.contains(where: { $0.id == spaceID }) else { return false }
        let container: BrowserSidebarDropContainer
        switch payload.primary {
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.id == id }), tab.placement != .app, tab.spaceID != spaceID
            else { return false }
            container = tab.placement == .spacePinned ? .pinned(spaceID) : .temporary(spaceID)
        case .folder(let id):
            guard let folder = pinnedTabFolders.first(where: { $0.id == id }), folder.spaceID != spaceID
            else { return false }
            container = .pinned(spaceID)
        }
        let first = BrowserSidebarTabTree(snapshot: sidebarSnapshot).items(in: container).first
        return commitSidebarDrop(payload: payload, destination: .init(container: container, beforeItem: first))
    }

    /// Moves tabs through the sidebar drop path, which keeps their order, a
    /// split's grouping, persistence and sync, to the top of their section.
    private func moveToTopOfSpace(tabIDs: Set<String>, primaryID: String, spaceID: String) -> Bool {
        moveSidebarItems(.init(primary: .tab(primaryID), tabIDs: tabIDs), toTopOfSpace: spaceID)
    }

    private func temporaryTabIDs(inSpaceOf id: String) -> [String] {
        guard let tab = tabs.first(where: { $0.id == id }), tab.placement == .temporary else { return [] }
        return tabs.filter { $0.spaceID == tab.spaceID && $0.placement == .temporary }.map(\.id)
    }
}
