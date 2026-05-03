import AppKit
import QuartzCore
import SwiftUI

struct BrowserSidebarSnapshot: Equatable {
    let spaces: [BrowserChromeModel.Space]
    let selectedSpaceID: String?
    let activeSpace: BrowserChromeModel.Space?
    let isActiveSpacePinnedSectionCollapsed: Bool
    let allTabs: [BrowserChromeModel.Tab]
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

    func replacingTabs(_ tabs: [BrowserChromeModel.Tab]) -> BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            spaces: spaces,
            selectedSpaceID: selectedSpaceID,
            activeSpace: activeSpace,
            isActiveSpacePinnedSectionCollapsed: isActiveSpacePinnedSectionCollapsed,
            allTabs: tabs,
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
}
