import Foundation

// MARK: - Crashed tabs

/// A tab whose renderer crashed shows "Tab crashed. Maybe reload
/// the page?" and Chromium's error code. As in Chrome, a tab whose renderer
/// went away in the background reloads when it is shown instead.
extension BrowserChromeModel {
    func handleRenderProcessTerminated(tabID: String, errorCode: Int) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        if visibleTabIDs.contains(tabID) {
            crashedTabErrorCodes[tabID] = errorCode
        } else {
            tabsNeedingReloadAfterCrash.insert(tabID)
        }
    }

    /// The crash page's Reload: the tab takes the focus and loads again.
    func reloadCrashedTab(id: String) {
        guard crashedTabErrorCodes[id] != nil else { return }
        if selectedTabID != id {
            selectTab(id: id)
        }
        crashedTabErrorCodes.removeValue(forKey: id)
        reloadCurrentTab()
    }

    /// A tab that crashed in the background reloads when it takes the focus;
    /// a split pane beside it shows the crash page instead.
    func revealCrashedTabs() {
        guard !tabsNeedingReloadAfterCrash.isEmpty else { return }
        for id in visibleTabIDs where tabsNeedingReloadAfterCrash.remove(id) != nil {
            if id == selectedTabID {
                // The engine switches its active page after the selection.
                DispatchQueue.main.async { [weak self] in
                    guard let self, selectedTabID == id else { return }
                    reloadCurrentTab()
                }
            } else {
                crashedTabErrorCodes[id] = 0
            }
        }
    }

    /// The selected tab and the panes shown beside it.
    private var visibleTabIDs: [String] {
        selectedTabID.map { splitPaneTabIDs(forTabID: $0) } ?? []
    }
}
