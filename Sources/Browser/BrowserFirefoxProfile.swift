// BrowserFirefoxProfile.swift

import Foundation
import GRDB

// MARK: - BrowserFirefoxProfile

/// Reads a Firefox-family profile (Firefox, Zen, LibreWolf, Floorp, Waterfox).
/// Its databases are copied first, as the browser may be running.
enum BrowserFirefoxProfile {
    // MARK: Internal

    /// Profiles listed in `profiles.ini` that hold bookmarks, history or cookies.
    /// Without the file, every folder in `Profiles` is tried.
    static func profiles(in root: URL, fileManager: FileManager = .default) -> [BrowserImportProfile] {
        var listed = [(name: String, directory: URL)]()
        if let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            for section in iniSections(text) where section.name.hasPrefix("Profile") {
                guard let path = section.values["Path"], !path.isEmpty else { continue }
                let directory = section.values["IsRelative"] == "0"
                    ? URL(fileURLWithPath: path, isDirectory: true)
                    : root.appendingPathComponent(path, isDirectory: true)
                listed.append((section.values["Name"] ?? directory.lastPathComponent, directory))
            }
        }
        if listed.isEmpty {
            let folder = root.appendingPathComponent("Profiles", isDirectory: true)
            listed = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().map {
                (displayName(ofFolder: $0), folder.appendingPathComponent($0, isDirectory: true))
            }
        }
        var seen = Set<String>()
        return listed.compactMap { name, directory in
            let files = ["places.sqlite", "places.sqlite-wal", "cookies.sqlite", "cookies.sqlite-wal"]
                .map { directory.appendingPathComponent($0) }
            guard seen.insert(directory.standardizedFileURL.path).inserted,
                  fileManager.fileExists(atPath: files[0].path) || fileManager.fileExists(atPath: files[2].path)
            else { return nil }
            let lastUsed = files.compactMap {
                BrowserBookmarkImportSource.modificationDate(of: $0, fileManager: fileManager)
            }
            .max()
            return BrowserImportProfile(name: name, directory: directory, lastUsed: lastUsed)
        }
    }

    /// The toolbar, menu, Other and Mobile bookmarks, in that order. Nil
    /// without a `places.sqlite`.
    static func bookmarkItems(profileDirectory: URL) -> [BrowserBookmarkImportItem]? {
        let places = profileDirectory.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: places.path) else { return nil }
        return try? BrowserProfileImporter.readCopy(of: places) { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT b.id, b.type, b.parent, b.title, b.guid, p.url
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
            ORDER BY b.parent, b.position
            """)
            var children = [Int64: [Row]]()
            var rootIDs = [String: Int64]()
            for row in rows {
                children[row["parent"], default: []].append(row)
                if let guid: String = row["guid"] { rootIDs[guid] = row["id"] }
            }
            var visited = Set<Int64>()
            func items(in folderID: Int64) -> [BrowserBookmarkImportItem] {
                guard visited.insert(folderID).inserted else { return [] }
                return (children[folderID] ?? []).compactMap { row -> BrowserBookmarkImportItem? in
                    let type: Int = row["type"]
                    let title: String = row["title"] ?? ""
                    if type == 1 {
                        guard let url: String = row["url"], !url.isEmpty, !url.hasPrefix("place:") else { return nil }
                        return BrowserBookmarkImportItem(title: title, urlString: url, children: [])
                    }
                    guard type == 2 else { return nil }
                    let folder = BrowserBookmarkImportItem(title: title, urlString: nil, children: items(in: row["id"]))
                    return folder.children.isEmpty || isDefaultFolder(folder) ? nil : folder
                }
            }
            return ["toolbar_____", "menu________", "unfiled_____", "mobile______"]
                .compactMap { rootIDs[$0] }
                .flatMap(items(in:))
        }
    }

    /// Visited pages, newest first. Typed visits are counted from the visit list.
    static func history(profileDirectory: URL, limit: Int = 50000) -> [BrowserSearchDocument] {
        let places = profileDirectory.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: places.path) else { return [] }
        return (try? BrowserProfileImporter.readCopy(of: places) { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT p.url, p.title, p.visit_count, p.last_visit_date,
                       (SELECT COUNT(*) FROM moz_historyvisits v WHERE v.place_id = p.id AND v.visit_type = 2)
                           AS typed_count
                FROM moz_places p
                WHERE p.hidden = 0 AND p.visit_count > 0 AND p.last_visit_date IS NOT NULL
                  AND (p.url LIKE 'https://%' OR p.url LIKE 'http://%' OR p.url LIKE 'file://%')
                ORDER BY p.last_visit_date DESC
                LIMIT ?
                """,
                arguments: [limit],
            )
            .map { row in
                let lastVisit: Int64 = row["last_visit_date"]
                return BrowserSearchDocument(
                    title: row["title"] ?? "",
                    urlString: row["url"],
                    visitCount: row["visit_count"],
                    typedCount: row["typed_count"],
                    lastVisit: TimeInterval(lastVisit) / 1_000_000,
                )
            }
        }) ?? []
    }

    /// Cookies of the ordinary browsing context that have not expired. Those of
    /// containers and partitioned third-party cookies are left out.
    static func cookies(profileDirectory: URL, now: Date = Date()) -> [BrowserImportedCookie] {
        let file = profileDirectory.appendingPathComponent("cookies.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return (try? BrowserProfileImporter.readCopy(of: file) { db in
            let columns = try Set(db.columns(in: "moz_cookies").map(\.name))
            let sameSite = columns.contains("sameSite") ? "sameSite" : "0 AS sameSite"
            let origin = columns.contains("originAttributes") ? "originAttributes" : "'' AS originAttributes"
            return try Row.fetchAll(db, sql: """
            SELECT name, value, host, path, expiry, isSecure, isHttpOnly, \(sameSite), \(origin) FROM moz_cookies
            """)
            .compactMap { row -> BrowserImportedCookie? in
                let originAttributes: String = row["originAttributes"] ?? ""
                guard originAttributes.isEmpty, let host: String = row["host"], let name: String = row["name"] else {
                    return nil
                }
                let expiry: Int64 = row["expiry"] ?? 0
                // Firefox moved this column from seconds to milliseconds.
                let seconds = expiry > 100_000_000_000 ? TimeInterval(expiry) / 1000 : TimeInterval(expiry)
                guard seconds > now.timeIntervalSince1970 else { return nil }
                let isSecure: Bool = row["isSecure"] ?? false
                let firefoxSameSite: Int = row["sameSite"] ?? 0
                return BrowserImportedCookie(
                    host: host,
                    name: name,
                    value: row["value"] ?? "",
                    path: row["path"] ?? "/",
                    expires: Int64((seconds + 11_644_473_600) * 1_000_000),
                    isSecure: isSecure,
                    isHTTPOnly: row["isHttpOnly"] ?? false,
                    sameSite: chromiumSameSite(firefoxSameSite, isSecure: isSecure),
                )
            }
        }) ?? []
    }

    // MARK: Private

    /// Firefox has 0 for None, 1 for Lax, 2 for Strict and 256 for unset.
    /// Chromium refuses None without Secure, so such a cookie stays unspecified.
    private static func chromiumSameSite(_ value: Int, isSecure: Bool) -> Int {
        switch value {
        case 0: isSecure ? 0 : -1
        case 1: 1
        case 2: 2
        default: -1
        }
    }

    /// The links every new Firefox profile starts with.
    private static func isDefaultFolder(_ folder: BrowserBookmarkImportItem) -> Bool {
        folder.title == "Mozilla Firefox" && folder.children.allSatisfy { item in
            guard let host = item.urlString.flatMap(URL.init(string:))?.host?.lowercased() else { return false }
            return host == "mozilla.org" || host.hasSuffix(".mozilla.org")
        }
    }

    /// `abcd1234.default-release` reads as `default-release`.
    private static func displayName(ofFolder folder: String) -> String {
        guard let dot = folder.firstIndex(of: "."), folder.index(after: dot) < folder.endIndex else { return folder }
        return String(folder[folder.index(after: dot)...])
    }

    private static func iniSections(_ text: String) -> [(name: String, values: [String: String])] {
        var sections = [(name: String, values: [String: String])]()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty, !line.hasPrefix(";") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        return sections
    }
}
