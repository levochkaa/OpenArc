import AppKit
import Combine
import Foundation

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

enum BrowserSearchEngine: String, CaseIterable, Codable, Identifiable {
    case google
    case microsoftBing
    case yahoo
    case duckDuckGo
    case yandex
    case perplexity

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .google:
            BrowserStrings.settingsSearchEngineGoogle
        case .microsoftBing:
            BrowserStrings.settingsSearchEngineMicrosoftBing
        case .yahoo:
            BrowserStrings.settingsSearchEngineYahoo
        case .duckDuckGo:
            BrowserStrings.settingsSearchEngineDuckDuckGo
        case .yandex:
            BrowserStrings.settingsSearchEngineYandex
        case .perplexity:
            BrowserStrings.settingsSearchEnginePerplexity
        }
    }

    func searchURLString(for query: String) -> String {
        var components = URLComponents()
        components.scheme = "https"

        switch self {
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .microsoftBing:
            components.host = "www.bing.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yahoo:
            components.host = "search.yahoo.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "p", value: query)]
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yandex:
            components.host = "yandex.com"
            components.path = "/search/"
            components.queryItems = [URLQueryItem(name: "text", value: query)]
        case .perplexity:
            components.host = "www.perplexity.ai"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }

        return components.url?.absoluteString ?? BrowserSearchEngine.google.searchURLString(for: query)
    }
}

final class BrowserUserPreferencesStore: ObservableObject {
    private enum Key {
        static let automaticUpdatesEnabled = "browser.settings.automaticUpdatesEnabled"
        static let warnBeforeQuitting = "browser.settings.warnBeforeQuitting"
        static let searchEngine = "browser.settings.searchEngine"
        static let searchEngineSuggestionsEnabled = "browser.settings.searchEngineSuggestionsEnabled"
        static let hapticFeedbackEnabled = "browser.settings.hapticFeedbackEnabled"
        static let restoreWindowsOnLaunch = "browser.settings.restoreWindowsOnLaunch"
        static let pictureInPictureEnabled = "browser.settings.pictureInPictureEnabled"
    }

    private let userDefaults: UserDefaults

    @Published var automaticUpdatesEnabled: Bool {
        didSet { userDefaults.set(automaticUpdatesEnabled, forKey: Key.automaticUpdatesEnabled) }
    }

    @Published var warnBeforeQuitting: Bool {
        didSet { userDefaults.set(warnBeforeQuitting, forKey: Key.warnBeforeQuitting) }
    }

    @Published var searchEngine: BrowserSearchEngine {
        didSet { userDefaults.set(searchEngine.rawValue, forKey: Key.searchEngine) }
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        automaticUpdatesEnabled = Self.loadBool(userDefaults, key: Key.automaticUpdatesEnabled, defaultValue: true)
        warnBeforeQuitting = Self.loadBool(userDefaults, key: Key.warnBeforeQuitting, defaultValue: true)
        let rawSearchEngine = userDefaults.string(forKey: Key.searchEngine)
        searchEngine = rawSearchEngine.flatMap(BrowserSearchEngine.init(rawValue:)) ?? .google
        searchEngineSuggestionsEnabled = Self.loadBool(
            userDefaults,
            key: Key.searchEngineSuggestionsEnabled,
            defaultValue: true
        )
        hapticFeedbackEnabled = Self.loadBool(userDefaults, key: Key.hapticFeedbackEnabled, defaultValue: true)
        restoreWindowsOnLaunch = Self.loadBool(userDefaults, key: Key.restoreWindowsOnLaunch, defaultValue: true)
        pictureInPictureEnabled = Self.loadBool(userDefaults, key: Key.pictureInPictureEnabled, defaultValue: true)
    }

    private static func loadBool(_ userDefaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return userDefaults.bool(forKey: key)
    }
}

enum BrowserCommandID: String, CaseIterable, Codable, Identifiable {
    case openSettings
    case setAsDefaultBrowser
    case newTab
    case archiveTab
    case savePage
    case printPage
    case copyLink
    case findInPage
    case findAndReplace
    case findNext
    case findPrevious
    case jumpToSelection
    case clearTemporaryTabs
    case goBack
    case goForward
    case reload
    case forceReload
    case toggleSidebar

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
        case .archiveTab:
            BrowserCommands.archiveTab
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
        case .toggleSidebar:
            BrowserCommands.toggleSidebar
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
        case .archiveTab:
            .archiveTab
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
        case .toggleSidebar:
            .toggleSidebar
        }
    }
}

protocol BrowserShortcutResolving: AnyObject {
    func shortcut(for commandID: BrowserCommandID) -> BrowserKeyboardShortcut
    func descriptor(for commandID: BrowserCommandID) -> BrowserCommandDescriptor
}

final class BrowserShortcutStore: ObservableObject, BrowserShortcutResolving {
    private enum Key {
        static let overrides = "browser.settings.shortcutOverrides"
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Published private var overrides: [BrowserCommandID: BrowserKeyboardShortcut]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        overrides = Self.loadOverrides(userDefaults: userDefaults, decoder: decoder)
    }

    var commandIDs: [BrowserCommandID] {
        BrowserCommandID.allCases
    }

    func shortcut(for commandID: BrowserCommandID) -> BrowserKeyboardShortcut {
        overrides[commandID] ?? commandID.defaultDescriptor.shortcut
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

    @discardableResult
    func setShortcut(_ shortcut: BrowserKeyboardShortcut, for commandID: BrowserCommandID) -> Bool {
        guard conflictDescription(for: shortcut, excluding: commandID) == nil else {
            return false
        }

        if shortcut == commandID.defaultDescriptor.shortcut {
            overrides[commandID] = nil
        } else {
            overrides[commandID] = shortcut
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

    private static func loadOverrides(
        userDefaults: UserDefaults,
        decoder: JSONDecoder
    ) -> [BrowserCommandID: BrowserKeyboardShortcut] {
        guard let data = userDefaults.data(forKey: Key.overrides) else {
            return [:]
        }

        guard let rawOverrides = try? decoder.decode([String: BrowserKeyboardShortcut].self, from: data) else {
            return [:]
        }

        return rawOverrides.reduce(into: [:]) { result, item in
            guard let commandID = BrowserCommandID(rawValue: item.key) else {
                return
            }

            result[commandID] = item.value
        }
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
    ].reduce(into: [:]) { result, item in
        result[item.key.normalizedForMatching] = item.value
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

struct BrowserQuitWarningPolicy {
    let warnsBeforeQuitting: Bool
    let openTabCount: Int

    var shouldWarn: Bool {
        warnsBeforeQuitting && openTabCount > 0
    }
}
