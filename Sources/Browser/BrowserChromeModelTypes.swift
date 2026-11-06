// BrowserChromeModelTypes.swift

import AppKit
import Foundation

// MARK: - BrowserChromeModel Types

extension BrowserChromeModel {
    /// A local Split View: one sidebar item showing several tabs in one window.
    /// Members are sync IDs in pane order because runtime IDs change when a
    /// dormant tab reopens. Groups are never sent through sync.
    struct SplitGroup: Identifiable, Equatable {
        let id: String
        var tabSyncIDs: [String]
        var orientation = BrowserTabSplitOrientation.horizontal
        var fractions: [Double]?
        var focusedTabSyncID: String?
        var title: String?
        var systemImageName: String?
    }

    struct Tab: Identifiable, Equatable {
        // MARK: Internal

        let id: String
        var syncID: String
        var spaceID: String
        var title: String
        var userTitleOverride: String?
        var urlString: String
        var pinnedURLString: String?
        var faviconURLString: String?
        var placement = BrowserTabPlacement.temporary
        var pinnedFolderID: String?
        var pinnedSiblingRank: Double?
        var lastActivityAt = Date()
        var canGoBack = false
        var canGoForward = false
        var isLoading = false
        var creationState = BrowserTabCreationState.creating
        var hasPendingLocalNavigation = false

        var displayTitle: String {
            let trimmedUserTitleOverride = userTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedUserTitleOverride.isEmpty {
                return trimmedUserTitleOverride
            }

            return pageTitle
        }

        var pageTitle: String {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }

            if
                let url = URL(string: urlString),
                let host = url.host,
                !host.isEmpty
            {
                return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
            }

            return BrowserStrings.newTabTitle
        }

        var faviconURL: URL? {
            if faviconFallbackStyle == .chromiumWebUI {
                return nil
            }

            if
                let faviconURLString,
                let faviconURL = URL(string: faviconURLString)
            {
                return faviconURL
            }

            guard
                !urlString.isEmpty,
                let encodedURL = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else {
                return nil
            }

            return URL(string: "https://www.google.com/s2/favicons?sz=64&domain_url=\(encodedURL)")
        }

        var faviconFallbackStyle: BrowserFaviconFallbackStyle {
            BrowserFaviconFallbackStyle.style(forPageURLString: urlString)
        }

        var pageURL: URL? {
            URL(string: urlString)
        }

        var canResetToPinnedURL: Bool {
            guard placement == .spacePinned, let pinnedURLString else {
                return false
            }

            return Self.comparablePinnedURLString(urlString) != Self.comparablePinnedURLString(pinnedURLString)
        }

        // MARK: Private

        private static func comparablePinnedURLString(_ urlString: String) -> String {
            let resolvedURLString = BrowserInternalURLNormalizer.canonicalURLString(for: urlString) ?? urlString
            guard var components = URLComponents(string: resolvedURLString) else {
                return resolvedURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if components.path == "/" {
                components.path = ""
            }
            return components.url?.absoluteString ?? resolvedURLString.lowercased()
        }
    }

    struct Space: Identifiable, Equatable {
        let id: String
        var title: String
        var systemImageName: String
        var isPinnedSectionCollapsed: Bool
        var selectedTabID: String?
    }

    struct PinnedTabFolder: Identifiable, Equatable {
        let id: String
        var spaceID: String
        var parentFolderID: String?
        var title: String
        var systemImageName: String?
        var isExpanded: Bool
        var pinnedSiblingRank: Double?
    }

    struct TabSwitcherEntry: Identifiable {
        let tab: Tab
        let previewImage: NSImage?

        var id: String {
            tab.id
        }
    }

    struct TabSwitcherState {
        var entries: [TabSwitcherEntry]
        var selectedTabID: String
        var isVisible: Bool
    }

    enum BrowserInternalPage: Equatable {
        case settings
        case extensions
        case history
        case passwordManager
        case bookmarks
        case chromiumWebUI
    }
}

// MARK: - BrowserTextStyle

/// Format › Font commands, named as `document.execCommand` takes them.
enum BrowserTextStyle: String {
    case bold
    case italic
    case underline
}
