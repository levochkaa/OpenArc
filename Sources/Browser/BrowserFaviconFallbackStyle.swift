// BrowserFaviconFallbackStyle.swift

import Foundation

enum BrowserFaviconFallbackStyle: Equatable {
    case globe
    case chromiumWebUI

    // MARK: Internal

    static func style(forPageURLString pageURLString: String?) -> Self {
        guard
            let pageURLString,
            BrowserInternalURLNormalizer.host(for: pageURLString) != nil
        else {
            return .globe
        }

        return .chromiumWebUI
    }

    /// The symbol an internal page shows as its icon, as Chromium draws its own
    /// pages: a clock for History, a gear for Settings. Nil keeps the generic one.
    static func webUISymbol(forPageURLString pageURLString: String?) -> String? {
        guard let pageURLString, let host = BrowserInternalURLNormalizer.host(for: pageURLString) else { return nil }
        return switch host {
        case "history": "clock.arrow.circlepath"
        case "settings": "gearshape.fill"
        case "downloads": "arrow.down.to.line"
        case "bookmarks": "star.fill"
        default: nil
        }
    }
}
