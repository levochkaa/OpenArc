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

    @Test func updatingABoostCreatesItKeepsZapsUniqueAndRemovesItWhenEmpty() {
        var boosts = [BrowserBoost]()
        boosts.updateBoost(host: "Example.com") { $0.isEnabled = false }
        #expect(boosts.isEmpty, "A Boost that adds nothing is not saved")

        boosts.updateBoost(host: "www.example.com") { $0.zappedSelectors = ["#ad", "#ad", " ", ".banner"] }
        #expect(boosts == [BrowserBoost(host: "example.com", zappedSelectors: ["#ad", ".banner"])])

        boosts.updateBoost(host: "example.com") { $0.css = "a {}" }
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
        #expect(decoded == [BrowserBoost(host: "example.com", css: "a {}")], "Missing fields take their defaults")
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
    private static func views(in view: NSView, identifier: String) -> [NSView] {
        (view.accessibilityIdentifier() == identifier ? [view] : [])
            + view.subviews.flatMap { views(in: $0, identifier: identifier) }
    }

    private static func textView(in view: NSView, identifier: String) -> NSTextView? {
        views(in: view, identifier: identifier).first as? NSTextView
    }

    @Test func theEditorSavesCSSAndJavaScriptAndListsHiddenElements() throws {
        let (model, _) = makeBoostModel(urls: ["https://example.com"])
        model.updateBoost(host: "example.com") { $0.zappedSelectors = ["#ad", ".promo"] }
        let editor = BrowserBoostEditorViewController(model: model, host: "example.com")
        let view = editor.view
        #expect(view.frame.width == BrowserBoostEditorViewController.width)
        #expect(view.frame.height > 300 && view.frame.height < 760)
        view.layoutSubtreeIfNeeded()
        #expect(!view.hasAmbiguousLayout)

        let css = try #require(Self.textView(in: view, identifier: "browser.boost-editor.css"))
        let javaScript = try #require(Self.textView(in: view, identifier: "browser.boost-editor.javascript"))
        css.string = "a { color: red }"
        javaScript.string = "console.log(1)"
        editor.commitPendingEdits()
        #expect(model.boost(forHost: "example.com").css == "a { color: red }")
        #expect(model.boost(forHost: "example.com").javaScript == "console.log(1)")
        #expect(Self.views(in: view, identifier: "browser.boost-editor.remove-hidden-element").count == 2)
    }
}
