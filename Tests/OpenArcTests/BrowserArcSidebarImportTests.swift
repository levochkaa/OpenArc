// BrowserArcSidebarImportTests.swift

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

    /// Arc binds each Space to a Chromium profile; the first profile's Spaces name none.
    static let profilesSample = """
    {"sidebar": {"containers": [{
      "spaces": ["S1", {"id": "S1", "title": "Home", "profile": {"default": true}, "containerIDs": []},
                 "S2", {"id": "S2", "title": "Work", "containerIDs": [],
                        "profile": {"custom": {"_0": {"machineID": "M", "directoryBasename": "Profile 2"}}}},
                 "S3", {"id": "S3", "title": "Side", "containerIDs": [],
                        "profile": {"custom": {"_0": {"directoryBasename": "Profile 3"}}}}],
      "items": []}]}}
    """

    @Test func parsesSpacesPinnedTreesAndFavorites() throws {
        let sidebar = try BrowserImportedSidebar(arcData: Data(Self.sample.utf8))
        #expect(sidebar.spaces.map(\.title) == ["Work", nil])
        #expect(sidebar.spaces.first?.icon == "briefcase")
        let docs = BrowserImportedSidebar.Node.folder(
            title: "Docs",
            icon: "bolt.fill",
            children: [
                .tab(title: nil, savedTitle: "Docs", urlString: "https://docs.example"),
                .folder(title: "Empty", icon: nil, children: []),
            ],
        )
        #expect(sidebar.spaces.first?.pinned == [
            .tab(title: "Mail", savedTitle: "Inbox", urlString: "https://mail.example"),
            docs,
            .tab(title: nil, savedTitle: nil, urlString: "https://left.example"),
        ], "Today tabs, notes and empty URLs are skipped; a split adds its tabs")
        #expect(sidebar.favorites == [.tab(title: nil, savedTitle: "Calendar", urlString: "https://calendar.example")])
        #expect(sidebar.pinnedTabCount == 4)
        #expect(throws: BrowserImportedSidebar.ImportError.unreadable) {
            try BrowserImportedSidebar(arcData: Data("[]".utf8))
        }
    }

    @Test func importAddsDormantSpacesFoldersAndFavorites() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let selectedSpace = f.model.selectedSpaceID
        let sidebar = try BrowserImportedSidebar(arcData: Data(Self.sample.utf8))
        let createdBefore = f.driver.createdTabRequests.count
        let result = f.model.importSidebar(sidebar)
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
        #expect(folders.first?.systemImageName == "bolt.fill", "Arc's icons come over as the closest symbols")
        #expect(workTabs[1].pinnedFolderID == folders.first?.id)
        #expect(f.model.appTabs.map(\.urlString).contains("https://calendar.example"))
        #expect(f.driver.createdTabRequests.count == createdBefore, "Imported tabs stay dormant until selected")
        let saved = try #require(f.store.savedSnapshots.last)
        #expect(saved.tabs.contains { $0.urlString == "https://docs.example" && $0.placement == .spacePinned })
        #expect(saved.spaces?.contains { $0.title == "Work" } == true)

        #expect(f.model.importSidebar(sidebar).spaceCount == 1, "Work is already there; the untitled Space is not")

        // Opening a Space of unloaded tabs shows none; selecting one loads it.
        let mail = try #require(f.model.tabs.first { $0.urlString == "https://mail.example" && $0.spaceID == work.id })
        f.model.selectSpace(id: work.id)
        #expect(f.model.selectedTabID == nil)
        #expect(f.driver.createdTabRequests.count == createdBefore)
        f.model.selectTab(id: mail.id)
        #expect(f.model.tabs.first { $0.syncID == mail.syncID }?.id != mail.id)
        #expect(f.model.selectedTabID == f.model.tabs.first { $0.syncID == mail.syncID }?.id)
    }

    @Test func importFromDiskReportsTheResultThenThatItIsAlreadyImported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = BrowserImportLocations(home: directory, applicationSupport: directory)
        let url = directory.appendingPathComponent("Arc/StorableSidebar.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sidebar = """
        {"sidebar": {"containers": [{"global": {}}, {
          "spaces": ["S1", {"id": "S1", "title": "Work", "containerIDs": ["pinned", "P1"]}],
          "topAppsContainerIDs": [],
          "items": [
            "P1", {"id": "P1", "childrenIds": ["T1"], "data": {"itemContainer": {}}},
            "T1", {"id": "T1", "childrenIds": [], "data": {"tab": {"savedURL": "https://mail.example"}}}
          ]}]}}
        """
        try Data(sidebar.utf8).write(to: url)
        let f = SidebarDragFixture(temporary: ["x"])
        let spaces = f.model.spaces.count
        let already = BrowserStrings.sidebarImportAlreadyImported(from: "Arc")
        #expect(f.model.importSidebarFromDisk(of: .arc, locations: locations) != already)
        #expect(f.model.spaces.count > spaces)
        #expect(f.model.importSidebarFromDisk(of: .arc, locations: locations) == already)
    }

    @Test func importFromDiskSaysWhyNothingCameIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = SidebarDragFixture(temporary: ["x"])
        let locations = BrowserImportLocations(home: directory, applicationSupport: directory)
        #expect(f.model.importSidebarFromDisk(of: .arc, locations: locations)
            == BrowserStrings.sidebarImportMissing(from: "Arc"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Arc"),
            withIntermediateDirectories: true,
        )
        try Data("{}".utf8).write(to: directory.appendingPathComponent("Arc/StorableSidebar.json"))
        #expect(f.model.importSidebarFromDisk(of: .arc, locations: locations)
            == BrowserStrings.sidebarImportUnreadable(from: "Arc"))
    }

    @Test func everyArcSpaceIconMapsToASymbolThatExists() throws {
        // Every icon name Arc's sidebar can store.
        let arcIcons = """
        star bookmark heart flag flash triangle medical notifications bulb shapes grid apps layers server albums copy
        folder fileTrayFull calendar mail checkbox document book chatBubbleEllipses people terminal construction square
        egg ellipse moon sunny planet leaf cloud paw bag gift bed restaurant barbell airplane musicalNote colorPallete
        video bandage code baseball cloudOutline map bonfire pizza skull receipt thumbsUp train rss github linear figma
        search
        """.split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(arcIcons.count == 61)
        let unmapped = Set(arcIcons).subtracting(BrowserImportedSidebar.arcIconSymbols.keys)
        #expect(unmapped == ["skull", "github", "linear", "figma"], "Only those have no symbol")
        for (name, symbol) in BrowserImportedSidebar.arcIconSymbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(name) → \(symbol)")
        }
        let sidebar = try BrowserImportedSidebar(arcData: Data("""
        {"sidebar": {"containers": [{"spaces": [
          "A", {"title": "A", "customInfo": {"iconType": {"icon": "bulb"}}},
          "B", {"title": "B", "customInfo": {"iconType": {"icon": "github"}}}
        ], "items": []}]}}
        """.utf8))
        #expect(sidebar.spaces.map(\.icon) == ["lightbulb.fill", nil], "Unknown names get the default icon")
    }

    @Test func eachSpaceGoesToTheProfileChosenForItsArcProfile() throws {
        let sidebar = try BrowserImportedSidebar(arcData: Data(Self.profilesSample.utf8))
        #expect(sidebar.spaces.map(\.profileDirectory) == [nil, "Profile 2", "Profile 3"])

        let f = SidebarDragFixture(temporary: ["x"])
        f.model.profileDirectories = BrowserSpaceProfileDirectories(
            windowProfile: "Default",
            profiles: { [] },
            cachePath: { "/profiles/\($0)" },
        )
        let result = f.model.importSidebar(sidebar, profiles: BrowserSidebarProfileChoice(
            skipped: ["Profile 3"],
            targets: ["Profile 2": "Profile 7"],
        ))
        #expect(result.spaceCount == 2, "Side's profile was left out")
        let home = try #require(f.model.spaces.first { $0.title == "Home" })
        let work = try #require(f.model.spaces.first { $0.title == "Work" })
        #expect(f.model.spaceProfilesByID[home.id] == nil, "Arc's first profile fills the window's")
        #expect(f.model.spaceProfilesByID[work.id] == "Profile 7")
        #expect(!f.model.spaces.contains { $0.title == "Side" })
    }

    @Test func anotherProfileGetsItsOwnOpenArcProfileOnce() async throws {
        let f = SidebarDragFixture(temporary: ["x"])
        var created = [BrowserProfile]()
        f.model.profileDirectories = BrowserSpaceProfileDirectories(
            windowProfile: "Default",
            profiles: { created },
            cachePath: { "/profiles/\($0)" },
            createNamedProfile: { name in
                let profile = BrowserProfile(directoryName: "Profile \(created.count + 1)", name: name)
                created.append(profile)
                return profile.id
            },
        )
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var personal = BrowserProfileImporter(
            source: .firefox,
            profileDirectory: home.appendingPathComponent("a.default"),
        )
        personal.profileName = "Personal"
        var work = BrowserProfileImporter(source: .firefox, profileDirectory: home.appendingPathComponent("b.work"))
        work.profileName = "Work"
        let spacesBefore = f.model.spaces.count

        _ = await f.model.importProfiles([personal, work], items: [.bookmarks])
        #expect(created.isEmpty, "Bookmarks alone come into this window's profile")

        _ = await f.model.importProfiles([personal, work], items: [.signIns])
        #expect(created.map(\.name) == ["Work"], "The first profile fills the window's")
        let space = try #require(f.model.spaces.last)
        #expect(f.model.spaces.count == spacesBefore + 1)
        #expect(space.title == "Work", "Its sign-ins get a Space to be used in")
        #expect(f.model.spaceProfilesByID[space.id] == "Profile 1")

        _ = await f.model.importProfiles([personal, work], items: [.signIns])
        #expect(created.count == 1, "A second import finds the profile it made")
        #expect(f.model.spaces.count == spacesBefore + 1)
    }
}
