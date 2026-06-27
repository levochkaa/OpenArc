import AppKit
import Foundation

// MARK: - BrowserTabControllerDriver

@MainActor final class BrowserTabControllerDriver: NSObject, BrowserTabDriving {
    // MARK: Lifecycle

    init(
        hostView: BrowserTabHostView,
        usesEphemeralRequestContext: Bool = false,
        profileCachePath: String? = nil
    ) {
        self.browserHostView = hostView
        self.controller = BrowserTabController(
            hostView: hostView,
            usesEphemeralRequestContext: usesEphemeralRequestContext,
            profileCachePath: profileCachePath
        )
        super.init()
        controller.delegate = self
    }

    override convenience init() {
        self.init(hostView: BrowserTabHostView(frame: .zero))
    }

    convenience init(usesEphemeralRequestContext: Bool) {
        self.init(
            hostView: BrowserTabHostView(frame: .zero),
            usesEphemeralRequestContext: usesEphemeralRequestContext
        )
    }

    convenience init(profileCachePath: String) {
        self.init(
            hostView: BrowserTabHostView(frame: .zero),
            profileCachePath: profileCachePath
        )
    }

    // MARK: Internal

    var onTabCreated: ((String, String, String) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)?
    var onLoadingStateChanged: ((String, Bool) -> Void)?
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)?
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)?

    var hostView: NSView {
        browserHostView
    }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String {
        controller.createTab(withURLString: urlString, makeActive: makeActive)
    }

    func selectTab(withID tabID: String) {
        controller.selectTab(withID: tabID)
    }

    func deselectActiveTab() {
        controller.deselectActiveTab()
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

    func clearCacheAndReloadActiveTab() {
        controller.clearCacheAndReloadActiveTab()
    }

    func clearCookiesAndReloadActiveTab() {
        controller.clearCookiesAndReloadActiveTab()
    }

    func stopLoadingActiveTab() {
        controller.stopLoadingActiveTab()
    }

    func saveActiveTab(withSuggestedName suggestedName: String?) {
        controller.saveActiveTab(withSuggestedName: suggestedName)
    }

    func captureFullPageActiveTabToPasteboard() {
        controller.captureFullPageActiveTabToPasteboard()
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

    func stopFindingInActiveTab(clearSelection: Bool) {
        controller.stopFindingInActiveTab(clearSelection: clearSelection)
    }

    func closeTab(withID tabID: String, forceClose: Bool) {
        controller.closeTab(withID: tabID, forceClose: forceClose)
    }

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
}

// MARK: BrowserTabControllerDelegate

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

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateDownloadWithID downloadID: String,
        fileName: String,
        urlString: String,
        fullPath: String?,
        receivedBytes: Int64,
        totalBytes: Int64,
        currentSpeedBytesPerSecond: Int64,
        stateRawValue: String
    ) {
        Task { @MainActor [weak self] in
            let state = BrowserDownloadState(rawValue: stateRawValue) ?? .interrupted
            self?.onDownloadUpdated?(BrowserDownloadUpdate(
                id: downloadID,
                fileName: fileName,
                urlString: urlString,
                fullPath: fullPath,
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
                currentSpeedBytesPerSecond: currentSpeedBytesPerSecond,
                state: state
            ))
        }
    }
}
