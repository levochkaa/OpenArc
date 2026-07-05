import Foundation
import Testing

@Test func faviconFallbackStyleUsesChromiumWebUIIconForInternalPages() {
    for pageURLString in [
        "tb://settings",
        "tb://settings/privacy",
        "chrome://settings",
        "about:settings",
        "tb://extensions",
        "tb://extensions/shortcuts",
        "chrome://extensions",
        "tb://history",
        "chrome://version",
        "tb://flags",
        "tb://password-manager/passwords",
        "tb://bookmarks/",
    ] {
        #expect(
            BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) == .chromiumWebUI
        )
    }
}

@Test func faviconFallbackStyleKeepsGlobeForRegularPages() {
    for pageURLString in [
        nil,
        "",
        "about:blank",
        "https://example.com",
        "tb://credits",
    ] {
        #expect(BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) == .globe)
    }
}

@Test func internalWebUITabsDoNotRequestRemoteFavicons() throws {
    let internalTab = makeFaviconTab(
        urlString: "tb://settings/privacy",
        faviconURLString: "https://example.com/favicon.ico"
    )

    #expect(internalTab.faviconFallbackStyle == .chromiumWebUI)
    #expect(internalTab.faviconURL == nil)

    let regularTab = makeFaviconTab(
        urlString: "https://example.com/article",
        faviconURLString: "https://example.com/favicon.ico"
    )

    #expect(regularTab.faviconFallbackStyle == .globe)
    #expect(regularTab.faviconURL?.absoluteString == "https://example.com/favicon.ico")

    let fallbackTab = makeFaviconTab(urlString: "https://example.com/article")
    let fallbackURL = try #require(fallbackTab.faviconURL)

    #expect(fallbackURL.host == "www.google.com")
    #expect(fallbackURL.path == "/s2/favicons")
}

private func makeFaviconTab(
    urlString: String,
    faviconURLString: String? = nil
) -> BrowserChromeModel.Tab {
    BrowserChromeModel.Tab(
        id: UUID().uuidString,
        syncID: UUID().uuidString,
        spaceID: BrowserChromeModel.defaultSpaceID,
        title: "",
        urlString: urlString,
        faviconURLString: faviconURLString
    )
}
