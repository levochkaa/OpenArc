// BrowserChromeModel+DeveloperMode.swift

import Foundation

// MARK: - BrowserDeveloperModeHosts

/// Sites in Developer Mode. Local servers start in it until they are turned off.
struct BrowserDeveloperModeHosts: Codable, Equatable {
    static let defaultHosts: Set = ["localhost", "127.0.0.1"]

    var enabled = Set<String>()
    var disabledDefaults = Set<String>()

    func isEnabled(host: String) -> Bool {
        enabled.contains(host) || (Self.defaultHosts.contains(host) && !disabledDefaults.contains(host))
    }

    mutating func set(_ on: Bool, host: String) {
        if on {
            disabledDefaults.remove(host)
            if !Self.defaultHosts.contains(host) {
                enabled.insert(host)
            }
        } else {
            enabled.remove(host)
            if Self.defaultHosts.contains(host) {
                disabledDefaults.insert(host)
            }
        }
    }
}

// MARK: - BrowserDeveloperReloadBehavior

/// What Reload does on a site in Developer Mode.
enum BrowserDeveloperReloadBehavior: String, CaseIterable {
    case reload
    case ignoreCache
    case clearCookies
}

// MARK: - BrowserChromeModel + Developer Mode

extension BrowserChromeModel {
    static func developerModeHost(ofURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              components.scheme == "http" || components.scheme == "https"
        else { return nil }
        return components.host?.lowercased()
    }

    /// The host to show under a tab's title, if its site is in Developer Mode.
    func developerModeHost(forTabURLString urlString: String) -> String? {
        guard let host = Self.developerModeHost(ofURLString: urlString),
              userPreferencesStore.developerModeHosts.isEnabled(host: host)
        else { return nil }
        return host
    }

    var canToggleDeveloperMode: Bool {
        currentTab.flatMap { Self.developerModeHost(ofURLString: $0.urlString) } != nil
    }

    var isDeveloperModeOn: Bool {
        currentTab.flatMap { developerModeHost(forTabURLString: $0.urlString) } != nil
    }

    func toggleDeveloperMode() {
        guard let host = currentTab.flatMap({ Self.developerModeHost(ofURLString: $0.urlString) }) else { return }
        let on = !userPreferencesStore.developerModeHosts.isEnabled(host: host)
        userPreferencesStore.developerModeHosts.set(on, host: host)
        objectWillChange.send()
    }

    /// Reload, as the site's mode asks for.
    func reloadRespectingDeveloperMode() {
        guard isDeveloperModeOn else {
            reloadCurrentTab()
            return
        }
        switch userPreferencesStore.developerReloadBehavior {
        case .reload: reloadCurrentTab()
        case .ignoreCache: forceReloadCurrentTab()
        case .clearCookies: clearCookiesAndRefreshCurrentTab()
        }
    }
}
