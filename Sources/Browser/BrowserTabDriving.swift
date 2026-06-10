import AppKit
import Foundation

@MainActor protocol BrowserTabDriving: AnyObject {
    var hostView: NSView { get }
    var onTabCreated: ((String, String, String) -> Void)? { get set }
    var onTabUpdated: ((String, String?, String?, String?) -> Void)? { get set }
    var onTabClosed: ((String) -> Void)? { get set }
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)? { get set }
    var onLoadingStateChanged: ((String, Bool) -> Void)? { get set }
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)? { get set }
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)? { get set }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String
    func selectTab(withID tabID: String)
    func deselectActiveTab()
    func navigateActiveTab(toURLString urlString: String)
    func goBackActiveTab()
    func goForwardActiveTab()
    func reloadActiveTab()
    func reloadActiveTabIgnoringCache()
    func stopLoadingActiveTab()
    func saveActiveTab(withSuggestedName suggestedName: String?)
    func captureFullPageActiveTabToPasteboard()
    func pasteAndMatchStyleActiveTab()
    func printActiveTab()
    func findInActiveTab(text: String, forward: Bool, matchCase: Bool, findNext: Bool)
    func stopFindingInActiveTab(clearSelection: Bool)
    func closeTab(withID tabID: String, forceClose: Bool)
}
