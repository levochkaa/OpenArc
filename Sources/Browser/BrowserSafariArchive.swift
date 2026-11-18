// BrowserSafariArchive.swift

import Foundation
import ZIPFoundation

// MARK: - BrowserSafariArchive

/// The ZIP Safari writes with File > Export Browsing Data: `Bookmarks.html`,
/// one `History.json` per Safari profile and `Passwords.csv`. Files are told
/// apart by type and content rather than by name.
struct BrowserSafariArchive {
    // MARK: Private

    private struct HistoryFile: Decodable {
        struct Metadata: Decodable {
            enum CodingKeys: String, CodingKey { case dataType = "data_type" }

            let dataType: String
        }

        struct Entry: Decodable {
            enum CodingKeys: String, CodingKey {
                case url
                case title
                case timeUsec = "time_usec"
                case visitCount = "visit_count"
            }

            let url: String
            let title: String?
            /// Safari sometimes writes whole numbers with a fraction.
            let timeUsec: Double?
            let visitCount: Double?
        }

        let metadata: Metadata
        let history: [Entry]?
    }

    private static let maximumHistoryFileSize = 512 * 1024 * 1024
    private static let maximumPasswordsFileSize = 64 * 1024 * 1024

    // MARK: Internal

    let url: URL

    // MARK: Parsing

    /// Entries of a history file, whose metadata says `"data_type": "history"`;
    /// nil for any other JSON.
    static func historyDocuments(fromJSON data: Data) -> [BrowserSearchDocument]? {
        guard let file = try? JSONDecoder().decode(HistoryFile.self, from: data),
              file.metadata.dataType == "history"
        else { return nil }
        return (file.history ?? []).compactMap { entry in
            guard let scheme = URL(string: entry.url)?.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme)
            else { return nil }
            return BrowserSearchDocument(
                title: entry.title ?? "",
                urlString: entry.url,
                visitCount: max(1, Int(entry.visitCount ?? 1)),
                typedCount: 0,
                lastVisit: (entry.timeUsec ?? 0) / 1_000_000,
            )
        }
    }

    /// Passwords from the `Title,URL,Username,Password,Notes,OTPAuth` file,
    /// found by their column names.
    static func logins(fromCSV data: Data) -> [(login: BrowserSavedLogin, password: String)] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let rows = csvRows(text)
        guard let header = rows.first?.map({
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }),
              let urlColumn = header.firstIndex(of: "url"),
              let usernameColumn = header.firstIndex(of: "username"),
              let passwordColumn = header.firstIndex(of: "password")
        else { return [] }
        return rows.dropFirst().compactMap { row in
            guard row.count > max(urlColumn, usernameColumn, passwordColumn),
                  let origin = BrowserChromeModel.passwordOrigin(ofURLString: row[urlColumn]),
                  !row[passwordColumn].isEmpty
            else { return nil }
            return (BrowserSavedLogin(origin: origin, username: row[usernameColumn]), row[passwordColumn])
        }
    }

    /// Fields of a comma-separated text, with quoted fields holding commas,
    /// line breaks and doubled quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows = [[String]]()
        var row = [String]()
        var field = ""
        var isQuoted = false
        var characters = text.makeIterator()
        var pending = characters.next()
        while let character = pending {
            pending = characters.next()
            if isQuoted {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        isQuoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                isQuoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character.isNewline {
                row.append(field)
                field = ""
                if row != [""] {
                    rows.append(row)
                }
                row = []
            } else if character != "\u{FEFF}" {
                field.append(character)
            }
        }
        row.append(field)
        if row != [""] {
            rows.append(row)
        }
        return rows
    }

    private static func merged(_ lists: [[BrowserSearchDocument]], limit: Int) -> [BrowserSearchDocument] {
        var byURL = [String: BrowserSearchDocument]()
        for document in lists.joined() {
            guard var existing = byURL[document.urlString] else {
                byURL[document.urlString] = document
                continue
            }
            existing.visitCount += document.visitCount
            if document.lastVisit > existing.lastVisit {
                existing.lastVisit = document.lastVisit
                existing.title = document.title.isEmpty ? existing.title : document.title
            }
            byURL[document.urlString] = existing
        }
        return Array(byURL.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit))
    }

    /// Nil when the archive cannot be opened or holds no bookmarks file.
    func bookmarkItems() -> [BrowserBookmarkImportItem]? {
        var found = false
        var result: [BrowserBookmarkImportItem]?
        forEachFile(withExtension: "html", maximumSize: BrowserChromiumBookmarkStore.maximumSafariBookmarksFileSize) {
            found = true
            let items = BrowserChromiumBookmarkStore.importItems(fromSafariHTMLData: $0)
            if !items.isEmpty, result == nil {
                result = items
            }
        }
        return result ?? (found ? [] : nil)
    }

    /// Pages from every profile's history, a page visited in several counted once.
    func history(limit: Int = 50000) -> [BrowserSearchDocument] {
        var lists = [[BrowserSearchDocument]]()
        forEachFile(withExtension: "json", maximumSize: Self.maximumHistoryFileSize) {
            if let documents = Self.historyDocuments(fromJSON: $0) {
                lists.append(documents)
            }
        }
        return Self.merged(lists, limit: limit)
    }

    func logins() -> [(login: BrowserSavedLogin, password: String)] {
        var result = [(login: BrowserSavedLogin, password: String)]()
        forEachFile(withExtension: "csv", maximumSize: Self.maximumPasswordsFileSize) {
            for entry in Self.logins(fromCSV: $0) where !result.contains(where: { $0.login == entry.login }) {
                result.append(entry)
            }
        }
        return result
    }

    /// Calls `body` with each file of the type, leaving out macOS's resource
    /// forks and files over the size limit.
    private func forEachFile(withExtension pathExtension: String, maximumSize: Int, _ body: (Data) -> Void) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return }
        for entry in archive where entry.type == .file {
            let path = URL(fileURLWithPath: entry.path)
            guard path.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame,
                  !path.lastPathComponent.hasPrefix("."),
                  !entry.path.hasPrefix("__MACOSX/"),
                  UInt64(entry.uncompressedSize) <= UInt64(maximumSize)
            else { continue }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            guard (try? archive.extract(entry) { data.append($0) }) != nil else { continue }
            body(data)
        }
    }
}
