// BrowserFaviconFallbackStyleTests.swift

import AppKit
import Foundation
import Testing

@Test func faviconFallbackStyleUsesChromiumWebUIIconForInternalPages() {
    for pageURLString in [
        "openarc://settings",
        "openarc://settings/privacy",
        "chrome://settings",
        "about:settings",
        "openarc://extensions",
        "openarc://extensions/shortcuts",
        "chrome://extensions",
        "openarc://history",
        "chrome://version",
        "openarc://flags",
        "openarc://password-manager/passwords",
        "openarc://bookmarks/",
    ] {
        #expect(
            BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) == .chromiumWebUI,
        )
    }
}

@Test func faviconFallbackStyleKeepsGlobeForRegularPages() {
    for pageURLString in [
        nil,
        "",
        "about:blank",
        "https://example.com",
        "openarc://credits",
    ] {
        #expect(BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) == .globe)
    }
}

@Test func internalWebUITabsDoNotRequestRemoteFavicons() throws {
    let internalTab = makeFaviconTab(
        urlString: "openarc://settings/privacy",
        faviconURLString: "https://example.com/favicon.ico",
    )

    #expect(internalTab.faviconFallbackStyle == .chromiumWebUI)
    #expect(internalTab.faviconURL == nil)

    let regularTab = makeFaviconTab(
        urlString: "https://example.com/article",
        faviconURLString: "https://example.com/favicon.ico",
    )

    #expect(regularTab.faviconFallbackStyle == .globe)
    #expect(regularTab.faviconURL?.absoluteString == "https://example.com/favicon.ico")

    let fallbackTab = makeFaviconTab(urlString: "https://example.com/article")
    let fallbackURL = try #require(fallbackTab.faviconURL)

    #expect(BrowserFaviconCache.pageURLString(forPageIconURL: fallbackURL) == "https://example.com/article")
}

@Test @MainActor func anUnloadedPageShowsItsRecordedIconWithoutAskingTheService() async throws {
    var requested = [URL]()
    let recorded = try #require(NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        return true
    }.tiffRepresentation)
    let cache = BrowserFaviconCache { url in
        await MainActor.run { requested.append(url) }
        return recorded
    }
    cache.pageIconProvider = { $0 == "https://example.com/article" ? recorded : nil }

    let known = try #require(makeFaviconTab(urlString: "https://example.com/article").faviconURL)
    await cache.loadImageIfNeeded(from: known)
    #expect(cache.image(for: known) != nil)
    #expect(requested.isEmpty, "A recorded icon needs no request")

    let unknown = try #require(makeFaviconTab(urlString: "https://unknown.example/").faviconURL)
    await cache.loadImageIfNeeded(from: unknown)
    #expect(cache.image(for: unknown) != nil)
    #expect(requested.map(\.host) == ["www.google.com"], "A page without a record asks the service")
}

private func makeFaviconTab(
    urlString: String,
    faviconURLString: String? = nil,
) -> BrowserChromeModel.Tab {
    BrowserChromeModel.Tab(
        id: UUID().uuidString,
        syncID: UUID().uuidString,
        spaceID: BrowserChromeModel.defaultSpaceID,
        title: "",
        urlString: urlString,
        faviconURLString: faviconURLString,
    )
}

@MainActor @Test func sidebarIconsShowASquareForPagesWithoutAnIcon() {
    let view = BrowserFaviconNSView(cache: BrowserFaviconCache())
    view.update(url: nil, pageURLString: "https://example.com")
    #expect(view.image !== BrowserFaviconNSView.squareImage, "Elsewhere a globe")
    view.fallback = .square
    #expect(view.image === BrowserFaviconNSView.squareImage)
    #expect(BrowserFaviconNSView.squareImage.isTemplate, "Tinted with the row's text color")
}

@Test func internalPagesShowTheirOwnIcons() {
    #expect(BrowserFaviconFallbackStyle.webUISymbol(forPageURLString: "openarc://history/") == "clock.arrow.circlepath")
    #expect(BrowserFaviconFallbackStyle.webUISymbol(forPageURLString: "openarc://settings") == "gearshape.fill")
    #expect(
        BrowserFaviconFallbackStyle.webUISymbol(forPageURLString: "openarc://extensions") == nil,
        "The generic icon",
    )
    #expect(BrowserFaviconFallbackStyle.webUISymbol(forPageURLString: "https://example.com/history") == nil)
}

@MainActor @Test func theHistoryTabShowsABlueClock() {
    let view = BrowserFaviconNSView(cache: BrowserFaviconCache())
    view.update(url: nil, pageURLString: "openarc://history/")
    #expect(view.contentTintColor == BrowserChromeColors.internalPageIcon)
    #expect(view.image != nil)
}
