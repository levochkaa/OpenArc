import Testing

@Test
func urlDisplayFormatterShowsBareHost() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://youtube.com/watch?v=1") == "youtube.com")
}

@Test
func urlDisplayFormatterStripsLeadingWWWOnly() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "https://www.youtube.com/feed") == "youtube.com")
}

@Test
func urlDisplayFormatterPreservesImportantSubdomains() {
    #expect(
        BrowserURLDisplayFormatter.displayString(
            for: "https://chromewebstore.google.com/detail/example"
        ) == "chromewebstore.google.com"
    )
}

@Test
func urlDisplayFormatterKeepsLocalhostPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://localhost:3000/path") == "localhost:3000")
}

@Test
func urlDisplayFormatterKeepsIPAddressPort() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "http://127.0.0.1:9222/json") == "127.0.0.1:9222")
}

@Test
func urlDisplayFormatterFallsBackForInternalURLs() {
    #expect(BrowserURLDisplayFormatter.displayString(for: "tb://settings/privacy") == "tb://settings/privacy")
}

@Test
func urlDisplayFormatterFallsBackForFileURLs() {
    #expect(
        BrowserURLDisplayFormatter.displayString(
            for: "file:///Users/lev/Downloads/example.html"
        ) == "file:///Users/lev/Downloads/example.html"
    )
}
