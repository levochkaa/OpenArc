// BrowserKeyboardShortcuts.swift

import AppKit
import Foundation

// MARK: - BrowserKeyboardShortcut

struct BrowserKeyboardShortcut: Codable, Equatable, Hashable {
    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case keyEquivalent
        case modifiersRawValue
    }

    // MARK: Internal

    static let unassigned = BrowserKeyboardShortcut("", modifiers: [])

    /// Menu key equivalents for the arrow keys.
    static let upArrow = functionKey(NSUpArrowFunctionKey)
    static let downArrow = functionKey(NSDownArrowFunctionKey)
    static let leftArrow = functionKey(NSLeftArrowFunctionKey)
    static let rightArrow = functionKey(NSRightArrowFunctionKey)

    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    var isAssigned: Bool {
        !keyEquivalent.isEmpty
    }

    var keyCaps: [String] {
        var result = [String]()

        if modifiers.contains(.control) {
            result.append("\u{2303}")
        }

        if modifiers.contains(.option) {
            result.append("\u{2325}")
        }

        if modifiers.contains(.shift) {
            result.append("\u{21E7}")
        }

        if modifiers.contains(.command) {
            result.append("\u{2318}")
        }

        let arrows = [
            Self.upArrow: "\u{2191}",
            Self.downArrow: "\u{2193}",
            Self.leftArrow: "\u{2190}",
            Self.rightArrow: "\u{2192}",
        ]
        result.append(arrows[keyEquivalent] ?? keyEquivalent.uppercased())
        return result
    }

    var displayText: String {
        keyCaps.joined()
    }

    init(_ keyEquivalent: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        let modifiersRawValue = try container.decode(NSEvent.ModifierFlags.RawValue.self, forKey: .modifiersRawValue)
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    private static func functionKey(_ key: Int) -> String {
        UnicodeScalar(UInt32(key)).map { String(Character($0)) } ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(modifiers.rawValue, forKey: .modifiersRawValue)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyEquivalent)
        hasher.combine(modifiers.rawValue)
    }
}

// MARK: - BrowserCommandDescriptor

struct BrowserCommandDescriptor {
    let menuTitle: String
    let helpTitle: String
    let shortcut: BrowserKeyboardShortcut
}

// MARK: - BrowserCommands

enum BrowserCommands {
    static let openSettings = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSettings,
        helpTitle: BrowserStrings.menuSettings,
        shortcut: BrowserKeyboardShortcut(","),
    )

    static let setAsDefaultBrowser = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSetAsDefaultBrowser,
        helpTitle: BrowserStrings.menuSetAsDefaultBrowser,
        shortcut: BrowserKeyboardShortcut("♡"),
    )

    static let newTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewTab,
        helpTitle: BrowserStrings.sidebarNewTab,
        shortcut: BrowserKeyboardShortcut("t"),
    )

    /// Open Location is Command-L and starts from the current URL in the
    /// compact current-page bar.
    static let openLocation = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuOpenLocation,
        helpTitle: BrowserStrings.menuOpenLocation,
        shortcut: BrowserKeyboardShortcut("l"),
    )

    /// Restore Last Closed Tab is Shift-Command-T.
    static let restoreLastClosedTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuRestoreLastClosedTab,
        helpTitle: BrowserStrings.menuRestoreLastClosedTab,
        shortcut: BrowserKeyboardShortcut("t", modifiers: [.command, .shift]),
    )

    /// Stop Loading is Command-period.
    static let stopLoading = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationStopLoading,
        helpTitle: BrowserStrings.navigationStopLoading,
        shortcut: BrowserKeyboardShortcut("."),
    )

    /// Developer Tools is Option-Command-I.
    static let inspectElements = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuInspectElements,
        helpTitle: BrowserStrings.menuInspectElements,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .option]),
    )

    static let javaScriptConsole = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuJavaScriptConsole,
        helpTitle: BrowserStrings.menuJavaScriptConsole,
        shortcut: BrowserKeyboardShortcut("j", modifiers: [.command, .option]),
    )

    static let muteAllTabs = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuMuteAllTabs,
        helpTitle: BrowserStrings.menuMuteAllTabs,
        shortcut: .unassigned,
    )

    static let unmuteAllTabs = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuUnmuteAllTabs,
        helpTitle: BrowserStrings.menuUnmuteAllTabs,
        shortcut: .unassigned,
    )

    static let togglePictureInPicture = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuOpenPictureInPicture,
        helpTitle: BrowserStrings.menuOpenPictureInPicture,
        shortcut: .unassigned,
    )

    static let editSpaceTheme = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.spaceEditThemeAction,
        helpTitle: BrowserStrings.spaceEditThemeAction,
        shortcut: .unassigned,
    )

    static let toggleDeveloperMode = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuTurnOnDeveloperMode,
        helpTitle: BrowserStrings.menuTurnOnDeveloperMode,
        shortcut: BrowserKeyboardShortcut("d", modifiers: [.control]),
    )

    static let editBoost = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuBoostThisSite,
        helpTitle: BrowserStrings.menuBoostThisSite,
        shortcut: .unassigned,
    )

    static let viewBoosts = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuViewBoosts,
        helpTitle: BrowserStrings.menuViewBoosts,
        shortcut: .unassigned,
    )

    static let networkInspector = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNetworkInspector,
        helpTitle: BrowserStrings.menuNetworkInspector,
        shortcut: .unassigned,
    )

    static let viewMedia = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuViewMedia,
        helpTitle: BrowserStrings.menuViewMedia,
        shortcut: .unassigned,
    )

    static let blankWindow = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuBlankWindow,
        helpTitle: BrowserStrings.menuBlankWindow,
        shortcut: BrowserKeyboardShortcut("n", modifiers: [.control, .command]),
    )

    static let capturePortrait = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.captureInPortraitMode,
        helpTitle: BrowserStrings.captureInPortraitMode,
        shortcut: .unassigned,
    )

    static let addLeftSplit = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitAddLeft,
        helpTitle: BrowserStrings.splitAddLeft,
        shortcut: .unassigned,
    )

    static let addRightSplit = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitAddRight,
        helpTitle: BrowserStrings.splitAddRight,
        shortcut: .unassigned,
    )

    static let addTopSplit = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitAddTop,
        helpTitle: BrowserStrings.splitAddTop,
        shortcut: .unassigned,
    )

    static let addBottomSplit = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitAddBottom,
        helpTitle: BrowserStrings.splitAddBottom,
        shortcut: .unassigned,
    )

    static let translatePage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuTranslatePage,
        helpTitle: BrowserStrings.menuTranslatePage,
        shortcut: .unassigned,
    )

    static let manageSpaces = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuManageSpaces,
        helpTitle: BrowserStrings.menuManageSpaces,
        shortcut: .unassigned,
    )

    static let shareTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuShareTab,
        helpTitle: BrowserStrings.menuShareTab,
        shortcut: .unassigned,
    )

    static let developerTools = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuDeveloperTools,
        helpTitle: BrowserStrings.menuDeveloperTools,
        shortcut: BrowserKeyboardShortcut("i", modifiers: [.command, .option]),
    )

    /// View Source is Option-Command-U.
    static let viewSource = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuViewSource,
        helpTitle: BrowserStrings.menuViewSource,
        shortcut: BrowserKeyboardShortcut("u", modifiers: [.command, .option]),
    )

    /// Zoom In, Zoom Out and Zoom to Actual Size are
    /// Command-+, Command-- and Command-0; Command-= is the unshifted + key.
    static let zoomIn = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.webAppZoomInAction,
        helpTitle: BrowserStrings.webAppZoomInAction,
        shortcut: BrowserKeyboardShortcut("="),
    )

    static let zoomOut = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.webAppZoomOutAction,
        helpTitle: BrowserStrings.webAppZoomOutAction,
        shortcut: BrowserKeyboardShortcut("-"),
    )

    static let resetZoom = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.webAppZoomResetAction,
        helpTitle: BrowserStrings.webAppZoomResetAction,
        shortcut: BrowserKeyboardShortcut("0"),
    )

    static let newWindow = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewWindow,
        helpTitle: BrowserStrings.menuNewWindow,
        shortcut: BrowserKeyboardShortcut("n"),
    )

    static let newIncognitoWindow = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewIncognitoWindow,
        helpTitle: BrowserStrings.menuNewIncognitoWindow,
        shortcut: BrowserKeyboardShortcut("n", modifiers: [.command, .shift]),
    )

    /// New Small Window is Option-Command-N.
    static let newLittleWindow = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewLittleWindow,
        helpTitle: BrowserStrings.menuNewLittleWindow,
        shortcut: BrowserKeyboardShortcut("n", modifiers: [.command, .option]),
    )

    static let openHistory = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuHistory,
        helpTitle: BrowserStrings.menuHistory,
        shortcut: BrowserKeyboardShortcut("y"),
    )

    static let toggleBookmark = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.bookmarksAddCurrentPage,
        helpTitle: BrowserStrings.bookmarksAddCurrentPage,
        shortcut: .unassigned,
    )

    static let archiveTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabArchiveAction,
        helpTitle: BrowserStrings.tabArchiveTooltip,
        shortcut: BrowserKeyboardShortcut("w"),
    )

    static let viewArchive = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.archiveViewAction,
        helpTitle: BrowserStrings.archiveViewAction,
        shortcut: .unassigned,
    )

    static let clearArchive = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.archiveClear,
        helpTitle: BrowserStrings.archiveClear,
        shortcut: .unassigned,
    )

    static let savePage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSavePageAs,
        helpTitle: BrowserStrings.menuSavePageAs,
        shortcut: BrowserKeyboardShortcut("s", modifiers: [.command, .shift]),
    )

    static let printPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuPrint,
        helpTitle: BrowserStrings.menuPrint,
        shortcut: BrowserKeyboardShortcut("p"),
    )

    static let copyLink = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabCopyURLAction,
        helpTitle: BrowserStrings.tabCopyURLAction,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .shift]),
    )

    static let findInPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFind,
        helpTitle: BrowserStrings.menuFind,
        shortcut: BrowserKeyboardShortcut("f"),
    )

    static let findAndReplace = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindAndReplace,
        helpTitle: BrowserStrings.menuFindAndReplace,
        shortcut: BrowserKeyboardShortcut("f", modifiers: [.command, .option]),
    )

    static let findNext = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindNext,
        helpTitle: BrowserStrings.menuFindNext,
        shortcut: BrowserKeyboardShortcut("g"),
    )

    static let findPrevious = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindPrevious,
        helpTitle: BrowserStrings.menuFindPrevious,
        shortcut: BrowserKeyboardShortcut("g", modifiers: [.command, .shift]),
    )

    static let jumpToSelection = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuJumpToSelection,
        helpTitle: BrowserStrings.menuJumpToSelection,
        shortcut: BrowserKeyboardShortcut("j"),
    )

    static let clearTemporaryTabs = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearTemporaryTabs,
        helpTitle: BrowserStrings.sidebarClearTemporaryTabsTooltip,
        shortcut: BrowserKeyboardShortcut("k", modifiers: [.command, .shift]),
    )

    static let goBack = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuGoBack,
        helpTitle: BrowserStrings.navigationBack,
        shortcut: BrowserKeyboardShortcut("["),
    )

    static let goForward = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuGoForward,
        helpTitle: BrowserStrings.navigationForward,
        shortcut: BrowserKeyboardShortcut("]"),
    )

    static let reload = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuRefreshPage,
        helpTitle: BrowserStrings.navigationRefresh,
        shortcut: BrowserKeyboardShortcut("r"),
    )

    static let forceReload = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuForceRefresh,
        helpTitle: BrowserStrings.menuForceRefresh,
        shortcut: BrowserKeyboardShortcut("r", modifiers: [.command, .shift]),
    )

    static let clearCacheAndRefresh = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearCacheAndRefresh,
        helpTitle: BrowserStrings.menuClearCacheAndRefresh,
        shortcut: .unassigned,
    )

    static let clearCookiesAndRefresh = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearCookiesAndRefresh,
        helpTitle: BrowserStrings.menuClearCookiesAndRefresh,
        shortcut: .unassigned,
    )

    /// Add Split View is Control-Shift-=.
    static let addSplitView = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuAddSplitView,
        helpTitle: BrowserStrings.menuAddSplitView,
        shortcut: BrowserKeyboardShortcut("=", modifiers: [.control, .shift]),
    )

    /// Close this Split Pane is Control-Shift--.
    static let closeSplitPane = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuCloseSplitPane,
        helpTitle: BrowserStrings.menuCloseSplitPane,
        shortcut: BrowserKeyboardShortcut("-", modifiers: [.control, .shift]),
    )

    static let separateTabFromSplit = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSeparatePageFromSplitView,
        helpTitle: BrowserStrings.menuSeparatePageFromSplitView,
        shortcut: .unassigned,
    )

    static let separateSplitView = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitSeparateAllTabsAction,
        helpTitle: BrowserStrings.splitSeparateAllTabsAction,
        shortcut: .unassigned,
    )

    static let toggleSplitOrientation = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuToggleSplitOrientation,
        helpTitle: BrowserStrings.menuToggleSplitOrientation,
        shortcut: .unassigned,
    )

    /// Expand Current Split has no default shortcut.
    static let expandCurrentSplit = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuExpandCurrentSplit,
        helpTitle: BrowserStrings.menuExpandCurrentSplit,
        shortcut: .unassigned,
    )

    /// Switch to Split View 1–4 is Control-Shift-1…4
    /// and next/previous is Control-Shift-]/[.
    static let focusSplitPane1 = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitFocusPaneTitle(1),
        helpTitle: BrowserStrings.splitFocusPaneTitle(1),
        shortcut: BrowserKeyboardShortcut("1", modifiers: [.control, .shift]),
    )

    static let focusSplitPane2 = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitFocusPaneTitle(2),
        helpTitle: BrowserStrings.splitFocusPaneTitle(2),
        shortcut: BrowserKeyboardShortcut("2", modifiers: [.control, .shift]),
    )

    static let focusSplitPane3 = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitFocusPaneTitle(3),
        helpTitle: BrowserStrings.splitFocusPaneTitle(3),
        shortcut: BrowserKeyboardShortcut("3", modifiers: [.control, .shift]),
    )

    static let focusSplitPane4 = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.splitFocusPaneTitle(4),
        helpTitle: BrowserStrings.splitFocusPaneTitle(4),
        shortcut: BrowserKeyboardShortcut("4", modifiers: [.control, .shift]),
    )

    static let focusNextSplitPane = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFocusNextSplitPane,
        helpTitle: BrowserStrings.menuFocusNextSplitPane,
        shortcut: BrowserKeyboardShortcut("]", modifiers: [.control, .shift]),
    )

    static let focusPreviousSplitPane = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFocusPreviousSplitPane,
        helpTitle: BrowserStrings.menuFocusPreviousSplitPane,
        shortcut: BrowserKeyboardShortcut("[", modifiers: [.control, .shift]),
    )

    static let toggleSidebarPosition = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuMoveSidebarRight,
        helpTitle: BrowserStrings.menuMoveSidebarRight,
        shortcut: .unassigned,
    )

    static let toggleSidebar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuToggleSidebar,
        helpTitle: BrowserStrings.sidebarHide,
        shortcut: BrowserKeyboardShortcut("s"),
    )

    static let toggleBookmarksBar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.settingsShowBookmarksBar,
        helpTitle: BrowserStrings.settingsShowBookmarksBar,
        shortcut: BrowserKeyboardShortcut("b", modifiers: [.command, .shift]),
    )

    /// Show/Hide Toolbar is Command-Shift-D.
    static let toggleSiteToolbar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuShowToolbar,
        helpTitle: BrowserStrings.menuShowToolbar,
        shortcut: BrowserKeyboardShortcut("d", modifiers: [.command, .shift]),
    )

    static let customizeToolbar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuCustomizeToolbar,
        helpTitle: BrowserStrings.menuCustomizeToolbar,
        shortcut: .unassigned,
    )

    /// Pin/Unpin Tab has no default: Command-D is Add Bookmark.
    static let togglePinTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuPinTab,
        helpTitle: BrowserStrings.menuPinTab,
        shortcut: BrowserKeyboardShortcut("d"),
    )

    /// These commands have no default shortcut.
    static let duplicateTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuDuplicateTab,
        helpTitle: BrowserStrings.menuDuplicateTab,
        shortcut: .unassigned,
    )

    static let renameTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuRenameTab,
        helpTitle: BrowserStrings.menuRenameTab,
        shortcut: .unassigned,
    )

    static let resetTabToPinnedURL = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuResetTabToPinnedURL,
        helpTitle: BrowserStrings.menuResetTabToPinnedURL,
        shortcut: .unassigned,
    )

    /// Reset all tabs in this Space, unbound by default.
    static let resetSpaceTabs = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuResetSpaceTabs,
        helpTitle: BrowserStrings.menuResetSpaceTabs,
        shortcut: .unassigned,
    )

    static let collapseAllFolders = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuCollapseAllFolders,
        helpTitle: BrowserStrings.menuCollapseAllFolders,
        shortcut: .unassigned,
    )

    static let expandAllFolders = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuExpandAllFolders,
        helpTitle: BrowserStrings.menuExpandAllFolders,
        shortcut: .unassigned,
    )

    /// New Folder…; folders hold at least one tab, so the new folder takes the
    /// selected tab.
    static let newFolder = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewFolderEllipsis,
        helpTitle: BrowserStrings.pinnedTabFolderNewAction,
        shortcut: .unassigned,
    )

    /// Capture… is Shift-Command-2. Capture Full Page has no default.
    static let captureArea = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuCaptureArea,
        helpTitle: BrowserStrings.menuCaptureArea,
        shortcut: BrowserKeyboardShortcut("2", modifiers: [.command, .shift]),
    )

    static let captureFullPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.siteCaptureFullPageAction,
        helpTitle: BrowserStrings.siteCaptureFullPageAction,
        shortcut: .unassigned,
    )

    static let newSpace = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewSpaceEllipsis,
        helpTitle: BrowserStrings.spaceNewAction,
        shortcut: .unassigned,
    )

    /// View Downloads is Command-Shift-J.
    static let viewDownloads = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuViewDownloadsEllipsis,
        helpTitle: BrowserStrings.menuViewDownloads,
        shortcut: BrowserKeyboardShortcut("j", modifiers: [.command, .shift]),
    )

    /// View Library is Command-Shift-L.
    static let viewLibrary = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuOpenLibrary,
        helpTitle: BrowserStrings.menuViewLibrary,
        shortcut: BrowserKeyboardShortcut("l", modifiers: [.command, .shift]),
    )

    /// Next/Previous Tab are Option-Command-Down/Up, the sidebar's direction.
    static let selectNextTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSelectNextTab,
        helpTitle: BrowserStrings.menuSelectNextTab,
        shortcut: BrowserKeyboardShortcut(BrowserKeyboardShortcut.downArrow, modifiers: [.command, .option]),
    )

    static let selectPreviousTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSelectPreviousTab,
        helpTitle: BrowserStrings.menuSelectPreviousTab,
        shortcut: BrowserKeyboardShortcut(BrowserKeyboardShortcut.upArrow, modifiers: [.command, .option]),
    )

    /// Next/Previous Tab (Alternate) are Command-}/{, as in other browsers.
    static let selectNextTabAlternate = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSelectNextTabAlternate,
        helpTitle: BrowserStrings.menuSelectNextTabAlternate,
        shortcut: BrowserKeyboardShortcut("]", modifiers: [.command, .shift]),
    )

    static let selectPreviousTabAlternate = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSelectPreviousTabAlternate,
        helpTitle: BrowserStrings.menuSelectPreviousTabAlternate,
        shortcut: BrowserKeyboardShortcut("[", modifiers: [.command, .shift]),
    )

    /// Next/Previous Space are Option-Command-Right/Left.
    static let selectNextSpace = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSelectNextSpace,
        helpTitle: BrowserStrings.menuSelectNextSpace,
        shortcut: BrowserKeyboardShortcut(BrowserKeyboardShortcut.rightArrow, modifiers: [.command, .option]),
    )

    static let selectPreviousSpace = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSelectPreviousSpace,
        helpTitle: BrowserStrings.menuSelectPreviousSpace,
        shortcut: BrowserKeyboardShortcut(BrowserKeyboardShortcut.leftArrow, modifiers: [.command, .option]),
    )

    /// Reveal Current Tab has no default: macOS uses Control-Space to switch
    /// input sources.
    static let revealCurrentTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuRevealCurrentTab,
        helpTitle: BrowserStrings.menuRevealCurrentTab,
        shortcut: .unassigned,
    )

    /// Open Extensions is Command-E.
    static let openExtensions = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuOpenExtensions,
        helpTitle: BrowserStrings.menuOpenExtensions,
        shortcut: BrowserKeyboardShortcut("e"),
    )

    /// Copy URL as Markdown is Option-Shift-Command-C.
    static let copyLinkAsMarkdown = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuCopyLinkAsMarkdown,
        helpTitle: BrowserStrings.menuCopyLinkAsMarkdown,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .option, .shift]),
    )

    /// Copy URL as Quote is Control-Shift-Command-C.
    static let copyLinkAsQuote = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuCopyLinkAsQuote,
        helpTitle: BrowserStrings.menuCopyLinkAsQuote,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .control, .shift]),
    )

    /// Go to last Sidebar Item is Command-9.
    static let goToLastSidebarItem = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuGoToLastSidebarItem,
        helpTitle: BrowserStrings.menuGoToLastSidebarItem,
        shortcut: BrowserKeyboardShortcut("9"),
    )

    /// Go to Sidebar Item 1–8 is Command-1…8.
    static func goToSidebarItem(_ index: Int) -> BrowserCommandDescriptor {
        BrowserCommandDescriptor(
            menuTitle: BrowserStrings.menuGoToSidebarItem(index + 1),
            helpTitle: BrowserStrings.menuGoToSidebarItem(index + 1),
            shortcut: BrowserKeyboardShortcut("\(index + 1)"),
        )
    }
}

// MARK: - BrowserSpaceShortcuts

enum BrowserSpaceShortcuts {
    static let maximumIndexedSpaces = 4

    static func shortcut(forSpaceIndex index: Int) -> BrowserKeyboardShortcut? {
        guard (0..<maximumIndexedSpaces).contains(index) else {
            return nil
        }

        return BrowserKeyboardShortcut("\(index + 1)", modifiers: [.control])
    }

    static func spaceIndex(forPhysicalKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Int? {
        guard modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control] else {
            return nil
        }

        switch keyCode {
        case 18:
            return 0
        case 19:
            return 1
        case 20:
            return 2
        case 21:
            return 3
        default:
            return nil
        }
    }
}

// MARK: - BrowserLayoutIndependentShortcutCommand

enum BrowserLayoutIndependentShortcutCommand: Equatable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case pasteAndMatchStyle
    case selectAll
    case quit
    case hideApplication
    case hideOtherApplications
    case minimizeWindow
    case closeWindow
    case openSettings
    case setAsDefaultBrowser
    case newTab
    case openLocation
    case restoreLastClosedTab
    case stopLoading
    case developerTools
    case shareTab
    case manageSpaces
    case translatePage
    case addBottomSplit
    case addTopSplit
    case addRightSplit
    case addLeftSplit
    case capturePortrait
    case blankWindow
    case viewMedia
    case networkInspector
    case toggleDeveloperMode
    case editBoost
    case viewBoosts
    case editSpaceTheme
    case togglePictureInPicture
    case muteAllTabs
    case unmuteAllTabs
    case javaScriptConsole
    case inspectElements
    case viewSource
    case zoomIn
    case zoomOut
    case resetZoom
    case newWindow
    case newIncognitoWindow
    case newLittleWindow
    case openHistory
    case toggleBookmark
    case archiveTab
    case viewArchive
    case clearArchive
    case savePage
    case printPage
    case copyLink
    case findInPage
    case findAndReplace
    case findNextInPage
    case findPreviousInPage
    case jumpToSelection
    case clearTemporaryTabs
    case goBack
    case goForward
    case reload
    case forceReload
    case clearCacheAndRefresh
    case clearCookiesAndRefresh
    case addSplitView
    case closeSplitPane
    case separateTabFromSplit
    case separateSplitView
    case toggleSplitOrientation
    case expandCurrentSplit
    case focusSplitPane1
    case focusSplitPane2
    case focusSplitPane3
    case focusSplitPane4
    case focusNextSplitPane
    case focusPreviousSplitPane
    case toggleSidebar
    case toggleSidebarPosition
    case toggleBookmarksBar
    case toggleSiteToolbar
    case customizeToolbar
    case togglePinTab
    case duplicateTab
    case renameTab
    case resetTabToPinnedURL
    case setAllFoldersExpanded(Bool)
    case resetSpaceTabs
    case newSpace
    case newFolder
    case captureFullPage
    case captureArea
    case viewDownloads
    case viewLibrary
    case selectNextTab
    case selectPreviousTab
    case selectNextSpace
    case selectPreviousSpace
    case revealCurrentTab
    case openExtensions
    case copyLinkAsMarkdown
    case copyLinkAsQuote
    /// Go to Sidebar Item N, counted from 0.
    case goToSidebarItem(Int)
    case goToLastSidebarItem
}

// MARK: - BrowserKeyboardShortcutBridge

enum BrowserKeyboardShortcutBridge {
    // MARK: Private

    private struct ShortcutMatch {
        // MARK: Internal

        let command: BrowserLayoutIndependentShortcutCommand
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags

        init(
            command: BrowserLayoutIndependentShortcutCommand,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags,
        ) {
            self.command = command
            self.keyEquivalent = keyEquivalent.lowercased()
            self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        }

        init(
            command: BrowserLayoutIndependentShortcutCommand,
            shortcut: BrowserKeyboardShortcut,
        ) {
            self.init(
                command: command,
                keyEquivalent: shortcut.keyEquivalent,
                modifiers: shortcut.modifiers,
            )
        }
    }

    // MARK: Internal

    static let windowShortcuts: [
        (command: BrowserLayoutIndependentShortcutCommand, shortcut: BrowserKeyboardShortcut)
    ] =
        [
            (.hideApplication, BrowserKeyboardShortcut("h")),
            (.hideOtherApplications, BrowserKeyboardShortcut("h", modifiers: [.command, .option])),
            (.minimizeWindow, BrowserKeyboardShortcut("m")),
            (.closeWindow, BrowserKeyboardShortcut("w", modifiers: [.command, .shift])),
        ]

    private static var windowShortcutMatches: [ShortcutMatch] {
        windowShortcuts.map { ShortcutMatch(command: $0.command, shortcut: $0.shortcut) }
    }

    static func commandForLayoutIndependentDispatch(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        shortcutResolver: BrowserShortcutResolving? = nil,
    ) -> BrowserLayoutIndependentShortcutCommand? {
        let normalizedModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A focused page takes arrow keys with Command before the menu sees them.
        if let arrow = arrowKeyEquivalent(for: keyCode) {
            let modifiers = normalizedModifiers.subtracting([.numericPad, .function])
            guard !modifiers.isDisjoint(with: [.command, .control]) else { return nil }
            return shortcutMatches(shortcutResolver: shortcutResolver)
                .first { $0.keyEquivalent == arrow && $0.modifiers == modifiers }?
                .command
        }
        guard !normalizedModifiers.isDisjoint(with: [.command, .control]),
              let usKeyEquivalent = usKeyEquivalent(for: keyCode),
              normalizedCharacters(from: charactersIgnoringModifiers) != usKeyEquivalent
        else {
            return nil
        }

        return shortcutMatches(shortcutResolver: shortcutResolver)
            .first {
                $0.keyEquivalent == usKeyEquivalent && $0.modifiers == normalizedModifiers
            }?.command
    }

    /// The US-layout key that types a shortcut's character, for shortcuts
    /// registered outside the app's key handling.
    static func physicalKeyCode(forKeyEquivalent keyEquivalent: String) -> UInt16? {
        (0..<128).first { usKeyEquivalent(for: $0) == keyEquivalent.lowercased() }
    }

    private static func arrowKeyEquivalent(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 123: BrowserKeyboardShortcut.leftArrow
        case 124: BrowserKeyboardShortcut.rightArrow
        case 125: BrowserKeyboardShortcut.downArrow
        case 126: BrowserKeyboardShortcut.upArrow
        default: nil
        }
    }

    private static func shortcutMatches(shortcutResolver: BrowserShortcutResolving?) -> [ShortcutMatch] {
        var matches = [
            ShortcutMatch(command: .undo, keyEquivalent: "z", modifiers: [.command]),
            ShortcutMatch(command: .redo, keyEquivalent: "z", modifiers: [.command, .shift]),
            ShortcutMatch(command: .cut, keyEquivalent: "x", modifiers: [.command]),
            ShortcutMatch(command: .copy, keyEquivalent: "c", modifiers: [.command]),
            ShortcutMatch(command: .paste, keyEquivalent: "v", modifiers: [.command]),
            ShortcutMatch(command: .pasteAndMatchStyle, keyEquivalent: "v", modifiers: [.command, .shift]),
            ShortcutMatch(command: .selectAll, keyEquivalent: "a", modifiers: [.command]),
            ShortcutMatch(command: .quit, keyEquivalent: "q", modifiers: [.command]),
        ]

        matches.append(
            contentsOf: BrowserCommandID.allCases.map { commandID in
                ShortcutMatch(
                    command: commandID.layoutIndependentCommand,
                    shortcut: shortcutResolver?.shortcut(for: commandID) ?? commandID.defaultDescriptor.shortcut,
                )
            },
        )
        // The window keys added later come after commands, so a key the user
        // gave a command before they were reserved keeps working.
        matches += windowShortcutMatches
        return matches
    }

    private static func normalizedCharacters(from characters: String?) -> String? {
        characters?.lowercased()
    }

    private static func usKeyEquivalent(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0:
            "a"
        case 1:
            "s"
        case 2:
            "d"
        case 3:
            "f"
        case 14:
            "e"
        case 4:
            "h"
        case 46:
            "m"
        case 5:
            "g"
        case 6:
            "z"
        case 7:
            "x"
        case 8:
            "c"
        case 9:
            "v"
        case 11:
            "b"
        case 12:
            "q"
        case 45:
            "n"
        case 13:
            "w"
        case 15:
            "r"
        case 16:
            "y"
        case 17:
            "t"
        case 35:
            "p"
        case 38:
            "j"
        case 40:
            "k"
        case 37:
            "l"
        case 18:
            "1"
        case 19:
            "2"
        case 20:
            "3"
        case 21:
            "4"
        case 23:
            "5"
        case 22:
            "6"
        case 26:
            "7"
        case 28:
            "8"
        case 25:
            "9"
        case 29:
            "0"
        case 34:
            "i"
        case 32:
            "u"
        case 47:
            "."
        case 123:
            BrowserKeyboardShortcut.leftArrow
        case 124:
            BrowserKeyboardShortcut.rightArrow
        case 125:
            BrowserKeyboardShortcut.downArrow
        case 126:
            BrowserKeyboardShortcut.upArrow
        case 30:
            "]"
        case 33:
            "["
        case 43:
            ","
        case 24:
            "="
        case 27:
            "-"
        default:
            nil
        }
    }
}
