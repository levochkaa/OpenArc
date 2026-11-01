// BrowserChromiumHistory.swift

import Foundation
import GRDB

// MARK: - BrowserHistorySearching

protocol BrowserHistorySearching {
    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion]
    /// The pages to offer before anything is typed, latest first.
    func recentSuggestions(maximumCount: Int) -> [BrowserCommandSuggestion]
}

extension BrowserHistorySearching {
    func recentSuggestions(maximumCount _: Int) -> [BrowserCommandSuggestion] { [] }
}

// MARK: - BrowserEmptyHistoryStore

struct BrowserEmptyHistoryStore: BrowserHistorySearching {
    func suggestions(for _: String, maximumCount _: Int) -> [BrowserCommandSuggestion] {
        []
    }
}

// MARK: - BrowserChromiumHistoryStore

final class BrowserChromiumHistoryStore: BrowserHistorySearching {
    // MARK: Private

    private let profileDirectoryCandidates: [URL]
    private let fileManager: FileManager

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

    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedQuery.isEmpty,
            maximumCount > 0,
            let historyURL = existingHistoryURL
        else {
            return []
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
        guard let historyURL = existingHistoryURL else { return suggestions }
        let path = historyURL.deletingLastPathComponent().appendingPathComponent("Favicons").path
        guard FileManager.default.fileExists(atPath: path) else { return suggestions }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(0.1)
        guard let dbQueue = try? DatabaseQueue(path: path, configuration: configuration) else { return suggestions }
        defer { try? dbQueue.close() }
        return suggestions.map { suggestion in
            var suggestion = suggestion
            suggestion.iconData = try? dbQueue.read { db in
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
                    arguments: [suggestion.resolvedURLString],
                )
            }
            return suggestion
        }
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
