import AppKit
import Combine
import Foundation

// MARK: - BrowserSettingsRoute

enum BrowserSettingsRoute {
    static let rootURL = URL(string: "tb://settings/")!
    static let searchEnginesURL = URL(string: "tb://settings/searchEngines")!
    static let privacyURL = URL(string: "tb://settings/privacy")!
    static let passwordManagerURL = URL(string: "tb://password-manager/passwords")!
    static let paymentsURL = URL(string: "tb://settings/payments")!
    static let notificationsURL = URL(string: "tb://settings/content/notifications")!
    static let languageURL = URL(string: "tb://settings/languages")!
    static let extensionShortcutsURL = URL(string: "tb://extensions/shortcuts")!
}

// MARK: - BrowserAISearchProvider

enum BrowserAISearchProvider: String, CaseIterable, Codable, Identifiable {
    case chatGPT
    case claude
    case gemini
    case perplexity
    case deepSeek

    // MARK: Internal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .chatGPT:
            BrowserStrings.settingsAISearchProviderChatGPT
        case .claude:
            BrowserStrings.settingsAISearchProviderClaude
        case .gemini:
            BrowserStrings.settingsAISearchProviderGemini
        case .perplexity:
            BrowserStrings.settingsAISearchProviderPerplexity
        case .deepSeek:
            BrowserStrings.settingsAISearchProviderDeepSeek
        }
    }

    func searchURLString(for query: String) -> String {
        var components = URLComponents()
        components.scheme = "https"

        switch self {
        case .chatGPT:
            components.host = "chatgpt.com"
            components.path = "/"
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "hints", value: "search"),
            ]
        case .claude:
            components.host = "claude.ai"
            components.path = "/new"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .gemini:
            components.host = "gemini.google.com"
            components.path = "/app"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .perplexity:
            components.host = "www.perplexity.ai"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .deepSeek:
            components.host = "chat.deepseek.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }

        return components.url?.absoluteString ?? "https://chatgpt.com/"
    }
}

// MARK: - BrowserUpdateChannel

enum BrowserUpdateChannel: String, CaseIterable, Codable, Identifiable {
    case stable
    case beta

    // MARK: Internal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .stable:
            BrowserStrings.updateChannelStable
        case .beta:
            BrowserStrings.updateChannelBeta
        }
    }
}

// MARK: - BrowserAppearancePreference

enum BrowserAppearancePreference: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    // MARK: Internal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system:
            BrowserStrings.settingsAppearanceSystem
        case .light:
            BrowserStrings.settingsAppearanceLight
        case .dark:
            BrowserStrings.settingsAppearanceDark
        }
    }

    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            nil
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }
}

// MARK: - BrowserSidebarPosition

/// Window edge of the sidebar, left or right; the right one
/// follows Zen, where the window controls move with the sidebar.
enum BrowserSidebarPosition: String, CaseIterable, Codable, Identifiable {
    case left
    case right

    // MARK: Internal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: BrowserStrings.settingsSidebarPositionLeft
        case .right: BrowserStrings.settingsSidebarPositionRight
        }
    }

    var opposite: BrowserSidebarPosition { self == .left ? .right : .left }
}

// MARK: - BrowserUserPreferencesStore

final class BrowserUserPreferencesStore: ObservableObject {
    // MARK: Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.automaticUpdatesEnabled = Self.loadBool(userDefaults, key: Key.automaticUpdatesEnabled, defaultValue: true)
        let rawUpdateChannel = userDefaults.string(forKey: Key.updateChannel)
        self.updateChannel = rawUpdateChannel.flatMap(BrowserUpdateChannel.init(rawValue:)) ?? .stable
        let rawAppearancePreference = userDefaults.string(forKey: Key.appearancePreference)
        self.appearancePreference = rawAppearancePreference
            .flatMap(BrowserAppearancePreference.init(rawValue:)) ?? .system
        self.warnBeforeQuitting = Self.loadBool(userDefaults, key: Key.warnBeforeQuitting, defaultValue: true)
        self.sidebarPosition = userDefaults.string(forKey: Key.sidebarPosition)
            .flatMap(BrowserSidebarPosition.init(rawValue:)) ?? .left
        let rawSearchEngine = userDefaults.string(forKey: Key.searchEngine)
        self.searchEngine = rawSearchEngine.flatMap(BrowserSearchEngine.init(rawValue:)) ?? .google
        let rawAISearchProvider = userDefaults.string(forKey: Key.aiSearchProvider)
        self.aiSearchProvider = rawAISearchProvider.flatMap(BrowserAISearchProvider.init(rawValue:))
            ?? (rawSearchEngine == "perplexity" ? .perplexity : .chatGPT)
        self.searchEngineSuggestionsEnabled = Self.loadBool(
            userDefaults,
            key: Key.searchEngineSuggestionsEnabled,
            defaultValue: true
        )
        self.hapticFeedbackEnabled = Self.loadBool(userDefaults, key: Key.hapticFeedbackEnabled, defaultValue: true)
        self.restoreWindowsOnLaunch = Self.loadBool(userDefaults, key: Key.restoreWindowsOnLaunch, defaultValue: true)
        self.pictureInPictureEnabled = Self.loadBool(userDefaults, key: Key.pictureInPictureEnabled, defaultValue: true)
        self.bookmarksBarVisible = Self.loadBool(userDefaults, key: Key.bookmarksBarVisible, defaultValue: true)
        self.siteURLToolbarEnabled = Self.loadBool(
            userDefaults,
            key: Key.siteURLToolbarEnabled,
            defaultValue: false
        )
        self.siteToolbarShowsFullURL = Self.loadBool(
            userDefaults,
            key: Key.siteToolbarShowsFullURL,
            defaultValue: false
        )
        self.blurredChromeBackgroundEnabled = Self.loadBool(
            userDefaults,
            key: Key.blurredChromeBackgroundEnabled,
            defaultValue: true
        )
        self.batterySaverEnabled = Self.loadBool(userDefaults, key: Key.batterySaverEnabled, defaultValue: true)
        self.pinnedExtensionIDs = Self.loadStringArray(userDefaults, key: Key.pinnedExtensionIDs)
        self.downloadDirectoryPath = userDefaults.string(forKey: Self.downloadDirectoryKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Read by the engine through `BrowserDownloadLocation` on its own thread.
    static let downloadDirectoryKey = "browser.settings.downloadDirectoryPath"

    // MARK: Internal

    @Published var automaticUpdatesEnabled: Bool {
        didSet { userDefaults.set(automaticUpdatesEnabled, forKey: Key.automaticUpdatesEnabled) }
    }

    @Published var updateChannel: BrowserUpdateChannel {
        didSet { userDefaults.set(updateChannel.rawValue, forKey: Key.updateChannel) }
    }

    @Published var appearancePreference: BrowserAppearancePreference {
        didSet { userDefaults.set(appearancePreference.rawValue, forKey: Key.appearancePreference) }
    }

    @Published var sidebarPosition: BrowserSidebarPosition {
        didSet { userDefaults.set(sidebarPosition.rawValue, forKey: Key.sidebarPosition) }
    }

    @Published var warnBeforeQuitting: Bool {
        didSet { userDefaults.set(warnBeforeQuitting, forKey: Key.warnBeforeQuitting) }
    }

    @Published var searchEngine: BrowserSearchEngine {
        didSet { userDefaults.set(searchEngine.rawValue, forKey: Key.searchEngine) }
    }

    @Published var aiSearchProvider: BrowserAISearchProvider {
        didSet { userDefaults.set(aiSearchProvider.rawValue, forKey: Key.aiSearchProvider) }
    }

    @Published var searchEngineSuggestionsEnabled: Bool {
        didSet { userDefaults.set(searchEngineSuggestionsEnabled, forKey: Key.searchEngineSuggestionsEnabled) }
    }

    @Published var hapticFeedbackEnabled: Bool {
        didSet { userDefaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }

    @Published var restoreWindowsOnLaunch: Bool {
        didSet { userDefaults.set(restoreWindowsOnLaunch, forKey: Key.restoreWindowsOnLaunch) }
    }

    @Published var pictureInPictureEnabled: Bool {
        didSet { userDefaults.set(pictureInPictureEnabled, forKey: Key.pictureInPictureEnabled) }
    }

    @Published var bookmarksBarVisible: Bool {
        didSet { userDefaults.set(bookmarksBarVisible, forKey: Key.bookmarksBarVisible) }
    }

    @Published var siteURLToolbarEnabled: Bool {
        didSet { userDefaults.set(siteURLToolbarEnabled, forKey: Key.siteURLToolbarEnabled) }
    }

    @Published var siteToolbarShowsFullURL: Bool {
        didSet { userDefaults.set(siteToolbarShowsFullURL, forKey: Key.siteToolbarShowsFullURL) }
    }

    @Published var blurredChromeBackgroundEnabled: Bool {
        didSet { userDefaults.set(blurredChromeBackgroundEnabled, forKey: Key.blurredChromeBackgroundEnabled) }
    }

    @Published var batterySaverEnabled: Bool {
        didSet { userDefaults.set(batterySaverEnabled, forKey: Key.batterySaverEnabled) }
    }

    @Published var pinnedExtensionIDs: [String] {
        didSet { userDefaults.set(pinnedExtensionIDs, forKey: Key.pinnedExtensionIDs) }
    }

    /// Download location; nil saves to the user's Downloads folder.
    @Published var downloadDirectoryPath: String? {
        didSet { userDefaults.set(downloadDirectoryPath, forKey: Self.downloadDirectoryKey) }
    }

    // MARK: Private

    private enum Key {
        static let automaticUpdatesEnabled = "browser.settings.automaticUpdatesEnabled"
        static let updateChannel = "browser.settings.updateChannel"
        static let appearancePreference = "browser.settings.appearancePreference"
        static let sidebarPosition = "browser.settings.sidebarPosition"
        static let warnBeforeQuitting = "browser.settings.warnBeforeQuitting"
        static let searchEngine = "browser.settings.searchEngine"
        static let aiSearchProvider = "browser.settings.aiSearchProvider"
        static let searchEngineSuggestionsEnabled = "browser.settings.searchEngineSuggestionsEnabled"
        static let hapticFeedbackEnabled = "browser.settings.hapticFeedbackEnabled"
        static let restoreWindowsOnLaunch = "browser.settings.restoreWindowsOnLaunch"
        static let pictureInPictureEnabled = "browser.settings.pictureInPictureEnabled"
        static let bookmarksBarVisible = "browser.settings.bookmarksBarVisible"
        static let siteURLToolbarEnabled = "browser.settings.siteURLToolbarEnabled"
        static let siteToolbarShowsFullURL = "browser.settings.siteToolbarShowsFullURL"
        static let blurredChromeBackgroundEnabled = "browser.settings.blurredChromeBackgroundEnabled"
        static let batterySaverEnabled = "browser.settings.batterySaverEnabled"
        static let pinnedExtensionIDs = "browser.extensions.pinnedExtensionIDs"
    }

    private let userDefaults: UserDefaults

    private static func loadBool(_ userDefaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return userDefaults.bool(forKey: key)
    }

    private static func loadStringArray(_ userDefaults: UserDefaults, key: String) -> [String] {
        guard let values = userDefaults.stringArray(forKey: key) else {
            return []
        }

        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty, !seen.contains(value) else {
                return false
            }

            seen.insert(value)
            return true
        }
    }
}

// MARK: - BrowserCommandID

enum BrowserCommandID: String, CaseIterable, Codable, Identifiable {
    case openSettings
    case setAsDefaultBrowser
    case newTab
    case openLocation
    case restoreLastClosedTab
    case stopLoading
    case developerTools
    case zoomIn
    case zoomOut
    case resetZoom
    case newIncognitoWindow
    case openHistory
    case toggleBookmark
    case archiveTab
    case viewArchive
    case clearArchive
    case savePage
    case printPage
    case copyLink
    case copyLinkAsMarkdown
    case findInPage
    case findAndReplace
    case findNext
    case findPrevious
    case jumpToSelection
    case clearTemporaryTabs
    case togglePinTab
    case duplicateTab
    case renameTab
    case resetTabToPinnedURL
    case collapseAllFolders
    case expandAllFolders
    case newSpace
    case viewDownloads
    case selectNextTab
    case selectPreviousTab
    case selectNextTabAlternate
    case selectPreviousTabAlternate
    case selectNextSpace
    case selectPreviousSpace
    case revealCurrentTab
    case openExtensions
    case goToSidebarItem1
    case goToSidebarItem2
    case goToSidebarItem3
    case goToSidebarItem4
    case goToSidebarItem5
    case goToSidebarItem6
    case goToSidebarItem7
    case goToSidebarItem8
    case goToLastSidebarItem
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

    // MARK: Internal

    var id: String {
        rawValue
    }

    var defaultDescriptor: BrowserCommandDescriptor {
        switch self {
        case .openSettings:
            BrowserCommands.openSettings
        case .setAsDefaultBrowser:
            BrowserCommands.setAsDefaultBrowser
        case .newTab:
            BrowserCommands.newTab
        case .openLocation:
            BrowserCommands.openLocation
        case .restoreLastClosedTab:
            BrowserCommands.restoreLastClosedTab
        case .stopLoading:
            BrowserCommands.stopLoading
        case .developerTools:
            BrowserCommands.developerTools
        case .zoomIn:
            BrowserCommands.zoomIn
        case .zoomOut:
            BrowserCommands.zoomOut
        case .resetZoom:
            BrowserCommands.resetZoom
        case .newIncognitoWindow:
            BrowserCommands.newIncognitoWindow
        case .openHistory:
            BrowserCommands.openHistory
        case .toggleBookmark:
            BrowserCommands.toggleBookmark
        case .archiveTab:
            BrowserCommands.archiveTab
        case .viewArchive:
            BrowserCommands.viewArchive
        case .clearArchive:
            BrowserCommands.clearArchive
        case .savePage:
            BrowserCommands.savePage
        case .printPage:
            BrowserCommands.printPage
        case .copyLink:
            BrowserCommands.copyLink
        case .findInPage:
            BrowserCommands.findInPage
        case .findAndReplace:
            BrowserCommands.findAndReplace
        case .findNext:
            BrowserCommands.findNext
        case .findPrevious:
            BrowserCommands.findPrevious
        case .jumpToSelection:
            BrowserCommands.jumpToSelection
        case .clearTemporaryTabs:
            BrowserCommands.clearTemporaryTabs
        case .goBack:
            BrowserCommands.goBack
        case .goForward:
            BrowserCommands.goForward
        case .reload:
            BrowserCommands.reload
        case .forceReload:
            BrowserCommands.forceReload
        case .clearCacheAndRefresh:
            BrowserCommands.clearCacheAndRefresh
        case .clearCookiesAndRefresh:
            BrowserCommands.clearCookiesAndRefresh
        case .addSplitView:
            BrowserCommands.addSplitView
        case .closeSplitPane:
            BrowserCommands.closeSplitPane
        case .separateTabFromSplit:
            BrowserCommands.separateTabFromSplit
        case .separateSplitView:
            BrowserCommands.separateSplitView
        case .toggleSplitOrientation:
            BrowserCommands.toggleSplitOrientation
        case .expandCurrentSplit:
            BrowserCommands.expandCurrentSplit
        case .toggleSidebar:
            BrowserCommands.toggleSidebar
        case .toggleSidebarPosition:
            BrowserCommands.toggleSidebarPosition
        case .focusSplitPane1:
            BrowserCommands.focusSplitPane1
        case .focusSplitPane2:
            BrowserCommands.focusSplitPane2
        case .focusSplitPane3:
            BrowserCommands.focusSplitPane3
        case .focusSplitPane4:
            BrowserCommands.focusSplitPane4
        case .focusNextSplitPane:
            BrowserCommands.focusNextSplitPane
        case .focusPreviousSplitPane:
            BrowserCommands.focusPreviousSplitPane
        case .toggleBookmarksBar:
            BrowserCommands.toggleBookmarksBar
        case .toggleSiteToolbar:
            BrowserCommands.toggleSiteToolbar
        case .viewDownloads:
            BrowserCommands.viewDownloads
        case .togglePinTab:
            BrowserCommands.togglePinTab
        case .duplicateTab:
            BrowserCommands.duplicateTab
        case .renameTab:
            BrowserCommands.renameTab
        case .resetTabToPinnedURL:
            BrowserCommands.resetTabToPinnedURL
        case .collapseAllFolders:
            BrowserCommands.collapseAllFolders
        case .expandAllFolders:
            BrowserCommands.expandAllFolders
        case .newSpace:
            BrowserCommands.newSpace
        case .selectNextTab:
            BrowserCommands.selectNextTab
        case .selectPreviousTab:
            BrowserCommands.selectPreviousTab
        case .selectNextTabAlternate:
            BrowserCommands.selectNextTabAlternate
        case .selectPreviousTabAlternate:
            BrowserCommands.selectPreviousTabAlternate
        case .selectNextSpace:
            BrowserCommands.selectNextSpace
        case .revealCurrentTab:
            BrowserCommands.revealCurrentTab
        case .openExtensions:
            BrowserCommands.openExtensions
        case .selectPreviousSpace:
            BrowserCommands.selectPreviousSpace
        case .copyLinkAsMarkdown:
            BrowserCommands.copyLinkAsMarkdown
        case .goToSidebarItem1, .goToSidebarItem2, .goToSidebarItem3, .goToSidebarItem4,
             .goToSidebarItem5, .goToSidebarItem6, .goToSidebarItem7, .goToSidebarItem8:
            BrowserCommands.goToSidebarItem(sidebarItemIndex)
        case .goToLastSidebarItem:
            BrowserCommands.goToLastSidebarItem
        }
    }

    var layoutIndependentCommand: BrowserLayoutIndependentShortcutCommand {
        switch self {
        case .openSettings:
            .openSettings
        case .setAsDefaultBrowser:
            .setAsDefaultBrowser
        case .newTab:
            .newTab
        case .openLocation:
            .openLocation
        case .restoreLastClosedTab:
            .restoreLastClosedTab
        case .stopLoading:
            .stopLoading
        case .developerTools:
            .developerTools
        case .zoomIn:
            .zoomIn
        case .zoomOut:
            .zoomOut
        case .resetZoom:
            .resetZoom
        case .newIncognitoWindow:
            .newIncognitoWindow
        case .openHistory:
            .openHistory
        case .toggleBookmark:
            .toggleBookmark
        case .archiveTab:
            .archiveTab
        case .viewArchive:
            .viewArchive
        case .clearArchive:
            .clearArchive
        case .savePage:
            .savePage
        case .printPage:
            .printPage
        case .copyLink:
            .copyLink
        case .findInPage:
            .findInPage
        case .findAndReplace:
            .findAndReplace
        case .findNext:
            .findNextInPage
        case .findPrevious:
            .findPreviousInPage
        case .jumpToSelection:
            .jumpToSelection
        case .clearTemporaryTabs:
            .clearTemporaryTabs
        case .goBack:
            .goBack
        case .goForward:
            .goForward
        case .reload:
            .reload
        case .forceReload:
            .forceReload
        case .clearCacheAndRefresh:
            .clearCacheAndRefresh
        case .clearCookiesAndRefresh:
            .clearCookiesAndRefresh
        case .addSplitView:
            .addSplitView
        case .closeSplitPane:
            .closeSplitPane
        case .separateTabFromSplit:
            .separateTabFromSplit
        case .separateSplitView:
            .separateSplitView
        case .toggleSplitOrientation:
            .toggleSplitOrientation
        case .expandCurrentSplit:
            .expandCurrentSplit
        case .toggleSidebar:
            .toggleSidebar
        case .toggleSidebarPosition:
            .toggleSidebarPosition
        case .focusSplitPane1:
            .focusSplitPane1
        case .focusSplitPane2:
            .focusSplitPane2
        case .focusSplitPane3:
            .focusSplitPane3
        case .focusSplitPane4:
            .focusSplitPane4
        case .focusNextSplitPane:
            .focusNextSplitPane
        case .focusPreviousSplitPane:
            .focusPreviousSplitPane
        case .toggleBookmarksBar:
            .toggleBookmarksBar
        case .toggleSiteToolbar:
            .toggleSiteToolbar
        case .viewDownloads:
            .viewDownloads
        case .togglePinTab:
            .togglePinTab
        case .duplicateTab:
            .duplicateTab
        case .renameTab:
            .renameTab
        case .resetTabToPinnedURL:
            .resetTabToPinnedURL
        case .collapseAllFolders:
            .setAllFoldersExpanded(false)
        case .expandAllFolders:
            .setAllFoldersExpanded(true)
        case .newSpace:
            .newSpace
        case .selectNextTab:
            .selectNextTab
        case .selectPreviousTab, .selectPreviousTabAlternate:
            .selectPreviousTab
        case .selectNextTabAlternate:
            .selectNextTab
        case .selectNextSpace:
            .selectNextSpace
        case .revealCurrentTab:
            .revealCurrentTab
        case .openExtensions:
            .openExtensions
        case .selectPreviousSpace:
            .selectPreviousSpace
        case .copyLinkAsMarkdown:
            .copyLinkAsMarkdown
        case .goToSidebarItem1, .goToSidebarItem2, .goToSidebarItem3, .goToSidebarItem4,
             .goToSidebarItem5, .goToSidebarItem6, .goToSidebarItem7, .goToSidebarItem8:
            .goToSidebarItem(sidebarItemIndex)
        case .goToLastSidebarItem:
            .goToLastSidebarItem
        }
    }

    /// Position of a Go to Sidebar Item command, counted from 0.
    var sidebarItemIndex: Int {
        switch self {
        case .goToSidebarItem2: 1
        case .goToSidebarItem3: 2
        case .goToSidebarItem4: 3
        case .goToSidebarItem5: 4
        case .goToSidebarItem6: 5
        case .goToSidebarItem7: 6
        case .goToSidebarItem8: 7
        default: 0
        }
    }
}

// MARK: - BrowserShortcutResolving

protocol BrowserShortcutResolving: AnyObject {
    func shortcut(for commandID: BrowserCommandID) -> BrowserKeyboardShortcut
    func descriptor(for commandID: BrowserCommandID) -> BrowserCommandDescriptor
}

// MARK: - BrowserShortcutStore

final class BrowserShortcutStore: ObservableObject, BrowserShortcutResolving {
    // MARK: Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.overrides = Self.loadOverrides(userDefaults: userDefaults, decoder: decoder)
    }

    // MARK: Internal

    var commandIDs: [BrowserCommandID] {
        BrowserCommandID.allCases
    }

    /// A default added in a later version yields to a key the user already
    /// gave another command, so their own binding keeps working.
    func shortcut(for commandID: BrowserCommandID) -> BrowserKeyboardShortcut {
        if let override = overrides[commandID] {
            return override
        }
        let fallback = commandID.defaultDescriptor.shortcut
        let normalized = fallback.normalizedForMatching
        let isTaken = normalized.isAssigned && overrides.contains { key, value in
            key != commandID && value.normalizedForMatching == normalized
        }
        return isTaken ? .unassigned : fallback
    }

    func descriptor(for commandID: BrowserCommandID) -> BrowserCommandDescriptor {
        let defaultDescriptor = commandID.defaultDescriptor
        return BrowserCommandDescriptor(
            menuTitle: defaultDescriptor.menuTitle,
            helpTitle: defaultDescriptor.helpTitle,
            shortcut: shortcut(for: commandID)
        )
    }

    func isCustomized(_ commandID: BrowserCommandID) -> Bool {
        overrides[commandID] != nil
    }

    @discardableResult func setShortcut(_ shortcut: BrowserKeyboardShortcut, for commandID: BrowserCommandID) -> Bool {
        guard conflictDescription(for: shortcut, excluding: commandID) == nil else {
            return false
        }

        overrides[commandID] =
            if shortcut == commandID.defaultDescriptor.shortcut {
                nil
            } else {
                shortcut
            }
        persistOverrides()
        return true
    }

    func resetShortcut(for commandID: BrowserCommandID) {
        overrides[commandID] = nil
        persistOverrides()
    }

    func resetAllShortcuts() {
        overrides = [:]
        persistOverrides()
    }

    func conflictDescription(for shortcut: BrowserKeyboardShortcut, excluding commandID: BrowserCommandID?) -> String? {
        let normalizedShortcut = shortcut.normalizedForMatching
        guard normalizedShortcut.isAssigned else {
            return nil
        }

        if let conflictingCommand = commandIDs.first(where: {
            $0 != commandID && self.shortcut(for: $0).normalizedForMatching == normalizedShortcut
        }) {
            return conflictingCommand.defaultDescriptor.menuTitle
        }

        return BrowserShortcutStore.reservedShortcutTitles[normalizedShortcut]
    }

    // MARK: Private

    private enum Key {
        static let overrides = "browser.settings.shortcutOverrides"
    }

    private static let reservedShortcutTitles: [BrowserKeyboardShortcut: String] = [
        BrowserKeyboardShortcut("z"): BrowserStrings.menuUndo,
        BrowserKeyboardShortcut("z", modifiers: [.command, .shift]): BrowserStrings.menuRedo,
        BrowserKeyboardShortcut("x"): BrowserStrings.menuCut,
        BrowserKeyboardShortcut("c"): BrowserStrings.menuCopy,
        BrowserKeyboardShortcut("v"): BrowserStrings.menuPaste,
        BrowserKeyboardShortcut("v", modifiers: [.command, .shift]): BrowserStrings.menuPasteAndMatchStyle,
        BrowserKeyboardShortcut("a"): BrowserStrings.menuSelectAll,
        BrowserKeyboardShortcut("q"): BrowserStrings.quitShortcutTitle,
        BrowserKeyboardShortcut("h"): BrowserStrings.hideMenuItem(appName: ProcessInfo.processInfo.processName),
        BrowserKeyboardShortcut("h", modifiers: [.command, .option]): BrowserStrings.menuHideOthers,
        BrowserKeyboardShortcut("m"): BrowserStrings.menuMinimize,
        BrowserKeyboardShortcut("w", modifiers: [.command, .shift]): BrowserStrings.webAppCloseWindowAction,
    ].reduce(into: [:]) { result, item in
        result[item.key.normalizedForMatching] = item.value
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Published private var overrides: [BrowserCommandID: BrowserKeyboardShortcut]

    private static func loadOverrides(
        userDefaults: UserDefaults,
        decoder: JSONDecoder
    ) -> [BrowserCommandID: BrowserKeyboardShortcut] {
        guard let data = userDefaults.data(forKey: Key.overrides), let rawOverrides = try? decoder.decode(
            [String: BrowserKeyboardShortcut].self,
            from: data
        ) else {
            return [:]
        }

        return rawOverrides.reduce(into: [:]) { result, item in
            guard let commandID = BrowserCommandID(rawValue: item.key) else {
                return
            }

            result[commandID] = item.value
        }
    }

    private func persistOverrides() {
        let rawOverrides = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if rawOverrides.isEmpty {
            userDefaults.removeObject(forKey: Key.overrides)
            return
        }

        guard let data = try? encoder.encode(rawOverrides) else {
            return
        }

        userDefaults.set(data, forKey: Key.overrides)
    }
}

extension BrowserKeyboardShortcut {
    var normalizedForMatching: BrowserKeyboardShortcut {
        BrowserKeyboardShortcut(
            keyEquivalent.lowercased(),
            modifiers: modifiers.intersection(.deviceIndependentFlagsMask)
        )
    }
}

// MARK: - BrowserQuitWarningPolicy

struct BrowserQuitWarningPolicy {
    let warnsBeforeQuitting: Bool
    let openTabCount: Int

    var shouldWarn: Bool {
        warnsBeforeQuitting && openTabCount > 0
    }
}
