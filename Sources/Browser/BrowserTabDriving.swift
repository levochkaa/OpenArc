import AppKit
import Foundation

@MainActor
protocol BrowserTabDriving: AnyObject {
    var hostView: NSView { get }
    var onTabCreated: ((String, String, String) -> Void)? { get set }
    var onTabUpdated: ((String, String?, String?, String?) -> Void)? { get set }
    var onTabClosed: ((String) -> Void)? { get set }
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)? { get set }
    var onLoadingStateChanged: ((String, Bool) -> Void)? { get set }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String
    func selectTab(withID tabID: String)
    func goBackActiveTab()
    func goForwardActiveTab()
    func reloadActiveTab()
    func reloadActiveTabIgnoringCache()
    func stopLoadingActiveTab()
    func saveActiveTab(withSuggestedName suggestedName: String?)
    func closeTab(withID tabID: String, forceClose: Bool)
}
