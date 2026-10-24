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

    var onTabCreated: ((String, String, String, Bool) -> Void)?
    var onTabCreationStateChanged: ((String, BrowserTabCreationState) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabCloseRequestFinished: ((String, String, BrowserTabCloseOutcome) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)?
    var onLoadingStateChanged: ((String, Bool) -> Void)?
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)?
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)?
    var onTabFocused: ((String) -> Void)?
    var onSplitResized: (([String], [Double]) -> Void)?
    var onSplitPaneLayout: (([String], [CGRect]) -> Void)?

    var hostView: NSView {
        browserHostView
    }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String {
        controller.createTab(withURLString: urlString, makeActive: makeActive)
    }

    func retryTabCreation(withID tabID: String, urlString: String) -> Bool {
        controller.retryTabCreation(withID: tabID, urlString: urlString)
    }

    func selectTab(withID tabID: String) {
        controller.selectTab(withID: tabID)
    }

    func setVisibleTabLayout(_ layout: BrowserTabVisibleLayout?) {
        controller.setVisibleTabLayout(
            withTabIDs: layout?.tabIDs,
            vertical: layout?.orientation == .vertical,
            fractions: layout?.fractions?.map { NSNumber(value: $0) }
        )
    }

    func deselectActiveTab() {
        controller.deselectActiveTab()
    }

    @discardableResult func navigateTab(withID tabID: String, toURLString urlString: String) -> Bool {
        controller.navigateTab(withID: tabID, toURLString: urlString)
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

    func showDevToolsForActiveTab() {
        controller.showDevToolsForActiveTab()
    }

    func showLittleWindow(withURLString urlString: String) {
        controller.showLittleWindow(withURLString: urlString)
    }

    func setPictureInPicture(_ active: Bool, forTabWithID tabID: String) {
        controller.setPictureInPicture(active, forTabWithID: tabID)
    }

    func printActiveTab() {
        controller.printActiveTab()
    }

    func castActiveTab() {
        controller.castActiveTab()
    }

    func requestActiveTabWebAppManifest() async -> String? {
        await withCheckedContinuation { continuation in
            controller.requestActiveTabWebAppManifest { payloadJSON in
                continuation.resume(returning: payloadJSON)
            }
        }
    }

    func setAudioMuted(_ muted: Bool, forTabWithID tabID: String) {
        controller.setAudioMuted(muted, forTabWithID: tabID)
    }

    func zoomLevel(forTabWithID tabID: String) -> Double? {
        let level = controller.zoomLevel(forTabWithID: tabID)
        return level.isNaN ? nil : level
    }

    func setActiveTabZoomLevel(_ zoomLevel: Double) {
        controller.setActiveTabZoomLevel(zoomLevel)
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

    @discardableResult func requestCloseTab(withID tabID: String, requestID: String) -> Bool {
        controller.requestCloseTab(withID: tabID, requestID: requestID)
    }

    func closeTab(withID tabID: String, forceClose: Bool) {
        controller.closeTab(withID: tabID, forceClose: forceClose)
    }

    func prepareForCefShutdown() {
        onTabCreated = nil
        onTabCreationStateChanged = nil
        onTabUpdated = nil
        onTabCloseRequestFinished = nil
        onTabClosed = nil
        onNavigationStateChanged = nil
        onLoadingStateChanged = nil
        onFindResultChanged = nil
        onDownloadUpdated = nil
        onTabFocused = nil
        onSplitResized = nil
        onSplitPaneLayout = nil
        controller.prepareForCefShutdown()
    }

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
}

// MARK: BrowserTabControllerDelegate

extension BrowserTabControllerDriver: BrowserTabControllerDelegate {
    nonisolated func browserTabController(_: BrowserTabController, didFocusTabWithID tabID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onTabFocused?(tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didLayoutSplitPanesWithTabIDs tabIDs: [String],
        frames: [NSValue]
    ) {
        let rects = frames.map(\.rectValue)
        // Layout runs on the main thread; reporting synchronously keeps the bars
        // on the same frame as the panes during a divider drag.
        MainActor.assumeIsolated {
            onSplitPaneLayout?(tabIDs, rects)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didResizeSplitWithTabIDs tabIDs: [String],
        fractions: [NSNumber]
    ) {
        let sizes = fractions.map(\.doubleValue)
        DispatchQueue.main.async { [weak self] in
            self?.onSplitResized?(tabIDs, sizes)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didFinishCloseRequestForTabWithID tabID: String,
        requestID: String,
        outcome: BrowserTabCloseRequestOutcome
    ) {
        // FIFO keeps the token completion ahead of the generic closed event.
        DispatchQueue.main.async { [weak self] in
            let result: BrowserTabCloseOutcome
            switch outcome {
            case .closed: result = .closed
            case .cancelled: result = .cancelled
            @unknown default: return
            }
            self?.onTabCloseRequestFinished?(tabID, requestID, result)
        }
    }

    /// The bridge emits allocation before engine outcomes on the UI thread.
    /// Main-queue FIFO preserves that order and delivers after createTab returns.
    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangeCreationStateForTabWithID tabID: String,
        state: BrowserTabEngineCreationState
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let creationState: BrowserTabCreationState
            switch state {
            case .creating: creationState = .creating
            case .ready: creationState = .ready
            case .failed: creationState = .failed
            @unknown default: return
            }
            onTabCreationStateChanged?(tabID, creationState)
            if creationState == .ready {
                // A callback may close the tab or shut down the controller.
                // The bridge rechecks the record before enabling navigation.
                controller.acknowledgeTabReady(withID: tabID)
            }
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didCreateTabWithID tabID: String,
        title: String,
        urlString: String,
        isActive: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onTabCreated?(tabID, title, urlString, isActive)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateTabWithID tabID: String,
        title: String?,
        urlString: String?,
        faviconURLString: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onTabUpdated?(tabID, title, urlString, faviconURLString)
        }
    }

    nonisolated func browserTabController(_: BrowserTabController, didCloseTabWithID tabID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onTabClosed?(tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateNavigationStateForTabWithID tabID: String,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onNavigationStateChanged?(tabID, canGoBack, canGoForward)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID tabID: String,
        isLoading: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
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
        DispatchQueue.main.async { [weak self] in
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
        DispatchQueue.main.async { [weak self] in
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
