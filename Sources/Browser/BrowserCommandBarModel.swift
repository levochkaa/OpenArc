import Combine
import Foundation

// MARK: - BrowserCommandSuggestion

struct BrowserCommandSuggestion: Identifiable, Equatable {
    // MARK: Lifecycle

    init(
        kind: Kind,
        displayText: String,
        detailText: String? = nil,
        resolvedURLString: String = "",
        commandID: BrowserCommandID? = nil,
        shortcut: BrowserKeyboardShortcut? = nil,
        tabID: String? = nil,
        tabIDs: [String] = []
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
    }

    let kind: Kind
    let displayText: String
    var detailText: String?
    let resolvedURLString: String
    let commandID: BrowserCommandID?
    let shortcut: BrowserKeyboardShortcut?
    var tabIDs: [String]

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
            "rectangle.on.rectangle"
        case .url:
            "globe"
        case .googleSuggestion, .search:
            "magnifyingglass"
        case .aiSearch:
            "sparkles"
        case .command:
            commandID?.commandBarSystemImageName ?? "command"
        }
    }

    func inlineCompletionSuffix(relativeTo query: String) -> String? {
        guard kind != .command else {
            return nil
        }

        guard
            !query.isEmpty,
            let matchedRange = displayText.range(
                of: query,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive]
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
}

// MARK: - BrowserSuggestionProviding

protocol BrowserSuggestionProviding: Sendable {
    func suggestions(for query: String, maximumCount: Int) async -> [String]
}

// MARK: - BrowserGoogleSuggestionService

struct BrowserGoogleSuggestionService: BrowserSuggestionProviding {
    // MARK: Lifecycle

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

    // MARK: Private

    private let session: URLSession
}

// MARK: - BrowserCommandBarModel

@MainActor final class BrowserCommandBarModel: ObservableObject {
    // MARK: Lifecycle

    init(
        suggestionProvider: BrowserSuggestionProviding,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver(),
        suggestionDebounceNanoseconds: UInt64 = 150_000_000,
        localSuggestionProvider: @escaping (String, Int) -> [BrowserCommandSuggestion] = { _, _ in [] },
        remoteSuggestionsEnabledProvider: @escaping () -> Bool = { true },
        aiSearchProviderProvider: @escaping () -> BrowserAISearchProvider = { .chatGPT },
        submitHandler: @escaping (String) -> Void,
        openTabHandler: @escaping ([String]) -> Void = { _ in },
        commandHandler: @escaping (BrowserCommandID) -> Void = { _ in }
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
    }

    // MARK: Internal

    static let maximumSuggestions = 10
    nonisolated static let maximumVisibleSuggestions = 5

    @Published private(set) var isPresented = false
    @Published private(set) var focusRequestID = 0
    @Published private(set) var suggestions = [BrowserCommandSuggestion]()
    @Published private(set) var selectedSuggestionIndex: Int?

    @Published var query = "" {
        didSet {
            handleQueryChange()
        }
    }

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

    var inlineCompletionSuffix: String? {
        selectedSuggestion?.inlineCompletionSuffix(relativeTo: query)
    }

    var previewDisplayText: String? {
        guard let selectedSuggestion else {
            return nil
        }

        guard selectedSuggestion.kind != .aiSearch, selectedSuggestion.kind != .command else {
            return nil
        }

        let previewDisplayText = selectedSuggestion.displayText
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            previewDisplayText != query,
            !(previewDisplayText == trimmedQuery && trimmedQuery != query)
        else {
            return nil
        }

        return previewDisplayText
    }

    @discardableResult func acceptSelectedSuggestion() -> Bool {
        guard let selectedSuggestion else {
            return false
        }

        guard selectedSuggestion.kind != .aiSearch, selectedSuggestion.kind != .command else {
            return false
        }

        if let completionSuffix = inlineCompletionSuffix {
            query += completionSuffix
        } else {
            guard selectedSuggestion.displayText != query else {
                return false
            }

            query = selectedSuggestion.displayText
        }

        selectPrimarySuggestionIfNeeded()
        return true
    }

    func present(initialQuery: String = "") {
        suggestionLoadTask?.cancel()
        focusRequestID += 1
        isPresented = true
        query = initialQuery
    }

    func dismiss() {
        suggestionLoadTask?.cancel()
        suggestionLoadTask = nil
        isPresented = false
        query = ""
        suggestions = []
        selectedSuggestionIndex = nil
    }

    func moveSelection(by offset: Int) {
        guard !suggestions.isEmpty else {
            return
        }

        let currentIndex = selectedSuggestionIndex ?? 0
        selectedSuggestionIndex = min(max(currentIndex + offset, 0), suggestions.count - 1)
    }

    func selectSuggestion(id: String) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
            return
        }

        selectedSuggestionIndex = index
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

    // MARK: Private

    private let suggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
    private let submitHandler: (String) -> Void
    private let openTabHandler: ([String]) -> Void
    private let commandHandler: (BrowserCommandID) -> Void
    private let suggestionDebounceNanoseconds: UInt64
    private let localSuggestionProvider: (String, Int) -> [BrowserCommandSuggestion]
    private let remoteSuggestionsEnabledProvider: () -> Bool
    private let aiSearchProviderProvider: () -> BrowserAISearchProvider

    private var suggestionLoadTask: Task<Void, Never>?
}

@MainActor private extension BrowserCommandBarModel {
    func handleQueryChange() {
        suggestionLoadTask?.cancel()
        suggestionLoadTask = nil

        guard isPresented else {
            suggestions = []
            selectedSuggestionIndex = nil
            return
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let localSuggestionLimit = max(Self.maximumSuggestions - 2, 0)
        let localSuggestions = localSuggestionProvider(trimmedQuery, localSuggestionLimit)
        suggestions = assembledSuggestions(
            for: trimmedQuery,
            localSuggestions: localSuggestions,
            remoteSuggestions: []
        )
        selectedSuggestionIndex = suggestions.isEmpty ? nil : 0

        guard !trimmedQuery.isEmpty else {
            return
        }

        guard remoteSuggestionsEnabledProvider() else {
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

            guard !Task.isCancelled else {
                return
            }

            guard remoteSuggestionsEnabledProvider() else {
                return
            }

            let remoteSuggestionLimit = max(Self.maximumSuggestions - 2, 0)
            let remoteSuggestions = await suggestionProvider.suggestions(
                for: currentQuery,
                maximumCount: remoteSuggestionLimit
            )

            guard !Task.isCancelled else {
                return
            }

            let trimmedLiveQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPresented, trimmedLiveQuery == currentQuery else {
                return
            }

            let localSuggestions = localSuggestionProvider(currentQuery, localSuggestionLimit)
            suggestions = assembledSuggestions(
                for: currentQuery,
                localSuggestions: localSuggestions,
                remoteSuggestions: remoteSuggestions
            )
            selectedSuggestionIndex = suggestions.isEmpty
                ? nil
                : min(selectedSuggestionIndex ?? 0, suggestions.count - 1)
        }
    }

    func assembledSuggestions(
        for query: String,
        localSuggestions: [BrowserCommandSuggestion],
        remoteSuggestions: [String]
    ) -> [BrowserCommandSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        var assembledSuggestions = [BrowserCommandSuggestion]()
        var seenDisplayTexts = Set<String>()
        var seenSuggestionKeys = Set<String>()

        func appendSuggestion(_ suggestion: BrowserCommandSuggestion) {
            let displayKey = suggestion.displayText.lowercased()
            let suggestionKey = duplicateKey(for: suggestion)
            if suggestion.kind == .openTab,
               let existingIndex = assembledSuggestions.firstIndex(where: {
                   $0.kind == .openTab && duplicateKey(for: $0) == suggestionKey
               })
            {
                assembledSuggestions[existingIndex].appendTabIDs(suggestion.tabIDs)
                return
            }

            let shouldDedupeDisplayText = suggestion.kind != .openTab
            guard
                !shouldDedupeDisplayText || !seenDisplayTexts.contains(displayKey),
                !seenSuggestionKeys.contains(suggestionKey),
                assembledSuggestions.count < Self.maximumSuggestions
            else {
                return
            }

            assembledSuggestions.append(suggestion)
            seenDisplayTexts.insert(displayKey)
            seenSuggestionKeys.insert(suggestionKey)
        }

        if let primarySuggestion = primarySuggestion(for: query) {
            appendSuggestion(primarySuggestion)
        }

        appendSuggestion(aiSearchSuggestion(for: query))

        for localSuggestion in localSuggestions {
            appendSuggestion(localSuggestion)
        }

        for remoteSuggestion in remoteSuggestions {
            let trimmedSuggestion = remoteSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmedSuggestion.isEmpty,
                !seenDisplayTexts.contains(trimmedSuggestion.lowercased()),
                let resolvedSuggestion = navigationResolver.resolve(trimmedSuggestion)
            else {
                continue
            }

            let suggestionKind: BrowserCommandSuggestion.Kind =
                switch resolvedSuggestion.kind {
                case .url:
                    .url
                case .search:
                    .googleSuggestion
                }

            let suggestion = BrowserCommandSuggestion(
                kind: suggestionKind,
                displayText: trimmedSuggestion,
                resolvedURLString: resolvedSuggestion.resolvedURLString
            )
            appendSuggestion(suggestion)

            if assembledSuggestions.count == Self.maximumSuggestions {
                break
            }
        }

        return assembledSuggestions
    }

    func aiSearchSuggestion(for query: String) -> BrowserCommandSuggestion {
        let provider = aiSearchProviderProvider()
        return BrowserCommandSuggestion(
            kind: .aiSearch,
            displayText: BrowserStrings.commandBarAskAI(provider.title),
            detailText: query,
            resolvedURLString: provider.searchURLString(for: query)
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
            resolvedURLString: resolvedQuery.resolvedURLString
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

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
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
