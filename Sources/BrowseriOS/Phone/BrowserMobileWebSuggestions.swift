// BrowserMobileWebSuggestions.swift

import Foundation

// MARK: - BrowserMobileWebSuggestions

/// Asks the search engine what people search for that starts with the typed
/// text. Only Google answers; a newer query cancels the one in flight.
@MainActor final class BrowserMobileWebSuggestions {
    // MARK: Internal

    static let maximumCount = 8

    /// The latest answer and the query it answers.
    private(set) var query = ""
    private(set) var suggestions = [String]()

    var onChange: (() -> Void)?

    // MARK: Private

    private let session: URLSession
    private var task: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated static func url(for query: String) -> URL? {
        guard var components = URLComponents(string: "https://suggestqueries.google.com/complete/search") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "q", value: query),
        ]
        // A plus would read as a space.
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encoded
        return components.url
    }

    /// The suggestions in the engine's JSON answer: `[query, [suggestion…], …]`.
    nonisolated static func parse(_ data: Data) -> [String] {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [Any], payload.count > 1,
              let suggestions = payload[1] as? [String]
        else { return [] }
        return suggestions
    }

    // MARK: Internal

    /// The suggestions for `query`, if they are what was asked last.
    func suggestions(for query: String) -> [String] {
        self.query.caseInsensitiveCompare(query) == .orderedSame ? suggestions : []
    }

    /// Asks for `query` shortly, unless another keystroke comes first; an
    /// empty query, or nil, stops asking.
    func request(_ rawQuery: String?) {
        task?.cancel()
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty, let url = Self.url(for: query) else {
            task = nil
            if !suggestions.isEmpty {
                self.query = ""
                suggestions = []
                onChange?()
            }
            return
        }
        let session = session
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let (data, _) = try? await session.data(from: url), !Task.isCancelled else {
                return
            }
            let suggestions = Array(Self.parse(data).prefix(Self.maximumCount))
            guard let self else { return }
            self.query = query
            self.suggestions = suggestions
            onChange?()
        }
    }
}
