import Foundation
import Network

enum BrowserURLDisplayFormatter {
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

        if shouldDisplayPort(for: displayHost), let port = components.port {
            return "\(displayHost):\(port)"
        }

        return displayHost
    }

    private static func fallbackDisplayString(for urlString: String) -> String {
        urlString
    }

    private static func shouldDisplayPort(for host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame
            || IPv4Address(host) != nil
            || IPv6Address(host) != nil
    }
}
