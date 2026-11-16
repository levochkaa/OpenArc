// BrowserExternalAppLauncher.swift

import AppKit

// MARK: - BrowserExternalAppLauncher

/// A page's link to an app, such as `slack://` or `zoommtg://`, opens that app instead of
/// an error page.
@MainActor @objc final class BrowserExternalAppLauncher: NSObject {
    // MARK: Internal

    @objc static let shared = BrowserExternalAppLauncher()

    /// Schemes the browser loads itself; the rest belong to apps.
    nonisolated static let browserSchemes: Set = [
        "about", "arc", "blob", "chrome", "chrome-error", "chrome-extension", "chrome-search",
        "chrome-untrusted", "data", "devtools", "file", "filesystem", "ftp", "http", "https",
        "isolated-app", "javascript", "openarc", "openarc-auth", "view-source", "ws", "wss",
    ]

    /// A page that keeps sending app links opens at most one this often.
    static let minimumInterval: TimeInterval = 1

    // MARK: Private

    private let appURL: @MainActor (URL) -> URL?
    private let open: @MainActor (URL) -> Void
    private let now: @MainActor () -> Date
    private var lastOpenedAt = [ObjectIdentifier?: Date]()

    init(
        appURL: @escaping @MainActor (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        now: @escaping @MainActor () -> Date = Date.init,
    ) {
        self.appURL = appURL
        self.open = open
        self.now = now
    }

    /// Whether `urlString` belongs to an app other than the browser.
    @objc func handles(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              !Self.browserSchemes.contains(scheme), let app = appURL(url)
        else { return false }
        return app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
    }

    /// Opens the link's app. `window` keeps one page from opening apps in a loop.
    @objc func open(_ urlString: String, in window: NSWindow?) {
        guard handles(urlString), let url = URL(string: urlString) else { return }
        let key = window.map(ObjectIdentifier.init)
        let time = now()
        if let last = lastOpenedAt[key], time.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastOpenedAt[key] = time
        open(url)
    }
}
