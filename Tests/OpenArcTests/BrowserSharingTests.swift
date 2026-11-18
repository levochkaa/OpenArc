// BrowserSharingTests.swift

import AppKit
import Testing

// MARK: - FakeShareTransport

private final class FakeShareTransport: BrowserShareTransport, @unchecked Sendable {
    var published = [BrowserShareRequest]()
    var listed = [BrowserSharedLink]()
    var deleted = [String]()
    var content: BrowserSharedContent?
    var publishError: BrowserShareError?
    var deleteError: BrowserShareError?

    func publishShare(_ request: BrowserShareRequest, authSession _: BrowserAuthSession) throws
        -> BrowserSharedLink
    {
        if let publishError { throw publishError }
        published.append(request)
        let (sourceID, title): (String, String) =
            switch request {
            case .folder(let collection),
                 .space(let collection): (collection.sourceID, collection.title)
            case .quote(let quote): (quote.urlString, quote.title ?? "")
            }
        return link(
            id: "Link\(String(format: "%06d", sourceID.count))",
            kind: request.kind,
            sourceID: sourceID,
            title: title,
        )
    }

    func listShares(authSession _: BrowserAuthSession) -> [BrowserSharedLink] { listed }

    func deleteShare(id: String, authSession _: BrowserAuthSession) throws {
        if let deleteError { throw deleteError }
        deleted.append(id)
    }

    func readShare(id _: String) throws -> BrowserSharedContent {
        guard let content else { throw BrowserShareError.notFound }
        return content
    }

    func link(id: String, kind: BrowserShareKind = .space, sourceID: String = "s", title: String = "Space")
        -> BrowserSharedLink
    {
        BrowserSharedLink(
            id: id,
            kind: kind,
            url: URL(string: "https://openarc.su/\(kind == .quote ? "q" : "s")/\(id)")!,
            sourceID: sourceID,
            title: title,
            excerpt: nil,
            itemCount: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
        )
    }
}

// MARK: - BrowserSharingTests

@Suite(.serialized)
@MainActor struct BrowserSharingTests {
    private static let session = BrowserAuthSession(accessToken: "token", userID: "user", userEmail: nil, deviceID: "d")
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    @Test func shareLinksNameOneIdentifier() throws {
        let url = try #require(BrowserShareLink.url(id: "AbCdEfGh12"))
        #expect(url.absoluteString == "openarc://share/AbCdEfGh12")
        #expect(BrowserShareLink.id(from: url) == "AbCdEfGh12")
        #expect(try BrowserShareLink.id(from: #require(URL(string: "OPENARC://Share/AbCdEfGh12"))) == "AbCdEfGh12")
        #expect(try BrowserShareLink.id(from: #require(URL(string: "openarc://settings/AbCdEfGh12"))) == nil)
        #expect(try BrowserShareLink.id(from: #require(URL(string: "openarc://share/AbCdEfGh12/more"))) == nil)
        #expect(try BrowserShareLink.id(from: #require(URL(string: "openarc://share/short"))) == nil)
        #expect(try BrowserShareLink.id(from: #require(URL(string: "https://share/AbCdEfGh12"))) == nil)
        #expect(BrowserShareLink.url(id: "../../etc") == nil)
        let dataURL = BrowserShareLink.dataURL(png: Self.png)
        #expect(dataURL.hasPrefix("data:image/png;base64,"))
        #expect(BrowserShareLink.png(dataURL: dataURL) == Self.png)
        #expect(BrowserShareLink.png(dataURL: "data:image/svg+xml,<svg/>") == nil)
    }

    @Test func aTreeBecomesAListOfWebTabsNamingTheirFolders() {
        let big = Data(repeating: 1, count: BrowserShareConversion.maximumImageBytes + 1)
        let items = BrowserShareConversion.items(from: [
            .tab(title: " Mail ", urlString: "https://mail.example", faviconPNG: Self.png),
            .folder(title: "Docs", icon: "doc.text", children: [
                .tab(title: "Spec", urlString: "https://docs.example/spec", faviconPNG: big),
                .tab(title: "Settings", urlString: "openarc://settings", faviconPNG: nil),
                .folder(title: "Deep", icon: "Not A Symbol", children: [
                    .tab(title: nil, urlString: "http://deep.example", faviconPNG: nil),
                ]),
            ]),
            .tab(title: "File", urlString: "file:///Users/me/notes.txt", faviconPNG: nil),
        ])
        #expect(items == [
            .tab(title: "Mail", urlString: "https://mail.example", faviconPNG: Self.png),
            .folder(title: "Docs", icon: "doc.text"),
            .tab(title: "Spec", urlString: "https://docs.example/spec", parent: 1),
            .folder(title: "Deep", parent: 1),
            .tab(title: nil, urlString: "http://deep.example", parent: 3),
        ])

        // Too deep: the tabs of folders past the limit join the deepest kept folder.
        var nested = BrowserShareNode.tab(title: "Bottom", urlString: "https://bottom.example", faviconPNG: nil)
        for depth in (0...BrowserShareConversion.maximumFolderDepth + 2).reversed() {
            nested = .folder(title: "\(depth)", icon: nil, children: [nested])
        }
        let deep = BrowserShareConversion.items(from: [nested])
        #expect(deep.count { $0.kind == .folder } == BrowserShareConversion.maximumFolderDepth + 1)
        #expect(deep.last?.parent == BrowserShareConversion.maximumFolderDepth)
    }

    @Test func aSharedListBecomesTheTreeItCameFrom() {
        let items: [BrowserShareItem] = [
            .folder(title: "Docs", icon: "doc.text"),
            .tab(title: "Spec", urlString: "https://docs.example/spec", parent: 0),
            .tab(title: "Loose", urlString: "https://loose.example", parent: 1),
            .tab(title: "Script", urlString: "javascript:alert(1)"),
        ]
        #expect(BrowserShareConversion.importedNodes(from: items) == [
            .folder(title: "Docs", icon: "doc.text", children: [
                .tab(title: nil, savedTitle: "Spec", urlString: "https://docs.example/spec"),
            ]),
            // A parent that is not a folder puts the tab at the top level.
            .tab(title: nil, savedTitle: "Loose", urlString: "https://loose.example"),
        ])
        let space = BrowserShareConversion.importedSpace(from: BrowserSharedContent(
            id: "AbCdEfGh12", kind: .space, title: "Trip", icon: "🧳", colors: ["#3139FB"], items: items,
            updatedAt: Date(),
        ))
        #expect(space.title == "Trip")
        #expect(space.icon == BrowserIconImage.name(emoji: "🧳"))
        #expect(space.theme?.colors.map(BrowserShareConversion.hex) == ["#3139FB"])
        #expect(abs((BrowserShareConversion.luminance(hex: "#FFFFFF") ?? 0) - 1) < 0.0001)
        #expect(BrowserShareConversion.luminance(hex: "red") == nil)
    }

    @Test func shareSpaceCollectsPinnedTabsFoldersIconAndColors() throws {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("b", "f")],
            temporary: ["x"],
            folders: [.init(id: "f", spaceID: "s", title: "Folder", systemImageName: "folder.fill")],
        )
        let collection = try #require(f.model.shareCollection(forSpaceID: "s"))
        #expect(collection.sourceID == "s")
        #expect(collection.title == "Space")
        #expect(collection.icon == "square.grid.2x2")
        #expect(collection.iconPNG != nil, "A symbol is drawn for viewers without it")
        #expect(collection.items.map(\.kind) == [.tab, .folder, .tab] || collection.items.map(\.kind) == [
            .folder,
            .tab,
            .tab,
        ])
        #expect(collection.tabCount == 2, "Temporary tabs stay out")
        let folderTab = try #require(collection.items.first { $0.urlString == "https://b.example" })
        #expect(folderTab.parent.map { collection.items[$0].title } == "Folder")
        #expect(folderTab.title == "b")

        let folder = try #require(f.model.shareCollection(forFolderID: "f"))
        #expect(folder.sourceID == "f")
        #expect(folder.title == "Folder")
        #expect(folder.icon == "folder.fill")
        #expect(folder.items == [.tab(title: "b", urlString: "https://b.example")])

        #expect(f.model.shareCollection(forSpaceID: "t") == nil, "A Space without pinned pages has nothing to share")
        #expect(f.model.shareCollection(forFolderID: "missing") == nil)
    }

    @Test func aSharedFolderIsAddedClosedAtTheTopOfTheSpace() throws {
        let f = SidebarDragFixture(pinned: [("a", nil)], temporary: ["x"])
        let createdBefore = f.driver.createdTabRequests.count
        let content = BrowserSharedContent(
            id: "AbCdEfGh12", kind: .folder, title: "Recipes", icon: "fork.knife", colors: [],
            items: [
                .tab(title: "Soup", urlString: "https://soup.example"),
                .folder(title: "Bread"),
                .tab(title: "Focaccia", urlString: "https://bread.example", parent: 1),
            ],
            updatedAt: Date(),
        )
        let id = try #require(f.model.addImportedFolder(
            BrowserShareConversion.importedFolder(from: content),
            toSpaceID: "s",
        ))
        let folder = try #require(f.model.pinnedTabFolders.first { $0.id == id })
        #expect(folder.title == "Recipes")
        #expect(folder.systemImageName == "fork.knife")
        #expect(!folder.isExpanded)
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        #expect(tree.items(in: .pinned("s")).first == .folder(id))
        let tabs = tree.tabIDs(in: .pinned("s", folderID: id)).compactMap { tabID in
            f.model.tabs.first { $0.id == tabID }?.urlString
        }
        #expect(tabs == ["https://soup.example", "https://bread.example"])
        #expect(f.driver.createdTabRequests.count == createdBefore, "Added tabs stay dormant until selected")
        #expect(f.model.addImportedFolder(
            .tab(title: nil, savedTitle: nil, urlString: "https://a.example"),
            toSpaceID: "s",
        ) == nil)
    }

    @Test func aSharedSpaceIsAddedOnce() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let content = BrowserSharedContent(
            id: "AbCdEfGh12", kind: .space, title: "Trip", icon: "airplane", colors: ["#2E7D5B"],
            items: [.tab(title: "Map", urlString: "https://map.example")],
            updatedAt: Date(),
        )
        let sidebar = BrowserImportedSidebar(
            spaces: [BrowserShareConversion.importedSpace(from: content)],
            favorites: [],
        )
        #expect(f.model.importSidebar(sidebar).spaceCount == 1)
        let trip = try #require(f.model.spaces.first { $0.title == "Trip" })
        #expect(trip.systemImageName == "airplane")
        #expect(f.model.spaceThemesByID[trip.id]?.colors.map(BrowserShareConversion.hex) == ["#2E7D5B"])
        #expect(f.model.importSidebar(sidebar).spaceCount == 0, "The same Space is not added twice")
    }

    @Test func theStorePublishesListsAndRemovesForTheSignedInAccount() async throws {
        let transport = FakeShareTransport()
        var session: BrowserAuthSession? = Self.session
        let store = BrowserShareStore(transport: transport) { session }
        #expect(store.canPublish)
        transport.listed = [transport.link(id: "OldLink001", sourceID: "old")]
        await store.refresh()
        #expect(store.loadState == .loaded)
        #expect(store.links.map(\.id) == ["OldLink001"])

        let collection = BrowserShareCollection(sourceID: "space", title: "Work", colors: [], items: [
            .tab(title: "Mail", urlString: "https://mail.example"),
        ])
        let link = try await store.publish(.space(collection))
        _ = try await store.publish(.space(collection))
        #expect(store.links.map(\.id) == [link.id, "OldLink001"], "Sharing again keeps one entry, first")
        #expect(store.link(forSourceID: "space", kind: .space) == link)
        #expect(store.link(forSourceID: "space", kind: .folder) == nil)

        transport.deleteError = .notFound
        try await store.remove(link)
        #expect(store.links.map(\.id) == ["OldLink001"], "A link already gone leaves the list too")

        transport.publishError = .tooManyRequests("Too many shared links this hour; try again later")
        await #expect(throws: BrowserShareError.self) { try await store.publish(.space(collection)) }
        #expect(BrowserShareStore.message(for: BrowserShareError.tooManyRequests("Slow down")) == "Slow down")
        #expect(BrowserShareStore.message(for: BrowserShareError.notFound) == BrowserStrings.shareNotFound)

        session = nil
        #expect(!store.canPublish)
        await #expect(throws: BrowserShareError.signedOut) { try await store.publish(.space(collection)) }
        await store.refresh()
        #expect(store.links.isEmpty && store.loadState == .idle, "Signed out, the list is forgotten")
    }

    @Test func copyURLAsQuotePublishesWhenSignedInAndFallsBackToTheHighlight() async {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let transport = FakeShareTransport()
        f.model.shareStore = BrowserShareStore(transport: transport) { Self.session }
        f.driver.selectedText = "Example text"
        #expect(await f.model.copySelectedTextAsQuoteLink())
        let quote = transport.published.first
        #expect(quote == .quote(BrowserShareQuote(
            text: "Example text",
            title: "x",
            urlString: "https://x.example#:~:text=Example%20text",
        )))
        #expect(pasteboard.string(forType: .string)?.hasPrefix("https://openarc.su/q/") == true)

        transport.publishError = .server(statusCode: 503, message: nil)
        #expect(await f.model.copySelectedTextAsQuoteLink())
        #expect(pasteboard.string(forType: .string) == "https://x.example#:~:text=Example%20text")

        f.model.shareStore = BrowserShareStore(transport: transport) { nil }
        transport.publishError = nil
        let before = transport.published.count
        #expect(await f.model.copySelectedTextAsQuoteLink())
        #expect(transport.published.count == before, "Signed out, nothing is published")
        #expect(pasteboard.string(forType: .string) == "https://x.example#:~:text=Example%20text")
    }
}
