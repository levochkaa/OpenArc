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
        guard canCreateTab, let tab = tabs.first(where: { $0.id == id }), let url = URL(string: tab.urlString),
              tab.placement == .app || tab.spaceID == selectedSpaceID
        else { return nil }
        openURLInNewTab(url)
        guard let newID = selectedTabID, newID != id else { return nil }
        let siblings = temporaryTabs.map(\.id).filter { $0 != newID }
        let index = tab.placement == .temporary ? siblings.firstIndex(of: id).map { $0 + 1 } ?? 0 : 0
        moveTab(withID: newID, toPlacement: .temporary, atSectionIndex: index)
        return newID
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

    /// Archive Item on a Split View row closes every pane.
    func closeSplit(containingTabID tabID: String) {
        for id in splitPaneTabIDs(forTabID: tabID) {
            closeTab(id: id)
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

    /// Moves tabs through the sidebar drop path, which keeps their order, a
    /// split's grouping, persistence and sync, to the top of their section.
    private func moveToTopOfSpace(tabIDs: Set<String>, primaryID: String, spaceID: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == primaryID }),
              spacesForMovingTab(id: primaryID).contains(where: { $0.id == spaceID })
        else { return false }
        let container: BrowserSidebarDropContainer = tab.placement == .spacePinned
            ? .pinned(spaceID)
            : .temporary(spaceID)
        let first = BrowserSidebarTabTree(snapshot: sidebarSnapshot).items(in: container).first
        return commitSidebarDrop(
            payload: .init(primary: .tab(primaryID), tabIDs: tabIDs),
            destination: .init(container: container, beforeItem: first)
        )
    }

    private func temporaryTabIDs(inSpaceOf id: String) -> [String] {
        guard let tab = tabs.first(where: { $0.id == id }), tab.placement == .temporary else { return [] }
        return tabs.filter { $0.spaceID == tab.spaceID && $0.placement == .temporary }.map(\.id)
    }
}
