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
        BrowserPageEnginePolicy.movesProtectedVideoToWebKit = false
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.netflix.com") == .chromium)
    }

    @Test func theFairPlayBridgeKeepsItsSitesInChromium() {
        #expect(!BrowserPageEnginePolicy.bridgesFairPlay(forURLString: "https://open.spotify.com/track/1"))
        BrowserPageEnginePolicy.playsProtectedMediaInChromium = true
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://open.spotify.com/track/1") == .chromium)
        #expect(BrowserPageEnginePolicy.bridgesFairPlay(forURLString: "https://open.spotify.com/album/2"))
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.netflix.com/watch/1") == .chromium)
        #expect(BrowserPageEnginePolicy.bridgesFairPlay(forURLString: "https://www.disneyplus.com/video/3"))
        // Only the exact origins the bridges serve.
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://help.netflix.com") == .webKit)
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.primevideo.com") == .webKit)
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

    @Test func failedProtectedVideoMovesThePageToWebKitAndItsSiteStaysThere() {
        let url = "https://video.example.com/watch/1"
        #expect(BrowserPageEnginePolicy.engine(forURLString: url) == .chromium)
        for reason in [
            "access",
            "request",
            "license",
            "license-timeout",
            "key-error",
            "output-restricted",
            "media-keys",
            "playback",
        ] {
            #expect(action(url, reason: reason) == .moveToWebKit, "\(reason)")
        }
        #expect(action(url, keySystem: "com.microsoft.playready.recommendation") == .moveToWebKit)
        #expect(action(url, keySystem: "com.apple.fps.1_0") == .moveToWebKit)

        BrowserPageEnginePolicy.rememberProtectedVideoSite(forURLString: url)
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://video.example.com/other") == .webKit)
        // By origin: other hosts and schemes stay.
        #expect(BrowserPageEnginePolicy.engine(forURLString: "https://www.example.com/") == .chromium)
        #expect(BrowserPageEnginePolicy.engine(forURLString: "http://video.example.com/") == .chromium)

        BrowserPageEnginePolicy.movesProtectedVideoToWebKit = false
        #expect(BrowserPageEnginePolicy.engine(forURLString: url) == .chromium)
        #expect(action(url) == .offer)

        BrowserPageEnginePolicy.movesProtectedVideoToWebKit = true
        BrowserPageEnginePolicy.resetSiteEngines()
        #expect(BrowserPageEnginePolicy.engine(forURLString: url) == .chromium)
    }

    @Test func otherFailuresAndKeySystemsChangeNothing() {
        let url = "https://video.example.com/watch/1"
        #expect(action(url, keySystem: "org.w3.clearkey") == .ignore)
        #expect(action(url, keySystem: "") == .ignore)
        #expect(action(url, reason: "network") == .ignore)
        #expect(action("about:blank") == .ignore)
        #expect(action("file:///tmp/video.html") == .ignore)
    }

    @Test func rememberedChoicesWinOverAFailure() {
        let url = "https://video.example.com/watch/1"
        #expect(action(url, notAskedAgain: ["https://video.example.com"]) == .ignore)
        #expect(action(url, notAskedAgain: ["https://other.example.com"]) == .moveToWebKit)

        BrowserPageEnginePolicy.setEngine(.chromium, forURLString: url)
        #expect(action(url) == .ignore)
        BrowserPageEnginePolicy.removeRule(forURLString: url)
        #expect(action(url) == .moveToWebKit)

        BrowserPageEnginePolicy.rememberProtectedVideoSite(forURLString: url)
        BrowserPageEnginePolicy.setEngine(.chromium, forURLString: url)
        #expect(BrowserPageEnginePolicy.engine(forURLString: url) == .chromium)
    }

    @Test func theFairPlayBridgeIgnoresFailures() {
        BrowserPageEnginePolicy.playsProtectedMediaInChromium = true
        #expect(action("https://www.netflix.com/watch/1") == .ignore)
        #expect(action("https://open.spotify.com/track/1") == .ignore)
        #expect(action("https://www.primevideo.com/detail/1") == .moveToWebKit)
    }

    @Test func aSiteIsItsSchemeHostAndPortLowercased() {
        #expect(BrowserPageEnginePolicy
            .site(forURLString: "HTTPS://WWW.Netflix.com/browse?x=1") == "https://www.netflix.com")
        #expect(BrowserPageEnginePolicy.site(forURLString: "http://localhost:3000/a") == "http://localhost:3000")
        #expect(BrowserPageEnginePolicy.site(forURLString: "file:///tmp/a.html") == nil)
        #expect(BrowserPageEnginePolicy.site(forURLString: "about:blank") == nil)
    }

    // MARK: Private

    private func action(
        _ url: String,
        keySystem: String = "com.widevine.alpha",
        reason: String = "license-timeout",
        notAskedAgain: Set<String> = [],
    ) -> BrowserProtectedMediaAction {
        BrowserPageEnginePolicy.decideProtectedMediaAction(
            forURLString: url,
            keySystem: keySystem,
            reason: reason,
            notAskedAgain: notAskedAgain,
        )
    }
}
