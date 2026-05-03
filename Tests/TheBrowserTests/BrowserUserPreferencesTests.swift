import AppKit
import Foundation
import Testing

@Test func settingsDefaultsAndPersistenceUseUserDefaults() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let store = BrowserUserPreferencesStore(userDefaults: userDefaults)
    #expect(store.automaticUpdatesEnabled)
    #expect(store.warnBeforeQuitting)
    #expect(store.searchEngine == .google)
    #expect(store.searchEngineSuggestionsEnabled)
    #expect(store.hapticFeedbackEnabled)
    #expect(store.restoreWindowsOnLaunch)
    #expect(store.pictureInPictureEnabled)

    store.automaticUpdatesEnabled = false
    store.warnBeforeQuitting = false
    store.searchEngine = .yandex
    store.searchEngineSuggestionsEnabled = false
    store.hapticFeedbackEnabled = false
    store.restoreWindowsOnLaunch = false
    store.pictureInPictureEnabled = false

    let reloadedStore = BrowserUserPreferencesStore(userDefaults: userDefaults)
    #expect(!reloadedStore.automaticUpdatesEnabled)
    #expect(!reloadedStore.warnBeforeQuitting)
    #expect(reloadedStore.searchEngine == .yandex)
    #expect(!reloadedStore.searchEngineSuggestionsEnabled)
    #expect(!reloadedStore.hapticFeedbackEnabled)
    #expect(!reloadedStore.restoreWindowsOnLaunch)
    #expect(!reloadedStore.pictureInPictureEnabled)
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

@Test func settingsRoutesMatchChromiumButtonDestinations() {
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
