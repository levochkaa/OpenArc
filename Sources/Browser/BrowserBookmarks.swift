// BrowserBookmarks.swift

import Combine
import Foundation

// MARK: - BrowserBookmarkItem

struct BrowserBookmarkItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case bookmark
        case folder
    }

    let id: String
    let kind: Kind
    let title: String
    let urlString: String?
    let children: [BrowserBookmarkItem]

    var isFolder: Bool {
        kind == .folder
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        guard
            let urlString,
            let host = URL(string: urlString)?.host,
            !host.isEmpty
        else {
            return BrowserStrings.newTabTitle
        }

        return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
    }

    var faviconURL: URL? {
        urlString.flatMap(BrowserFaviconCache.pageIconURL(forPageURLString:))
    }

    var hostDisplayString: String? {
        guard let urlString else {
            return nil
        }

        let displayString = BrowserURLDisplayFormatter.displayString(for: urlString)
        return displayString.isEmpty ? nil : displayString
    }

    var flattenedBookmarkURLStrings: [String] {
        if let urlString {
            return [urlString]
        }

        return children.flatMap(\.flattenedBookmarkURLStrings)
    }

    static func find(id: String, in items: [BrowserBookmarkItem]) -> BrowserBookmarkItem? {
        for item in items {
            if item.id == id { return item }
            if let found = find(id: id, in: item.children) { return found }
        }
        return nil
    }

    /// The folder holding `id`, nil for the bar itself; `.none` when it is not there.
    static func parentFolderID(of id: String, in items: [BrowserBookmarkItem]) -> String?? {
        if items.contains(where: { $0.id == id }) { return .some(nil) }
        for item in items where item.isFolder {
            if item.children.contains(where: { $0.id == id }) { return .some(item.id) }
            if let found = parentFolderID(of: id, in: item.children) { return found }
        }
        return .none
    }

    func contains(id: String) -> Bool {
        self.id == id || children.contains { $0.contains(id: id) }
    }
}

// MARK: - BrowserBookmarkClipboardItem

/// A bookmark or folder tree on the pasteboard, without the IDs of its source.
struct BrowserBookmarkClipboardItem: Codable, Equatable {
    let title: String
    let urlString: String?
    let children: [BrowserBookmarkClipboardItem]

    init(title: String, urlString: String?, children: [BrowserBookmarkClipboardItem] = []) {
        self.title = title
        self.urlString = urlString
        self.children = children
    }

    init(_ item: BrowserBookmarkItem) {
        self.init(title: item.title, urlString: item.urlString, children: item.children.map(Self.init))
    }
}

// MARK: - BrowserBookmarkImportResult

struct BrowserBookmarkImportResult: Equatable {
    let source: BrowserBookmarkImportSource
    let importedCount: Int
    let sourceWasAvailable: Bool
}

// MARK: - BrowserBookmarkStoring

protocol BrowserBookmarkStoring {
    func loadBookmarkBarItems() -> [BrowserBookmarkItem]
    func containsBookmark(urlString: String) -> Bool
    func addBookmark(title: String, urlString: String) -> Bool
    func removeBookmark(urlString: String) -> Bool
    func deleteBookmark(id: String) -> Bool
    func renameBookmark(id: String, title: String) -> Bool
    func updateBookmarkAddress(id: String, urlString: String) -> Bool
    func moveBookmark(id: String, toFolderID: String?) -> Bool
    func createFolder(title: String) -> String?
    /// `index` counts the destination's current children, as a drop indicator shows them.
    func moveBookmark(id: String, toFolderID: String?, atIndex index: Int) -> Bool
    /// Unlike `addBookmark`, keeps duplicates, as a drop or paste asks for this exact place.
    func insertBookmark(title: String, urlString: String, toFolderID: String?, atIndex index: Int?) -> String?
    func insertFolder(title: String, toFolderID: String?, atIndex index: Int?) -> String?
    func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult
    func importSafariBookmarks(from sourceURL: URL) -> BrowserBookmarkImportResult
    /// Adds bookmarks another browser's reader already found, in a folder named for it.
    func importBookmarkItems(
        _ items: [BrowserBookmarkImportItem],
        from source: BrowserBookmarkImportSource,
    ) -> BrowserBookmarkImportResult
}

extension BrowserBookmarkStoring {
    func moveBookmark(id _: String, toFolderID _: String?, atIndex _: Int) -> Bool { false }
    func insertBookmark(title _: String, urlString _: String, toFolderID _: String?, atIndex _: Int?) -> String? { nil }
    func insertFolder(title _: String, toFolderID _: String?, atIndex _: Int?) -> String? { nil }

    func importSafariBookmarks(from _: URL) -> BrowserBookmarkImportResult {
        BrowserBookmarkImportResult(source: .safari, importedCount: 0, sourceWasAvailable: false)
    }

    func importBookmarkItems(
        _: [BrowserBookmarkImportItem],
        from source: BrowserBookmarkImportSource,
    ) -> BrowserBookmarkImportResult {
        BrowserBookmarkImportResult(source: source, importedCount: 0, sourceWasAvailable: false)
    }
}

// MARK: - BrowserEmptyBookmarkStore

struct BrowserEmptyBookmarkStore: BrowserBookmarkStoring {
    func loadBookmarkBarItems() -> [BrowserBookmarkItem] {
        []
    }

    func containsBookmark(urlString _: String) -> Bool {
        false
    }

    func addBookmark(title _: String, urlString _: String) -> Bool {
        false
    }

    func removeBookmark(urlString _: String) -> Bool {
        false
    }

    func deleteBookmark(id _: String) -> Bool {
        false
    }

    func renameBookmark(id _: String, title _: String) -> Bool {
        false
    }

    func updateBookmarkAddress(id _: String, urlString _: String) -> Bool {
        false
    }

    func moveBookmark(id _: String, toFolderID _: String?) -> Bool {
        false
    }

    func createFolder(title _: String) -> String? {
        nil
    }

    func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult {
        BrowserBookmarkImportResult(source: source, importedCount: 0, sourceWasAvailable: false)
    }
}

// MARK: - BrowserBookmarksModel

@MainActor final class BrowserBookmarksModel: ObservableObject {
    // MARK: Internal

    @Published private(set) var bookmarkBarItems = [BrowserBookmarkItem]()

    // MARK: Private

    private let store: BrowserBookmarkStoring

    var isEmpty: Bool {
        bookmarkBarItems.isEmpty
    }

    init(store: BrowserBookmarkStoring = BrowserEmptyBookmarkStore()) {
        self.store = store
    }

    func reload() {
        bookmarkBarItems = store.loadBookmarkBarItems()
    }

    func containsBookmark(urlString: String) -> Bool {
        BrowserBookmarkSearch.containsBookmark(in: bookmarkBarItems, urlString: urlString)
    }

    @discardableResult func addBookmark(title: String, urlString: String) -> Bool {
        guard store.addBookmark(title: title, urlString: urlString) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func toggleBookmark(title: String, urlString: String) -> Bool {
        if containsBookmark(urlString: urlString) {
            return removeBookmark(urlString: urlString)
        }

        return addBookmark(title: title, urlString: urlString)
    }

    @discardableResult func removeBookmark(urlString: String) -> Bool {
        guard store.removeBookmark(urlString: urlString) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func deleteBookmark(id: String) -> Bool {
        guard store.deleteBookmark(id: id) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func renameBookmark(id: String, title: String) -> Bool {
        guard store.renameBookmark(id: id, title: title) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func updateBookmarkAddress(id: String, urlString: String) -> Bool {
        guard store.updateBookmarkAddress(id: id, urlString: urlString) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func moveBookmark(id: String, toFolderID: String?) -> Bool {
        guard store.moveBookmark(id: id, toFolderID: toFolderID) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func createFolder(title: String) -> String? {
        guard let folderID = store.createFolder(title: title) else {
            return nil
        }

        reload()
        return folderID
    }

    @discardableResult func moveBookmark(id: String, toFolderID: String?, atIndex index: Int) -> Bool {
        guard store.moveBookmark(id: id, toFolderID: toFolderID, atIndex: index) else {
            return false
        }

        reload()
        return true
    }

    @discardableResult func insertBookmark(
        title: String,
        urlString: String,
        toFolderID: String?,
        atIndex index: Int?,
    ) -> String? {
        guard let id = store.insertBookmark(title: title, urlString: urlString, toFolderID: toFolderID, atIndex: index)
        else { return nil }
        reload()
        return id
    }

    @discardableResult func insertFolder(title: String, toFolderID: String?, atIndex index: Int?) -> String? {
        guard let id = store.insertFolder(title: title, toFolderID: toFolderID, atIndex: index) else { return nil }
        reload()
        return id
    }

    /// Pastes a bookmark or a whole folder. Returns false if anything could not be added.
    @discardableResult func insert(
        copyOf item: BrowserBookmarkClipboardItem,
        toFolderID: String?,
        atIndex index: Int?,
    ) -> Bool {
        let didInsert = insertTree(item, toFolderID: toFolderID, atIndex: index)
        reload()
        return didInsert
    }

    func item(withID id: String) -> BrowserBookmarkItem? {
        BrowserBookmarkItem.find(id: id, in: bookmarkBarItems)
    }

    @discardableResult func createFolderAndMoveBookmark(title: String, bookmarkID: String) -> Bool {
        guard let folderID = store.createFolder(title: title) else {
            return false
        }

        guard store.moveBookmark(id: bookmarkID, toFolderID: folderID) else {
            reload()
            return false
        }

        reload()
        return true
    }

    @discardableResult func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult {
        let result = store.importBookmarks(from: source)
        reload()
        return result
    }

    @discardableResult func importSafariBookmarks(from sourceURL: URL) -> BrowserBookmarkImportResult {
        let result = store.importSafariBookmarks(from: sourceURL)
        reload()
        return result
    }

    @discardableResult func importBookmarkItems(
        _ items: [BrowserBookmarkImportItem],
        from source: BrowserBookmarkImportSource,
    ) -> BrowserBookmarkImportResult {
        let result = store.importBookmarkItems(items, from: source)
        reload()
        return result
    }

    func suggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let normalizedQuery = BrowserBookmarkSearch.normalized(query)
        guard !normalizedQuery.isEmpty, maximumCount > 0 else {
            return []
        }

        return BrowserBookmarkSearch
            .matchingBookmarks(in: bookmarkBarItems, query: normalizedQuery)
            .prefix(maximumCount)
            .map { item in
                BrowserCommandSuggestion(
                    kind: .bookmark,
                    displayText: item.displayTitle,
                    detailText: item.urlString.map(BrowserCommandSuggestion.addressText(for:)),
                    resolvedURLString: item.urlString ?? "",
                )
            }
    }

    private func insertTree(_ item: BrowserBookmarkClipboardItem, toFolderID: String?, atIndex index: Int?) -> Bool {
        if let urlString = item.urlString {
            return store.insertBookmark(title: item.title, urlString: urlString, toFolderID: toFolderID, atIndex: index)
                != nil
        }
        guard let folderID = store.insertFolder(title: item.title, toFolderID: toFolderID, atIndex: index) else {
            return false
        }
        return item.children.map { insertTree($0, toFolderID: folderID, atIndex: nil) }.allSatisfy(\.self)
    }
}

// MARK: - BrowserChromiumProfileDirectoryResolver

enum BrowserChromiumProfileDirectoryResolver {
    // MARK: Internal

    static func profileDirectoryCandidates(profileDirectoryURL: URL) -> [URL] {
        uniqueURLs([
            profileDirectoryURL,
            profileDirectoryURL.appendingPathComponent("Default", isDirectory: true),
        ])
    }

    static func profileDirectoryCandidates(rootCacheURL: URL, cacheURL: URL) -> [URL] {
        uniqueURLs([
            rootCacheURL.appendingPathComponent("Default", isDirectory: true),
            cacheURL.appendingPathComponent("Default", isDirectory: true),
            cacheURL,
            rootCacheURL
                .appendingPathComponent("Profile", isDirectory: true)
                .appendingPathComponent("Default", isDirectory: true),
        ])
    }

    // MARK: Private

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else {
                return false
            }

            seenPaths.insert(path)
            return true
        }
    }
}
