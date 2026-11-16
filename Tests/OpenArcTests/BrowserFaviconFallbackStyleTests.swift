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

/// Icons refresh whenever any favicon arrives; one without a favicon of its own keeps
/// the image it shows, and many arrivals in a pass refresh it once.
@MainActor @Test func iconsKeepTheirImageAcrossRefreshes() {
    let cache = BrowserFaviconCache()
    let globe = BrowserFaviconNSView(cache: cache)
    globe.update(url: nil, pageURLString: "https://example.com")
    let globeImage = globe.image
    let history = BrowserFaviconNSView(cache: cache)
    history.update(url: nil, pageURLString: "openarc://history/")
    let clock = history.image
    for _ in 0..<5 {
        cache.objectWillChange.send()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    globe.update(url: nil, pageURLString: "https://example.com")
    history.update(url: nil, pageURLString: "openarc://history/")
    #expect(globe.image != nil && globe.image === globeImage)
    #expect(history.image != nil && history.image === clock)
}

/// A refresh that asks for the same icon does not hand the view its picture again,
/// which made it convert the picture for the screen on every tab switch.
@MainActor @Test func aRefreshWithTheSameIconLeavesTheViewAlone() {
    let view = BrowserFaviconNSView(cache: BrowserFaviconCache())
    view.update(url: nil, pageURLString: "https://example.com")
    var sets = 0
    let observation = view.observe(\.image) { _, _ in
        MainActor.assumeIsolated { sets += 1 }
    }
    defer { observation.invalidate() }
    for _ in 0..<3 {
        view.update(url: nil, pageURLString: "https://example.com")
    }
    #expect(sets == 0)
    view.update(url: nil, pageURLString: "openarc://history/")
    #expect(sets == 1)
}

/// A sidebar row shows the plain square until the page's icon arrives, then the icon
/// itself, untinted.
@MainActor @Test func anArrivingIconReplacesTheSquare() throws {
    let cache = BrowserFaviconCache()
    let view = BrowserFaviconNSView(cache: cache)
    view.fallback = .square
    let url = try #require(URL(string: "https://docs.example/static/icon.svg"))
    view.update(url: url, pageURLString: "https://docs.example/")
    #expect(view.image === BrowserFaviconNSView.squareImage)
    #expect(view.contentTintColor != nil)
    let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        return true
    }
    cache.store(icon, for: url)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(view.image === icon)
    #expect(view.contentTintColor == nil)
}
