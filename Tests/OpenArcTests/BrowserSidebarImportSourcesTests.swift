// BrowserSidebarImportSourcesTests.swift

import Foundation
import GRDB
import Testing

// MARK: - SidebarHome

/// A made-up home folder whose Application Support holds other browsers' files.
private struct SidebarHome {
    let url: URL

    var locations: BrowserImportLocations { BrowserImportLocations(home: url) }

    init() throws {
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent("SidebarHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult func write(_ contents: String, at path: String, modified: Date? = nil) throws -> URL {
        try write(Data(contents.utf8), at: path, modified: modified)
    }

    @discardableResult func write(_ data: Data, at path: String, modified: Date? = nil) throws -> URL {
        let file = locations.applicationSupport.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }

    /// A SQLite database at a path below Application Support.
    func database(at path: String, _ fill: (Database) throws -> Void) throws {
        let file = locations.applicationSupport.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: file.path)
        try queue.write(fill)
        try queue.close()
    }
}

private typealias Node = BrowserImportedSidebar.Node

private func tab(_ url: String, _ savedTitle: String? = nil, title: String? = nil) -> Node {
    .tab(title: title, savedTitle: savedTitle, urlString: url)
}

// MARK: - Cra

/// Cra's `sidebar.json`, with made-up content in its shape.
private let craSample = """
{"version": 1,
 "spaceOrder": ["S2", "s1"],
 "favoritesContainerID": null,
 "profiles": [{"id": "aaaa-1", "name": "Work"}],
 "spaces": [
  {"id": "S1", "title": "Personal", "emoji": "🌱", "favoritesContainerID": "FAV", "pinnedContainerID": "P1",
   "todayContainerID": "T1", "theme": {"colors": ["#336699", "#FFFFFF"], "intensity": 0.5, "noise": 0.2}},
  {"id": "S2", "title": "Work", "emoji": "", "symbol": "briefcase", "favoritesContainerID": "FAV",
   "pinnedContainerID": "P2", "todayContainerID": "T2", "profileID": "AAAA-1"},
  {"id": "S3", "title": "Gone profile", "emoji": "", "pinnedContainerID": "P3", "profileID": "BBBB-2"},
  {"id": "S4", "title": "Blank window", "emoji": "", "pinnedContainerID": "P4", "standaloneWindowID": "W"}
 ],
 "items": [
  {"id": "FAV", "children": ["B1"], "data": {"container": {"_0": {"favorites": {"spaceID": "S1"}}}}},
  {"id": "B1", "parentID": "FAV", "children": [],
   "data": {"tab": {"_0": {"url": "https://mail.example/inbox/4", "savedURL": "https://mail.example/", "savedTitle": "Mail"}}}},
  {"id": "P1", "children": ["D1", "C2", "SP", "NOTE"], "data": {"container": {"_0": {"pinned": {"spaceID": "S1"}}}}},
  {"id": "D1", "parentID": "P1", "title": "Docs", "folderSymbol": "book", "children": ["C1", "D2"], "data": {"folder": {}}},
  {"id": "C1", "children": [], "title": "Spec",
   "data": {"tab": {"_0": {"url": "https://docs.example/now", "savedURL": "https://docs.example/", "savedTitle": "Docs"}}}},
  {"id": "D2", "title": "Empty", "children": [], "data": {"folder": {}}},
  {"id": "C2", "children": [], "data": {"tab": {"_0": {"url": "https://only-url.example/", "savedURL": ""}}}},
  {"id": "SP", "children": ["C3", "C4"], "data": {"split": {"_0": {"orientation": "horizontal"}}}},
  {"id": "C3", "children": [], "data": {"tab": {"_0": {"savedURL": "https://left.example/"}}}},
  {"id": "C4", "children": [], "data": {"tab": {"_0": {"savedURL": "not a url"}}}},
  {"id": "NOTE", "children": [], "data": {"easel": {"_0": {}}}},
  {"id": "P2", "children": ["C5"], "data": {"container": {"_0": {"pinned": {"spaceID": "S2"}}}}},
  {"id": "C5", "children": [], "data": {"tab": {"_0": {"savedURL": "https://work.example/"}}}},
  {"id": "T1", "children": ["C6"], "data": {"container": {"_0": {"today": {"spaceID": "S1"}}}}},
  {"id": "C6", "children": [], "data": {"tab": {"_0": {"savedURL": "https://today.example/"}}}}
 ]}
"""

@Test func craSpacesKeepTheirOrderFoldersSplitsProfilesAndSharedFavorites() throws {
    let sidebar = try BrowserImportedSidebar(craData: Data(craSample.utf8))
    #expect(sidebar.spaces.map(\.title) == ["Work", "Personal", "Gone profile"], "Blank-window Spaces stay out")
    let work = sidebar.spaces[0]
    let personal = sidebar.spaces[1]
    #expect(work.icon == "briefcase")
    #expect(work.profileDirectory == "Profile AAAA-1")
    #expect(personal.profileDirectory == nil)
    #expect(sidebar.spaces[2].profileDirectory == nil, "A profile Cra no longer lists falls back to the first")
    #expect(personal.icon == BrowserIconImage.name(emoji: "🌱"))
    #expect(personal.theme?.colors.count == 2)
    #expect(personal.theme?.intensity == 0.5)
    #expect(personal.pinned == [
        .folder(title: "Docs", icon: "book", children: [
            tab("https://docs.example/", "Docs", title: "Spec"),
            .folder(title: "Empty", icon: nil, children: []),
        ]),
        tab("https://only-url.example/"),
        tab("https://left.example/"),
    ], "Saved pages win, a split adds its tabs, and Today and unknown kinds stay out")
    #expect(sidebar.favorites == [tab("https://mail.example/", "Mail")], "A shared list comes once")
    #expect(sidebar.profileNames == ["Profile AAAA-1": "Work"])
    #expect(throws: BrowserImportedSidebar.ImportError.unreadable) {
        try BrowserImportedSidebar(craData: Data("[]".utf8))
    }
}

// MARK: - Crest

private let crestSample = """
{"defaultSpaceID": {"rawValue": "11111111-1111-1111-1111-111111111111"},
 "spaces": [
  {"id": {"rawValue": "11111111-1111-1111-1111-111111111111"},
   "profile": {"id": "aaaaaaaa-0000-0000-0000-000000000001"},
   "name": "Work", "symbol": "crest.emoji:🛠️",
   "folders": [
    {"id": {"rawValue": "F1"}, "location": "saved", "title": "Docs"},
    {"id": {"rawValue": "F2"}, "location": "saved", "title": "Specs", "parentID": {"rawValue": "F1"}, "symbol": "doc"},
    {"id": {"rawValue": "F3"}, "location": "saved", "title": "Anchored", "orderAnchorTabID": {"rawValue": "T4"}},
    {"id": {"rawValue": "F4"}, "location": "saved", "title": "Last"},
    {"id": {"rawValue": "F5"}, "location": "current", "title": "Open folder"}
   ],
   "tabs": [
    {"id": {"rawValue": "T0"}, "title": "Mail", "url": "https://mail.example/inbox", "savedURL": "https://mail.example/",
     "placement": "pinned"},
    {"id": {"rawValue": "T1"}, "title": "Home", "url": "https://home.example/", "placement": "saved",
     "customTitle": "My home"},
    {"id": {"rawValue": "T2"}, "title": "Spec", "url": "https://docs.example/spec", "placement": "saved",
     "folderID": {"rawValue": "F2"}},
    {"id": {"rawValue": "T3"}, "title": "Guide", "url": "https://docs.example/guide", "placement": "saved",
     "folderID": {"rawValue": "F1"}},
    {"id": {"rawValue": "T4"}, "title": "News", "url": "https://news.example/", "placement": "current"},
    {"id": {"rawValue": "T5"}, "title": "Board", "url": "https://board.example/", "placement": "someday"},
    {"id": {"rawValue": "T6"}, "title": "Settings", "placement": "saved", "nativeContent": {"kind": "settings"}},
    {"id": {"rawValue": "T7"}, "title": "Start", "placement": "saved"}
   ]},
  {"id": {"rawValue": "22222222-2222-2222-2222-222222222222"},
   "profile": {"id": "BBBBBBBB-0000-0000-0000-000000000002"},
   "sharedProfileID": "aaaaaaaa-0000-0000-0000-000000000001",
   "name": "Work notes", "symbol": "note.text", "branding": {"iconStyle": "simpleSymbol"}, "folders": [], "tabs": []},
  {"id": {"rawValue": "33333333-3333-3333-3333-333333333333"},
   "profile": {"id": "CCCCCCCC-0000-0000-0000-000000000003"},
   "name": "Home", "symbol": "house", "branding": {"iconStyle": "layeredCrest"}, "folders": [], "tabs": []}
 ]}
"""

private func writeCrestSession(_ json: String, in home: SidebarHome) throws {
    try home.database(at: "Crest/ControlPlane/session.sqlite") { db in
        try db.execute(sql: "CREATE TABLE checkpoint (part TEXT PRIMARY KEY, data BLOB NOT NULL)")
        try db.execute(sql: "INSERT INTO checkpoint VALUES ('journal', x'7B7D')")
        try db.execute(sql: "INSERT INTO checkpoint VALUES ('core', ?)", arguments: [Data(json.utf8)])
    }
}

@Test func crestSavedTabsBecomePinnedFoldersAndItsPinnedGridBecomesFavorites() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeCrestSession(crestSample, in: home)
    let sidebar = try BrowserImportedSidebar.load(.crest, locations: home.locations)
    #expect(sidebar.spaces.map(\.title) == ["Work", "Work notes", "Home"])
    let work = sidebar.spaces[0]
    #expect(work.icon == BrowserIconImage.name(emoji: "🛠️"))
    #expect(sidebar.spaces[1].icon == "note.text")
    #expect(sidebar.spaces[2].icon == nil, "A Space shown as a crest does not show its symbol")
    #expect(work.pinned == [
        tab("https://home.example/", "Home", title: "My home"),
        .folder(title: "Docs", icon: nil, children: [
            .folder(title: "Specs", icon: "doc", children: [tab("https://docs.example/spec", "Spec")]),
            tab("https://docs.example/guide", "Guide"),
        ]),
        tab("https://board.example/", "Board"),
        .folder(title: "Anchored", icon: nil, children: []),
        .folder(title: "Last", icon: nil, children: []),
    ], "A folder sits at its first tab; unknown placements read as saved; open tabs and native pages stay out")
    #expect(sidebar.favorites == [tab("https://mail.example/", "Mail")])
    #expect(sidebar.spaces.map(\.profileDirectory) == [
        "Crest-AAAAAAAA-0000-0000-0000-000000000001",
        "Crest-AAAAAAAA-0000-0000-0000-000000000001",
        "Crest-CCCCCCCC-0000-0000-0000-000000000003",
    ], "A Space sharing sign-ins browses in the other's profile")
    #expect(sidebar.profileNames["Crest-AAAAAAAA-0000-0000-0000-000000000001"] == "Work, Work notes")

    #expect(throws: BrowserImportedSidebar.ImportError.missing) {
        try BrowserImportedSidebar.load(
            .crest,
            locations: BrowserImportLocations(home: home.url.appendingPathComponent("elsewhere")),
        )
    }
    #expect(throws: BrowserImportedSidebar.ImportError.unreadable) {
        try BrowserImportedSidebar(crestCheckpoint: Data("{}".utf8))
    }
}

@Test func crestAndCraProfilesTakeTheNamesTheirSidebarsGiveThem() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeCrestSession(crestSample, in: home)
    try home.write("{}", at: "Crest/Chromium/Default/Preferences")
    try home.write("{}", at: "Crest/Chromium/Crest-AAAAAAAA-0000-0000-0000-000000000001/Preferences")
    try home.write("{}", at: "Crest/Chromium/Crest-CCCCCCCC-0000-0000-0000-000000000003/Preferences")
    let crest = BrowserBookmarkImportSource.crest.importProfiles(in: home.locations)
    #expect(Set(crest.map(\.name)) == ["Work, Work notes", "Home"], "Crest's Default serves private windows")

    try home.write(craSample, at: "Cra/sidebar.json")
    try home.write("{}", at: "Cra/Chromium/Default/Preferences")
    try home.write("{}", at: "Cra/Chromium/Profile AAAA-1/Preferences")
    let cra = BrowserBookmarkImportSource.cra.importProfiles(in: home.locations)
    #expect(Set(cra.map(\.name)) == ["Default", "Work"])
}

@MainActor @Test func crestSpacesGoToTheProfilesChosenForTheirFolders() throws {
    let sidebar = try BrowserImportedSidebar(crestCheckpoint: Data(crestSample.utf8))
    let f = SidebarDragFixture(temporary: ["x"])
    f.model.profileDirectories = BrowserSpaceProfileDirectories(
        windowProfile: "Default",
        profiles: { [] },
        cachePath: { "/profiles/\($0)" },
        createProfile: { nil },
    )
    let result = f.model.importSidebar(sidebar, profiles: BrowserSidebarProfileChoice(
        skipped: ["Crest-CCCCCCCC-0000-0000-0000-000000000003"],
        targets: [:],
    ))
    #expect(result.spaceCount == 2)
    #expect(result.favoriteCount == 1)
    #expect(!f.model.spaces.contains { $0.title == "Home" }, "Its profile was left out")
    let work = try #require(f.model.spaces.first { $0.title == "Work" })
    #expect(f.model.spaceProfilesByID[work.id] == nil, "The first profile chosen fills the window's")
    let folders = f.model.pinnedTabFolders.filter { $0.spaceID == work.id }
    #expect(folders.map(\.title) == ["Docs", "Specs", "Anchored", "Last"])
}

// MARK: - Yab

private let yabSpaces = """
[{"id": "00000000-0000-0000-0000-000000000001", "name": "Personal", "icon": "🏠", "ownSignIns": false},
 {"id": "6F1C0000-0000-0000-0000-000000000002", "name": "Work", "icon": "briefcase", "ownSignIns": true,
  "paint": {"swatch": "custom", "color": "#3366AA", "grain": false, "grainAmount": 0, "transparency": 0}}]
"""

private func writeYab(in home: SidebarHome, folder: String = "Yab") throws {
    try home.write(yabSpaces, at: "\(folder)/spaces.json")
    try home.write("""
    {"tabs": [
      {"url": "https://mail.example/inbox/4", "title": "Inbox", "pin": "M", "home": "https://mail.example/",
       "homeTitle": "Mail"},
      {"url": "https://news.example/", "title": "News"}
    ], "active": 1}
    """, at: "\(folder)/session.json")
    try home.write("""
    {"tabs": [
      {"url": "https://docs.example/a?x", "title": "Spec now", "kept": true, "home": "https://docs.example/a",
       "homeTitle": "Spec", "name": "The spec", "folder": "F2", "folderName": "Specs",
       "folderPath": [{"id": "F1", "name": "Projects", "mark": "hammer"}]},
      {"url": "https://board.example/", "title": "Board", "kept": true},
      {"url": "https://docs.example/b", "title": "Guide", "kept": true, "folder": "F1", "folderName": "Projects"},
      {"url": "https://today.example/", "title": "Today"}
    ], "active": -1}
    """, at: "\(folder)/session-6F1C0000-0000-0000-0000-000000000002.json")
    try home.write("""
    {"tabs": [{"url": "https://calendar.example/", "title": "Calendar", "pin": "C"}], "active": 0}
    """, at: "\(folder)/session-00000000-0000-0000-0000-000000000A11.json")
}

@Test func yabKeptTabsBecomePinnedFoldersAndItsPinsBecomeFavorites() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeYab(in: home)
    let sidebar = try BrowserImportedSidebar.load(.yab, locations: home.locations)
    #expect(sidebar.spaces.map(\.title) == ["Personal", "Work"])
    #expect(sidebar.spaces[0].icon == BrowserIconImage.name(emoji: "🏠"))
    #expect(sidebar.spaces[0].pinned.isEmpty, "Today's tabs stay out")
    #expect(sidebar.spaces[1].icon == "briefcase")
    #expect(sidebar.spaces[1].theme?.colors.count == 1)
    #expect(sidebar.spaces[1].pinned == [
        .folder(title: "Projects", icon: "hammer", children: [
            .folder(title: "Specs", icon: nil, children: [tab("https://docs.example/a", "Spec", title: "The spec")]),
            tab("https://docs.example/b", "Guide"),
        ]),
        tab("https://board.example/", "Board"),
    ])
    #expect(sidebar.favorites == [
        tab("https://calendar.example/", "Calendar"),
        tab("https://mail.example/", "Mail"),
    ], "Pins every Space shares come first")
}

@Test func yabFilesAreFoundInItsEarlierFolderAndGiveBookmarksAndMergedHistory() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeYab(in: home, folder: "Fast")
    try home.write("""
    [{"id": "1", "title": "Dev", "children": [{"id": "2", "title": "MDN", "url": "https://developer.mozilla.org/",
      "added": 785000000}]}, {"id": "3", "title": "Loose", "url": "https://loose.example/"}]
    """, at: "Fast/bookmarks.json")
    try home.write("""
    [{"url": "https://github.com/", "key": "github.com", "title": "GitHub", "count": 2, "last": 700000000, "typed": 1},
     {"url": "https://news.example/", "key": "news.example", "title": "News", "count": 1, "last": 600000000}]
    """, at: "Fast/history.json")
    try home.write("""
    [{"url": "https://github.com/", "key": "github.com", "title": "GitHub — new", "count": 3, "last": 800000000}]
    """, at: "Fast/history-6F1C0000-0000-0000-0000-000000000002.json")

    let directory = try #require(BrowserBookmarkImportSource.yab.webKitAppDirectory(in: home.locations))
    #expect(directory.lastPathComponent == "Fast")
    #expect(try BrowserImportedSidebar.load(.yab, locations: home.locations).spaces.count == 2)
    #expect(BrowserWebKitAppImport.bookmarkItems(of: .yab, directory: directory) == [
        BrowserBookmarkImportItem(title: "Dev", urlString: nil, children: [
            BrowserBookmarkImportItem(title: "MDN", urlString: "https://developer.mozilla.org/", children: []),
        ]),
        BrowserBookmarkImportItem(title: "Loose", urlString: "https://loose.example/", children: []),
    ])
    let history = BrowserWebKitAppImport.history(of: .yab, directory: directory)
    #expect(history.map(\.urlString) == ["https://github.com/", "https://news.example/"])
    #expect(history.first?.title == "GitHub — new")
    #expect(history.first?.visitCount == 5)
    #expect(history.first?.typedCount == 1)
    #expect(history.first?.lastVisit == 800_000_000 + Date.timeIntervalBetween1970AndReferenceDate)
}

// MARK: - Search

private func writeSearch(in home: SidebarHome) throws {
    try home.write("""
    [{"id": "00000000-0000-0000-0000-000000000001", "name": "Personal", "colour": 0},
     {"id": "5A1E0000-0000-0000-0000-000000000002", "name": "Work", "colour": 1, "icon": "briefcase",
      "gradient": {"colours": ["#3366FF", "#AA44CC"], "angle": 135, "grain": false}},
     {"id": "77AB0000-0000-0000-0000-000000000003", "name": "Client", "colour": 4, "profile": "D00D0000-0000-0000-0000-000000000004"}]
    """, at: "Search/spaces.json")
    try home.write("""
    [{"id": "00000000-0000-0000-0000-0000000000A1", "name": "Personal", "home": "00000000-0000-0000-0000-000000000001"},
     {"id": "D00D0000-0000-0000-0000-000000000004", "name": "Client", "home": "77AB0000-0000-0000-0000-000000000003"}]
    """, at: "Search/profiles.json")
    try home.write("""
    {"5A1E0000-0000-0000-0000-000000000002": [
       {"id": "P1", "letter": "L", "home": "https://linear.example/", "title": "Linear", "listed": true, "folder": "F1"},
       {"id": "P2", "letter": "D", "home": "https://docs.example/", "title": "Docs", "listed": true, "name": "Handbook"},
       {"id": "P3", "letter": "S", "home": "https://square.example/", "title": "Square"}],
     "shared": [{"id": "P0", "letter": "G", "home": "https://mail.example/", "title": "Mail"}],
     "shared:D00D0000-0000-0000-0000-000000000004": [{"id": "P9", "letter": "S", "home": "https://chat.example/", "title": "Chat"}]}
    """, at: "Search/pins.json")
    try home.write("""
    {"5A1E0000-0000-0000-0000-000000000002": [
       {"id": "F1", "name": "Tickets", "parent": "F0", "collapsed": true},
       {"id": "F0", "name": "Eng"},
       {"id": "FEED", "name": "Feed", "feed": "https://feed.example/rss"}]}
    """, at: "Search/pin-folders.json")
}

@Test func searchListedPinsBecomePinnedFoldersAndSharedPinsBecomeFavorites() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeSearch(in: home)
    let sidebar = try BrowserImportedSidebar.load(.search, locations: home.locations)
    #expect(sidebar.spaces.map(\.title) == ["Personal", "Work", "Client"])
    let work = sidebar.spaces[1]
    #expect(work.icon == "briefcase")
    #expect(work.theme?.colors.count == 2)
    #expect(work.pinned == [
        .folder(title: "Eng", icon: nil, children: [
            .folder(title: "Tickets", icon: nil, children: [tab("https://linear.example/", "Linear")]),
        ]),
        tab("https://docs.example/", "Docs", title: "Handbook"),
    ], "Folders come first at each level, and live feed folders stay out")
    #expect(sidebar.favorites == [
        tab("https://mail.example/", "Mail"),
        tab("https://chat.example/", "Chat"),
        tab("https://square.example/", "Square"),
    ])
}

@Test func searchBookmarksOfSeveralProfilesEachKeepAFolderAndHistoryMerges() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeSearch(in: home)
    try home.write("""
    [{"id": "1", "title": "News", "url": "https://news.example/"}]
    """, at: "Search/bookmarks.json")
    try home.write("""
    [{"id": "2", "title": "Docs", "children": [{"id": "3", "title": "API", "url": "https://api.example/"}]}]
    """, at: "Search/bookmarks-D00D0000-0000-0000-0000-000000000004.json")
    try home.write("""
    [{"url": "https://news.example/", "key": "https://news.example/", "title": "News", "count": 4, "last": 700000000}]
    """, at: "Search/history.json")
    let directory = try #require(BrowserBookmarkImportSource.search.webKitAppDirectory(in: home.locations))
    let bookmarks = try #require(BrowserWebKitAppImport.bookmarkItems(of: .search, directory: directory))
    #expect(bookmarks.map(\.title) == ["Personal", "Client"])
    #expect(bookmarks[1].children.first?.children.first?.urlString == "https://api.example/")
    #expect(BrowserWebKitAppImport.history(of: .search, directory: directory).map(\.visitCount) == [4])
}

// MARK: - Vane

private let vaneData = "Library/Containers/io.github.notnaki.vane/Data/Library"

private func writeVane(in home: SidebarHome) throws {
    let support = "\(vaneData)/Application Support/Vane"
    let root = home.url.path + "/"
    func write(_ contents: String, _ path: String) throws {
        let url = URL(fileURLWithPath: root + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    try write("""
    {"profiles": [{"id": "00000000-0000-0000-0000-000056616E65", "name": "Personal", "colorHex": "#6E7DD2"},
                  {"id": "9B2E0000-0000-0000-0000-000000000002", "name": "Work", "colorHex": "#4CAF6E"}],
     "activeID": "00000000-0000-0000-0000-000056616E65"}
    """, "\(support)/profiles.json")
    try write("""
    [{"id": "C0FF0000-0000-0000-0000-000000000001", "name": "Personal",
      "profileID": "00000000-0000-0000-0000-000056616E65", "tabURLs": ["https://news.example/"],
      "pinnedURLs": ["https://legacy.example/"], "pinnedTabURLs": ["https://figma.example/", "https://linear.example/"],
      "colorHex": "#4CAF6E", "icon": "🌿"},
     {"id": "C0FF0000-0000-0000-0000-000000000002", "name": "Plain", "profileID": "00000000-0000-0000-0000-000056616E65",
      "tabURLs": [], "pinnedURLs": [], "pinnedTabURLs": ["https://plain.example/"], "icon": "cloud"}]
    """, "\(support)/spaces.json")
    try write("""
    [{"id": "D1D10000-0000-0000-0000-000000000003", "name": "Templated", "profileID": "9B2E0000-0000-0000-0000-000000000002",
      "tabURLs": [], "pinnedURLs": [],
      "layout": {"tabs": [{"id": "A0000000-0000-0000-0000-000000000001", "url": "https://wiki.example/page",
                           "kind": 1, "title": "Wiki", "home": "https://wiki.example/", "customName": "Team wiki"}],
                 "pins": {"entries": [
                   {"row": {"folder": {"_0": {"id": "E0000000-0000-0000-0000-000000000001", "name": "Team", "icon": "person.2"}}}},
                   {"row": {"tab": {"_0": "A0000000-0000-0000-0000-000000000001"}},
                    "parent": "E0000000-0000-0000-0000-000000000001"}]},
                 "today": {"entries": []}, "splits": []}}]
    """, "\(support)/spaces-9b2e0000-0000-0000-0000-000000000002.json")
    try write("[]", "\(support)/spacestate.json")
    let shape = """
    {"entries": [{"row": {"folder": {"_0": {"id": "F1", "name": "Design", "icon": "🎨"}}}},
                 {"row": {"tab": {"_0": "https://figma.example/"}}, "parent": "F1"},
                 {"row": {"tab": {"_0": "https://linear.example/"}}}]}
    """
    let preferences: [String: Any] = [
        "pinnedTabs": ["https://mail.example/"],
        "pinShape.C0FF0000-0000-0000-0000-000000000001": Data(shape.utf8),
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: root + "\(vaneData)/Preferences"),
        withIntermediateDirectories: true,
    )
    try plist.write(to: URL(fileURLWithPath: root + "\(vaneData)/Preferences/io.github.notnaki.vane.plist"))

    for (suffix, rows) in [("", 1), ("-9b2e0000-0000-0000-0000-000000000002", 2)] {
        let queue = try DatabaseQueue(path: root + "\(support)/vane\(suffix).db")
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', at REAL NOT NULL);
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '',
                at REAL NOT NULL, folder_id TEXT);
            CREATE TABLE bookmark_folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL,
                created_at REAL NOT NULL);
            INSERT INTO bookmark_folders VALUES ('FA', 'Reading', 1, 0), ('FB', 'Tools', 0, 0);
            INSERT INTO bookmarks VALUES (1, 'https://read.example/', 'Read', 2, 'fa');
            INSERT INTO bookmarks VALUES (2, 'https://tool.example/', 'Tool', 1, 'FB');
            INSERT INTO bookmarks VALUES (3, 'https://loose.example/', 'Loose', 3, NULL);
            INSERT INTO visits VALUES (1, 'https://news.example/', 'Old', 1000);
            INSERT INTO visits VALUES (2, 'https://news.example/', 'New', 2000);
            """)
            if rows > 1 {
                try db.execute(sql: "INSERT INTO visits VALUES (3, 'https://news.example/', 'Newest', 3000)")
            }
        }
        try queue.close()
    }
}

@Test func vaneIsFoundByItsContainerAloneAndReadOnlyWhenImported() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try FileManager.default.createDirectory(
        at: home.url.appendingPathComponent("Library/Containers/io.github.notnaki.vane"),
        withIntermediateDirectories: true,
    )
    let profiles = BrowserBookmarkImportSource.vane.importProfiles(in: home.locations)
    #expect(profiles.map(\.name) == ["Vane"])
    #expect(profiles.first?.lastUsed == nil, "Nothing inside the container is looked at")
    #expect(profiles.first?.directory.path.hasSuffix("Data/Library/Application Support/Vane") == true)
    #expect(BrowserBookmarkImportSource.vane.supportedImportItems == [.spaces, .bookmarks, .history])
    #expect(throws: BrowserImportedSidebar.ImportError.missing) {
        try BrowserImportedSidebar.load(.vane, locations: home.locations)
    }
}

@Test func vaneFolderMacOSKeepsClosedIsUnreadableNotMissing() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeVane(in: home)
    let directory = try #require(BrowserBookmarkImportSource.vane.webKitAppDirectory(in: home.locations))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
    #expect(throws: BrowserImportedSidebar.ImportError.unreadable) {
        try BrowserImportedSidebar.load(.vane, locations: home.locations)
    }
}

@Test func vaneSpacesTakeFoldersFromLayoutsOrPreferencesAndFavoritesFromPreferences() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeVane(in: home)
    let sidebar = try BrowserImportedSidebar.load(.vane, locations: home.locations)
    #expect(sidebar.spaces.map(\.title) == ["Personal", "Plain", "Templated"])
    #expect(sidebar.spaces[0].icon == BrowserIconImage.name(emoji: "🌿"))
    #expect(sidebar.spaces[0].theme != nil)
    #expect(sidebar.spaces[0].pinned == [
        .folder(title: "Design", icon: nil, children: [tab("https://figma.example/")]),
        tab("https://linear.example/"),
    ])
    #expect(sidebar.spaces[1].pinned == [tab("https://plain.example/")])
    #expect(sidebar.spaces[2].pinned == [
        .folder(title: "Team", icon: "person.2", children: [tab("https://wiki.example/", "Wiki", title: "Team wiki")]),
    ])
    #expect(sidebar.favorites == [tab("https://mail.example/"), tab("https://legacy.example/")])

    let directory = try #require(BrowserBookmarkImportSource.vane.webKitAppDirectory(in: home.locations))
    let bookmarks = try #require(BrowserWebKitAppImport.bookmarkItems(of: .vane, directory: directory))
    #expect(bookmarks.map(\.title) == ["Personal", "Work"], "Each profile keeps a folder")
    #expect(bookmarks[0].children.map(\.title) == ["Tools", "Reading", "Loose"])
    #expect(bookmarks[0].children[1].children.map(\.urlString) == ["https://read.example/"])
    let history = BrowserWebKitAppImport.history(of: .vane, directory: directory)
    #expect(history.count == 1)
    #expect(history.first?.visitCount == 5)
    #expect(history.first?.title == "Newest")
    #expect(history.first?.lastVisit == 3000)
}

// MARK: - Detection and import

@Test func webKitAppsAreDetectedWithTheirFilesDatesAndOfferSpacesBookmarksAndHistory() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeSearch(in: home)
    let detected = BrowserProfileImporter.detected(locations: home.locations) { _ in nil }
    let search = try #require(detected.first { $0.source == .search })
    #expect(search.lastUsed != nil, "Its files' dates tell when it was used")
    #expect(search.hasImportableData)
    #expect(!search.needsKeychainKey)
    #expect(search.supportedItems == [.spaces, .bookmarks, .history])
    #expect(search.profiles.count == 1, "No profile picker")
    #expect(search.signInCookies(key: nil).isEmpty)
    #expect(search.savedLogins(key: nil).isEmpty)
}

@MainActor @Test func importingAWebKitAppAddsItsSpacesToTheWindowsProfile() throws {
    let home = try SidebarHome()
    defer { home.cleanup() }
    try writeYab(in: home)
    let f = SidebarDragFixture(temporary: ["x"])
    let spaces = f.model.spaces.count
    let message = f.model.importSidebarFromDisk(of: .yab, locations: home.locations)
    #expect(message == BrowserStrings.sidebarImportResult(spaces: 2, pinnedTabs: 3, folders: 2, favorites: 2))
    #expect(f.model.spaces.count == spaces + 2)
    #expect(f.model.spaces.allSatisfy { f.model.spaceProfilesByID[$0.id] == nil })
    #expect(f.model.importSidebarFromDisk(of: .yab, locations: home.locations)
        == BrowserStrings.sidebarImportAlreadyImported(from: "Yab"))
}
