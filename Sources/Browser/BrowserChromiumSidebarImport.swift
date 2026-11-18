// BrowserChromiumSidebarImport.swift

import Foundation
import GRDB

// MARK: - BrowserImportedSidebar + Cra

/// Cra keeps its sidebar in `sidebar.json`: Spaces, and every item in one flat
/// list that names its children. Item kinds are Swift enum cases:
/// `{"tab": {"_0": {…}}}`, `{"folder": {}}`, `{"container": {"_0": {"pinned": …}}}`,
/// `{"split": {"_0": {…}}}`. A Space on another profile names it by `profileID`,
/// whose Chromium folder is `Profile <ID>`.
extension BrowserImportedSidebar {
    private struct CraReader {
        let items: [String: [String: Any]]

        func children(of id: String, depth: Int = 0, visited: Set<String> = []) -> [Node] {
            guard depth < 32, !visited.contains(id), let item = items[id] else { return [] }
            let visited = visited.union([id])
            return (item["children"] as? [Any] ?? []).compactMap(BrowserImportedSidebar.identifier).flatMap {
                childID -> [Node] in
                guard let child = items[childID], let data = child["data"] as? [String: Any] else { return [] }
                if let tab = (data["tab"] as? [String: Any])?["_0"] as? [String: Any] {
                    // A pinned tab returns to its saved page; `url` is where it was last.
                    return BrowserImportedSidebar.tab(
                        url: (tab["savedURL"] as? String)
                            .flatMap(BrowserImportedSidebar.trimmed) ?? tab["url"] as? String,
                        title: child["title"],
                        savedTitle: tab["savedTitle"],
                    )
                    .map { [$0] } ?? []
                }
                if data["folder"] != nil {
                    return [.folder(
                        title: (child["title"] as? String).flatMap(BrowserImportedSidebar.trimmed),
                        icon: (child["folderSymbol"] as? String).flatMap(BrowserImportedSidebar.trimmed),
                        children: children(of: childID, depth: depth + 1, visited: visited),
                    )]
                }
                if data["split"] != nil {
                    return children(of: childID, depth: depth + 1, visited: visited).flatMap(\.tabs)
                }
                return []
            }
        }
    }

    init(craData data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaceList = root["spaces"] as? [Any]
        else { throw ImportError.unreadable }
        var items = [String: [String: Any]]()
        for case let item as [String: Any] in root["items"] as? [Any] ?? [] {
            if let id = Self.identifier(item["id"]) {
                items[id] = item
            }
        }
        let reader = CraReader(items: items)
        var profileNames = [String: String]()
        var profiles = Set<String>()
        for case let profile as [String: Any] in root["profiles"] as? [Any] ?? [] {
            guard let id = Self.identifier(profile["id"]) else { continue }
            profiles.insert("Profile \(id)")
            if let name = (profile["name"] as? String).flatMap(Self.trimmed) {
                profileNames["Profile \(id)"] = name
            }
        }

        // `spaceOrder` sets the order; a Space of a Blank Window is not in the sidebar.
        let order = (root["spaceOrder"] as? [Any] ?? []).compactMap(Self.identifier)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = spaceList.compactMap { $0 as? [String: Any] }.filter { $0["standaloneWindowID"] == nil }
        let sorted = listed.enumerated()
            .sorted { lhs, rhs in
                let left = Self.identifier(lhs.element["id"]).flatMap { rank[$0] } ?? Int.max
                let right = Self.identifier(rhs.element["id"]).flatMap { rank[$0] } ?? Int.max
                return (left, lhs.offset) < (right, rhs.offset)
            }
            .map(\.element)

        var favoriteContainers = Set<String>()
        var favorites = [Node]()
        // Older files kept one Favorites list for the whole sidebar.
        if let id = Self.identifier(root["favoritesContainerID"]) {
            favoriteContainers.insert(id)
            favorites = reader.children(of: id).flatMap(\.tabs)
        }
        self.spaces = sorted.map { space in
            // Spaces on one profile may share one Favorites list.
            if let id = Self.identifier(space["favoritesContainerID"]), favoriteContainers.insert(id).inserted {
                favorites += reader.children(of: id).flatMap(\.tabs)
            }
            let profile = Self.identifier(space["profileID"]).map { "Profile \($0)" }
            let emoji = (space["emoji"] as? String).flatMap(Self.trimmed)
            let colors = (space["theme"] as? [String: Any])?["colors"] as? [Any] ?? []
            let theme = space["theme"] as? [String: Any]
            return Space(
                title: (space["title"] as? String).flatMap(Self.trimmed),
                icon: emoji.map(BrowserIconImage.name(emoji:)) ?? (space["symbol"] as? String).flatMap(Self.trimmed),
                pinned: Self.identifier(space["pinnedContainerID"]).map { reader.children(of: $0) } ?? [],
                theme: Self.theme(hexColors: colors, intensity: theme?["intensity"], noise: theme?["noise"]),
                // A profile Cra no longer lists falls back to its first.
                profileDirectory: profile.flatMap { profiles.contains($0) ? $0 : nil },
            )
        }
        self.favorites = favorites
        self.profileNames = profileNames
    }
}

// MARK: - BrowserImportedSidebar + Crest

/// Crest keeps its session as JSON in the `checkpoint` table of
/// `ControlPlane/session.sqlite`, in the `core` row. Each Space has its own
/// Chromium profile, `Crest-<ID>`; its tabs are `pinned` (the icon grid, taken as
/// Favorites), `saved` (the pinned list, with folders) or `current` (open tabs).
extension BrowserImportedSidebar {
    init(crestSessionAt url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { throw ImportError.missing }
        let data = try? BrowserProfileImporter.readCopy(of: url) { db in
            try Data.fetchOne(db, sql: "SELECT data FROM checkpoint WHERE part = 'core'")
        }
        guard let data else { throw ImportError.unreadable }
        try self.init(crestCheckpoint: data)
    }

    init(crestCheckpoint data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaceList = root["spaces"] as? [Any]
        else { throw ImportError.unreadable }
        var favorites = [Node]()
        var profileSpaces = [String: [String]]()
        self.spaces = spaceList.compactMap { $0 as? [String: Any] }.map { space in
            let tabs = (space["tabs"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            favorites += tabs.filter { Self.crestSection($0) == "pinned" }.compactMap(Self.crestTab)
            let title = (space["name"] as? String).flatMap(Self.trimmed)
            // A Space that shares another's sign-ins browses in that profile.
            let profileID = Self.identifier(space["sharedProfileID"])
                ?? Self.identifier((space["profile"] as? [String: Any])?["id"])
            let profile = profileID.map { "Crest-\($0)" }
            if let profile, let title {
                profileSpaces[profile, default: []].append(title)
            }
            // A Space drawn as a layered crest keeps a symbol it does not show.
            let branding = space["branding"] as? [String: Any]
            var icon = branding?["iconStyle"] as? String == "layeredCrest"
                ? nil
                : (space["symbol"] as? String).flatMap(Self.trimmed)
            if let emoji = icon?.dropPrefix("crest.emoji:") {
                icon = BrowserIconImage.name(emoji: emoji)
            }
            return Space(
                title: title,
                icon: icon,
                pinned: Self.crestSavedTree(tabs: tabs, folders: space["folders"] as? [Any] ?? []),
                theme: nil,
                profileDirectory: profile,
            )
        }
        self.favorites = favorites
        self.profileNames = profileSpaces.mapValues { $0.joined(separator: ", ") }
    }

    /// Where a tab sits; an unknown value reads as `saved`, as Crest reads it.
    private static func crestSection(_ tab: [String: Any]) -> String {
        let placement = tab["placement"] as? String
        return placement == "pinned" || placement == "current" ? placement ?? "saved" : "saved"
    }

    /// A saved or pinned tab returns to its saved page. Start Pages and native views have none.
    private static func crestTab(_ tab: [String: Any]) -> Node? {
        guard tab["nativeContent"] == nil else { return nil }
        return BrowserImportedSidebar.tab(
            url: (tab["savedURL"] as? String).flatMap(BrowserImportedSidebar.trimmed) ?? tab["url"] as? String,
            title: tab["customTitle"],
            savedTitle: tab["savedTitle"] as? String ?? tab["title"] as? String,
        )
    }

    /// The Saved section: tabs in order, each folder where its first tab is; an
    /// empty folder before the tab it is anchored to, or at the end.
    private static func crestSavedTree(tabs: [[String: Any]], folders: [Any]) -> [Node] {
        var byID = [String: [String: Any]]()
        for case let folder as [String: Any] in folders {
            guard (folder["location"] as? String ?? "saved") != "current",
                  let id = identifier(folder["id"])
            else { continue }
            byID[id] = folder
        }
        func path(to id: String?) -> [BrowserSidebarTree.Folder] {
            var path = [BrowserSidebarTree.Folder]()
            var next = id
            var seen = Set<String>()
            while let id = next, let folder = byID[id], seen.insert(id).inserted, seen.count <= 16 {
                path.insert(BrowserSidebarTree.Folder(
                    id: id,
                    title: (folder["title"] as? String).flatMap(trimmed),
                    icon: (folder["symbol"] as? String).flatMap(trimmed),
                ), at: 0)
                next = identifier(folder["parentID"])
            }
            return path
        }
        let order = folders.compactMap { ($0 as? [String: Any]).flatMap { identifier($0["id"]) } }
            .filter { byID[$0] != nil }
        var anchored = [String: [String]]()
        for id in order {
            if let anchor = byID[id].flatMap({ identifier($0["orderAnchorTabID"]) }) {
                anchored[anchor, default: []].append(id)
            }
        }
        var tree = BrowserSidebarTree()
        for tab in tabs where crestSection(tab) == "saved" {
            for folder in identifier(tab["id"]).flatMap({ anchored[$0] }) ?? [] {
                tree.addFolders(path(to: folder))
            }
            guard let node = crestTab(tab) else { continue }
            tree.add(node, in: path(to: identifier(tab["folderID"])))
        }
        // Empty folders left over go last; those already placed stay.
        for folder in order {
            tree.addFolders(path(to: folder))
        }
        return tree.nodes
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
