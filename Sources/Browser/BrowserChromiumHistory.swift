import Foundation
import GRDB

// MARK: - BrowserHistorySearching

protocol BrowserHistorySearching {
    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion]
}

// MARK: - BrowserEmptyHistoryStore

struct BrowserEmptyHistoryStore: BrowserHistorySearching {
    func suggestions(for _: String, maximumCount _: Int) -> [BrowserCommandSuggestion] {
        []
    }
}

// MARK: - BrowserChromiumHistoryStore

final class BrowserChromiumHistoryStore: BrowserHistorySearching {
    // MARK: Lifecycle

    init(profileDirectoryCandidates: [URL], fileManager: FileManager = .default) {
        self.profileDirectoryCandidates = profileDirectoryCandidates
        self.fileManager = fileManager
    }

    // MARK: Internal

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
                      AND url NOT LIKE 'tb://%'
                      AND url NOT LIKE 'about:%'
                    ORDER BY typed_count DESC, visit_count DESC, last_visit_time DESC
                    LIMIT ?
                    """,
                    arguments: [pattern, pattern, maximumCount]
                )
            }

            return rows.compactMap { row in
                let urlString: String = row["url"]
                guard !urlString.isEmpty else {
                    return nil
                }

                let title: String = row["title"]
                return BrowserCommandSuggestion(
                    kind: .history,
                    displayText: Self.displayTitle(title: title, urlString: urlString),
                    detailText: BrowserURLDisplayFormatter.displayString(for: urlString),
                    resolvedURLString: urlString
                )
            }
        } catch {
            return []
        }
    }

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

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
