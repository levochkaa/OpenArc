import AppKit
import Foundation

// MARK: - BrowserChromeModel Types

extension BrowserChromeModel {
    struct Tab: Identifiable, Equatable {
        let id: String
        var syncID: String
        var spaceID: String
        var title: String
        var userTitleOverride: String?
        var urlString: String
        var faviconURLString: String?
        var placement = BrowserTabPlacement.temporary
        var pinnedFolderID: String?
        var lastActivityAt = Date()
        var canGoBack = false
        var canGoForward = false
        var isLoading = false

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

        var pageURL: URL? {
            URL(string: urlString)
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
