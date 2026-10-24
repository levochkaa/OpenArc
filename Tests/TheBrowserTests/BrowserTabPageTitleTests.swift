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
        driver.flushPendingCreateEvents()
        try driver.emitUpdate(id: #require(model.tabs.first?.id), title: "Inbox (2)")
        model.createNewSpace()
        #expect(store.savedSnapshots.last?.tabs.first?.pageTitle == "Inbox (2)", "Later writes carry the current title")
    }
}
