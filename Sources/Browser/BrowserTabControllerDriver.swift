import AppKit
import Foundation

@MainActor
final class BrowserTabControllerDriver: NSObject, BrowserTabDriving {
    var onTabCreated: ((String, String, String) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)?
    var onLoadingStateChanged: ((String, Bool) -> Void)?
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)?

    var hostView: NSView {
        browserHostView
    }

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController

    init(hostView: BrowserTabHostView) {
        browserHostView = hostView
        controller = BrowserTabController(hostView: hostView)
        super.init()
        controller.delegate = self
    }

    convenience override init() {
        self.init(hostView: BrowserTabHostView(frame: .zero))
    }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String {
        controller.createTab(withURLString: urlString, makeActive: makeActive)
    }

    func selectTab(withID tabID: String) {
        controller.selectTab(withID: tabID)
    }

    func navigateActiveTab(toURLString urlString: String) {
        controller.navigateActiveTab(toURLString: urlString)
    }

    func goBackActiveTab() {
        controller.goBackActiveTab()
    }

    func goForwardActiveTab() {
        controller.goForwardActiveTab()
    }

    func reloadActiveTab() {
        controller.reloadActiveTab()
    }

    func reloadActiveTabIgnoringCache() {
        controller.reloadActiveTabIgnoringCache()
    }

    func stopLoadingActiveTab() {
        controller.stopLoadingActiveTab()
    }

    func saveActiveTab(withSuggestedName suggestedName: String?) {
        controller.saveActiveTab(withSuggestedName: suggestedName)
    }

    func pasteAndMatchStyleActiveTab() {
        controller.pasteAndMatchStyleActiveTab()
    }

    func printActiveTab() {
        controller.printActiveTab()
    }

    func findInActiveTab(text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        controller.findInActiveTab(
            withText: text,
            forward: forward,
            matchCase: matchCase,
            findNext: findNext
        )
    }

    func focusSearchInActiveChromeSettingsTab() -> Bool {
        controller.focusSearchInActiveChromeSettingsTab()
    }

    func stopFindingInActiveTab(clearSelection: Bool) {
        controller.stopFindingInActiveTab(clearSelection: clearSelection)
    }

    func closeTab(withID tabID: String, forceClose: Bool) {
        controller.closeTab(withID: tabID, forceClose: forceClose)
    }
}

extension BrowserTabControllerDriver: BrowserTabControllerDelegate {
    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID tabID: String,
        title: String,
        urlString: String
    ) {
        Task { @MainActor [weak self] in
            self?.onTabCreated?(tabID, title, urlString)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID tabID: String,
        title: String?,
        urlString: String?,
        faviconURLString: String?
    ) {
        Task { @MainActor [weak self] in
            self?.onTabUpdated?(tabID, title, urlString, faviconURLString)
        }
    }

    nonisolated func browserTabController(_: BrowserTabController, didCloseTabWithID tabID: String) {
        Task { @MainActor [weak self] in
            self?.onTabClosed?(tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateNavigationStateForTabWithID tabID: String,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.onNavigationStateChanged?(tabID, canGoBack, canGoForward)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID tabID: String,
        isLoading: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.onLoadingStateChanged?(tabID, isLoading)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateFindResultForTabWithID tabID: String,
        matchCount: Int,
        activeMatchOrdinal: Int,
        finalUpdate: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.onFindResultChanged?(tabID, matchCount, activeMatchOrdinal, finalUpdate)
        }
    }
}
