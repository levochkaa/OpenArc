// BrowserMobilePhoneTests.swift

import Foundation
import Testing
import UIKit

// MARK: - Search suggestions

@Test func mobileSearchSuggestionsListTabsForAnEmptyQuery() {
    let candidates = [
        BrowserMobileSearchSuggestions.Candidate(
            tabID: "a", title: "", urlString: "https://www.apple.com/", location: nil,
        ),
        .init(tabID: "b", title: "Docs", urlString: "https://docs.example.com/", location: "Pinned in Work"),
    ]
    let suggestions = BrowserMobileSearchSuggestions(query: "  ", candidates: candidates)
    #expect(suggestions.completion == nil)
    #expect(suggestions.items.map(\.kind) == [.tab("a"), .tab("b")])
    #expect(suggestions.items.map(\.title) == ["apple.com", "Docs"], "An untitled tab shows its host")
    #expect(suggestions.items[1].subtitle == nil, "The list of tabs shows titles only")
}

@Test func mobileSearchSuggestionsCompleteATypedHostFromOpenTabs() {
    let candidates = [
        BrowserMobileSearchSuggestions.Candidate(
            tabID: "a", title: "Apple", urlString: "https://www.apple.com/iphone", location: nil,
        ),
    ]
    let suggestions = BrowserMobileSearchSuggestions(query: "app", candidates: candidates)
    #expect(suggestions.completion == "apple.com")
    #expect(suggestions.items.map(\.kind) == [.address("apple.com"), .search("app"), .tab("a")])
    #expect(suggestions.items[0].title == "Apple")

    let exact = BrowserMobileSearchSuggestions(query: "apple.com", candidates: candidates)
    #expect(exact.completion == nil, "A host typed in full needs no completion")
    #expect(exact.items.first?.kind == .address("apple.com"))
}

@Test func mobileSearchSuggestionsTreatSpacedTextAsASearch() {
    let suggestions = BrowserMobileSearchSuggestions(query: "apple pie", candidates: [])
    #expect(suggestions.completion == nil)
    #expect(suggestions.items.map(\.kind) == [.search("apple pie")])
    let address = BrowserMobileSearchSuggestions(query: "example.org/path", candidates: [])
    #expect(address.items.map(\.kind) == [.address("example.org/path"), .search("example.org/path")])
    #expect(address.items[0].iconPage == "https://example.org/path")
}

@Test func mobileSearchSuggestionsListTheEnginesSearchesAfterAFewTabs() {
    let candidates = (1...5).map {
        BrowserMobileSearchSuggestions.Candidate(
            tabID: "t\($0)", title: "Weather \($0)", urlString: "https://w\($0).example/", location: nil,
        )
    }
    let suggestions = BrowserMobileSearchSuggestions(
        query: "weather", candidates: candidates, searches: ["Weather", "weather today", "weather tomorrow"],
    )
    #expect(suggestions.items.map(\.kind) == [
        .search("weather"), .tab("t1"), .tab("t2"), .tab("t3"),
        .search("weather today"), .search("weather tomorrow"),
    ], "The typed query is listed once, and the engine's searches follow three tabs")
}

@Test func mobileWebSuggestionsReadTheEnginesAnswer() {
    let data = Data(#"["wea",["weather","weather today"],[],{}]"#.utf8)
    #expect(BrowserMobileWebSuggestions.parse(data) == ["weather", "weather today"])
    #expect(BrowserMobileWebSuggestions.parse(Data("{}".utf8)).isEmpty)
    let url = BrowserMobileWebSuggestions.url(for: "a b&c+d")
    #expect(url?.host() == "suggestqueries.google.com")
    #expect(url?.query()?.contains("q=a%20b%26c%2Bd") == true)
}

@Test func mobileRemovedSuggestionsStayOutOnce() throws {
    let defaults = try #require(UserDefaults(suiteName: "mobileRemovedSuggestions-\(UUID().uuidString)"))
    #expect(BrowserMobileRemovedSuggestions.pages(in: defaults).isEmpty)
    BrowserMobileRemovedSuggestions.remove("https://example.com/", in: defaults)
    BrowserMobileRemovedSuggestions.remove("https://example.com/", in: defaults)
    BrowserMobileRemovedSuggestions.remove("https://apple.com/", in: defaults)
    #expect(BrowserMobileRemovedSuggestions.pages(in: defaults) == ["https://example.com/", "https://apple.com/"])
    #expect(defaults.stringArray(forKey: "BrowserMobileRemovedSuggestions")?.count == 2)
}

// MARK: - Bar backdrop

@MainActor @Test func mobileCompletingFieldReplacesOrKeepsTheFilledInPart() {
    let field = BrowserMobileCompletingField()
    field.showCompletion("hub.com", after: "git")
    #expect(field.text == "github.com")
    #expect(field.typedText == "git")
    #expect(field.completion == "hub.com")

    field.deleteBackward()
    #expect(field.text == "git", "Delete removes only the filled-in part")
    #expect(field.completion == nil)
    #expect(field.lastEditDeleted)

    field.showCompletion("hub.com", after: "git")
    field.keepCompletion()
    #expect(field.text == "github.com")
    #expect(field.typedText == "github.com")

    field.showCompletion("", after: "github.com")
    #expect(field.completion == nil)
}

@MainActor @Test func mobileCompletingFieldTypingOverTheCaretDropsTheFilledInPart() throws {
    let field = BrowserMobileCompletingField()
    field.showCompletion("hub.com", after: "git")
    let caret = try #require(field.position(from: field.beginningOfDocument, offset: 3))
    let range = try #require(field.textRange(from: caret, to: caret))
    field.replace(range, withText: "l")
    #expect(field.text == "gitl", "A keystroke sent as a replacement types after the typed part")
    #expect(field.completion == nil)
}

@Test func mobileAutoOpenKeyboardIsOnUntilTurnedOff() throws {
    let suite = "BrowserMobileAutoOpenKeyboardTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(BrowserMobileAutoOpenKeyboardSetting.isOn(defaults))
    BrowserMobileAutoOpenKeyboardSetting.set(false, defaults: defaults)
    #expect(!BrowserMobileAutoOpenKeyboardSetting.isOn(defaults))
    BrowserMobileAutoOpenKeyboardSetting.set(true, defaults: defaults)
    #expect(BrowserMobileAutoOpenKeyboardSetting.isOn(defaults))
}

@MainActor @Test func mobileLinkMenuTitleDropsTheSchemeAndWWW() throws {
    let url = try #require(URL(string: "https://www.example.com/a/b?c=1"))
    #expect(BrowserWebKitEngine.menuTitle(for: url) == "example.com/a/b?c=1")
    let plain = try #require(URL(string: "http://wwwexample.org/"))
    #expect(BrowserWebKitEngine.menuTitle(for: plain) == "wwwexample.org/")
    let mail = try #require(URL(string: "mailto:someone@example.com"))
    #expect(BrowserWebKitEngine.menuTitle(for: mail) == "mailto:someone@example.com")
}

@MainActor @Test func mobileTranslationReadsThePageLanguageFromItsText() {
    let german = BrowserMobilePageText(
        texts: [
            "Die Linden bilden eine Pflanzengattung in der Unterfamilie der Lindengewächse.",
            "",
            "Sie sind in den gemäßigten Gebieten der Nordhalbkugel weit verbreitet.",
        ],
        language: "en",
    )
    #expect(BrowserMobilePageTranslator.sourceLanguage(of: german)?.languageCode == "de")
    let numbers = BrowserMobilePageText(texts: ["42", "7"], language: "fr")
    #expect(BrowserMobilePageTranslator.sourceLanguage(of: numbers)?.languageCode == "fr")
    #expect(BrowserMobilePageTranslator.sourceLanguage(of: .init(texts: ["42"], language: " ")) == nil)
}

@Test func mobileSiteSettingsKeepTheBarPerSite() throws {
    let suite = "BrowserMobileSiteSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(BrowserMobileSiteSettings.collapsesBar(onPage: "https://example.com/a", defaults: defaults))
    BrowserMobileSiteSettings.setCollapsesBar(false, host: "example.com", defaults: defaults)
    #expect(!BrowserMobileSiteSettings.collapsesBar(onPage: "https://www.example.com/b", defaults: defaults))
    #expect(BrowserMobileSiteSettings.collapsesBar(onPage: "https://other.org/", defaults: defaults))
    #expect(BrowserMobileSiteSettings.collapsesBar(onPage: nil, defaults: defaults))
    BrowserMobileSiteSettings.setCollapsesBar(true, host: "example.com", defaults: defaults)
    #expect(BrowserMobileSiteSettings.collapsesBar(onPage: "https://example.com/", defaults: defaults))
}

@Test func mobileBackdropMeasuresLuminanceOfPicturesAndColors() throws {
    func image(white: CGFloat) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor(white: white, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try #require(rendered.cgImage)
    }
    let black = try #require(BrowserMobileBackdrop.luminance(of: image(white: 0)))
    let white = try #require(BrowserMobileBackdrop.luminance(of: image(white: 1)))
    #expect(black < 0.01)
    #expect(white > 0.99)
    #expect(BrowserMobileBackdrop.isDark(luminance: black))
    #expect(!BrowserMobileBackdrop.isDark(luminance: white))
    // Pages by background: gray 128 and pure red are light; gray 100, green
    // 128 and a saturated blue are dark.
    func isDark(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> Bool {
        let color = UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        return try BrowserMobileBackdrop.isDark(luminance: #require(BrowserMobileBackdrop.luminance(of: color)))
    }
    #expect(try !isDark(128, 128, 128))
    #expect(try !isDark(255, 0, 0))
    #expect(try isDark(100, 100, 100))
    #expect(try isDark(0, 128, 0))
    #expect(try isDark(53, 61, 237))
    #expect(BrowserMobileBackdrop.luminance(of: .clear) == nil)
}

// MARK: - Favicons

@Test func mobileFaviconsShareAHostWithAndWithoutWWW() {
    #expect(BrowserMobileFavicons.host(forPage: "https://www.Example.com/a") == "example.com")
    #expect(BrowserMobileFavicons.host(forPage: "http://example.com") == "example.com")
    #expect(BrowserMobileFavicons.host(forPage: "about:blank") == nil)
    #expect(BrowserMobileFavicons.host(forPage: "file:///tmp/a.html") == nil)
}

@Test func mobileFaviconsRankDrawnAndSizedIconsFirstAndFallBackToFaviconICO() {
    let rows = [
        ["https://example.com/icon.svg", "icon", "", "image/svg+xml"],
        ["https://example.com/touch.png", "apple-touch-icon", "180x180", ""],
        ["https://example.com/16.png", "icon", "16x16", "image/png"],
        ["https://example.com/32.png", "icon", "32x32", "image/png"],
        ["data:image/png;base64,AAAA", "icon", "", ""],
        ["javascript:alert(1)", "icon", "", ""],
    ]
    let urls = BrowserMobileFavicons.rankedIconURLs(rows, pageURL: URL(string: "https://example.com/page?q=1"))
    #expect(urls.map(\.absoluteString) == [
        "data:image/png;base64,AAAA",
        "https://example.com/32.png",
        "https://example.com/16.png",
        "https://example.com/touch.png",
        "https://example.com/icon.svg",
        "https://example.com/favicon.ico",
    ])
}

// MARK: - Page menu

@MainActor @Test func mobileTextSizeStepsStopAtTheEnds() {
    let steps = BrowserMobilePhoneViewController.zoomSteps
    #expect(BrowserMobilePhoneViewController.nextZoom(from: 1, larger: true) == 1.15)
    #expect(BrowserMobilePhoneViewController.nextZoom(from: 1, larger: false) == 0.85)
    #expect(BrowserMobilePhoneViewController.nextZoom(from: 1.1, larger: false) == 1, "Off-step sizes snap to a step")
    #expect(BrowserMobilePhoneViewController.nextZoom(from: steps[steps.count - 1], larger: true) == steps.last)
    #expect(BrowserMobilePhoneViewController.nextZoom(from: steps[0], larger: false) == steps.first)
}

// MARK: - Tab switcher

@MainActor @Test func mobileSwitcherCardsBunchOlderTabsLeftAndSpaceTheNewestOut() {
    let switcher = BrowserMobileTabSwitcherView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    let entries = (0..<4).map { BrowserMobileTabSwitcherView.Entry(id: "\($0)", title: "", urlString: "") }
    switcher.setEntries(entries, focus: 2)
    let width: CGFloat = 402
    let focused = switcher.cardFrame(index: 2, position: 2)
    #expect(abs(focused.minX - width * 0.211) < 0.5)
    #expect(abs(focused.width - width * BrowserMobileTabSwitcherView.cardWidthShare) < 0.5)
    #expect(abs(focused.height / focused.width - 874 / width) < 0.01, "Cards keep the screen's shape")

    let newest = switcher.cardFrame(index: 3, position: 2)
    let step = BrowserMobileTabSwitcherView.forwardStep + BrowserMobileTabSwitcherView.newestExtraStep
    #expect(abs(newest.minX - focused.minX - width * step) < 0.5)
    #expect(abs(switcher.cardFrame(index: 3, position: 1).minX - switcher.cardFrame(index: 2, position: 1).minX
            - width * step) < 0.5, "The newest card keeps its extra room once a step away")

    let older = switcher.cardFrame(index: 1, position: 2)
    let oldest = switcher.cardFrame(index: 0, position: 2)
    #expect(abs(focused.minX - older.minX - width * BrowserMobileTabSwitcherView.backwardStep) < 0.5)
    #expect(focused.minX - older.minX > older.minX - oldest.minX, "Older cards bunch up")
    #expect(oldest.minX < older.minX)
}

@Test func mobileFaviconsPlateOnlyIconsThatVanishOnDarkBackgrounds() throws {
    func icon(_ color: UIColor, background: UIColor?) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            if let background {
                background.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            color.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
        return try #require(rendered.cgImage)
    }
    #expect(try BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.black, background: nil)))
    #expect(try !BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.black, background: .white)))
    #expect(try !BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.systemRed, background: nil)))
    #expect(try !BrowserMobileFavicons.isTooDarkForDarkBackground(icon(.white, background: nil)))
}

@Test func mobileFaviconsRejectBlankIcons() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format)
    let blank = try #require(renderer.image { _ in }.cgImage)
    let mark = try #require(renderer.image { context in
        UIColor.black.setFill()
        context.fill(CGRect(x: 6, y: 6, width: 4, height: 4))
    }
    .cgImage)
    #expect(BrowserMobileFavicons.isBlank(blank))
    #expect(!BrowserMobileFavicons.isBlank(mark))
}

// MARK: - Bar and panels

@MainActor @Test func mobileBarSwapsItsSideControlsOverTheSwitcher() {
    let bar = BrowserMobilePhoneBarView(frame: CGRect(x: 0, y: 0, width: 402, height: 86))
    bar.layoutIfNeeded()
    #expect(bar.spacesButton.alpha == 0 && !bar.spacesButton.isUserInteractionEnabled)
    #expect(bar.background.effect != nil)
    bar.setShowsSwitcherControls(true)
    #expect(bar.tabStack.alpha == 0 && !bar.tabStack.isUserInteractionEnabled)
    #expect(bar.moreButton.alpha == 0 && bar.settingsButton.alpha == 1 && bar.spacesButton.alpha == 1)
    #expect(bar.plusButton.alpha == 1, "New Tab stays in place")
    #expect(bar.background.effect == nil, "The switcher shows through the bar")
    #expect(bar.settingsButton.frame == bar.moreButton.frame)
    #expect(abs(bar.spacesButton.center.y - bar.plusButton.center.y) < 0.5)
    bar.setShowsSwitcherControls(false)
    #expect(bar.tabStack.alpha == 1 && bar.moreButton.alpha == 1 && bar.settingsButton.alpha == 0)
    #expect(bar.background.effect != nil)
}

@MainActor @Test func mobileSearchPanelMovesOnlyWhenTheSuggestionsAreAtTheTop() {
    let panel = BrowserMobileSearchPanel(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
    panel.prepare(text: "")
    panel.setFieldExpanded(false)
    #expect(!panel.isFieldExpanded)
    #expect(!panel.field.isFirstResponder, "Preparing does not bring up the keyboard")
    panel.setFieldExpanded(true)
    #expect(panel.isFieldExpanded)
    #expect(panel.dragMovesPanel(at: CGPoint(x: 200, y: 20), downward: false), "The field area always moves it")
    #expect(panel.dragMovesPanel(at: CGPoint(x: 200, y: 200), downward: true))
    #expect(!panel.dragMovesPanel(at: CGPoint(x: 200, y: 200), downward: false), "Up over suggestions scrolls")
}

@MainActor @Test func mobileSearchFieldHandlesKeystrokesThatLandBeforeTheFilledInPart() {
    let panel = BrowserMobileSearchPanel(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
    // Incognito asks the web for nothing.
    panel.isIncognito = true
    panel.candidates = [.init(tabID: "a", title: "Google", urlString: "https://google.com/", location: nil)]
    let field = panel.field
    field.text = "google.co"
    field.sendActions(for: .editingChanged)
    #expect(field.text == "google.com")
    #expect(field.completion == "m")

    // The last letter arrives in place, before the highlighted one.
    field.text = "google.comm"
    field.sendActions(for: .editingChanged)
    #expect(field.text == "google.com", "The typed host is whole, with nothing left filled in")
    #expect(field.completion == nil)

    panel.prepare(text: "")
    field.text = "g"
    field.sendActions(for: .editingChanged)
    #expect(field.text == "google.com")
    // Delete arrives in place too, taking the typed letter.
    field.text = "oogle.com"
    field.sendActions(for: .editingChanged)
    #expect(field.text == "g", "Delete takes away the filled-in part")
    #expect(field.completion == nil)
    #expect(field.lastEditDeleted)
}

// MARK: - Settings

@Test func mobileSearchEngineSettingDefaultsToGoogleAndKeepsTheChoice() throws {
    let suite = "BrowserMobileSearchEngineTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(BrowserMobileSearchEngineSetting.current(defaults) == .google)
    BrowserMobileSearchEngineSetting.set(.duckDuckGo, defaults: defaults)
    #expect(BrowserMobileSearchEngineSetting.current(defaults) == .duckDuckGo)
    let resolver = BrowserNavigationResolver { BrowserMobileSearchEngineSetting.current(defaults) }
    #expect(resolver.resolve("open arc")?.resolvedURLString.hasPrefix("https://duckduckgo.com/") == true)
}

// MARK: - Content blocking

@MainActor @Test func mobileContentBlockingKeepsPerSiteListsUnderTheSharedKey() throws {
    let name = "BrowserMobileContentBlockingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let page = "https://www.news.example/story"
    #expect(BrowserMobileContentBlocking.blocks(.ads, onPage: page, defaults: defaults))

    BrowserMobileContentBlocking.setBlocks(.ads, false, onPage: page, defaults: defaults, applies: false)
    #expect(!BrowserMobileContentBlocking.blocks(.ads, onPage: "https://news.example/", defaults: defaults))
    #expect(BrowserMobileContentBlocking.blocks(.trackers, onPage: page, defaults: defaults))
    #expect(BrowserMobileContentBlocking.blocks(.ads, onPage: "https://other.example/", defaults: defaults))
    #expect(defaults.data(forKey: "browser.settings.contentBlocking") != nil)

    BrowserMobileContentBlocking.update(defaults, applies: false) { $0.blocksTrackers = false }
    #expect(!BrowserMobileContentBlocking.blocks(.trackers, onPage: "https://other.example/", defaults: defaults))
}

// MARK: - Load error

@MainActor @Test func mobileLoadErrorCentersItsFaceAndWordsAboveTheBar() throws {
    let view = BrowserMobileLoadErrorView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    view.contentInsets = UIEdgeInsets(top: 62, left: 0, bottom: 76, right: 0)
    view.setMessage("A server with the specified hostname could not be found.")
    view.layoutIfNeeded()
    let labels = view.subviews.compactMap { $0 as? UILabel }
    let face = try #require(view.subviews.first)
    let message = try #require(labels.last)
    let reload = try #require(view.subviews.first { $0.accessibilityIdentifier == "browser.loadError.reload" })
    #expect(abs(face.frame.midX - 201) < 1)
    let middle = (face.frame.minY + message.frame.maxY) / 2
    #expect(abs(middle - (62 + 874 - 76) / 2) < 1, "The face and the words center between the status bar and the bar")
    #expect(reload.frame.minY > message.frame.maxY, "The reload button hangs below the words")

    view.setMessage(nil)
    #expect(message.isHidden)
}

@MainActor @Test func mobileLoadErrorReloadButtonCallsBack() throws {
    let view = BrowserMobileLoadErrorView()
    var reloads = 0
    view.onReload = { reloads += 1 }
    let reload = try #require(view.subviews
        .first { $0.accessibilityIdentifier == "browser.loadError.reload" } as? UIButton)
    reload.sendActions(for: .touchUpInside)
    #expect(reloads == 1)
}

@MainActor @Test func mobileLoadErrorCentersOnTheScreenBesideACameraColumn() throws {
    let view = BrowserMobileLoadErrorView(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
    view.contentInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 84)
    view.setMessage("A server with the specified hostname could not be found.")
    view.layoutIfNeeded()
    let face = try #require(view.subviews.first)
    let message = try #require(view.subviews.compactMap { $0 as? UILabel }.last)
    #expect(abs(face.frame.midX - 233) < 1, "The face centers on the screen, not beside the camera")
    #expect(message.frame.maxX <= 466 - 84 - 16, "The words stay clear of the camera column")
}
