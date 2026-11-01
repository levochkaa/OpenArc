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
        return URLComponents(string: urlString)?.port.map { "\(host):\($0)" } ?? host
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

// MARK: - BrowserChromeModel + recent pages preview

extension BrowserChromeModel {
    static let recentPagesPreviewPrefix = "recent-pages:"
    private static let recentPagesHosts: Set = [
        "linear.app",
        "notion.so",
        "www.notion.so",
        "notion.com",
        "www.notion.com",
        "figma.com",
        "www.figma.com",
    ]

    /// Pinned tabs and Favorites on these sites list the latest pages visited there on hover.
    func recentPagesPreviewID(forTab tab: Tab) -> String? {
        guard tab.placement != .temporary, userPreferencesStore.recentPagesPreviewsEnabled,
              let host = URLComponents(string: tab.pinnedURLString ?? tab.urlString)?.host?.lowercased(),
              Self.recentPagesHosts.contains(host)
        else { return nil }
        return Self.recentPagesPreviewPrefix + tab.id
    }

    func recentPagesPreviewItems(previewID: String) -> [BrowserFolderPreviewItem] {
        let tabID = String(previewID.dropFirst(Self.recentPagesPreviewPrefix.count))
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let host = URLComponents(string: tab.pinnedURLString ?? tab.urlString)?.host?.lowercased()
        else { return [] }
        return recentSuggestions(onHost: host, maximumCount: 8).map { suggestion in
            BrowserFolderPreviewItem(
                id: Self.recentPagesPreviewPrefix + tabID + "|" + suggestion.resolvedURLString,
                title: suggestion.displayText,
                urlString: suggestion.resolvedURLString,
                faviconURL: tab.faviconURL,
            )
        }
    }

    /// `id` comes from `recentPagesPreviewItems`. False when it is some other item.
    func openRecentPagePreviewItem(id: String) -> Bool {
        guard id.hasPrefix(Self.recentPagesPreviewPrefix) else { return false }
        let parts = id.dropFirst(Self.recentPagesPreviewPrefix.count).split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return false }
        selectTab(id: String(parts[0]))
        navigateTab(id: String(parts[0]), toURLString: String(parts[1]))
        return true
    }
}
