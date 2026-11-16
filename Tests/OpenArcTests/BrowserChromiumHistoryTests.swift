// BrowserChromiumHistoryTests.swift

import Foundation
import GRDB
import Testing

@Test func chromiumHistoryStoreSearchesChromiumHistoryDatabase() throws {
    let harness = try ChromiumHistoryHarness()
    defer { harness.cleanup() }
    try harness.insertHistory(
        urlString: "https://docs.example.com/start",
        title: "Example Docs",
        visitCount: 4,
        typedCount: 2,
        lastVisitTime: 2,
    )
    try harness.insertHistory(
        urlString: "https://other.example.com",
        title: "Other",
        visitCount: 10,
        typedCount: 0,
        lastVisitTime: 3,
    )

    let store = BrowserChromiumHistoryStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    let suggestions = store.suggestions(for: "docs", maximumCount: 5)

    let suggestion = try #require(suggestions.first)
    #expect(suggestions.count == 1)
    #expect(suggestion.kind == .history)
    #expect(suggestion.displayText == "Example Docs")
    #expect(suggestion.resolvedURLString == "https://docs.example.com/start")
}

@Test func chromiumHistoryListsASitesEarlierResultsOnePerTitle() throws {
    let harness = try ChromiumHistoryHarness()
    defer { harness.cleanup() }
    for (url, title, time) in [
        ("https://github.com/search?q=repo%3Aa+x&type=code", "Code search results", 5),
        ("https://github.com/search?q=repo%3Ab+y&type=code", "Code search results", 4),
        ("https://github.com/search?q=openarc&type=repositories", "Repository search results", 3),
        ("https://github.com/levochkaa", "levochkaa", 6),
        ("https://GITHUB.com/search?q=upper", "Upper", 7),
        ("https://example.com/search?q=1", "Elsewhere", 8),
    ] {
        try harness.insertHistory(urlString: url, title: title, visitCount: 1, typedCount: 0, lastVisitTime: time)
    }
    let store = BrowserChromiumHistoryStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    let pages = store.recentSuggestions(withURLPrefix: "https://github.com/search?q=", maximumCount: 5)
    #expect(pages.map(\.displayText) == ["Code search results", "Repository search results"])
    #expect(
        pages.first?.resolvedURLString == "https://github.com/search?q=repo%3Aa+x&type=code",
        "The latest of a title",
    )
    #expect(pages.allSatisfy { $0.kind == .history })
    #expect(store.recentSuggestions(withURLPrefix: "https://github.com/search?q=", maximumCount: 1).count == 1)
    #expect(
        store.recentSuggestions(withURLPrefix: "https://github.com/search_q", maximumCount: 5).isEmpty,
        "_ is literal",
    )
}

@Test func chromiumHistoryGivesSavedIconsOfPagesThatAreNotOpen() throws {
    let harness = try ChromiumHistoryHarness()
    defer { harness.cleanup() }
    try harness.insertHistory(
        urlString: "https://a.example/",
        title: "A",
        visitCount: 1,
        typedCount: 0,
        lastVisitTime: 1,
    )
    let favicons = try DatabaseQueue(path: harness.profileDirectoryURL.appendingPathComponent("Favicons").path)
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let touchIcon = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    try favicons.write { db in
        try db.execute(sql: "CREATE TABLE favicons (id INTEGER PRIMARY KEY, url LONGVARCHAR, icon_type INTEGER)")
        try db.execute(sql: "CREATE TABLE icon_mapping (page_url LONGVARCHAR, icon_id INTEGER)")
        try db.execute(sql: "CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER)")
        try db.execute(sql: "INSERT INTO favicons VALUES (1, 'https://a.example/favicon.png', 1)")
        try db.execute(sql: "INSERT INTO favicons VALUES (2, 'https://a.example/touch.png', 2)")
        try db.execute(sql: "INSERT INTO icon_mapping VALUES ('https://a.example/', 1)")
        try db.execute(sql: "INSERT INTO icon_mapping VALUES ('https://a.example/', 2)")
        try db.execute(sql: "INSERT INTO favicon_bitmaps VALUES (1, ?, 32)", arguments: [png])
        try db.execute(sql: "INSERT INTO favicon_bitmaps VALUES (2, ?, 180)", arguments: [touchIcon])
    }
    try favicons.close()
    let store = BrowserChromiumHistoryStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    let icons = store.pageIcons(for: ["https://a.example/", "https://a.example/other", "https://b.example/"])
    #expect(icons == [
        "https://a.example/": png,
        "https://a.example/other": png,
    ], "The favicon before a larger touch icon, the site's icon for its other pages, none for unknown sites")
}

@Test func aLockedHistoryAnswersAtOnceAndIconsComeOnceItIsFree() throws {
    let harness = try ChromiumHistoryHarness()
    defer { harness.cleanup() }
    try harness.insertHistory(
        urlString: "https://a.example/",
        title: "A",
        visitCount: 1,
        typedCount: 0,
        lastVisitTime: 1,
    )
    let favicons = try DatabaseQueue(path: harness.profileDirectoryURL.appendingPathComponent("Favicons").path)
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    try favicons.write { db in
        try db.execute(sql: "CREATE TABLE favicons (id INTEGER PRIMARY KEY, url LONGVARCHAR, icon_type INTEGER)")
        try db.execute(sql: "CREATE TABLE icon_mapping (page_url LONGVARCHAR, icon_id INTEGER)")
        try db.execute(sql: "CREATE TABLE favicon_bitmaps (icon_id INTEGER, image_data BLOB, width INTEGER)")
        try db.execute(sql: "INSERT INTO favicons VALUES (1, 'https://a.example/favicon.png', 1)")
        try db.execute(sql: "INSERT INTO icon_mapping VALUES ('https://a.example/', 1)")
        try db.execute(sql: "INSERT INTO favicon_bitmaps VALUES (1, ?, 32)", arguments: [png])
    }
    let store = BrowserChromiumHistoryStore(profileDirectoryCandidates: [harness.profileDirectoryURL])

    // The engine writing: both databases locked.
    try harness.dbQueue.inTransaction(.exclusive) { db in
        try db.execute(sql: "UPDATE urls SET title = title")
        try favicons.inTransaction(.exclusive) { db in
            try db.execute(sql: "UPDATE favicons SET icon_type = icon_type")
            let start = Date()
            _ = store.recentSuggestions(maximumCount: 5)
            #expect(store.pageIcons(for: ["https://a.example/"]).isEmpty)
            #expect(Date().timeIntervalSince(start) < 0.05, "No wait for the lock")
            return .rollback
        }
        return .rollback
    }

    #expect(store.pageIcons(for: ["https://a.example/"]) == ["https://a.example/": png])
    try favicons.close()
}

// MARK: - ChromiumHistoryHarness

private struct ChromiumHistoryHarness {
    // MARK: Internal

    let directoryURL: URL
    let profileDirectoryURL: URL
    let historyURL: URL
    let dbQueue: DatabaseQueue

    init() throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OpenArcHistoryTests-\(UUID().uuidString)", isDirectory: true)
        self.profileDirectoryURL = directoryURL.appendingPathComponent("Default", isDirectory: true)
        self.historyURL = profileDirectoryURL.appendingPathComponent("History", isDirectory: false)
        try FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
        self.dbQueue = try DatabaseQueue(path: historyURL.path)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE urls (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  url LONGVARCHAR,
                  title LONGVARCHAR,
                  visit_count INTEGER DEFAULT 0 NOT NULL,
                  typed_count INTEGER DEFAULT 0 NOT NULL,
                  last_visit_time INTEGER NOT NULL,
                  hidden INTEGER DEFAULT 0 NOT NULL
                )
                """,
            )
        }
    }

    func insertHistory(
        urlString: String,
        title: String,
        visitCount: Int,
        typedCount: Int,
        lastVisitTime: Int,
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
                VALUES (?, ?, ?, ?, ?, 0)
                """,
                arguments: [urlString, title, visitCount, typedCount, lastVisitTime],
            )
        }
    }

    func cleanup() {
        try? dbQueue.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
