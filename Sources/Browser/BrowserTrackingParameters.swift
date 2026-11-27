// BrowserTrackingParameters.swift

import Foundation

// MARK: - BrowserTrackingParameters

/// Query parameters that only tell a site or an ad network where a click came
/// from. Copy URL leaves them out, so a shared link carries the page alone. The
/// Rust core keeps the list (`Core/openarc-core/src/web/tracking.rs`).
enum BrowserTrackingParameters {
    /// The address without tracking parameters; any other address as it was.
    static func cleaned(_ urlString: String) -> String {
        coreRemoveTrackingParameters(url: urlString)
    }
}
