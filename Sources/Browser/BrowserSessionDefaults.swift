// BrowserSessionDefaults.swift

import Foundation

/// Stable shared identities must not depend on either platform's browser model; the Rust core holds them.
enum BrowserSessionDefaults {
    static let defaultSpaceID = coreDefaultSpaceId()
    static let defaultSpaceIconName = coreDefaultSpaceIcon()
}
