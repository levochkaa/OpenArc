// BrowserBoostsTests.swift

import AppKit
import Foundation
import JavaScriptCore
import Testing

// MARK: - BrowserBoostsTests

@MainActor struct BrowserBoostsTests {
    // MARK: Private

    private static func literal(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed])) ?? Data()
        return String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029") ?? "''"
    }

    /// A document with a root element that holds one child, enough for the boost scripts.
    private static func domContext(hostname: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this;
        var ran = [];
        var errors = [];
        var console = { error: function () { errors.push(arguments); } };
        var location = { hostname: \(literal(hostname)) };
        var elements = {};
        function element() {
          var node = { parentNode: null, nextSibling: null, textContent: '' };
          node.remove = function () {
            var parent = node.parentNode;
            if (!parent) return;
            parent.children.splice(parent.children.indexOf(node), 1);
            node.parentNode = null;
            delete elements[node.id];
          };
          return node;
        }
        var root = { children: [element()] };
        root.appendChild = function (node) {
          if (node.parentNode === root) root.children.splice(root.children.indexOf(node), 1);
          if (root.children.length) root.children[root.children.length - 1].nextSibling = node;
          root.children.push(node);
          node.parentNode = root;
          node.nextSibling = null;
          if (node.id) elements[node.id] = node;
        };
        var document = {
          readyState: 'complete',
          documentElement: root,
          getElementById: function (id) { return elements[id] || null; },
          createElement: function () { return element(); },
          addEventListener: function () {},
        };
        """)
        return context
    }

    /// `createElementNS` for the fake document, with attributes and children.
    private static func addSVGSupport(to context: JSContext) {
        context.evaluateScript("""
        document.createElementNS = function (ns, name) {
          var node = element();
          node.tagName = name;
          node.attributes = {};
          node.children = [];
          node.setAttribute = function (key, value) {
            node.attributes[key] = String(value);
            if (key === 'id') node.id = String(value);
          };
          node.getAttribute = function (key) { return key in node.attributes ? node.attributes[key] : null; };
          node.appendChild = function (child) { node.children.push(child); child.parentNode = node; };
          return node;
        };
        """)
    }

    @Test func aPageBelongsToItsHostWithoutWWWOrATrailingDot() {
        #expect(BrowserBoost.host(ofURLString: "https://www.Example.com./a?b") == "example.com")
        #expect(BrowserBoost.host(ofURLString: "http://news.example.com:8080/") == "news.example.com")
        #expect(BrowserBoost.host(ofURLString: "http://localhost:3000") == "localhost")
        #expect(BrowserBoost.host(ofURLString: "openarc://settings") == nil)
        #expect(BrowserBoost.host(ofURLString: "file:///tmp/a.html") == nil)
        #expect(BrowserBoost.host(ofURLString: "about:blank") == nil)
        #expect(BrowserBoost.normalizedHost(" WWW.example.com ") == "example.com")
        #expect(BrowserBoost.normalizedHost("www.com") == "www.com", "www. is part of a two-label host")
        #expect(BrowserBoost.normalizedHost("  ") == nil)
        #expect(BrowserBoost.candidateHosts(forHost: "a.b.example.com") == [
            "a.b.example.com", "b.example.com", "example.com", "com",
        ])
    }

    @Test func theClosestDomainsBoostThatIsOnApplies() {
        let boosts = [
            BrowserBoost(host: "example.com", css: "body { color: red }"),
            BrowserBoost(host: "news.example.com", isEnabled: false, css: "p { color: blue }"),
            BrowserBoost(host: "mail.example.com", css: "a { color: green }"),
        ]
        #expect(boosts.applicableBoost(forURLString: "https://www.example.com/")?.host == "example.com")
        #expect(boosts.applicableBoost(forURLString: "https://mail.example.com/inbox")?.host == "mail.example.com")
        #expect(boosts.applicableBoost(forURLString: "https://a.mail.example.com")?.host == "mail.example.com")
        #expect(
            boosts.applicableBoost(forURLString: "https://news.example.com")?.host == "example.com",
            "A Boost that is off lets the parent domain's apply",
        )
        #expect(boosts.applicableBoost(forURLString: "https://notexample.com") == nil)
        #expect(boosts.applicableBoost(forURLString: "https://example.org") == nil)

        #expect(boosts.editableHost(forURLString: "https://news.example.com/a") == "news.example.com")
        #expect(boosts.editableHost(forURLString: "https://deep.news.example.com") == "news.example.com")
        #expect(boosts.editableHost(forURLString: "https://www.other.org") == "other.org")
        #expect(boosts.editableHost(forURLString: "openarc://history") == nil)
    }

    @Test func updatingABoostCreatesItKeepsZapsUniqueAndRemovesItWhenEmpty() throws {
        var boosts = [BrowserBoost]()
        boosts.updateBoost(host: "Example.com") { $0.isEnabled = false }
        #expect(boosts.isEmpty, "A Boost that adds nothing is not saved")

        boosts.updateBoost(host: "www.example.com") { $0.zappedSelectors = ["#ad", "#ad", " ", ".banner"] }
        #expect(boosts
            .map(\.syncRecord) == [BrowserBoost(host: "example.com", zappedSelectors: ["#ad", ".banner"]).syncRecord])
        let identity = try #require(boosts.first?.syncID)

        boosts.updateBoost(host: "example.com") { $0.css = "a {}" }
        #expect(boosts.first?.syncID == identity, "Edits keep the boost's identity")
        boosts.updateBoost(host: "other.org") { $0.javaScript = "1" }
        #expect(boosts.map(\.host) == ["example.com", "other.org"])
        #expect(boosts.boost(forHost: "example.com")?.css == "a {}")

        boosts.updateBoost(host: "example.com") { boost in
            boost.css = "  \n"
            boost.zappedSelectors = []
        }
        #expect(boosts.map(\.host) == ["other.org"])
        boosts.removeBoost(host: "other.org")
        #expect(boosts.isEmpty)
    }

    @Test func boostsPersistWithThePreferences() throws {
        let defaults = try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserBoostsTests")))
        let boosts = [
            BrowserBoost(host: "example.com", css: "body { margin: 0 }", zappedSelectors: ["#cookie-banner"]),
            BrowserBoost(host: "news.example.com", isEnabled: false, javaScript: "console.log('hi')"),
        ]
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).boosts.isEmpty)
        BrowserUserPreferencesStore(userDefaults: defaults).boosts = boosts
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).boosts == boosts)

        let older = Data(#"[{"host":"example.com","css":"a {}"}]"#.utf8)
        let decoded = try JSONDecoder().decode([BrowserBoost].self, from: older)
        #expect(
            decoded.map(\.syncRecord) == [BrowserBoost(host: "example.com", css: "a {}").syncRecord],
            "Missing fields take their defaults",
        )

        // Boosts saved before sync get an identity once, and keep it.
        defaults.set(older, forKey: "browser.settings.boosts")
        let identified = BrowserUserPreferencesStore(userDefaults: defaults).boosts
        #expect(identified.count == 1)
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).boosts == identified)
    }

    @Test func openPagesRestyleForCSSAndReloadForJavaScript() {
        let url = "https://www.example.com/page"
        let css = [BrowserBoost(host: "example.com", css: "a {}")]
        let zapped = [BrowserBoost(host: "example.com", css: "a {}", zappedSelectors: ["#ad"])]
        let scripted = [BrowserBoost(host: "example.com", css: "a {}", javaScript: "run()")]

        #expect(BrowserBoostRefresh.refresh(forURLString: url, from: css, to: css) == .none)
        #expect(BrowserBoostRefresh.refresh(forURLString: "https://example.org", from: [], to: css) == .none)
        guard case .restyle(let script) = BrowserBoostRefresh.refresh(forURLString: url, from: css, to: zapped)
        else {
            Issue.record("A new zap restyles the page")
            return
        }
        #expect(script.contains("#ad { display: none !important; }"))
        #expect(BrowserBoostRefresh.refresh(forURLString: url, from: css, to: scripted) == .reload)
        #expect(BrowserBoostRefresh.refresh(forURLString: url, from: scripted, to: []) == .reload)
        #expect(
            BrowserBoostRefresh.refresh(forURLString: url, from: zapped, to: []) ==
                .restyle(BrowserBoostScript.styleScript(stylesheet: "")),
            "A deleted Boost takes its stylesheet away",
        )
        var off = zapped
        off[0].isEnabled = false
        #expect(
            BrowserBoostRefresh.refresh(forURLString: url, from: zapped, to: off) ==
                .restyle(BrowserBoostScript.styleScript(stylesheet: "")),
        )
        let child = css + [BrowserBoost(host: "a.example.com", css: "b {}")]
        #expect(
            BrowserBoostRefresh.refresh(forURLString: "https://a.example.com", from: child, to: child.map { boost in
                var boost = boost
                if boost.host == "example.com" { boost.css = "changed {}" }
                return boost
            }) == .none,
            "A page whose own subdomain has a Boost ignores the parent's changes",
        )
    }

    @Test func documentScriptsAddTheStylesheetThenTheJavaScript() {
        let boost = BrowserBoost(
            host: "example.com",
            css: "body { background: url(\"x.png\") }",
            javaScript: "document.title = 'Boosted'",
            zappedSelectors: ["div.ad > a"],
        )
        let scripts = BrowserBoostScript.documentScripts(forURLString: "https://example.com", in: [boost])
        #expect(scripts.count == 2)
        #expect(scripts[0].contains(#"background: url(\"x.png\")"#))
        #expect(scripts[0].contains("div.ad > a { display: none !important; }"))
        #expect(scripts[1].contains("document.title = 'Boosted'"))
        #expect(BrowserBoostScript.documentScripts(forURLString: "https://example.org", in: [boost]).isEmpty)

        var off = boost
        off.isEnabled = false
        #expect(BrowserBoostScript.documentScripts(for: off).isEmpty)
        #expect(BrowserBoostScript.documentScripts(for: BrowserBoost(host: "a.com", css: "a {}")).count == 1)
        #expect(BrowserBoostScript.documentScripts(for: BrowserBoost(host: "a.com", javaScript: "x()")).count == 1)
    }

    @Test func everyGeneratedScriptParses() throws {
        let tricky = BrowserBoost(
            host: "example.com",
            css: "a::after { content: \"</style>\\u2028 `${x}` '\" }\u{2028}\n/* \u{2029} */",
            javaScript: "// a comment on the last line",
            zappedSelectors: ["a[href=\"x\"]", "#a\\:b"],
        )
        let scripts = BrowserBoostScript.documentScripts(for: tricky)
            + BrowserBoostScript.webKitUserScripts(for: [tricky, BrowserBoost(host: "b.org", javaScript: "1")])
            + [
                BrowserBoostScript.styleScript(stylesheet: ""),
                BrowserBoostScript.zapStartScript,
                BrowserBoostScript.zapPollScript,
                BrowserBoostScript.zapStopScript,
            ]
        let context = try #require(JSContext())
        for script in scripts {
            let checked = context
                .evaluateScript("(function () { new Function(\(Self.literal(script))); return 'ok'; })()")
            #expect(checked?.toString() == "ok", "\(script)")
            context.exception = nil
        }
    }

    @Test func theStyleScriptPlacesReplacesAndRemovesOneStyleElement() throws {
        let context = try Self.domContext(hostname: "example.com")
        context.evaluateScript(BrowserBoostScript.styleScript(stylesheet: "a { color: red }"))
        context.evaluateScript(BrowserBoostScript.styleScript(stylesheet: "a { color: blue }"))
        #expect(context.evaluateScript("root.children.length")?.toInt32() == 2)
        #expect(context.evaluateScript("root.children[1].id")?.toString() == BrowserBoostScript.styleElementID)
        #expect(context.evaluateScript("root.children[1].textContent")?.toString() == "a { color: blue }")
        context.evaluateScript(BrowserBoostScript.styleScript(stylesheet: ""))
        #expect(context.evaluateScript("root.children.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    @Test func javaScriptRunsOncePerDocumentAndAThrowStaysInIt() throws {
        let context = try Self.domContext(hostname: "example.com")
        let script = BrowserBoostScript.javaScriptScript("ran.push(1); throw new Error('boom')")
        context.evaluateScript(script)
        context.evaluateScript(script)
        #expect(context.evaluateScript("ran.length")?.toInt32() == 1)
        #expect(context.evaluateScript("errors.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    @Test func webKitRunsOnlyTheClosestBoostThatIsOn() throws {
        let boosts = [
            BrowserBoost(host: "example.com", javaScript: "ran.push('example.com')"),
            BrowserBoost(host: "mail.example.com", javaScript: "ran.push('mail.example.com')"),
            BrowserBoost(host: "news.example.com", isEnabled: false, javaScript: "ran.push('news.example.com')"),
        ]
        let scripts = BrowserBoostScript.webKitUserScripts(for: boosts)
        #expect(scripts.count == 2, "A Boost that is off adds no user script")
        for (hostname, expected) in [
            ("www.mail.example.com", "mail.example.com"),
            ("news.example.com", "example.com"),
            ("example.com.", "example.com"),
            ("example.org", ""),
            ("", ""),
        ] {
            let context = try Self.domContext(hostname: hostname)
            for script in scripts {
                context.evaluateScript(script)
            }
            #expect(context.evaluateScript("ran.join(',')")?.toString() == expected, "\(hostname)")
            #expect(context.exception == nil)
        }
        #expect(BrowserBoostScript.webKitUserScripts(for: []).isEmpty)
    }

    @Test func zapPollsDecode() {
        #expect(BrowserBoostScript.zapPoll(fromJSON: ##"{"picked":["#a"],"done":false}"##) == .init(
            picked: ["#a"],
            done: false,
        ))
        #expect(BrowserBoostScript.zapPoll(fromJSON: nil) == nil)
        #expect(BrowserBoostScript.zapPoll(fromJSON: "started") == nil)
    }

    @Test func theCatalogAnnouncesChangesWithTheOldAndNewBoosts() {
        let catalog = BrowserBoostCatalog()
        var changes = [BrowserBoostCatalog.Change]()
        let observation = catalog.changes.sink { changes.append($0) }
        let boosts = [BrowserBoost(host: "example.com", css: "a {}")]
        catalog.update(boosts)
        catalog.update(boosts)
        #expect(changes.count == 1)
        #expect(changes.first?.old == [])
        #expect(changes.first?.new == boosts)
        #expect(catalog.documentScripts(forURLString: "https://example.com").count == 1)
        observation.cancel()
    }

    // MARK: Window model

    @Test func aWindowRestylesAndReloadsTheSitesOpenTabs() {
        let (model, driver) = makeBoostModel(urls: ["https://www.example.com/a", "https://other.org"])
        let tabIDs = model.tabs.map(\.id)
        let old = [BrowserBoost(host: "example.com", css: "a {}")]
        model.applyBoostChange(from: old, to: [BrowserBoost(host: "example.com", css: "b {}")])
        #expect(driver.evaluatedScripts.map(\.tabID) == [tabIDs[0]])
        #expect(driver.evaluatedScripts.last?.code.contains("b {}") == true)

        model.applyBoostChange(from: old, to: [BrowserBoost(host: "example.com", css: "a {}", javaScript: "x()")])
        #expect(driver.evaluatedScripts.last?.tabID == tabIDs[0])
        #expect(driver.evaluatedScripts.last?.code == "location.reload(); undefined")
        #expect(driver.evaluatedScripts.count == 2)
    }

    @Test func newFieldsRoundTripAndOddValuesDecodeLeniently() throws {
        let boost = BrowserBoost(
            host: "example.com",
            title: "Calm",
            colors: BrowserBoostColors(
                tint: .init(hue: 300, saturation: 0.5, secondaryHueOffset: -20),
                invertsLightness: true,
                contrast: 1.2,
                brightness: 0.9,
                originalSaturation: 0.3,
            ),
            fontFamily: "Georgia",
            textCase: .uppercase,
            textZoom: 1.25,
        )
        let data = try JSONEncoder().encode([boost])
        #expect(try JSONDecoder().decode([BrowserBoost].self, from: data) == [boost])
        let older = try JSONDecoder().decode([BrowserBoost].self, from: Data(#"[{"host":"a.com","css":"a {}"}]"#.utf8))
        #expect(try !String(decoding: JSONEncoder().encode(older), as: UTF8.self).contains("colors"))
        let odd = Data(#"[{"host":"a.com","textCase":"smallcaps","colors":{"tint":7},"textZoom":"big","title":3}]"#
            .utf8)
        let decoded = try #require(try JSONDecoder().decode([BrowserBoost].self, from: odd).first)
        #expect(decoded.textCase == nil && decoded.textZoom == nil && decoded.title == nil)
        #expect(decoded.colors == BrowserBoostColors(), "A broken tint leaves the other color fields' defaults")
    }

    @Test func styleEditsKeepABoostAndOriginalValuesDropOut() {
        var boosts = [BrowserBoost]()
        boosts.updateBoost(host: "example.com") { $0.colors = BrowserBoostColors() }
        #expect(boosts.isEmpty, "Original colors are no Boost")
        boosts.updateBoost(host: "example.com") { $0.textZoom = 1.1 }
        #expect(boosts.first?.hasStyle == true)
        boosts.updateBoost(host: "example.com") { $0.textZoom = 1 }
        #expect(boosts.isEmpty, "Back to the site's size drops the Boost")
        boosts.updateBoost(host: "example.com") { $0.title = "Named" }
        #expect(boosts.first?.title == "Named", "A named Boost stays without content")
        #expect(boosts.first?.displayTitle(defaultTitle: "My Boost") == "Named")
        boosts.updateBoost(host: "example.com") { $0.title = "  " }
        #expect(boosts.isEmpty)
    }

    @Test func fontCaseAndZapsReachEveryFrameAndColorsOnlyTheTopPage() throws {
        let boost = BrowserBoost(
            host: "example.com",
            css: "a { color: red }",
            zappedSelectors: ["#ad"],
            colors: BrowserBoostColors(invertsLightness: true, contrast: 1.2),
            fontFamily: "Snell Roundhand",
            textCase: .lowercase,
            textZoom: 1.1,
        )
        let lines = boost.activeStylesheet.components(separatedBy: "\n")
        #expect(lines == [
            #"*:not(i, .material-symbols-outlined, .material-icons) { font-family: "Snell Roundhand", cursive !important; }"#,
            "*:not(i, .material-symbols-outlined, .material-icons) { text-transform: lowercase !important; }",
            "a { color: red }",
            "#ad { display: none !important; }",
        ])
        #expect(boost.activePageStylesheet.components(separatedBy: "\n") == [
            "html { zoom: 1.1 !important; }",
            "html { filter: invert(1) hue-rotate(180deg) contrast(1.2) !important; }",
            "img, video, canvas, iframe, embed, object, svg image { filter: invert(1) hue-rotate(180deg) !important; }",
        ])
        #expect(boost.activeTintFilter == nil)
        #expect(BrowserBoostFont.cssValue(#"Odd "Name""#) == #""Odd \"Name\"", sans-serif"#)

        var tinted = boost
        tinted.colors?.tint = .init(hue: 120, saturation: 1)
        #expect(tinted.activePageStylesheet.contains("url(#\(BrowserBoostScript.tintFilterID))"))
        let filter = try #require(tinted.activeTintFilter)
        #expect(filter.red.count == BrowserBoostTintFilter.stopCount)
        // Black maps to the darkest shade, white to the lightest; green dominates the light end.
        #expect(try #require(filter.green.last) > 0.9 && #require(filter.red.last) < #require(filter.green.last))
        #expect(try #require(filter.green.first) < 0.15)
        tinted.isEnabled = false
        #expect(tinted.activePageStylesheet.isEmpty && tinted.activeTintFilter == nil && tinted.activeStylesheet
            .isEmpty)
    }

    @Test func colorChangesRestyleOpenPagesWithoutReloading() {
        let url = "https://example.com"
        let plain = [BrowserBoost(host: "example.com", css: "a {}")]
        var tinted = plain
        tinted[0].colors = BrowserBoostColors(tint: .init(hue: 200, saturation: 0.6))
        guard case .restyle(let script) = BrowserBoostRefresh.refresh(forURLString: url, from: plain, to: tinted) else {
            Issue.record("A tint restyles the page")
            return
        }
        #expect(script.contains(BrowserBoostScript.tintFilterID))
        var zoomed = plain
        zoomed[0].textZoom = 1.5
        #expect(BrowserBoostRefresh.refresh(forURLString: url, from: plain, to: zoomed) != .none)
        #expect(BrowserBoostRefresh.refresh(forURLString: url, from: plain, to: zoomed) != .reload)
    }

    @Test func theTopDocumentTakesThePageRulesAndTheTintFilterAndFramesDoNot() throws {
        let tint = BrowserBoostTintFilter(tint: .init(hue: 20, saturation: 0.5), originalSaturation: 0.25)
        let script = BrowserBoostScript.styleScript(
            stylesheet: "a {}",
            pageStylesheet: "html { zoom: 2 !important; }",
            tint: tint,
        )
        let top = try Self.domContext(hostname: "example.com")
        Self.addSVGSupport(to: top)
        top.evaluateScript(script)
        #expect(top.exception == nil, "\(String(describing: top.exception))")
        #expect(top.evaluateScript("root.children.length")?.toInt32() == 3, "The SVG filter, then the style")
        #expect(top.evaluateScript("root.children[1].id")?.toString() == BrowserBoostScript.filterElementID)
        #expect(top.evaluateScript("root.children[1].children[0].attributes.id")?.toString()
            == BrowserBoostScript.tintFilterID)
        #expect(top.evaluateScript("root.children[2].textContent")?.toString()
            == "a {}\nhtml { zoom: 2 !important; }")
        #expect(top.evaluateScript("root.children[1].children[0].children[2].attributes.k3")?.toString() == "0.25")
        top.evaluateScript(BrowserBoostScript.styleScript(stylesheet: "a {}"))
        #expect(top.evaluateScript("root.children.length")?.toInt32() == 2, "No tint removes the filter")

        let frame = try Self.domContext(hostname: "example.com")
        Self.addSVGSupport(to: frame)
        frame.evaluateScript("window.top = {};")
        frame.evaluateScript(script)
        #expect(frame.exception == nil)
        #expect(frame.evaluateScript("root.children.length")?.toInt32() == 2, "A frame gets no filter")
        #expect(frame.evaluateScript("root.children[1].textContent")?.toString() == "a {}")
    }

    @Test func theCurrentSiteHasABoostToEdit() {
        let (model, _) = makeBoostModel(urls: ["https://news.example.com/a"])
        var edited = [String]()
        model.onEditBoost = { edited.append($0) }
        #expect(model.currentBoostHost == "news.example.com")
        #expect(!model.currentSiteHasBoost)
        #expect(model.editCurrentSiteBoost())
        model.updateBoost(host: "example.com") { $0.css = "a {}" }
        #expect(model.currentBoostHost == "example.com", "The parent domain's Boost covers the page")
        #expect(model.currentSiteHasBoost && model.currentSiteHasActiveBoost)
        #expect(model.editCurrentSiteBoost())
        #expect(edited == ["news.example.com", "example.com"])
        #expect(model.boost(forHost: "example.com").css == "a {}")
        model.removeBoost(host: "example.com")
        #expect(!model.currentSiteHasBoost)
        #expect(model.librarySections.contains(.boosts))
        #expect(model.viewBoosts())
        #expect(model.librarySection == .boosts)
    }

    @Test func zappedElementsJoinTheBoostUntilThePageEndsZapping() throws {
        let (model, driver) = makeBoostModel(urls: ["https://example.com"])
        let tabID = try #require(model.selectedTabID)
        model.updateBoost(host: "example.com") { boost in
            boost.css = "a {}"
            boost.isEnabled = false
        }
        model.startZapping(host: "example.com")
        #expect(driver.evaluatedScripts.last?.code == BrowserBoostScript.zapStartScript)
        #expect(model.boostZapSession == nil, "A page that cannot zap ends it")

        let session = BrowserBoostZapSession(tabID: tabID, host: "example.com")
        model.boostZapSession = session
        model.handleZapPoll(##"{"picked":["#ad",".promo"],"done":false}"##, sessionID: session.id)
        #expect(model.boost(forHost: "example.com").zappedSelectors == ["#ad", ".promo"])
        #expect(model.boost(forHost: "example.com").isEnabled, "Zapping turns the Boost on")
        #expect(model.boostZapSession == session)

        model.handleZapPoll(nil, sessionID: session.id)
        #expect(model.boostZapSession?.missedPolls == 1)
        model.handleZapPoll(##"{"picked":["#ad"],"done":true}"##, sessionID: session.id)
        #expect(model.boostZapSession == nil)
        #expect(model.boost(forHost: "example.com").zappedSelectors == ["#ad", ".promo"])

        model.boostZapSession = BrowserBoostZapSession(tabID: tabID, host: "example.com")
        model.stopZapping()
        #expect(model.boostZapSession == nil)
        #expect(driver.evaluatedScripts.last?.code == BrowserBoostScript.zapStopScript)
    }
}

// MARK: - Model fixture

@MainActor private func makeBoostModel(urls: [String]) -> (BrowserChromeModel, FakeBrowserTabDriver) {
    let driver = FakeBrowserTabDriver()
    let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserBoostsModelTests"))!
    let model = BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
            tabs: urls.map { .init(urlString: $0) },
        )),
        sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
        commandBarSuggestionProvider: FakeSuggestionProvider(),
        userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
        shortcutStore: BrowserShortcutStore(userDefaults: defaults),
        extensionManager: FakeBrowserExtensionManager(),
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {},
    )
    model.handleContextReady()
    driver.flushPendingCreateEvents()
    for tab in model.tabs {
        driver.emitTabCreationState(id: tab.id, state: .ready)
    }
    return (model, driver)
}

// MARK: - BrowserBoostEditorTests

@MainActor struct BrowserBoostEditorTests {
    /// Snapshot runs show the app's English strings, which the test bundle lacks.
    init() {
        if ProcessInfo.processInfo.environment["OPENARC_BOOST_SNAPSHOTS"] != nil {
            BrowserBoostSnapshotStrings.install()
        }
    }

    private static func views(in view: NSView, identifier: String) -> [NSView] {
        (view.accessibilityIdentifier() == identifier ? [view] : [])
            + view.subviews.flatMap { views(in: $0, identifier: identifier) }
    }

    private static func view(in view: NSView, identifier: String) throws -> NSView {
        try #require(views(in: view, identifier: identifier).first, "\(identifier)")
    }

    private static func press(_ view: NSView) {
        (view as? BrowserNativePressableView)?.onClick(nil)
    }

    /// The view drawn offscreen on the panel's own ground, saved as a PNG when
    /// OPENARC_BOOST_SNAPSHOTS names a folder.
    private static func render(_ view: NSView, name: String, dark: Bool = false) throws -> NSBitmapImageRep {
        let ground = BrowserNativeSurface(frame: view.frame)
        ground.fillColor = BrowserBoostEditorColors.panel
        ground.strokeColor = BrowserBoostEditorColors.border
        ground.strokeWidth = 1
        ground.cornerRadius = BrowserBoostEditorLayout.panelCornerRadius
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = ground
        view.frame.origin = .zero
        ground.addSubview(view)
        ground.layoutSubtreeIfNeeded()
        let rep = try #require(ground.bitmapImageRepForCachingDisplay(in: ground.bounds))
        ground.cacheDisplay(in: ground.bounds, to: rep)
        view.removeFromSuperview()
        if let folder = ProcessInfo.processInfo.environment["OPENARC_BOOST_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return rep
    }

    @Test func theEditorStacksItsControlsInOneNarrowColumn() throws {
        let (model, _) = makeBoostModel(urls: ["https://example.com"])
        let editor = BrowserBoostEditorViewController(model: model, host: "example.com")
        let view = editor.view
        #expect(view.frame.width == 184)
        #expect(view.frame.height > 500 && view.frame.height < 700)
        let order = ["close", "colors", "invert", "fonts", "size", "zap", "code"]
        let frames = try order.map { try Self.view(in: view, identifier: "browser.boost-editor.\($0)").frame }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.minY <= $1.minY }, "Top to bottom: \(frames)")
        let wheel = frames[1]
        #expect(wheel.size == CGSize(width: 148, height: 148))
        #expect(wheel.minX == 18)
        let tools = try ["invert", "advanced", "reset-colors"].map {
            try Self.view(in: view, identifier: "browser.boost-editor.\($0)").frame
        }
        #expect(Set(tools.map(\.minY)).count == 1 && tools.allSatisfy { $0.height == 36 })
        let size = try Self.view(in: view, identifier: "browser.boost-editor.size").frame
        let textCase = try Self.view(in: view, identifier: "browser.boost-editor.case").frame
        #expect(size.minY == textCase.minY && size.width == textCase.width)
        #expect(Self.views(in: view, identifier: "browser.boost-editor.font.Georgia").count == 1)
        #expect(BrowserBoostFont.options.count == 20)
        #expect(model.userPreferencesStore.boosts.isEmpty, "Opening the editor saves nothing")

        let rep = try Self.render(view, name: "editor-new")
        let middle = try #require(rep.colorAt(x: Int(rep.pixelsWide / 2), y: Int(rep.pixelsHigh - 4))?
            .usingColorSpace(.sRGB))
        #expect(middle.alphaComponent > 0.99, "The panel's ground fills it")

        model.updateBoost(host: "example.com") { boost in
            boost.colors = BrowserBoostColors(tint: .init(hue: 310, saturation: 0.55, secondaryHueOffset: 25))
        }
        editor.refresh()
        _ = try Self.render(view, name: "editor-pink")
    }

    @Test func everyControlChangesTheBoostAndUndoTakesItBack() throws {
        let (model, _) = makeBoostModel(urls: ["https://example.com"])
        let editor = BrowserBoostEditorViewController(model: model, host: "example.com")
        let view = editor.view

        let wheel = try #require(Self.view(
            in: view,
            identifier: "browser.boost-editor.colors",
        ) as? BrowserBoostColorWheelView)
        let tint = wheel.tint(at: CGPoint(x: wheel.bounds.maxX - 30, y: wheel.bounds.midY), secondaryHueOffset: 30)
        #expect(abs(tint.hue) < 1 || abs(tint.hue - 360) < 1, "The right edge is hue 0")
        #expect(tint.saturation > 0.7)
        wheel.onBegin()
        wheel.onChange(tint)
        wheel.onEnd()
        #expect(model.boost(forHost: "example.com").colors?.tint == tint)

        try Self.press(Self.view(in: view, identifier: "browser.boost-editor.invert"))
        #expect(model.boost(forHost: "example.com").colors?.invertsLightness == true)
        try Self.press(Self.view(in: view, identifier: "browser.boost-editor.font.Georgia"))
        #expect(model.boost(forHost: "example.com").fontFamily == "Georgia")
        editor.refresh()
        try Self.press(Self.view(in: view, identifier: "browser.boost-editor.font.Georgia"))
        #expect(model.boost(forHost: "example.com").fontFamily == nil, "The picked font again goes back to the site's")

        let before = view.frame.height
        editor.toggleAdvancedColors()
        #expect(view.frame.height > before, "The sliders make the editor taller")
        _ = try Self.render(view, name: "editor-tinted")
        _ = try Self.render(view, name: "editor-tinted-dark", dark: true)

        #expect(editor.undoStack.count == 4)
        editor.undo()
        #expect(model.boost(forHost: "example.com").fontFamily == "Georgia")
        editor.undo()
        editor.undo()
        #expect(model.boost(forHost: "example.com").colors?.invertsLightness != true)
        editor.undo()
        #expect(model.userPreferencesStore.boosts.isEmpty, "Undoing the first change leaves no Boost")

        try Self.press(Self.view(in: view, identifier: "browser.boost-editor.reset-colors"))
        #expect(model.userPreferencesStore.boosts.isEmpty)
    }

    @Test func zappedElementsListUnderZapAndComeBack() {
        let (model, _) = makeBoostModel(urls: ["https://example.com"])
        model.updateBoost(host: "example.com") { $0.zappedSelectors = ["#ad", ".promo"] }
        let editor = BrowserBoostEditorViewController(model: model, host: "example.com")
        let view = editor.view
        let restore = Self.views(in: view, identifier: "browser.boost-editor.remove-hidden-element")
        #expect(restore.count == 2)
        Self.press(restore[0])
        #expect(model.boost(forHost: "example.com").zappedSelectors == [".promo"])
    }

    @Test func theCodePanelSavesCSSAndJavaScript() throws {
        let (model, _) = makeBoostModel(urls: ["https://example.com"])
        let code = BrowserBoostCodeViewController(model: model, host: "example.com")
        let view = code.view
        #expect(view.frame.size == BrowserBoostEditorLayout.codeSize)
        let css = try #require(Self.views(in: view, identifier: "browser.boost-editor.css").first as? NSTextView)
        let javaScript = try #require(
            Self.views(in: view, identifier: "browser.boost-editor.javascript").first as? NSTextView,
        )
        css.string = "a { color: red }"
        javaScript.string = "console.log(1)"
        code.commitPendingEdits()
        #expect(model.boost(forHost: "example.com").css == "a { color: red }")
        #expect(model.boost(forHost: "example.com").javaScript == "console.log(1)")
        _ = try Self.render(view, name: "code")
    }

    @Test func anotherSitesPageClosesTheEditor() {
        let (model, _) = makeBoostModel(urls: ["https://example.com", "https://other.org"])
        let editor = BrowserBoostEditorViewController(model: model, host: "example.com")
        var closed = 0
        editor.onClose = { closed += 1 }
        _ = editor.view
        #expect(closed == 0)
        #expect(model.currentPageKeepsBoostEditor(host: "example.com"))
        #expect(!model.currentPageKeepsBoostEditor(host: "other.org"))
        editor.refresh()
        #expect(closed == 0)
    }
}

// MARK: - BrowserBoostSnapshotStrings

/// Looks keys up in the app's English strings file, for snapshots made in the
/// test bundle, which has none.
private enum BrowserBoostSnapshotStrings {
    nonisolated(unsafe) static var table = [String: String]()
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        // Debug builds map source paths, so OPENARC_BOOST_STRINGS can name the file.
        let source = ProcessInfo.processInfo.environment["OPENARC_BOOST_STRINGS"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Browser/Resources/en.lproj/Localizable.strings")
        table = (NSDictionary(contentsOf: source) as? [String: String]) ?? [:]
        guard let original = class_getInstanceMethod(
            Bundle.self,
            #selector(Bundle.localizedString(forKey:value:table:)),
        ), let replacement = class_getInstanceMethod(
            Bundle.self,
            #selector(Bundle.openArcSnapshotLocalizedString(forKey:value:table:)),
        ) else { return }
        method_exchangeImplementations(original, replacement)
    }
}

private extension Bundle {
    @objc func openArcSnapshotLocalizedString(
        forKey key: String,
        value: String?,
        table: String?,
    ) -> String {
        BrowserBoostSnapshotStrings.table[key]
            ?? openArcSnapshotLocalizedString(forKey: key, value: value, table: table)
    }
}
