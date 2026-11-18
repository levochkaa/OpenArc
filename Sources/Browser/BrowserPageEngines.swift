// BrowserPageEngines.swift

import Foundation
import os

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

/// Which engine a site opens in. Chromium has a Widevine CDM but no VMP
/// signature, so license servers that check the browser refuse it: a page whose
/// protected video fails in Chromium moves to WebKit, which plays it with
/// FairPlay, and its site keeps opening there. The FairPlay bridge and the
/// user's rules for sites win over that.
@objc final class BrowserPageEnginePolicy: NSObject {
    // MARK: Internal

    enum Key {
        static let movesProtectedVideoToWebKit = "browser.settings.opensStreamingSitesInWebKit"
        static let playsProtectedMediaInChromium = "browser.settings.playsProtectedMediaInChromium"
        static let siteEngines = "browser.settings.siteEngines"
        static let protectedVideoSites = "browser.settings.protectedVideoSites"
    }

    /// Registrable domains of streaming sites, matched with their subdomains over
    /// https. They open in WebKit right away: in Chromium they would first load,
    /// ask for a license and fail, which takes seconds and may show the site's
    /// error page. Other sites move after such a failure (`protectedVideoSites`).
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

    /// Origins the FairPlay bridges play in Chromium: Spotify's audio (the
    /// renderer's `BridgesFairPlay`) and the video sites (`BridgesProtectedVideo`).
    static let fairPlayOrigins = [
        "https://open.spotify.com",
        "https://www.netflix.com",
        "https://www.disneyplus.com",
    ]

    /// Posted on the main thread when a setting or a site's rule changes, so open
    /// pages move to the engine they now belong in.
    @objc static let didChangeNotification = Notification.Name("BrowserPageEnginePolicyDidChange")

    nonisolated(unsafe) static var userDefaults = UserDefaults.standard

    /// Pages whose protected video fails in Chromium move to WebKit without
    /// asking, and streaming sites open there; off, such a page offers WebKit.
    static var movesProtectedVideoToWebKit: Bool {
        get { userDefaults.object(forKey: Key.movesProtectedVideoToWebKit) as? Bool ?? true }
        set {
            userDefaults.set(newValue, forKey: Key.movesProtectedVideoToWebKit)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Sites whose protected video failed in Chromium, by site origin. They open
    /// in WebKit while `movesProtectedVideoToWebKit` is on.
    static var protectedVideoSites: Set<String> {
        get { Set(userDefaults.stringArray(forKey: Key.protectedVideoSites) ?? []) }
        set { userDefaults.set(newValue.sorted(), forKey: Key.protectedVideoSites) }
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

    /// A streaming site, a site the FairPlay bridge serves, or one whose
    /// protected video failed in Chromium before.
    static func isProtectedVideoSite(_ urlString: String) -> Bool {
        isStreamingSite(urlString) || isFairPlaySite(urlString)
            || site(forURLString: urlString).map(protectedVideoSites.contains) ?? false
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
        if isProtectedVideoSite(urlString), movesProtectedVideoToWebKit, !bridgesFairPlay(forURLString: urlString) {
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
        protectedVideoSites = []
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    @objc static func removeRule(forURLString urlString: String) {
        guard let site = site(forURLString: urlString) else { return }
        var engines = siteEngines
        engines[site] = nil
        siteEngines = engines
    }
}

// MARK: - BrowserProtectedMediaFailure

/// Why the renderer's observer reports a page's protected video as failed in
/// Chromium (`kProtectedMediaObserverScript`).
enum BrowserProtectedMediaFailure: String {
    /// `createMediaKeys` failed, or every `requestMediaKeySystemAccess` for a
    /// protected key system was refused.
    case accessRefused = "access"
    /// `generateRequest` failed: the CDM made no license request.
    case requestFailed = "request"
    /// `update` refused the license the page fetched.
    case licenseRefused = "license"
    /// A license request got no usable key in time: the license server refused it.
    case licenseTimedOut = "license-timeout"
    /// A key's status became `internal-error`.
    case keyError = "key-error"
    /// Every key's status is `output-restricted`.
    case outputRestricted = "output-restricted"
    /// `setMediaKeys` failed on a media element.
    case mediaKeysRefused = "media-keys"
    /// A media element with keys failed to decode.
    case playbackFailed = "playback"
}

// MARK: - BrowserProtectedMediaAction

/// What a failed protected video does to its Chromium page.
@objc enum BrowserProtectedMediaAction: Int {
    case ignore
    /// A prompt offers WebKit.
    case offer
    /// The page moves to WebKit, and its site is remembered.
    case moveToWebKit

    var name: String {
        switch self {
        case .ignore: "ignore"
        case .offer: "offer"
        case .moveToWebKit: "move to WebKit"
        }
    }
}

extension BrowserPageEnginePolicy {
    /// Key systems Chromium may fail: Widevine and PlayReady, which license
    /// servers refuse without a VMP signature, and FairPlay, which Chromium lacks.
    static func isProtectedKeySystem(_ keySystem: String) -> Bool {
        ["com.widevine.alpha", "com.microsoft.playready", "com.apple.fps"].contains { keySystem.hasPrefix($0) }
    }

    /// The action for a page whose protected video failed in Chromium. Pages
    /// without protected video never get here: every report needs a key system
    /// the page asked for and, in the renderer, a video on the page.
    @objc static func protectedMediaAction(
        forURLString urlString: String,
        keySystem: String,
        reason: String,
        notAskedAgain: Set<String>,
    ) -> BrowserProtectedMediaAction {
        let action = decideProtectedMediaAction(
            forURLString: urlString,
            keySystem: keySystem,
            reason: reason,
            notAskedAgain: notAskedAgain,
        )
        protectedMediaLog.info(
            "Protected media failed (\(reason, privacy: .public), \(keySystem, privacy: .public)): \(action.name, privacy: .public)",
        )
        return action
    }

    static func decideProtectedMediaAction(
        forURLString urlString: String,
        keySystem: String,
        reason: String,
        notAskedAgain: Set<String>,
    ) -> BrowserProtectedMediaAction {
        guard BrowserProtectedMediaFailure(rawValue: reason) != nil, isProtectedKeySystem(keySystem),
              let site = site(forURLString: urlString),
              // The bridge refuses Widevine on purpose, so the site asks for FairPlay instead.
              !bridgesFairPlay(forURLString: urlString),
              rule(forURLString: urlString) == nil, !notAskedAgain.contains(site) else { return .ignore }
        return movesProtectedVideoToWebKit ? .moveToWebKit : .offer
    }

    /// Opens the page's site in WebKit from now on, while
    /// `movesProtectedVideoToWebKit` is on, and moves its other open pages.
    @objc static func rememberProtectedVideoSite(forURLString urlString: String) {
        guard let site = site(forURLString: urlString), !protectedVideoSites.contains(site) else { return }
        protectedVideoSites.insert(site)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

private let protectedMediaLog = Logger(subsystem: "com.levochkaa.OpenArc", category: "ProtectedVideo")
