// BrowserContentBlockerTests.swift

import Foundation
import Testing

// MARK: - BrowserContentBlockerTests

@Suite(.serialized)
@MainActor struct BrowserContentBlockerTests {
    @Test func parsesHostRulesAndSkipsWhatItCannotDo() {
        let list = BrowserFilterList(parsing: """
        [Adblock Plus 2.0]
        ! a comment
        ||ads.example^
        ||tracker.example^$third-party
        ||scripts.example^$script
        ||limited.example^$domain=news.example
        ||path.example/banner.js
        @@||good.example^
        @@||conditional.example^$document
        /generic-banner.
        ##.generic-ad
        news.example,~other.example##.banner
        news.example##div:has-text(sponsored)
        news.example#@#.allowed
        news.example#?#.scripted
        """)
        #expect(list.blockedHosts == ["ads.example"])
        #expect(list.thirdPartyHosts == ["tracker.example"])
        #expect(list.exceptionHosts == ["good.example"])
        #expect(list.genericSelectors == [".generic-ad"])
        #expect(list.selectorsByHost == ["news.example": [".banner"]])
    }

    @Test func combinesListsAndKeepsGenericHidingOnlyWhereAsked() {
        let ads = BrowserFilterList(parsing: "||ads.example^\n##.ad\nnews.example##.ad2")
        let cookies = BrowserFilterList(parsing: "##.cookie-banner\nnews.example##.consent")
        let rules = BrowserContentBlockerRules(
            lists: [(ads, false), (cookies, true)],
            excludedSites: ["mine.example"],
        )
        #expect(rules.blockedHosts == ["ads.example"])
        #expect(rules.genericSelectors == [".cookie-banner"])
        #expect(rules.selectorsByHost["news.example"] == [".ad2", ".consent"])
        #expect(rules.excludedSites == ["mine.example"])
    }

    @Test func listsDownloadOnlyWhenEnabledAndStayFreshForAWeek() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Filters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetched = Fetched()
        var applied = [BrowserContentBlockerRules]()
        var now = Date()
        let blocker = BrowserContentBlocker(
            directory: directory,
            loader: { url in
                await fetched.add(url)
                return Data("||\(url.host ?? "x").blocked.example^".utf8)
            },
            apply: { applied.append($0) },
            now: { now },
        )
        blocker.update(settings: BrowserContentBlockerSettings(blocksAds: true))
        await blocker.waitForPendingWork()
        #expect(await fetched.count == 1)
        #expect(applied.last?.blockedHosts == ["easylist.to.blocked.example"])
        blocker.update(settings: BrowserContentBlockerSettings(blocksAds: true, blocksTrackers: true))
        await blocker.waitForPendingWork()
        #expect(await fetched.count == 2, "The saved list is used again")
        #expect(applied.last?.blockedHosts.count == 1, "Both test lists name the same host")
        blocker.update(settings: BrowserContentBlockerSettings())
        await blocker.waitForPendingWork()
        #expect(applied.last?.blockedHosts.isEmpty == true, "Off applies an empty rule set")
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        blocker.update(settings: BrowserContentBlockerSettings(blocksAds: true))
        await blocker.waitForPendingWork()
        #expect(await fetched.count == 3, "An old list downloads again")
    }

    @Test func aFailedDownloadKeepsTheOldCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("ads.txt")
        try "||old.example^".write(to: saved, atomically: true, encoding: .utf8)
        var applied = [BrowserContentBlockerRules]()
        let blocker = BrowserContentBlocker(
            directory: directory,
            loader: { _ in throw URLError(.notConnectedToInternet) },
            apply: { applied.append($0) },
            now: { Date().addingTimeInterval(30 * 24 * 60 * 60) },
        )
        blocker.update(settings: BrowserContentBlockerSettings(blocksAds: true))
        await blocker.waitForPendingWork()
        #expect(applied.last?.blockedHosts == ["old.example"])
        #expect(!blocker.lastUpdateFailed, "A saved copy counts as success")
    }

    @Test func aSiteCanBeExcludedAndBroughtBack() {
        var settings = BrowserContentBlockerSettings(blocksAds: true)
        #expect(!settings.isExcluded(host: "www.example.com"))
        settings = settings.excluding(true, host: "www.Example.com")
        #expect(settings.excludedHosts == ["example.com"])
        #expect(settings.isExcluded(host: "example.com"))
        #expect(settings.isExcluded(host: "news.example.com"), "Subdomains follow the site")
        #expect(!settings.isExcluded(host: "notexample.com"))
        #expect(settings.excluding(true, host: "news.example.com") == settings, "Already covered")
        settings = settings.excluding(false, host: "news.example.com")
        #expect(settings.excludedHosts.isEmpty, "Bringing back a subdomain clears what covered it")
    }

    @Test func themesBecomeCSSVariables() throws {
        let theme = BrowserSpaceTheme(key: BrowserSpaceTheme.Color(1, 0.522, 0.344), colorCount: 3, wheel: .analogous)
        let script = try #require(theme.pageScript)
        #expect(script.contains("--arc-palette-title"))
        #expect(script.contains("--arc-background-gradient-overlay-color1"))
        #expect(BrowserSpaceTheme().pageScript == nil)
    }
}

// MARK: - Fetched

private actor Fetched {
    private(set) var count = 0

    func add(_: URL) { count += 1 }
}
