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
