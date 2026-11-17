// BrowserPageEngines.swift

import Foundation

// MARK: - BrowserPageEngine

/// The engine that shows a tab's page.
@objc enum BrowserPageEngine: Int {
    case chromium
    case webKit
}

extension BrowserPageEngine {
    var key: String {
        switch self {
        case .webKit: "webkit"
        case .chromium: "chromium"
        }
    }

    init?(key: String) {
        switch key {
        case "chromium": self = .chromium
        case "webkit": self = .webKit
        default: return nil
        }
    }
}

// MARK: - BrowserPageEnginePolicy

/// Which engine a site opens in. Streaming sites play protected video only
/// with FairPlay, which Chromium lacks, so they open in WebKit, unless the
/// FairPlay bridge plays them in Chromium or the user set a rule for the site.
@objc final class BrowserPageEnginePolicy: NSObject {
    // MARK: Internal

    enum Key {
        static let opensStreamingSitesInWebKit = "browser.settings.opensStreamingSitesInWebKit"
        static let playsProtectedMediaInChromium = "browser.settings.playsProtectedMediaInChromium"
        static let siteEngines = "browser.settings.siteEngines"
    }

    /// Registrable domains of streaming sites, matched with their subdomains over https.
    static let streamingDomains = [
        "netflix.com",
        "disneyplus.com",
        "max.com",
        "hbomax.com",
        "primevideo.com",
        "hulu.com",
        "tv.apple.com",
        "music.apple.com",
        "peacocktv.com",
        "paramountplus.com",
        "crunchyroll.com",
        "hotstar.com",
        "jiohotstar.com",
        "v.qq.com",
    ]

    /// Origins the FairPlay bridge plays in Chromium.
    static let fairPlayOrigins = [
        "https://open.spotify.com",
        "https://www.netflix.com",
        "https://www.disneyplus.com",
    ]

    /// Posted on the main thread when a setting or a site's rule changes, so open
    /// pages move to the engine they now belong in.
    @objc static let didChangeNotification = Notification.Name("BrowserPageEnginePolicyDidChange")

    nonisolated(unsafe) static var userDefaults = UserDefaults.standard

    static var opensStreamingSitesInWebKit: Bool {
        get { userDefaults.object(forKey: Key.opensStreamingSitesInWebKit) as? Bool ?? true }
        set {
            userDefaults.set(newValue, forKey: Key.opensStreamingSitesInWebKit)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    @objc static var playsProtectedMediaInChromium: Bool {
        get { userDefaults.bool(forKey: Key.playsProtectedMediaInChromium) }
        set {
            userDefaults.set(newValue, forKey: Key.playsProtectedMediaInChromium)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Engines the user chose for sites, by site origin.
    static var siteEngines: [String: BrowserPageEngine] {
        get {
            let stored = userDefaults.dictionary(forKey: Key.siteEngines) as? [String: String] ?? [:]
            return stored.compactMapValues(BrowserPageEngine.init(key:))
        }
        set { userDefaults.set(newValue.mapValues(\.key), forKey: Key.siteEngines) }
    }

    /// `scheme://host[:port]`, lowercased, for http and https pages; nil otherwise.
    @objc static func site(forURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func isStreamingSite(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else { return false }
        return streamingDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    @objc static func isFairPlaySite(_ urlString: String) -> Bool {
        site(forURLString: urlString).map(fairPlayOrigins.contains) ?? false
    }

    /// The bridge plays this page's protected media in Chromium.
    @objc static func bridgesFairPlay(forURLString urlString: String) -> Bool {
        playsProtectedMediaInChromium && isFairPlaySite(urlString)
    }

    /// The engine the user chose for the page's site, if any.
    static func rule(forURLString urlString: String) -> BrowserPageEngine? {
        site(forURLString: urlString).flatMap { siteEngines[$0] }
    }

    @objc static func hasRule(forURLString urlString: String) -> Bool {
        rule(forURLString: urlString) != nil
    }

    /// The engine a page opens in when the app loads it: typed, restored or opened.
    @objc static func engine(forURLString urlString: String) -> BrowserPageEngine {
        if let rule = rule(forURLString: urlString) {
            return rule
        }
        let streaming = isStreamingSite(urlString) || isFairPlaySite(urlString)
        if streaming, opensStreamingSitesInWebKit, !bridgesFairPlay(forURLString: urlString) {
            return .webKit
        }
        return .chromium
    }

    /// Saves the engine for the page's site; nil removes the rule.
    @objc static func setEngine(_ engine: BrowserPageEngine, forURLString urlString: String) {
        guard let site = site(forURLString: urlString) else { return }
        var engines = siteEngines
        engines[site] = engine
        siteEngines = engines
    }

    static func resetSiteEngines() {
        siteEngines = [:]
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    @objc static func removeRule(forURLString urlString: String) {
        guard let site = site(forURLString: urlString) else { return }
        var engines = siteEngines
        engines[site] = nil
        siteEngines = engines
    }
}
