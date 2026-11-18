// BrowserWebKitAppImport.swift

import Foundation
import GRDB

// MARK: - BrowserWebKitAppImport

/// Reads the files of WebKit browsers that keep their Spaces in plain JSON:
/// Yab, Vane and Search. Their cookies and passwords stay with them. Dates in
/// their JSON are seconds since 2001, as Swift's `JSONEncoder` writes them.
enum BrowserWebKitAppImport {
    // MARK: Internal

    typealias Node = BrowserImportedSidebar.Node
    typealias Space = BrowserImportedSidebar.Space

    // MARK: Private

    /// Seconds from 1970 to 2001, where Swift's dates count from.
    private static let referenceDateOffset = Date.timeIntervalBetween1970AndReferenceDate

    static func sidebar(
        of source: BrowserBookmarkImportSource,
        directory: URL,
        fileManager: FileManager = .default,
    ) throws -> BrowserImportedSidebar {
        switch source {
        case .yab: try yabSidebar(directory: directory, fileManager: fileManager)
        case .vane: try vaneSidebar(directory: directory, fileManager: fileManager)
        case .search: try searchSidebar(directory: directory, fileManager: fileManager)
        default: throw BrowserImportedSidebar.ImportError.missing
        }
    }

    /// Bookmarks of every profile; several profiles each keep a folder of their name.
    static func bookmarkItems(
        of source: BrowserBookmarkImportSource,
        directory: URL,
        fileManager: FileManager = .default,
    ) -> [BrowserBookmarkImportItem]? {
        let lists: [(profile: String?, items: [BrowserBookmarkImportItem])]
        switch source {
        case .yab:
            guard let tree = json(directory.appendingPathComponent("bookmarks.json"), fileManager) as? [Any] else {
                return nil
            }
            return bookmarkTree(tree)
        case .search:
            let names = searchProfileNames(directory: directory, fileManager: fileManager)
            lists = files(in: directory, prefix: "bookmarks", suffix: ".json", fileManager: fileManager)
                .compactMap { suffix, url in
                    guard let tree = json(url, fileManager) as? [Any] else { return nil }
                    let profile = suffix.isEmpty ? searchPersonalProfileID : String(suffix.dropFirst()).uppercased()
                    return (names[profile] ?? (suffix.isEmpty ? nil : profile), bookmarkTree(tree))
                }
        case .vane:
            let names = vaneProfileNames(directory: directory, fileManager: fileManager)
            lists = files(in: directory, prefix: "vane", suffix: ".db", fileManager: fileManager)
                .compactMap { suffix, url in
                    guard let items = vaneBookmarks(url) else { return nil }
                    return (names[suffix] ?? (suffix.isEmpty ? nil : String(suffix.dropFirst())), items)
                }
        default:
            return nil
        }
        let found = lists.filter { !$0.items.isEmpty }
        guard !lists.isEmpty else { return nil }
        guard found.count > 1 else { return found.first?.items ?? [] }
        return found.map { list in
            BrowserBookmarkImportItem(title: list.profile ?? source.browserName, urlString: nil, children: list.items)
        }
    }

    /// Every profile's history, one entry per page, newest first.
    static func history(
        of source: BrowserBookmarkImportSource,
        directory: URL,
        limit: Int = 50000,
        fileManager: FileManager = .default,
    ) -> [BrowserSearchDocument] {
        var documents = [BrowserSearchDocument]()
        switch source {
        case .search, .yab:
            for (_, url) in files(in: directory, prefix: "history", suffix: ".json", fileManager: fileManager) {
                for case let visit as [String: Any] in json(url, fileManager) as? [Any] ?? [] {
                    guard let page = visit["url"] as? String, !page.isEmpty else { continue }
                    documents.append(BrowserSearchDocument(
                        title: visit["title"] as? String ?? "",
                        urlString: page,
                        visitCount: visit["count"] as? Int ?? 1,
                        typedCount: visit["typed"] as? Int ?? 0,
                        lastVisit: (visit["last"] as? Double).map { $0 + referenceDateOffset } ?? 0,
                    ))
                }
            }
        case .vane:
            for (_, url) in files(in: directory, prefix: "vane", suffix: ".db", fileManager: fileManager) {
                documents += vaneHistory(url, limit: limit)
            }
        default:
            return []
        }
        return Array(merged(documents).prefix(limit))
    }

    // MARK: Files

    private static func json(_ url: URL, _ fileManager: FileManager) -> Any? {
        fileManager.contents(atPath: url.path).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// Files named `<prefix><suffix-part><suffix>`, keyed by the part between,
    /// which is empty for the first profile and `-<id>` for others.
    private static func files(
        in directory: URL,
        prefix: String,
        suffix: String,
        fileManager: FileManager,
    ) -> [(part: String, url: URL)] {
        ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .map { name in
                (String(name.dropFirst(prefix.count).dropLast(suffix.count)), directory.appendingPathComponent(name))
            }
            .filter { $0.part.isEmpty || $0.part.hasPrefix("-") }
            .sorted { $0.part < $1.part }
    }

    private static func bookmarkTree(_ items: [Any], depth: Int = 0) -> [BrowserBookmarkImportItem] {
        guard depth < 32 else { return [] }
        return items.compactMap { value -> BrowserBookmarkImportItem? in
            guard let item = value as? [String: Any] else { return nil }
            let title = item["title"] as? String ?? ""
            if let url = (item["url"] as? String).flatMap(BrowserImportedSidebar.trimmed) {
                return BrowserBookmarkImportItem(title: title, urlString: url, children: [])
            }
            guard let children = item["children"] as? [Any] else { return nil }
            return BrowserBookmarkImportItem(
                title: title,
                urlString: nil,
                children: bookmarkTree(children, depth: depth + 1),
            )
        }
    }

    /// One entry per page: visits add up and the newest visit's title stays.
    private static func merged(_ documents: [BrowserSearchDocument]) -> [BrowserSearchDocument] {
        var byURL = [String: BrowserSearchDocument]()
        for document in documents {
            guard var existing = byURL[document.urlString] else {
                byURL[document.urlString] = document
                continue
            }
            if document.lastVisit > existing.lastVisit, !document.title.isEmpty {
                existing.title = document.title
            }
            existing.visitCount += document.visitCount
            existing.typedCount += document.typedCount
            existing.lastVisit = max(existing.lastVisit, document.lastVisit)
            byURL[document.urlString] = existing
        }
        return byURL.values.sorted { ($0.lastVisit, $1.urlString) > ($1.lastVisit, $0.urlString) }
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap(BrowserImportedSidebar.trimmed)
    }

    /// A symbol name for a folder; an emoji folder keeps the default icon.
    private static func folderSymbol(_ value: Any?) -> String? {
        string(value).flatMap { $0.unicodeScalars.allSatisfy(\.isASCII) ? $0 : nil }
    }
}

// MARK: - BrowserWebKitAppImport + Yab

extension BrowserWebKitAppImport {
    /// The first Space's tabs are in `session.json`; every other Space's in
    /// `session-<ID>.json`; pins shown in every Space in the `…0A11` one.
    static let yabFirstSpaceID = "00000000-0000-0000-0000-000000000001"
    static let yabSharedPinsID = "00000000-0000-0000-0000-000000000A11"

    /// Yab's `spaces.json` and each Space's session. Pin squares come over as
    /// Favorites; kept rows as pinned tabs, in folders their tabs name.
    static func yabSidebar(directory: URL, fileManager: FileManager = .default) throws -> BrowserImportedSidebar {
        let spacesURL = directory.appendingPathComponent("spaces.json")
        guard fileManager.fileExists(atPath: spacesURL.path) else { throw BrowserImportedSidebar.ImportError.missing }
        guard let spaceList = json(spacesURL, fileManager) as? [Any] else {
            throw BrowserImportedSidebar.ImportError.unreadable
        }
        func tabs(of id: String) -> [[String: Any]] {
            var names = ["session-\(id).json", "session-\(id.uppercased()).json", "session-\(id.lowercased()).json"]
            if id.uppercased() == yabFirstSpaceID { names.insert("session.json", at: 0) }
            for name in names {
                let shape = json(directory.appendingPathComponent(name), fileManager) as? [String: Any]
                let tabs = (shape?["tabs"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                if !tabs.isEmpty { return tabs }
            }
            return []
        }
        var favorites = tabs(of: yabSharedPinsID).compactMap(yabTab)
        let spaces = spaceList.compactMap { $0 as? [String: Any] }.map { space -> Space in
            var tree = BrowserSidebarTree()
            for tab in string(space["id"]).map(tabs(of:)) ?? [] {
                guard let node = yabTab(tab) else { continue }
                if tab["pin"] is String {
                    favorites.append(node)
                } else if tab["kept"] as? Bool == true {
                    tree.add(node, in: yabFolderPath(tab))
                }
            }
            let paint = space["paint"] as? [String: Any]
            return Space(
                title: string(space["name"]),
                icon: BrowserImportedSidebar.icon(space["icon"]),
                pinned: tree.nodes,
                theme: BrowserImportedSidebar.theme(
                    hexColors: paint?["colors"] as? [Any] ?? [paint?["color"]].compactMap(\.self),
                ),
                profileDirectory: nil,
            )
        }
        return BrowserImportedSidebar(spaces: spaces, favorites: favorites)
    }

    /// A pinned or kept tab returns to the page it was kept at.
    private static func yabTab(_ tab: [String: Any]) -> Node? {
        BrowserImportedSidebar.tab(
            url: string(tab["home"]) ?? tab["url"] as? String,
            title: tab["name"],
            savedTitle: string(tab["homeTitle"]) ?? tab["title"] as? String,
        )
    }

    /// `folderPath` lists the folders above the tab's own `folder`, from the top.
    private static func yabFolderPath(_ tab: [String: Any]) -> [BrowserSidebarTree.Folder] {
        guard let folder = BrowserImportedSidebar.identifier(tab["folder"]) else { return [] }
        let above = (tab["folderPath"] as? [Any] ?? []).compactMap { value -> BrowserSidebarTree.Folder? in
            guard let step = value as? [String: Any], let id = BrowserImportedSidebar.identifier(step["id"]) else {
                return nil
            }
            return BrowserSidebarTree.Folder(id: id, title: string(step["name"]), icon: folderSymbol(step["mark"]))
        }
        return above + [BrowserSidebarTree.Folder(
            id: folder,
            title: string(tab["folderName"]),
            icon: folderSymbol(tab["folderMark"]),
        )]
    }
}

// MARK: - BrowserWebKitAppImport + Search

extension BrowserWebKitAppImport {
    /// Search's `spaces.json`, `pins.json` and `pin-folders.json`. Listed pins are
    /// pinned rows, in folders; pin squares and the pins every Space shares come
    /// over as Favorites.
    static func searchSidebar(directory: URL, fileManager: FileManager = .default) throws -> BrowserImportedSidebar {
        let spacesURL = directory.appendingPathComponent("spaces.json")
        guard fileManager.fileExists(atPath: spacesURL.path) else { throw BrowserImportedSidebar.ImportError.missing }
        guard let spaceList = json(spacesURL, fileManager) as? [Any] else {
            throw BrowserImportedSidebar.ImportError.unreadable
        }
        func uppercasedKeys(_ value: Any?) -> [String: [[String: Any]]] {
            var result = [String: [[String: Any]]]()
            for (key, list) in value as? [String: Any] ?? [:] {
                result[key.uppercased()] = (list as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            }
            return result
        }
        let pins = uppercasedKeys(json(directory.appendingPathComponent("pins.json"), fileManager))
        let folderLists = uppercasedKeys(json(directory.appendingPathComponent("pin-folders.json"), fileManager))

        // Personal's shared pins, then other profiles'.
        let sharedKeys = pins.keys.filter { $0.hasPrefix("SHARED") }.sorted()
        var favorites = sharedKeys.flatMap { pins[$0] ?? [] }.compactMap(searchPin)
        let spaces = spaceList.compactMap { $0 as? [String: Any] }.map { space -> Space in
            let id = BrowserImportedSidebar.identifier(space["id"]) ?? ""
            var byID = [String: [String: Any]]()
            let folders = (folderLists[id] ?? []).filter { $0["feed"] == nil }
            for folder in folders {
                if let folderID = BrowserImportedSidebar.identifier(folder["id"]) { byID[folderID] = folder }
            }
            func path(to id: String?) -> [BrowserSidebarTree.Folder] {
                var path = [BrowserSidebarTree.Folder]()
                var next = id
                var seen = Set<String>()
                while let id = next, let folder = byID[id], seen.insert(id).inserted, seen.count <= 8 {
                    path.insert(BrowserSidebarTree.Folder(id: id, title: string(folder["name"])), at: 0)
                    next = BrowserImportedSidebar.identifier(folder["parent"])
                }
                return path
            }
            // Folders come before pins at each level.
            var tree = BrowserSidebarTree()
            for folder in folders {
                tree.addFolders(path(to: BrowserImportedSidebar.identifier(folder["id"])))
            }
            for pin in pins[id] ?? [] {
                guard let node = searchPin(pin) else { continue }
                if pin["listed"] as? Bool == true {
                    tree.add(node, in: path(to: BrowserImportedSidebar.identifier(pin["folder"])))
                } else {
                    favorites.append(node)
                }
            }
            let gradient = space["gradient"] as? [String: Any]
            return Space(
                title: string(space["name"]),
                icon: BrowserImportedSidebar.icon(space["icon"]),
                pinned: tree.nodes,
                theme: BrowserImportedSidebar.theme(hexColors: gradient?["colours"] as? [Any] ?? []),
                profileDirectory: nil,
            )
        }
        return BrowserImportedSidebar(spaces: spaces, favorites: favorites)
    }

    static let searchPersonalProfileID = "00000000-0000-0000-0000-0000000000A1"

    /// Profile names by upper-case id, from `profiles.json`.
    static func searchProfileNames(directory: URL, fileManager: FileManager = .default) -> [String: String] {
        var names = [String: String]()
        for case let profile as [String: Any] in json(
            directory.appendingPathComponent("profiles.json"),
            fileManager,
        ) as? [Any] ?? [] {
            if let id = BrowserImportedSidebar.identifier(profile["id"]), let name = string(profile["name"]) {
                names[id] = name
            }
        }
        return names
    }

    private static func searchPin(_ pin: [String: Any]) -> Node? {
        BrowserImportedSidebar.tab(url: pin["home"], title: pin["name"], savedTitle: pin["title"])
    }
}

// MARK: - BrowserWebKitAppImport + Vane

extension BrowserWebKitAppImport {
    /// Vane keeps a set of files per profile: `spaces<sfx>.json` and `vane<sfx>.db`,
    /// where `<sfx>` is empty for the first profile and `-<id>` for others.
    /// Favorites and the folders of pinned rows live in its preferences.
    static func vaneSidebar(directory: URL, fileManager: FileManager = .default) throws -> BrowserImportedSidebar {
        let spaceFiles = files(in: directory, prefix: "spaces", suffix: ".json", fileManager: fileManager)
        guard !spaceFiles.isEmpty else { throw BrowserImportedSidebar.ImportError.missing }
        let preferences = vanePreferences(directory: directory, fileManager: fileManager)
        var favorites = [Node]()
        var spaces = [Space]()
        var readAny = false
        for (suffix, url) in spaceFiles {
            guard let list = json(url, fileManager) as? [Any] else { continue }
            readAny = true
            favorites += (preferences["pinnedTabs\(suffix)"] as? [Any] ?? []).compactMap {
                BrowserImportedSidebar.tab(url: $0)
            }
            for case let space as [String: Any] in list {
                favorites += (space["pinnedURLs"] as? [Any] ?? []).compactMap { BrowserImportedSidebar.tab(url: $0) }
                let id = BrowserImportedSidebar.identifier(space["id"]) ?? ""
                spaces.append(Space(
                    title: string(space["name"]),
                    icon: BrowserImportedSidebar.icon(space["icon"]),
                    pinned: vanePinned(space, shape: preferences["pinShape.\(id)\(suffix)"]),
                    theme: BrowserImportedSidebar.theme(
                        hexColors: space["colors"] as? [Any] ?? [space["colorHex"]].compactMap(\.self),
                    ),
                    profileDirectory: nil,
                ))
            }
        }
        guard readAny else { throw BrowserImportedSidebar.ImportError.unreadable }
        return BrowserImportedSidebar(spaces: spaces, favorites: favorites)
    }

    /// Profile names by file suffix: empty for the first profile, `-<lower-case id>` for others.
    static func vaneProfileNames(directory: URL, fileManager: FileManager = .default) -> [String: String] {
        let disk = json(directory.appendingPathComponent("profiles.json"), fileManager) as? [String: Any]
        var names = [String: String]()
        for case let profile as [String: Any] in disk?["profiles"] as? [Any] ?? [] {
            guard let id = BrowserImportedSidebar.identifier(profile["id"]), let name = string(profile["name"])
            else { continue }
            names[id == "00000000-0000-0000-0000-000056616E65" ? "" : "-\(id.lowercased())"] = name
        }
        return names
    }

    /// A Space's pinned rows: its layout when it has one, else the folder shape
    /// from preferences, else its plain list of pages.
    private static func vanePinned(_ space: [String: Any], shape: Any?) -> [Node] {
        if let layout = space["layout"] as? [String: Any],
           let pins = layout["pins"] as? [String: Any],
           !(pins["entries"] as? [Any] ?? []).isEmpty
        {
            var pages = [String: Node]()
            for case let page as [String: Any] in layout["tabs"] as? [Any] ?? [] {
                guard let id = BrowserImportedSidebar.identifier(page["id"]) else { continue }
                pages[id] = BrowserImportedSidebar.tab(
                    url: string(page["home"]) ?? page["url"] as? String,
                    title: page["customName"],
                    savedTitle: page["title"],
                )
            }
            return vanePins(pins) { BrowserImportedSidebar.identifier($0).flatMap { pages[$0] } }
        }
        let shapeData = (shape as? Data) ?? (shape as? String).map { Data($0.utf8) }
        if let pins = shapeData.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] {
            let nodes = vanePins(pins) { BrowserImportedSidebar.tab(url: $0) }
            if !nodes.isEmpty { return nodes }
        }
        return (space["pinnedTabURLs"] as? [Any] ?? []).compactMap { BrowserImportedSidebar.tab(url: $0) }
    }

    /// A flat list of folders and tabs, each naming its parent folder, which comes earlier.
    private static func vanePins(_ pins: [String: Any], tab: (String) -> Node?) -> [Node] {
        var parents = [String: (folder: BrowserSidebarTree.Folder, parent: String?)]()
        func path(to id: String?) -> [BrowserSidebarTree.Folder] {
            var path = [BrowserSidebarTree.Folder]()
            var next = id
            var seen = Set<String>()
            while let id = next, let entry = parents[id], seen.insert(id).inserted, seen.count <= 8 {
                path.insert(entry.folder, at: 0)
                next = entry.parent
            }
            return path
        }
        var tree = BrowserSidebarTree()
        for case let entry as [String: Any] in pins["entries"] as? [Any] ?? [] {
            let row = entry["row"] as? [String: Any] ?? [:]
            let parent = BrowserImportedSidebar.identifier(entry["parent"])
            if let folder = (row["folder"] as? [String: Any]).map({ $0["_0"] as? [String: Any] ?? $0 }),
               let id = BrowserImportedSidebar.identifier(folder["id"])
            {
                parents[id] = (
                    BrowserSidebarTree.Folder(
                        id: id,
                        title: string(folder["name"]),
                        icon: folderSymbol(folder["icon"]),
                    ),
                    parent,
                )
                tree.addFolders(path(to: id))
            } else if let value = row["tab"] {
                let reference = (value as? [String: Any])?["_0"] ?? value
                guard let reference = reference as? String, let node = tab(reference) else { continue }
                tree.add(node, in: path(to: parent))
            }
        }
        return tree.nodes
    }

    /// Vane's preferences plist, beside its Application Support folder in its container.
    private static func vanePreferences(directory: URL, fileManager: FileManager) -> [String: Any] {
        let url = directory.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Preferences/io.github.notnaki.vane.plist")
        guard let data = fileManager.contents(atPath: url.path) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }

    /// Bookmarks of one profile: folders by position, each with its bookmarks, then the rest.
    private static func vaneBookmarks(_ url: URL) -> [BrowserBookmarkImportItem]? {
        try? BrowserProfileImporter.readCopy(of: url) { db in
            let hasFolders = try db.tableExists("bookmark_folders")
            let hasFolderColumn = try db.columns(in: "bookmarks").contains { $0.name == "folder_id" }
            let bookmarks = try Row.fetchAll(
                db,
                sql: "SELECT url, title\(hasFolderColumn ? ", folder_id" : "") FROM bookmarks ORDER BY at, id",
            )
            func item(_ row: Row) -> BrowserBookmarkImportItem {
                BrowserBookmarkImportItem(title: row["title"] ?? "", urlString: row["url"], children: [])
            }
            var filed = Set<String>()
            var items = [BrowserBookmarkImportItem]()
            if hasFolders, hasFolderColumn {
                for folder in try Row.fetchAll(db, sql: "SELECT id, name FROM bookmark_folders ORDER BY position") {
                    let id: String = folder["id"]
                    filed.insert(id.uppercased())
                    let children = bookmarks.filter { ($0["folder_id"] as String?)?.uppercased() == id.uppercased() }
                    items.append(BrowserBookmarkImportItem(
                        title: folder["name"],
                        urlString: nil,
                        children: children.map(item),
                    ))
                }
            }
            let loose = bookmarks.filter { row in
                guard hasFolderColumn, let folder: String = row["folder_id"] else { return true }
                return !filed.contains(folder.uppercased())
            }
            return items + loose.map(item)
        }
    }

    private static func vaneHistory(_ url: URL, limit: Int) -> [BrowserSearchDocument] {
        (try? BrowserProfileImporter.readCopy(of: url) { db in
            // SQLite takes the title from the row with the latest visit.
            try Row.fetchAll(
                db,
                sql: """
                SELECT url, title, MAX(at) AS last, COUNT(*) AS visits
                FROM visits
                GROUP BY url
                ORDER BY last DESC
                LIMIT \(limit)
                """,
            )
            .map { row in
                BrowserSearchDocument(
                    title: row["title"] ?? "",
                    urlString: row["url"],
                    visitCount: row["visits"],
                    lastVisit: row["last"],
                )
            }
        }) ?? []
    }
}
