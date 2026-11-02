// BrowserChromiumHistory.swift

import Foundation
import GRDB

// MARK: - BrowserHistorySearching

protocol BrowserHistorySearching {
    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion]
    /// The pages to offer before anything is typed, latest first.
    func recentSuggestions(maximumCount: Int) -> [BrowserCommandSuggestion]
    /// Reads the history into memory, so typing doesn't wait for the disk.
    func prepareSearchIndex()
    /// Keeps pages from another browser searchable beside this one's history.
    func importDocuments(_ documents: [BrowserSearchDocument])
}

extension BrowserHistorySearching {
    func recentSuggestions(maximumCount _: Int) -> [BrowserCommandSuggestion] { [] }
    func prepareSearchIndex() {}
    func importDocuments(_: [BrowserSearchDocument]) {}
}

// MARK: - BrowserEmptyHistoryStore

struct BrowserEmptyHistoryStore: BrowserHistorySearching {
    func suggestions(for _: String, maximumCount _: Int) -> [BrowserCommandSuggestion] {
        []
    }
}

// MARK: - BrowserChromiumHistoryStore

/// The index and icon cache are only touched on the main thread.
final class BrowserChromiumHistoryStore: BrowserHistorySearching, @unchecked Sendable {
    // MARK: Private

    private static let maximumIndexedPages = 50000

    private let profileDirectoryCandidates: [URL]
    private let fileManager: FileManager
    private var searchIndex: BrowserSearchIndex?
    private var indexedModificationDate: Date?
    private var isBuildingIndex = false
    /// Icons of pages shown recently, so typing doesn't reopen the icon database.
    private var iconCache = [String: Data?]()

    private var historyFileCandidates: [URL] {
        profileDirectoryCandidates.map {
            $0.appendingPathComponent("History", isDirectory: false)
        }
    }

    private var existingHistoryURL: URL? {
        historyFileCandidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .max { lhs, rhs in
                modificationDate(for: lhs) < modificationDate(for: rhs)
            }
    }

    private var importedDocumentsURL: URL? {
        (existingHistoryURL?.deletingLastPathComponent() ?? profileDirectoryCandidates.first)?
            .appendingPathComponent("OpenArcImportedHistory.json")
    }

    init(profileDirectoryCandidates: [URL], fileManager: FileManager = .default) {
        self.profileDirectoryCandidates = profileDirectoryCandidates
        self.fileManager = fileManager
    }

    private static func displayTitle(title: String, urlString: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        guard
            let host = URL(string: urlString)?.host,
            !host.isEmpty
        else {
            return urlString
        }

        return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
    }

    private static func likePattern(for query: String) -> String {
        var pattern = "%"
        for character in query {
            switch character {
            case "\\":
                pattern += "\\\\"
            case "%":
                pattern += "\\%"
            case "_":
                pattern += "\\_"
            default:
                pattern.append(character)
            }
        }
        pattern += "%"
        return pattern
    }

    private static func loadDocuments(from historyURL: URL) -> [BrowserSearchDocument]? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(1)
        guard let dbQueue = try? DatabaseQueue(path: historyURL.path, configuration: configuration) else { return nil }
        defer { try? dbQueue.close() }
        return try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT url, title, visit_count, typed_count, last_visit_time
                FROM urls
                WHERE hidden = 0
                  AND url NOT LIKE 'chrome://%'
                  AND url NOT LIKE 'openarc://%'
                  AND url NOT LIKE 'about:%'
                ORDER BY last_visit_time DESC
                LIMIT \(maximumIndexedPages)
                """,
            )
            .compactMap { row in
                let urlString: String = row["url"]
                guard !urlString.isEmpty else { return nil }
                // Chromium counts microseconds since 1601.
                let lastVisit: Int64 = row["last_visit_time"]
                return BrowserSearchDocument(
                    title: row["title"],
                    urlString: urlString,
                    visitCount: row["visit_count"],
                    typedCount: row["typed_count"],
                    lastVisit: lastVisit > 0 ? TimeInterval(lastVisit) / 1_000_000 - 11_644_473_600 : 0,
                )
            }
        }
    }

    // MARK: Internal

    func recentSuggestions(maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0, let historyURL = existingHistoryURL else { return [] }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(0.1)
            let dbQueue = try DatabaseQueue(path: historyURL.path, configuration: configuration)
            defer { try? dbQueue.close() }
            let rows = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT url, title
                    FROM urls
                    WHERE hidden = 0
                      AND url NOT LIKE 'chrome://%'
                      AND url NOT LIKE 'chrome-extension://%'
                      AND url NOT LIKE 'openarc://%'
                      AND url NOT LIKE 'about:%'
                    ORDER BY last_visit_time DESC
                    LIMIT ?
                    """,
                    arguments: [maximumCount],
                )
            }
            return withIcons(rows.compactMap { row in
                let urlString: String = row["url"]
                guard !urlString.isEmpty else { return nil }
                let title: String = row["title"]
                return BrowserCommandSuggestion(
                    kind: .history,
                    displayText: Self.displayTitle(title: title, urlString: urlString),
                    detailText: BrowserURLDisplayFormatter.displayString(for: urlString),
                    resolvedURLString: urlString,
                )
            })
        } catch {
            return []
        }
    }

    func importDocuments(_ documents: [BrowserSearchDocument]) {
        guard let url = importedDocumentsURL, let data = try? JSONEncoder().encode(documents) else { return }
        try? data.write(to: url, options: [.atomic])
        indexedModificationDate = nil
        prepareSearchIndex()
    }

    /// Reads the newest pages off the main thread. A file that hasn't changed since
    /// the last read keeps the index it has.
    func prepareSearchIndex() {
        guard !isBuildingIndex, let historyURL = existingHistoryURL else { return }
        let modified = modificationDate(for: historyURL)
        guard modified != indexedModificationDate else { return }
        isBuildingIndex = true
        let importedURL = importedDocumentsURL
        Task.detached(priority: .utility) { [weak self] in
            let own = Self.loadDocuments(from: historyURL)
            let imported = importedURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode([BrowserSearchDocument].self, from: $0) } ?? []
            let urls = Set(own?.map(\.urlString) ?? [])
            let documents = own.map { $0 + imported.filter { !urls.contains($0.urlString) } }
            let index = documents.map(BrowserSearchIndex.init(documents:))
            await MainActor.run { [weak self] in
                guard let self else { return }
                isBuildingIndex = false
                if let index {
                    searchIndex = index
                    indexedModificationDate = modified
                    iconCache.removeAll()
                }
            }
        }
    }

    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedQuery.isEmpty,
            maximumCount > 0,
            let historyURL = existingHistoryURL
        else {
            return []
        }

        if let searchIndex {
            return withIcons(searchIndex.search(trimmedQuery, limit: maximumCount).map { index in
                let document = searchIndex.documents[index]
                return BrowserCommandSuggestion(
                    kind: .history,
                    displayText: Self.displayTitle(title: document.title, urlString: document.urlString),
                    detailText: BrowserURLDisplayFormatter.displayString(for: document.urlString),
                    resolvedURLString: document.urlString,
                )
            })
        }

        do {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(0.1)
            let dbQueue = try DatabaseQueue(path: historyURL.path, configuration: configuration)
            defer { try? dbQueue.close() }
            let pattern = Self.likePattern(for: trimmedQuery)
            let rows = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT url, title
                    FROM urls
                    WHERE hidden = 0
                      AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')
                      AND url NOT LIKE 'chrome://%'
                      AND url NOT LIKE 'openarc://%'
                      AND url NOT LIKE 'about:%'
                    ORDER BY typed_count DESC, visit_count DESC, last_visit_time DESC
                    LIMIT ?
                    """,
                    arguments: [pattern, pattern, maximumCount],
                )
            }

            return withIcons(rows.compactMap { row in
                let urlString: String = row["url"]
                guard !urlString.isEmpty else {
                    return nil
                }

                let title: String = row["title"]
                return BrowserCommandSuggestion(
                    kind: .history,
                    displayText: Self.displayTitle(title: title, urlString: urlString),
                    detailText: BrowserURLDisplayFormatter.displayString(for: urlString),
                    resolvedURLString: urlString,
                )
            })
        } catch {
            return []
        }
    }

    /// Chromium keeps page icons beside the history, so a row's icon needs no network.
    private func withIcons(_ suggestions: [BrowserCommandSuggestion]) -> [BrowserCommandSuggestion] {
        let missing = suggestions.map(\.resolvedURLString).filter { iconCache[$0] == nil }
        if !missing.isEmpty, let historyURL = existingHistoryURL {
            let path = historyURL.deletingLastPathComponent().appendingPathComponent("Favicons").path
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(0.1)
            if FileManager.default.fileExists(atPath: path),
               let dbQueue = try? DatabaseQueue(path: path, configuration: configuration)
            {
                defer { try? dbQueue.close() }
                for urlString in missing {
                    iconCache[urlString] = .some(try? dbQueue.read { db in
                        try Data.fetchOne(
                            db,
                            sql: """
                            SELECT b.image_data
                            FROM favicon_bitmaps b
                            JOIN icon_mapping m ON m.icon_id = b.icon_id
                            WHERE m.page_url = ?
                            ORDER BY b.width DESC
                            LIMIT 1
                            """,
                            arguments: [urlString],
                        )
                    })
                }
            }
        }
        return suggestions.map { suggestion in
            var suggestion = suggestion
            suggestion.iconData = iconCache[suggestion.resolvedURLString] ?? nil
            return suggestion
        }
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
