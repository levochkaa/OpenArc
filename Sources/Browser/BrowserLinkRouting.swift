// BrowserLinkRouting.swift

import Foundation

// MARK: - BrowserLinkRoute

/// A rule that sends links from other apps to a Space or to the small
/// window. The first matching rule wins; a link no rule matches, or whose
/// Space's window is closed, opens as before. Each rule has one condition,
/// and more rules cover more.
struct BrowserLinkRoute: Codable, Equatable, Identifiable {
    // MARK: Internal

    enum Match: String, Codable, CaseIterable {
        /// The link is on the site or a subdomain, and under the path when the
        /// pattern has one: `github.com/org` matches `docs.github.com/org/repo`.
        case site
        /// The link's address contains the text, ignoring case.
        case contains
    }

    enum Destination: Codable, Hashable {
        /// A profile's Space. Space IDs repeat across profiles, so both are kept.
        case space(profileID: String, spaceID: String)
        case littleWindow
    }

    var id: UUID
    var match: Match
    var pattern: String
    var destination: Destination
    /// The Space's title when the rule was set, shown while its profile is closed.
    var spaceTitle: String?

    init(
        id: UUID = UUID(),
        match: Match = .site,
        pattern: String = "",
        destination: Destination,
        spaceTitle: String? = nil,
    ) {
        self.id = id
        self.match = match
        self.pattern = pattern
        self.destination = destination
        self.spaceTitle = spaceTitle
    }

    // MARK: Private

    private static func site(_ pattern: String, contains url: URL) -> Bool {
        var pattern = pattern
        for scheme in ["https://", "http://"] where pattern.hasPrefix(scheme) {
            pattern.removeFirst(scheme.count)
        }
        let slash = pattern.firstIndex(of: "/") ?? pattern.endIndex
        let site = withoutWWW(String(pattern[..<slash]))
        let path = pattern[slash...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !site.isEmpty, var host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        else { return false }
        host = withoutWWW(host)
        if site.contains(":") {
            let defaultPort = ["http": 80, "https": 443][url.scheme?.lowercased() ?? ""]
            guard let port = url.port ?? defaultPort else { return false }
            host += ":\(port)"
        }
        guard host == site || host.hasSuffix("." + site) else { return false }
        guard !path.isEmpty else { return true }
        let urlPath = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return urlPath == path || urlPath.hasPrefix(path + "/")
    }

    private static func withoutWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func matches(_ url: URL) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        switch match {
        case .contains:
            let address = url.absoluteString
            return [address, address.removingPercentEncoding ?? address].contains { $0.lowercased().contains(pattern) }
        case .site:
            return Self.site(pattern, contains: url)
        }
    }
}

// MARK: - BrowserLinkRouter

enum BrowserLinkRouter {
    /// The first rule for a web link; other schemes keep their usual handling.
    static func route(for url: URL, in routes: [BrowserLinkRoute]) -> BrowserLinkRoute? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return routes.first { $0.matches(url) }
    }
}

// MARK: - BrowserSite

enum BrowserSite {
    // MARK: Private

    private static let countrySecondLevels: Set = ["ac", "co", "com", "edu", "gov", "ne", "net", "or", "org"]

    // MARK: Internal

    /// Whether two web addresses belong to one site: the same registrable
    /// domain, such as `mail.google.com` and `docs.google.com`. Without the
    /// public suffix list, a two-letter country domain keeps its common
    /// second level (`bbc.co.uk`).
    static func isSameSite(_ first: URL, _ second: URL) -> Bool {
        guard let first = site(of: first), let second = site(of: second) else { return false }
        return first == second
    }

    private static func site(of url: URL) -> String? {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty
        else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        // An IP address is its own site.
        if host.contains(":") || labels.allSatisfy({ Int($0) != nil }) {
            return host
        }
        let keepsThree = labels.count >= 3 && labels[labels.count - 1].count == 2
            && countrySecondLevels.contains(labels[labels.count - 2])
        return labels.suffix(keepsThree ? 3 : 2).joined(separator: ".")
    }
}
