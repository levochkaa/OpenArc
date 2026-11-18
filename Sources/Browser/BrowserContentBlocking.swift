// BrowserContentBlocking.swift

import Foundation
import Synchronization

// MARK: - BrowserFilterListKind

/// The filter lists behind the built-in blocker, one per setting.
enum BrowserFilterListKind: String, CaseIterable, Codable {
    case ads
    case trackers
    case cookieBanners

    // MARK: Internal

    /// The list's name, as its authors call it.
    var listName: String {
        switch self {
        case .ads: "EasyList"
        case .trackers: "EasyPrivacy"
        case .cookieBanners: "EasyList Cookie List"
        }
    }

    var downloadURL: URL {
        switch self {
        case .ads: URL(string: "https://easylist.to/easylist/easylist.txt")!
        case .trackers: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
        case .cookieBanners: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!
        }
    }

    /// The copy that ships in the app, used until the first download.
    var bundledResourceName: String {
        switch self {
        case .ads: "filter-list-easylist"
        case .trackers: "filter-list-easyprivacy"
        case .cookieBanners: "filter-list-easylist-cookie"
        }
    }
}

// MARK: - BrowserContentBlockingSettings

/// What the built-in blocker blocks, and the sites where it stays out.
struct BrowserContentBlockingSettings: Codable, Equatable {
    // MARK: Internal

    var blocksAds = true
    var blocksTrackers = true
    var blocksCookieBanners = true
    /// Sites allowed to show ads, by host without `www.`; each covers its subdomains.
    private(set) var allowedSites = [String]()

    var enabledKinds: [BrowserFilterListKind] {
        BrowserFilterListKind.allCases.filter(blocks)
    }

    var isEnabled: Bool { !enabledKinds.isEmpty }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.blocksAds = try container.decodeIfPresent(Bool.self, forKey: .blocksAds) ?? true
        self.blocksTrackers = try container.decodeIfPresent(Bool.self, forKey: .blocksTrackers) ?? true
        self.blocksCookieBanners = try container.decodeIfPresent(Bool.self, forKey: .blocksCookieBanners) ?? true
        self.allowedSites = try container.decodeIfPresent([String].self, forKey: .allowedSites) ?? []
    }

    /// The site a page's allowance is kept under: its host without `www.`.
    /// Nil for pages that are not on the web.
    static func siteKey(forURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www."), host.count > 4 {
            host.removeFirst(4)
        }
        return host
    }

    func blocks(_ kind: BrowserFilterListKind) -> Bool {
        switch kind {
        case .ads: blocksAds
        case .trackers: blocksTrackers
        case .cookieBanners: blocksCookieBanners
        }
    }

    mutating func setBlocks(_ kind: BrowserFilterListKind, _ on: Bool) {
        switch kind {
        case .ads: blocksAds = on
        case .trackers: blocksTrackers = on
        case .cookieBanners: blocksCookieBanners = on
        }
    }

    /// The allowed site that covers the host, if any.
    func allowedSite(coveringHost host: String) -> String? {
        let host = host.lowercased()
        return allowedSites.first { BrowserFilterDomains.host(host, isOrIsSubdomainOf: $0) }
    }

    func isAllowed(urlString: String) -> Bool {
        guard !allowedSites.isEmpty,
              let host = BrowserFilterRequest.host(ofURLString: urlString) else { return false }
        return allowedSite(coveringHost: host) != nil
    }

    /// Allows ads on the page's site, or blocks them again there, also when
    /// an allowance for a parent domain covered it.
    mutating func setAllowed(_ allowed: Bool, urlString: String) {
        guard let site = Self.siteKey(forURLString: urlString) else { return }
        if allowed {
            guard allowedSite(coveringHost: site) == nil else { return }
            allowedSites.append(site)
            allowedSites.sort()
        } else {
            allowedSites.removeAll { BrowserFilterDomains.host(site, isOrIsSubdomainOf: $0) }
        }
    }

    mutating func removeAllowedSite(_ site: String) {
        allowedSites.removeAll { $0 == site }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case blocksAds
        case blocksTrackers
        case blocksCookieBanners
        case allowedSites
    }
}

// MARK: - BrowserContentBlocker

/// The blocker both page engines ask: the settings and a ready engine per
/// filter list. Chromium asks from its network thread, so it is safe from any thread.
final class BrowserContentBlocker: Sendable {
    // MARK: Internal

    static let shared = BrowserContentBlocker()

    var settings: BrowserContentBlockingSettings {
        state.withLock(\.settings)
    }

    func update(settings: BrowserContentBlockingSettings) {
        state.withLock {
            guard $0.settings != settings else { return }
            $0.settings = settings
            $0.hidingScripts.removeAll()
        }
    }

    func install(_ engine: BrowserFilterEngine?, for kind: BrowserFilterListKind) {
        state.withLock {
            $0.engines[kind] = engine
            $0.hidingScripts.removeAll()
        }
    }

    func hasEngine(for kind: BrowserFilterListKind) -> Bool {
        state.withLock { $0.engines[kind] != nil }
    }

    /// Whether a page's request should not load. `documentURLString` is the
    /// tab's page, whose site may be allowed; requests of pages that are not
    /// on the web, such as the browser's own, always load.
    func shouldBlock(
        urlString: String,
        sourceURLString: String?,
        documentURLString: String,
        type: BrowserFilterResourceTypes,
    ) -> Bool {
        let (settings, engines) = state.withLock { state in
            (state.settings, state.settings.enabledKinds.compactMap { state.engines[$0] })
        }
        guard !engines.isEmpty,
              BrowserFilterRequest.host(ofURLString: documentURLString) != nil,
              !settings.isAllowed(urlString: documentURLString),
              let request = BrowserFilterRequest(urlString: urlString, sourceURLString: sourceURLString, type: type)
        else { return false }
        return engines.contains { $0.blocks(request, documentURLString: documentURLString) }
    }

    /// CSS that hides the lists' elements in a frame. A frame inside a page
    /// gets only the rules written for its site.
    func hidingStyleSheet(frameURLString: String, documentURLString: String, isMainFrame: Bool) -> String {
        let (settings, engines) = state.withLock { state in
            (state.settings, state.settings.enabledKinds.compactMap { state.engines[$0] })
        }
        guard !engines.isEmpty, !settings.isAllowed(urlString: documentURLString) else { return "" }
        return engines.map {
            $0.hidingStyleSheet(forDocumentURLString: frameURLString, includesGeneric: isMainFrame)
        }.joined()
    }

    /// A script that adds the hiding CSS to a new document, or nil when it hides nothing.
    func hidingScript(frameURLString: String, documentURLString: String, isMainFrame: Bool) -> String? {
        guard let host = BrowserFilterRequest.host(ofURLString: frameURLString),
              !settings.isAllowed(urlString: documentURLString) else { return nil }
        // The lists name sites, so pages of one host share their CSS.
        let key = "\(isMainFrame ? "main" : "frame") \(host)"
        if let cached = state.withLock({ $0.hidingScripts[key] }) {
            return cached.isEmpty ? nil : cached
        }
        let css = hidingStyleSheet(
            frameURLString: frameURLString,
            documentURLString: documentURLString,
            isMainFrame: isMainFrame,
        )
        let script = css.isEmpty ? "" : Self.script(addingStyleSheet: css)
        state.withLock {
            if $0.hidingScripts.count > 64 {
                $0.hidingScripts.removeAll()
            }
            $0.hidingScripts[key] = script
        }
        return script.isEmpty ? nil : script
    }

    /// Adds the CSS as an adopted style sheet, which the page's own markup
    /// and content security policy leave alone.
    static func script(addingStyleSheet css: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: css, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        let literal = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        (function(){var css=\(literal);try{var sheet=new CSSStyleSheet();sheet.replaceSync(css);\
        document.adoptedStyleSheets=document.adoptedStyleSheets.concat([sheet]);}catch(e){\
        var add=function(){var style=document.createElement('style');style.textContent=css;\
        (document.head||document.documentElement).appendChild(style);};\
        if(document.documentElement)add();else document.addEventListener('readystatechange',add,{once:true});}})();
        """
    }

    // MARK: Private

    private struct State {
        var settings = BrowserContentBlockingSettings()
        var engines = [BrowserFilterListKind: BrowserFilterEngine]()
        /// Recent hiding scripts by frame; an empty one hides nothing.
        var hidingScripts = [String: String]()
    }

    private let state = Mutex(State())
}

// MARK: - BrowserContentBlockingBridge

/// The blocker for the Chromium engine's Objective-C++ side.
@objc final class BrowserContentBlockingBridge: NSObject {
    /// Chromium's resource types, as `cef_resource_type_t` numbers them.
    static func resourceType(forEngineType type: Int) -> BrowserFilterResourceTypes? {
        switch type {
        case 1,
             20: .subdocument
        case 2: .stylesheet
        case 3,
             9,
             10,
             15: .script
        case 4,
             12: .image
        case 5: .font
        case 7,
             17: .object
        case 8: .media
        case 13: .xmlHTTPRequest
        case 14,
             16: .ping
        case 6,
             11: .other
        default: nil
        }
    }

    /// Called on the engine's network thread for each request a page makes.
    @objc static func shouldBlockRequest(
        _ urlString: String,
        sourceURLString: String?,
        documentURLString: String,
        resourceType: Int,
    ) -> Bool {
        guard let type = Self.resourceType(forEngineType: resourceType) else { return false }
        return BrowserContentBlocker.shared.shouldBlock(
            urlString: urlString,
            sourceURLString: sourceURLString,
            documentURLString: documentURLString,
            type: type,
        )
    }

    @objc static func hidingScript(
        forFrameURLString frameURLString: String,
        documentURLString: String,
        isMainFrame: Bool,
    ) -> String? {
        BrowserContentBlocker.shared.hidingScript(
            frameURLString: frameURLString,
            documentURLString: documentURLString,
            isMainFrame: isMainFrame,
        )
    }
}
