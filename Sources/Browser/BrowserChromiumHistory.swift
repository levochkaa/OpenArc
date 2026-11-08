// BrowserChromiumHistory.swift

import Foundation
import GRDB

// MARK: - BrowserHistorySearching

protocol BrowserHistorySearching {
    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion]
    /// The pages to offer before anything is typed, latest first.
    func recentSuggestions(maximumCount: Int) -> [BrowserCommandSuggestion]
    /// Recent pages whose address starts with `prefix`, latest first, one per title:
    /// a site search's earlier results, listed under its chip.
    func recentSuggestions(withURLPrefix prefix: String, maximumCount: Int) -> [BrowserCommandSuggestion]
    /// Reads the history into memory, so typing doesn't wait for the disk.
    func prepareSearchIndex()
    /// Keeps pages from another browser searchable beside this one's history.
    func importDocuments(_ documents: [BrowserSearchDocument])
    /// A page this session showed. The engine writes its history database
    /// only now and then, so the newest pages are kept here meanwhile.
    func noteVisit(title: String, urlString: String)
}

extension BrowserHistorySearching {
    func noteVisit(title _: String, urlString _: String) {}
    func recentSuggestions(maximumCount _: Int) -> [BrowserCommandSuggestion] { [] }
    func recentSuggestions(withURLPrefix _: String, maximumCount _: Int) -> [BrowserCommandSuggestion] { [] }
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

    private static let maximumSessionPages = 500

    private let profileDirectoryCandidates: [URL]
    private let fileManager: FileManager
    private var searchIndex: BrowserSearchIndex?
    private var indexedModificationDate: Date?
    private var isBuildingIndex = false
    /// Pages shown in this session, newest last, searched before the index.
    private var sessionDocuments = [BrowserSearchDocument]()
    private var sessionIndex: BrowserSearchIndex?
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

    private static func loadDocuments(from historyURL: URL, readonly: Bool = true) -> [BrowserSearchDocument]? {
        var configuration = Configuration()
        // A copy opens writable so SQLite can roll back the journal copied with it.
        configuration.readonly = readonly
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

    /// The engine keeps its History database locked while it runs, so the pages
    /// of this session are read from a copy: a clone of the file and its journal,
    /// which SQLite rolls back to the last commit when it opens the copy.
    private static func loadDocumentsFromSnapshot(of historyURL: URL) -> [BrowserSearchDocument]? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenArcHistory-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? fileManager.removeItem(at: directory) }
        let copy = directory.appendingPathComponent(historyURL.lastPathComponent)
        guard (try? fileManager.copyItem(at: historyURL, to: copy)) != nil else { return nil }
        let journal = historyURL.deletingLastPathComponent()
            .appendingPathComponent(historyURL.lastPathComponent + "-journal")
        if fileManager.fileExists(atPath: journal.path) {
            try? fileManager.copyItem(at: journal, to: directory.appendingPathComponent(journal.lastPathComponent))
        }
        return loadDocuments(from: copy, readonly: false)
    }

    private static func suggestion(for document: BrowserSearchDocument) -> BrowserCommandSuggestion {
        BrowserCommandSuggestion(
            kind: .history,
            displayText: displayTitle(title: document.title, urlString: document.urlString),
            detailText: BrowserURLDisplayFormatter.displayString(for: document.urlString),
            resolvedURLString: document.urlString,
        )
    }

    // MARK: Internal

    func recentSuggestions(maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0 else { return [] }
        return withIcons(withSessionPages(
            storedRecentSuggestions(maximumCount: maximumCount),
            maximumCount: maximumCount,
        ))
    }

    func recentSuggestions(withURLPrefix prefix: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0, !prefix.isEmpty else { return [] }
        var titles = Set<String>()
        return withIcons(withSessionPages(
            storedRecentSuggestions(withURLPrefix: prefix, maximumCount: maximumCount),
            where: {
                $0.urlString.hasPrefix(prefix)
                    && titles.insert(Self.displayTitle(title: $0.title, urlString: $0.urlString)).inserted
            },
            maximumCount: maximumCount,
        ))
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
            let own = Self.loadDocuments(from: historyURL) ?? Self.loadDocumentsFromSnapshot(of: historyURL)
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
        guard !trimmedQuery.isEmpty, maximumCount > 0 else { return [] }
        let session = sessionIndex.map { index in
            index.search(trimmedQuery, limit: maximumCount).map { Self.suggestion(for: index.documents[$0]) }
        } ?? []
        let sessionURLs = Set(session.map(\.resolvedURLString))
        let stored = storedSuggestions(for: trimmedQuery, maximumCount: maximumCount)
            .filter { !sessionURLs.contains($0.resolvedURLString) }
        return withIcons(Array((session + stored).prefix(maximumCount)))
    }

    func noteVisit(title: String, urlString: String) {
        guard let scheme = URL(string: urlString)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return
        }
        var document = sessionDocuments.first { $0.urlString == urlString }
            ?? BrowserSearchDocument(title: title, urlString: urlString)
        guard document.title != title || sessionDocuments.last?.urlString != urlString else { return }
        sessionDocuments.removeAll { $0.urlString == urlString }
        document.title = title
        document.visitCount += 1
        document.lastVisit = Date().timeIntervalSince1970
        sessionDocuments.append(document)
        if sessionDocuments.count > Self.maximumSessionPages {
            sessionDocuments.removeFirst(sessionDocuments.count - Self.maximumSessionPages)
        }
        sessionIndex = BrowserSearchIndex(documents: sessionDocuments)
    }

    private func storedRecentSuggestions(maximumCount: Int) -> [BrowserCommandSuggestion] {
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
            return indexedPages(where: { !$0.urlString.hasPrefix("chrome-extension://") }, maximumCount: maximumCount)
        }
    }

    private func storedRecentSuggestions(
        withURLPrefix prefix: String,
        maximumCount: Int,
    ) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0, !prefix.isEmpty, let historyURL = existingHistoryURL else { return [] }
        let pattern = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
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
                    WHERE hidden = 0 AND url LIKE ? ESCAPE '\\'
                    ORDER BY last_visit_time DESC
                    LIMIT ?
                    """,
                    arguments: [pattern, maximumCount * 4],
                )
            }
            var titles = Set<String>()
            let unique = rows.compactMap { row -> BrowserCommandSuggestion? in
                let urlString: String = row["url"]
                // LIKE ignores case; a site's own address does not.
                guard urlString.hasPrefix(prefix) else { return nil }
                let title = Self.displayTitle(title: row["title"], urlString: urlString)
                guard titles.insert(title).inserted else { return nil }
                return BrowserCommandSuggestion(
                    kind: .history,
                    displayText: title,
                    detailText: BrowserURLDisplayFormatter.displayString(for: urlString),
                    resolvedURLString: urlString,
                )
            }
            return withIcons(Array(unique.prefix(maximumCount)))
        } catch {
            var titles = Set<String>()
            return indexedPages(where: {
                $0.urlString.hasPrefix(prefix)
                    && titles.insert(Self.displayTitle(title: $0.title, urlString: $0.urlString)).inserted
            }, maximumCount: maximumCount)
        }
    }

    /// This session's pages, newest first, then the stored ones not among them.
    private func withSessionPages(
        _ stored: [BrowserCommandSuggestion],
        where include: (BrowserSearchDocument) -> Bool = { _ in true },
        maximumCount: Int,
    ) -> [BrowserCommandSuggestion] {
        let session = sessionDocuments.reversed().filter(include).map(Self.suggestion(for:))
        let urls = Set(session.map(\.resolvedURLString))
        return Array((session + stored.filter { !urls.contains($0.resolvedURLString) }).prefix(maximumCount))
    }

    private func storedSuggestions(for trimmedQuery: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard let historyURL = existingHistoryURL else { return [] }

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

    /// The indexed pages, newest first, for when the database itself is locked.
    private func indexedPages(where include: (BrowserSearchDocument) -> Bool, maximumCount: Int)
        -> [BrowserCommandSuggestion]
    {
        guard let searchIndex else { return [] }
        return withIcons(searchIndex.documents
            .filter(include)
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(maximumCount)
            .map {
                BrowserCommandSuggestion(
                    kind: .history,
                    displayText: Self.displayTitle(title: $0.title, urlString: $0.urlString),
                    detailText: BrowserURLDisplayFormatter.displayString(for: $0.urlString),
                    resolvedURLString: $0.urlString,
                )
            })
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
