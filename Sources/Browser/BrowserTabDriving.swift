import AppKit
import Foundation

// MARK: - BrowserTabCreationState

enum BrowserTabCreationState: Equatable, Sendable {
    case creating
    case ready
    case failed
}

// MARK: - BrowserTabDriving

@MainActor protocol BrowserTabDriving: AnyObject {
    var hostView: NSView { get }
    var onTabCreated: ((String, String, String, Bool) -> Void)? { get set }
    var onTabCreationStateChanged: ((String, BrowserTabCreationState) -> Void)? { get set }
    var onTabUpdated: ((String, String?, String?, String?) -> Void)? { get set }
    var onTabClosed: ((String) -> Void)? { get set }
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)? { get set }
    var onLoadingStateChanged: ((String, Bool) -> Void)? { get set }
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)? { get set }
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)? { get set }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String
    /// True admits another attempt for a synchronously refused creation.
    /// Creation-state notifications use onTabCreationStateChanged; admission
    /// does not establish readiness or guarantee completion of an accepted attempt.
    func retryTabCreation(withID tabID: String, urlString: String) -> Bool
    func selectTab(withID tabID: String)
    func deselectActiveTab()
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
    func closeTab(withID tabID: String, forceClose: Bool)
    func prepareForCefShutdown()
}
