// BrowserNavigationResolver.swift

import DomainParser
import Foundation
import Network

// MARK: - BrowserNavigationResolver

struct BrowserNavigationResolver {
    // MARK: Internal

    enum Kind: Equatable {
        case url
        case search
    }

    struct Resolution: Equatable {
        let kind: Kind
        let displayText: String
        let resolvedURLString: String
    }

    // MARK: Private

    private let domainParser: any BrowserDomainParsing
    private let searchEngineProvider: () -> BrowserSearchEngine

    init(
        domainParser: any BrowserDomainParsing = BrowserPublicSuffixDomainParser.shared,
        searchEngineProvider: @escaping () -> BrowserSearchEngine = { .google },
    ) {
        self.domainParser = domainParser
        self.searchEngineProvider = searchEngineProvider
    }

    func resolve(_ rawInput: String) -> Resolution? {
        let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        if let resolvedURLString = resolvedURLString(for: trimmedInput) {
            return Resolution(
                kind: .url,
                displayText: trimmedInput,
                resolvedURLString: resolvedURLString,
            )
        }

        return Resolution(
            kind: .search,
            displayText: trimmedInput,
            resolvedURLString: searchEngineProvider().searchURLString(for: trimmedInput),
        )
    }

    private func resolvedURLString(for input: String) -> String? {
        if let canonicalInternalURLString = BrowserInternalURLNormalizer.canonicalURLString(for: input) {
            return canonicalInternalURLString
        }

        if hasExplicitScheme(input) {
            guard
                let components = URLComponents(string: input),
                let scheme = components.scheme?.lowercased(),
                !scheme.isEmpty,
                isValidResolvedURL(components: components, scheme: scheme, allowSingleLabelHost: true)
            else {
                return nil
            }

            return components.url?.absoluteString
        }

        let prefixedInput = "https://\(input)"
        guard
            let components = URLComponents(string: prefixedInput),
            isValidResolvedURL(components: components, scheme: "https", allowSingleLabelHost: false)
        else {
            return nil
        }

        return components.url?.absoluteString
    }

    private func hasExplicitScheme(_ input: String) -> Bool {
        guard let colonIndex = input.firstIndex(of: ":") else {
            return false
        }

        let schemeCandidate = input[..<colonIndex]
        guard
            schemeCandidate.range(
                of: #"^[A-Za-z][A-Za-z0-9+\-.]*$"#,
                options: .regularExpression,
            ) != nil
        else {
            return false
        }

        let remainder = input[input.index(after: colonIndex)...]
        if isLikelyBareHostPort(schemeCandidate: schemeCandidate, remainder: remainder) {
            return false
        }

        return true
    }

    private func isLikelyBareHostPort(schemeCandidate: Substring, remainder: Substring) -> Bool {
        guard remainder.first?.isNumber == true else {
            return false
        }

        return schemeCandidate.caseInsensitiveCompare("localhost") == .orderedSame || schemeCandidate.contains(".")
    }

    private func isValidResolvedURL(
        components: URLComponents,
        scheme: String,
        allowSingleLabelHost: Bool,
    ) -> Bool {
        guard components.url != nil else {
            return false
        }

        guard requiresHostValidation(for: scheme) else {
            return true
        }

        guard let host = components.host else {
            return false
        }

        return isValidWebHost(host, allowSingleLabelHost: allowSingleLabelHost)
    }

    private func requiresHostValidation(for scheme: String) -> Bool {
        switch scheme {
        case "http",
             "https":
            true
        default:
            false
        }
    }

    private func isValidWebHost(_ host: String, allowSingleLabelHost: Bool) -> Bool {
        guard !host.isEmpty else {
            return false
        }

        if host.caseInsensitiveCompare("localhost") == .orderedSame {
            return true
        }

        if IPv4Address(host) != nil || IPv6Address(host) != nil {
            return true
        }

        guard !host.hasSuffix(".") else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard
            !labels.isEmpty,
            !labels.contains(where: \.isEmpty),
            allowSingleLabelHost || labels.count > 1,
            labels.allSatisfy(isValidDomainLabel)
        else {
            return false
        }

        if labels.count == 1 {
            return true
        }

        return isKnownPublicSuffixOrRegistrableDomainHost(host)
    }

    private func isValidDomainLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63,
              let first = label.unicodeScalars.first,
              let last = label.unicodeScalars.last,
              isASCIIAlphaNumeric(first),
              isASCIIAlphaNumeric(last)
        else {
            return false
        }

        return label.unicodeScalars.allSatisfy(isDomainLabelCharacter)
    }

    private func isKnownPublicSuffixOrRegistrableDomainHost(_ host: String) -> Bool {
        guard let parsedHost = domainParser.parse(host: host) else {
            return false
        }

        return parsedHost.registrableDomain != nil || parsedHost.publicSuffix
            .caseInsensitiveCompare(host) == .orderedSame
    }

    private func isDomainLabelCharacter(_ scalar: UnicodeScalar) -> Bool {
        isASCIIAlphaNumeric(scalar) || scalar.value == 45
    }

    private func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        isASCIIAlpha(scalar) || isASCIIDigit(scalar)
    }

    private func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 65...90,
             97...122:
            true
        default:
            false
        }
    }

    private func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57:
            true
        default:
            false
        }
    }
}

// MARK: - BrowserInternalURLNormalizer

enum BrowserInternalURLNormalizer {
    // MARK: Internal

    static let canonicalScheme = "openarc"
    static let chromiumScheme = "chrome"
    static let aliasSchemes: Set<String> = [canonicalScheme, chromiumScheme, "arc", "dia"]

    static let settingsHost = "settings"
    static let extensionsHost = "extensions"
    static let historyHost = "history"
    static let passwordManagerHost = "password-manager"
    static let bookmarksHost = "bookmarks"
    static let creditsHost = "credits"
    /// Easels: the engine shows an empty page there and the window draws the canvas.
    static let easelHost = "easel"
    /// Notes open at openarc://notes/<id>; the window draws the note over an empty page.
    static let notesHost = "notes"
    /// Hosts the app serves itself rather than Chromium's internal pages.
    static let appServedHosts: Set<String> = [creditsHost, easelHost, notesHost]

    static func canonicalURLString(for rawURLString: String) -> String? {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return nil
        }

        if trimmedURLString.caseInsensitiveCompare("about:settings") == .orderedSame {
            return "openarc://settings/"
        }

        if trimmedURLString.caseInsensitiveCompare("about:bookmarks") == .orderedSame {
            return "openarc://bookmarks/"
        }

        guard
            var components = URLComponents(string: trimmedURLString),
            let rawScheme = components.scheme?.lowercased(),
            aliasSchemes.contains(rawScheme),
            let rawHost = components.host?.lowercased(),
            !rawHost.isEmpty,
            !appServedHosts.contains(rawHost)
        else {
            return nil
        }

        components.scheme = canonicalScheme
        components.host = rawHost
        if components.path.isEmpty, shouldPreferRootPath(forHost: rawHost) {
            components.path = "/"
        }
        return components.url?.absoluteString
    }

    static func chromiumURLString(forCanonicalURLString urlString: String) -> String? {
        guard
            var components = URLComponents(string: urlString),
            components.scheme?.lowercased() == canonicalScheme,
            let host = components.host?.lowercased(),
            !host.isEmpty,
            !appServedHosts.contains(host)
        else {
            return nil
        }

        components.scheme = chromiumScheme
        components.host = host
        if components.path.isEmpty, shouldPreferRootPath(forHost: host) {
            components.path = "/"
        }
        return components.url?.absoluteString
    }

    static func host(for urlString: String) -> String? {
        guard let canonicalURLString = canonicalURLString(for: urlString) ??
            canonicalURLStringIfAlreadyCanonical(urlString),
            let components = URLComponents(string: canonicalURLString)
        else {
            return nil
        }

        return components.host?.lowercased()
    }

    // MARK: Private

    private static func canonicalURLStringIfAlreadyCanonical(_ urlString: String) -> String? {
        guard
            let components = URLComponents(string: urlString),
            components.scheme?.lowercased() == canonicalScheme,
            let host = components.host,
            !host.isEmpty,
            !appServedHosts.contains(host.lowercased())
        else {
            return nil
        }

        return components.url?.absoluteString
    }

    private static func shouldPreferRootPath(forHost host: String) -> Bool {
        switch host {
        case bookmarksHost,
             extensionsHost,
             settingsHost:
            true
        default:
            false
        }
    }
}

// MARK: - BrowserParsedHost

struct BrowserParsedHost: Equatable {
    let publicSuffix: String
    let registrableDomain: String?
}

// MARK: - BrowserDomainParsing

protocol BrowserDomainParsing: Sendable {
    func parse(host: String) -> BrowserParsedHost?
}

// MARK: - BrowserPublicSuffixDomainParser

struct BrowserPublicSuffixDomainParser: BrowserDomainParsing, @unchecked Sendable {
    // MARK: Internal

    static let shared: any BrowserDomainParsing = {
        do {
            return try BrowserPublicSuffixDomainParser()
        } catch {
            assertionFailure("Failed to initialize DomainParser: \(error)")
            return BrowserNoopDomainParser()
        }
    }()

    // MARK: Private

    private let parser: DomainParser

    init() throws {
        self.parser = try DomainParser()
    }

    func parse(host: String) -> BrowserParsedHost? {
        guard let parsedHost = parser.parse(host: host.lowercased()) else {
            return nil
        }

        return BrowserParsedHost(
            publicSuffix: parsedHost.publicSuffix,
            registrableDomain: parsedHost.domain,
        )
    }
}

// MARK: - BrowserNoopDomainParser

private struct BrowserNoopDomainParser: BrowserDomainParsing {
    func parse(host _: String) -> BrowserParsedHost? {
        nil
    }
}
