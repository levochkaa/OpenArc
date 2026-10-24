import AppKit
import Testing

// MARK: - BrowserTabPageTitleTests

@Suite(.serialized)
@MainActor struct BrowserTabPageTitleTests {
    @Test func pageTitlesSurviveTheStoreButNotEquality() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PageTitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("session.sqlite")
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "s", title: "Space", systemImageName: "star")],
            tabs: [
                .init(id: "a", urlString: "https://a.example", placement: .spacePinned, spaceID: "s", pageTitle: "Inbox"),
                .init(id: "b", urlString: "https://b.example", spaceID: "s"),
            ]
        )
        do {
            let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            store.saveSnapshot(snapshot)
        }
        let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let tabs = try #require(reopened.loadSnapshot()?.tabs)
        #expect(tabs.map(\.pageTitle) == ["Inbox", nil])
        #expect(
            BrowserTabSessionSnapshotTab(id: "a", urlString: "https://a.example", pageTitle: "Old")
                == BrowserTabSessionSnapshotTab(id: "a", urlString: "https://a.example", pageTitle: "New"),
            "Titles lag behind pages, so stored-tab checks ignore them"
        )
    }

    @Test func pinnedTabsRestoreUnloadedExceptTheShownTabFavoritesAndSplitPanes() throws {
        let store = InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [.init(id: "s", title: "Space", systemImageName: "star")],
            tabs: [
                .init(id: "fav", urlString: "https://fav.example", placement: .app, spaceID: "s"),
                .init(id: "p1", urlString: "https://p1.example/inbox", pinnedURLString: "https://p1.example",
                      placement: .spacePinned, spaceID: "s", pageTitle: "Inbox"),
                .init(id: "p2", urlString: "https://p2.example", placement: .spacePinned, spaceID: "s"),
                .init(id: "p3", urlString: "https://p3.example", placement: .spacePinned, spaceID: "s"),
                .init(id: "t", urlString: "https://t.example", spaceID: "s"),
            ],
            splitGroups: [.init(id: "g", tabIDs: ["p3", "t"])]
        ))
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 4),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            extensionManager: FakeBrowserExtensionManager(), windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        #expect(driver.createdTabRequests.map(\.urlString) == ["https://fav.example", "https://p3.example", "https://t.example"])
        let p1 = try #require(model.tabs.first { $0.syncID == "p1" })
        #expect(p1.displayTitle == "Inbox", "An unloaded tab shows its last title")
        model.selectTab(id: p1.id)
        #expect(driver.createdTabRequests.last?.urlString == "https://p1.example/inbox", "It reopens at the page it showed")
    }

    @Test func restoredTabsShowTheirLastTitleBeforeThePageLoads() throws {
        let store = InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [.init(id: "s", title: "Space", systemImageName: "star")],
            tabs: [.init(id: "a", urlString: "https://a.example", placement: .spacePinned, spaceID: "s", pageTitle: "Inbox")]
        ))
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            extensionManager: FakeBrowserExtensionManager(), windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        model.handleContextReady()
        #expect(model.tabs.first?.displayTitle == "Inbox")
        #expect(driver.createdTabRequests.isEmpty == false, "The only tab is shown, so it loads")
        driver.flushPendingCreateEvents()
        try driver.emitUpdate(id: #require(model.tabs.first?.id), title: "Inbox (2)")
        model.createNewSpace()
        #expect(store.savedSnapshots.last?.tabs.first?.pageTitle == "Inbox (2)", "Later writes carry the current title")
    }
}

// MARK: - BrowserLazySpaceSelectionTests

@Suite(.serialized)
@MainActor struct BrowserLazySpaceSelectionTests {
    @Test func switchingSpacesLoadsTheRememberedUnloadedPinnedTab() throws {
        let store = InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "s", title: "One", systemImageName: "star"),
                .init(id: "t", title: "Two", systemImageName: "book", selectedTabIndex: 0),
            ],
            tabs: [
                .init(id: "a", urlString: "https://a.example", spaceID: "s"),
                .init(id: "pinned", urlString: "https://pinned.example", placement: .spacePinned, spaceID: "t"),
                .init(id: "today", urlString: "https://today.example", spaceID: "t"),
            ]
        ))
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            extensionManager: FakeBrowserExtensionManager(), windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        #expect(!driver.createdTabRequests.contains { $0.urlString == "https://pinned.example" })
        model.selectSpace(id: "t")
        let selected = try #require(model.tabs.first { $0.id == model.selectedTabID })
        #expect(selected.syncID == "pinned", "The Space shows its remembered tab, now loaded")
        #expect(driver.createdTabRequests.last?.urlString == "https://pinned.example")
    }
}
