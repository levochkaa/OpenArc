import CryptoKit
import Foundation
import ZIPFoundation

// MARK: - BrowserChromiumBookmarkStore

final class BrowserChromiumBookmarkStore: BrowserBookmarkStoring {
    // MARK: Lifecycle

    init(profileDirectoryCandidates: [URL], fileManager: FileManager = .default) {
        self.profileDirectoryCandidates = profileDirectoryCandidates
        self.fileManager = fileManager
    }

    // MARK: Internal

    func loadBookmarkBarItems() -> [BrowserBookmarkItem] {
        guard
            let document = loadDocumentIfPresent(),
            let bookmarkBar = rootNode(named: Key.bookmarkBar, in: document),
            let children = bookmarkBar[Key.children] as? [[String: Any]]
        else {
            return []
        }

        return children.compactMap(BrowserChromiumBookmarkStore.bookmarkItem(from:))
    }

    func containsBookmark(urlString: String) -> Bool {
        guard let document = loadDocumentIfPresent() else {
            return false
        }

        return allBookmarkURLStrings(in: document).contains(Self.normalizedURLString(urlString))
    }

    @discardableResult func addBookmark(title: String, urlString: String) -> Bool {
        guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        var document = loadDocumentOrDefault()
        let existingURLs = allBookmarkURLStrings(in: document)
        guard !existingURLs.contains(Self.normalizedURLString(urlString)) else {
            return false
        }

        var nextID = nextBookmarkID(in: document)
        let node = makeURLNode(
            title: title,
            urlString: urlString,
            id: nextAvailableID(&nextID)
        )
        appendNodes([node], toBookmarkBarIn: &document)
        return writeDocument(document)
    }

    @discardableResult func removeBookmark(urlString: String) -> Bool {
        let normalizedURL = Self.normalizedURLString(urlString)
        var document = loadDocumentOrDefault()
        guard mutateRoots(in: &document, mutation: { root in
            var children = root[Key.children] as? [BookmarkDocument] ?? []
            let didRemove = removeNodes(matchingURL: normalizedURL, from: &children)
            guard didRemove else {
                return false
            }

            root[Key.children] = children
            return true
        }) else {
            return false
        }

        return writeDocument(document)
    }

    @discardableResult func deleteBookmark(id: String) -> Bool {
        var document = loadDocumentOrDefault()
        guard mutateRoots(in: &document, mutation: { root in
            var children = root[Key.children] as? [BookmarkDocument] ?? []
            guard removeNode(withID: id, from: &children) != nil else {
                return false
            }

            root[Key.children] = children
            return true
        }) else {
            return false
        }

        return writeDocument(document)
    }

    @discardableResult func renameBookmark(id: String, title: String) -> Bool {
        var document = loadDocumentOrDefault()
        guard mutateRoots(in: &document, mutation: { root in
            var children = root[Key.children] as? [BookmarkDocument] ?? []
            guard renameNode(withID: id, title: title, in: &children) else {
                return false
            }

            root[Key.children] = children
            return true
        }) else {
            return false
        }

        return writeDocument(document)
    }

    @discardableResult func updateBookmarkAddress(id: String, urlString: String) -> Bool {
        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return false
        }

        var document = loadDocumentOrDefault()
        let existingURLs = allBookmarkURLStrings(in: document, excludingID: id)
        guard !existingURLs.contains(Self.normalizedURLString(trimmedURLString)), mutateRoots(
            in: &document,
            mutation: { root in
                var children = root[Key.children] as? [BookmarkDocument] ?? []
                guard updateBookmarkURL(withID: id, urlString: trimmedURLString, in: &children) else {
                    return false
                }

                root[Key.children] = children
                return true
            }
        ) else {
            return false
        }

        return writeDocument(document)
    }

    @discardableResult func moveBookmark(id: String, toFolderID: String?) -> Bool {
        guard toFolderID != id else {
            return false
        }

        var document = loadDocumentOrDefault()
        guard mutateBookmarkBar(in: &document, mutation: { children in
            guard let movingNode = removeNode(withID: id, from: &children) else {
                return false
            }

            if
                let toFolderID,
                containsNode(withID: toFolderID, in: movingNode)
            {
                children.append(movingNode)
                return false
            }

            return appendNode(movingNode, toFolderID: toFolderID, in: &children)
        }) else {
            return false
        }

        return writeDocument(document)
    }

    @discardableResult func createFolder(title: String) -> String? {
        var document = loadDocumentOrDefault()
        var nextID = nextBookmarkID(in: document)
        let folderID = nextAvailableID(&nextID)
        let folder = makeFolderNode(title: title, children: [], id: folderID)
        appendNodes([folder], toBookmarkBarIn: &document)
        guard writeDocument(document) else {
            return nil
        }

        return folderID
    }

    @discardableResult func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult {
        importBookmarkItems(loadImportItems(from: source), from: source)
    }

    @discardableResult func importSafariBookmarks(from sourceURL: URL) -> BrowserBookmarkImportResult {
        importBookmarkItems(loadSafariExportImportItems(from: sourceURL), from: .safari)
    }

    // MARK: Private

    private typealias BookmarkDocument = [String: Any]

    private enum Key {
        static let bookmarkBar = "bookmark_bar"
        static let checksum = "checksum"
        static let checksumSHA256 = "checksum_sha256"
        static let children = "children"
        static let dateAdded = "date_added"
        static let dateLastUsed = "date_last_used"
        static let dateModified = "date_modified"
        static let guid = "guid"
        static let id = "id"
        static let name = "name"
        static let other = "other"
        static let roots = "roots"
        static let synced = "synced"
        static let type = "type"
        static let url = "url"
        static let version = "version"
    }

    private enum NodeType {
        static let folder = "folder"
        static let url = "url"
    }

    private struct ImportItems {
        let sourceWasAvailable: Bool
        let items: [BrowserBookmarkImportItem]
    }

    private static let maximumSafariBookmarksFileSize = 50 * 1024 * 1024

    private let profileDirectoryCandidates: [URL]
    private let fileManager: FileManager

    private var bookmarkFileCandidates: [URL] {
        profileDirectoryCandidates.map {
            $0.appendingPathComponent("Bookmarks", isDirectory: false)
        }
    }

    private var existingBookmarkFileURL: URL? {
        newestExistingFileURL(in: bookmarkFileCandidates)
    }

    private var writableBookmarkFileURL: URL? {
        existingBookmarkFileURL ?? bookmarkFileCandidates.first
    }

    private static func bookmarkItem(from node: BookmarkDocument) -> BrowserBookmarkItem? {
        guard
            let id = node[Key.id] as? String,
            let type = node[Key.type] as? String
        else {
            return nil
        }

        let title = node[Key.name] as? String ?? ""

        if type == NodeType.url {
            guard let urlString = node[Key.url] as? String else {
                return nil
            }

            return BrowserBookmarkItem(
                id: id,
                kind: .bookmark,
                title: title,
                urlString: urlString,
                children: []
            )
        }

        guard type == NodeType.folder else {
            return nil
        }

        let children = (node[Key.children] as? [BookmarkDocument])?
            .compactMap(bookmarkItem(from:)) ?? []
        return BrowserBookmarkItem(
            id: id,
            kind: .folder,
            title: title,
            urlString: nil,
            children: children
        )
    }

    private static func normalizedURLString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString.lowercased()
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }
        components.fragment = nil
        return components.url?.absoluteString ?? urlString.lowercased()
    }

    private static func md5Hex(for data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func importBookmarkItems(
        _ importItems: ImportItems,
        from source: BrowserBookmarkImportSource
    ) -> BrowserBookmarkImportResult {
        guard importItems.sourceWasAvailable else {
            return BrowserBookmarkImportResult(source: source, importedCount: 0, sourceWasAvailable: false)
        }

        var document = loadDocumentOrDefault()
        var existingURLs = allBookmarkURLStrings(in: document)
        var importedCount = 0
        var nextID = nextBookmarkID(in: document)
        let importedNodes = nodes(
            from: importItems.items,
            existingURLs: &existingURLs,
            nextID: &nextID,
            importedCount: &importedCount
        )
        guard importedCount > 0, !importedNodes.isEmpty else {
            return BrowserBookmarkImportResult(source: source, importedCount: 0, sourceWasAvailable: true)
        }

        let folder = makeFolderNode(
            title: source.importedFolderTitle,
            children: importedNodes,
            id: nextAvailableID(&nextID)
        )
        appendNodes([folder], toBookmarkBarIn: &document)
        _ = writeDocument(document)
        return BrowserBookmarkImportResult(source: source, importedCount: importedCount, sourceWasAvailable: true)
    }

    private func loadDocumentIfPresent() -> BookmarkDocument? {
        guard
            let bookmarkFileURL = existingBookmarkFileURL,
            let data = try? Data(contentsOf: bookmarkFileURL),
            let document = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers])
            as? BookmarkDocument
        else {
            return nil
        }

        return ensurePermanentRoots(in: document)
    }

    private func loadDocumentOrDefault() -> BookmarkDocument {
        loadDocumentIfPresent() ?? makeEmptyDocument()
    }

    private func writeDocument(_ document: BookmarkDocument) -> Bool {
        guard let bookmarkFileURL = writableBookmarkFileURL else {
            return false
        }

        var document = ensurePermanentRoots(in: document)
        updateChecksums(in: &document)

        do {
            try fileManager.createDirectory(
                at: bookmarkFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: bookmarkFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func makeEmptyDocument() -> BookmarkDocument {
        let now = chromiumTimestamp()
        return [
            Key.roots: [
                Key.bookmarkBar: makePermanentFolderNode(
                    id: "1",
                    guid: "0bc5d13f-2cba-5d74-951f-3f233fe6c908",
                    title: "Bookmarks Bar",
                    now: now
                ),
                Key.other: makePermanentFolderNode(
                    id: "2",
                    guid: "82b081ec-3dd3-529c-8475-ab6c344590dd",
                    title: "Other Bookmarks",
                    now: now
                ),
                Key.synced: makePermanentFolderNode(
                    id: "3",
                    guid: "4cf2e351-0e85-532b-bb37-df045d8f8d0f",
                    title: "Mobile Bookmarks",
                    now: now
                ),
            ],
            Key.version: 1,
        ]
    }

    private func ensurePermanentRoots(in document: BookmarkDocument) -> BookmarkDocument {
        var document = document
        var roots = document[Key.roots] as? [String: Any] ?? [:]
        let defaults = makeEmptyDocument()[Key.roots] as? [String: Any] ?? [:]
        for rootName in [Key.bookmarkBar, Key.other, Key.synced] where roots[rootName] == nil {
            roots[rootName] = defaults[rootName]
        }
        document[Key.roots] = roots
        document[Key.version] = document[Key.version] ?? 1
        return document
    }

    private func makePermanentFolderNode(id: String, guid: String, title: String, now: String) -> BookmarkDocument {
        [
            Key.children: [],
            Key.dateAdded: now,
            Key.dateLastUsed: "0",
            Key.dateModified: now,
            Key.guid: guid,
            Key.id: id,
            Key.name: title,
            Key.type: NodeType.folder,
        ]
    }

    private func rootNode(named rootName: String, in document: BookmarkDocument) -> BookmarkDocument? {
        guard let roots = document[Key.roots] as? [String: Any] else {
            return nil
        }

        return roots[rootName] as? BookmarkDocument
    }

    private func appendNodes(_ nodes: [BookmarkDocument], toBookmarkBarIn document: inout BookmarkDocument) {
        var roots = document[Key.roots] as? [String: Any] ?? [:]
        var bookmarkBar = roots[Key.bookmarkBar] as? BookmarkDocument ?? makeEmptyBookmarkBarRoot()
        var children = bookmarkBar[Key.children] as? [BookmarkDocument] ?? []
        children.append(contentsOf: nodes)
        bookmarkBar[Key.children] = children
        bookmarkBar[Key.dateModified] = chromiumTimestamp()
        roots[Key.bookmarkBar] = bookmarkBar
        document[Key.roots] = roots
    }

    private func mutateBookmarkBar(
        in document: inout BookmarkDocument,
        mutation: (inout [BookmarkDocument]) -> Bool
    ) -> Bool {
        var roots = document[Key.roots] as? [String: Any] ?? [:]
        var bookmarkBar = roots[Key.bookmarkBar] as? BookmarkDocument ?? makeEmptyBookmarkBarRoot()
        var children = bookmarkBar[Key.children] as? [BookmarkDocument] ?? []
        guard mutation(&children) else {
            return false
        }

        bookmarkBar[Key.children] = children
        bookmarkBar[Key.dateModified] = chromiumTimestamp()
        roots[Key.bookmarkBar] = bookmarkBar
        document[Key.roots] = roots
        return true
    }

    private func mutateRoots(
        in document: inout BookmarkDocument,
        mutation: (inout BookmarkDocument) -> Bool
    ) -> Bool {
        var roots = document[Key.roots] as? [String: Any] ?? [:]
        var didChange = false

        for rootName in [Key.bookmarkBar, Key.other, Key.synced] {
            guard var root = roots[rootName] as? BookmarkDocument, mutation(&root) else {
                continue
            }

            root[Key.dateModified] = chromiumTimestamp()
            roots[rootName] = root
            didChange = true
        }

        guard didChange else {
            return false
        }

        document[Key.roots] = roots
        return true
    }

    private func removeNodes(matchingURL normalizedURL: String, from children: inout [BookmarkDocument]) -> Bool {
        var didRemove = false
        children.removeAll { child in
            guard
                child[Key.type] as? String == NodeType.url,
                let urlString = child[Key.url] as? String,
                Self.normalizedURLString(urlString) == normalizedURL
            else {
                return false
            }

            didRemove = true
            return true
        }

        for index in children.indices {
            var child = children[index]
            var childChildren = child[Key.children] as? [BookmarkDocument] ?? []
            guard removeNodes(matchingURL: normalizedURL, from: &childChildren) else {
                continue
            }

            child[Key.children] = childChildren
            child[Key.dateModified] = chromiumTimestamp()
            children[index] = child
            didRemove = true
        }

        return didRemove
    }

    private func removeNode(withID id: String, from children: inout [BookmarkDocument]) -> BookmarkDocument? {
        if let index = children.firstIndex(where: { $0[Key.id] as? String == id }) {
            return children.remove(at: index)
        }

        for index in children.indices {
            var child = children[index]
            var childChildren = child[Key.children] as? [BookmarkDocument] ?? []
            guard let removedNode = removeNode(withID: id, from: &childChildren) else {
                continue
            }

            child[Key.children] = childChildren
            child[Key.dateModified] = chromiumTimestamp()
            children[index] = child
            return removedNode
        }

        return nil
    }

    private func renameNode(withID id: String, title: String, in children: inout [BookmarkDocument]) -> Bool {
        for index in children.indices {
            var child = children[index]
            if child[Key.id] as? String == id {
                child[Key.name] =
                    if child[Key.type] as? String == NodeType.folder {
                        sanitizedFolderTitle(title)
                    } else {
                        sanitizedTitle(title, fallbackURLString: child[Key.url] as? String ?? title)
                    }
                children[index] = child
                return true
            }

            var childChildren = child[Key.children] as? [BookmarkDocument] ?? []
            guard renameNode(withID: id, title: title, in: &childChildren) else {
                continue
            }

            child[Key.children] = childChildren
            child[Key.dateModified] = chromiumTimestamp()
            children[index] = child
            return true
        }

        return false
    }

    private func updateBookmarkURL(
        withID id: String,
        urlString: String,
        in children: inout [BookmarkDocument]
    ) -> Bool {
        for index in children.indices {
            var child = children[index]
            if child[Key.id] as? String == id {
                guard child[Key.type] as? String == NodeType.url else {
                    return false
                }

                child[Key.url] = urlString
                children[index] = child
                return true
            }

            var childChildren = child[Key.children] as? [BookmarkDocument] ?? []
            guard updateBookmarkURL(withID: id, urlString: urlString, in: &childChildren) else {
                continue
            }

            child[Key.children] = childChildren
            child[Key.dateModified] = chromiumTimestamp()
            children[index] = child
            return true
        }

        return false
    }

    private func appendNode(
        _ node: BookmarkDocument,
        toFolderID folderID: String?,
        in children: inout [BookmarkDocument]
    )
        -> Bool
    {
        guard let folderID else {
            children.append(node)
            return true
        }

        for index in children.indices {
            var child = children[index]
            if child[Key.id] as? String == folderID, child[Key.type] as? String == NodeType.folder {
                var childChildren = child[Key.children] as? [BookmarkDocument] ?? []
                childChildren.append(node)
                child[Key.children] = childChildren
                child[Key.dateModified] = chromiumTimestamp()
                children[index] = child
                return true
            }

            var childChildren = child[Key.children] as? [BookmarkDocument] ?? []
            guard appendNode(node, toFolderID: folderID, in: &childChildren) else {
                continue
            }

            child[Key.children] = childChildren
            child[Key.dateModified] = chromiumTimestamp()
            children[index] = child
            return true
        }

        return false
    }

    private func containsNode(withID id: String, in node: BookmarkDocument) -> Bool {
        if node[Key.id] as? String == id {
            return true
        }

        let children = node[Key.children] as? [BookmarkDocument] ?? []
        return children.contains { containsNode(withID: id, in: $0) }
    }

    private func makeEmptyBookmarkBarRoot() -> BookmarkDocument {
        makePermanentFolderNode(
            id: "1",
            guid: "0bc5d13f-2cba-5d74-951f-3f233fe6c908",
            title: "Bookmarks Bar",
            now: chromiumTimestamp()
        )
    }

    private func nextBookmarkID(in document: BookmarkDocument) -> Int {
        maxBookmarkID(in: document) + 1
    }

    private func nextAvailableID(_ nextID: inout Int) -> String {
        defer { nextID += 1 }
        return String(nextID)
    }

    private func maxBookmarkID(in document: BookmarkDocument) -> Int {
        guard let roots = document[Key.roots] as? [String: Any] else {
            return 0
        }

        return roots.values.compactMap { $0 as? BookmarkDocument }.map(maxBookmarkID(inNode:)).max() ?? 0
    }

    private func maxBookmarkID(inNode node: BookmarkDocument) -> Int {
        let nodeID = (node[Key.id] as? String).flatMap(Int.init) ?? 0
        let childMax = (node[Key.children] as? [BookmarkDocument])?
            .map(maxBookmarkID(inNode:))
            .max() ?? 0
        return max(nodeID, childMax)
    }

    private func allBookmarkURLStrings(in document: BookmarkDocument) -> Set<String> {
        allBookmarkURLStrings(in: document, excludingID: nil)
    }

    private func allBookmarkURLStrings(in document: BookmarkDocument, excludingID excludedID: String?) -> Set<String> {
        guard let roots = document[Key.roots] as? [String: Any] else {
            return []
        }

        return roots.values
            .compactMap { $0 as? BookmarkDocument }
            .flatMap { allBookmarkURLStrings(inNode: $0, excludingID: excludedID) }
            .reduce(into: Set<String>()) { result, urlString in
                result.insert(Self.normalizedURLString(urlString))
            }
    }

    private func allBookmarkURLStrings(inNode node: BookmarkDocument) -> [String] {
        allBookmarkURLStrings(inNode: node, excludingID: nil)
    }

    private func allBookmarkURLStrings(inNode node: BookmarkDocument, excludingID excludedID: String?) -> [String] {
        if let excludedID, node[Key.id] as? String == excludedID {
            return []
        }

        if node[Key.type] as? String == NodeType.url, let urlString = node[Key.url] as? String {
            return [urlString]
        }

        return (node[Key.children] as? [BookmarkDocument])?
            .flatMap { allBookmarkURLStrings(inNode: $0, excludingID: excludedID) } ?? []
    }

    private func makeURLNode(title: String, urlString: String, id: String) -> BookmarkDocument {
        [
            Key.dateAdded: chromiumTimestamp(),
            Key.dateLastUsed: "0",
            Key.guid: UUID().uuidString.lowercased(),
            Key.id: id,
            Key.name: sanitizedTitle(title, fallbackURLString: urlString),
            Key.type: NodeType.url,
            Key.url: urlString,
        ]
    }

    private func makeFolderNode(title: String, children: [BookmarkDocument], id: String) -> BookmarkDocument {
        [
            Key.children: children,
            Key.dateAdded: chromiumTimestamp(),
            Key.dateLastUsed: "0",
            Key.dateModified: chromiumTimestamp(),
            Key.guid: UUID().uuidString.lowercased(),
            Key.id: id,
            Key.name: sanitizedFolderTitle(title),
            Key.type: NodeType.folder,
        ]
    }

    private func sanitizedTitle(_ title: String, fallbackURLString: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        guard
            let host = URL(string: fallbackURLString)?.host,
            !host.isEmpty
        else {
            return fallbackURLString
        }

        return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
    }

    private func sanitizedFolderTitle(_ title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? BrowserStrings.bookmarksUntitledFolder : trimmedTitle
    }

    private func nodes(
        from items: [BrowserBookmarkImportItem],
        existingURLs: inout Set<String>,
        nextID: inout Int,
        importedCount: inout Int
    ) -> [BookmarkDocument] {
        items.compactMap { item in
            if let urlString = item.urlString {
                let normalizedURL = Self.normalizedURLString(urlString)
                guard !existingURLs.contains(normalizedURL) else {
                    return nil
                }

                existingURLs.insert(normalizedURL)
                importedCount += 1
                return makeURLNode(
                    title: item.title,
                    urlString: urlString,
                    id: nextAvailableID(&nextID)
                )
            }

            let children = nodes(
                from: item.children,
                existingURLs: &existingURLs,
                nextID: &nextID,
                importedCount: &importedCount
            )
            guard !children.isEmpty else {
                return nil
            }

            return makeFolderNode(
                title: item.title,
                children: children,
                id: nextAvailableID(&nextID)
            )
        }
    }

    private func loadImportItems(from source: BrowserBookmarkImportSource) -> ImportItems {
        switch source {
        case .arc, .chrome, .dia:
            loadChromiumImportItems(from: source)
        case .safari:
            ImportItems(sourceWasAvailable: false, items: [])
        }
    }

    private func loadChromiumImportItems(from source: BrowserBookmarkImportSource) -> ImportItems {
        let bookmarkURLs = chromiumSourceBookmarkURLs(for: source)
        guard !bookmarkURLs.isEmpty else {
            return ImportItems(sourceWasAvailable: false, items: [])
        }

        let items = bookmarkURLs.flatMap { bookmarkURL in
            chromiumImportItems(fromBookmarksURL: bookmarkURL)
        }
        return ImportItems(sourceWasAvailable: true, items: items)
    }

    private func chromiumSourceBookmarkURLs(for source: BrowserBookmarkImportSource) -> [URL] {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else {
            return []
        }

        let userDataURL: URL
        switch source {
        case .arc:
            userDataURL = applicationSupportURL
                .appendingPathComponent("Arc", isDirectory: true)
                .appendingPathComponent("User Data", isDirectory: true)
        case .dia:
            userDataURL = applicationSupportURL
                .appendingPathComponent("Dia", isDirectory: true)
                .appendingPathComponent("User Data", isDirectory: true)
        case .chrome:
            userDataURL = applicationSupportURL
                .appendingPathComponent("Google", isDirectory: true)
                .appendingPathComponent("Chrome", isDirectory: true)
        case .safari:
            return []
        }

        guard let profileURLs = try? fileManager.contentsOfDirectory(
            at: userDataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return profileURLs
            .filter { profileURL in
                guard
                    let values = try? profileURL.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory == true
                else {
                    return false
                }

                let name = profileURL.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile"
            }
            .map { $0.appendingPathComponent("Bookmarks", isDirectory: false) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func chromiumImportItems(fromBookmarksURL bookmarkURL: URL) -> [BrowserBookmarkImportItem] {
        guard
            let data = try? Data(contentsOf: bookmarkURL),
            let document = try? JSONSerialization.jsonObject(with: data) as? BookmarkDocument,
            let roots = document[Key.roots] as? [String: Any]
        else {
            return []
        }

        return [Key.bookmarkBar, Key.other, Key.synced].flatMap { rootName -> [BrowserBookmarkImportItem] in
            guard
                let root = roots[rootName] as? BookmarkDocument,
                let children = root[Key.children] as? [BookmarkDocument]
            else {
                return []
            }

            return children.compactMap(importItem(fromChromiumNode:))
        }
    }

    private func importItem(fromChromiumNode node: BookmarkDocument) -> BrowserBookmarkImportItem? {
        guard let type = node[Key.type] as? String else {
            return nil
        }

        let title = node[Key.name] as? String ?? ""
        if type == NodeType.url {
            guard let urlString = node[Key.url] as? String else {
                return nil
            }

            return BrowserBookmarkImportItem(title: title, urlString: urlString, children: [])
        }

        guard type == NodeType.folder else {
            return nil
        }

        let children = (node[Key.children] as? [BookmarkDocument])?
            .compactMap(importItem(fromChromiumNode:)) ?? []
        guard !children.isEmpty else {
            return nil
        }

        return BrowserBookmarkImportItem(title: title, urlString: nil, children: children)
    }

    private func loadSafariExportImportItems(from sourceURL: URL) -> ImportItems {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        switch sourceURL.pathExtension.lowercased() {
        case "htm", "html":
            guard let data = safariBookmarksHTMLData(from: sourceURL) else {
                return ImportItems(sourceWasAvailable: true, items: [])
            }
            return ImportItems(sourceWasAvailable: true, items: safariImportItems(fromHTMLData: data))
        case "zip":
            return loadSafariArchiveImportItems(from: sourceURL)
        default:
            return ImportItems(sourceWasAvailable: false, items: [])
        }
    }

    private func loadSafariArchiveImportItems(from archiveURL: URL) -> ImportItems {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: nil) else {
            return ImportItems(sourceWasAvailable: true, items: [])
        }

        for entry in archive where entry.type == .file {
            guard URL(fileURLWithPath: entry.path).pathExtension.caseInsensitiveCompare("html") == .orderedSame,
                  UInt64(entry.uncompressedSize) <= UInt64(Self.maximumSafariBookmarksFileSize)
            else {
                continue
            }

            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            guard (try? archive.extract(entry) { data.append($0) }) != nil else {
                continue
            }

            let items = safariImportItems(fromHTMLData: data)
            if !items.isEmpty {
                return ImportItems(sourceWasAvailable: true, items: items)
            }
        }

        return ImportItems(sourceWasAvailable: true, items: [])
    }

    private func safariBookmarksHTMLData(from sourceURL: URL) -> Data? {
        if
            let fileSize = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            fileSize > Self.maximumSafariBookmarksFileSize
        {
            return nil
        }

        return try? Data(contentsOf: sourceURL, options: .mappedIfSafe)
    }

    private func safariImportItems(fromHTMLData data: Data) -> [BrowserBookmarkImportItem] {
        guard data.count <= Self.maximumSafariBookmarksFileSize,
              let document = try? XMLDocument(
                  data: data,
                  options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
              ),
              let rootElement = document.rootElement(),
              let rootList = firstSafariElement(named: "dl", in: rootElement)
        else {
            return []
        }

        return safariImportItems(in: rootList)
    }

    private func safariImportItems(in listElement: XMLElement) -> [BrowserBookmarkImportItem] {
        (listElement.children ?? []).compactMap { node in
            guard let element = node as? XMLElement else {
                return nil
            }

            if let linkElement = directSafariChild(named: "a", in: element),
               let urlString = linkElement.attribute(forName: "href")?.stringValue,
               !urlString.isEmpty
            {
                let title = linkElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? urlString
                return BrowserBookmarkImportItem(
                    title: displayTitle,
                    urlString: urlString,
                    children: []
                )
            }

            guard
                let headingElement = directSafariChild(named: "h3", in: element),
                let childListElement = directSafariChild(named: "dl", in: element)
            else {
                return nil
            }

            let children = safariImportItems(in: childListElement)
            guard !children.isEmpty else {
                return nil
            }

            let title = safariFolderTitle(from: headingElement)
            return BrowserBookmarkImportItem(title: title, urlString: nil, children: children)
        }
    }

    private func safariFolderTitle(from headingElement: XMLElement) -> String {
        let title = headingElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }

        if headingElement.attribute(forName: "id")?.stringValue == "com.apple.ReadingList" {
            return "Reading List"
        }

        return BrowserStrings.bookmarksUntitledFolder
    }

    private func firstSafariElement(named name: String, in node: XMLNode) -> XMLElement? {
        if let element = node as? XMLElement, safariElementName(element) == name {
            return element
        }

        for child in node.children ?? [] {
            if let match = firstSafariElement(named: name, in: child) {
                return match
            }
        }

        return nil
    }

    private func directSafariChild(named name: String, in element: XMLElement) -> XMLElement? {
        (element.children ?? []).compactMap { $0 as? XMLElement }.first {
            safariElementName($0) == name
        }
    }

    private func safariElementName(_ element: XMLElement) -> String {
        (element.localName ?? element.name ?? "").lowercased()
    }

    private func updateChecksums(in document: inout BookmarkDocument) {
        guard let roots = document[Key.roots] as? [String: Any] else {
            return
        }

        var checksumPayload = Data()
        for rootName in [Key.bookmarkBar, Key.other, Key.synced] {
            guard let rootNode = roots[rootName] as? BookmarkDocument else {
                continue
            }

            appendChecksumPayload(for: rootNode, to: &checksumPayload)
        }

        document[Key.checksum] = Self.md5Hex(for: checksumPayload)
        if document[Key.checksumSHA256] != nil {
            document[Key.checksumSHA256] = Self.sha256Hex(for: checksumPayload)
        }
    }

    private func appendChecksumPayload(for node: BookmarkDocument, to data: inout Data) {
        guard
            let id = node[Key.id] as? String,
            let type = node[Key.type] as? String
        else {
            return
        }

        let title = node[Key.name] as? String ?? ""
        data.appendUTF8(id)
        data.appendUTF16LittleEndian(title)
        data.appendUTF8(type)

        if type == NodeType.url {
            data.appendUTF8(node[Key.url] as? String ?? "")
            return
        }

        guard type == NodeType.folder else {
            return
        }

        let children = node[Key.children] as? [BookmarkDocument] ?? []
        for child in children {
            appendChecksumPayload(for: child, to: &data)
        }
    }

    private func newestExistingFileURL(in urls: [URL]) -> URL? {
        urls
            .filter { fileManager.fileExists(atPath: $0.path) }
            .max { lhs, rhs in
                modificationDate(for: lhs) < modificationDate(for: rhs)
            }
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func chromiumTimestamp(date: Date = Date()) -> String {
        let windowsEpochOffset: TimeInterval = 11_644_473_600
        let microseconds = Int64((date.timeIntervalSince1970 + windowsEpochOffset) * 1_000_000)
        return String(microseconds)
    }
}

// MARK: - BrowserBookmarkImportItem

private struct BrowserBookmarkImportItem {
    let title: String
    let urlString: String?
    let children: [BrowserBookmarkImportItem]
}

// MARK: - BrowserBookmarkSearch

enum BrowserBookmarkSearch {
    // MARK: Internal

    static func containsBookmark(in items: [BrowserBookmarkItem], urlString: String) -> Bool {
        flattenedBookmarks(in: items).contains {
            normalizedURLString($0.urlString ?? "") == normalizedURLString(urlString)
        }
    }

    static func matchingBookmarks(in items: [BrowserBookmarkItem], query: String) -> [BrowserBookmarkItem] {
        flattenedBookmarks(in: items).filter { item in
            normalized(item.displayTitle).contains(query)
                || normalized(item.urlString ?? "").contains(query)
        }
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    // MARK: Private

    private static func flattenedBookmarks(in items: [BrowserBookmarkItem]) -> [BrowserBookmarkItem] {
        items.flatMap { item -> [BrowserBookmarkItem] in
            if item.isFolder {
                return flattenedBookmarks(in: item.children)
            }

            return [item]
        }
    }

    private static func normalizedURLString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString.lowercased()
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }
        components.fragment = nil
        return components.url?.absoluteString ?? urlString.lowercased()
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(string.data(using: .utf8) ?? Data())
    }

    mutating func appendUTF16LittleEndian(_ string: String) {
        for codeUnit in string.utf16 {
            var littleEndianCodeUnit = codeUnit.littleEndian
            Swift.withUnsafeBytes(of: &littleEndianCodeUnit) { buffer in
                append(contentsOf: buffer)
            }
        }
    }
}
