// BrowserNavigationResolver.swift

import Foundation

// MARK: - BrowserNavigationResolver

/// What the address bar does with typed text. The Rust core decides (`Core/openarc-core/src/web/navigation.rs`).
struct BrowserNavigationResolver {
    // MARK: Internal

    enum Kind: Equatable {
        case url
        case search
    }

    struct Resolution: Equatable {
        let kind: Kind
        let displayText: String
        let resolvedURLString: String
    }

    // MARK: Private

    private let searchEngineProvider: () -> BrowserSearchEngine

    init(searchEngineProvider: @escaping () -> BrowserSearchEngine = { .google }) {
        self.searchEngineProvider = searchEngineProvider
    }

    /// Hosts that only make sense on this machine or network: localhost, any
    /// `.localhost` or `.local` name, and IP addresses.
    static func isLocalHost(_ host: String) -> Bool {
        coreIsLocalHost(host: host)
    }

    func resolve(_ rawInput: String) -> Resolution? {
        guard let resolution = coreResolveNavigation(input: rawInput, searchEngine: searchEngineProvider().coreEngine)
        else {
            return nil
        }
        return Resolution(
            kind: resolution.kind == .url ? .url : .search,
            displayText: resolution.displayText,
            resolvedURLString: resolution.resolvedUrl,
        )
    }
}

// MARK: - BrowserInternalURLNormalizer

/// Internal pages live at `openarc://` addresses; `chrome://`, `arc://` and `dia://` are aliases. The Rust core maps
/// them (`Core/openarc-core/src/web/internal_urls.rs`).
enum BrowserInternalURLNormalizer {
    // MARK: Internal

    static let canonicalScheme = "openarc"
    static let chromiumScheme = "chrome"

    static let settingsHost = "settings"
    static let extensionsHost = "extensions"
    static let historyHost = "history"
    static let passwordManagerHost = "password-manager"
    static let bookmarksHost = "bookmarks"
    static let creditsHost = "credits"
    /// Easels: the engine shows an empty page there and the window draws the canvas.
    static let easelHost = "easel"
    /// Notes open at openarc://notes/<id>; the window draws the note over an empty page.
    static let notesHost = "notes"

    static func canonicalURLString(for rawURLString: String) -> String? {
        coreCanonicalInternalUrl(url: rawURLString)
    }

    static func chromiumURLString(forCanonicalURLString urlString: String) -> String? {
        coreChromiumInternalUrl(canonicalUrl: urlString)
    }

    static func host(for urlString: String) -> String? {
        coreInternalUrlHost(url: urlString)
    }
}

// MARK: - BrowserChromeEngineInternalURLs

/// On Chrome's engine, `openarc://` addresses of Chromium's pages load Chromium's own page and show under
/// `openarc://` again, as CEF's tabs do. openarc://credits is the engine's own chrome://credits there; the engine
/// serves OpenArc's other addresses (Easels, notes) itself.
@objc final class BrowserChromeEngineInternalURLs: NSObject {
    /// The address a Chrome engine page loads for `urlString`.
    @objc(loadURLStringFor:) static func loadURLString(for urlString: String) -> String {
        coreChromeEngineLoadUrl(url: urlString)
    }

    /// The address a Chrome engine page shows for the `urlString` it committed.
    @objc(displayURLStringFor:) static func displayURLString(for urlString: String) -> String {
        coreChromeEngineDisplayUrl(url: urlString)
    }
}

// MARK: - BrowserParsedHost

struct BrowserParsedHost: Equatable {
    let publicSuffix: String
    let registrableDomain: String?
}

// MARK: - BrowserDomainParsing

protocol BrowserDomainParsing: Sendable {
    func parse(host: String) -> BrowserParsedHost?
}

// MARK: - BrowserPublicSuffixDomainParser

/// The Public Suffix List, from the Rust core (`Core/openarc-core/src/web/domain.rs`).
struct BrowserPublicSuffixDomainParser: BrowserDomainParsing {
    static let shared: any BrowserDomainParsing = BrowserPublicSuffixDomainParser()

    func parse(host: String) -> BrowserParsedHost? {
        coreParseHost(host: host).map {
            BrowserParsedHost(publicSuffix: $0.publicSuffix, registrableDomain: $0.registrableDomain)
        }
    }
}
