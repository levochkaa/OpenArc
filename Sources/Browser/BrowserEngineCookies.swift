// BrowserEngineCookies.swift

import Foundation

// MARK: - BrowserChromiumCookie

/// A cookie as Chromium's cookie manager reports it, on its way to WebKit's
/// cookie store. Chromium and WebKit keep separate stores, so a page that moves
/// to WebKit would otherwise lose the site's sign-in.
struct BrowserChromiumCookie: Equatable {
    /// `cef_cookie_same_site_t`'s values.
    enum SameSite: Int {
        case unspecified = 0
        case none = 1
        case lax = 2
        case strict = 3
    }

    /// Seconds from 1601-01-01, Chromium's epoch, to 1970-01-01.
    static let windowsEpochOffset: Int64 = 11_644_473_600

    let name: String
    let value: String
    /// A leading dot marks a domain cookie, sent to subdomains too; a bare host
    /// is a host-only cookie. Foundation reads the dot the same way.
    let domain: String
    let path: String
    let isSecure: Bool
    let isHTTPOnly: Bool
    /// Microseconds since 1601, Chromium's own clock; nil for a session cookie.
    let expires: Int64?
    let sameSite: SameSite

    var isHostOnly: Bool { !domain.hasPrefix(".") }

    var expiryDate: Date? {
        expires.map { Date(timeIntervalSince1970: Double($0) / 1_000_000 - Double(Self.windowsEpochOffset)) }
    }

    /// Foundation's properties for this cookie, or nil when it has expired.
    /// An unspecified SameSite stays unset: WebKit then treats the cookie as
    /// Safari does, which the site expects of a WebKit page.
    func httpCookieProperties(now: Date = Date()) -> [HTTPCookiePropertyKey: Any]? {
        guard !name.isEmpty, !domain.isEmpty else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
        ]
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let expiryDate {
            guard expiryDate > now else { return nil }
            properties[.expires] = expiryDate
        } else {
            properties[.discard] = "TRUE"
        }
        switch sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .none, .unspecified: break
        }
        return properties
    }

    func httpCookie(now: Date = Date()) -> HTTPCookie? {
        httpCookieProperties(now: now).flatMap(HTTPCookie.init(properties:))
    }
}

extension BrowserChromiumCookie {
    /// Reads the dictionary `BrowserTabController` builds from a `CefCookie`.
    init?(dictionary: [String: Any]) {
        guard let name = dictionary["name"] as? String,
              let domain = dictionary["domain"] as? String else { return nil }
        self.name = name
        self.value = dictionary["value"] as? String ?? ""
        self.domain = domain
        self.path = dictionary["path"] as? String ?? "/"
        self.isSecure = (dictionary["secure"] as? NSNumber)?.boolValue ?? false
        self.isHTTPOnly = (dictionary["httpOnly"] as? NSNumber)?.boolValue ?? false
        let hasExpires = (dictionary["hasExpires"] as? NSNumber)?.boolValue ?? false
        self.expires = hasExpires ? (dictionary["expires"] as? NSNumber)?.int64Value : nil
        self.sameSite = (dictionary["sameSite"] as? NSNumber)
            .flatMap { SameSite(rawValue: $0.intValue) } ?? .unspecified
    }
}

// MARK: - BrowserEngineCookieTransfer

/// Which of a profile's Chromium cookies go along when a page moves to WebKit,
/// and which of them WebKit's store still lacks.
@objc final class BrowserEngineCookieTransfer: NSObject {
    // MARK: Private

    private struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: HTTPCookie) {
            self.name = cookie.name
            self.domain = cookie.domain.lowercased()
            self.path = cookie.path
        }
    }

    // MARK: Internal

    /// Sites that sign in on another registrable domain, by the page's domain.
    static let signInDomains: [String: [String]] = [
        "primevideo.com": ["amazon.com"],
        "max.com": ["hbomax.com"],
        "hbomax.com": ["max.com"],
    ]

    private static let signInHostLabels: Set = [
        "account", "accounts", "auth", "id", "identity", "idp", "login", "signin", "sso",
    ]
    private static let signInPathComponents: Set = ["auth", "oauth", "oauth2", "sso", "authorize"]

    /// The page's registrable domain, the domains its site signs in on, and
    /// those of sign-in pages this tab passed through, such as an account
    /// host the site redirected to and back.
    @objc static func domains(forPageURLString pageURLString: String, historyURLStrings: [String]) -> [String] {
        domains(
            forPageURLString: pageURLString,
            historyURLStrings: historyURLStrings,
            parser: BrowserPublicSuffixDomainParser.shared,
        )
    }

    static func domains(
        forPageURLString pageURLString: String,
        historyURLStrings: [String],
        parser: any BrowserDomainParsing,
    ) -> [String] {
        guard let page = webURL(pageURLString), let pageDomain = registrableDomain(of: page, parser: parser) else {
            return []
        }
        var domains = [pageDomain] + (signInDomains[pageDomain] ?? [])
        for urlString in historyURLStrings {
            guard let url = webURL(urlString), isSignInURL(url),
                  let domain = registrableDomain(of: url, parser: parser) else { continue }
            domains.append(domain)
        }
        var seen = Set<String>()
        return domains.filter { seen.insert($0).inserted }
    }

    /// A cookie for one of the domains or a subdomain of one.
    @objc static func cookieDomain(_ cookieDomain: String, matchesDomains domains: [String]) -> Bool {
        var host = cookieDomain.lowercased()
        if host.hasPrefix(".") {
            host.removeFirst()
        }
        guard !host.isEmpty else { return false }
        return domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Account pages: a host such as `accounts.` or `login.`, or a path such as
    /// `/signin` or `/oauth`.
    static func isSignInURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let label = host.split(separator: ".").first, signInHostLabels.contains(String(label)) {
            return true
        }
        return url.pathComponents.contains { component in
            let component = component.lowercased()
            return signInPathComponents.contains(component) || component.hasPrefix("signin")
                || component.hasPrefix("login") || component.hasPrefix("sign-in")
        }
    }

    /// Chromium's cookies WebKit's store lacks: a cookie the store has, by name,
    /// domain and path, stays as it is, so a sign-in made in WebKit is not
    /// replaced by an older one from Chromium.
    static func cookiesToAdd(_ cookies: [HTTPCookie], existing: [HTTPCookie]) -> [HTTPCookie] {
        let present = Set(existing.map(CookieKey.init))
        var seen = Set<CookieKey>()
        return cookies.filter { cookie in
            let key = CookieKey(cookie)
            return !present.contains(key) && seen.insert(key).inserted
        }
    }

    private static func webURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func registrableDomain(of url: URL, parser: any BrowserDomainParsing) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return parser.parse(host: host)?.registrableDomain ?? host
    }
}
