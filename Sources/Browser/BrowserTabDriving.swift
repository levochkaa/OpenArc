// BrowserTabDriving.swift

import AppKit
import Foundation

// MARK: - BrowserTabCreationState

enum BrowserTabCreationState: Equatable {
    case creating
    case ready
    case failed
}

// MARK: - BrowserTabCloseOutcome

enum BrowserTabCloseOutcome: Equatable {
    case closed
    case cancelled
}

// MARK: - BrowserTabVisibleLayout

/// Several tabs shown at once in one window (Split View), in pane order.
struct BrowserTabVisibleLayout: Equatable {
    let tabIDs: [String]
    let orientation: BrowserTabSplitOrientation
    let fractions: [Double]?
}

// MARK: - BrowserPageContextCommand

/// What a page's context menu asks the window to do, with a URL or text.
enum BrowserPageContextCommand: String {
    case openInSplitView
    case openInIncognito
    case copyLinkToHighlight
    case searchForSelection
    case savePage
    case viewSource
}

// MARK: - BrowserExtensionTabReport

/// One tab as extensions see it through `chrome.tabs`.
struct BrowserExtensionTabReport: Equatable {
    let tabID: String
    let index: Int
    let isActive: Bool
    let isPinned: Bool
}

// MARK: - BrowserPageTranslationStart

enum BrowserPageTranslationStart: Int {
    case unavailable
    case started
    case alreadyInLanguage
}

// MARK: - BrowserPageTranslationState

enum BrowserPageTranslationState: Int {
    case none
    case translating
    case translated
}

// MARK: - BrowserTabDriving

@MainActor protocol BrowserTabDriving: AnyObject {
    var onPageContextCommand: ((BrowserPageContextCommand, String) -> Void)? { get set }
    /// Where the next page keeps its data, nil for the window's own profile.
    var profileCachePathForNewTabs: String? { get set }
    var hostView: NSView { get }
    var onTabCreated: ((String, String, String, Bool) -> Void)? { get set }
    var onTabCreationStateChanged: ((String, BrowserTabCreationState) -> Void)? { get set }
    var onTabUpdated: ((String, String?, String?, String?) -> Void)? { get set }
    var onTabCloseRequestFinished: ((String, String, BrowserTabCloseOutcome) -> Void)? { get set }
    var onTabCloseConfirmationPresented: ((String) -> Void)? { get set }
    var onTabClosed: ((String) -> Void)? { get set }
    var onStatusChanged: ((String, String) -> Void)? { get set }
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)? { get set }
    var onLoadingStateChanged: ((String, Bool) -> Void)? { get set }
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)? { get set }
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)? { get set }
    /// A visible split pane received focus, for example from a click.
    var onTabFocused: ((String) -> Void)? { get set }
    /// A divider drag or reset ended in the visible split: every pane's tab ID
    /// in pane order with its new size fraction.
    var onSplitResized: (([String], [Double]) -> Void)? { get set }
    /// Pane frames of the visible split in the host view, in pane order, after
    /// each layout that changes them; empty outside a split. Synchronous, so
    /// pane bars follow a live divider drag.
    var onSplitPaneLayout: (([String], [CGRect]) -> Void)? { get set }
    /// Asked before a link click in a tab's page leaves it, with the tab ID and
    /// target; true opens the link in Peek and keeps the tab on its page.
    var shouldPeekNavigation: ((String, String) -> Bool)? { get set }
    /// The Spaces a Peek card or small window can open in.
    var peekSpaces: (() -> [BrowserPeekSpace])? { get set }
    /// The user closed a Peek card, or a small window when true, at this URL.
    var onPeekClosedByUser: ((String, Bool) -> Void)? { get set }
    /// Open in Split View from a Peek card, with its URL.
    var onOpenPeekInSplitView: ((String) -> Void)? { get set }
    /// Open In from a card or small window: the URL and the chosen Space.
    var onOpenPeekInSpace: ((String, String) -> Void)? { get set }
    /// A page asks for permissions; the answer goes to resolveSitePermissionRequest.
    var onSitePermissionRequested: ((BrowserSitePermissionRequest) -> Void)? { get set }
    /// The engine withdrew a request because its page navigated or closed.
    var onSitePermissionRequestDismissed: ((Int) -> Void)? { get set }
    /// A tab's renderer crashed or was killed, with Chromium's error code.
    var onRenderProcessTerminated: ((String, Int) -> Void)? { get set }
    /// A tab's pages started playing media or changed it; nil when they stop.
    var onMediaStateChanged: ((String, BrowserTabMediaState?) -> Void)? { get set }
    /// Tab, frame and the frame's address: the page has an address form.
    var onAddressFormFound: ((String, String, String) -> Void)? { get set }
    /// Tab, frame and the frame's address: the page has a card form.
    var onCardFormFound: ((String, String, String) -> Void)? { get set }
    /// Tab, the frame's address and the form's fields as JSON.
    var onAddressSubmitted: ((String, String, String) -> Void)? { get set }
    /// Tab, frame and the frame's address.
    var onPasswordFormFound: ((String, String, String) -> Void)? { get set }
    /// Tab, the frame's address, username and password.
    var onPasswordSubmitted: ((String, String, String, String) -> Void)? { get set }
    /// The prompt of a Peek card or small window was answered: true
    /// allows, false blocks, nil closes it without an answer.
    var onPeekSitePermissionAnswered: ((Int, Bool?) -> Void)? { get set }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String
    /// True admits another attempt for a synchronously refused creation.
    /// Creation-state notifications use onTabCreationStateChanged; admission
    /// does not establish readiness or guarantee completion of an accepted attempt.
    func retryTabCreation(withID tabID: String, urlString: String) -> Bool
    func selectTab(withID tabID: String)
    /// Shows every tab of a Split View with the active tab focused. nil shows
    /// only the active tab. Tabs without an engine are skipped.
    func setVisibleTabLayout(_ layout: BrowserTabVisibleLayout?)
    func deselectActiveTab()
    /// Accepts the latest target for an existing tab, including a pending engine.
    /// Returns false for an empty target or an unknown/closing tab.
    @discardableResult func navigateTab(withID tabID: String, toURLString urlString: String) -> Bool
    func navigateActiveTab(toURLString urlString: String)
    func goBackActiveTab()
    /// The active tab's history, oldest first, and the current page's index.
    func navigationEntriesForActiveTab(completion: @escaping @MainActor ([BrowserNavigationEntry], Int) -> Void)
    func goToHistoryOffsetInActiveTab(_ offset: Int)
    func setMediaVolume(_ volume: Double, forTabWithID tabID: String)
    func fillPassword(username: String, password: String, frameID: String, origin: String, tabID: String)
    func fillAddress(json: String, frameID: String, origin: String, tabID: String)
    func evaluateJavaScript(
        _ code: String,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    )
    func goForwardActiveTab()
    func reloadActiveTab()
    func reloadActiveTabIgnoringCache()
    func clearCacheAndReloadActiveTab()
    func clearCookiesAndReloadActiveTab()
    func stopLoadingActiveTab()
    func saveActiveTab(withSuggestedName suggestedName: String?)
    func captureFullPageActiveTabToPasteboard()
    func captureActiveTabPicture(completion: @escaping @MainActor (Data?) -> Void)
    /// A Cocoa action for the active page's own view; false without one.
    @discardableResult func sendActionToActivePage(_ action: Selector) -> Bool
    func focusActivePage()
    /// The outlined part of the page as fractions of its view, y downward.
    func captureActiveTabRegionToPasteboard(fraction: CGRect)
    func pasteAndMatchStyleActiveTab()
    func printActiveTab()
    /// Opens the page's Developer Tools in their own window.
    func showDevToolsForActiveTab()
    /// Developer Tools with the element picker on.
    func inspectElementsInActiveTab()
    /// Developer Tools on their Console panel.
    func showJavaScriptConsoleForActiveTab()
    func showNetworkInspectorForActiveTab()
    /// The page in a small window of its own.
    func showLittleWindow(withURLString urlString: String)
    /// Peek card over the window.
    func showPeek(withURLString urlString: String)
    /// An empty small window with its address field focused.
    func showNewLittleWindow()
    /// Closes the window's Peek cards and small windows with it.
    func closePeeks()
    /// Moves the page's playing video into Picture in Picture, or back.
    func setPictureInPicture(_ active: Bool, forTabWithID tabID: String)
    func togglePictureInPictureInActiveTab()
    func castActiveTab()
    func requestActiveTabWebAppManifest() async -> String?
    /// The text selected in the active page; empty or nil without a selection.
    func requestActiveTabSelectedText() async -> String?
    func setActiveTabZoomLevel(_ zoomLevel: Double)
    /// The page's current zoom level, or nil without an attached page.
    func zoomLevel(forTabWithID tabID: String) -> Double?
    /// Mute Tab. The engine keeps the state for a tab whose page attaches later.
    func setAudioMuted(_ muted: Bool, forTabWithID tabID: String)
    /// true allows, false blocks, nil dismisses the request without an answer.
    func resolveSitePermissionRequest(_ id: Int, allowed: Bool?)
    /// Plays, pauses or skips the media a tab is playing.
    func controlMedia(_ action: BrowserMediaAction, inTabWithID tabID: String)
    /// The waiting requests of Peek cards and small windows, in arrival
    /// order; each card shows its oldest.
    func showPeekSitePermissionRequests(_ requests: [BrowserSitePermissionRequest])
    func isPeekSessionOpen(_ sessionID: Int) -> Bool
    func rendererProcessIDsByTabID() -> [String: Int32]
    func executeDevTools(
        method: String,
        paramsJSON: String,
        tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    )
    func fillPasswordInMainFrame(username: String, password: String, origin: String, tabID: String) -> Bool
    @discardableResult func importCookies(_ cookies: [BrowserImportedCookie]) -> Int
    /// Tells extensions which pages are this window's tabs.
    func reportExtensionTabs(windowKey: String, focused: Bool, tabs: [BrowserExtensionTabReport])
    func tabID(forBrowserIdentifier browserIdentifier: Int32) -> String?
    func translateTab(withID tabID: String, toLanguage language: String) -> BrowserPageTranslationStart
    func revertTranslation(ofTabWithID tabID: String)
    func translationState(ofTabWithID tabID: String) -> BrowserPageTranslationState
    /// Puts a prompt over a Peek's page. False when the Peek is gone.
    func hostPrompt(_ prompt: NSView, height: CGFloat, inPeekSession sessionID: Int) -> Bool
    /// Chromium's settings for a page that differ from the profile default.
    func siteSettings(forURLString urlString: String) -> [BrowserSiteSettingKind: BrowserSiteSettingValue]
    func setSiteSetting(_ kind: BrowserSiteSettingKind, value: BrowserSiteSettingValue, forURLString urlString: String)
    func findInActiveTab(text: String, forward: Bool, matchCase: Bool, findNext: Bool)
    func stopFindingInActiveTab(clearSelection: Bool)
    /// Admits a manual close. Completion carries the same nonce; only `.closed`
    /// means the engine has closed. Forced/structural closes supersede this request.
    @discardableResult func requestCloseTab(withID tabID: String, requestID: String) -> Bool
    func closeTab(withID tabID: String, forceClose: Bool)
    func prepareForCefShutdown()
}

// MARK: - BrowserNavigationEntry

/// One page of a tab's history, as far from the current page as `offset`.
struct BrowserNavigationEntry: Equatable {
    let urlString: String
    let title: String
    var offset = 0

    var displayTitle: String { title.isEmpty ? urlString : title }

    var faviconURL: URL? {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    /// The pages one button leads to, nearest first.
    static func list(_ entries: [Self], currentIndex: Int, goingBack: Bool) -> [Self] {
        let indices = goingBack
            ? Array((0..<min(currentIndex, entries.count)).reversed())
            : Array(min(currentIndex + 1, entries.count)..<entries.count)
        return indices.map { index in
            var entry = entries[index]
            entry.offset = index - currentIndex
            return entry
        }
    }
}
