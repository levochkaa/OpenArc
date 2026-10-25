// BrowserSidebarDragFixtures.swift

import AppKit
import Testing

@MainActor final class SidebarDragFixture {
    // MARK: Internal

    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()
    let store: InMemorySessionSnapshotStore

    init(
        pinned: [(String, String?)] = [("a", nil), ("b", nil)],
        temporary: [String] = ["x", "y"],
        apps: [String] = [],
        folders: [BrowserPinnedTabFolderSessionSnapshot] = [],
    ) {
        let defaults = UserDefaults(suiteName: "SidebarDragFixture.\(UUID().uuidString)")!
        let prefs = BrowserUserPreferencesStore(userDefaults: defaults)
        prefs.hapticFeedbackEnabled = false
        let tabs = apps.map { BrowserTabSessionSnapshotTab(
            id: $0,
            urlString: "https://\($0).example",
            userTitleOverride: $0,
            placement: .app,
            spaceID: "s",
        ) }
            + pinned.map { BrowserTabSessionSnapshotTab(
                id: $0.0,
                urlString: "https://\($0.0).example",
                userTitleOverride: $0.0,
                placement: .spacePinned,
                spaceID: "s",
                pinnedFolderID: $0.1,
            ) }
            + temporary.map { BrowserTabSessionSnapshotTab(
                id: $0,
                urlString: "https://\($0).example",
                userTitleOverride: $0,
                spaceID: "s",
            ) }
        self.store = InMemorySessionSnapshotStore(loadedSnapshot: .init(
            spaces: [
                .init(id: "s", title: "Space", systemImageName: "square.grid.2x2"),
                .init(id: "t", title: "Other", systemImageName: "book"),
            ],
            pinnedTabFolders: folders, tabs: tabs,
        ))
        self.model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: prefs,
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            // A fixed clock keeps activity dates stable when activating a dragged tab crosses a second.
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
    }

    func id(_ name: String) -> String { model.tabs.first { $0.userTitleOverride == name }!.id }
    func item(_ name: String) -> BrowserSidebarItemID { .tab(id(name)) }
    func payload(_ names: String...) -> BrowserSidebarDragPayload {
        .init(primary: item(names[0]), tabIDs: Set(names.map(id)))
    }

    func folderPayload(_ id: String) -> BrowserSidebarDragPayload {
        let tree = BrowserSidebarTabTree(snapshot: model.sidebarSnapshot)
        let folder = tree.folders[id]!
        return .init(primary: .folder(id), tabIDs: Set(tree.tabIDs(in: .pinned(folder.spaceID, folderID: id))))
    }

    func names(_ tabs: [BrowserChromeModel.Tab]) -> [String] { tabs.map { $0.userTitleOverride! } }
    func pinnedNames() -> [String] { names(model.spacePinnedTabs) }
}
