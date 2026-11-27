// BrowserURLDisplayFormatter.swift

import Foundation

/// How the toolbar and the sidebar show an address. The Rust core formats it
/// (`Core/openarc-core/src/web/display.rs`); a blank address shows the new tab title.
enum BrowserURLDisplayFormatter {
    static func displayString(for urlString: String) -> String {
        coreUrlDisplayString(url: urlString) ?? BrowserStrings.newTabTitle
    }

    static func fullDisplayString(for urlString: String) -> String {
        coreUrlFullDisplayString(url: urlString) ?? BrowserStrings.newTabTitle
    }

    static func hostDisplayString(forHost host: String) -> String {
        coreHostDisplayString(host: host)
    }
}
