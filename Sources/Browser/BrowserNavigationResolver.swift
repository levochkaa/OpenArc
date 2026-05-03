import DomainParser
import Foundation
import Network

// MARK: - BrowserNavigationResolver

struct BrowserNavigationResolver {
    // MARK: Lifecycle

    init(
        domainParser: any BrowserDomainParsing = BrowserPublicSuffixDomainParser.shared,
        searchEngineProvider: @escaping () -> BrowserSearchEngine = { .google }
    ) {
        self.domainParser = domainParser
        self.searchEngineProvider = searchEngineProvider
    }

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

    func resolve(_ rawInput: String) -> Resolution? {
        let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        if let resolvedURLString = resolvedURLString(for: trimmedInput) {
            return Resolution(
                kind: .url,
                displayText: trimmedInput,
                resolvedURLString: resolvedURLString
            )
        }

        return Resolution(
            kind: .search,
            displayText: trimmedInput,
            resolvedURLString: searchEngineProvider().searchURLString(for: trimmedInput)
        )
    }

    // MARK: Private

    private let domainParser: any BrowserDomainParsing
    private let searchEngineProvider: () -> BrowserSearchEngine

    private func resolvedURLString(for input: String) -> String? {
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
                options: .regularExpression
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
        allowSingleLabelHost: Bool
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
        case "http", "https":
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
        guard !label.isEmpty, label.count <= 63 else {
            return false
        }

        guard
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
        case 65...90, 97...122:
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

// MARK: - BrowserParsedHost

struct BrowserParsedHost: Equatable {
    let publicSuffix: String
    let registrableDomain: String?
}

// MARK: - BrowserDomainParsing

protocol BrowserDomainParsing {
    func parse(host: String) -> BrowserParsedHost?
}

// MARK: - BrowserPublicSuffixDomainParser

struct BrowserPublicSuffixDomainParser: BrowserDomainParsing {
    // MARK: Lifecycle

    init() throws {
        self.parser = try DomainParser()
    }

    // MARK: Internal

    static let shared: any BrowserDomainParsing = {
        do {
            return try BrowserPublicSuffixDomainParser()
        } catch {
            assertionFailure("Failed to initialize DomainParser: \(error)")
            return BrowserNoopDomainParser()
        }
    }()

    func parse(host: String) -> BrowserParsedHost? {
        guard let parsedHost = parser.parse(host: host.lowercased()) else {
            return nil
        }

        return BrowserParsedHost(
            publicSuffix: parsedHost.publicSuffix,
            registrableDomain: parsedHost.domain
        )
    }

    // MARK: Private

    private let parser: DomainParser
}

// MARK: - BrowserNoopDomainParser

private struct BrowserNoopDomainParser: BrowserDomainParsing {
    func parse(host _: String) -> BrowserParsedHost? {
        nil
    }
}
