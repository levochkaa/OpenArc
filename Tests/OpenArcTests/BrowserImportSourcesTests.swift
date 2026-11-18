// BrowserImportSourcesTests.swift

import Foundation
import GRDB
import Testing
import ZIPFoundation

// MARK: - FakeHome

private struct FakeHome {
    let url: URL

    var locations: BrowserImportLocations { BrowserImportLocations(home: url) }

    init() throws {
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent("ImportHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `contents` at a path below Application Support and dates it.
    @discardableResult func write(
        _ contents: String,
        at path: String,
        modified: Date? = nil,
    ) throws -> URL {
        let file = locations.applicationSupport.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(contents.utf8).write(to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ImportFixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePlaces(at url: URL, _ fill: (Database) throws -> Void) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER DEFAULT 0,
            hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER);
        CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER,
            visit_type INTEGER);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER,
            position INTEGER, title TEXT, guid TEXT);
        INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________');
        INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'menu', 'menu________');
        INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____');
        INSERT INTO moz_bookmarks VALUES (4, 2, NULL, 1, 2, 'tags', 'tags________');
        INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____');
        INSERT INTO moz_bookmarks VALUES (6, 2, NULL, 1, 4, 'mobile', 'mobile______');
        """)
        try fill(db)
    }
    try queue.close()
}

// MARK: - Chromium family

@Test func everyChromiumBrowserResolvesItsOwnProfileFolder() throws {
    let home = try FakeHome()
    defer { home.cleanup() }
    let expected: [BrowserBookmarkImportSource: String] = [
        .arc: "Arc/User Data/Default",
        .dia: "Dia/User Data/Default",
        .chrome: "Google/Chrome/Default",
        .brave: "BraveSoftware/Brave-Browser/Default",
        .edge: "Microsoft Edge/Default",
        .opera: "com.operasoftware.Opera",
        .vivaldi: "Vivaldi/Default",
        .helium: "net.imput.helium/Default",
        .comet: "Comet/Default",
        .atlas: "com.openai.atlas/browser-data/host/Default",
        .ardia: "com.ardia.browser/Chromium/Default",
        .aside: "Aside/Default",
        .cra: "Cra/Chromium/Default",
        .crest: "Crest/Chromium/Crest-2F1C",
        .chromium: "Chromium/Default",
    ]
    for (_, path) in expected {
        try home.write("{}", at: path + "/Preferences")
    }
    try home.write("{}", at: "com.openai.atlas/browser-data/host/Local State")
    let sources = BrowserBookmarkImportSource.allCases.filter { $0.engine == .chromium }
    #expect(Set(sources) == Set(expected.keys))
    for source in sources {
        let directories = source.chromiumProfileDirectories(in: home.locations)
        let paths = directories.map {
            String($0.standardizedFileURL
                .path
                .dropFirst(home.locations.applicationSupport.standardizedFileURL.path.count + 1))
        }
        #expect(paths == expected[source].map { [$0] }, "\(source)")
    }
}

@Test func chromiumProfilesTakeTheirNamesFromLocalStateAndComeNewestFirst() throws {
    let home = try FakeHome()
    defer { home.cleanup() }
    try home.write("{}", at: "BraveSoftware/Brave-Browser/Default/Preferences")
    try home.write("{}", at: "BraveSoftware/Brave-Browser/Default/History", modified: Date(timeIntervalSince1970: 1000))
    try home.write("{}", at: "BraveSoftware/Brave-Browser/Profile 3/Preferences")
    try home.write(
        "{}",
        at: "BraveSoftware/Brave-Browser/Profile 3/History",
        modified: Date(timeIntervalSince1970: 5000),
    )
    try home.write("{}", at: "BraveSoftware/Brave-Browser/Guest Profile/Preferences")
    try home.write("""
    {"profile": {"info_cache": {
        "Default": {"name": "Personal", "active_time": 2000.5},
        "Profile 3": {"name": "Work"}
    }}}
    """, at: "BraveSoftware/Brave-Browser/Local State")

    let profiles = BrowserBookmarkImportSource.brave.importProfiles(in: home.locations)
    #expect(profiles.map(\.name) == ["Work", "Personal"])
    #expect(profiles.map(\.lastUsed) == [Date(timeIntervalSince1970: 5000), Date(timeIntervalSince1970: 2000.5)])
}

// MARK: - Detection

@Test func detectionListsInstalledBrowsersAndBrowsersWithDataByRecency() throws {
    let home = try FakeHome()
    defer { home.cleanup() }
    try home.write("{}", at: "Google/Chrome/Default/Preferences")
    try home.write("{}", at: "Google/Chrome/Default/History", modified: Date(timeIntervalSince1970: 1000))
    try home.write("""
    [Profile0]
    Name=Default (release)
    IsRelative=1
    Path=Profiles/abc.Default (release)
    
    [Profile1]
    Name=Empty
    IsRelative=1
    Path=Profiles/def.Empty
    """, at: "zen/profiles.ini")
    try home.write(
        "",
        at: "zen/Profiles/abc.Default (release)/places.sqlite",
        modified: Date(timeIntervalSince1970: 9000),
    )
    try home.write("", at: "zen/Profiles/def.Empty/times.json")
    let apps = [
        "com.brave.Browser": URL(fileURLWithPath: "/Applications/Brave Browser.app"),
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
        "app.zen-browser.zen": URL(fileURLWithPath: "/Applications/Zen.app"),
    ]

    let detected = BrowserProfileImporter.detected(locations: home.locations) { apps[$0] }

    #expect(detected.map(\.source) == [.zen, .chrome, .brave, .safari])
    let zen = try #require(detected.first)
    #expect(zen.profileName == "Default (release)")
    #expect(zen.profiles.map(\.name) == ["Default (release)"])
    #expect(zen.lastUsed == Date(timeIntervalSince1970: 9000))
    #expect(zen.applicationURL?.lastPathComponent == "Zen.app")
    #expect(zen.supportedItems == [.bookmarks, .history, .signIns])
    #expect(zen.hasImportableData)
    let chrome = detected[1]
    #expect(chrome.applicationURL == nil)
    #expect(chrome.profileDirectory.lastPathComponent == "Default")
    #expect(chrome.supportedItems.contains(.passwords))
    #expect(!chrome.supportedItems.contains(.spaces))
    let brave = detected[2]
    #expect(brave.profiles.isEmpty)
    #expect(!brave.hasImportableData)
    let safari = detected[3]
    #expect(!safari.hasImportableData)
    #expect(safari.supportedItems == [.bookmarks, .history, .passwords])
    let archive = home.url.appendingPathComponent("Safari Export.zip")
    #expect(safari.withArchive(archive).archiveURL == archive)
    #expect(safari.withArchive(archive).hasImportableData)
}

@Test func browsersWithSidebarFilesOfferSpacesAndUnknownKeychainsOfferNoSecrets() {
    #expect(BrowserBookmarkImportSource.allCases.filter { $0.supportedImportItems.contains(.spaces) }
        == [.arc, .cra, .crest, .yab, .vane, .search])
    #expect(BrowserBookmarkImportSource.allCases.filter { $0.engine == .webkitApp }.allSatisfy {
        $0.keychainService == nil && $0.supportedImportItems.isDisjoint(with: [.passwords, .signIns])
    })
    #expect(!BrowserBookmarkImportSource.atlas.supportedImportItems.contains(.passwords))
    #expect(!BrowserBookmarkImportSource.atlas.supportedImportItems.contains(.signIns))
    #expect(BrowserBookmarkImportSource.helium.keychainService == "Helium Storage Key")
    #expect(BrowserBookmarkImportSource.allCases.filter { $0.engine == .firefox }.allSatisfy {
        !$0.supportedImportItems.contains(.passwords) && $0.keychainService == nil
    })
}

@Test func choosingAnotherProfileKeepsTheBrowsersList() throws {
    let home = try FakeHome()
    defer { home.cleanup() }
    try home.write("{}", at: "Vivaldi/Default/History", modified: Date(timeIntervalSince1970: 3000))
    try home.write("{}", at: "Vivaldi/Profile 1/History", modified: Date(timeIntervalSince1970: 1000))
    let vivaldi = try #require(BrowserProfileImporter.detected(locations: home.locations) { _ in nil }.first)
    #expect(vivaldi.profileDirectory.lastPathComponent == "Default")
    let other = vivaldi.selecting(vivaldi.profiles[1])
    #expect(other.profileDirectory.lastPathComponent == "Profile 1")
    #expect(other.profileName == "Profile 1")
    #expect(other.profiles == vivaldi.profiles)
}

// MARK: - Firefox family

@Test func firefoxBookmarksKeepFoldersAndLeaveOutDefaultsQueriesAndSeparators() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlaces(at: directory.appendingPathComponent("places.sqlite")) { db in
        try db.execute(sql: """
        INSERT INTO moz_places (id, url, title) VALUES
            (1, 'https://example.com/', 'Example'), (2, 'https://news.example/', 'News'),
            (3, 'place:sort=8&maxResults=10', 'Recent'), (4, 'https://support.mozilla.org/products/firefox', 'Help'),
            (5, 'https://mobile.example/', 'Phone'), (6, 'https://www.mozilla.org/about/', 'About Us');
        INSERT INTO moz_bookmarks VALUES (10, 1, 1, 3, 0, 'Example', 'a1');
        INSERT INTO moz_bookmarks VALUES (11, 3, NULL, 3, 1, NULL, 'a2');
        INSERT INTO moz_bookmarks VALUES (12, 2, NULL, 3, 2, 'Reading', 'a3');
        INSERT INTO moz_bookmarks VALUES (13, 1, 2, 12, 0, 'News', 'a4');
        INSERT INTO moz_bookmarks VALUES (14, 1, 3, 3, 3, 'Recent', 'a5');
        INSERT INTO moz_bookmarks VALUES (15, 2, NULL, 2, 0, 'Mozilla Firefox', 'a6');
        INSERT INTO moz_bookmarks VALUES (16, 1, 4, 15, 0, 'Help', 'a7');
        INSERT INTO moz_bookmarks VALUES (17, 1, 6, 15, 1, 'About Us', 'a8');
        INSERT INTO moz_bookmarks VALUES (18, 1, 5, 6, 0, 'Phone', 'a9');
        INSERT INTO moz_bookmarks VALUES (19, 2, NULL, 3, 4, 'Empty', 'b1');
        """)
    }

    let items = try #require(BrowserFirefoxProfile.bookmarkItems(profileDirectory: directory))

    #expect(items == [
        BrowserBookmarkImportItem(title: "Example", urlString: "https://example.com/", children: []),
        BrowserBookmarkImportItem(title: "Reading", urlString: nil, children: [
            BrowserBookmarkImportItem(title: "News", urlString: "https://news.example/", children: []),
        ]),
        BrowserBookmarkImportItem(title: "Phone", urlString: "https://mobile.example/", children: []),
    ])
    #expect(BrowserFirefoxProfile.bookmarkItems(profileDirectory: directory.appendingPathComponent("none")) == nil)
}

@Test func firefoxHistoryIsNewestFirstWithTypedVisitsCounted() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makePlaces(at: directory.appendingPathComponent("places.sqlite")) { db in
        try db.execute(sql: """
        INSERT INTO moz_places (id, url, title, visit_count, hidden, last_visit_date) VALUES
            (1, 'https://old.example/', 'Old', 2, 0, 1000000000000000),
            (2, 'https://new.example/', NULL, 1, 0, 1700000000000000),
            (3, 'about:config', 'Config', 4, 0, 1700000000000001),
            (4, 'https://hidden.example/', 'Hidden', 1, 1, 1700000000000002),
            (5, 'https://bookmarked.example/', 'Never visited', 0, 0, NULL);
        INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES (1, 1, 2), (1, 2, 1), (2, 3, 1);
        """)
    }

    let history = BrowserFirefoxProfile.history(profileDirectory: directory)

    #expect(history.map(\.urlString) == ["https://new.example/", "https://old.example/"])
    #expect(history.map(\.title) == ["", "Old"])
    #expect(history.map(\.typedCount) == [0, 1])
    #expect(history.map(\.visitCount) == [1, 2])
    #expect(history.first?.lastVisit == 1_700_000_000)
}

@Test func firefoxCookiesCarryOverInChromiumsTermsWithoutPartitionedOrExpiredOnes() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue(path: directory.appendingPathComponent("cookies.sqlite").path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT,
            value TEXT, host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER,
            isSecure INTEGER, isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0,
            schemeMap INTEGER DEFAULT 0);
        INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, isSecure, isHttpOnly, sameSite)
        VALUES
            ('', 'sid', 'token', '.example.com', '/', 1900000000000, 1, 1, 1),
            ('', 'pref', 'dark', 'site.example', '/app', 1900000000, 0, 0, 0),
            ('^partitionKey=%28https%2Cother.example%29', 'embed', 'x', '.example.com', '/', 1900000000000, 1, 0, 0),
            ('^userContextId=2', 'work', 'y', '.example.com', '/', 1900000000000, 1, 0, 0),
            ('', 'gone', 'z', '.example.com', '/', 1000000000000, 1, 0, 2),
            ('', 'lax', 'w', '.example.com', '/', 1900000000000, 1, 0, 256);
        """)
    }
    try queue.close()

    let cookies = BrowserFirefoxProfile.cookies(
        profileDirectory: directory,
        now: Date(timeIntervalSince1970: 1_800_000_000),
    )

    #expect(cookies.map(\.name) == ["sid", "pref", "lax"])
    #expect(cookies.map(\.sameSite) == [1, -1, -1])
    #expect(cookies[0].expires == Int64((1_900_000_000 + 11_644_473_600) * 1_000_000))
    #expect(cookies[1].expires == cookies[0].expires)
    #expect(cookies[0].urlString == "https://example.com/")
    #expect(cookies[1].urlString == "http://site.example/app")
    #expect(cookies[0].isHTTPOnly)
}

@Test func firefoxProfilesWithoutAnIniAreFoundInTheirFolder() throws {
    let home = try FakeHome()
    defer { home.cleanup() }
    try home.write("", at: "Floorp/Profiles/x1y2.default-release/cookies.sqlite")
    let profiles = BrowserBookmarkImportSource.floorp.importProfiles(in: home.locations)
    #expect(profiles.map(\.name) == ["default-release"])
}

// MARK: - Safari export

private let safariHistoryJSON = """
{"metadata": {"browser_name": "Safari", "browser_version": "18.2", "data_type": "history",
              "export_time_usec": 1734000000000000, "schema_version": 1},
 "history": [
    {"url": "https://example.com/", "title": "Example", "time_usec": 1734000000000000.0, "visit_count": 3,
     "destination_url": "https://example.com/home", "latest_visit_was_load_failure": false},
    {"url": "https://other.example/", "time_usec": 1733000000000000, "visit_count": 1},
    {"url": "favorites://", "title": "Favorites", "time_usec": 1735000000000000, "visit_count": 1}
 ]}
"""

private let secondProfileHistoryJSON = """
{"metadata": {"data_type": "history"},
 "history": [{"url": "https://example.com/", "title": "Example Home", "time_usec": 1735000000000000, "visit_count": 2}]}
"""

private let safariPasswordsCSV = """
Title,URL,Username,Password,Notes,OTPAuth
example.com (me),https://example.com/login,me,"pa,ss""word",,
Bare,http://192.168.1.1:8080/,admin,secret,"two
lines",
No password,https://empty.example/,someone,,,
App,android://com.example,app,x,,
"""

private func makeSafariArchive() throws -> URL {
    let directory = try makeDirectory()
    let export = directory.appendingPathComponent("Safari Export", isDirectory: true)
    try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
    try Data("""
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <HTML><BODY><DL><p>
    <DT><A HREF="https://bookmark.example/">Bookmark</A>
    </DL></BODY></HTML>
    """.utf8).write(to: export.appendingPathComponent("Bookmarks.html"))
    try Data(safariHistoryJSON.utf8).write(to: export.appendingPathComponent("History.json"))
    try Data(secondProfileHistoryJSON.utf8).write(to: export.appendingPathComponent("Work - History.json"))
    try Data(#"{"metadata": {"data_type": "payment_cards"}, "payment_cards": []}"#.utf8)
        .write(to: export.appendingPathComponent("PaymentCards.json"))
    try Data(safariPasswordsCSV.utf8).write(to: export.appendingPathComponent("Passwords.csv"))
    let archive = directory.appendingPathComponent("Safari Export.zip")
    try FileManager.default.zipItem(at: export, to: archive, shouldKeepParent: false, compressionMethod: .deflate)
    return archive
}

@Test func aSafariArchiveGivesBookmarksMergedHistoryAndPasswords() throws {
    let archiveURL = try makeSafariArchive()
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
    let importer = BrowserProfileImporter.safariArchive(archiveURL)

    #expect(importer.bookmarkItems() == [
        BrowserBookmarkImportItem(title: "Bookmark", urlString: "https://bookmark.example/", children: []),
    ])

    let history = importer.history()
    #expect(history.map(\.urlString) == ["https://example.com/", "https://other.example/"])
    #expect(history.first?.title == "Example Home")
    #expect(history.first?.visitCount == 5)
    #expect(history.first?.lastVisit == 1_735_000_000)

    let logins = importer.savedLogins(key: nil)
    #expect(logins.map(\.login) == [
        BrowserSavedLogin(origin: "https://example.com", username: "me"),
        BrowserSavedLogin(origin: "http://192.168.1.1:8080", username: "admin"),
    ])
    #expect(logins.map(\.password) == [#"pa,ss"word"#, "secret"])
    #expect(importer.signInCookies(key: nil).isEmpty)
}

@Test func otherFilesAreNotTakenForSafariData() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let notAnArchive = directory.appendingPathComponent("notes.zip")
    try Data("not a zip".utf8).write(to: notAnArchive)
    #expect(BrowserSafariArchive(url: notAnArchive).bookmarkItems() == nil)
    #expect(BrowserSafariArchive(url: notAnArchive).history().isEmpty)
    #expect(BrowserSafariArchive.historyDocuments(fromJSON: Data("{}".utf8)) == nil)
    #expect(BrowserSafariArchive.historyDocuments(
        fromJSON: Data(#"{"metadata": {"data_type": "extensions"}, "extensions": []}"#.utf8),
    ) == nil)
    #expect(BrowserSafariArchive.logins(fromCSV: Data("Name,Value\na,b".utf8)).isEmpty)
}

@Test func csvFieldsKeepQuotedCommasLineBreaksAndQuotes() {
    let rows = BrowserSafariArchive.csvRows("\u{FEFF}a,\"b,c\",\"d\"\"e\"\r\n\"f\ng\",,h\n\n")
    #expect(rows == [["a", "b,c", "d\"e"], ["f\ng", "", "h"]])
}

// MARK: - Bookmark store

@Test func bookmarksReadByAnImporterLandInAFolderNamedForTheBrowser() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserChromiumBookmarkStore(profileDirectoryCandidates: [directory])
    let result = store.importBookmarkItems([
        BrowserBookmarkImportItem(title: "Example", urlString: "https://example.com/", children: []),
    ], from: .zen)
    #expect(result == BrowserBookmarkImportResult(source: .zen, importedCount: 1, sourceWasAvailable: true))
    let folder = try #require(store.loadBookmarkBarItems().first)
    #expect(folder.title == BrowserBookmarkImportSource.zen.importedFolderTitle)
    #expect(folder.children.map(\.urlString) == ["https://example.com/"])
}
