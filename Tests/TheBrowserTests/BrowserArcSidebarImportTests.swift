import AppKit
import Testing

// MARK: - BrowserArcSidebarImportTests

@Suite(.serialized)
@MainActor struct BrowserArcSidebarImportTests {
    /// The shape of Arc's StorableSidebar.json with made-up content:
    /// ordered dictionaries are flat arrays of alternating keys and values.
    static let sample = """
    {"sidebar": {"containers": [{"global": {}}, {
      "spaces": ["S1", {"id": "S1", "title": "Work", "customInfo": {"iconType": {"icon": "briefcase"}},
                        "containerIDs": ["unpinned", "U1", "pinned", "P1"]},
                 "S2", {"id": "S2", "title": "  ", "customInfo": {}, "containerIDs": ["pinned", "P2", "unpinned", "U2"]}],
      "topAppsContainerIDs": [{"default": true}, "TOP", {"custom": {}}, "OTHER"],
      "items": [
        "P1", {"id": "P1", "childrenIds": ["T1", "F1", "SPLIT", "NOTE"], "data": {"itemContainer": {}}},
        "T1", {"id": "T1", "title": "Mail", "childrenIds": [], "data": {"tab": {"savedURL": "https://mail.example", "savedTitle": "Inbox"}}},
        "F1", {"id": "F1", "title": "Docs", "childrenIds": ["T2", "F2"], "data": {"list": {"customInfo": {"iconType": {"icon": "flash"}}}}},
        "T2", {"id": "T2", "title": null, "childrenIds": [], "data": {"tab": {"savedURL": "https://docs.example", "savedTitle": "Docs"}}},
        "F2", {"id": "F2", "title": "Empty", "childrenIds": [], "data": {"list": {}}},
        "SPLIT", {"id": "SPLIT", "childrenIds": ["T3", "T4"], "data": {"splitView": {}}},
        "T3", {"id": "T3", "childrenIds": [], "data": {"tab": {"savedURL": "https://left.example"}}},
        "T4", {"id": "T4", "childrenIds": [], "data": {"tab": {"savedURL": ""}}},
        "NOTE", {"id": "NOTE", "childrenIds": [], "data": {"note": {}}},
        "U1", {"id": "U1", "childrenIds": ["T5"], "data": {"itemContainer": {}}},
        "T5", {"id": "T5", "childrenIds": [], "data": {"tab": {"savedURL": "https://today.example"}}},
        "P2", {"id": "P2", "childrenIds": ["F1"], "data": {"itemContainer": {}}},
        "TOP", {"id": "TOP", "childrenIds": ["T6"], "data": {"itemContainer": {}}},
        "T6", {"id": "T6", "childrenIds": [], "data": {"tab": {"savedURL": "https://calendar.example", "savedTitle": "Calendar"}}}
      ]}]}}
    """

    @Test func parsesSpacesPinnedTreesAndFavorites() throws {
        let sidebar = try BrowserArcSidebar(data: Data(Self.sample.utf8))
        #expect(sidebar.spaces.map(\.title) == ["Work", nil])
        #expect(sidebar.spaces.first?.icon == "briefcase")
        let docs = BrowserArcSidebar.Node.folder(
            title: "Docs",
            icon: "flash",
            children: [
                .tab(title: nil, savedTitle: "Docs", urlString: "https://docs.example"),
                .folder(title: "Empty", icon: nil, children: []),
            ]
        )
        #expect(sidebar.spaces.first?.pinned == [
            .tab(title: "Mail", savedTitle: "Inbox", urlString: "https://mail.example"),
            docs,
            .tab(title: nil, savedTitle: nil, urlString: "https://left.example"),
        ], "Today tabs, notes and empty URLs are skipped; a split adds its tabs")
        #expect(sidebar.favorites == [.tab(title: nil, savedTitle: "Calendar", urlString: "https://calendar.example")])
        #expect(sidebar.pinnedTabCount == 4)
        #expect(throws: BrowserArcSidebar.ImportError.unreadable) { try BrowserArcSidebar(data: Data("[]".utf8)) }
    }

    @Test func importAddsDormantSpacesFoldersAndFavorites() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let selectedSpace = f.model.selectedSpaceID
        let sidebar = try BrowserArcSidebar(data: Data(Self.sample.utf8))
        let createdBefore = f.driver.createdTabRequests.count
        let result = f.model.importArcSidebar(sidebar)
        #expect(result == .init(spaceCount: 2, pinnedTabCount: 4, folderCount: 4, favoriteCount: 1))
        #expect(f.model.selectedSpaceID == selectedSpace, "The current Space stays selected")
        let work = try #require(f.model.spaces.first { $0.title == "Work" })
        #expect(work.systemImageName == "briefcase")
        let workTabs = f.model.tabs.filter { $0.spaceID == work.id }
        #expect(workTabs.map(\.urlString) == ["https://mail.example", "https://docs.example", "https://left.example"])
        #expect(workTabs.allSatisfy { $0.placement == .spacePinned && $0.pinnedURLString != nil })
        #expect(workTabs.first?.userTitleOverride == "Mail")
        let folders = f.model.pinnedTabFolders.filter { $0.spaceID == work.id }
        #expect(folders.map(\.title) == ["Docs", "Empty"])
        #expect(folders.last?.parentFolderID == folders.first?.id, "Nested folders keep their parent")
        #expect(folders.first?.systemImageName == nil, "Arc icons that are not SF Symbols fall back")
        #expect(workTabs[1].pinnedFolderID == folders.first?.id)
        #expect(f.model.appTabs.map(\.urlString).contains("https://calendar.example"))
        #expect(f.driver.createdTabRequests.count == createdBefore, "Imported tabs stay dormant until selected")
        let saved = try #require(f.store.savedSnapshots.last)
        #expect(saved.tabs.contains { $0.urlString == "https://docs.example" && $0.placement == .spacePinned })
        #expect(saved.spaces?.contains { $0.title == "Work" } == true)

        #expect(f.model.importArcSidebar(sidebar).spaceCount == 1, "Work is already there; the untitled Space is not")

        // Selecting a dormant tab loads it.
        let mail = try #require(f.model.tabs.first { $0.urlString == "https://mail.example" && $0.spaceID == work.id })
        f.model.selectSpace(id: work.id)
        #expect(f.model.tabs.first { $0.syncID == mail.syncID }?.id != mail.id,
                "Opening a Space of unloaded tabs loads the one it shows")
        #expect(f.model.selectedTabID == f.model.tabs.first { $0.syncID == mail.syncID }?.id)
    }
}
