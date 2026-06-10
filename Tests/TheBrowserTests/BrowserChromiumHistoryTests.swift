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
        lastVisitTime: 2
    )
    try harness.insertHistory(
        urlString: "https://other.example.com",
        title: "Other",
        visitCount: 10,
        typedCount: 0,
        lastVisitTime: 3
    )

    let store = BrowserChromiumHistoryStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    let suggestions = store.suggestions(for: "docs", maximumCount: 5)

    let suggestion = try #require(suggestions.first)
    #expect(suggestions.count == 1)
    #expect(suggestion.kind == .history)
    #expect(suggestion.displayText == "Example Docs")
    #expect(suggestion.resolvedURLString == "https://docs.example.com/start")
}

// MARK: - ChromiumHistoryHarness

private struct ChromiumHistoryHarness {
    // MARK: Lifecycle

    init() throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("TheBrowserHistoryTests-\(UUID().uuidString)", isDirectory: true)
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
                """
            )
        }
    }

    // MARK: Internal

    let directoryURL: URL
    let profileDirectoryURL: URL
    let historyURL: URL
    let dbQueue: DatabaseQueue

    func insertHistory(
        urlString: String,
        title: String,
        visitCount: Int,
        typedCount: Int,
        lastVisitTime: Int
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden)
                VALUES (?, ?, ?, ?, ?, 0)
                """,
                arguments: [urlString, title, visitCount, typedCount, lastVisitTime]
            )
        }
    }

    func cleanup() {
        try? dbQueue.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
