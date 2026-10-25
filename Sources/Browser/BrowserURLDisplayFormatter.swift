// BrowserURLDisplayFormatter.swift

import Foundation
import Network

enum BrowserURLDisplayFormatter {
    // MARK: Internal

    static func displayString(for urlString: String) -> String {
        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return BrowserStrings.newTabTitle
        }

        guard
            let components = URLComponents(string: trimmedURLString),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty
        else {
            return fallbackDisplayString(for: trimmedURLString)
        }

        let displayHost = hostDisplayString(forHost: host)

        if let port = components.port, shouldDisplayPort(port, for: scheme, host: displayHost) {
            let displayHostWithPort = displayHostForPort(displayHost)
            return "\(displayHostWithPort):\(port)"
        }

        return displayHost
    }

    static func fullDisplayString(for urlString: String) -> String {
        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return BrowserStrings.newTabTitle
        }

        guard
            var components = URLComponents(string: trimmedURLString),
            let host = components.host,
            !host.isEmpty
        else {
            return fallbackDisplayString(for: trimmedURLString)
        }

        let displayHost = hostDisplayString(forHost: host)
        guard displayHost != host else {
            return trimmedURLString
        }

        components.host = displayHost
        return components.url?.absoluteString ?? trimmedURLString
    }

    static func hostDisplayString(forHost host: String) -> String {
        guard host.count > 4, host.lowercased().hasPrefix("www.") else {
            return host
        }

        return String(host.dropFirst(4))
    }

    // MARK: Private

    private static func fallbackDisplayString(for urlString: String) -> String {
        guard urlString.count > 4, urlString.lowercased().hasPrefix("www.") else {
            return urlString
        }

        return String(urlString.dropFirst(4))
    }

    private static func displayHostForPort(_ host: String) -> String {
        guard let ipv6Host = ipv6AddressHost(host) else {
            return host
        }

        return "[\(ipv6Host)]"
    }

    private static func shouldDisplayPort(_ port: Int, for scheme: String, host: String) -> Bool {
        isLocalHostOrIPAddress(host) || isNonDefaultPort(port, for: scheme)
    }

    private static func isNonDefaultPort(_ port: Int, for scheme: String) -> Bool {
        switch scheme {
        case "http":
            port != 80
        case "https":
            port != 443
        default:
            false
        }
    }

    private static func isLocalHostOrIPAddress(_ host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame
            || IPv4Address(host) != nil
            || ipv6AddressHost(host) != nil
    }

    private static func ipv6AddressHost(_ host: String) -> String? {
        let unbracketedHost =
            if host.hasPrefix("["), host.hasSuffix("]") {
                String(host.dropFirst().dropLast())
            } else {
                host
            }
        guard IPv6Address(unbracketedHost) != nil else {
            return nil
        }

        return unbracketedHost
    }
}
