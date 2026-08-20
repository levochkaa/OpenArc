import Foundation
import Testing
import ZIPFoundation

@Test func chromiumBookmarkStoreAddsAndReloadsBookmarkBarItems() throws {
    let harness = try ChromiumBookmarkHarness()
    defer { harness.cleanup() }

    let store = BrowserChromiumBookmarkStore(profileDirectoryCandidates: [harness.profileDirectoryURL])

    #expect(store.addBookmark(title: "Example", urlString: "https://example.com"))
    #expect(!store.addBookmark(title: "Duplicate", urlString: "https://example.com/"))

    let items = store.loadBookmarkBarItems()
    let item = try #require(items.first)
    #expect(items.count == 1)
    #expect(item.displayTitle == "Example")
    #expect(item.urlString == "https://example.com")
    #expect(store.containsBookmark(urlString: "https://EXAMPLE.com/"))

    let document = try harness.bookmarksDocument()
    #expect((document["checksum"] as? String)?.isEmpty == false)
}

@Test func chromiumBookmarkStoreEditsMovesAndDeletesBookmarks() throws {
    let harness = try ChromiumBookmarkHarness()
    defer { harness.cleanup() }

    let store = BrowserChromiumBookmarkStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    #expect(store.addBookmark(title: "One", urlString: "https://one.example"))
    #expect(store.addBookmark(title: "Two", urlString: "https://two.example"))
    let firstID = try #require(store.loadBookmarkBarItems().first?.id)

    #expect(store.renameBookmark(id: firstID, title: "Renamed"))
    #expect(store.updateBookmarkAddress(id: firstID, urlString: "https://renamed.example/path"))
    let folderID = try #require(store.createFolder(title: "Folder"))
    #expect(store.moveBookmark(id: firstID, toFolderID: folderID))

    let folder = try #require(store.loadBookmarkBarItems().first { $0.id == folderID })
    let movedItem = try #require(folder.children.first)
    #expect(movedItem.displayTitle == "Renamed")
    #expect(movedItem.urlString == "https://renamed.example/path")
    #expect(!store.containsBookmark(urlString: "https://one.example"))
    #expect(store.containsBookmark(urlString: "https://renamed.example/path"))

    #expect(store.removeBookmark(urlString: "https://renamed.example/path"))
    #expect(!store.containsBookmark(urlString: "https://renamed.example/path"))

    let remainingItem = try #require(store.loadBookmarkBarItems().first { $0.urlString == "https://two.example" })
    #expect(store.deleteBookmark(id: remainingItem.id))
    #expect(!store.containsBookmark(urlString: "https://two.example"))
}

@Test func safariBookmarksHTMLImportPreservesReadingListFolder() throws {
    let harness = try ChromiumBookmarkHarness()
    defer { harness.cleanup() }

    let store = BrowserChromiumBookmarkStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    let result = try store.importSafariBookmarks(from: harness.makeSafariBookmarksHTMLFile())

    #expect(result == BrowserBookmarkImportResult(source: .safari, importedCount: 3, sourceWasAvailable: true))

    let importedFolder = try #require(store.loadBookmarkBarItems().first)
    #expect(importedFolder.displayTitle == BrowserStrings.bookmarksImportedFromSafari)
    #expect(importedFolder.children.map(\.displayTitle) == ["Favorites", "Reading List"])

    let readingList = try #require(importedFolder.children.last)
    #expect(readingList.isFolder)
    #expect(readingList.children.map(\.displayTitle) == ["First Article", "Second Article"])
    #expect(readingList.children.map(\.urlString) == [
        "https://reading.example/first",
        "https://reading.example/second",
    ])
}

@Test func safariBrowsingDataArchiveImportFindsLocalizedBookmarksFile() throws {
    let harness = try ChromiumBookmarkHarness()
    defer { harness.cleanup() }

    let store = BrowserChromiumBookmarkStore(profileDirectoryCandidates: [harness.profileDirectoryURL])
    let result = try store.importSafariBookmarks(from: harness.makeSafariExportArchive())

    #expect(result.importedCount == 3)
    #expect(result.sourceWasAvailable)

    let importedFolder = try #require(store.loadBookmarkBarItems().first)
    #expect(importedFolder.children.contains { $0.displayTitle == "Reading List" })
}

@Test
@MainActor func bookmarksModelFindsBookmarksByTitleAndURL() {
    let model = BrowserBookmarksModel(store: FakeBookmarkStore(items: [
        BrowserBookmarkItem(
            id: "1",
            kind: .bookmark,
            title: "Example Docs",
            urlString: "https://docs.example.com/start",
            children: []
        ),
    ]))

    model.reload()
    let titleMatches = model.suggestions(for: "docs", maximumCount: 5)
    let urlMatches = model.suggestions(for: "start", maximumCount: 5)

    #expect(titleMatches.first?.kind == .bookmark)
    #expect(titleMatches.first?.displayText == "Example Docs")
    #expect(urlMatches.first?.resolvedURLString == "https://docs.example.com/start")
}

// MARK: - FakeBookmarkStore

private struct FakeBookmarkStore: BrowserBookmarkStoring {
    let items: [BrowserBookmarkItem]

    func loadBookmarkBarItems() -> [BrowserBookmarkItem] {
        items
    }

    func containsBookmark(urlString: String) -> Bool {
        items.contains { $0.urlString == urlString }
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

// MARK: - ChromiumBookmarkHarness

private struct ChromiumBookmarkHarness {
    // MARK: Lifecycle

    init() throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("TheBrowserBookmarksTests-\(UUID().uuidString)", isDirectory: true)
        self.profileDirectoryURL = directoryURL.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
    }

    // MARK: Internal

    let directoryURL: URL
    let profileDirectoryURL: URL

    func bookmarksDocument() throws -> [String: Any] {
        let bookmarksURL = profileDirectoryURL.appendingPathComponent("Bookmarks", isDirectory: false)
        let data = try Data(contentsOf: bookmarksURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func makeSafariBookmarksHTMLFile() throws -> URL {
        let bookmarksURL = directoryURL.appendingPathComponent("Bookmarks.html", isDirectory: false)
        try Data(Self.safariBookmarksHTML.utf8).write(to: bookmarksURL, options: .atomic)
        return bookmarksURL
    }

    func makeSafariExportArchive() throws -> URL {
        let exportDirectoryURL = directoryURL.appendingPathComponent("Safari Export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)
        try Data(Self.safariBookmarksHTML.utf8).write(
            to: exportDirectoryURL.appendingPathComponent("Закладки.html", isDirectory: false),
            options: .atomic
        )
        try Data("{}".utf8).write(
            to: exportDirectoryURL.appendingPathComponent("History.json", isDirectory: false),
            options: .atomic
        )

        let archiveURL = directoryURL.appendingPathComponent("Safari Export.zip", isDirectory: false)
        try FileManager.default.zipItem(
            at: exportDirectoryURL,
            to: archiveURL,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        return archiveURL
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: Private

    private static let safariBookmarksHTML = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 FOLDED ID="favorites">Favorites</H3>
        <DL><p>
            <DT><A HREF="https://apple.example">Apple</A>
        </DL><p>
        <DT><H3 FOLDED ID="com.apple.ReadingList">Reading List</H3>
        <DL><p>
            <DT><A HREF="https://reading.example/first">First Article</A>
            <DT><A HREF="https://reading.example/second">Second Article</A>
        </DL><p>
    </DL><p>
    """
}
