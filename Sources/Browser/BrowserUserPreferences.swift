// BrowserUserPreferences.swift

import AppKit
import Combine
import Foundation

// MARK: - BrowserSettingsRoute

enum BrowserSettingsRoute {
    static let rootURL = URL(string: "openarc://settings/")!
    static let searchEnginesURL = URL(string: "openarc://settings/searchEngines")!
    static let privacyURL = URL(string: "openarc://settings/privacy")!
    static let passwordManagerURL = URL(string: "openarc://password-manager/passwords")!
    static let notificationsURL = URL(string: "openarc://settings/content/notifications")!
    static let languageURL = URL(string: "openarc://settings/languages")!
    static let extensionShortcutsURL = URL(string: "openarc://extensions/shortcuts")!
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

/// Window edge of the sidebar. The right one follows Zen, where the window
/// controls move with the sidebar.
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
        static let windowDraggingFromPageTopEnabled = "browser.settings.windowDraggingFromPageTopEnabled"
        static let bookmarksBarVisible = "browser.settings.bookmarksBarVisible"
        static let siteURLToolbarEnabled = "browser.settings.siteURLToolbarEnabled"
        static let toolbarConfiguration = "browser.settings.toolbarConfiguration"
        static let agentAccessEnabled = "browser.settings.agentAccessEnabled"
        static let onboardingCompleted = "browser.settings.onboardingCompleted"
        static let siteToolbarShowsFullURL = "browser.settings.siteToolbarShowsFullURL"
        static let blurredChromeBackgroundEnabled = "browser.settings.blurredChromeBackgroundEnabled"
        static let batterySaverEnabled = "browser.settings.batterySaverEnabled"
        static let pinnedExtensionIDs = "browser.extensions.pinnedExtensionIDs"
        static let littleArcEnabled = "browser.settings.littleArcEnabled"
        static let linkRoutes = "browser.settings.linkRoutes"
        static let siteSearches = "browser.settings.siteSearches"
        static let sitePermissionDecisions = "browser.settings.sitePermissionDecisions"
        static let peeksLinksToOtherSites = "browser.settings.peeksLinksToOtherSites"
        static let folderPreviewsEnabled = "browser.settings.folderPreviewsEnabled"
        static let sharesThemeWithWebsites = "browser.settings.sharesThemeWithWebsites"
        static let allowsJavaScriptFromAppleEvents = "browser.settings.allowsJavaScriptFromAppleEvents"
        static let developerModeHosts = "browser.settings.developerModeHosts"
        static let boosts = "browser.settings.boosts"
        static let boostsEnabled = "browser.settings.boostsEnabled"
        static let passwordNeverOrigins = "browser.settings.passwordNeverOrigins"
        static let soundEffectsEnabled = "browser.settings.soundEffectsEnabled"
        static let gitHubLiveFolderIDs = "browser.settings.gitHubLiveFolderIDs"
        static let hiddenMediaSources = "browser.settings.hiddenMediaSources"
        static let recentPagesPreviewsEnabled = "browser.settings.recentPagesPreviewsEnabled"
        static let mailPreviewsEnabled = "browser.settings.mailPreviewsEnabled"
        static let appIcon = BrowserAppIcon.preferenceKey
        static let showsAISearchSuggestion = "browser.settings.showsAISearchSuggestion"
        static let developerReloadBehavior = "browser.settings.developerReloadBehavior"
        static let opensLittleWindowFromAnyApp = "browser.settings.opensLittleWindowFromAnyApp"
        static let newDocumentsApp = "browser.settings.newDocumentsApp"
    }

    // MARK: Internal

    /// Read by the engine through `BrowserDownloadLocation` on its own thread.
    static let downloadDirectoryKey = "browser.settings.downloadDirectoryPath"
    /// Read by the engine through `BrowserPeekSettings`.
    static let peekEnabledKey = "browser.settings.peekEnabled"
    static let littleWindowOptionCommandClickKey = "browser.settings.littleWindowOptionCommandClick"
    /// Read by the engine through `BrowserPeekSettings`.
    static let smallWindowLifetimeKey = "browser.settings.smallWindowLifetime"

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

    /// "Allow window dragging from the top of websites", on by default.
    @Published var windowDraggingFromPageTopEnabled: Bool {
        didSet { userDefaults.set(windowDraggingFromPageTopEnabled, forKey: Key.windowDraggingFromPageTopEnabled) }
    }

    /// The bar of bookmarks under the toolbar. Off by default: the sidebar is
    /// where pages are kept, and the bar is there for those who want it.
    @Published var bookmarksBarVisible: Bool {
        didSet { userDefaults.set(bookmarksBarVisible, forKey: Key.bookmarksBarVisible) }
    }

    @Published var onboardingCompleted: Bool {
        didSet { userDefaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    /// Off until the person turns it on: it lets local programs drive the browser.
    @Published var agentAccessEnabled: Bool {
        didSet { userDefaults.set(agentAccessEnabled, forKey: Key.agentAccessEnabled) }
    }

    @Published var toolbarConfiguration: BrowserToolbarConfiguration {
        didSet { userDefaults.set(toolbarConfiguration.storedValues, forKey: Key.toolbarConfiguration) }
    }

    @Published var siteURLToolbarEnabled: Bool {
        didSet { userDefaults.set(siteURLToolbarEnabled, forKey: Key.siteURLToolbarEnabled) }
    }

    @Published var siteToolbarShowsFullURL: Bool {
        didSet { userDefaults.set(siteToolbarShowsFullURL, forKey: Key.siteToolbarShowsFullURL) }
    }

    /// Lets pages read the Space's colors as CSS variables.
    @Published var showsAISearchSuggestion: Bool {
        didSet { userDefaults.set(showsAISearchSuggestion, forKey: Key.showsAISearchSuggestion) }
    }

    @Published var appIcon: BrowserAppIcon {
        didSet { userDefaults.set(appIcon.rawValue, forKey: Key.appIcon) }
    }

    /// Off until asked for: it reads the subjects of unread mail, on this Mac only.
    @Published var mailPreviewsEnabled: Bool {
        didSet { userDefaults.set(mailPreviewsEnabled, forKey: Key.mailPreviewsEnabled) }
    }

    @Published var recentPagesPreviewsEnabled: Bool {
        didSet { userDefaults.set(recentPagesPreviewsEnabled, forKey: Key.recentPagesPreviewsEnabled) }
    }

    @Published var gitHubLiveFolderIDs: Set<String> {
        didSet { userDefaults.set(Array(gitHubLiveFolderIDs), forKey: Key.gitHubLiveFolderIDs) }
    }

    /// Folders the Library's Media leaves out; all of them show by default.
    @Published var hiddenMediaSources: Set<BrowserLibraryMediaSource> {
        didSet { userDefaults.set(hiddenMediaSources.map(\.rawValue), forKey: Key.hiddenMediaSources) }
    }

    @Published var soundEffectsEnabled: Bool {
        didSet { userDefaults.set(soundEffectsEnabled, forKey: Key.soundEffectsEnabled) }
    }

    @Published var passwordNeverOrigins: Set<String> {
        didSet { userDefaults.set(Array(passwordNeverOrigins), forKey: Key.passwordNeverOrigins) }
    }

    @Published var developerModeHosts: BrowserDeveloperModeHosts {
        didSet {
            userDefaults.set(try? JSONEncoder().encode(developerModeHosts), forKey: Key.developerModeHosts)
        }
    }

    @Published var developerReloadBehavior: BrowserDeveloperReloadBehavior {
        didSet { userDefaults.set(developerReloadBehavior.rawValue, forKey: Key.developerReloadBehavior) }
    }

    @Published var allowsJavaScriptFromAppleEvents: Bool {
        didSet { userDefaults.set(allowsJavaScriptFromAppleEvents, forKey: Key.allowsJavaScriptFromAppleEvents) }
    }

    @Published var sharesThemeWithWebsites: Bool {
        didSet { userDefaults.set(sharesThemeWithWebsites, forKey: Key.sharesThemeWithWebsites) }
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

    /// Peek: Shift-clicked links open in a floating card.
    @Published var peekEnabled: Bool {
        didSet { userDefaults.set(peekEnabled, forKey: Self.peekEnabledKey) }
    }

    /// Links from other apps open in a small window, from which the page can
    /// move into a Space. On by default.
    @Published var littleArcEnabled: Bool {
        didSet { userDefaults.set(littleArcEnabled, forKey: Key.littleArcEnabled) }
    }

    /// An Option-Command-clicked link opens in a small
    /// window instead of a background tab. Off by default.
    @Published var opensOptionCommandClicksInLittleWindow: Bool {
        didSet {
            userDefaults.set(opensOptionCommandClicksInLittleWindow, forKey: Self.littleWindowOptionCommandClickKey)
        }
    }

    /// Option-Command-N in any app opens a small window. Off by default:
    /// it takes the key combination from every other app.
    @Published var smallWindowLifetime: BrowserSmallWindowLifetime {
        didSet { userDefaults.set(smallWindowLifetime.rawValue, forKey: Self.smallWindowLifetimeKey) }
    }

    @Published var newDocumentsApp: BrowserNewDocumentsApp {
        didSet { userDefaults.set(newDocumentsApp.rawValue, forKey: Key.newDocumentsApp) }
    }

    @Published var opensLittleWindowFromAnyApp: Bool {
        didSet { userDefaults.set(opensLittleWindowFromAnyApp, forKey: Key.opensLittleWindowFromAnyApp) }
    }

    /// Folder preview: resting on a collapsed folder lists its tabs.
    @Published var folderPreviewsEnabled: Bool {
        didSet { userDefaults.set(folderPreviewsEnabled, forKey: Key.folderPreviewsEnabled) }
    }

    /// Peek for links to other sites from pinned tabs and Favorites. Off
    /// by default: sign-in flows that leave the site would open in a card.
    @Published var peeksLinksToOtherSites: Bool {
        didSet { userDefaults.set(peeksLinksToOtherSites, forKey: Key.peeksLinksToOtherSites) }
    }

    /// Rules for links from other apps, in order.
    @Published var linkRoutes: [BrowserLinkRoute] {
        didSet { userDefaults.set(try? JSONEncoder().encode(linkRoutes), forKey: Key.linkRoutes) }
    }

    /// Site searches for the command bar, in order; the default set until edited.
    @Published var siteSearches: [BrowserSiteSearch] {
        didSet { userDefaults.set(try? JSONEncoder().encode(siteSearches), forKey: Key.siteSearches) }
    }

    /// Each site's Boost, in the order they were made.
    @Published var boosts: [BrowserBoost] {
        didSet { userDefaults.set(try? JSONEncoder().encode(boosts), forKey: Key.boosts) }
    }

    /// Pages run Boosts; off, every Boost is kept but none applies.
    @Published var boostsEnabled: Bool {
        didSet { userDefaults.set(boostsEnabled, forKey: Key.boostsEnabled) }
    }

    /// Remembered camera and microphone answers of every profile.
    @Published var sitePermissionDecisions: [BrowserSitePermissionDecision] {
        didSet {
            userDefaults.set(try? JSONEncoder().encode(sitePermissionDecisions), forKey: Key.sitePermissionDecisions)
        }
    }

    /// Download location; nil saves to the user's Downloads folder.
    @Published var downloadDirectoryPath: String? {
        didSet { userDefaults.set(downloadDirectoryPath, forKey: Self.downloadDirectoryKey) }
    }

    private let userDefaults: UserDefaults

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
            defaultValue: true,
        )
        self.hapticFeedbackEnabled = Self.loadBool(userDefaults, key: Key.hapticFeedbackEnabled, defaultValue: true)
        self.restoreWindowsOnLaunch = Self.loadBool(userDefaults, key: Key.restoreWindowsOnLaunch, defaultValue: true)
        self.pictureInPictureEnabled = Self.loadBool(userDefaults, key: Key.pictureInPictureEnabled, defaultValue: true)
        self.windowDraggingFromPageTopEnabled = Self.loadBool(
            userDefaults,
            key: Key.windowDraggingFromPageTopEnabled,
            defaultValue: true,
        )
        self.bookmarksBarVisible = Self.loadBool(userDefaults, key: Key.bookmarksBarVisible, defaultValue: false)
        self.onboardingCompleted = Self.loadBool(userDefaults, key: Key.onboardingCompleted, defaultValue: false)
        self.agentAccessEnabled = Self.loadBool(userDefaults, key: Key.agentAccessEnabled, defaultValue: true)
        self.toolbarConfiguration = userDefaults.stringArray(forKey: Key.toolbarConfiguration)
            .map(BrowserToolbarConfiguration.init(storedValues:)) ?? .standard
        self.siteURLToolbarEnabled = Self.loadBool(
            userDefaults,
            key: Key.siteURLToolbarEnabled,
            defaultValue: false,
        )
        self.showsAISearchSuggestion = Self.loadBool(
            userDefaults,
            key: Key.showsAISearchSuggestion,
            defaultValue: false,
        )
        self.appIcon = userDefaults.string(forKey: Key.appIcon).flatMap(BrowserAppIcon.init(rawValue:)) ?? .standard
        self.mailPreviewsEnabled = Self.loadBool(userDefaults, key: Key.mailPreviewsEnabled, defaultValue: false)
        self.recentPagesPreviewsEnabled = Self.loadBool(
            userDefaults,
            key: Key.recentPagesPreviewsEnabled,
            defaultValue: true,
        )
        self.gitHubLiveFolderIDs = Set(userDefaults.stringArray(forKey: Key.gitHubLiveFolderIDs) ?? [])
        self.hiddenMediaSources = Set(
            (userDefaults.stringArray(forKey: Key.hiddenMediaSources) ?? []).compactMap(BrowserLibraryMediaSource.init),
        )
        self.soundEffectsEnabled = Self.loadBool(userDefaults, key: Key.soundEffectsEnabled, defaultValue: true)
        self.passwordNeverOrigins = Set(userDefaults.stringArray(forKey: Key.passwordNeverOrigins) ?? [])
        self.developerModeHosts = userDefaults.data(forKey: Key.developerModeHosts)
            .flatMap { try? JSONDecoder().decode(BrowserDeveloperModeHosts.self, from: $0) } ?? .init()
        self.developerReloadBehavior = userDefaults.string(forKey: Key.developerReloadBehavior)
            .flatMap(BrowserDeveloperReloadBehavior.init(rawValue:)) ?? .reload
        self.allowsJavaScriptFromAppleEvents = Self.loadBool(
            userDefaults,
            key: Key.allowsJavaScriptFromAppleEvents,
            defaultValue: false,
        )
        self.sharesThemeWithWebsites = Self.loadBool(userDefaults, key: Key.sharesThemeWithWebsites, defaultValue: true)
        self.siteToolbarShowsFullURL = Self.loadBool(
            userDefaults,
            key: Key.siteToolbarShowsFullURL,
            defaultValue: false,
        )
        self.blurredChromeBackgroundEnabled = Self.loadBool(
            userDefaults,
            key: Key.blurredChromeBackgroundEnabled,
            defaultValue: true,
        )
        self.batterySaverEnabled = Self.loadBool(userDefaults, key: Key.batterySaverEnabled, defaultValue: true)
        self.pinnedExtensionIDs = Self.loadStringArray(userDefaults, key: Key.pinnedExtensionIDs)
        self.downloadDirectoryPath = userDefaults.string(forKey: Self.downloadDirectoryKey).flatMap { $0.isEmpty
            ? nil
            : $0
        }
        self.peekEnabled = Self.loadBool(userDefaults, key: Self.peekEnabledKey, defaultValue: true)
        self.littleArcEnabled = Self.loadBool(userDefaults, key: Key.littleArcEnabled, defaultValue: true)
        self.opensOptionCommandClicksInLittleWindow = userDefaults.bool(forKey: Self.littleWindowOptionCommandClickKey)
        self.opensLittleWindowFromAnyApp = userDefaults.bool(forKey: Key.opensLittleWindowFromAnyApp)
        self.smallWindowLifetime = userDefaults.object(forKey: Self.smallWindowLifetimeKey) == nil
            ? .twelveHours
            : BrowserSmallWindowLifetime(rawValue: userDefaults.double(forKey: Self.smallWindowLifetimeKey)) ??
            .twelveHours
        self.newDocumentsApp = userDefaults.string(forKey: Key.newDocumentsApp)
            .flatMap(BrowserNewDocumentsApp.init(rawValue:)) ?? .googleDocs
        self.folderPreviewsEnabled = Self.loadBool(userDefaults, key: Key.folderPreviewsEnabled, defaultValue: true)
        self.peeksLinksToOtherSites = Self.loadBool(userDefaults, key: Key.peeksLinksToOtherSites, defaultValue: false)
        self.linkRoutes = userDefaults.data(forKey: Key.linkRoutes)
            .flatMap { try? JSONDecoder().decode([BrowserLinkRoute].self, from: $0) } ?? []
        self.siteSearches = userDefaults.data(forKey: Key.siteSearches)
            .flatMap { try? JSONDecoder().decode([BrowserSiteSearch].self, from: $0) }?
            .map(\.withCurrentDefaultColor) ?? BrowserSiteSearch.arcDefaults
        self.sitePermissionDecisions = userDefaults.data(forKey: Key.sitePermissionDecisions)
            .flatMap { try? JSONDecoder().decode([BrowserSitePermissionDecision].self, from: $0) } ?? []
        let boostData = userDefaults.data(forKey: Key.boosts)
        let boosts = boostData.flatMap { try? JSONDecoder().decode([BrowserBoost].self, from: $0) } ?? []
        // Boosts saved before sync got their identities while decoding; keep them.
        if let boostData, !boosts.isEmpty,
           (try? JSONSerialization.jsonObject(with: boostData) as? [[String: Any]])?
            .contains(where: { $0["syncID"] == nil }) == true
        {
            userDefaults.set(try? JSONEncoder().encode(boosts), forKey: Key.boosts)
        }
        self.boosts = boosts
        self.boostsEnabled = Self.loadBool(userDefaults, key: Key.boostsEnabled, defaultValue: true)
    }

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
    case shareTab
    case manageSpaces
    case translatePage
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
    case copyLinkAsMarkdown
    case copyLinkAsQuote
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
    case resetSpaceTabs
    case collapseAllFolders
    case expandAllFolders
    case newFolder
    case newSpace
    case captureFullPage
    case captureArea
    case viewDownloads
    case viewLibrary
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
    case addTopSplit
    case addLeftSplit
    case addRightSplit
    case addBottomSplit
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
        case .shareTab:
            BrowserCommands.shareTab
        case .manageSpaces:
            BrowserCommands.manageSpaces
        case .translatePage:
            BrowserCommands.translatePage
        case .addBottomSplit:
            BrowserCommands.addBottomSplit
        case .addTopSplit:
            BrowserCommands.addTopSplit
        case .addRightSplit:
            BrowserCommands.addRightSplit
        case .addLeftSplit:
            BrowserCommands.addLeftSplit
        case .capturePortrait:
            BrowserCommands.capturePortrait
        case .blankWindow:
            BrowserCommands.blankWindow
        case .viewMedia:
            BrowserCommands.viewMedia
        case .networkInspector:
            BrowserCommands.networkInspector
        case .toggleDeveloperMode:
            BrowserCommands.toggleDeveloperMode
        case .editBoost:
            BrowserCommands.editBoost
        case .viewBoosts:
            BrowserCommands.viewBoosts
        case .editSpaceTheme:
            BrowserCommands.editSpaceTheme
        case .togglePictureInPicture:
            BrowserCommands.togglePictureInPicture
        case .muteAllTabs:
            BrowserCommands.muteAllTabs
        case .unmuteAllTabs:
            BrowserCommands.unmuteAllTabs
        case .javaScriptConsole:
            BrowserCommands.javaScriptConsole
        case .inspectElements:
            BrowserCommands.inspectElements
        case .viewSource:
            BrowserCommands.viewSource
        case .zoomIn:
            BrowserCommands.zoomIn
        case .zoomOut:
            BrowserCommands.zoomOut
        case .resetZoom:
            BrowserCommands.resetZoom
        case .newWindow:
            BrowserCommands.newWindow
        case .newIncognitoWindow:
            BrowserCommands.newIncognitoWindow
        case .newLittleWindow:
            BrowserCommands.newLittleWindow
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
        case .customizeToolbar:
            BrowserCommands.customizeToolbar
        case .viewDownloads:
            BrowserCommands.viewDownloads
        case .viewLibrary:
            BrowserCommands.viewLibrary
        case .togglePinTab:
            BrowserCommands.togglePinTab
        case .duplicateTab:
            BrowserCommands.duplicateTab
        case .renameTab:
            BrowserCommands.renameTab
        case .resetTabToPinnedURL:
            BrowserCommands.resetTabToPinnedURL
        case .resetSpaceTabs:
            BrowserCommands.resetSpaceTabs
        case .collapseAllFolders:
            BrowserCommands.collapseAllFolders
        case .expandAllFolders:
            BrowserCommands.expandAllFolders
        case .newSpace:
            BrowserCommands.newSpace
        case .newFolder:
            BrowserCommands.newFolder
        case .captureFullPage:
            BrowserCommands.captureFullPage
        case .captureArea:
            BrowserCommands.captureArea
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
        case .copyLinkAsQuote:
            BrowserCommands.copyLinkAsQuote
        case .goToSidebarItem1,
             .goToSidebarItem2,
             .goToSidebarItem3,
             .goToSidebarItem4,
             .goToSidebarItem5,
             .goToSidebarItem6,
             .goToSidebarItem7,
             .goToSidebarItem8:
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
        case .shareTab:
            .shareTab
        case .manageSpaces:
            .manageSpaces
        case .translatePage:
            .translatePage
        case .addBottomSplit:
            .addBottomSplit
        case .addTopSplit:
            .addTopSplit
        case .addRightSplit:
            .addRightSplit
        case .addLeftSplit:
            .addLeftSplit
        case .capturePortrait:
            .capturePortrait
        case .blankWindow:
            .blankWindow
        case .viewMedia:
            .viewMedia
        case .networkInspector:
            .networkInspector
        case .toggleDeveloperMode:
            .toggleDeveloperMode
        case .editBoost:
            .editBoost
        case .viewBoosts:
            .viewBoosts
        case .editSpaceTheme:
            .editSpaceTheme
        case .togglePictureInPicture:
            .togglePictureInPicture
        case .muteAllTabs:
            .muteAllTabs
        case .unmuteAllTabs:
            .unmuteAllTabs
        case .javaScriptConsole:
            .javaScriptConsole
        case .inspectElements:
            .inspectElements
        case .viewSource:
            .viewSource
        case .zoomIn:
            .zoomIn
        case .zoomOut:
            .zoomOut
        case .resetZoom:
            .resetZoom
        case .newWindow:
            .newWindow
        case .newIncognitoWindow:
            .newIncognitoWindow
        case .newLittleWindow:
            .newLittleWindow
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
        case .customizeToolbar:
            .customizeToolbar
        case .viewDownloads:
            .viewDownloads
        case .viewLibrary:
            .viewLibrary
        case .togglePinTab:
            .togglePinTab
        case .duplicateTab:
            .duplicateTab
        case .renameTab:
            .renameTab
        case .resetTabToPinnedURL:
            .resetTabToPinnedURL
        case .resetSpaceTabs:
            .resetSpaceTabs
        case .collapseAllFolders:
            .setAllFoldersExpanded(false)
        case .expandAllFolders:
            .setAllFoldersExpanded(true)
        case .newSpace:
            .newSpace
        case .newFolder:
            .newFolder
        case .captureFullPage:
            .captureFullPage
        case .captureArea:
            .captureArea
        case .selectNextTab:
            .selectNextTab
        case .selectPreviousTab,
             .selectPreviousTabAlternate:
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
        case .copyLinkAsQuote:
            .copyLinkAsQuote
        case .goToSidebarItem1,
             .goToSidebarItem2,
             .goToSidebarItem3,
             .goToSidebarItem4,
             .goToSidebarItem5,
             .goToSidebarItem6,
             .goToSidebarItem7,
             .goToSidebarItem8:
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

    // MARK: Internal

    var commandIDs: [BrowserCommandID] {
        BrowserCommandID.allCases
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.overrides = Self.loadOverrides(userDefaults: userDefaults, decoder: decoder)
    }

    private static func loadOverrides(
        userDefaults: UserDefaults,
        decoder: JSONDecoder,
    ) -> [BrowserCommandID: BrowserKeyboardShortcut] {
        guard let data = userDefaults.data(forKey: Key.overrides), let rawOverrides = try? decoder.decode(
            [String: BrowserKeyboardShortcut].self,
            from: data,
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
            shortcut: shortcut(for: commandID),
        )
    }

    /// The command whose current shortcut is `shortcut`, if any.
    func command(using shortcut: BrowserKeyboardShortcut) -> BrowserCommandID? {
        let normalized = shortcut.normalizedForMatching
        guard normalized.isAssigned else { return nil }
        return commandIDs.first { self.shortcut(for: $0).normalizedForMatching == normalized }
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
            modifiers: modifiers.intersection(.deviceIndependentFlagsMask),
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

// MARK: - BrowserLibraryMediaSource

/// A folder the Library's Media shows pictures from.
enum BrowserLibraryMediaSource: String, CaseIterable {
    case documents
    case desktop
    case screenshots
    case downloads

    var title: String {
        switch self {
        case .documents: BrowserStrings.libraryMediaDocuments
        case .desktop: BrowserStrings.libraryMediaDesktop
        case .screenshots: BrowserStrings.libraryMediaScreenshots
        case .downloads: BrowserStrings.libraryMediaDownloads
        }
    }

    /// Screenshots go where the system's screenshot setting points, the Desktop by default.
    func folder(downloadDirectoryPath: String?) -> URL? {
        let files = FileManager.default
        switch self {
        case .documents:
            return files.urls(for: .documentDirectory, in: .userDomainMask).first
        case .desktop:
            return files.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .screenshots:
            if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
               !location.isEmpty
            {
                return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            }
            return files.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .downloads:
            return BrowserDownloadLocation.directory(customPath: downloadDirectoryPath)
        }
    }
}
