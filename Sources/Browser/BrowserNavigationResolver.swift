import Foundation
import Network

struct BrowserNavigationResolver {
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
            resolvedURLString: googleSearchURLString(for: trimmedInput)
        )
    }

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
        input.range(
            of: #"^[A-Za-z][A-Za-z0-9+\-.]*:"#,
            options: .regularExpression
        ) != nil
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
            return true
        default:
            return false
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

        guard let topLevelLabel = labels.last else {
            return false
        }

        if labels.count == 1 {
            return true
        }

        return isValidTopLevelDomainLabel(topLevelLabel)
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

    private func isValidTopLevelDomainLabel(_ label: Substring) -> Bool {
        let lowercasedLabel = label.lowercased()
        if lowercasedLabel.hasPrefix("xn--") {
            return lowercasedLabel.count > 4 && isValidDomainLabel(Substring(lowercasedLabel))
        }

        return label.count >= 2 && label.unicodeScalars.allSatisfy(isASCIIAlpha)
    }

    private func isDomainLabelCharacter(_ scalar: UnicodeScalar) -> Bool {
        isASCIIAlphaNumeric(scalar) || scalar.value == 45
    }

    private func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        isASCIIAlpha(scalar) || isASCIIDigit(scalar)
    }

    private func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 65 ... 90, 97 ... 122:
            return true
        default:
            return false
        }
    }

    private func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48 ... 57:
            return true
        default:
            return false
        }
    }

    private func googleSearchURLString(for query: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url?.absoluteString ?? "https://www.google.com/search?q=\(query)"
    }
}
