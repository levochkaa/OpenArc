import AppKit
import Foundation

// MARK: - BrowserTabCreationState

enum BrowserTabCreationState: Equatable, Sendable {
    case creating
    case ready
    case failed
}

// MARK: - BrowserTabCloseOutcome

enum BrowserTabCloseOutcome: Equatable, Sendable {
    case closed
    case cancelled
}

// MARK: - BrowserTabVisibleLayout

/// Several tabs shown at once in one window (Split View), in pane order.
struct BrowserTabVisibleLayout: Equatable, Sendable {
    let tabIDs: [String]
    let orientation: BrowserTabSplitOrientation
    let fractions: [Double]?
}

// MARK: - BrowserTabDriving

@MainActor protocol BrowserTabDriving: AnyObject {
    var hostView: NSView { get }
    var onTabCreated: ((String, String, String, Bool) -> Void)? { get set }
    var onTabCreationStateChanged: ((String, BrowserTabCreationState) -> Void)? { get set }
    var onTabUpdated: ((String, String?, String?, String?) -> Void)? { get set }
    var onTabCloseRequestFinished: ((String, String, BrowserTabCloseOutcome) -> Void)? { get set }
    var onTabClosed: ((String) -> Void)? { get set }
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)? { get set }
    var onLoadingStateChanged: ((String, Bool) -> Void)? { get set }
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)? { get set }
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)? { get set }
    /// A visible split pane received focus, for example from a click.
    var onTabFocused: ((String) -> Void)? { get set }
    /// A divider drag or reset ended in the visible split: every pane's tab ID
    /// in pane order with its new size fraction.
    var onSplitResized: (([String], [Double]) -> Void)? { get set }

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
    func goForwardActiveTab()
    func reloadActiveTab()
    func reloadActiveTabIgnoringCache()
    func clearCacheAndReloadActiveTab()
    func clearCookiesAndReloadActiveTab()
    func stopLoadingActiveTab()
    func saveActiveTab(withSuggestedName suggestedName: String?)
    func captureFullPageActiveTabToPasteboard()
    func pasteAndMatchStyleActiveTab()
    func printActiveTab()
    func castActiveTab()
    func requestActiveTabWebAppManifest() async -> String?
    func setActiveTabZoomLevel(_ zoomLevel: Double)
    func findInActiveTab(text: String, forward: Bool, matchCase: Bool, findNext: Bool)
    func stopFindingInActiveTab(clearSelection: Bool)
    /// Admits a manual close. Completion carries the same nonce; only `.closed`
    /// means the engine has closed. Forced/structural closes supersede this request.
    @discardableResult func requestCloseTab(withID tabID: String, requestID: String) -> Bool
    func closeTab(withID tabID: String, forceClose: Bool)
    func prepareForCefShutdown()
}
