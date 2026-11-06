// BrowserNewDocumentsTests.swift

import Foundation
import Testing

@MainActor struct BrowserNewDocumentsTests {
    @Test func shortQueriesOfferNothing() {
        #expect(BrowserNewDocument.matching("ne", app: .googleDocs).isEmpty)
    }

    @Test func thePreferredAppComesFirst() {
        let google = BrowserNewDocument.matching("new", app: .googleDocs)
        #expect(google.first == .googleDoc)
        let notion = BrowserNewDocument.matching("new", app: .notion)
        #expect(notion.first == .notionPage)
        #expect(notion.count == google.count, "Every kind stays reachable")
        #expect(Set(notion.map(\.urlString)).count == notion.count)
    }

    @Test func queriesNarrowTheList() {
        let sheets = BrowserNewDocument.matching("SHEET", app: .word)
        #expect(sheets.map(\.urlString) == ["https://sheet.new"])
    }

    @Test func choicesAreKept() throws {
        let suite = BrowserTestDefaults.suiteName("BrowserNewDocumentsTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = BrowserUserPreferencesStore(userDefaults: defaults)
        #expect(first.newDocumentsApp == .googleDocs)
        #expect(first.smallWindowLifetime == .twelveHours)
        first.newDocumentsApp = .word
        first.smallWindowLifetime = .never
        let second = BrowserUserPreferencesStore(userDefaults: defaults)
        #expect(second.newDocumentsApp == .word)
        #expect(second.smallWindowLifetime == .never)
    }

    @Test func theCommandBarOpensADocument() async {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.userPreferencesStore.newDocumentsApp = .notion
        f.model.presentCommandBar()
        f.model.commandBarModel.query = "notion"
        await f.model.commandBarModel.waitForPendingSuggestionLoad()
        let matches = f.model
            .commandBarModel
            .suggestions
            .filter { $0.resolvedURLString == "https://app.notion.com/new" }
        #expect(matches.count == 1)
        #expect(matches.first?.kind == .url)
    }

    @Test func allTabsMuteAndUnmute() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        #expect(f.model.isCommandBarActionAvailable(.muteAllTabs))
        #expect(!f.model.isCommandBarActionAvailable(.unmuteAllTabs))
        #expect(f.model.setAllTabsMuted(true))
        #expect(f.model.mutedTabSyncIDs.count == f.model.tabs.count)
        #expect(!f.model.isCommandBarActionAvailable(.muteAllTabs))
        #expect(f.model.isCommandBarActionAvailable(.unmuteAllTabs))
        #expect(f.model.setAllTabsMuted(false))
        #expect(f.model.mutedTabSyncIDs.isEmpty)
    }

    @Test func aWindowCanStartOnAGivenPage() throws {
        let driver = FakeBrowserTabDriver()
        let defaults = try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserNewDocumentsTests")))
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: nil),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.firstTabURLString = "https://link.example/"
        model.handleContextReady()
        #expect(driver.createdTabRequests.map(\.urlString) == ["https://link.example/"])
    }
}
