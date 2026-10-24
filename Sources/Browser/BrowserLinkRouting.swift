import Foundation

// MARK: - BrowserLinkRoute

/// A link rule sends links from other apps to a
/// Space or to the small window. The first matching rule wins; a link no rule
/// matches, or whose Space's window is closed, opens as before. One could let a rule
/// list several conditions; here each rule has one, and more rules cover more.
struct BrowserLinkRoute: Codable, Equatable, Identifiable {
    // MARK: Lifecycle

    init(
        id: UUID = UUID(),
        match: Match = .site,
        pattern: String = "",
        destination: Destination,
        spaceTitle: String? = nil
    ) {
        self.id = id
        self.match = match
        self.pattern = pattern
        self.destination = destination
        self.spaceTitle = spaceTitle
    }

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
        /// The small window.
        case littleWindow
    }

    var id: UUID
    var match: Match
    var pattern: String
    var destination: Destination
    /// The Space's title when the rule was set, shown while its profile is closed.
    var spaceTitle: String?

    func matches(_ url: URL) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        switch match {
        case .contains:
            return url.absoluteString.lowercased().contains(pattern)
        case .site:
            return Self.site(pattern, contains: url)
        }
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
        guard !site.isEmpty, var host = url.host?.lowercased() else { return false }
        host = withoutWWW(host)
        if site.contains(":") {
            guard let port = url.port else { return false }
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
}

// MARK: - BrowserLinkRouter

enum BrowserLinkRouter {
    /// The first rule for a web link; other schemes keep their usual handling.
    static func route(for url: URL, in routes: [BrowserLinkRoute]) -> BrowserLinkRoute? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return routes.first { $0.matches(url) }
    }
}
