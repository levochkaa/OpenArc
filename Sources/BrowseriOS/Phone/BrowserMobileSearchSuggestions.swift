// BrowserMobileSearchSuggestions.swift

import Foundation

// MARK: - BrowserMobileSearchSuggestions

/// What the search panel lists for a query: the site the query completes to,
/// a web search, open and pinned tabs that match, then the search engine's
/// suggestions.
struct BrowserMobileSearchSuggestions: Equatable {
    // MARK: Internal

    struct Item: Equatable {
        enum Kind: Equatable {
            /// Open the address in a new tab.
            case address(String)
            /// Search the web for the text.
            case search(String)
            /// Switch to a tab this browser already has.
            case tab(String)
        }

        let kind: Kind
        let title: String
        let subtitle: String?
        /// The page whose icon the row shows.
        let iconPage: String?
    }

    struct Candidate: Equatable {
        let tabID: String
        let title: String
        let urlString: String
        /// Where the tab lives, such as "Pinned in Work" or "Tab in Work".
        let location: String?
    }

    /// Tabs listed before the search engine's suggestions take the rest.
    static let tabLimitWithSearches = 3

    let items: [Item]
    /// The host the typed text completes to, such as "apple.com" for "app".
    let completion: String?

    init(query rawQuery: String, candidates: [Candidate], searches: [String] = [], limit: Int = 8) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion = nil
            items = candidates.prefix(limit).map {
                Item(kind: .tab($0.tabID), title: Self.title($0), subtitle: nil, iconPage: $0.urlString)
            }
            return
        }
        let lowered = query.lowercased()
        var completion: String?
        var completedPage: String?
        if !lowered.contains(" ") {
            for candidate in candidates {
                guard let host = Self.host(candidate.urlString), host.hasPrefix(lowered), host != lowered else {
                    continue
                }
                completion = host
                completedPage = candidate.urlString
                break
            }
        }
        self.completion = completion
        var items = [Item]()
        if let completion {
            items.append(Item(
                kind: .address(completion), title: Self.siteTitle(completion, candidates: candidates),
                subtitle: nil, iconPage: completedPage,
            ))
        } else if Self.looksLikeAddress(query) {
            items.append(Item(kind: .address(query), title: query, subtitle: nil, iconPage: Self.pageURL(query)))
        }
        items.append(Item(kind: .search(query), title: query, subtitle: nil, iconPage: nil))
        let matches = candidates.filter { candidate in
            candidate.title.localizedCaseInsensitiveContains(query)
                || candidate.urlString.localizedCaseInsensitiveContains(query)
        }
        let searches = searches.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        let tabRoom = searches.isEmpty ? limit - items.count : Self.tabLimitWithSearches
        for candidate in matches.prefix(max(min(tabRoom, limit - items.count), 0)) {
            items.append(Item(
                kind: .tab(candidate.tabID), title: Self.title(candidate),
                subtitle: candidate.location ?? Self.host(candidate.urlString), iconPage: candidate.urlString,
            ))
        }
        for search in searches.prefix(max(limit - items.count, 0)) {
            items.append(Item(kind: .search(search), title: search, subtitle: nil, iconPage: nil))
        }
        self.items = items
    }

    static func host(_ urlString: String) -> String? {
        BrowserMobileFavicons.host(forPage: urlString)
    }

    // MARK: Private

    private static func title(_ candidate: Candidate) -> String {
        candidate.title.isEmpty ? host(candidate.urlString) ?? candidate.urlString : candidate.title
    }

    /// A short name for a site: the title of a tab on it when one is short, else the host.
    private static func siteTitle(_ host: String, candidates _: [Candidate]) -> String {
        let name = host.split(separator: ".").dropLast().last.map(String.init) ?? host
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func looksLikeAddress(_ query: String) -> Bool {
        guard !query.contains(" ") else { return false }
        if query.contains("://") { return true }
        let parts = query.split(separator: ".")
        return parts.count >= 2 && (parts.last?.count ?? 0) >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func pageURL(_ query: String) -> String {
        query.contains("://") ? query : "https://" + query
    }
}

// MARK: - BrowserMobileRemovedSuggestions

/// Pages taken out of the search suggestions from a row's menu; they stay
/// out, inline completion included.
enum BrowserMobileRemovedSuggestions {
    private static let key = "BrowserMobileRemovedSuggestions"
    private static let limit = 500

    static func pages(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func remove(_ page: String, in defaults: UserDefaults = .standard) {
        var pages = (defaults.stringArray(forKey: key) ?? []).filter { $0 != page }
        pages.append(page)
        defaults.set(Array(pages.suffix(limit)), forKey: key)
    }
}
