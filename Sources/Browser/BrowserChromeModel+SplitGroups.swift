import Foundation

// MARK: - Split View

/// Split View. A group is a local sidebar item whose members
/// keep their own rows in the shared tab tree, so order, drag and sync use the
/// existing paths. Members share one Space, section and folder; the group is
/// shown at its first member. Selecting a member focuses its pane. Closing or
/// moving a member elsewhere removes it, and a group left with one member
/// dissolves. Favorites cannot join a split.
extension BrowserChromeModel {
    static let maximumSplitPaneCount = BrowserTabSplitGroupSessionSnapshot.maximumTabCount

    var selectedSplitGroup: SplitGroup? {
        selectedTabID.flatMap { splitGroup(containingTabID: $0) }
    }

    /// The validated group that contains a runtime tab ID.
    func splitGroup(containingTabID tabID: String) -> SplitGroup? {
        guard !splitGroups.isEmpty, let syncID = tabs.first(where: { $0.id == tabID })?.syncID else { return nil }
        return validatedSplitGroups().first { $0.tabSyncIDs.contains(syncID) }
    }

    /// Runtime IDs of a group's panes in pane order.
    func splitPaneTabIDs(of group: SplitGroup) -> [String] {
        let runtimeIDs = Dictionary(tabs.map { ($0.syncID, $0.id) }, uniquingKeysWith: { first, _ in first })
        return group.tabSyncIDs.compactMap { runtimeIDs[$0] }
    }

    /// Every pane shown together with a tab, or the tab alone outside a split.
    func splitPaneTabIDs(forTabID tabID: String) -> [String] {
        splitGroup(containingTabID: tabID).map { splitPaneTabIDs(of: $0) } ?? [tabID]
    }

    /// Applies the membership rules to the raw groups without mutating them.
    func validatedSplitGroups() -> [SplitGroup] {
        guard !splitGroups.isEmpty else { return [] }
        let tabsBySyncID = Dictionary(tabs.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var groupIDs = Set<String>()
        var result = [SplitGroup]()
        for group in splitGroups where groupIDs.insert(group.id).inserted {
            var seen = Set<String>()
            let candidates = group.tabSyncIDs.filter { id in
                guard !claimed.contains(id), seen.insert(id).inserted, let tab = tabsBySyncID[id] else { return false }
                return tab.placement != .app
            }
            let preferred = group.focusedTabSyncID.flatMap { tabsBySyncID[$0] }.map(SplitContainerKey.init)
            guard let key = Self.dominantSplitKey(
                candidates.compactMap { tabsBySyncID[$0].map(SplitContainerKey.init) },
                preferring: preferred
            ) else { continue }
            let members = Array(
                candidates.filter { tabsBySyncID[$0].map(SplitContainerKey.init) == key }
                    .prefix(Self.maximumSplitPaneCount)
            )
            guard members.count >= 2 else { continue }
            claimed.formUnion(members)
            var valid = group
            if members != group.tabSyncIDs {
                valid.tabSyncIDs = members
                valid.fractions = nil
            }
            valid.fractions = BrowserTabSplitGroupSessionSnapshot.validFractions(valid.fractions, count: members.count)
            if let focused = valid.focusedTabSyncID, !members.contains(focused) {
                valid.focusedTabSyncID = nil
            }
            result.append(valid)
        }
        return result
    }

    func pruneSplitGroupsIfNeeded() {
        let valid = validatedSplitGroups()
        if valid != splitGroups {
            splitGroups = valid
        }
    }

    func splitGroupSessionSnapshots() -> [BrowserTabSplitGroupSessionSnapshot] {
        validatedSplitGroups().map { group in
            BrowserTabSplitGroupSessionSnapshot(
                id: group.id,
                tabIDs: group.tabSyncIDs,
                orientation: group.orientation,
                fractions: group.fractions,
                focusedTabID: group.focusedTabSyncID
            )
        }
    }

    func restoredSplitGroups(from snapshot: BrowserTabSessionSnapshot) -> [SplitGroup] {
        (snapshot.splitGroups ?? []).map { group in
            SplitGroup(
                id: group.id,
                tabSyncIDs: group.tabIDs,
                orientation: group.orientation,
                fractions: group.fractions,
                focusedTabSyncID: group.focusedTabID
            )
        }
    }

    /// Remembers the focused pane so returning to the split restores it.
    func recordSplitFocus(tabID: String?) {
        guard !splitGroups.isEmpty, let tabID,
              let syncID = tabs.first(where: { $0.id == tabID })?.syncID,
              let index = splitGroups.firstIndex(where: { $0.tabSyncIDs.contains(syncID) }),
              splitGroups[index].focusedTabSyncID != syncID
        else { return }
        splitGroups[index].focusedTabSyncID = syncID
    }

    /// The window shows every pane of the selected tab's split, or only the
    /// selected tab. Identical layouts are not resent to the engine.
    func syncSplitLayout() {
        let layout = selectedSplitGroup.map { group in
            BrowserTabVisibleLayout(
                tabIDs: splitPaneTabIDs(of: group),
                orientation: group.orientation,
                fractions: group.fractions
            )
        }
        guard layout != appliedSplitLayout else { return }
        appliedSplitLayout = layout
        sendVisibleTabLayout(layout)
    }

    /// A click in another visible pane focuses that pane's tab.
    func handleSplitPaneFocused(_ tabID: String) {
        guard tabID != selectedTabID,
              let group = selectedSplitGroup,
              splitPaneTabIDs(of: group).contains(tabID)
        else { return }
        selectTab(id: tabID)
    }

    /// "Open in Split View": the anchor (by default the selected tab)
    /// keeps its pane and sidebar position, `tabID` becomes the next pane and is
    /// focused. Its own row joins the group, moving into the anchor's Space,
    /// section and folder.
    @discardableResult func openInSplitView(tabID: String, anchorTabID: String? = nil) -> Bool {
        guard let anchorID = anchorTabID ?? selectedTabID, anchorID != tabID,
              let anchor = tabs.first(where: { $0.id == anchorID }), anchor.placement != .app,
              let added = tabs.first(where: { $0.id == tabID }), added.placement != .app
        else { return false }
        let existing = splitGroup(containingTabID: anchorID)
        let paneIDs = existing.map { splitPaneTabIDs(of: $0) } ?? [anchorID]
        guard !paneIDs.contains(tabID), paneIDs.count < Self.maximumSplitPaneCount,
              let lastPaneID = paneIDs.last
        else { return false }
        removeFromSplitGroups(syncID: added.syncID)
        guard placeTab(tabID, after: lastPaneID) else { return false }
        if let existing, let index = splitGroups.firstIndex(where: { $0.id == existing.id }) {
            splitGroups[index].tabSyncIDs = existing.tabSyncIDs + [added.syncID]
            splitGroups[index].fractions = nil
            splitGroups[index].focusedTabSyncID = added.syncID
        } else {
            splitGroups.append(SplitGroup(
                id: UUID().uuidString,
                tabSyncIDs: [anchor.syncID, added.syncID],
                focusedTabSyncID: added.syncID
            ))
        }
        let wasSelected = selectedTabID == tabID
        selectTab(id: tabID)
        if wasSelected || selectedTabID != tabID {
            persistSplitGroupChange()
        }
        return true
    }

    /// "Add Split View": the selected tab, or the selected split, can take
    /// another pane.
    var canAddSplitView: Bool {
        guard canCreateTab, let selectedTabID,
              let selected = tabs.first(where: { $0.id == selectedTabID }), selected.placement != .app
        else { return false }
        return splitPaneTabIDs(forTabID: selectedTabID).count < Self.maximumSplitPaneCount
    }

    /// Opens the command bar; the page or tab chosen there becomes a new pane
    /// after the selected split's last pane.
    func presentSplitViewCommandBar() {
        guard canAddSplitView, let selectedTabID else { return }
        presentCommandBar()
        pendingSplitAnchorTabID = commandBarModel.isPresented ? selectedTabID : nil
    }

    /// Consumes the split anchor left by `presentSplitViewCommandBar()`.
    func takePendingSplitAnchorTabID() -> String? {
        defer { pendingSplitAnchorTabID = nil }
        guard let anchorID = pendingSplitAnchorTabID, tabs.contains(where: { $0.id == anchorID }) else { return nil }
        return anchorID
    }

    /// "Close this Split Pane": the focused pane leaves the split, the
    /// next pane (or the previous one at the end) takes focus, and the pane's
    /// tab closes like Close Tab: a temporary tab archives, a pinned tab with a
    /// pinned URL unloads and keeps its row.
    @discardableResult func closeFocusedSplitPane() -> Bool {
        guard !isShuttingDown, let closingID = selectedTabID, let group = selectedSplitGroup,
              let closing = tabs.first(where: { $0.id == closingID })
        else { return false }
        let panes = splitPaneTabIDs(of: group)
        guard let index = panes.firstIndex(of: closingID) else { return false }
        let siblingID = panes.indices.contains(index + 1) ? panes[index + 1] : panes[index - 1]
        removeFromSplitGroups(syncID: closing.syncID)
        selectTab(id: siblingID)
        persistSplitGroupChange()
        // Without a pinned URL this declines, and the pinned row is removed
        // like Close Tab does.
        if closing.placement == .spacePinned, closePinnedTabProcessOrReset(id: closingID) {
            return true
        }
        return closeTab(id: closingID)
    }

    @discardableResult func separateSelectedTabFromSplit() -> Bool {
        guard let selectedTabID else { return false }
        return separateTabFromSplit(tabID: selectedTabID)
    }

    @discardableResult func separateSelectedSplitGroup() -> Bool {
        guard let group = selectedSplitGroup else { return false }
        return separateSplitGroup(id: group.id)
    }

    /// Convert title for the selected split; outside a split, the
    /// horizontal default converts to vertical.
    var splitOrientationToggleTitle: String {
        selectedSplitGroup?.orientation == .vertical
            ? BrowserStrings.splitConvertToHorizontalAction
            : BrowserStrings.splitConvertToVerticalAction
    }

    /// Converts the selected split between side by side and stacked panes.
    @discardableResult func toggleSelectedSplitOrientation() -> Bool {
        guard let group = selectedSplitGroup else { return false }
        return setSplitOrientation(group.orientation == .horizontal ? .vertical : .horizontal, groupID: group.id)
    }

    /// The pane that takes focus when `closingTab` leaves its split: the next
    /// pane, else the previous one. Nil outside a split.
    func splitSiblingTabID(afterClosing closingTab: Tab, excluding excludedTabIDs: Set<String>) -> String? {
        guard let group = splitGroups.first(where: { $0.tabSyncIDs.contains(closingTab.syncID) }),
              let index = group.tabSyncIDs.firstIndex(of: closingTab.syncID)
        else { return nil }
        let tabsBySyncID = Dictionary(tabs.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = group.tabSyncIDs[(index + 1)...] + group.tabSyncIDs[..<index].reversed()
        return candidates.lazy
            .compactMap { tabsBySyncID[$0] }
            .first { $0.id != closingTab.id && $0.spaceID == closingTab.spaceID && !excludedTabIDs.contains($0.id) }?
            .id
    }

    /// "Separate All Tabs": members stay in pane order at the group's
    /// position and the focused tab stays selected.
    @discardableResult func separateSplitGroup(id: String) -> Bool {
        guard splitGroups.contains(where: { $0.id == id }) else { return false }
        splitGroups.removeAll { $0.id == id }
        persistSplitGroupChange()
        return true
    }

    /// "Separate Tab from Split": the tab leaves the group and its row
    /// follows the remaining panes, so the group keeps its sidebar position.
    @discardableResult func separateTabFromSplit(tabID: String) -> Bool {
        guard let group = splitGroup(containingTabID: tabID),
              let syncID = tabs.first(where: { $0.id == tabID })?.syncID
        else { return false }
        let remaining = splitPaneTabIDs(of: group).filter { $0 != tabID }
        removeFromSplitGroups(syncID: syncID)
        if let last = remaining.last {
            _ = placeTab(tabID, after: last)
        }
        persistSplitGroupChange()
        return true
    }

    @discardableResult func setSplitOrientation(_ orientation: BrowserTabSplitOrientation, groupID: String) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.id == groupID }),
              splitGroups[index].orientation != orientation
        else { return false }
        splitGroups[index].orientation = orientation
        persistSplitGroupChange()
        return true
    }

    /// Commit pane sizes once, for example when a divider drag ends.
    @discardableResult func setSplitFractions(_ fractions: [Double], groupID: String) -> Bool {
        guard let group = validatedSplitGroups().first(where: { $0.id == groupID }),
              let valid = BrowserTabSplitGroupSessionSnapshot.validFractions(fractions, count: group.tabSyncIDs.count),
              valid != group.fractions,
              let index = splitGroups.firstIndex(where: { $0.id == groupID })
        else { return false }
        splitGroups[index].tabSyncIDs = group.tabSyncIDs
        splitGroups[index].fractions = valid
        persistSplitGroupChange()
        return true
    }

    // MARK: Private

    private struct SplitContainerKey: Hashable {
        // MARK: Lifecycle

        init(_ tab: Tab) {
            self.spaceID = tab.spaceID
            self.placement = tab.placement
            self.folderID = tab.pinnedFolderID
        }

        // MARK: Internal

        let spaceID: String
        let placement: BrowserTabPlacement
        let folderID: String?
    }

    /// The container holding most members keeps the group; ties prefer the
    /// focused member's container, then the earliest member's.
    private static func dominantSplitKey(
        _ keys: [SplitContainerKey],
        preferring preferred: SplitContainerKey?
    ) -> SplitContainerKey? {
        var counts = [SplitContainerKey: Int]()
        for key in keys {
            counts[key, default: 0] += 1
        }
        guard let best = counts.values.max() else { return nil }
        if let preferred, counts[preferred] == best {
            return preferred
        }
        return keys.first { counts[$0] == best }
    }

    private func removeFromSplitGroups(syncID: String) {
        guard splitGroups.contains(where: { $0.tabSyncIDs.contains(syncID) }) else { return }
        splitGroups = splitGroups.compactMap { group in
            guard group.tabSyncIDs.contains(syncID) else { return group }
            var group = group
            group.tabSyncIDs.removeAll { $0 == syncID }
            group.fractions = nil
            if group.focusedTabSyncID == syncID {
                group.focusedTabSyncID = nil
            }
            return group.tabSyncIDs.count >= 2 ? group : nil
        }
    }

    /// Puts `tabID` directly after `anchorID` in the anchor's container through
    /// the normal drop path, which persists the order and records the sync move.
    private func placeTab(_ tabID: String, after anchorID: String) -> Bool {
        let tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
        guard let container = tree.container(of: .tab(anchorID)) else { return false }
        let current = tree.items(in: container)
        if tree.container(of: .tab(tabID)) == container, let index = current.firstIndex(of: .tab(tabID)),
           index > 0, current[index - 1] == .tab(anchorID)
        {
            return true
        }
        let siblings = current.filter { $0 != .tab(tabID) }
        guard let anchorIndex = siblings.firstIndex(of: .tab(anchorID)) else { return false }
        let next = siblings.indices.contains(anchorIndex + 1) ? siblings[anchorIndex + 1] : nil
        return commitSidebarDrop(
            payload: .init(primary: .tab(tabID), tabIDs: [tabID]),
            destination: .init(container: container, beforeItem: next)
        )
    }
}
