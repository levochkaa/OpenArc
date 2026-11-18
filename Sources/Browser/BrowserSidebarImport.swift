// BrowserSidebarImport.swift

import Foundation

// MARK: - BrowserImportedSidebar

/// Another browser's Spaces, pinned tabs, folders and Favorites, read from its
/// own files. Each browser's reader fills the same shape.
struct BrowserImportedSidebar: Equatable {
    // MARK: Internal

    enum ImportError: Error, Equatable {
        case missing
        case unreadable
    }

    indirect enum Node: Equatable {
        /// `title` is the name the user gave the tab; `savedTitle` the page's own.
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
        /// The browser's Chromium profile folder for the Space, such as `Profile 2`;
        /// nil for `Default`, or where the browser keeps no Chromium profiles.
        var profileDirectory: String?
    }

    var spaces: [Space]
    var favorites: [Node]
    /// Names the browser gives its Chromium profile folders, where its own files
    /// name them better than Chromium's `Local State` does.
    var profileNames = [String: String]()

    var pinnedTabCount: Int { spaces.flatMap(\.pinned).flatMap(\.tabs).count }

    /// The sidebar `source` keeps on this Mac.
    static func load(
        _ source: BrowserBookmarkImportSource,
        locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
    ) throws -> BrowserImportedSidebar {
        switch source {
        case .arc:
            let url = locations.applicationSupport.appendingPathComponent("Arc/StorableSidebar.json")
            return try BrowserImportedSidebar(arcData: contents(of: url, fileManager: fileManager))
        case .cra:
            let url = locations.applicationSupport.appendingPathComponent("Cra/sidebar.json")
            return try BrowserImportedSidebar(craData: contents(of: url, fileManager: fileManager))
        case .crest:
            let url = locations.applicationSupport.appendingPathComponent("Crest/ControlPlane/session.sqlite")
            return try BrowserImportedSidebar(crestSessionAt: url, fileManager: fileManager)
        case .search, .vane, .yab:
            guard let directory = source.webKitAppDirectory(in: locations, fileManager: fileManager) else {
                throw ImportError.missing
            }
            return try BrowserWebKitAppImport.sidebar(of: source, directory: directory, fileManager: fileManager)
        default:
            throw ImportError.missing
        }
    }

    static func contents(of url: URL, fileManager: FileManager) throws -> Data {
        guard let data = fileManager.contents(atPath: url.path) else { throw ImportError.missing }
        return data
    }

    static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A tab for a page address the sidebar can open; nil for anything else.
    static func tab(url: Any?, title: Any? = nil, savedTitle: Any? = nil) -> Node? {
        guard let url = (url as? String).flatMap(trimmed), URL(string: url)?.scheme != nil else { return nil }
        return .tab(
            title: (title as? String).flatMap(trimmed),
            savedTitle: (savedTitle as? String).flatMap(trimmed),
            urlString: url,
        )
    }
}

// MARK: - BrowserImportedSidebar + Shared reading

extension BrowserImportedSidebar {
    /// Sidebar formats keep Swift `UUID`s in upper case; some write lower case.
    static func identifier(_ value: Any?) -> String? {
        if let string = value as? String { return trimmed(string)?.uppercased() }
        // Some formats wrap typed identifiers: `{"rawValue": "…"}`.
        return ((value as? [String: Any])?["rawValue"] as? String).flatMap(trimmed)?.uppercased()
    }

    /// An emoji comes over as an emoji icon; a plain name as a symbol, which the
    /// import checks before using.
    static func icon(_ value: Any?) -> String? {
        guard let value = (value as? String).flatMap(trimmed) else { return nil }
        return value.unicodeScalars.allSatisfy(\.isASCII) ? value : BrowserIconImage.name(emoji: value)
    }

    /// A theme from colors written as `#RRGGBB`, the first one leading.
    static func theme(hexColors: [Any], intensity: Any? = nil, noise: Any? = nil) -> BrowserSpaceTheme? {
        let colors = hexColors.compactMap { value -> BrowserSpaceTheme.Color? in
            guard var hex = (value as? String).flatMap(trimmed) else { return nil }
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6 || hex.count == 8, let number = UInt32(hex.prefix(6), radix: 16) else { return nil }
            return BrowserSpaceTheme.Color(
                Double((number >> 16) & 0xFF) / 255,
                Double((number >> 8) & 0xFF) / 255,
                Double(number & 0xFF) / 255,
            )
        }
        guard let key = colors.first else { return nil }
        var theme = BrowserSpaceTheme(key: key)
        theme.colors = Array(colors.prefix(BrowserSpaceTheme.maximumColors))
        if let intensity = intensity as? Double { theme.intensity = min(max(intensity, 0), 1) }
        if let noise = noise as? Double { theme.noise = min(max(noise, 0), 1) }
        return theme
    }
}

// MARK: - BrowserSidebarTree

/// Builds a pinned tree from tabs that each name the folders they sit in, from
/// the top down. A folder takes the place where it first appears.
struct BrowserSidebarTree {
    struct Folder: Equatable {
        let id: String
        var title: String?
        var icon: String?
    }

    private enum Entry {
        case tab(BrowserImportedSidebar.Node)
        case folder(String)
    }

    private static let maximumDepth = 32

    private var root = [Entry]()
    private var folders = [String: (folder: Folder, children: [Entry])]()

    var nodes: [BrowserImportedSidebar.Node] { nodes(of: root, depth: 0) }

    /// Adds the folders of `path` that are not there yet, keeping empty ones.
    mutating func addFolders(_ path: [Folder]) {
        var parent: String?
        for folder in path.prefix(Self.maximumDepth) {
            if folders[folder.id] == nil {
                folders[folder.id] = (folder, [])
                append(.folder(folder.id), to: parent)
            }
            parent = folder.id
        }
    }

    mutating func add(_ tab: BrowserImportedSidebar.Node, in path: [Folder] = []) {
        let path = Array(path.prefix(Self.maximumDepth))
        addFolders(path)
        append(.tab(tab), to: path.last?.id)
    }

    private mutating func append(_ entry: Entry, to parent: String?) {
        if let parent {
            folders[parent]?.children.append(entry)
        } else {
            root.append(entry)
        }
    }

    private func nodes(of entries: [Entry], depth: Int) -> [BrowserImportedSidebar.Node] {
        guard depth < Self.maximumDepth else { return [] }
        return entries.compactMap { entry in
            switch entry {
            case .tab(let node):
                return node
            case .folder(let id):
                guard let (folder, children) = folders[id] else { return nil }
                return .folder(title: folder.title, icon: folder.icon, children: nodes(of: children, depth: depth + 1))
            }
        }
    }
}

// MARK: - BrowserSidebarProfileChoice

/// Which of the source browser's profiles a sidebar import takes, by its folder
/// name (`Default`, `Profile 2`). A Space on a skipped profile stays behind; one
/// on a profile in `targets` goes to that OpenArc profile; any other goes to the window's.
struct BrowserSidebarProfileChoice: Equatable {
    var skipped = Set<String>()
    var targets = [String: String]()
}

// MARK: - BrowserSidebarImportResult

struct BrowserSidebarImportResult: Equatable {
    var spaceCount = 0
    var pinnedTabCount = 0
    var folderCount = 0
    var favoriteCount = 0

    var isEmpty: Bool { spaceCount == 0 && favoriteCount == 0 }
}
