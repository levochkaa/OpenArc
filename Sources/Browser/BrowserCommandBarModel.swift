// BrowserCommandBarModel.swift

import Combine
import Foundation

// MARK: - BrowserCommandSuggestion

struct BrowserCommandSuggestion: Identifiable, Equatable {
    // MARK: Internal

    enum Kind: String, Equatable {
        case bookmark
        case history
        case openTab
        case url
        case search
        case googleSuggestion
        case aiSearch
        case command
        case note
    }

    let kind: Kind
    let displayText: String
    var detailText: String?
    let resolvedURLString: String
    let commandID: BrowserCommandID?
    let shortcut: BrowserKeyboardShortcut?
    var tabIDs: [String]
    /// The Space of a tab in another Space, named in place of "Switch to Tab".
    var spaceTitle: String?
    /// An open tab's icon, from the address its page last reported.
    var faviconURL: URL?
    /// The page's address as the field completes the typed text to it, such
    /// as "example.com/a" for "exam".
    var completionText: String?
    /// The page's icon from the browser's own records.
    var iconData: Data?
    /// An entry that does something, such as opening a new document or a
    /// settings page: listed with the commands, after pages and searches,
    /// and, like a command, it leaves the typed text in the field.
    var isAction = false

    var tabID: String? {
        tabIDs.first
    }

    var id: String {
        "\(kind.rawValue)|\(commandID?.rawValue ?? "")|\(displayText)|\(resolvedURLString)|\(tabIDs.joined(separator: ","))"
    }

    var systemImageName: String {
        switch kind {
        case .bookmark:
            "star"
        case .history:
            "clock"
        case .openTab:
            "globe"
        case .url:
            "globe"
        case .googleSuggestion,
             .search:
            "magnifyingglass"
        case .aiSearch:
            "sparkles"
        case .command:
            commandID?.commandBarSystemImageName ?? "command"
        case .note:
            BrowserNoteURL.symbolName
        }
    }

    /// A page is shown in the field by its address, a search by its text.
    /// Commands and actions leave the typed text, so they have none.
    var fieldText: String? {
        if let completionText {
            return completionText
        }
        switch kind {
        case .aiSearch,
             .command:
            return nil
        case .bookmark,
             .history,
             .openTab:
            return Self.address(for: resolvedURLString) ?? displayText
        case .googleSuggestion,
             .search,
             .url:
            return isAction ? nil : displayText
        case .note:
            return displayText
        }
    }

    init(
        kind: Kind,
        displayText: String,
        detailText: String? = nil,
        resolvedURLString: String = "",
        commandID: BrowserCommandID? = nil,
        shortcut: BrowserKeyboardShortcut? = nil,
        tabID: String? = nil,
        tabIDs: [String] = [],
    ) {
        self.kind = kind
        self.displayText = displayText
        self.detailText = detailText
        self.resolvedURLString = resolvedURLString
        self.commandID = commandID
        self.shortcut = shortcut
        self.tabIDs =
            if !tabIDs.isEmpty {
                Self.normalizedTabIDs(tabIDs)
            } else if let tabID {
                Self.normalizedTabIDs([tabID])
            } else {
                []
            }
    }

    /// The address as the field and the rows show it: no scheme, "www." or
    /// trailing slash, such as "github.com/openarc/pulls". Nil for addresses
    /// other than web pages.
    static func address(for urlString: String) -> String? {
        guard var components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = components.host, !host.isEmpty
        else { return nil }
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        components.scheme = nil
        components.host = host
        var address = components.string ?? host
        if address.hasPrefix("//") {
            address.removeFirst(2)
        }
        if address.hasSuffix("/") {
            address.removeLast()
        }
        return address
    }

    /// The address after a page's title: the whole address of a web page,
    /// the address as is otherwise.
    static func addressText(for urlString: String) -> String {
        address(for: urlString) ?? BrowserURLDisplayFormatter.displayString(for: urlString)
    }

    /// A page title without the parts that repeat the address: a pull
    /// request's author, number and repository, and a video site's name.
    static func cleanedPageTitle(_ title: String, urlString: String) -> String {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return title }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if site == "github.com",
           let range = title.range(of: #" by \S+ · Pull Request #\d+ · \S+/\S+$"#, options: .regularExpression),
           range.lowerBound > title.startIndex
        {
            return String(title[..<range.lowerBound])
        }
        if site == "youtube.com" || site.hasSuffix(".youtube.com"), title.hasSuffix(" - YouTube"), title.count > 10 {
            return String(title.dropLast(10))
        }
        return title
    }

    // MARK: Private

    private static func normalizedTabIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard !id.isEmpty, !seen.contains(id) else {
                return false
            }

            seen.insert(id)
            return true
        }
    }

    func inlineCompletionSuffix(relativeTo query: String) -> String? {
        guard let displayText = fieldText,
              !query.isEmpty,
              let matchedRange = displayText.range(
                  of: query,
                  options: [.anchored, .caseInsensitive, .diacriticInsensitive],
              ),
              matchedRange.lowerBound == displayText.startIndex,
              matchedRange.upperBound < displayText.endIndex
        else {
            return nil
        }

        let suffix = String(displayText[matchedRange.upperBound...])
        return suffix.isEmpty ? nil : suffix
    }

    mutating func appendTabIDs(_ ids: [String]) {
        tabIDs = Self.normalizedTabIDs(tabIDs + ids)
    }
}

// MARK: - BrowserSuggestionProviding

protocol BrowserSuggestionProviding: Sendable {
    func suggestions(for query: String, maximumCount: Int) async -> [String]
}

// MARK: - BrowserGoogleSuggestionService

struct BrowserGoogleSuggestionService: BrowserSuggestionProviding {
    // MARK: Private

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Internal

    func suggestions(for query: String, maximumCount: Int) async -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedQuery.isEmpty,
            var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")
        else {
            return []
        }

        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "q", value: trimmedQuery),
        ]

        guard let url = components.url else {
            return []
        }

        do {
            let (data, _) = try await session.data(from: url)
            let object = try JSONSerialization.jsonObject(with: data)
            guard
                let payload = object as? [Any],
                payload.count > 1,
                let suggestions = payload[1] as? [String]
            else {
                return []
            }

            return Array(suggestions.prefix(maximumCount))
        } catch {
            return []
        }
    }
}

// MARK: - BrowserCommandBarModel

@MainActor final class BrowserCommandBarModel: ObservableObject {
    // MARK: Internal

    /// The list scrolls past the first five rows.
    static let maximumSuggestions = 18
    /// Pages from tabs, bookmarks and history, besides the top hit.
    static let maximumPages = 9
    /// The search engine's suggestions.
    static let maximumRemoteSuggestions = 8
    /// Commands and actions listed after the pages and searches.
    static let maximumTrailingActions = 5
    static let maximumRecentPages = 5
    nonisolated static let maximumVisibleSuggestions = 5

    @Published private(set) var isPresented = false
    @Published private(set) var focusRequestID = 0
    @Published private(set) var suggestions = [BrowserCommandSuggestion]()
    @Published private(set) var selectedSuggestionIndex: Int?
    /// The site the bar searches after Tab, shown as a chip before the query.
    @Published private(set) var activeSiteSearch: BrowserSiteSearch?
    @Published var query = "" {
        didSet {
            handleQueryChange()
        }
    }

    /// Where Option-Return sends a page; nil makes it a plain Return.
    var splitSubmitHandler: ((String) -> Void)?
    /// Where Command-Return sends a page; nil makes it a plain Return.
    var backgroundSubmitHandler: ((String) -> Void)?

    /// The person moved to the selected suggestion; until then the field only
    /// completes what was typed and never replaces it.
    private var selectionWasChosen = false

    // MARK: Private

    /// The page the bar opened on, with its address as the query.
    private var presentedPage: BrowserCommandSuggestion?
    private let suggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
    private let submitHandler: (String) -> Void
    private let openTabHandler: ([String]) -> Void
    private let commandHandler: (BrowserCommandID) -> Void
    private let suggestionDebounceNanoseconds: UInt64
    private let localSuggestionProvider: (String, Int) -> [BrowserCommandSuggestion]
    private let remoteSuggestionsEnabledProvider: () -> Bool
    private let aiSearchEnabledProvider: () -> Bool
    private let recentPagesProvider: (Int) -> [BrowserCommandSuggestion]
    private let aiSearchProviderProvider: () -> BrowserAISearchProvider
    private let siteSearchesProvider: () -> [BrowserSiteSearch]
    private let siteRecentPagesProvider: (BrowserSiteSearch, Int) -> [BrowserCommandSuggestion]

    private var suggestionLoadTask: Task<Void, Never>?
    private var siteSearchTriggerQuery: String?
    /// The text whose completion Delete removed: until more is typed, the
    /// field keeps it as is and the search comes first.
    private var completionRemovedQuery: String?
    /// The search engine's latest suggestions and the text they answer.
    private var remoteSuggestions: (query: String, texts: [String])?

    var selectedSuggestion: BrowserCommandSuggestion? {
        guard
            let selectedSuggestionIndex,
            suggestions.indices.contains(selectedSuggestionIndex)
        else {
            return nil
        }

        return suggestions[selectedSuggestionIndex]
    }

    var selectedSuggestionID: String? {
        selectedSuggestion?.id
    }

    /// The site Tab would search, offered at the end of the field.
    var siteSearchCandidate: BrowserSiteSearch? {
        guard isPresented, activeSiteSearch == nil else { return nil }
        return BrowserSiteSearch.match(for: query, in: siteSearchesProvider())
    }

    var inlineCompletionSuffix: String? {
        selectedSuggestion?.inlineCompletionSuffix(relativeTo: query)
    }

    var previewDisplayText: String? {
        // Before anything is typed, the field keeps its placeholder over the recent pages.
        guard !query.isEmpty, let selectedSuggestion, selectedSuggestion.kind != .aiSearch,
              selectedSuggestion.kind != .command,
              let previewDisplayText = selectedSuggestion.fieldText else { return nil }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            selectionWasChosen || inlineCompletionSuffix != nil,
            previewDisplayText != query,
            !(previewDisplayText == trimmedQuery && trimmedQuery != query)
        else {
            return nil
        }

        return previewDisplayText
    }

    init(
        suggestionProvider: BrowserSuggestionProviding,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver(),
        suggestionDebounceNanoseconds: UInt64 = 150_000_000,
        localSuggestionProvider: @escaping (String, Int) -> [BrowserCommandSuggestion] = { _, _ in [] },
        remoteSuggestionsEnabledProvider: @escaping () -> Bool = { true },
        aiSearchProviderProvider: @escaping () -> BrowserAISearchProvider = { .chatGPT },
        aiSearchEnabledProvider: @escaping () -> Bool = { true },
        recentPagesProvider: @escaping (Int) -> [BrowserCommandSuggestion] = { _ in [] },
        siteSearchesProvider: @escaping () -> [BrowserSiteSearch] = { [] },
        siteRecentPagesProvider: @escaping (BrowserSiteSearch, Int) -> [BrowserCommandSuggestion] = { _, _ in [] },
        submitHandler: @escaping (String) -> Void,
        openTabHandler: @escaping ([String]) -> Void = { _ in },
        commandHandler: @escaping (BrowserCommandID) -> Void = { _ in },
    ) {
        self.suggestionProvider = suggestionProvider
        self.navigationResolver = navigationResolver
        self.submitHandler = submitHandler
        self.openTabHandler = openTabHandler
        self.commandHandler = commandHandler
        self.suggestionDebounceNanoseconds = suggestionDebounceNanoseconds
        self.localSuggestionProvider = localSuggestionProvider
        self.remoteSuggestionsEnabledProvider = remoteSuggestionsEnabledProvider
        self.aiSearchProviderProvider = aiSearchProviderProvider
        self.aiSearchEnabledProvider = aiSearchEnabledProvider
        self.siteRecentPagesProvider = siteRecentPagesProvider
        self.recentPagesProvider = recentPagesProvider
        self.siteSearchesProvider = siteSearchesProvider
    }

    /// Tab scopes the bar to the offered site; the typed keyword comes back
    /// if the scope is removed with Delete.
    @discardableResult func beginSiteSearch() -> Bool {
        guard let site = siteSearchCandidate else { return false }
        suggestionLoadTask?.cancel()
        siteSearchTriggerQuery = query
        activeSiteSearch = site
        query = ""
        return true
    }

    /// Delete in an empty field restores the keyword; Escape clears both.
    @discardableResult func endSiteSearch(restoringQuery: Bool) -> Bool {
        guard activeSiteSearch != nil else { return false }
        let trigger = siteSearchTriggerQuery ?? ""
        activeSiteSearch = nil
        siteSearchTriggerQuery = nil
        query = restoringQuery ? trigger : ""
        return true
    }

    @discardableResult func acceptSelectedSuggestion() -> Bool {
        guard let selectedSuggestion, let fieldText = selectedSuggestion.fieldText else {
            return false
        }

        if let completionSuffix = inlineCompletionSuffix {
            query += completionSuffix
        } else {
            guard fieldText != query else {
                return false
            }

            query = fieldText
        }

        selectPrimarySuggestionIfNeeded()
        return true
    }

    /// Delete over the completed part of the field: the text stays as typed,
    /// the page that completed it leaves the top, and the search comes first.
    @discardableResult func removeInlineCompletion() -> Bool {
        guard activeSiteSearch == nil, inlineCompletionSuffix != nil, !selectionWasChosen else { return false }
        completionRemovedQuery = query
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteSuggestions?.query == trimmedQuery ? remoteSuggestions?.texts ?? [] : []
        suggestions = assembledSuggestions(
            for: trimmedQuery,
            localSuggestions: localSuggestionProvider(trimmedQuery, Self.localSuggestionLimit),
            remoteSuggestions: remote,
        )
        selectedSuggestionIndex = suggestions.isEmpty ? nil : 0
        return true
    }

    /// `pageTitle` names the page whose address `initialQuery` is: until the
    /// address is edited, that page comes first, then the latest pages.
    func present(initialQuery: String = "", pageTitle: String? = nil) {
        suggestionLoadTask?.cancel()
        activeSiteSearch = nil
        siteSearchTriggerQuery = nil
        focusRequestID += 1
        isPresented = true
        presentedPage = pageTitle.flatMap { title in
            guard !initialQuery.isEmpty else { return nil }
            var page = BrowserCommandSuggestion(
                kind: .url,
                displayText: title.isEmpty ? initialQuery : title,
                resolvedURLString: initialQuery,
            )
            // The field keeps the address while the page is selected.
            page.completionText = initialQuery
            return page
        }
        if query == initialQuery {
            handleQueryChange()
        } else {
            query = initialQuery
        }
    }

    func dismiss() {
        suggestionLoadTask?.cancel()
        suggestionLoadTask = nil
        presentedPage = nil
        isPresented = false
        activeSiteSearch = nil
        siteSearchTriggerQuery = nil
        completionRemovedQuery = nil
        remoteSuggestions = nil
        query = ""
        suggestions = []
        selectedSuggestionIndex = nil
    }

    func moveSelection(by offset: Int) {
        guard !suggestions.isEmpty else {
            return
        }

        let currentIndex = selectedSuggestionIndex ?? 0
        selectionWasChosen = true
        selectedSuggestionIndex = min(max(currentIndex + offset, 0), suggestions.count - 1)
    }

    func selectSuggestion(id: String) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
            return
        }

        selectedSuggestionIndex = index
    }

    /// Command-Return: the chosen page opens in a tab behind and the bar stays,
    /// for the next one. Commands and tabs go as with Return.
    func submitSelectionInBackground() {
        guard
            let backgroundSubmitHandler,
            let suggestion = selectedSuggestion ?? primarySuggestion(for: query),
            suggestion.kind != .command,
            suggestion.kind != .openTab,
            !suggestion.resolvedURLString.isEmpty
        else {
            submitSelection()
            return
        }
        backgroundSubmitHandler(suggestion.resolvedURLString)
    }

    /// Option-Return: the chosen page opens in a Split View beside the one on
    /// screen. Commands and tabs go as with Return.
    func submitSelectionInSplitView() {
        guard
            let splitSubmitHandler,
            let suggestion = selectedSuggestion ?? primarySuggestion(for: query),
            suggestion.kind != .command,
            suggestion.kind != .openTab,
            !suggestion.resolvedURLString.isEmpty
        else {
            submitSelection()
            return
        }
        splitSubmitHandler(suggestion.resolvedURLString)
        dismiss()
    }

    func submitSelection() {
        guard let suggestion = selectedSuggestion ?? primarySuggestion(for: query) else {
            return
        }

        if suggestion.kind == .command, let commandID = suggestion.commandID {
            dismiss()
            commandHandler(commandID)
        } else if suggestion.kind == .openTab, !suggestion.tabIDs.isEmpty {
            openTabHandler(suggestion.tabIDs)
            dismiss()
        } else {
            submitHandler(suggestion.resolvedURLString)
            dismiss()
        }
    }

    func submitSuggestion(id: String) {
        selectSuggestion(id: id)
        submitSelection()
    }

    func waitForPendingSuggestionLoad() async {
        await suggestionLoadTask?.value
    }
}

@MainActor private extension BrowserCommandBarModel {
    func handleQueryChange() {
        suggestionLoadTask?.cancel()
        suggestionLoadTask = nil
        selectionWasChosen = false

        guard isPresented else {
            suggestions = []
            selectedSuggestionIndex = nil
            return
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let site = activeSiteSearch {
            // Lists only the query, which opens the site's results. Before
            // anything is typed, the site's earlier results pages.
            if trimmedQuery.isEmpty {
                // Shown as searches: a magnifier, the page's title without the
                // site's name, no address.
                suggestions = siteRecentPagesProvider(site, Self.maximumRecentPages).map {
                    BrowserCommandSuggestion(
                        kind: .search,
                        displayText: site.resultsTitle($0.displayText),
                        resolvedURLString: $0.resolvedURLString,
                    )
                }
                selectedSuggestionIndex = suggestions.isEmpty ? nil : 0
                return
            }
            suggestions = site.searchURLString(for: trimmedQuery).flatMap { urlString in
                trimmedQuery.isEmpty
                    ? nil
                    : [BrowserCommandSuggestion(
                        kind: .search,
                        displayText: trimmedQuery,
                        resolvedURLString: urlString,
                    )]
            } ?? []
            selectedSuggestionIndex = suggestions.isEmpty ? nil : 0
            return
        }
        // The address the bar opened with, unedited: that page, then the latest ones.
        if let page = presentedPage, query == page.resolvedURLString {
            let recent = recentPagesProvider(Self.maximumRecentPages)
                .filter { $0.resolvedURLString != page.resolvedURLString }
            suggestions = [page] + recent.prefix(Self.maximumRecentPages - 1)
            selectedSuggestionIndex = 0
            return
        }
        // Before anything is typed, the latest pages are one key away.
        if trimmedQuery.isEmpty {
            suggestions = recentPagesProvider(Self.maximumRecentPages)
            selectedSuggestionIndex = suggestions.isEmpty ? nil : 0
            return
        }
        let localSuggestions = localSuggestionProvider(trimmedQuery, Self.localSuggestionLimit)
        // The last suggestions stay while the next ones load, when they still
        // start with the text, so the list doesn't jump on every key.
        let carriedRemote = remoteSuggestions.map { previous in
            previous.texts.filter { $0.lowercased().hasPrefix(trimmedQuery.lowercased()) }
        } ?? []
        suggestions = assembledSuggestions(
            for: trimmedQuery,
            localSuggestions: localSuggestions,
            remoteSuggestions: carriedRemote,
        )
        selectedSuggestionIndex = suggestions.isEmpty ? nil : 0

        guard !trimmedQuery.isEmpty, remoteSuggestionsEnabledProvider() else {
            return
        }

        let currentQuery = trimmedQuery
        suggestionLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            if suggestionDebounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: suggestionDebounceNanoseconds)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, remoteSuggestionsEnabledProvider() else {
                return
            }

            let remoteSuggestions = await suggestionProvider.suggestions(
                for: currentQuery,
                maximumCount: Self.maximumRemoteSuggestions,
            )

            guard !Task.isCancelled else {
                return
            }

            let trimmedLiveQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPresented, activeSiteSearch == nil, trimmedLiveQuery == currentQuery else {
                return
            }

            self.remoteSuggestions = (currentQuery, remoteSuggestions)
            let previousSelection = selectedSuggestion
            let localSuggestions = localSuggestionProvider(currentQuery, Self.localSuggestionLimit)
            suggestions = assembledSuggestions(
                for: currentQuery,
                localSuggestions: localSuggestions,
                remoteSuggestions: remoteSuggestions,
            )
            // The chosen row stays chosen where it moved.
            selectedSuggestionIndex = suggestions.isEmpty
                ? nil
                : previousSelection.flatMap { selected in suggestions.firstIndex { $0.id == selected.id } }
                    ?? min(selectedSuggestionIndex ?? 0, suggestions.count - 1)
        }
    }

    /// One top hit, the search for the text, then pages: those that start
    /// with the text first, then the others taking turns with the search
    /// engine's suggestions. Commands and actions that did not make the top
    /// come last.
    func assembledSuggestions(
        for query: String,
        localSuggestions: [BrowserCommandSuggestion],
        remoteSuggestions: [String],
    ) -> [BrowserCommandSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        var assembledSuggestions = [BrowserCommandSuggestion]()
        var seenDisplayTexts = Set<String>()
        var seenSuggestionKeys = Set<String>()

        var limit = Self.maximumSuggestions
        @discardableResult func appendSuggestion(_ suggestion: BrowserCommandSuggestion) -> Bool {
            let displayKey = suggestion.displayText.lowercased()
            let suggestionKey = duplicateKey(for: suggestion)
            if suggestion.kind == .openTab,
               let existingIndex = assembledSuggestions.firstIndex(where: {
                   $0.kind == .openTab && duplicateKey(for: $0) == suggestionKey
               })
            {
                assembledSuggestions[existingIndex].appendTabIDs(suggestion.tabIDs)
                return false
            }

            // Pages with one title on different sites stay apart; they
            // share an address key only when they are the same page.
            let shouldDedupeDisplayText = ![.openTab, .history, .bookmark].contains(suggestion.kind)
            guard
                !shouldDedupeDisplayText || !seenDisplayTexts.contains(displayKey),
                !seenSuggestionKeys.contains(suggestionKey),
                assembledSuggestions.count < limit
            else {
                return false
            }

            assembledSuggestions.append(suggestion)
            seenDisplayTexts.insert(displayKey)
            seenSuggestionKeys.insert(suggestionKey)
            return true
        }

        let pages = localSuggestions.filter { $0.kind != .command && !$0.isAction }
        let actions = localSuggestions.filter { $0.kind == .command || $0.isAction }
        let primary = primarySuggestion(for: query)
        let endsWord = self.query.last?.isWhitespace == true

        // The top hit. A visited page whose address starts with the text
        // completes the field to that address. A typed space ends the word,
        // so the text is a search, not the start of an address; Delete over
        // the completion keeps the search first as well.
        if completionRemovedQuery != self.query {
            if !endsWord, let completed = Self.addressCompletion(for: query, in: pages) {
                appendSuggestion(completed)
            } else if primary?.kind != .url {
                if !endsWord, let tab = pages.first(where: { $0.kind == .openTab && Self.wordStarts(query, in: $0) }) {
                    appendSuggestion(tab)
                } else if let command = actions.first(where: { Self.commandAnswers($0, query) }) {
                    appendSuggestion(command)
                }
            }
        }
        if let primary {
            appendSuggestion(primary)
        }

        if aiSearchEnabledProvider() {
            appendSuggestion(aiSearchSuggestion(for: query))
        }

        let remote = remoteSuggestions.compactMap { remoteSuggestion -> BrowserCommandSuggestion? in
            let trimmedSuggestion = remoteSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSuggestion.isEmpty, let resolvedSuggestion = navigationResolver.resolve(trimmedSuggestion)
            else {
                return nil
            }
            return BrowserCommandSuggestion(
                kind: resolvedSuggestion.kind == .url ? .url : .googleSuggestion,
                displayText: trimmedSuggestion,
                resolvedURLString: resolvedSuggestion.resolvedURLString,
            )
        }
        .prefix(Self.maximumRemoteSuggestions)

        // The commands that did not make the top keep their rows at the end.
        let remainingActions = actions.filter { action in
            !assembledSuggestions.contains { duplicateKey(for: $0) == duplicateKey(for: action) }
        }
        limit = Self.maximumSuggestions - min(remainingActions.count, Self.maximumTrailingActions)
        var pageCount = 0
        func appendPage(_ page: BrowserCommandSuggestion) {
            guard pageCount < Self.maximumPages else { return }
            if appendSuggestion(page) {
                pageCount += 1
            }
        }
        let strong = pages.filter { Self.startsWith(query, $0) }
        let weak = pages.filter { !Self.startsWith(query, $0) }
        strong.forEach(appendPage)
        var weakPages = weak.makeIterator()
        var remoteRows = remote.makeIterator()
        var nextWeak = weakPages.next()
        var nextRemote = remoteRows.next()
        while nextWeak != nil || nextRemote != nil {
            if let page = nextWeak {
                appendPage(page)
                nextWeak = weakPages.next()
            }
            if let suggestion = nextRemote {
                appendSuggestion(suggestion)
                nextRemote = remoteRows.next()
            }
        }
        limit = Self.maximumSuggestions
        remainingActions.forEach { appendSuggestion($0) }
        return assembledSuggestions
    }

    static var localSuggestionLimit: Int { maximumPages + 6 }

    /// The first page among these whose address, without its scheme and
    /// "www.", starts with the text.
    static func addressCompletion(
        for query: String,
        in suggestions: [BrowserCommandSuggestion],
    ) -> BrowserCommandSuggestion? {
        let needle = query.lowercased()
        guard needle.count >= 2, !needle.contains(where: \.isWhitespace) else { return nil }
        for suggestion in suggestions where [.openTab, .history, .bookmark].contains(suggestion.kind) {
            guard let address = BrowserCommandSuggestion.address(for: suggestion.resolvedURLString),
                  address.lowercased().hasPrefix(needle), address.count > needle.count
            else { continue }
            var completed = suggestion
            completed.completionText = address
            return completed
        }
        return nil
    }

    /// The page's address or title starts with the text.
    static func startsWith(_ query: String, _ suggestion: BrowserCommandSuggestion) -> Bool {
        let needle = BrowserSearchIndex.normalized(query)
        guard !needle.isEmpty else { return false }
        if let address = BrowserCommandSuggestion.address(for: suggestion.resolvedURLString),
           BrowserSearchIndex.normalized(address).hasPrefix(needle)
        {
            return true
        }
        return BrowserSearchIndex.normalized(suggestion.displayText).hasPrefix(needle)
    }

    /// Every word of the text starts a word of the page's title or address.
    static func wordStarts(_ query: String, in suggestion: BrowserCommandSuggestion) -> Bool {
        let terms = BrowserSearchIndex.words(in: query)
        guard !terms.isEmpty, terms.joined().count >= 2 else { return false }
        let words = BrowserSearchIndex.words(in: suggestion.displayText)
            + BrowserSearchIndex.words(in: BrowserCommandSuggestion.address(for: suggestion.resolvedURLString) ?? "")
        return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }

    private static func commandAnswers(_ suggestion: BrowserCommandSuggestion, _ query: String) -> Bool {
        guard suggestion.kind == .command, query.count >= 2 else { return false }
        let needle = query.lowercased()
        return suggestion.displayText.lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
    }

    func aiSearchSuggestion(for query: String) -> BrowserCommandSuggestion {
        let provider = aiSearchProviderProvider()
        return BrowserCommandSuggestion(
            kind: .aiSearch,
            displayText: BrowserStrings.commandBarAskAI(provider.title),
            detailText: query,
            resolvedURLString: provider.searchURLString(for: query),
        )
    }

    func primarySuggestion(for query: String) -> BrowserCommandSuggestion? {
        guard let resolvedQuery = navigationResolver.resolve(query) else {
            return nil
        }

        let kind: BrowserCommandSuggestion.Kind =
            switch resolvedQuery.kind {
            case .url:
                .url
            case .search:
                .search
            }

        return BrowserCommandSuggestion(
            kind: kind,
            displayText: resolvedQuery.displayText,
            resolvedURLString: resolvedQuery.resolvedURLString,
        )
    }

    func duplicateKey(for suggestion: BrowserCommandSuggestion) -> String {
        if suggestion.kind == .openTab {
            return "open-tab|\(normalizedURLString(suggestion.resolvedURLString))"
        }

        if suggestion.kind == .command {
            return "command|\(suggestion.commandID?.rawValue ?? suggestion.displayText.lowercased())"
        }

        return "url|\(normalizedURLString(suggestion.resolvedURLString))"
    }

    func normalizedURLString(_ urlString: String) -> String {
        if let canonicalURLString = BrowserInternalURLNormalizer.canonicalURLString(for: urlString) {
            return canonicalURLString.lowercased()
        }

        guard var components = URLComponents(string: urlString) else {
            return urlString.lowercased()
        }

        // One page whatever its scheme, "www." or the part after "#".
        components.scheme = components.scheme?.lowercased() == "http" ? "https" : components.scheme?.lowercased()
        if var host = components.host?.lowercased() {
            if host.hasPrefix("www.") {
                host.removeFirst(4)
            }
            components.host = host
        }
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        }
        return components.url?.absoluteString ?? urlString.lowercased()
    }

    func selectPrimarySuggestionIfNeeded() {
        guard !suggestions.isEmpty else {
            selectedSuggestionIndex = nil
            return
        }

        selectedSuggestionIndex = 0
    }
}
