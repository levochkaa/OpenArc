// BrowserNativeBookmarksTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeBookmarksTests {
    // MARK: Internal

    @Test func bookmarkActionsRefreshStarAndReuseExistingButtons() throws {
        try withModel { model, _ in
            let view = BrowserBookmarksBarNSView(model: model)
            #expect(!view.star.isSelected)
            view.star.performClick(nil)
            view.refresh()
            #expect(view.star.isSelected)
            let item = try #require(model.bookmarksModel.bookmarkBarItems.first)
            let button = try #require(view.buttons[item.id])
            #expect(model.renameBookmark(id: item.id, title: "Renamed"))
            view.refresh()
            #expect(view.buttons[item.id] === button)
            #expect(button.accessibilityLabel() == "Renamed")
            view.star.performClick(nil)
            view.refresh()
            #expect(!view.star.isSelected)
            #expect(view.buttons.isEmpty)
        }
    }

    @Test func overflowingBookmarksKeepStarVisibleAndClipLongTitles() throws {
        try withModel { model, _ in
            for index in 0..<10 {
                _ = model.createBookmarkFolder(title: String(
                    repeating: "Long folder \(index) ",
                    count: 10,
                ))
            }
            let view = BrowserBookmarksBarNSView(model: model)
            view.frame = NSRect(x: 0, y: 0, width: 320, height: BrowserChromeLayout.bookmarksBarHeight)
            view.layoutSubtreeIfNeeded()
            #expect(view.bounds.contains(view.star.frame))
            #expect(view.buttons
                .values
                .allSatisfy { $0.frame.width <= BrowserChromeLayout.bookmarksBarItemMaximumWidth })
            let scroll = try #require(view.subviews.compactMap { $0 as? NSScrollView }.first)
            #expect(scroll.frame.maxX < view.star.frame.minX)
            #expect(try #require(scroll.documentView).frame.width > scroll.frame.width)
        }
    }

    @Test func recursiveFolderMenusOpenLeafAndDeleteOnlyRequestedFolder() throws {
        try withModel { model, driver in
            let leaf = BrowserBookmarkItem(
                id: "leaf",
                kind: .bookmark,
                title: "Leaf",
                urlString: "https://leaf.example",
                children: [],
            )
            let nested = BrowserBookmarkItem(
                id: "nested",
                kind: .folder,
                title: "Nested",
                urlString: nil,
                children: [leaf],
            )
            let folder = BrowserBookmarkItem(
                id: "root",
                kind: .folder,
                title: "Root",
                urlString: nil,
                children: [nested],
            )
            #expect(BrowserBookmarkFolderDestination.destinations(in: [folder]) == [
                .init(id: "root", title: "Root"), .init(id: "nested", title: "Root / Nested"),
            ])
            let view = BrowserBookmarksBarNSView(model: model)
            let leafMenu = try #require(view.folderMenu(folder).items.first?.submenu)
            #expect(leafMenu.items.map(\.title) == ["Leaf"])
            leafMenu.performActionForItem(at: 0)
            #expect(driver.activeTabNavigationURLStrings.last == "https://leaf.example")
            let folderID = try #require(model.createBookmarkFolder(title: "Delete me"))
            _ = model.createBookmarkFolder(title: "Keep me")
            view.refresh()
            let owned = try #require(model.bookmarksModel.bookmarkBarItems.first { $0.id == folderID })
            let menu = view.itemMenu(owned)
            try menu
                .performActionForItem(at: #require(menu.items
                        .firstIndex { $0.title == BrowserStrings.bookmarksDeleteAction }))
            view.refresh()
            #expect(model.bookmarksModel.bookmarkBarItems.map(\.displayTitle) == ["Keep me"])
        }
    }

    // MARK: Private

    private func withModel(_ body: (BrowserChromeModel, FakeBrowserTabDriver) throws -> Void) throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("NativeBookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "OpenArcNativeBookmarksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FakeBrowserTabDriver()
        let bookmarks =
            BrowserBookmarksModel(store: BrowserChromiumBookmarkStore(profileDirectoryCandidates: [directory]))
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(
                loadedSnapshot: .init(tabURLStrings: ["https://example.com/page"]),
            ),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            bookmarksModel: bookmarks,
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        try body(model, driver)
    }
}
