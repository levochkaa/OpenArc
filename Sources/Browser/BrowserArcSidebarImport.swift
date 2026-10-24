import Foundation

// MARK: - BrowserArcSidebar

/// Arc's Spaces, pinned tabs, folders and Favorites as read from its
/// `StorableSidebar.json`. Today tabs, notes and easels are skipped; a
/// Split View contributes its tabs. Arc stores ordered dictionaries as flat
/// arrays that alternate keys and values.
struct BrowserArcSidebar: Equatable {
    // MARK: Lifecycle

    init(spaces: [Space], favorites: [Node]) {
        self.spaces = spaces
        self.favorites = favorites
    }

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any],
              let container = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil })
        else { throw ImportError.unreadable }

        var items = [String: [String: Any]]()
        for (key, value) in Self.pairs(container["items"] as? [Any] ?? []) {
            if let id = key as? String, let item = value as? [String: Any] {
                items[id] = item
            }
        }
        let reader = Reader(items: items)
        spaces = Self.pairs(container["spaces"] as? [Any] ?? []).compactMap { _, value in
            guard let space = value as? [String: Any] else { return nil }
            let containerIDs = Self.pairs(space["containerIDs"] as? [Any] ?? [])
            let pinnedID = containerIDs.first { $0.key as? String == "pinned" }?.value as? String
            return Space(
                title: (space["title"] as? String).flatMap(Self.trimmed),
                icon: Self.icon(in: space["customInfo"]),
                pinned: pinnedID.map { reader.children(of: $0) } ?? []
            )
        }
        let favoritesID = Self.pairs(container["topAppsContainerIDs"] as? [Any] ?? []).first { key, _ in
            (key as? [String: Any])?["default"] as? Bool == true
        }?.value as? String
        favorites = favoritesID.map { reader.children(of: $0).flatMap(\.tabs) } ?? []
    }

    // MARK: Internal

    enum ImportError: Error, Equatable {
        case missing
        case unreadable
    }

    indirect enum Node: Equatable {
        /// `title` is the name the user gave the tab in Arc.
        case tab(title: String?, savedTitle: String?, urlString: String)
        case folder(title: String?, icon: String?, children: [Node])

        // MARK: Internal

        /// Every tab in this node, depth first.
        var tabs: [Node] {
            switch self {
            case .tab: [self]
            case .folder(_, _, let children): children.flatMap(\.tabs)
            }
        }
    }

    struct Space: Equatable {
        var title: String?
        var icon: String?
        var pinned: [Node]
    }

    /// Arc keeps the file in its Application Support folder.
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Arc", isDirectory: true)
            .appendingPathComponent("StorableSidebar.json")
    }

    var spaces: [Space]
    var favorites: [Node]

    var pinnedTabCount: Int { spaces.flatMap(\.pinned).flatMap(\.tabs).count }

    static func load(from url: URL) throws -> BrowserArcSidebar {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ImportError.missing }
        return try BrowserArcSidebar(data: data)
    }

    // MARK: Private

    /// Builds nodes from the item graph, ignoring cycles and very deep trees.
    private struct Reader {
        let items: [String: [String: Any]]

        func children(of id: String, depth: Int = 0, visited: Set<String> = []) -> [Node] {
            guard depth < 32, !visited.contains(id), let item = items[id] else { return [] }
            let visited = visited.union([id])
            return (item["childrenIds"] as? [String] ?? []).flatMap { childID -> [Node] in
                guard let child = items[childID], let data = child["data"] as? [String: Any] else { return [] }
                if let tab = data["tab"] as? [String: Any] {
                    guard let url = (tab["savedURL"] as? String).flatMap(BrowserArcSidebar.trimmed),
                          URL(string: url)?.scheme != nil
                    else { return [] }
                    return [.tab(
                        title: (child["title"] as? String).flatMap(BrowserArcSidebar.trimmed),
                        savedTitle: (tab["savedTitle"] as? String).flatMap(BrowserArcSidebar.trimmed),
                        urlString: url
                    )]
                }
                if let list = data["list"] {
                    return [.folder(
                        title: (child["title"] as? String).flatMap(BrowserArcSidebar.trimmed),
                        icon: BrowserArcSidebar.icon(in: (list as? [String: Any])?["customInfo"]),
                        children: children(of: childID, depth: depth + 1, visited: visited)
                    )]
                }
                if data["splitView"] != nil {
                    return children(of: childID, depth: depth + 1, visited: visited).flatMap(\.tabs)
                }
                return []
            }
        }
    }

    private static func pairs(_ array: [Any]) -> [(key: Any, value: Any)] {
        stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }

    private static func icon(in customInfo: Any?) -> String? {
        ((customInfo as? [String: Any])?["iconType"] as? [String: Any])?["icon"] as? String
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - BrowserArcSidebarImportResult

struct BrowserArcSidebarImportResult: Equatable {
    var spaceCount = 0
    var pinnedTabCount = 0
    var folderCount = 0
    var favoriteCount = 0

    var isEmpty: Bool { spaceCount == 0 && favoriteCount == 0 }
}
