// BrowserLinkStatusViewTests.swift

import Testing

@MainActor struct BrowserLinkStatusViewTests {
    @Test func addressesLoseTheirSchemeAndTrailingSlash() {
        #expect(BrowserLinkStatusView.displayText(for: "https://gh.io/ghe-with-cp") == "gh.io/ghe-with-cp")
        #expect(BrowserLinkStatusView.displayText(for: "http://www.example.com/") == "example.com")
        #expect(BrowserLinkStatusView.displayText(for: "mailto:a@b.c") == "mailto:a@b.c")
    }
}
