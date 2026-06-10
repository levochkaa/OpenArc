import Combine
import Foundation

// MARK: - BrowserBookmarkImportSource

enum BrowserBookmarkImportSource: String, CaseIterable, Identifiable {
    case arc
    case dia
    case chrome
    case safari

    // MARK: Internal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .arc:
            BrowserStrings.bookmarksImportArc
        case .dia:
            BrowserStrings.bookmarksImportDia
        case .chrome:
            BrowserStrings.bookmarksImportChrome
        case .safari:
            BrowserStrings.bookmarksImportSafari
        }
    }

    var importedFolderTitle: String {
        switch self {
        case .arc:
            BrowserStrings.bookmarksImportedFromArc
        case .dia:
            BrowserStrings.bookmarksImportedFromDia
        case .chrome:
            BrowserStrings.bookmarksImportedFromChrome
        case .safari:
            BrowserStrings.bookmarksImportedFromSafari
        }
    }
}

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

        return host
    }

    var faviconURL: URL? {
        guard
            let urlString,
            let encodedURL = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            return nil
        }

        return URL(string: "https://www.google.com/s2/favicons?sz=64&domain_url=\(encodedURL)")
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
    func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult
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
    // MARK: Lifecycle

    init(store: BrowserBookmarkStoring = BrowserEmptyBookmarkStore()) {
        self.store = store
    }

    // MARK: Internal

    @Published private(set) var bookmarkBarItems = [BrowserBookmarkItem]()

    var isEmpty: Bool {
        bookmarkBarItems.isEmpty
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
                    detailText: item.urlString.map(BrowserURLDisplayFormatter.displayString),
                    resolvedURLString: item.urlString ?? ""
                )
            }
    }

    // MARK: Private

    private let store: BrowserBookmarkStoring
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
