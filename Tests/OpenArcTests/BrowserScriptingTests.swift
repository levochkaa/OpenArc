// BrowserScriptingTests.swift

import AppKit
import Foundation
import Testing

@MainActor struct BrowserScriptingTests {
    // MARK: Internal

    @Test func aWindowListsItsSpacesAndTabs() {
        let (model, driver, window) = makeWindow()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        #expect(window.appleScriptSpaces.map(\.id) == model.spaces.map(\.id))
        #expect(window.appleScriptTabs.map(\.id) == model.tabs.map(\.id))
        #expect(window.activeTab?.id == model.selectedTabID)
        #expect(window.activeSpace?.id == model.selectedSpaceID)
        #expect(!window.isIncognito)
        #expect(window.mode == "normal")
    }

    @Test func aMadeTabOpensItsURLWhenInserted() {
        let (model, driver, window) = makeWindow()
        let count = model.tabs.count
        let tab = BrowserScriptTab()
        tab.URL = "https://example.com/"
        #expect(tab.pendingURLString == "https://example.com/")
        window.insertInAppleScriptTabs(tab)
        driver.flushPendingCreateEvents()
        #expect(model.tabs.count == count + 1)
        #expect(tab.pendingURLString == nil)
        #expect(tab.id == model.selectedTabID)
        #expect(tab.URL.hasPrefix("https://example.com"))
    }

    @Test func locationPinsAndUnpins() throws {
        let (model, driver, window) = makeWindow()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        let tab = try #require(window.activeTab)
        #expect(tab.location == "unpinned")
        tab.location = "pinned"
        #expect(tab.location == "pinned")
        tab.location = "unpinned"
        #expect(tab.location == "unpinned")
    }

    @Test func javaScriptStaysOffUntilAllowed() throws {
        let (model, driver, window) = makeWindow()
        model.createNewTab()
        driver.flushPendingCreateEvents()
        let tab = try #require(window.activeTab)
        let command = NSScriptCommand()
        command.arguments = ["javascript": "1+1"]
        #expect(!model.userPreferencesStore.allowsJavaScriptFromAppleEvents)
        #expect(tab.executeJavascript(command) == nil)
    }

    // MARK: Private

    private func makeWindow() -> (BrowserChromeModel, FakeBrowserTabDriver, BrowserScriptWindow) {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: "OpenArcScriptingTests.\(UUID().uuidString)")!
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(extensions: []),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        return (model, driver, BrowserScriptWindow(window: window, model: model))
    }
}
