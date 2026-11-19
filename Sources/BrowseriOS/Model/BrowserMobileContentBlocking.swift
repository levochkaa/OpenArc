// BrowserMobileContentBlocking.swift

import Foundation

/// The built-in blocker's settings on iOS, kept under the Mac's key and
/// handed to the shared filter list updater on every change.
@MainActor enum BrowserMobileContentBlocking {
    static let key = "browser.settings.contentBlocking"

    static func settings(_ defaults: UserDefaults = .standard) -> BrowserContentBlockingSettings {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(BrowserContentBlockingSettings.self, from: $0) }
            ?? BrowserContentBlockingSettings()
    }

    /// Loads the lists the settings turn on and keeps them current.
    static func start(_ defaults: UserDefaults = .standard) {
        BrowserFilterListUpdater.shared.start(settings: settings(defaults))
    }

    static func update(
        _ defaults: UserDefaults = .standard,
        applies: Bool = true,
        _ change: (inout BrowserContentBlockingSettings) -> Void,
    ) {
        var settings = settings(defaults)
        change(&settings)
        defaults.set(try? JSONEncoder().encode(settings), forKey: key)
        if applies {
            BrowserFilterListUpdater.shared.apply(settings)
        }
    }

    /// Whether a list blocks on the page: on in Settings and not allowed on its site.
    static func blocks(
        _ kind: BrowserFilterListKind, onPage urlString: String, defaults: UserDefaults = .standard,
    ) -> Bool {
        settings(defaults).enabledKinds(forURLString: urlString).contains(kind)
    }

    static func setBlocks(
        _ kind: BrowserFilterListKind, _ on: Bool, onPage urlString: String, defaults: UserDefaults = .standard,
        applies: Bool = true,
    ) {
        update(defaults, applies: applies) { $0.setAllowed(!on, kind: kind, urlString: urlString) }
    }
}
