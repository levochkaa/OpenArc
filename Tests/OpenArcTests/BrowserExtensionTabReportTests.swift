// BrowserExtensionTabReportTests.swift

import Foundation
import Testing

@MainActor private func makeModel() -> (BrowserChromeModel, FakeBrowserTabDriver) {
    let driver = FakeBrowserTabDriver()
    let defaults = UserDefaults(suiteName: "OpenArcExtensionTabTests.\(UUID().uuidString)")!
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(tabs: [
            .init(urlString: "https://pinned.example", placement: .spacePinned),
            .init(urlString: "https://one.example"),
            .init(urlString: "https://two.example"),
        ])),
        sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 2),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    for tab in model.tabs {
        driver.emitTabCreationState(id: tab.id, state: .ready)
    }
    return (model, driver)
}

@Test @MainActor func extensionsSeeFinishedTabsInOrderWithPinAndSelection() throws {
    let (model, driver) = makeModel()
    let unopenedPin = try #require(model.tabs.first { $0.placement == .spacePinned }?.id)
    let selected = try #require(model.selectedTabID)
    var reports = BrowserChromeModel.extensionTabReports(tabs: model.tabs, selectedTabID: selected)
    #expect(!reports.contains { $0.tabID == unopenedPin }, "A pin with no page yet has nothing to reach")
    #expect(reports.map(\.index) == Array(reports.indices))
    #expect(reports.filter(\.isActive).map(\.tabID) == [selected])

    model.selectTab(id: unopenedPin)
    driver.flushPendingCreateEvents()
    let pinned = try #require(model.tabs.first { $0.placement == .spacePinned }?.id)
    driver.emitTabCreationState(id: pinned, state: .ready)
    reports = BrowserChromeModel.extensionTabReports(tabs: model.tabs, selectedTabID: model.selectedTabID)
    #expect(reports.filter(\.isPinned).map(\.tabID) == [pinned])
    #expect(reports.filter(\.isActive).map(\.tabID) == [pinned])
}

@Test @MainActor func anExtensionSelectsAndClosesTabsOfItsWindowOnly() throws {
    let (model, driver) = makeModel()
    let other = try #require(model.tabs.first { $0.id != model.selectedTabID && $0.placement == .temporary }?.id)
    driver.tabIDsByBrowserIdentifier[7] = other
    #expect(model.handleExtensionTabAction(browserIdentifier: 7, closes: false))
    #expect(model.selectedTabID == other)
    #expect(!model.handleExtensionTabAction(browserIdentifier: 8, closes: false))
    driver.tabIDsByBrowserIdentifier[9] = "another-window"
    #expect(!model.handleExtensionTabAction(browserIdentifier: 9, closes: true))
    #expect(model.handleExtensionTabAction(browserIdentifier: 7, closes: true))
    #expect(driver.closedTabRequests.contains { $0.id == other })
}

@Test @MainActor func translationStaysInThePageWhenTheEngineCanDoIt() throws {
    let (model, driver) = makeModel()
    let tab = try #require(model.currentTab)
    driver.nextTranslationStart = .started
    #expect(model.translateCurrentPage())
    #expect(driver.translationRequests.map(\.tabID) == [tab.id])
    #expect(model.currentTab?.urlString == tab.urlString)
    driver.currentTranslationState = .translated
    #expect(model.translateCurrentPage())
    #expect(driver.revertedTranslations == [tab.id], "A second press shows the original")
    #expect(driver.translationRequests.count == 1)
}

@Test func translationNamesChineseWithItsRegion() {
    #expect(BrowserChromeModel.translationLanguage(forPreferredLanguage: "ru-RU") == "ru")
    #expect(BrowserChromeModel.translationLanguage(forPreferredLanguage: "zh-Hans-CN") == "zh-CN")
    #expect(BrowserChromeModel.translationLanguage(forPreferredLanguage: "zh-Hant-TW") == "zh-TW")
    #expect(BrowserChromeModel.translationLanguage(forPreferredLanguage: nil) == "en")
}
