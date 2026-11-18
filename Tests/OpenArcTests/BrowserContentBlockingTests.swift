// BrowserContentBlockingTests.swift

import Foundation
import Testing
import WebKit

// MARK: - ContentBlockingFixture

private enum ContentBlockingFixture {
    static let list = """
    [Adblock Plus 2.0]
    ! Title: Fixture
    ||ads.example^
    ||tracker.example^$third-party
    /banner/*/ad.$image
    @@||ads.example/allowed/
    |https://start.example/ad
    ad.js|
    ||cdn.example/pixel.gif$domain=news.example|~sports.news.example
    ||important.example^$important
    @@||important.example^
    @@||trusted.example^$document
    ##.ad-banner
    news.example##.sponsored
    news.example#@#.ad-banner
    ~blog.example##.promo
    @@||nocosmetic.example^$generichide
    example.org#?#div:has-text(Ad)
    example.org##div:has-text(Ad)
    ||redirect.example^$redirect=noopjs
    ||popup.example^$popup
    ||page.example^$document
    /\\/ads\\/[0-9]+/
    example.org##+js(set, x, 1)
    """

    static let engine = BrowserFilterEngine(text: list)

    /// Every host is its own site, so a test names first- and third-party plainly.
    static func request(
        _ url: String,
        from source: String? = "https://site.example/",
        type: BrowserFilterResourceTypes = .script,
    ) throws -> BrowserFilterRequest {
        try #require(BrowserFilterRequest(urlString: url, sourceURLString: source, type: type) { host in
            host.split(separator: ".").suffix(2).joined(separator: ".")
        })
    }

    static func blocks(
        _ url: String,
        from source: String? = "https://site.example/",
        type: BrowserFilterResourceTypes = .script,
        document: String? = nil,
    ) throws -> Bool {
        try engine.blocks(request(url, from: source, type: type), documentURLString: document ?? source)
    }
}

// MARK: - BrowserContentBlockingTests

struct BrowserContentBlockingTests {
    // MARK: - Parsing

    @Test func filterParserReadsNetworkRulesAndTheirOptions() {
        guard case .network(let host) = BrowserFilterListParser.parseLine("||Ads.Example^$third-party,script,~image")
        else {
            Issue.record("not a network rule")
            return
        }
        #expect(host.pattern == "ads.example^")
        #expect(host.anchor == .host)
        #expect(host.thirdParty == true)
        #expect(host.types == .script)
        #expect(host.hostOnlyPattern == "ads.example")

        guard case .network(let exception) = BrowserFilterListParser
            .parseLine("@@|https://x.example/a*b|$domain=a.example|~b.a.example")
        else {
            Issue.record("not a network rule")
            return
        }
        #expect(exception.isException)
        #expect(exception.anchor == .start)
        #expect(exception.endAnchor)
        #expect(exception.includedDomains == ["a.example"])
        #expect(exception.excludedDomains == ["b.a.example"])
        #expect(exception.types == .all)

        guard case .network(let negated) = BrowserFilterListParser.parseLine("/ads/*$~script,~image") else {
            Issue.record("not a network rule")
            return
        }
        #expect(negated.types == BrowserFilterResourceTypes.all.subtracting([.script, .image]))

        guard case .network(let page) = BrowserFilterListParser.parseLine("@@||trusted.example^$document,subdocument")
        else {
            Issue.record("not a network rule")
            return
        }
        #expect(page.documentOptions == [.document])
        #expect(page.types == .subdocument)
    }

    @Test func filterParserLeavesOutRulesItCannotHonor() {
        let skipped = [
            "/\\/ads\\/[0-9]+/",
            "||redirect.example^$redirect=noopjs",
            "||popup.example^$popup",
            "||page.example^$document",
            "||csp.example^$csp=script-src 'none'",
            "example.org#?#div:has-text(Ad)",
            "example.org##div:has-text(Ad)",
            "example.org##+js(set, x, 1)",
            "example.org#$#abort-on-property-read x",
            "example.*##.ad",
            "##.unbalanced[",
            "$third-party",
        ]
        for line in skipped {
            #expect(BrowserFilterListParser.parseLine(line) == .skipped, "\(line)")
        }
        #expect(BrowserFilterListParser.parseLine("! comment") == .comment)
        #expect(BrowserFilterListParser.parseLine("[Adblock Plus 2.0]") == .comment)
        // A regular expression of plain words is the same text found anywhere.
        #expect(BrowserFilterListParser.parseLine("/adframe/") == .network(BrowserNetworkFilter(pattern: "adframe")))
    }

    @Test func filterParserReadsCosmeticRules() {
        #expect(BrowserFilterListParser
            .parseLine("##.ad-banner") == .cosmetic(BrowserCosmeticFilter(selector: ".ad-banner")))
        #expect(BrowserFilterListParser.parseLine("a.example,~b.a.example##div[id^=\"ad\"]") == .cosmetic(
            BrowserCosmeticFilter(
                selector: "div[id^=\"ad\"]",
                includedDomains: ["a.example"],
                excludedDomains: ["b.a.example"],
            ),
        ))
        #expect(BrowserFilterListParser.parseLine("a.example#@#.ad") == .cosmetic(
            BrowserCosmeticFilter(selector: ".ad", includedDomains: ["a.example"], isException: true),
        ))
    }

    // MARK: - Matching

    @Test func wildcardsAndSeparatorsMatchAsFilterListsMeanThem() {
        func glob(_ pattern: String, _ text: String) -> Bool {
            BrowserCompiledNetworkFilter.globMatch(Array(pattern.utf8), Array(text.utf8), from: 0)
        }
        #expect(glob("*ad.js^*", "https://a.example/ad.js?x"))
        #expect(glob("*ad.js^*", "https://a.example/ad.js"))
        #expect(!glob("*ad.js^*", "https://a.example/ad.jsx"))
        #expect(glob("*/banner/*/ad.*", "https://x.example/banner/1/2/ad.png"))
        #expect(!glob("*/banner/*/ad.*", "https://x.example/banner/ad.png"))
        #expect(glob("ad.js", "ad.js"))
        #expect(!glob("ad.js", "ad.js?"))
    }

    @Test func networkFiltersBlockByHostPathTypeAndParty() throws {
        // `||` takes the host and its subdomains, nothing that only contains them.
        #expect(try ContentBlockingFixture.blocks("https://ads.example/x.js"))
        #expect(try ContentBlockingFixture.blocks("https://cdn.ads.example/x.js"))
        #expect(try ContentBlockingFixture.blocks("https://ads.example:8443/x.js"))
        #expect(try !ContentBlockingFixture.blocks("https://badads.example/x.js"))
        #expect(try !ContentBlockingFixture.blocks("https://ads.example.evil/x.js"))
        // An exception wins over a block, and an important block over an exception.
        #expect(try !ContentBlockingFixture.blocks("https://ads.example/allowed/x.js"))
        #expect(try ContentBlockingFixture.blocks("https://important.example/x.js"))
        // Third-party only.
        #expect(try ContentBlockingFixture.blocks("https://tracker.example/t.gif", type: .image))
        #expect(try !ContentBlockingFixture.blocks(
            "https://tracker.example/t.gif",
            from: "https://www.tracker.example/",
        ))
        // Types.
        #expect(try ContentBlockingFixture.blocks("https://x.example/banner/123/ad.png", type: .image))
        #expect(try !ContentBlockingFixture.blocks("https://x.example/banner/123/ad.png", type: .script))
        // Start and end anchors.
        #expect(try ContentBlockingFixture.blocks("https://start.example/ad/1"))
        #expect(try !ContentBlockingFixture.blocks("https://other.example/?u=https://start.example/ad"))
        #expect(try ContentBlockingFixture.blocks("https://any.example/ad.js"))
        #expect(try !ContentBlockingFixture.blocks("https://any.example/ad.js?v=1"))
        // Sites a filter names, and those it leaves out.
        #expect(try ContentBlockingFixture.blocks("https://cdn.example/pixel.gif", from: "https://news.example/"))
        #expect(try ContentBlockingFixture.blocks("https://cdn.example/pixel.gif", from: "https://www.news.example/"))
        #expect(try !ContentBlockingFixture.blocks(
            "https://cdn.example/pixel.gif",
            from: "https://sports.news.example/",
        ))
        #expect(try !ContentBlockingFixture.blocks("https://cdn.example/pixel.gif", from: "https://other.example/"))
        // Rules the parser left out block nothing.
        #expect(try !ContentBlockingFixture.blocks("https://redirect.example/x.js"))
        #expect(try !ContentBlockingFixture.blocks("https://popup.example/x.js"))
        #expect(try !ContentBlockingFixture.blocks("https://x.example/ads/12"))
    }

    @Test func aDocumentExceptionAllowsEverythingOnThatPage() throws {
        #expect(try !ContentBlockingFixture.blocks(
            "https://ads.example/x.js",
            from: "https://trusted.example/",
            document: "https://trusted.example/article",
        ))
        #expect(ContentBlockingFixture.engine.documentOptions(forDocumentURLString: "https://trusted.example/") == [
            .document,
        ])
    }

    @Test func filterRequestsCoverOnlyWebURLs() {
        #expect(BrowserFilterRequest(urlString: "data:text/plain,x", sourceURLString: nil, type: .image) == nil)
        #expect(BrowserFilterRequest(urlString: "chrome://settings/", sourceURLString: nil, type: .other) == nil)
        #expect(BrowserFilterRequest.host(ofURLString: "https://user:pw@Ads.Example:443/x") == "ads.example")
        #expect(BrowserFilterRequest.host(ofURLString: "wss://live.example/socket") == "live.example")
        #expect(BrowserContentBlockingBridge.resourceType(forEngineType: 0) == nil)
        #expect(BrowserContentBlockingBridge.resourceType(forEngineType: 1) == .subdocument)
        #expect(BrowserContentBlockingBridge.resourceType(forEngineType: 13) == .xmlHTTPRequest)
    }

    // MARK: - Element hiding

    @Test func hidingStyleSheetsFollowTheSiteAndItsExceptions() {
        let engine = ContentBlockingFixture.engine
        let other = engine.hidingStyleSheet(forDocumentURLString: "https://site.example/")
        #expect(other.contains(".ad-banner"))
        #expect(other.contains(".promo"))
        #expect(!other.contains(".sponsored"))
        #expect(other.contains("{display:none!important}"))

        let news = engine.hidingStyleSheet(forDocumentURLString: "https://www.news.example/story")
        #expect(news.contains(".sponsored"))
        #expect(!news.contains(".ad-banner"))

        #expect(!engine.hidingStyleSheet(forDocumentURLString: "https://blog.example/").contains(".promo"))
        #expect(!engine.hidingStyleSheet(forDocumentURLString: "https://nocosmetic.example/").contains(".ad-banner"))
        #expect(engine.hidingStyleSheet(forDocumentURLString: "https://trusted.example/").isEmpty)
        // A frame inside a page gets only its own site's rules.
        #expect(!engine.hidingStyleSheet(forDocumentURLString: "https://site.example/", includesGeneric: false)
            .contains(".ad-banner"))
    }

    @Test func hidingRulesGroupSelectorsSoOneInvalidOneLosesOnlyItsGroup() {
        let selectors = (0..<45).map { ".ad-\($0)" }
        let css = BrowserCosmeticIndex.styleSheet(selectors)
        #expect(css.components(separatedBy: "{display:none!important}").count - 1 == 3)
    }

    // MARK: - Settings

    @Test func contentBlockingIsOnByDefaultAndReadsOlderSettings() throws {
        let settings = BrowserContentBlockingSettings()
        #expect(settings.enabledKinds == [.ads, .trackers, .cookieBanners])
        let decoded = try JSONDecoder().decode(
            BrowserContentBlockingSettings.self,
            from: Data(#"{"blocksTrackers":false}"#.utf8),
        )
        #expect(decoded.blocksAds)
        #expect(!decoded.blocksTrackers)
        #expect(decoded.blocksCookieBanners)
        #expect(decoded.allowedSites.isEmpty)
    }

    @Test func allowingASiteCoversItsSubdomainsUntilBlockedAgain() {
        var settings = BrowserContentBlockingSettings()
        #expect(BrowserContentBlockingSettings.siteKey(forURLString: "https://WWW.News.Example/a") == "news.example")
        #expect(BrowserContentBlockingSettings.siteKey(forURLString: "openarc://settings") == nil)

        settings.setAllowed(true, urlString: "https://www.news.example/a")
        #expect(settings.allowedSites == ["news.example"])
        #expect(settings.isAllowed(urlString: "https://news.example/"))
        #expect(settings.isAllowed(urlString: "https://sports.news.example/"))
        #expect(!settings.isAllowed(urlString: "https://othernews.example/"))
        // Already covered by its parent.
        settings.setAllowed(true, urlString: "https://sports.news.example/")
        #expect(settings.allowedSites == ["news.example"])
        // Blocking on a subdomain ends the parent's allowance too.
        settings.setAllowed(false, urlString: "https://sports.news.example/")
        #expect(settings.allowedSites.isEmpty)

        settings.setAllowed(true, urlString: "https://b.example/")
        settings.setAllowed(true, urlString: "https://a.example/")
        #expect(settings.allowedSites == ["a.example", "b.example"])
        settings.removeAllowedSite("a.example")
        #expect(settings.allowedSites == ["b.example"])
    }

    @Test func theBlockerFollowsItsSettingsAndAllowedSites() {
        let blocker = BrowserContentBlocker()
        blocker.install(ContentBlockingFixture.engine, for: .ads)
        func blocks(_ document: String) -> Bool {
            blocker.shouldBlock(
                urlString: "https://ads.example/x.js",
                sourceURLString: document,
                documentURLString: document,
                type: .script,
            )
        }
        #expect(blocks("https://site.example/"))
        // Pages that are not on the web, such as the browser's own, are left alone.
        #expect(!blocks("chrome://settings/"))

        var settings = BrowserContentBlockingSettings()
        settings.setAllowed(true, urlString: "https://site.example/")
        blocker.update(settings: settings)
        #expect(!blocks("https://site.example/"))
        #expect(blocker.hidingScript(
            frameURLString: "https://site.example/",
            documentURLString: "https://site.example/",
            isMainFrame: true,
        ) == nil)
        #expect(blocks("https://other.example/"))

        settings.blocksAds = false
        blocker.update(settings: settings)
        #expect(!blocks("https://other.example/"))
    }

    @Test func theHidingScriptAddsTheStyleSheetOnce() throws {
        let blocker = BrowserContentBlocker()
        blocker.install(ContentBlockingFixture.engine, for: .cookieBanners)
        let script = try #require(blocker.hidingScript(
            frameURLString: "https://site.example/",
            documentURLString: "https://site.example/",
            isMainFrame: true,
        ))
        #expect(script.contains("adoptedStyleSheets"))
        #expect(script.contains(".ad-banner"))
        #expect(BrowserContentBlocker.script(addingStyleSheet: "a[href=\"x\"]{}").contains(#"a[href=\"x\"]{}"#))
    }

    // MARK: - WebKit

    @Test func contentRuleURLFiltersMatchTheFilterAnchors() {
        func filters(_ line: String) -> [String] {
            guard case .network(let filter) = BrowserFilterListParser.parseLine(line) else { return [] }
            return BrowserContentRuleListCompiler.urlFilters(for: filter)
        }
        #expect(filters("||ads.example^") == [#"^[^:]+://+([^:/]+\.)?ads\.example[^a-zA-Z0-9_.%-]"#])
        #expect(filters("/ad.js^") == [#"/ad\.js[^a-zA-Z0-9_.%-]"#, #"/ad\.js$"#])
        #expect(filters("|https://x.example/a?b=*|") == [#"^https://x\.example/a\?b=.*$"#])
    }

    @Test func contentRulesKeepTheListsOrderAndOptions() {
        let rules = BrowserContentRuleListCompiler
            .rules(for: BrowserFilterListParser.parse(ContentBlockingFixture.list))
        let actions = rules.map(\.action.type)
        let lastBlock = actions.lastIndex(of: "block") ?? 0
        let firstException = actions.firstIndex(of: "ignore-previous-rules") ?? 0
        let firstHiding = actions.firstIndex(of: "css-display-none") ?? 0
        #expect(firstException < firstHiding)
        // The important block comes after the exceptions it overrides.
        #expect(lastBlock > firstException)
        let tracker = rules.first { $0.trigger.urlFilter.contains("tracker") }
        #expect(tracker?.trigger.loadType == ["third-party"])
        let pixel = rules.first { $0.trigger.urlFilter.contains("pixel") }
        #expect(pixel?.trigger.ifDomain == ["*news.example"])
        let banner = rules.first { $0.trigger.urlFilter.contains("banner") }
        #expect(banner?.trigger.resourceType == ["image"])
        #expect(rules.contains { $0.action.selector == ".sponsored" && $0.trigger.ifDomain == ["*news.example"] })
        #expect(rules.contains { $0.action.selector == ".ad-banner" && $0.trigger.unlessDomain == ["*news.example"] })
        #expect(rules.last?.trigger.ifTopURL?.first?.contains("trusted") == true)
    }

    @MainActor @Test func webKitCompilesTheContentRules() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OpenArcContentRules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let json = BrowserContentRuleListCompiler
            .encodedJSON(for: BrowserFilterListParser.parse(ContentBlockingFixture.list))
        let compiled = try await store.compileContentRuleList(forIdentifier: "fixture", encodedContentRuleList: json)
        #expect(compiled != nil)
    }

    // MARK: - Site controls

    @MainActor @Test func siteControlsAllowAdsOnTheSite() throws {
        let suite = BrowserTestDefaults.suiteName("BrowserContentBlockingTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(),
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(extensions: []),
            windowMode: .normal,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        defer {
            model.discardUnsavedSessionForClosure()
            model.prepareForTermination()
        }
        let url = "https://www.news.example/story"
        func row() -> BrowserSiteSettingRow? {
            model.siteSettingRows(forURLString: url).first { $0.kind == .contentBlocking }
        }
        #expect(row()?.value == .block)
        #expect(BrowserSiteSettingKind.contentBlocking.choices == [.block, .allow])
        #expect(BrowserSiteSettingKind.contentBlocking.menuTitle(for: .allow) == BrowserStrings
            .siteSettingContentBlockingAllow)

        model.setSiteSetting(.contentBlocking, value: .allow, forURLString: url)
        #expect(row()?.value == .allow)
        #expect(model.userPreferencesStore.contentBlocking.allowedSites == ["news.example"])
        // The allowance is kept with the other settings.
        let reloaded = BrowserUserPreferencesStore(userDefaults: defaults)
        #expect(reloaded.contentBlocking.allowedSites == ["news.example"])

        model.setSiteSetting(.contentBlocking, value: .block, forURLString: url)
        #expect(row()?.value == .block)
        #expect(model.siteSettingRows(forURLString: "openarc://settings").isEmpty)

        model.userPreferencesStore.contentBlocking = {
            var settings = BrowserContentBlockingSettings()
            for kind in BrowserFilterListKind.allCases {
                settings.setBlocks(kind, false)
            }
            return settings
        }()
        #expect(row() == nil)
    }

    @Test func shippedListsBlockWellKnownAdsAndTrackers() throws {
        for kind in BrowserFilterListKind.allCases {
            #expect(try BrowserFilterListUpdater.looksLikeFilterList(shippedList(kind)), "\(kind)")
        }
        let ads = try BrowserFilterEngine(text: shippedList(.ads))
        let trackers = try BrowserFilterEngine(text: shippedList(.trackers))
        let cookies = try BrowserFilterEngine(text: shippedList(.cookieBanners))
        #expect(ads.networkFilterCount > 10000)
        #expect(trackers.networkFilterCount > 10000)

        let page = "https://news.example/"
        func request(_ url: String, _ type: BrowserFilterResourceTypes) throws -> BrowserFilterRequest {
            try #require(BrowserFilterRequest(urlString: url, sourceURLString: page, type: type))
        }
        #expect(try ads.blocks(
            request("https://securepubads.g.doubleclick.net/tag/js/gpt.js", .script),
            documentURLString: page,
        ))
        #expect(try trackers.blocks(
            request("https://www.google-analytics.com/analytics.js", .script),
            documentURLString: page,
        ))
        #expect(try !ads.blocks(request("https://news.example/app.js", .script), documentURLString: page))
        #expect(try !trackers.blocks(request("https://news.example/logo.png", .image), documentURLString: page))
        #expect(cookies.hidingStyleSheet(forDocumentURLString: page).isEmpty == false)
    }
}

// MARK: - Shipped lists

/// The lists the app ships, which the test bundle carries too.
private func shippedList(_ kind: BrowserFilterListKind) throws -> String {
    let url = try #require(Bundle(for: ShippedListsBundleToken.self)
        .url(forResource: kind.bundledResourceName, withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8)
}

private final class ShippedListsBundleToken {}
