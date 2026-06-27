import AppKit
import Foundation
import Testing

@Test func settingsDefaultsAndPersistenceUseUserDefaults() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let store = BrowserUserPreferencesStore(userDefaults: userDefaults)
    #expect(store.automaticUpdatesEnabled)
    #expect(store.updateChannel == .stable)
    #expect(store.appearancePreference == .system)
    #expect(store.warnBeforeQuitting)
    #expect(store.searchEngine == .google)
    #expect(store.aiSearchProvider == .chatGPT)
    #expect(store.searchEngineSuggestionsEnabled)
    #expect(store.hapticFeedbackEnabled)
    #expect(store.restoreWindowsOnLaunch)
    #expect(store.pictureInPictureEnabled)
    #expect(store.bookmarksBarVisible)
    #expect(!store.siteURLToolbarEnabled)
    #expect(!store.siteToolbarShowsFullURL)
    #expect(store.blurredChromeBackgroundEnabled)
    #expect(store.batterySaverEnabled)
    #expect(store.pinnedExtensionIDs.isEmpty)
    #expect(BrowserSearchEngine.allCases == [
        .google,
        .microsoftBing,
        .yahoo,
        .duckDuckGo,
        .ecosia,
        .brave,
        .qwant,
        .yandex,
        .baidu,
    ])
    #expect(BrowserAISearchProvider.allCases == [.chatGPT, .claude, .gemini, .perplexity, .deepSeek])

    store.automaticUpdatesEnabled = false
    store.updateChannel = .beta
    store.appearancePreference = .dark
    store.warnBeforeQuitting = false
    store.searchEngine = .yandex
    store.aiSearchProvider = .deepSeek
    store.searchEngineSuggestionsEnabled = false
    store.hapticFeedbackEnabled = false
    store.restoreWindowsOnLaunch = false
    store.pictureInPictureEnabled = false
    store.bookmarksBarVisible = false
    store.siteURLToolbarEnabled = true
    store.siteToolbarShowsFullURL = true
    store.blurredChromeBackgroundEnabled = false
    store.batterySaverEnabled = false
    store.pinnedExtensionIDs = ["reader", "clipper"]

    let reloadedStore = BrowserUserPreferencesStore(userDefaults: userDefaults)
    #expect(!reloadedStore.automaticUpdatesEnabled)
    #expect(reloadedStore.updateChannel == .beta)
    #expect(reloadedStore.appearancePreference == .dark)
    #expect(!reloadedStore.warnBeforeQuitting)
    #expect(reloadedStore.searchEngine == .yandex)
    #expect(reloadedStore.aiSearchProvider == .deepSeek)
    #expect(!reloadedStore.searchEngineSuggestionsEnabled)
    #expect(!reloadedStore.hapticFeedbackEnabled)
    #expect(!reloadedStore.restoreWindowsOnLaunch)
    #expect(!reloadedStore.pictureInPictureEnabled)
    #expect(!reloadedStore.bookmarksBarVisible)
    #expect(reloadedStore.siteURLToolbarEnabled)
    #expect(reloadedStore.siteToolbarShowsFullURL)
    #expect(!reloadedStore.blurredChromeBackgroundEnabled)
    #expect(!reloadedStore.batterySaverEnabled)
    #expect(reloadedStore.pinnedExtensionIDs == ["reader", "clipper"])
}

@Test func legacyPerplexitySearchEnginePreferenceMigratesToAIProvider() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    userDefaults.set("perplexity", forKey: "browser.settings.searchEngine")

    let store = BrowserUserPreferencesStore(userDefaults: userDefaults)
    #expect(store.searchEngine == .google)
    #expect(store.aiSearchProvider == .perplexity)
}

@Test func shortcutOverridesPersistBlockConflictsAndReset() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let store = BrowserShortcutStore(userDefaults: userDefaults)
    let customShortcut = BrowserKeyboardShortcut("u")

    #expect(!store.setShortcut(BrowserCommands.newTab.shortcut, for: .openSettings))
    #expect(!store.setShortcut(BrowserKeyboardShortcut("q"), for: .newTab))
    #expect(store.setShortcut(customShortcut, for: .newTab))
    #expect(store.shortcut(for: .newTab) == customShortcut)
    #expect(store.isCustomized(.newTab))

    let reloadedStore = BrowserShortcutStore(userDefaults: userDefaults)
    #expect(reloadedStore.shortcut(for: .newTab) == customShortcut)
    #expect(reloadedStore.conflictDescription(for: customShortcut, excluding: .openSettings) == BrowserCommands.newTab
        .menuTitle)

    reloadedStore.resetShortcut(for: .newTab)
    #expect(reloadedStore.shortcut(for: .newTab) == BrowserCommands.newTab.shortcut)
    #expect(!reloadedStore.isCustomized(.newTab))

    reloadedStore.setShortcut(customShortcut, for: .newTab)
    reloadedStore.resetAllShortcuts()
    #expect(reloadedStore.shortcut(for: .newTab) == BrowserCommands.newTab.shortcut)
    #expect(reloadedStore.shortcut(for: .toggleBookmarksBar) == BrowserCommands.toggleBookmarksBar.shortcut)
}

@Test func unassignedCommandShortcutsDoNotConflict() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let store = BrowserShortcutStore(userDefaults: userDefaults)
    let customShortcut = BrowserKeyboardShortcut("e", modifiers: [.command, .option])

    #expect(store.shortcut(for: .clearCacheAndRefresh) == .unassigned)
    #expect(store.shortcut(for: .clearCookiesAndRefresh) == .unassigned)
    #expect(store.conflictDescription(for: .unassigned, excluding: .clearCacheAndRefresh) == nil)
    #expect(store.setShortcut(customShortcut, for: .clearCacheAndRefresh))
    #expect(!store.setShortcut(customShortcut, for: .clearCookiesAndRefresh))

    store.resetShortcut(for: .clearCacheAndRefresh)
    #expect(store.shortcut(for: .clearCacheAndRefresh) == .unassigned)
}

@Test func layoutIndependentBridgeUsesShortcutOverrides() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let store = BrowserShortcutStore(userDefaults: userDefaults)
    #expect(store.setShortcut(BrowserKeyboardShortcut("b"), for: .newTab))

    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 11,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "и",
        shortcutResolver: store
    )

    #expect(command == .newTab)
}

@Test func layoutIndependentBridgeRoutesNewIncognitoWindowShortcut() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 45,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "т"
    )

    #expect(command == .newIncognitoWindow)
}

@Test func layoutIndependentBridgeRoutesToggleBookmarksBarShortcut() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 11,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "и"
    )

    #expect(command == .toggleBookmarksBar)
}

@Test func settingsRoutesMatchChromiumButtonDestinations() {
    #expect(BrowserInternalPageRouting.historyURL.absoluteString == "tb://history")
    #expect(BrowserInternalPageRouting.bookmarksURL.absoluteString == "tb://bookmarks/")
    #expect(BrowserSettingsRoute.searchEnginesURL.absoluteString == "tb://settings/searchEngines")
    #expect(BrowserSettingsRoute.privacyURL.absoluteString == "tb://settings/privacy")
    #expect(BrowserSettingsRoute.passwordManagerURL.absoluteString == "tb://password-manager/passwords")
    #expect(BrowserSettingsRoute.paymentsURL.absoluteString == "tb://settings/payments")
    #expect(BrowserSettingsRoute.notificationsURL.absoluteString == "tb://settings/content/notifications")
    #expect(BrowserSettingsRoute.rootURL.absoluteString == "tb://settings/")
    #expect(BrowserSettingsRoute.languageURL.absoluteString == "tb://settings/languages")
    #expect(BrowserSettingsRoute.extensionShortcutsURL.absoluteString == "tb://extensions/shortcuts")
}

@Test func quitWarningPolicyRequiresEnabledPreferenceAndOpenTabs() {
    #expect(BrowserQuitWarningPolicy(warnsBeforeQuitting: true, openTabCount: 1).shouldWarn)
    #expect(!BrowserQuitWarningPolicy(warnsBeforeQuitting: true, openTabCount: 0).shouldWarn)
    #expect(!BrowserQuitWarningPolicy(warnsBeforeQuitting: false, openTabCount: 3).shouldWarn)
}
