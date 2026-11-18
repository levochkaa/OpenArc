// BrowserSiteSearch.swift

import Foundation
import GRDB

// MARK: - BrowserSiteSearch

/// Site search: typing the start of a keyword in the command bar offers
/// "Search <name>", Tab scopes the bar to that site and Return opens the
/// site's own results. Keywords are Chromium's (`github.com`, or a shortcut
/// such as `@y`), and the address uses `%s` for the query, as in Chrome's
/// search engine settings.
struct BrowserSiteSearch: Codable, Equatable, Identifiable {
    // MARK: Internal

    static let queryPlaceholder = "%s"

    /// The site searches seeded into a new profile, with their chip colors in Display P3.
    static let arcDefaults: [BrowserSiteSearch] = [
        .init(
            name: "Google Drive",
            keyword: "drive.google.com",
            urlTemplate: "https://drive.google.com/drive/search?q=%s",
            colorHex: "0F9D58",
        ),
        .init(
            name: "Gmail",
            keyword: "mail.google.com",
            urlTemplate: "https://mail.google.com/mail/ca/u/0/#apps/%s",
            colorHex: "D44638",
        ),
        .init(
            name: "Google Maps",
            keyword: "maps.google.com",
            urlTemplate: "https://www.google.com/maps/search/%s",
            colorHex: "FBBC05",
        ),
        .init(
            name: "Google Calendar",
            keyword: "calendar.google.com",
            urlTemplate: "https://calendar.google.com/calendar/u/0/r/search?q=%s",
            colorHex: "9C27B0",
        ),
        .init(
            name: "Google Docs",
            keyword: "docs.google.com",
            urlTemplate: "https://docs.google.com/document/u/0/?q=%s",
            colorHex: "4285F4",
        ),
        .init(
            name: "Dropbox",
            keyword: "dropbox.com",
            urlTemplate: "https://www.dropbox.com/search/personal?&query=%s",
            colorHex: "007EE5",
        ),
        .init(
            name: "Amazon",
            keyword: "amazon.com",
            urlTemplate: "https://www.amazon.com/s?k=%s",
            colorHex: "FF9900",
        ),
        .init(
            name: "GitHub",
            keyword: "github.com",
            urlTemplate: "https://github.com/search?q=%s",
            colorHex: "743FC7",
        ),
        .init(
            name: "Figma",
            keyword: "figma.com",
            urlTemplate: "https://www.figma.com/files/search?q=%s",
            colorHex: "F24E1E",
        ),
        .init(name: "X", keyword: "x.com", urlTemplate: "https://x.com/search?q=%s", colorHex: "000000"),
        .init(
            name: "YouTube",
            keyword: "youtube.com",
            urlTemplate: "https://www.youtube.com/results?search_query=%s",
            colorHex: "FF0000",
        ),
        .init(
            name: "Wikipedia",
            keyword: "wikipedia.org",
            urlTemplate: "https://wikipedia.org/w/index.php?search=%s",
            colorHex: "FFA500",
        ),
        .init(
            name: "Reddit",
            keyword: "reddit.com",
            urlTemplate: "https://www.reddit.com/search/?q=%s",
            colorHex: "FF4500",
        ),
        .init(
            name: "SoundCloud",
            keyword: "soundcloud.com",
            urlTemplate: "https://soundcloud.com/search?q=%s",
            colorHex: "F85216",
        ),
        .init(
            name: "Asana",
            keyword: "asana.com",
            urlTemplate: "https://app.asana.com/0/search?q=%s",
            colorHex: "F06A6A",
        ),
        .init(
            name: "LinkedIn",
            keyword: "linkedin.com",
            urlTemplate: "https://linkedin.com/search/results/all/?keywords=%s",
            colorHex: "0B66C2",
        ),
        .init(
            name: "Apple Music",
            keyword: "music.apple.com",
            urlTemplate: "https://music.apple.com/us/search?term=%s",
            colorHex: "FA2A44",
        ),
        .init(
            name: "Spotify",
            keyword: "spotify.com",
            urlTemplate: "https://open.spotify.com/search/%s",
            colorHex: "1DB954",
        ),
    ]

    var id: UUID
    var name: String
    var keyword: String
    var urlTemplate: String
    /// Six hex digits of a Display P3 color; nil uses the accent color.
    var colorHex: String?

    var normalizedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var displayName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? normalizedKeyword : name
    }

    /// A keyword without spaces and an http(s) address with the placeholder.
    var isUsable: Bool {
        let keyword = normalizedKeyword
        return !keyword.isEmpty && !keyword.contains(where: \.isWhitespace)
            && searchURLString(for: "test") != nil
    }

    /// The address before the query, which every results page of the site starts with.
    var resultsURLPrefix: String? {
        let template = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = template.range(of: Self.queryPlaceholder), range.lowerBound > template.startIndex else {
            return nil
        }
        return String(template[..<range.lowerBound])
    }

    init(id: UUID = UUID(), name: String, keyword: String, urlTemplate: String, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.urlTemplate = urlTemplate
        self.colorHex = colorHex
    }

    /// The first site whose keyword is the typed text, else the shortest
    /// keyword that starts with at least two typed characters (`git` offers
    /// GitHub). Text with spaces never matches: Tab is the only trigger.
    static func match(for query: String, in searches: [BrowserSiteSearch]) -> BrowserSiteSearch? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let usable = searches.filter(\.isUsable)
        if let exact = usable.first(where: { $0.normalizedKeyword == typed }) {
            return exact
        }
        guard typed.count >= 2 else { return nil }
        return usable
            .filter { $0.normalizedKeyword.hasPrefix(typed) }
            .min { $0.normalizedKeyword.count < $1.normalizedKeyword.count }
    }

    /// Chromium's encoding: `+` for spaces in the query string, `%20` in the
    /// path or fragment (Gmail's `#apps/%s`).
    func searchURLString(for query: String) -> String? {
        let template = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = template.range(of: Self.queryPlaceholder) else { return nil }
        let prefix = template[..<range.lowerBound]
        let isInQuery = prefix.contains("?") && !prefix.contains("#")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        allowed.formIntersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        let spaceless = query.split(separator: " ", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        let encoded = spaceless.joined(separator: isInQuery ? "+" : "%20")
        let urlString = template.replacing(Self.queryPlaceholder, with: encoded)
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return nil }
        return urlString
    }
}

// MARK: - BrowserSiteSearchImport

/// Site searches from another Chromium browser's `Web Data`: the active
/// entries the user or the browser added, without the default search engines
/// and Chrome's `@tabs` / `@history` / `@bookmarks` shortcuts.
enum BrowserSiteSearchImport {
    /// Every profile of the source, Default first. The database is copied
    /// first, since a running Chromium keeps it locked.
    static func load(
        from source: BrowserBookmarkImportSource,
        fileManager: FileManager = .default,
    ) -> [BrowserSiteSearch]? {
        func rank(_ directory: URL) -> Int {
            directory.lastPathComponent == "Default" ? 0 : 1
        }
        let directories = source.chromiumProfileDirectories(fileManager: fileManager).sorted { rank($0) < rank($1) }
        return load(profileDirectories: directories, fileManager: fileManager)
    }

    /// The searches of these Chromium profiles, the first one's winning a shared
    /// keyword; nil when none has a `Web Data` file.
    static func load(profileDirectories: [URL], fileManager: FileManager = .default) -> [BrowserSiteSearch]? {
        let files = profileDirectories.map { $0.appendingPathComponent("Web Data") }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return nil }
        var result = [BrowserSiteSearch]()
        for file in files {
            for search in (try? load(webDataURL: file, fileManager: fileManager)) ?? []
                where !result.contains(where: { $0.normalizedKeyword == search.normalizedKeyword })
            {
                result.append(search)
            }
        }
        return result
    }

    static func load(webDataURL: URL, fileManager: FileManager = .default) throws -> [BrowserSiteSearch] {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("site-search-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("Web Data")
        try fileManager.copyItem(at: webDataURL, to: copy)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: copy.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            let columns = try Set(db.columns(in: "keywords").map(\.name))
            var conditions = ["prepopulate_id = 0"]
            if columns.contains("is_active") {
                conditions.append("is_active = 1")
            }
            if columns.contains("starter_pack_id") {
                conditions.append("starter_pack_id = 0")
            }
            return try Row.fetchAll(db, sql: """
            SELECT short_name, keyword, url FROM keywords
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY id
            """)
            .compactMap { row in
                siteSearch(name: row["short_name"], keyword: row["keyword"], url: row["url"])
            }
        }
    }

    /// Chromium's `{searchTerms}` becomes `%s`; its encoding and Google
    /// parameters are filled or dropped; any other parameter skips the entry.
    static func siteSearch(name: String?, keyword: String?, url: String?) -> BrowserSiteSearch? {
        guard let keyword, let url, url.contains("{searchTerms}") else { return nil }
        var template = url
            .replacing("{searchTerms}", with: BrowserSiteSearch.queryPlaceholder)
            .replacing("{inputEncoding}", with: "UTF-8")
            .replacing("{outputEncoding}", with: "UTF-8")
            .replacing("{google:baseURL}", with: "https://www.google.com/")
        template = template.replacingOccurrences(
            of: #"\{google:[^}]*\}"#,
            with: "",
            options: .regularExpression,
        )
        guard !template.contains("{") else { return nil }
        let search = BrowserSiteSearch(
            name: name ?? keyword,
            keyword: keyword,
            urlTemplate: template,
            colorHex: BrowserSiteSearch.arcDefaults.first { $0.hasSameAddress(as: template) }?.colorHex,
        )
        return search.isUsable ? search : nil
    }

    /// Imported entries replace existing ones with the same address or
    /// keyword, so a renamed keyword (`@y` for YouTube) does not leave the old
    /// one behind.
    static func merge(_ imported: [BrowserSiteSearch], into current: [BrowserSiteSearch]) -> [BrowserSiteSearch] {
        var result = current
        for search in imported {
            // Only entries that were there before the import are replaced.
            if let index = result.prefix(current.count).firstIndex(where: {
                $0.normalizedKeyword == search.normalizedKeyword || $0.hasSameAddress(as: search.urlTemplate)
            }) {
                result[index].name = search.name
                result[index].keyword = search.keyword
                result[index].urlTemplate = search.urlTemplate
                result[index].colorHex = result[index].colorHex ?? search.colorHex
            } else {
                result.append(search)
            }
        }
        return result
    }
}

extension BrowserSiteSearch {
    /// The same search address: host without `www.`, path and query. Two
    /// searches of one site with different queries (`!w` on DuckDuckGo) differ.
    func hasSameAddress(as template: String) -> Bool {
        func key(_ string: String) -> String? {
            guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let host = components.host?.lowercased() else { return nil }
            let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return bareHost + components.path.lowercased() + "?" + (components.query ?? "") + "#"
                + (components.fragment ?? "")
        }
        guard let lhs = key(urlTemplate) else { return false }
        return lhs == key(template)
    }

    /// Earlier built-in chip colors, by the color that replaced them.
    private static let retiredDefaultColors = [
        "00A96B": "0F9D58",
        "DE5C47": "D44638",
        "FCC600": "FBBC05",
        "AD43BD": "9C27B0",
        "519AF6": "4285F4",
        "0061FE": "007EE5",
        "FFA900": "FF9900",
        "8859D1": "743FC7",
        "F66526": "F24E1E",
        "FF2600": "FF0000",
        "FFB300": "FFA500",
        "FF5D00": "FF4500",
        "FB6919": "F85216",
        "007CCD": "0B66C2",
        "FD4455": "FA2A44",
    ]

    /// A built-in entry still on an earlier built-in color takes the current one.
    var withCurrentDefaultColor: BrowserSiteSearch {
        guard let colorHex, let replacement = Self.retiredDefaultColors[colorHex.uppercased()],
              Self.arcDefaults.contains(where: { $0.colorHex == replacement && $0.hasSameAddress(as: urlTemplate) })
        else { return self }
        var search = self
        search.colorHex = replacement
        return search
    }

    /// A results page's title without the site's name at its end, as
    /// "Code search results · GitHub" or "theo - YouTube".
    func resultsTitle(_ title: String) -> String {
        let name = displayName
        for separator in [" - ", " · ", " | ", " – ", " — "] {
            let suffix = separator + name
            if title.count > suffix.count, title.lowercased().hasSuffix(suffix.lowercased()) {
                return String(title.dropLast(suffix.count))
            }
        }
        return title
    }

    /// The same search under a new identity, so a restored built-in entry
    /// never shares an ID with the edited one it came from.
    var withNewID: BrowserSiteSearch {
        BrowserSiteSearch(name: name, keyword: keyword, urlTemplate: urlTemplate, colorHex: colorHex)
    }
}
