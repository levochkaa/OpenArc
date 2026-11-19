// BrowserMobileSharedSidebarTests.swift

import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func sharedSidebarRendersMixedFoldersAndPersistsDisclosure() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        f.loadSidebar()

        #expect(f.sidebar.numberOfSections(in: f.table) == 3)
        #expect((0..<3).map { f.sidebar.tableView(f.table, titleForHeaderInSection: $0) } == [
            "Favorites", "Pinned", "Today",
        ])
        #expect(f.rowIDs(section: 0) == ["browser.tab.favorite"])
        #expect(f.rowIDs(section: 1) == [
            "browser.folder.folder", "browser.tab.child", "browser.folder.nested",
            "browser.tab.nested-child", "browser.tab.loose", "browser.folder.empty",
        ])
        #expect(f.rowIDs(section: 2) == ["browser.tab.today"])
        #expect(f.cells(section: 1).map(\.indentationLevel) == [0, 1, 1, 2, 0, 0])

        f.sidebar.tableView(f.table, didSelectRowAt: .init(row: 0, section: 1))
        #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.tab.loose", "browser.folder.empty"])
        #expect(f.document.snapshot.pinnedTabFolders?.first { $0.id == "folder" }?.isExpanded == false)
        #expect(try f.store.loadSnapshotStrict()?.pinnedTabFolders?.first { $0.id == "folder" }?.isExpanded == false)
        f.sidebar.tableView(f.table, didSelectRowAt: .init(row: 0, section: 1))
        #expect(f.rowIDs(section: 1).count == 6)

        f.sidebar.tableView(f.table, didSelectRowAt: .init(row: 3, section: 1))
        #expect(f.workspace.selectedTabID == "nested-child")
        #expect(f.engine.selectedID == f.workspace.selectedTab?.runtimeID)
        #expect(f.cells(section: 1)[3].accessoryType == .checkmark)
        #expect(await f.workspace.shutdown())
    }

    @Test func spacePickerKeepsFavoritesAndUsesLatestSpaceIdentity() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        f.loadSidebar()
        let picker = try #require(f.sidebar.tableView.tableHeaderView?.subviews.first {
            $0.accessibilityIdentifier == "browser.spaces"
        } as? UIButton)
        let menu = try #require(picker.menu)
        let target = try #require(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "Second" })
        #expect(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "First" }?.state == .on)
        #expect(menu.children.compactMap { $0 as? UIMenu }.flatMap(\.children).contains { $0.title == "New Space" })

        // Keep the action captured before another scene renames this Space.
        #expect(f.document.renameSpace(id: "second", title: "Renamed Space"))
        performSidebarAction(target)
        #expect(f.workspace.selectedSpaceID == "second")
        #expect(picker.configuration?.title == "Renamed Space")
        #expect(f.rowIDs(section: 0) == ["browser.tab.favorite"])
        #expect(f.rowIDs(section: 1).isEmpty)
        #expect(f.rowIDs(section: 2) == ["browser.tab.other"])
        #expect(f.workspace.tabs.count == 6)
        #expect(try f.store.loadSnapshotStrict()?.tabs.count == 6)
        #expect(await f.workspace.shutdown())
    }

    @Test func bottomBarListsSpacesAndSwitchesBetweenThem() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        f.loadSidebar()
        let items = f.sidebar.toolbarItems ?? []
        let first = try #require(items.first { $0.accessibilityIdentifier == "browser.space.first" })
        let second = try #require(items.first { $0.accessibilityIdentifier == "browser.space.second" })
        #expect(first.accessibilityTraits.contains(.selected))
        #expect(!second.accessibilityTraits.contains(.selected))
        #expect(items.contains { $0.accessibilityIdentifier == "browser.archive" } == f.workspace.supportsArchive)

        try performSidebarAction(#require(second.primaryAction))
        #expect(f.workspace.selectedSpaceID == "second")
        let selected = (f.sidebar.toolbarItems ?? []).filter { $0.accessibilityTraits.contains(.selected) }
        #expect(selected.map(\.accessibilityIdentifier) == ["browser.space.second"])

        f.sidebar.showSpace(offset: -1)
        #expect(f.workspace.selectedSpaceID == "first")
        f.sidebar.showSpace(offset: -1)
        #expect(f.workspace.selectedSpaceID == "first", "There is no Space before the first")
        #expect(await f.workspace.shutdown())
    }

    @Test func twoFingersPageBetweenSpacesWhileOneFingerSwipesRows() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        f.loadSidebar()
        let pans = (f.sidebar.tableView.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        let spacePan = try #require(pans.first { $0.delegate === f.sidebar })
        #expect(spacePan.minimumNumberOfTouches == 2, "One finger stays with the rows' swipe to close")
        #expect(spacePan.allowedScrollTypesMask.contains(.continuous), "Two fingers on a trackpad page too")
        #expect(await f.workspace.shutdown())
    }

    @Test func phoneSheetHasNoSelectButtonAndStartsRowsUnderTheName() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        let sheet = BrowserMobileTabsViewController(workspace: f.workspace, isPhoneSheet: true)
        let close = UIBarButtonItem(systemItem: .close)
        sheet.navigationItem.rightBarButtonItem = close
        sheet.loadViewIfNeeded()
        sheet.render()
        #expect(sheet.navigationItem.rightBarButtonItems == [close], "Rows close from their own menu")
        #expect((sheet.tableView.tableHeaderView?.bounds.height ?? 1) < 1)
        #expect(sheet.tableView.estimatedSectionHeaderHeight == 0)
        #expect(await f.workspace.shutdown())
    }

    @Test func contextActionsPinFavoriteAndMoveTheSameStableTab() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        f.loadSidebar()
        let runtimeID = try #require(f.workspace.tabs.first { $0.id == "today" }?.runtimeID)
        let pin = try sidebarAction(in: #require(f.sidebar.tabMenu(id: "today")), path: ["Pin"])
        performSidebarAction(pin)
        #expect(f.document.snapshot.tabs.first { $0.id == "today" }?.placement == .spacePinned)
        #expect(f.document.snapshot.tabs.first { $0.id == "today" }?.pinnedURLString == "https://example.com/today")

        let favorite = try sidebarAction(in: #require(f.sidebar.tabMenu(id: "today")), path: ["Add to Favorites"])
        performSidebarAction(favorite)
        #expect(f.document.snapshot.tabs.first { $0.id == "today" }?.placement == .app)
        #expect(f.rowIDs(section: 0).contains("browser.tab.today"))

        let move = try sidebarAction(in: #require(f.sidebar.tabMenu(id: "today")), path: ["Move To", "Second", "Today"])
        performSidebarAction(move)
        #expect(f.document.snapshot.tabs.first { $0.id == "today" }?.placement == .temporary)
        #expect(f.document.snapshot.tabs.first { $0.id == "today" }?.spaceID == "second")
        #expect(!f.rowIDs(section: 0).contains("browser.tab.today"))
        #expect(!f.rowIDs(section: 2).contains("browser.tab.today"))
        #expect(f.workspace.tabs.first { $0.id == "today" }?.runtimeID == runtimeID)
        #expect(f.engine.closedIDs.isEmpty)
        #expect(try f.store.loadSnapshotStrict() == f.document.snapshot)
        #expect(await f.workspace.shutdown())
    }

    @Test func pinnedRemoveAndFolderMoveMenusPreserveIdentityAcrossTreeChanges() async throws {
        let f = try SharedSidebarFixture()
        defer { f.cleanup() }
        await f.workspace.restore()
        f.loadSidebar()
        let runtimeID = try #require(f.workspace.tabs.first { $0.id == "loose" }?.runtimeID)
        let cell = f.cells(section: 1)[4]
        let swipe = try #require(f.sidebar
            .tableView(
                f.table, trailingSwipeActionsConfigurationForRowAt: .init(row: 4, section: 1),
            )?.actions
            .first)
        #expect(swipe.title == "Remove")
        #expect(f.document.removeTab(id: "child"))
        var removed = false
        swipe.handler(swipe, cell) { removed = $0 }
        #expect(removed)
        #expect(!f.document.snapshot.tabs.contains { $0.id == "loose" })
        #expect(f.document.snapshot.tabs.contains { $0.id == "nested-child" })
        #expect(f.document.snapshot.tabs.contains { $0.id == "favorite" })
        #expect(f.engine.closedIDs.contains(runtimeID))

        let menu = try #require(f.sidebar.folderMenu(id: "folder"))
        let destinations = try #require(menu.children.compactMap { $0 as? UIMenu }.first { $0.title == "Move To" })
        let source = try #require(destinations.children.compactMap { $0 as? UIMenu }.first { $0.title == "First" })
        #expect(!source.children.contains { $0.title == "Folder" || $0.title == "Folder / Nested" })
        let move = try sidebarAction(in: menu, path: ["Move To", "Second", "Pinned"])
        performSidebarAction(move)
        #expect(f.document.snapshot.pinnedTabFolders?.first { $0.id == "folder" }?.spaceID == "second")
        #expect(f.document.snapshot.pinnedTabFolders?.first { $0.id == "nested" }?.spaceID == "second")
        #expect(f.document.snapshot.tabs.first { $0.id == "nested-child" }?.spaceID == "second")
        #expect(f.rowIDs(section: 1) == ["browser.folder.empty"])
        #expect(try f.store.loadSnapshotStrict() == f.document.snapshot)
        #expect(await f.workspace.shutdown())
    }
}

@MainActor private func performSidebarAction(_ action: UIAction) {
    // Exercise the UIKit action handler without presenting a context menu or
    // relying on private APIs. The action is the one returned by the sidebar.
    let control = UIButton(type: .system)
    control.addAction(action, for: .touchUpInside)
    control.sendActions(for: .touchUpInside)
}

@MainActor private func sidebarAction(in menu: UIMenu, path: [String]) throws -> UIAction {
    let first = try #require(path.first)
    let child = try #require(menu.children.first { $0.title == first })
    if path.count == 1 {
        return try #require(child as? UIAction)
    }
    return try sidebarAction(in: #require(child as? UIMenu), path: Array(path.dropFirst()))
}

// MARK: - SharedSidebarFixture

@MainActor private final class SharedSidebarFixture {
    // MARK: Internal

    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let workspace: BrowserMobileWorkspace
    let root: BrowserMobileViewController
    let engine = SharedSidebarEngine()
    let directory: URL
    let preferences: UserDefaults
    let preferencesName: String

    var sidebar: BrowserMobileTabsViewController { root.tabsController }
    var table: UITableView { sidebar.tableView }

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("session.sqlite"))
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "first", title: "First", systemImageName: "globe"),
                .init(id: "second", title: "Second", systemImageName: "moon"),
            ],
            pinnedTabFolders: [
                .init(id: "folder", spaceID: "first", title: "Folder", pinnedSiblingRank: 0),
                .init(id: "nested", spaceID: "first", parentFolderID: "folder", title: "Nested", pinnedSiblingRank: 1),
                .init(id: "empty", spaceID: "first", title: "Empty", pinnedSiblingRank: 2),
            ],
            tabs: [
                .init(id: "favorite", urlString: "https://example.com/favorite", placement: .app, spaceID: "first"),
                .init(
                    id: "child",
                    urlString: "https://example.com/child",
                    placement: .spacePinned,
                    spaceID: "first",
                    pinnedFolderID: "folder",
                    pinnedSiblingRank: 0,
                ),
                .init(
                    id: "nested-child",
                    urlString: "https://example.com/nested",
                    placement: .spacePinned,
                    spaceID: "first",
                    pinnedFolderID: "nested",
                    pinnedSiblingRank: 0,
                ),
                .init(
                    id: "loose",
                    urlString: "https://example.com/loose",
                    placement: .spacePinned,
                    spaceID: "first",
                    pinnedSiblingRank: 1,
                ),
                .init(id: "today", urlString: "https://example.com/today", spaceID: "first"),
                .init(id: "other", urlString: "https://example.com/other", spaceID: "second"),
            ],
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        let document = try BrowserMobileProfileDocument(store: store, initialSnapshot: snapshot)
        self.document = document
        self.preferencesName = "SharedSidebarTests." + UUID().uuidString
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: "sidebar", profileLoader: { document }, preferences: preferences,
        )
        self.root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
    }

    func loadSidebar() {
        root.loadViewIfNeeded()
        sidebar.loadViewIfNeeded()
        sidebar.render()
    }

    func cells(section: Int) -> [UITableViewCell] {
        (0..<sidebar.tableView(table, numberOfRowsInSection: section)).map {
            sidebar.tableView(table, cellForRowAt: .init(row: $0, section: section))
        }
    }

    func rowIDs(section: Int) -> [String] { cells(section: section).compactMap(\.accessibilityIdentifier) }

    func cleanup() {
        engine.shutdown()
        preferences.removePersistentDomain(forName: preferencesName)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - SharedSidebarEngine

@MainActor private final class SharedSidebarEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var selectedID: String?
    var closedIDs = [String]()

    func createTab(id _: String, url _: URL) {}
    func selectTab(id: String?) { selectedID = id }
    func navigate(id _: String, url _: URL) {}
    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func closeTab(id: String) { closedIDs.append(id) }
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() { onEvent = nil
        onPopupCreated = nil
    }
}
