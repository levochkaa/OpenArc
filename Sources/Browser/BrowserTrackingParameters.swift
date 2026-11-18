// BrowserTrackingParameters.swift

import Foundation

// MARK: - BrowserTrackingParameters

/// Query parameters that only tell a site or an ad network where a click came
/// from. Copy URL leaves them out, so a shared link carries the page alone.
enum BrowserTrackingParameters {
    // MARK: Private

    private static let names: Set = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "vero_conv",
        "oly_anon_id", "oly_enc_id", "rb_clickid", "_openstat", "epik", "srsltid", "ref_src", "ref_url",
        "spm", "scm", "_ga", "_gl",
    ]

    /// Share IDs that some sites add to every link copied from their share button.
    private static let shareNamesByHost: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature"],
        "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si"],
        "x.com": ["s", "t"],
        "twitter.com": ["s", "t"],
        "instagram.com": ["igsh", "img_index"],
    ]

    // MARK: Internal

    /// The address without tracking parameters; any other address as it was.
    static func cleaned(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let items = components.percentEncodedQueryItems, !items.isEmpty
        else { return urlString }
        let host = components.host?.lowercased() ?? ""
        let kept = items.filter { !isTracking($0.name, host: host) }
        guard kept.count != items.count else { return urlString }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string ?? urlString
    }

    private static func isTracking(_ name: String, host: String) -> Bool {
        let name = name.lowercased()
        if name.hasPrefix("utm_") || names.contains(name) { return true }
        return shareNamesByHost.contains { site, shareNames in
            (host == site || host.hasSuffix("." + site)) && shareNames.contains(name)
        }
    }
}
