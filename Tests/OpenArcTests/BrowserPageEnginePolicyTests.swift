// BrowserPageEnginePolicyTests.swift

import Foundation
import Testing

// MARK: - BrowserPageEnginePolicyTests

@MainActor @Suite(.serialized) struct BrowserPageEnginePolicyTests {
    init() {
        let suite = "BrowserPageEnginePolicyTests.\(UUID().uuidString)"
        BrowserPageEnginePolicy.userDefaults = UserDefaults(suiteName: suite)!
    }

    // MARK: Internal

    @Test func streamingSitesAndTheirSubdomainsOpenInWebKitOverHTTPS() {
        for url in [
            "https://www.netflix.com/browse",
            "https://netflix.com",
            "https://www.disneyplus.com/",
            "https://tv.apple.com/show",
            "https://open.spotify.com/track/1",
        ] {
            #expect(BrowserPageEnginePolicy.engine(forURLString: url) == .webKit, "\(url)")
        }
        for url in [
            "http://www.netflix.com",
            "https://notnetflix.com",
            "https://example.com",
            "https://apple.com",
            "openarc://settings",
        ] {
            #expect(BrowserPageEnginePolicy.engine(forURLString: url) == .chromium, "\(url)")
        }
    }

    @Test func turningOffWebKitForStreamingSitesKeepsThemInChromium() {
        BrowserPageEnginePolicy.opensStreamingSitesInWebKit = false
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.netflix.com") == .chromium)
    }

    @Test func theFairPlayBridgeKeepsItsSitesInChromium() {
        #expect(!BrowserPageEnginePolicy.bridgesFairPlay(forURLString: "https://open.spotify.com/track/1"))
        BrowserPageEnginePolicy.playsProtectedMediaInChromium = true
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://open.spotify.com/track/1") == .chromium)
        #expect(BrowserPageEnginePolicy.bridgesFairPlay(forURLString: "https://open.spotify.com/album/2"))
        // Only the exact origins the bridge serves; video sites stay in WebKit.
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.netflix.com/watch/1") == .webKit)
        #expect(!BrowserPageEnginePolicy.bridgesFairPlay(forURLString: "https://spotify.com"))
    }

    @Test func aSiteRuleWinsForItsOriginOnly() {
        BrowserPageEnginePolicy.setEngine(.chromium, forURLString: "https://www.netflix.com/browse")
        BrowserPageEnginePolicy.setEngine(.webKit, forURLString: "https://example.com:8443/a")
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.netflix.com/title/2") == .chromium)
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://netflix.com") == .webKit)
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://example.com:8443/b") == .webKit)
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://example.com/b") == .chromium)

        BrowserPageEnginePolicy.resetSiteEngines()
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.netflix.com") == .webKit)
        #expect(!BrowserPageEnginePolicy.hasRule(forURLString: "https://example.com:8443/b"))
    }

    @Test func aSiteIsItsSchemeHostAndPortLowercased() {
        #expect(BrowserPageEnginePolicy
            .site(forURLString: "HTTPS://WWW.Netflix.com/browse?x=1") == "https://www.netflix.com")
        #expect(BrowserPageEnginePolicy.site(forURLString: "http://localhost:3000/a") == "http://localhost:3000")
        #expect(BrowserPageEnginePolicy.site(forURLString: "file:///tmp/a.html") == nil)
        #expect(BrowserPageEnginePolicy.site(forURLString: "about:blank") == nil)
    }
}
