// BrowserMobileAppLink.swift

import Foundation

/// What the Home Screen widget opens the app to do, as `openarc://` links
/// the scene receives.
enum BrowserMobileAppLink: String, CaseIterable, Sendable {
    /// Search in a new tab, the keyboard up.
    case search
    /// Search in a new tab by voice.
    case voiceSearch = "voice-search"
    /// A new tab, its search open.
    case newTab = "new-tab"

    // MARK: Internal

    static let scheme = "openarc"

    var url: URL {
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        self.init(rawValue: host)
    }
}
