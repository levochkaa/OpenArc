import Foundation
import Testing

private let defaultAISuggestionTitle = BrowserStrings.commandBarAskAI(BrowserAISearchProvider.chatGPT.title)

@Test func resolvePreservesFullURLInput() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("https://openai.com/research?q=browser")

    #expect(
        resolution == BrowserNavigationResolver.Resolution(
            kind: .url,
            displayText: "https://openai.com/research?q=browser",
            resolvedURLString: "https://openai.com/research?q=browser"
        )
    )
}

@Test func resolveTreatsBareDomainAsURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("openai.com/research")

    #expect(resolution?.kind == .url)
    #expect(resolution?.displayText == "openai.com/research")
    #expect(resolution?.resolvedURLString == "https://openai.com/research")
}

@Test func resolveTreatsPublicSuffixListDomainAsURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("docs.google.co.uk")

    #expect(resolution?.kind == .url)
    #expect(resolution?.resolvedURLString == "https://docs.google.co.uk")
}

@Test func resolveTreatsLocalhostAsURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("localhost:3000")

    #expect(resolution?.kind == .url)
    #expect(resolution?.resolvedURLString == "https://localhost:3000")
}

@Test func resolveTreatsLocalhostAsURLWithoutDomainParser() {
    let resolver = BrowserNavigationResolver(domainParser: RejectingDomainParser())
    let resolution = resolver.resolve("localhost:3000")

    #expect(resolution?.kind == .url)
    #expect(resolution?.resolvedURLString == "https://localhost:3000")
}

@Test func resolveTreatsBareDomainWithPortAsURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("openai.com:443/research")

    #expect(resolution?.kind == .url)
    #expect(resolution?.resolvedURLString == "https://openai.com:443/research")
}

@Test func resolvePreservesTheBrowserInternalURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("tb://settings")

    #expect(
        resolution == BrowserNavigationResolver.Resolution(
            kind: .url,
            displayText: "tb://settings",
            resolvedURLString: "tb://settings/"
        )
    )
}

@Test func resolvePreservesTheBrowserExtensionsURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("tb://extensions/?id=abc")

    #expect(
        resolution == BrowserNavigationResolver.Resolution(
            kind: .url,
            displayText: "tb://extensions/?id=abc",
            resolvedURLString: "tb://extensions/?id=abc"
        )
    )
}

@Test func resolveNormalizesChromiumInternalURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("chrome://settings")

    #expect(
        resolution == BrowserNavigationResolver.Resolution(
            kind: .url,
            displayText: "chrome://settings",
            resolvedURLString: "tb://settings/"
        )
    )
}

@Test func resolveNormalizesInternalBrowserAliases() {
    let resolver = BrowserNavigationResolver()

    #expect(resolver.resolve("arc://bookmarks")?.resolvedURLString == "tb://bookmarks/")
    #expect(resolver.resolve("dia://password-manager/passwords")?
        .resolvedURLString == "tb://password-manager/passwords")
    #expect(resolver.resolve("about:bookmarks")?.resolvedURLString == "tb://bookmarks/")
}

@Test func internalURLNormalizerMapsBookmarksAndPasswordManagerToChromiumURLs() {
    #expect(
        BrowserInternalURLNormalizer
            .chromiumURLString(forCanonicalURLString: "tb://bookmarks/") == "chrome://bookmarks/"
    )
    #expect(
        BrowserInternalURLNormalizer
            .chromiumURLString(forCanonicalURLString: "tb://password-manager/passwords")
            == "chrome://password-manager/passwords"
    )
}

@Test func resolveRejectsTrailingDotHost() throws {
    let resolver = BrowserNavigationResolver()
    let resolution = try #require(resolver.resolve("Google."))

    #expect(resolution.kind == .search)
    #expect(queryValue(from: resolution.resolvedURLString, name: "q") == "Google.")
}

@Test func resolveRejectsSingleCharacterTopLevelDomain() throws {
    let resolver = BrowserNavigationResolver()
    let resolution = try #require(resolver.resolve("Google.c"))

    #expect(resolution.kind == .search)
    #expect(queryValue(from: resolution.resolvedURLString, name: "q") == "Google.c")
}

@Test func resolveAcceptsTwoCharacterTopLevelDomain() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("Google.co")

    #expect(resolution?.kind == .url)
    #expect(resolution?.resolvedURLString == "https://Google.co")
}

@Test func resolveRejectsExplicitHTTPURLWithSingleCharacterTopLevelDomain() throws {
    let resolver = BrowserNavigationResolver()
    let resolution = try #require(resolver.resolve("https://Google.c"))

    #expect(resolution.kind == .search)
    #expect(queryValue(from: resolution.resolvedURLString, name: "q") == "https://Google.c")
}

@Test func resolveTreatsIPv4AddressAsURL() {
    let resolver = BrowserNavigationResolver()
    let resolution = resolver.resolve("127.0.0.1:9222")

    #expect(resolution?.kind == .url)
    #expect(resolution?.resolvedURLString == "https://127.0.0.1:9222")
}

@Test func resolveTurnsPlainTextIntoGoogleSearch() throws {
    let resolver = BrowserNavigationResolver()
    let resolution = try #require(resolver.resolve("command bar"))

    #expect(resolution.kind == .search)
    #expect(resolution.displayText == "command bar")
    #expect(queryValue(from: resolution.resolvedURLString, name: "q") == "command bar")
}

@Test func resolveUsesSelectedSearchEngineForPlainTextSearch() throws {
    let resolver = BrowserNavigationResolver(searchEngineProvider: { .duckDuckGo })
    let resolution = try #require(resolver.resolve("command bar"))

    #expect(resolution.kind == .search)
    #expect(URLComponents(string: resolution.resolvedURLString)?.host == "duckduckgo.com")
    #expect(queryValue(from: resolution.resolvedURLString, name: "q") == "command bar")
}

@Test func resolveReturnsNilForEmptyInput() {
    let resolver = BrowserNavigationResolver()

    #expect(resolver.resolve("   \n") == nil)
}

@Test
@MainActor func presentCanSeedInitialQuery() async {
    let model = makeModel(suggestionProvider: FakeSuggestionProvider())

    model.present(initialQuery: "https://openai.com")
    await model.waitForPendingSuggestionLoad()

    #expect(model.isPresented)
    #expect(model.query == "https://openai.com")
    #expect(model.selectedSuggestion?.resolvedURLString == "https://openai.com")
}

@Test
@MainActor func primarySuggestionIsSelectedByDefault() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["привет": ["привет макет", "привет мир"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "привет"
    await model.waitForPendingSuggestionLoad()

    #expect(model.isPresented)
    #expect(model.suggestions.map(\.displayText) == ["привет", defaultAISuggestionTitle, "привет макет", "привет мир"])
    #expect(model.selectedSuggestion?.displayText == "привет")
}

@Test
@MainActor func disabledRemoteSuggestionsKeepPrimaryAndAIOnly() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["browser": ["browser settings"]]
    )
    let model = makeModel(
        suggestionProvider: suggestionProvider,
        remoteSuggestionsEnabledProvider: { false }
    )

    model.present()
    model.query = "browser"
    await model.waitForPendingSuggestionLoad()

    #expect(suggestionProvider.requestedQueries.isEmpty)
    #expect(model.suggestions.map(\.displayText) == ["browser", defaultAISuggestionTitle])
}

@Test
@MainActor func remoteURLSuggestionUsesURLPresentationKind() async throws {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["https://google.com/": ["https://google.com/business"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "https://google.com/"
    await model.waitForPendingSuggestionLoad()

    #expect(model.suggestions.map(\.displayText) == [
        "https://google.com/",
        defaultAISuggestionTitle,
        "https://google.com/business",
    ])

    let urlSuggestion = try #require(model.suggestions.last)
    #expect(urlSuggestion.kind == .url)
    #expect(urlSuggestion.systemImageName == "globe")
    #expect(urlSuggestion.resolvedURLString == "https://google.com/business")
}

@Test
@MainActor func localSuggestionsAreShownBeforeRemoteSuggestions() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["docs": ["docs remote"]]
    )
    let localSuggestions = [
        BrowserCommandSuggestion(
            kind: .openTab,
            displayText: "Docs Tab",
            detailText: "docs.example",
            resolvedURLString: "https://docs.example",
            tabID: "tab-1"
        ),
        BrowserCommandSuggestion(
            kind: .bookmark,
            displayText: "Docs Bookmark",
            detailText: "bookmarks.example",
            resolvedURLString: "https://bookmarks.example"
        ),
    ]
    let model = makeModel(
        suggestionProvider: suggestionProvider,
        localSuggestionProvider: { query, maximumCount in
            query == "docs" ? Array(localSuggestions.prefix(maximumCount)) : []
        }
    )

    model.present()
    model.query = "docs"
    await model.waitForPendingSuggestionLoad()

    #expect(model.suggestions.map(\.displayText) == [
        "docs",
        defaultAISuggestionTitle,
        "Docs Tab",
        "Docs Bookmark",
        "docs remote",
    ])
    #expect(model.suggestions.map(\.kind) == [.search, .aiSearch, .openTab, .bookmark, .googleSuggestion])
}

@Test
@MainActor func aiSuggestionSubmitsSelectedProviderQueryURL() async throws {
    var submittedURLStrings = [String]()
    let model = makeModel(
        suggestionProvider: FakeSuggestionProvider(),
        aiSearchProviderProvider: { .deepSeek },
        submitHandler: { submittedURLStrings.append($0) }
    )

    model.present()
    model.query = "explain swift 6"
    await model.waitForPendingSuggestionLoad()

    model.moveSelection(by: 1)
    #expect(model.selectedSuggestion?.kind == .aiSearch)
    #expect(model.selectedSuggestion?.displayText == BrowserStrings
        .commandBarAskAI(BrowserAISearchProvider.deepSeek.title))

    model.submitSelection()

    let submittedURLString = try #require(submittedURLStrings.first)
    #expect(URLComponents(string: submittedURLString)?.host == "chat.deepseek.com")
    #expect(queryValue(from: submittedURLString, name: "q") == "explain swift 6")
    #expect(!model.isPresented)
}

@Test
@MainActor func aiSuggestionDoesNotReplaceTypedQueryDuringCompletion() async {
    let model = makeModel(suggestionProvider: FakeSuggestionProvider())

    model.present()
    model.query = "browser settings"
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 1)

    #expect(model.selectedSuggestion?.kind == .aiSearch)
    #expect(model.previewDisplayText == nil)
    #expect(!model.acceptSelectedSuggestion())
    #expect(model.query == "browser settings")
}

@Test
@MainActor func openTabSuggestionSwitchesTabInsteadOfSubmittingURL() async {
    var switchedTabIDs = [String]()
    var submittedURLStrings = [String]()
    let model = makeModel(
        suggestionProvider: FakeSuggestionProvider(),
        localSuggestionProvider: { _, _ in
            [
                BrowserCommandSuggestion(
                    kind: .openTab,
                    displayText: "Open Tab",
                    resolvedURLString: "https://open.example",
                    tabID: "tab-1"
                ),
            ]
        },
        submitHandler: { submittedURLStrings.append($0) },
        switchToTabHandler: { switchedTabIDs.append($0) }
    )

    model.present()
    model.query = "open"
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 2)
    model.submitSelection()

    #expect(switchedTabIDs == ["tab-1"])
    #expect(submittedURLStrings.isEmpty)
    #expect(!model.isPresented)
}

@Test
@MainActor func arrowNavigationUpdatesSelectedSuggestionAndInlineSuffix() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["привет": ["привет макет", "привет мир"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "привет"
    await model.waitForPendingSuggestionLoad()

    model.moveSelection(by: 2)

    #expect(model.selectedSuggestion?.displayText == "привет макет")
    #expect(model.inlineCompletionSuffix == " макет")
}

@Test
@MainActor func acceptSelectedSuggestionPromotesInlineCompletionIntoQuery() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["привет": ["привет макет"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "привет"
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 2)

    #expect(model.acceptSelectedSuggestion())
    #expect(model.query == "привет макет")
}

@Test
@MainActor func trailingSpaceDoesNotTriggerPrimarySuggestionPreview() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["hello": ["hello world"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "hello "
    await model.waitForPendingSuggestionLoad()

    #expect(model.selectedSuggestion?.displayText == "hello")
    #expect(model.previewDisplayText == nil)
    #expect(model.inlineCompletionSuffix == nil)
}

@Test
@MainActor func inlineCompletionPreservesTypedTrailingSpace() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["hello": ["hello world"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "hello "
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 2)

    #expect(model.inlineCompletionSuffix == "world")
    #expect(model.acceptSelectedSuggestion())
    #expect(model.query == "hello world")
}

@Test
@MainActor func nonPrefixSuggestionUsesFullPreviewText() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: [
            "test english com listening b2": ["https test english com listening b2 inside google's office"],
        ]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "test english com listening b2"
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 2)

    #expect(model.selectedSuggestion?.displayText == "https test english com listening b2 inside google's office")
    #expect(model.inlineCompletionSuffix == nil)
    #expect(model.previewDisplayText == "https test english com listening b2 inside google's office")
}

@Test
@MainActor func acceptSelectedSuggestionReplacesQueryForNonPrefixSuggestion() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: [
            "test english com listening b2": ["https test english com listening b2 inside google's office"],
        ]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "test english com listening b2"
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 2)

    #expect(model.acceptSelectedSuggestion())
    #expect(model.query == "https test english com listening b2 inside google's office")
}

@Test
@MainActor func submitUsesPrimarySuggestionByDefault() async {
    var submittedURLStrings = [String]()
    let model = makeModel(
        suggestionProvider: FakeSuggestionProvider(),
        submitHandler: { submittedURLStrings.append($0) }
    )

    model.present()
    model.query = "openai.com"
    await model.waitForPendingSuggestionLoad()
    model.submitSelection()

    #expect(submittedURLStrings == ["https://openai.com"])
    #expect(!model.isPresented)
}

@Test
@MainActor func submitUsesCurrentlySelectedSuggestion() async {
    var submittedURLStrings = [String]()
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["привет": ["привет макет"]]
    )
    let model = makeModel(
        suggestionProvider: suggestionProvider,
        submitHandler: { submittedURLStrings.append($0) }
    )

    model.present()
    model.query = "привет"
    await model.waitForPendingSuggestionLoad()
    model.moveSelection(by: 2)
    model.submitSelection()

    #expect(queryValue(from: submittedURLStrings.first, name: "q") == "привет макет")
    #expect(!model.isPresented)
}

@Test
@MainActor func dismissClearsTransientState() async {
    let suggestionProvider = FakeSuggestionProvider(
        suggestionsByQuery: ["browser": ["browser command bar"]]
    )
    let model = makeModel(suggestionProvider: suggestionProvider)

    model.present()
    model.query = "browser"
    await model.waitForPendingSuggestionLoad()

    model.dismiss()

    #expect(!model.isPresented)
    #expect(model.query.isEmpty)
    #expect(model.suggestions.isEmpty)
    #expect(model.selectedSuggestion == nil)
}

@MainActor private func makeModel(
    suggestionProvider: BrowserSuggestionProviding,
    localSuggestionProvider: @escaping (String, Int) -> [BrowserCommandSuggestion] = { _, _ in [] },
    remoteSuggestionsEnabledProvider: @escaping () -> Bool = { true },
    aiSearchProviderProvider: @escaping () -> BrowserAISearchProvider = { .chatGPT },
    submitHandler: @escaping (String) -> Void = { _ in },
    switchToTabHandler: @escaping (String) -> Void = { _ in }
) -> BrowserCommandBarModel {
    BrowserCommandBarModel(
        suggestionProvider: suggestionProvider,
        suggestionDebounceNanoseconds: 0,
        localSuggestionProvider: localSuggestionProvider,
        remoteSuggestionsEnabledProvider: remoteSuggestionsEnabledProvider,
        aiSearchProviderProvider: aiSearchProviderProvider,
        submitHandler: submitHandler,
        switchToTabHandler: switchToTabHandler
    )
}

private func queryValue(from urlString: String?, name: String) -> String? {
    guard let urlString else {
        return nil
    }

    return URLComponents(string: urlString)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

// MARK: - RejectingDomainParser

private struct RejectingDomainParser: BrowserDomainParsing {
    func parse(host _: String) -> BrowserParsedHost? {
        nil
    }
}
