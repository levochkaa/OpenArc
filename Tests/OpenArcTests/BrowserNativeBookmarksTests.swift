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
            #expect(!view.chevron.isHidden, "What doesn't fit goes under the chevron")
            #expect(!view.overflowItems.isEmpty)
            #expect(try #require(scroll.documentView).frame.width <= scroll.frame.width)
            let hidden = view.overflowItems.compactMap { view.buttons[$0.id] }
            try #expect(hidden.allSatisfy(\.isHidden))
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
            let list = BrowserBookmarkFolderListView(
                interactions: view.interactions,
                folderID: "nested",
                baseIndex: 0,
                level: 1,
            )
            list.update(nested.children)
            #expect(list.items.map(\.title) == ["Leaf"])
            try #require(list.rows["leaf"]).onClick(nil)
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

    @Test func aDropBetweenItemsOrInsideAFolderIsReadFromThePointer() {
        let page = BrowserBookmarkItem(
            id: "a",
            kind: .bookmark,
            title: "A",
            urlString: "https://a.example",
            children: [],
        )
        let folder = BrowserBookmarkItem(id: "f", kind: .folder, title: "F", urlString: nil, children: [])
        let spans: [(item: BrowserBookmarkItem, start: CGFloat, end: CGFloat)] = [(page, 0, 100), (folder, 100, 200)]
        #expect(BrowserBookmarkDrop.location(at: 10, spans: spans, folderID: nil) == .between(folderID: nil, index: 0))
        #expect(BrowserBookmarkDrop.location(at: 90, spans: spans, folderID: nil) == .between(folderID: nil, index: 1))
        #expect(BrowserBookmarkDrop.location(at: 110, spans: spans, folderID: nil) == .between(folderID: nil, index: 1))
        #expect(BrowserBookmarkDrop.location(at: 150, spans: spans, folderID: nil) == .into(folderID: "f"))
        #expect(BrowserBookmarkDrop.location(at: 190, spans: spans, folderID: nil) == .between(folderID: nil, index: 2))
        #expect(BrowserBookmarkDrop.location(at: 500, spans: spans, folderID: "p", baseIndex: 3) == .between(
            folderID: "p",
            index: 5,
        ))
    }

    @Test func aTypedAddressGetsASchemeAndNonsenseIsRefused() {
        #expect(BrowserBookmarkEditor.normalizedAddress(" example.com/a ") == "https://example.com/a")
        #expect(BrowserBookmarkEditor.normalizedAddress("http://example.com") == "http://example.com")
        #expect(BrowserBookmarkEditor.normalizedAddress("   ") == nil)
        #expect(BrowserBookmarkEditor.normalizedAddress("not an address") == nil)
    }

    // MARK: Private

    private func withModel(_ body: (BrowserChromeModel, FakeBrowserTabDriver) throws -> Void) throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("NativeBookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = BrowserTestDefaults.suiteName("OpenArcNativeBookmarksTests")
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
