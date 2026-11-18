// BrowserTrackingParametersTests.swift

import Testing

@Test func copiedLinksLeaveTrackingParametersOut() {
    #expect(BrowserTrackingParameters.cleaned(
        "https://example.com/a?id=7&utm_source=news&utm_medium=mail&fbclid=X1#part",
    ) == "https://example.com/a?id=7#part")
    #expect(
        BrowserTrackingParameters.cleaned("https://example.com/?gclid=1&UTM_Campaign=2")
            == "https://example.com/",
        "Nothing left: no question mark",
    )
    #expect(BrowserTrackingParameters.cleaned("https://www.youtube.com/watch?v=abc&si=share")
        == "https://www.youtube.com/watch?v=abc")
    #expect(
        BrowserTrackingParameters.cleaned("https://example.com/search?si=1&q=a%20b")
            == "https://example.com/search?si=1&q=a%20b",
        "Share IDs go only on the sites that add them",
    )
    #expect(BrowserTrackingParameters.cleaned("https://example.com/p?q=1") == "https://example.com/p?q=1")
    #expect(BrowserTrackingParameters.cleaned("not a url") == "not a url")
}
