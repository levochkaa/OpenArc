import Testing

@Test func urlDisplayFormatterShowsBareHost() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://youtube.com/watch?v=1") == "youtube.com")
}

@Test func urlDisplayFormatterStripsLeadingWWWOnly() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://www.youtube.com/feed") == "youtube.com")
}

@Test func urlFullDisplayFormatterStripsLeadingWWWFromHostOnly() {
    #expect(
        BrowserURLDisplayFormatter.fullDisplayString(
            for: "https://www.youtube.com/feed?list=latest#top"
        ) == "https://youtube.com/feed?list=latest#top"
    )
}

@Test func urlFullDisplayFormatterPreservesImportantSubdomains() {
    #expect(
        BrowserURLDisplayFormatter.fullDisplayString(
            for: "https://www1.youtube.com/feed"
        ) == "https://www1.youtube.com/feed"
    )
}

@Test func urlHostDisplayFormatterStripsLeadingWWWOnly() {
    #expect(BrowserURLDisplayFormatter.hostDisplayString(forHost: "www.youtube.com") == "youtube.com")
    #expect(BrowserURLDisplayFormatter.hostDisplayString(forHost: "WWW.YouTube.com") == "YouTube.com")
    #expect(BrowserURLDisplayFormatter.hostDisplayString(forHost: "www1.youtube.com") == "www1.youtube.com")
}

@Test func urlDisplayFormatterStripsLeadingWWWFromFallbackTabTitle() {
    let tab = BrowserChromeModel.Tab(
        id: "tab",
        syncID: "sync",
        spaceID: "space",
        title: "",
        urlString: "https://www.youtube.com/feed"
    )

    #expect(tab.pageTitle == "youtube.com")
}

@Test func urlDisplayFormatterStripsLeadingWWWFromFallbackBookmarkTitle() {
    let item = BrowserBookmarkItem(
        id: "bookmark",
        kind: .bookmark,
        title: "",
        urlString: "https://www.youtube.com/feed",
        children: []
    )

    #expect(item.displayTitle == "youtube.com")
}

@Test func urlDisplayFormatterKeepsNonDefaultHTTPSPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://example.com:8443/path") == "example.com:8443")
}

@Test func urlDisplayFormatterKeepsNonDefaultHTTPPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://example.com:8080/path") == "example.com:8080")
}

@Test func urlDisplayFormatterStripsLeadingWWWBeforeKeepingNonDefaultPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://www.example.com:8443/path") == "example.com:8443")
}

@Test func urlDisplayFormatterHidesDefaultHTTPAndHTTPSPorts() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://example.com:80/path") == "example.com")
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://example.com:443/path") == "example.com")
}

@Test func urlDisplayFormatterPreservesImportantSubdomains() {
    #expect(
        BrowserURLDisplayFormatter.displayString(
            for: "https://chromewebstore.google.com/detail/example"
        ) == "chromewebstore.google.com"
    )
}

@Test func urlDisplayFormatterKeepsLocalhostPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://localhost:3000/path") == "localhost:3000")
}

@Test func urlDisplayFormatterKeepsIPAddressPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://127.0.0.1:9222/json") == "127.0.0.1:9222")
}

@Test func urlDisplayFormatterBracketsIPv6AddressWithNonDefaultPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://[::1]:3000/path") == "[::1]:3000")
}

@Test func urlDisplayFormatterKeepsDefaultLocalhostAndIPAddressPorts() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://localhost:80/path") == "localhost:80")
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://127.0.0.1:443/json") == "127.0.0.1:443")
}

@Test func urlDisplayFormatterBracketsIPv6AddressWithDefaultPorts() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://[::1]:80/path") == "[::1]:80")
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://[::1]:443/json") == "[::1]:443")
}

@Test func urlDisplayFormatterKeepsIPv6AddressWithoutPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://[::1]/path") == "[::1]")
}

@Test func urlDisplayFormatterFallsBackForInternalURLs() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "openarc://settings/privacy") == "openarc://settings/privacy")
    #expect(BrowserURLDisplayFormatter
        .displayString(for: "openarc://extensions/?id=abc") == "openarc://extensions/?id=abc")
}

@Test func urlDisplayFormatterFallsBackForFileURLs() {
    #expect(
        BrowserURLDisplayFormatter.displayString(
            for: "file:///Users/lev/Downloads/example.html"
        ) == "file:///Users/lev/Downloads/example.html"
    )
}
