// BrowserArcSidebarImport.swift

import AppKit

// MARK: - BrowserArcSidebar

/// Arc's Spaces, pinned tabs, folders and Favorites as read from its
/// `StorableSidebar.json`. Today tabs, notes and easels are skipped; a
/// Split View contributes its tabs. Arc stores ordered dictionaries as flat
/// arrays that alternate keys and values.
struct BrowserArcSidebar: Equatable {
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
        var theme: BrowserSpaceTheme?
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
                        urlString: url,
                    )]
                }
                if let list = data["list"] {
                    return [.folder(
                        title: (child["title"] as? String).flatMap(BrowserArcSidebar.trimmed),
                        icon: BrowserArcSidebar.icon(in: (list as? [String: Any])?["customInfo"]),
                        children: children(of: childID, depth: depth + 1, visited: visited),
                    )]
                }
                if data["splitView"] != nil {
                    return children(of: childID, depth: depth + 1, visited: visited).flatMap(\.tabs)
                }
                return []
            }
        }
    }

    /// Arc's sidebar icon names, as the closest symbols.
    /// Arc's skull and its GitHub, Linear and Figma logos have no symbol and
    /// fall back to the default icon.
    static let arcIconSymbols = [
        "star": "star.fill",
        "bookmark": "bookmark.fill",
        "heart": "heart.fill",
        "flag": "flag.fill",
        "flash": "bolt.fill",
        "triangle": "triangle.fill",
        "medical": "cross.case.fill",
        "notifications": "bell.fill",
        "bulb": "lightbulb.fill",
        "shapes": "square.on.circle.fill",
        "grid": "square.grid.2x2.fill",
        "apps": "square.grid.3x3.fill",
        "layers": "square.3.layers.3d",
        "server": "server.rack",
        "albums": "rectangle.stack.fill",
        "copy": "doc.on.doc.fill",
        "folder": "folder.fill",
        "fileTrayFull": "tray.full.fill",
        "calendar": "calendar",
        "mail": "envelope.fill",
        "checkbox": "checkmark.square.fill",
        "document": "doc.fill",
        "book": "book.fill",
        "chatBubbleEllipses": "ellipsis.bubble.fill",
        "people": "person.2.fill",
        "terminal": "terminal.fill",
        "construction": "hammer.fill",
        "square": "square.fill",
        "egg": "oval.portrait.fill",
        "ellipse": "circle.fill",
        "moon": "moon.fill",
        "sunny": "sun.max.fill",
        "planet": "globe.americas.fill",
        "leaf": "leaf.fill",
        "cloud": "cloud.fill",
        "paw": "pawprint.fill",
        "bag": "bag.fill",
        "gift": "gift.fill",
        "bed": "bed.double.fill",
        "restaurant": "fork.knife",
        "barbell": "dumbbell.fill",
        "airplane": "airplane",
        "musicalNote": "music.note",
        "colorPallete": "paintpalette.fill",
        "video": "video.fill",
        "bandage": "bandage.fill",
        "code": "chevron.left.forwardslash.chevron.right",
        "baseball": "baseball.fill",
        "cloudOutline": "cloud",
        "map": "map.fill",
        "bonfire": "flame.fill",
        "pizza": "takeoutbag.and.cup.and.straw.fill",
        "receipt": "receipt.fill",
        "thumbsUp": "hand.thumbsup.fill",
        "train": "tram.fill",
        "rss": "dot.radiowaves.up.forward",
        "search": "magnifyingglass",
    ]

    /// Arc keeps the file in its Application Support folder.
    static var defaultFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Arc", isDirectory: true)
            .appendingPathComponent("StorableSidebar.json")
    }

    var spaces: [Space]
    var favorites: [Node]

    var pinnedTabCount: Int { spaces.flatMap(\.pinned).flatMap(\.tabs).count }

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
        self.spaces = Self.pairs(container["spaces"] as? [Any] ?? []).compactMap { _, value in
            guard let space = value as? [String: Any] else { return nil }
            let containerIDs = Self.pairs(space["containerIDs"] as? [Any] ?? [])
            let pinnedID = containerIDs.first { $0.key as? String == "pinned" }?.value as? String
            return Space(
                title: (space["title"] as? String).flatMap(Self.trimmed),
                icon: Self.icon(in: space["customInfo"]),
                pinned: pinnedID.map { reader.children(of: $0) } ?? [],
                theme: Self.theme(in: space["customInfo"]),
            )
        }
        let favoritesID = Self.pairs(container["topAppsContainerIDs"] as? [Any] ?? [])
            .first { key, _ in
                (key as? [String: Any])?["default"] as? Bool == true
            }?.value as? String
        self.favorites = favoritesID.map { reader.children(of: $0).flatMap(\.tabs) } ?? []
    }

    static func load(from url: URL) throws -> BrowserArcSidebar {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ImportError.missing }
        return try BrowserArcSidebar(data: data)
    }

    private static func pairs(_ array: [Any]) -> [(key: Any, value: Any)] {
        stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }

    /// Arc's own icon names, as the closest symbols; emoji come over as they are.
    private static func icon(in customInfo: Any?) -> String? {
        let iconType = (customInfo as? [String: Any])?["iconType"] as? [String: Any]
        if let emoji = iconType?["emoji_v2"] as? String { return BrowserIconImage.name(emoji: emoji) }
        guard let name = iconType?["icon"] as? String else { return nil }
        if let symbol = arcIconSymbols[name] { return symbol }
        // A name that is already a symbol comes over; anything else gets the default icon.
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? nil : name
    }

    /// A Space's colors, intensity and texture, for themes in either stored form.
    private static func theme(in customInfo: Any?) -> BrowserSpaceTheme? {
        let windowTheme = (customInfo as? [String: Any])?["windowTheme"] as? [String: Any]
        guard let background = windowTheme?["background"] as? [String: Any] else { return nil }
        let single = (background["single"] as? [String: Any])?["_0"] as? [String: Any]
        let dark = (background["appearanceBased"] as? [String: Any])?["dark"] as? [String: Any]
        guard let source = single ?? dark,
              let style = (source["style"] as? [String: Any])?["color"] as? [String: Any],
              let colorType = style["_0"] as? [String: Any]
        else { return nil }
        func color(_ value: Any?) -> BrowserSpaceTheme.Color? {
            guard let value = value as? [String: Any], value["alpha"] as? Double != 0,
                  let red = value["red"] as? Double, let green = value["green"] as? Double,
                  let blue = value["blue"] as? Double
            else { return nil }
            return BrowserSpaceTheme.Color(red, green, blue)
        }
        func payload(_ key: String) -> [String: Any]? {
            (colorType[key] as? [String: Any])?["_0"] as? [String: Any]
        }
        let colors: [BrowserSpaceTheme.Color]
        var details: [String: Any]
        if let gradient = payload("blendedGradient") {
            details = gradient
            let base = (gradient["baseColors"] as? [Any] ?? []).compactMap(color)
            let overlay = (gradient["overlayColors"] as? [Any] ?? []).compactMap(color)
            colors = Array((base + overlay).prefix(BrowserSpaceTheme.maximumColors))
        } else if let flat = payload("blendedSingleColor") ?? payload("basicColor") {
            details = flat
            colors = color(flat["color"]).map { [$0] } ?? []
        } else {
            return nil
        }
        guard let key = colors.first else { return nil }
        var theme = BrowserSpaceTheme(key: key)
        theme.colors = colors
        if (details["wheel"] as? [String: Any])?["analogous"] != nil { theme.wheel = .analogous }
        let modifiers = details["modifiers"] as? [String: Any]
        theme.intensity = modifiers?["intensityFactor"] as? Double ?? 1
        theme.noise = modifiers?["noiseFactor"] as? Double ?? 0
        theme.texture = (modifiers?["overlay"] as? String).flatMap(BrowserSpaceTheme.Texture.init) ?? .grain
        return theme
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
