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
}
