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

        var displayHost = host
        if displayHost.lowercased().hasPrefix("www.") {
            displayHost.removeFirst(4)
        }

        if let port = components.port, shouldDisplayPort(port, for: scheme, host: displayHost) {
            let displayHostWithPort = displayHostForPort(displayHost)
            return "\(displayHostWithPort):\(port)"
        }

        return displayHost
    }

    // MARK: Private

    private static func fallbackDisplayString(for urlString: String) -> String {
        urlString
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
