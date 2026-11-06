// BrowserSiteSearchTests.swift

import AppKit
import Foundation
import GRDB
import Testing

private let youTube = BrowserSiteSearch(
    name: "YouTube",
    keyword: "@y",
    urlTemplate: "https://www.youtube.com/results?search_query=%s",
    colorHex: "FF2600",
)
private let translate = BrowserSiteSearch(
    name: "Google Translate",
    keyword: "@t",
    urlTemplate: "https://translate.google.com/?q=%s",
)
private let gitHub = BrowserSiteSearch(
    name: "GitHub",
    keyword: "github.com",
    urlTemplate: "https://github.com/search?q=%s",
)
private let gitLab = BrowserSiteSearch(
    name: "GitLab",
    keyword: "gitlab.example.com",
    urlTemplate: "https://gitlab.example.com/search?search=%s",
)

@Test func siteSearchMatchesAKeywordOrTheShortestKeywordStartingWithTheText() {
    let searches = [gitLab, gitHub, youTube, translate]
    #expect(BrowserSiteSearch.match(for: "@y", in: searches) == youTube)
    #expect(BrowserSiteSearch.match(for: "@T", in: searches) == translate)
    #expect(BrowserSiteSearch.match(for: "git", in: searches) == gitHub)
    #expect(BrowserSiteSearch.match(for: "gitl", in: searches) == gitLab)
    // One character only matches a whole keyword; spaces never match.
    #expect(BrowserSiteSearch.match(for: "g", in: searches) == nil)
    #expect(BrowserSiteSearch.match(for: "@", in: searches) == nil)
    #expect(BrowserSiteSearch.match(for: "git hub", in: searches) == nil)
    #expect(BrowserSiteSearch.match(for: "you", in: searches) == nil)
    // A one-letter keyword matches exactly.
    let t = BrowserSiteSearch(name: "Translate", keyword: "t", urlTemplate: translate.urlTemplate)
    #expect(BrowserSiteSearch.match(for: "t", in: [t]) == t)
    // Unusable entries, such as a half-edited one, are skipped.
    let unfinished = BrowserSiteSearch(name: "", keyword: "gi", urlTemplate: "https://example.com/")
    #expect(BrowserSiteSearch.match(for: "gi", in: [unfinished, gitHub]) == gitHub)
}

@Test func siteSearchEncodesTheQueryLikeChromium() {
    #expect(youTube.searchURLString(for: "lofi beats") == "https://www.youtube.com/results?search_query=lofi+beats")
    #expect(youTube.searchURLString(for: "c++ & go?") ==
        "https://www.youtube.com/results?search_query=c%2B%2B+%26+go%3F")
    #expect(translate
        .searchURLString(for: "привет") == "https://translate.google.com/?q=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82")
    let spotify = BrowserSiteSearch(
        name: "Spotify",
        keyword: "spotify.com",
        urlTemplate: "https://open.spotify.com/search/%s",
    )
    #expect(spotify.searchURLString(for: "daft punk") == "https://open.spotify.com/search/daft%20punk")
    let gmail = BrowserSiteSearch(
        name: "Gmail",
        keyword: "mail.google.com",
        urlTemplate: "https://mail.google.com/mail/#apps/%s",
    )
    #expect(gmail.searchURLString(for: "a b") == "https://mail.google.com/mail/#apps/a%20b")
    #expect(BrowserSiteSearch(name: "", keyword: "x", urlTemplate: "https://example.com/")
        .searchURLString(for: "a") == nil)
    #expect(BrowserSiteSearch(name: "", keyword: "x", urlTemplate: "javascript:%s").searchURLString(for: "a") == nil)
    #expect(BrowserSiteSearch.arcDefaults.contains { !$0.isUsable } == false)
    #expect(Set(BrowserSiteSearch.arcDefaults.map(\.normalizedKeyword)).count == BrowserSiteSearch.arcDefaults.count)
}

@Test func siteSearchImportReadsOpenArcsOwnEntriesFromWebData() throws {
    let directory = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("BrowserSiteSearchTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let webData = directory.appendingPathComponent("Web Data")
    let queue = try DatabaseQueue(path: webData.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE keywords (
            id INTEGER PRIMARY KEY, short_name TEXT, keyword TEXT, url TEXT,
            prepopulate_id INTEGER DEFAULT 0, is_active INTEGER DEFAULT 1, starter_pack_id INTEGER DEFAULT 0
        );
        INSERT INTO keywords (short_name, keyword, url) VALUES
            ('YouTube', '@y', 'https://www.youtube.com/results?search_query={searchTerms}'),
            ('Google Translate', '@t', 'https://translate.google.com/?q={searchTerms}'),
            ('Google', 'g', '{google:baseURL}search?q={searchTerms}&{google:RLZ}ie={inputEncoding}'),
            ('Unknown', 'u', 'https://example.com/?q={searchTerms}&x={unknownParameter}'),
            ('No query', 'n', 'https://example.com/');
        INSERT INTO keywords (short_name, keyword, url, prepopulate_id) VALUES
            ('Bing', 'bing.com', 'https://www.bing.com/search?q={searchTerms}', 3);
        INSERT INTO keywords (short_name, keyword, url, is_active) VALUES
            ('Visited site', 'example.org', 'https://example.org/?s={searchTerms}', 0);
        INSERT INTO keywords (short_name, keyword, url, starter_pack_id) VALUES
            ('Tabs', '@tabs', 'chrome://tabs/?q={searchTerms}', 2);
        """)
    }
    try queue.close()

    let imported = try BrowserSiteSearchImport.load(webDataURL: webData)
    #expect(imported.map(\.keyword) == ["@y", "@t", "g"])
    #expect(imported[0].urlTemplate == "https://www.youtube.com/results?search_query=%s")
    // The chip color follows the site, whatever its keyword.
    #expect(imported[0].colorHex == "FF2600")
    #expect(imported[1].colorHex == nil)
    #expect(imported[2].urlTemplate == "https://www.google.com/search?q=%s&ie=UTF-8")
}

@Test func siteSearchImportReplacesTheSameSiteAndAddsNewOnes() {
    let merged = BrowserSiteSearchImport.merge([youTube, translate], into: BrowserSiteSearch.arcDefaults)
    #expect(merged.count == BrowserSiteSearch.arcDefaults.count + 1)
    let replaced = merged.first { $0.name == "YouTube" }
    #expect(replaced?.keyword == "@y")
    #expect(replaced?.id == BrowserSiteSearch.arcDefaults.first { $0.name == "YouTube" }?.id)
    #expect(merged.last?.keyword == "@t")
    // Importing again changes nothing.
    #expect(BrowserSiteSearchImport.merge([youTube, translate], into: merged) == merged)
    // Two searches of one site with different queries stay apart, and an
    // import never replaces another imported entry.
    let duckDuckGo = BrowserSiteSearch(name: "DuckDuckGo", keyword: "d", urlTemplate: "https://duckduckgo.com/?q=%s")
    let wikipediaBang = BrowserSiteSearch(
        name: "Wikipedia",
        keyword: "w",
        urlTemplate: "https://duckduckgo.com/?q=!w+%s",
    )
    #expect(BrowserSiteSearchImport.merge([duckDuckGo, wikipediaBang], into: []).map(\.keyword) == ["d", "w"])
    #expect(BrowserSiteSearchImport.merge([wikipediaBang], into: [duckDuckGo]).map(\.keyword) == ["d", "w"])
}

@Test func siteSearchesStartWithTheDefaultSetAndPersist() throws {
    let suite = BrowserTestDefaults.suiteName("BrowserSiteSearchTests")
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserUserPreferencesStore(userDefaults: defaults)
    #expect(preferences.siteSearches == BrowserSiteSearch.arcDefaults)
    preferences.siteSearches = [youTube]
    #expect(BrowserUserPreferencesStore(userDefaults: defaults).siteSearches == [youTube])
    preferences.siteSearches = []
    #expect(BrowserUserPreferencesStore(userDefaults: defaults).siteSearches.isEmpty)
}

@MainActor @Test func commandBarTabScopesTheQueryToTheSite() {
    var submitted = [String]()
    let model = BrowserCommandBarModel(
        suggestionProvider: FakeSuggestionProvider(),
        suggestionDebounceNanoseconds: 0,
        remoteSuggestionsEnabledProvider: { false },
        siteSearchesProvider: { [gitHub, youTube, translate] },
        submitHandler: { submitted.append($0) },
    )
    model.present()
    model.query = "lofi"
    #expect(model.siteSearchCandidate == nil)
    #expect(!model.beginSiteSearch())

    model.query = "@y"
    #expect(model.siteSearchCandidate == youTube)
    #expect(model.beginSiteSearch())
    #expect(model.activeSiteSearch == youTube)
    #expect(model.siteSearchCandidate == nil)
    #expect(model.query.isEmpty)
    #expect(model.suggestions.isEmpty)

    model.query = "lofi beats"
    #expect(model.suggestions.map(\.resolvedURLString) == [
        "https://www.youtube.com/results?search_query=lofi+beats",
    ])
    #expect(model.suggestions.first?.displayText == "lofi beats")
    model.submitSelection()
    #expect(submitted == ["https://www.youtube.com/results?search_query=lofi+beats"])
    #expect(!model.isPresented)
    #expect(model.activeSiteSearch == nil)
}

@MainActor @Test func aSiteChipWithNothingTypedListsTheSitesEarlierResults() {
    var asked = [(String?, Int)]()
    let earlier = BrowserCommandSuggestion(
        kind: .history,
        displayText: "Code search results",
        resolvedURLString: "https://github.com/search?q=repo%3Aa+x&type=code",
    )
    let model = BrowserCommandBarModel(
        suggestionProvider: FakeSuggestionProvider(),
        suggestionDebounceNanoseconds: 0,
        remoteSuggestionsEnabledProvider: { false },
        siteSearchesProvider: { [gitHub, youTube] },
        siteRecentPagesProvider: { site, count in
            asked.append((site.resultsURLPrefix, count))
            return site == gitHub ? [earlier] : []
        },
        submitHandler: { _ in },
    )
    model.present()
    model.query = "git"
    #expect(model.beginSiteSearch())
    #expect(model.suggestions.map(\.displayText) == ["Code search results"], "The site's earlier results")
    #expect(model.suggestions.first?.resolvedURLString == earlier.resolvedURLString)
    #expect(model.suggestions.first?.kind == .search, "Shown as a search, without its address")
    #expect(model.selectedSuggestionIndex == 0)
    #expect(asked.last?.0 == "https://github.com/search?q=")
    model.query = "x"
    #expect(model.suggestions.map(\.displayText) == ["x"], "Typing lists only the query")
    model.query = ""
    #expect(model.suggestions.map(\.resolvedURLString) == [earlier.resolvedURLString])
    #expect(BrowserSiteSearch(name: "Bad", keyword: "b", urlTemplate: "%s").resultsURLPrefix == nil)
}

@MainActor @Test func commandBarLeavesASiteSearchWithDeleteOrEscape() {
    var submitted = [String]()
    let model = BrowserCommandBarModel(
        suggestionProvider: FakeSuggestionProvider(),
        suggestionDebounceNanoseconds: 0,
        remoteSuggestionsEnabledProvider: { false },
        siteSearchesProvider: { [gitHub, translate] },
        submitHandler: { submitted.append($0) },
    )
    model.present()
    model.query = "git"
    #expect(model.beginSiteSearch())
    #expect(model.activeSiteSearch == gitHub)
    // Return in an empty scope does nothing.
    model.submitSelection()
    #expect(submitted.isEmpty)
    #expect(model.isPresented)
    // Delete restores what was typed.
    #expect(model.endSiteSearch(restoringQuery: true))
    #expect(model.activeSiteSearch == nil)
    #expect(model.query == "git")
    #expect(model.siteSearchCandidate == gitHub)
    // Escape clears both.
    #expect(model.beginSiteSearch())
    model.query = "swift"
    #expect(model.endSiteSearch(restoringQuery: false))
    #expect(model.query.isEmpty)
    #expect(model.isPresented)
    #expect(!model.endSiteSearch(restoringQuery: false))
    // Opening the bar again starts unscoped.
    model.query = "@t"
    #expect(model.beginSiteSearch())
    model.dismiss()
    model.present()
    #expect(model.activeSiteSearch == nil)
}

@MainActor @Test func nativeCommandBarShowsTheOfferAndTheChipAndHandlesTabDeleteEscape() async throws {
    let model = BrowserCommandBarModel(
        suggestionProvider: FakeSuggestionProvider(),
        suggestionDebounceNanoseconds: 0,
        remoteSuggestionsEnabledProvider: { false },
        siteSearchesProvider: { [youTube] },
        submitHandler: { _ in },
    )
    let view = BrowserCommandBarNSView(model: model, faviconCache: BrowserFaviconCache(dataLoader: { _ in nil }))
    view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    model.present(initialQuery: "pla")
    try await siteSearchWait { view.queryField.stringValue == "pla" }
    view.layoutSubtreeIfNeeded()
    let hint = try #require(siteSearchView("browser.command.site-search-hint", in: view) as? NSTextField)
    let chip = try #require(siteSearchView("browser.command.site-search", in: view))
    #expect(hint.isHidden)
    #expect(chip.isHidden)
    let editor = NSTextView()
    #expect(!view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))

    model.query = "@y"
    try await siteSearchWait { !hint.isHidden }
    view.layoutSubtreeIfNeeded()
    #expect(hint.stringValue == BrowserStrings.commandBarSiteSearchOffer("YouTube"))
    #expect(hint.frame.minX > view.queryField.frame.maxX)
    #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    // The field follows at once, before a quickly typed next key.
    #expect(!chip.isHidden)
    #expect(view.queryField.stringValue.isEmpty)
    view.layoutSubtreeIfNeeded()
    #expect(hint.isHidden)
    #expect(view.queryField.frame.minX > chip.frame.maxX)
    #expect(view.queryField.placeholderString == BrowserStrings.commandBarSiteSearchPlaceholder)

    // Delete with text deletes text; in an empty field it removes the chip.
    editor.string = "a"
    #expect(!view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    editor.string = ""
    #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
    #expect(model.activeSiteSearch == nil)
    #expect(model.query == "@y")
    #expect(chip.isHidden)
    #expect(view.queryField.stringValue == "@y")
    #expect(view.queryField.placeholderString == BrowserStrings.commandBarPlaceholder)

    // Tab and Delete leave text that an input method is composing alone.
    let composing = NSTextView()
    composing.setMarkedText(
        "か",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0),
    )
    #expect(composing.hasMarkedText())
    #expect(!view.control(view.queryField, textView: composing, doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(model.activeSiteSearch == nil)

    // Escape leaves the scope first, then closes the bar.
    #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(model.isPresented)
    #expect(model.activeSiteSearch == nil)
    #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!model.isPresented)
}

@MainActor private func siteSearchWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 where !predicate() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
}

@MainActor private func siteSearchView(_ identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    for subview in view.subviews {
        if let match = siteSearchView(identifier, in: subview) {
            return match
        }
    }
    return nil
}
