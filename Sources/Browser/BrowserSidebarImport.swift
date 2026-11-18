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
