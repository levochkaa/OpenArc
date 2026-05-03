import Combine
import Foundation

struct BrowserCommandSuggestion: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case url
        case search
        case googleSuggestion
    }

    let kind: Kind
    let displayText: String
    let resolvedURLString: String

    var id: String {
        "\(kind.rawValue)|\(displayText)|\(resolvedURLString)"
    }

    var systemImageName: String {
        switch kind {
        case .url:
            return "globe"
        case .search, .googleSuggestion:
            return "magnifyingglass"
        }
    }

    func inlineCompletionSuffix(relativeTo query: String) -> String? {
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
}

protocol BrowserSuggestionProviding {
    func suggestions(for query: String, maximumCount: Int) async -> [String]
}

struct BrowserGoogleSuggestionService: BrowserSuggestionProviding {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

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

@MainActor
final class BrowserCommandBarModel: ObservableObject {
    static let maximumSuggestions = 10
    static let maximumVisibleSuggestions = 5

    @Published private(set) var isPresented = false
    @Published private(set) var focusRequestID = 0
    @Published var query = "" {
        didSet {
            handleQueryChange()
        }
    }

    @Published private(set) var suggestions: [BrowserCommandSuggestion] = []
    @Published private(set) var selectedSuggestionIndex: Int?

    private let suggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
    private let submitHandler: (String) -> Void
    private let suggestionDebounceNanoseconds: UInt64

    private var suggestionLoadTask: Task<Void, Never>?

    init(
        suggestionProvider: BrowserSuggestionProviding,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver(),
        suggestionDebounceNanoseconds: UInt64 = 150_000_000,
        submitHandler: @escaping (String) -> Void
    ) {
        self.suggestionProvider = suggestionProvider
        self.navigationResolver = navigationResolver
        self.submitHandler = submitHandler
        self.suggestionDebounceNanoseconds = suggestionDebounceNanoseconds
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

    @discardableResult
    func acceptSelectedSuggestion() -> Bool {
        guard let selectedSuggestion else {
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

    func present() {
        suggestionLoadTask?.cancel()
        focusRequestID += 1
        isPresented = true
        query = ""
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
        let resolvedURLString = (selectedSuggestion ?? primarySuggestion(for: query))?.resolvedURLString
        guard let resolvedURLString else {
            return
        }

        submitHandler(resolvedURLString)
        dismiss()
    }

    func submitSuggestion(id: String) {
        selectSuggestion(id: id)
        submitSelection()
    }

    func waitForPendingSuggestionLoad() async {
        await suggestionLoadTask?.value
    }
}

@MainActor
private extension BrowserCommandBarModel {
    func handleQueryChange() {
        suggestionLoadTask?.cancel()
        suggestionLoadTask = nil

        guard isPresented else {
            suggestions = []
            selectedSuggestionIndex = nil
            return
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestions = assembledSuggestions(for: trimmedQuery, remoteSuggestions: [])
        selectedSuggestionIndex = suggestions.isEmpty ? nil : 0

        guard !trimmedQuery.isEmpty else {
            return
        }

        let currentQuery = trimmedQuery
        suggestionLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            if self.suggestionDebounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: self.suggestionDebounceNanoseconds)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }

            let remoteSuggestionLimit = max(Self.maximumSuggestions - 1, 0)
            let remoteSuggestions = await self.suggestionProvider.suggestions(
                for: currentQuery,
                maximumCount: remoteSuggestionLimit
            )

            guard !Task.isCancelled else {
                return
            }

            let trimmedLiveQuery = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.isPresented, trimmedLiveQuery == currentQuery else {
                return
            }

            self.suggestions = self.assembledSuggestions(for: currentQuery, remoteSuggestions: remoteSuggestions)
            self.selectedSuggestionIndex = self.suggestions.isEmpty ? nil : min(self.selectedSuggestionIndex ?? 0, self.suggestions.count - 1)
        }
    }

    func assembledSuggestions(for query: String, remoteSuggestions: [String]) -> [BrowserCommandSuggestion] {
        guard !query.isEmpty else {
            return []
        }

        var assembledSuggestions: [BrowserCommandSuggestion] = []
        var seenDisplayTexts = Set<String>()

        if let primarySuggestion = primarySuggestion(for: query) {
            assembledSuggestions.append(primarySuggestion)
            seenDisplayTexts.insert(primarySuggestion.displayText.lowercased())
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

            let suggestion = BrowserCommandSuggestion(
                kind: .googleSuggestion,
                displayText: trimmedSuggestion,
                resolvedURLString: resolvedSuggestion.resolvedURLString
            )
            assembledSuggestions.append(suggestion)
            seenDisplayTexts.insert(trimmedSuggestion.lowercased())

            if assembledSuggestions.count == Self.maximumSuggestions {
                break
            }
        }

        return assembledSuggestions
    }

    func primarySuggestion(for query: String) -> BrowserCommandSuggestion? {
        guard let resolvedQuery = navigationResolver.resolve(query) else {
            return nil
        }

        let kind: BrowserCommandSuggestion.Kind
        switch resolvedQuery.kind {
        case .url:
            kind = .url
        case .search:
            kind = .search
        }

        return BrowserCommandSuggestion(
            kind: kind,
            displayText: resolvedQuery.displayText,
            resolvedURLString: resolvedQuery.resolvedURLString
        )
    }

    func selectPrimarySuggestionIfNeeded() {
        guard !suggestions.isEmpty else {
            selectedSuggestionIndex = nil
            return
        }

        selectedSuggestionIndex = 0
    }
}
