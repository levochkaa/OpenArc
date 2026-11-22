// BrowserTabControllerDriver.swift

import AppKit
import Foundation

// MARK: - BrowserTabControllerDriver

@MainActor final class BrowserTabControllerDriver: NSObject, BrowserTabDriving {
    // MARK: Internal

    var onTabCreated: ((String, String, String, Bool) -> Void)?
    var onTabCreationStateChanged: ((String, BrowserTabCreationState) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabCloseRequestFinished: ((String, String, BrowserTabCloseOutcome) -> Void)?
    var onTabCloseConfirmationPresented: ((String) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onDownloadWithoutPage: ((String) -> Void)?
    var onStatusChanged: ((String, String) -> Void)?
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)?
    var onLoadingStateChanged: ((String, Bool) -> Void)?
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)?
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)?
    var onTabFocused: ((String) -> Void)?
    var onSplitResized: (([String], [Double]) -> Void)?
    var onSplitPaneLayout: (([String], [CGRect]) -> Void)?
    var shouldPeekNavigation: ((String, String) -> Bool)?
    var peekSpaces: (() -> [BrowserPeekSpace])?
    var onOpenPeekInSpace: ((String, String) -> Void)?
    var onOpenPeekInSplitView: ((String) -> Void)?
    var onPageContextCommand: ((BrowserPageContextCommand, String) -> Void)?
    var onPeekClosedByUser: ((String, Bool) -> Void)?
    var onSitePermissionRequested: ((BrowserSitePermissionRequest) -> Void)?
    var onSitePermissionRequestDismissed: ((Int) -> Void)?
    var onPeekSitePermissionAnswered: ((Int, Bool?) -> Void)?
    var onMediaStateChanged: ((String, BrowserTabMediaState?) -> Void)?
    var onCaptureChanged: ((String, Bool) -> Void)?
    var onPageFullscreenChanged: ((String, Bool) -> Void)?
    var onTabOpenedFromTab: ((String, String) -> Void)?
    var onPeekPagesChanged: (([String: String]) -> Void)?
    var onAddressFormFound: ((String, String, String) -> Void)?
    var onCardFormFound: ((String, String, String) -> Void)?
    var onAddressSubmitted: ((String, String, String) -> Void)?
    var onPasswordFormFound: ((String, String, String) -> Void)?
    var onPasswordSubmitted: ((String, String, String, String) -> Void)?
    var onRenderProcessTerminated: ((String, Int) -> Void)?

    var searchEngineName: (() -> String?)? {
        didSet {
            let provider = searchEngineName
            controller.searchEngineNameProvider = provider.map { provider in { provider() } }
        }
    }

    // MARK: Private

    private let browserHostView: BrowserTabHostView
    private let controller: BrowserTabController
    /// Peek sessions showing a prompt.
    private var promptingPeekSessions = Set<Int>()

    /// The window's own profile, which WebKit's cookie import falls back to.
    private let profileCachePath: String?

    var profileCachePathForNewTabs: String? {
        get { controller.profileCachePathForNewTabs }
        set { controller.profileCachePathForNewTabs = newValue }
    }

    var hostView: NSView {
        browserHostView
    }

    var activeTabEngine: BrowserPageEngine {
        BrowserPageEngine(rawValue: controller.activeTabEngine) ?? .chromium
    }

    var activeTabCanSwitchEngine: Bool {
        controller.activeTabCanSwitchEngine
    }

    init(
        hostView: BrowserTabHostView,
        usesEphemeralRequestContext: Bool = false,
        profileCachePath: String? = nil,
    ) {
        self.browserHostView = hostView
        self.profileCachePath = profileCachePath
        self.controller = BrowserTabController(
            hostView: hostView,
            usesEphemeralRequestContext: usesEphemeralRequestContext,
            profileCachePath: profileCachePath,
        )
        super.init()
        controller.delegate = self
        controller.webKitPagesEnabled = true
    }

    override convenience init() {
        self.init(hostView: BrowserTabHostView(frame: .zero))
    }

    convenience init(usesEphemeralRequestContext: Bool) {
        self.init(
            hostView: BrowserTabHostView(frame: .zero),
            usesEphemeralRequestContext: usesEphemeralRequestContext,
        )
    }

    convenience init(profileCachePath: String) {
        self.init(
            hostView: BrowserTabHostView(frame: .zero),
            profileCachePath: profileCachePath,
        )
    }

    func openActiveTab(in engine: BrowserPageEngine) {
        controller.openActiveTab(inEngine: engine.rawValue)
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
            fractions: layout?.fractions?.map { NSNumber(value: $0) },
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

    func cancelDownload(id: String) {
        controller.cancelDownload(withID: id)
    }

    func captureActiveTabPicture(completion: @escaping @MainActor (Data?) -> Void) {
        controller.captureActiveTabPicture { data in
            MainActor.assumeIsolated { completion(data) }
        }
    }

    func captureTabRegion(tabID: String, fraction: CGRect, completion: @escaping @MainActor (Data?) -> Void) {
        controller.captureTab(withID: tabID, region: fraction) { data in
            MainActor.assumeIsolated { completion(data) }
        }
    }

    func captureFullPageActiveTabToPasteboard() {
        controller.captureFullPageActiveTabToPasteboard()
    }

    @discardableResult func sendActionToActivePage(_ action: Selector) -> Bool {
        controller.sendActionToActivePage(action)
    }

    func focusActivePage() {
        controller.focusActivePage()
    }

    func captureActiveTabRegionToPasteboard(fraction: CGRect) {
        controller.captureActiveTabRegionToPasteboard(fraction: fraction)
    }

    func pasteAndMatchStyleActiveTab() {
        controller.pasteAndMatchStyleActiveTab()
    }

    func showDevToolsForActiveTab() {
        controller.showDevToolsForActiveTab()
    }

    func inspectElementsInActiveTab() {
        controller.inspectElementsInActiveTab()
    }

    func navigationEntriesForActiveTab(completion: @escaping @MainActor ([BrowserNavigationEntry], Int) -> Void) {
        controller.visitNavigationEntries(forActiveTab: { entries, currentIndex in
            let converted = entries.map {
                BrowserNavigationEntry(urlString: $0["url"] ?? "", title: $0["title"] ?? "")
            }
            MainActor.assumeIsolated { completion(converted, currentIndex) }
        })
    }

    func evaluateJavaScript(
        _ code: String,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        controller.evaluateJavaScript(code, inTabWithID: tabID) { value in
            MainActor.assumeIsolated { completion(value) }
        }
    }

    func fillAddress(json: String, frameID: String, origin: String, tabID: String) {
        controller.fillAddressJSON(json, frameID: frameID, urlPrefix: origin, forTabWithID: tabID)
    }

    func fillPassword(username: String, password: String, frameID: String, origin: String, tabID: String) {
        controller.fillPassword(
            withUsername: username,
            password: password,
            frameID: frameID,
            urlPrefix: origin,
            forTabWithID: tabID,
        )
    }

    func setMediaVolume(_ volume: Double, forTabWithID tabID: String) {
        controller.setMediaVolume(volume, forTabWithID: tabID)
    }

    func goToHistoryOffsetInActiveTab(_ offset: Int) {
        controller.goToHistoryOffset(inActiveTab: offset)
    }

    func showJavaScriptConsoleForActiveTab() {
        controller.showJavaScriptConsoleForActiveTab()
    }

    func showNetworkInspectorForActiveTab() {
        controller.showNetworkInspectorForActiveTab()
    }

    func showLittleWindow(withURLString urlString: String) {
        controller.showLittleWindow(withURLString: urlString)
    }

    func showSignInWindow(withURLString urlString: String) {
        controller.showSignInWindow(withURLString: urlString)
    }

    func showNewLittleWindow() {
        controller.showNewLittleWindow()
    }

    func showPeek(withURLString urlString: String) {
        controller.showPeek(withURLString: urlString)
    }

    func closePeeks() {
        controller.closeAllPeeks()
    }

    func togglePictureInPictureInActiveTab() {
        controller.togglePictureInPictureInActiveTab()
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

    func activeTabCertificateChain() -> [Data] {
        controller.activeTabCertificateChain()
    }

    func requestActiveTabWebAppManifest() async -> String? {
        await withCheckedContinuation { continuation in
            controller.requestActiveTabWebAppManifest { payloadJSON in
                continuation.resume(returning: payloadJSON)
            }
        }
    }

    func requestActiveTabSelectedText() async -> String? {
        await withCheckedContinuation { continuation in
            controller.requestActiveTabSelectedText { text in
                continuation.resume(returning: text)
            }
        }
    }

    func resolveSitePermissionRequest(_ id: Int, allowed: Bool?) {
        controller.resolveSitePermissionRequest(id, allowed: allowed.map { NSNumber(value: $0) })
    }

    func controlMedia(_ action: BrowserMediaAction, inTabWithID tabID: String) {
        controller.controlMedia(inTabWithID: tabID, action: action.rawValue)
    }

    func showPeekSitePermissionRequests(_ requests: [BrowserSitePermissionRequest]) {
        var oldest = [Int: BrowserSitePermissionRequest]()
        for request in requests {
            if let session = request.peekSessionID, oldest[session] == nil {
                oldest[session] = request
            }
        }
        // Cards whose requests are gone hide their prompt.
        for session in promptingPeekSessions.union(oldest.keys) {
            guard let panel = controller.peekPanel(forSessionID: session) else { continue }
            panel.onSitePermissionAnswer = { [weak self] id, allowed in
                self?.onPeekSitePermissionAnswered?(id, allowed)
            }
            panel.showSitePermissionRequest(oldest[session])
        }
        promptingPeekSessions = Set(oldest.keys)
    }

    func executeDevTools(
        method: String,
        paramsJSON: String,
        tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        controller.executeDevToolsMethod(method, params: paramsJSON, inTabWithID: tabID) { result in
            MainActor.assumeIsolated { completion(result) }
        }
    }

    @discardableResult func importCookies(_ cookies: [BrowserImportedCookie], profileCachePath: String?) -> Int {
        if BrowserUsesWebKitEngine() != 0 {
            return BrowserWebKitPage.importCookies(
                cookies,
                profileKey: profileCachePath ?? self.profileCachePath,
                ephemeral: controller.usesEphemeralRequestContext,
            )
        }
        return controller.importCookies(cookies.map {
            [
                "url": $0.urlString, "host": $0.host, "name": $0.name, "value": $0.value, "path": $0.path,
                "expires": $0.expires, "secure": $0.isSecure, "httpOnly": $0.isHTTPOnly, "sameSite": $0.sameSite,
            ]
        }, profileCachePath: profileCachePath)
    }

    func fillPasswordInMainFrame(username: String, password: String, origin: String, tabID: String) -> Bool {
        controller.fillPasswordInMainFrame(
            withUsername: username,
            password: password,
            urlPrefix: origin,
            forTabWithID: tabID,
        )
    }

    func rendererProcessIDsByTabID() -> [String: Int32] {
        controller.rendererProcessIDsByTabID().mapValues(\.int32Value)
    }

    func setWarmTabs(_ tabIDs: [String]) {
        controller.setWarmTabIDs(tabIDs)
    }

    func reportExtensionTabs(windowKey: String, focused: Bool, tabs: [BrowserExtensionTabReport]) {
        controller.reportExtensionTabs(
            forWindowKey: windowKey,
            focused: focused,
            tabs: tabs.map {
                ["tabID": $0.tabID, "index": $0.index, "active": $0.isActive, "pinned": $0.isPinned]
            },
        )
    }

    func tabID(forBrowserIdentifier browserIdentifier: Int32) -> String? {
        controller.tabID(forBrowserIdentifier: browserIdentifier)
    }

    func translateTab(withID tabID: String, toLanguage language: String) -> BrowserPageTranslationStart {
        BrowserPageTranslationStart(rawValue: controller.translateTab(withID: tabID, toLanguage: language)) ??
            .unavailable
    }

    func revertTranslation(ofTabWithID tabID: String) {
        controller.revertTranslationForTab(withID: tabID)
    }

    func translationState(ofTabWithID tabID: String) -> BrowserPageTranslationState {
        BrowserPageTranslationState(rawValue: controller.translationStateForTab(withID: tabID)) ?? .none
    }

    func isPeekSessionOpen(_ sessionID: Int) -> Bool {
        controller.peekPanel(forSessionID: sessionID) != nil
    }

    func hostPrompt(_ prompt: NSView, height: CGFloat, inPeekSession sessionID: Int) -> Bool {
        guard let panel = controller.peekPanel(forSessionID: sessionID) else { return false }
        panel.hostPrompt(prompt, height: height)
        return true
    }

    func siteSettings(forURLString urlString: String) -> [BrowserSiteSettingKind: BrowserSiteSettingValue] {
        var settings = [BrowserSiteSettingKind: BrowserSiteSettingValue]()
        for (kind, value) in controller.siteSettings(forURLString: urlString) {
            if let kind = BrowserSiteSettingKind(rawValue: kind), let value = BrowserSiteSettingValue(rawValue: value) {
                settings[kind] = value
            }
        }
        return settings
    }

    func setSiteSetting(
        _ kind: BrowserSiteSettingKind,
        value: BrowserSiteSettingValue,
        forURLString urlString: String,
    ) {
        controller.setSiteSetting(kind.rawValue, value: value.rawValue, forURLString: urlString)
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
            findNext: findNext,
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

    func exitPageFullscreen() {
        controller.exitPageFullscreen()
    }

    func detachPage(ofTabWithID tabID: String) -> BrowserTabPageHandoff? {
        controller.detachTab(withID: tabID).map {
            BrowserTabPageHandoff(
                page: $0, canGoBack: $0.canGoBack, canGoForward: $0.canGoForward, isLoading: $0.isLoading,
            )
        }
    }

    func adoptPage(_ handoff: BrowserTabPageHandoff, makeActive: Bool) -> String? {
        guard let page = handoff.page as? BrowserTabPageTransfer else { return nil }
        return controller.adoptTabPage(page, makeActive: makeActive)
    }

    func capturePicture(of handoff: BrowserTabPageHandoff, completion: @escaping @MainActor (Data?) -> Void) {
        guard let page = handoff.page as? BrowserTabPageTransfer else {
            completion(nil)
            return
        }
        page.capturePicture { data in
            MainActor.assumeIsolated { completion(data) }
        }
    }

    func prepareForCefShutdown() {
        onTabCreated = nil
        onTabCreationStateChanged = nil
        onTabUpdated = nil
        onTabCloseRequestFinished = nil
        onTabCloseConfirmationPresented = nil
        onTabClosed = nil
        onStatusChanged = nil
        onNavigationStateChanged = nil
        onLoadingStateChanged = nil
        onFindResultChanged = nil
        onDownloadUpdated = nil
        onTabFocused = nil
        onSplitResized = nil
        onSplitPaneLayout = nil
        controller.prepareForCefShutdown()
    }
}

// MARK: BrowserTabControllerDelegate

extension BrowserTabControllerDriver: BrowserTabControllerDelegate {
    nonisolated func peekSpaces(for _: BrowserTabController) -> [BrowserPeekSpace] {
        MainActor.assumeIsolated { peekSpaces?() ?? [] }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didClosePeekWithURLString urlString: String,
        standalone: Bool,
    ) {
        MainActor.assumeIsolated { onPeekClosedByUser?(urlString, standalone) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        performPageContextCommand command: String,
        argument: String,
    ) {
        MainActor.assumeIsolated {
            guard let command = BrowserPageContextCommand(rawValue: command) else { return }
            onPageContextCommand?(command, argument)
        }
    }

    nonisolated func browserTabController(_: BrowserTabController, openPeekURLStringInSplitView urlString: String) {
        MainActor.assumeIsolated { onOpenPeekInSplitView?(urlString) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        openPeekURLString urlString: String,
        inSpaceWithID spaceID: String,
    ) {
        MainActor.assumeIsolated { onOpenPeekInSpace?(urlString, spaceID) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        shouldPeekNavigationFromTabWithID tabID: String,
        toURLString urlString: String,
    ) -> Bool {
        // The engine asks on the main thread and needs the answer now.
        MainActor.assumeIsolated {
            shouldPeekNavigation?(tabID, urlString) ?? false
        }
    }

    nonisolated func browserTabController(_: BrowserTabController, didFocusTabWithID tabID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onTabFocused?(tabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didLayoutSplitPanesWithTabIDs tabIDs: [String],
        frames: [NSValue],
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
        fractions: [NSNumber],
    ) {
        let sizes = fractions.map(\.doubleValue)
        DispatchQueue.main.async { [weak self] in
            self?.onSplitResized?(tabIDs, sizes)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didRequestSitePermission requestID: Int,
        forTabWithID tabID: String,
        origin: String,
        kinds: [String],
        mediaAccess: Bool,
    ) {
        let request = BrowserSitePermissionRequest(
            id: requestID,
            tabID: tabID,
            origin: origin,
            kinds: kinds.compactMap(BrowserSitePermissionKind.init(rawValue:)),
            isMediaAccess: mediaAccess,
        )
        MainActor.assumeIsolated { onSitePermissionRequested?(request) }
    }

    nonisolated func browserTabController(_: BrowserTabController, didDismissSitePermissionRequest requestID: Int) {
        MainActor.assumeIsolated { onSitePermissionRequestDismissed?(requestID) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        renderProcessTerminatedForTabWithID tabID: String,
        errorCode: Int,
    ) {
        MainActor.assumeIsolated { onRenderProcessTerminated?(tabID, errorCode) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangeMediaStateForTabWithID tabID: String,
        audible: Bool,
        playing: Bool,
        paused: Bool,
        video: Bool,
        hasPreviousTrack: Bool,
        hasNextTrack: Bool,
        pictureInPicture: Bool,
        canToggleMicrophone: Bool,
        canToggleCamera: Bool,
        microphoneActive: Bool,
        cameraActive: Bool,
        title: String,
    ) {
        let state = playing || paused
            ? BrowserTabMediaState(
                isPlaying: playing,
                audible: audible,
                video: video,
                hasPreviousTrack: hasPreviousTrack,
                hasNextTrack: hasNextTrack,
                inPictureInPicture: pictureInPicture,
                call: canToggleMicrophone || canToggleCamera
                    ? BrowserCallControls(
                        canToggleMicrophone: canToggleMicrophone,
                        canToggleCamera: canToggleCamera,
                        isMicrophoneOn: microphoneActive,
                        isCameraOn: cameraActive,
                    )
                    : nil,
                title: title,
            )
            : nil
        MainActor.assumeIsolated { onMediaStateChanged?(tabID, state) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangePeekPagesByTabID pages: [String: String],
    ) {
        MainActor.assumeIsolated { onPeekPagesChanged?(pages) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangeCaptureForTabWithID tabID: String,
        video: Bool,
        audio: Bool,
    ) {
        MainActor.assumeIsolated { onCaptureChanged?(tabID, video || audio) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didOpenTabWithID tabID: String,
        fromTabWithID openerTabID: String,
    ) {
        // After the creation callback, which also waits for the main queue.
        DispatchQueue.main.async { [weak self] in
            self?.onTabOpenedFromTab?(tabID, openerTabID)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangePageFullscreenForTabWithID tabID: String,
        fullscreen: Bool,
    ) {
        MainActor.assumeIsolated { onPageFullscreenChanged?(tabID, fullscreen) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didChangeStatus status: String,
        forTabWithID tabID: String,
    ) {
        MainActor.assumeIsolated { onStatusChanged?(tabID, status) }
    }

    nonisolated func browserTabController(_: BrowserTabController, willConfirmCloseForTabWithID tabID: String) {
        MainActor.assumeIsolated { onTabCloseConfirmationPresented?(tabID) }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didFinishCloseRequestForTabWithID tabID: String,
        requestID: String,
        outcome: BrowserTabCloseRequestOutcome,
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
        state: BrowserTabEngineCreationState,
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
        isActive: Bool,
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
        faviconURLString: String?,
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onTabUpdated?(tabID, title, urlString, faviconURLString)
        }
    }

    nonisolated func browserTabController(_: BrowserTabController, didDownloadWithoutPageInTabWithID tabID: String) {
        MainActor.assumeIsolated { onDownloadWithoutPage?(tabID) }
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
        canGoForward: Bool,
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onNavigationStateChanged?(tabID, canGoBack, canGoForward)
        }
    }

    nonisolated func browserTabController(
        _: BrowserTabController,
        didUpdateLoadingStateForTabWithID tabID: String,
        isLoading: Bool,
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
        finalUpdate: Bool,
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
        stateRawValue: String,
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
                state: state,
            ))
        }
    }
}

// MARK: - Passwords

extension BrowserTabControllerDriver {
    @objc(browserTabController:didFindCardFormInTabWithID:frameID:urlString:) nonisolated func browserTabController(
        _: BrowserTabController,
        didFindCardFormInTabWithID tabID: String,
        frameID: String,
        urlString: String,
    ) {
        MainActor.assumeIsolated { onCardFormFound?(tabID, frameID, urlString) }
    }

    @objc(browserTabController:didFindAddressFormInTabWithID:frameID:urlString:) nonisolated func browserTabController(
        _: BrowserTabController,
        didFindAddressFormInTabWithID tabID: String,
        frameID: String,
        urlString: String,
    ) {
        MainActor.assumeIsolated { onAddressFormFound?(tabID, frameID, urlString) }
    }

    @objc(browserTabController:didSubmitAddressInTabWithID:urlString:json:) nonisolated func browserTabController(
        _: BrowserTabController,
        didSubmitAddressInTabWithID tabID: String,
        urlString: String,
        json: String,
    ) {
        MainActor.assumeIsolated { onAddressSubmitted?(tabID, urlString, json) }
    }

    @objc(browserTabController:didFindPasswordFormInTabWithID:frameID:urlString:) nonisolated func browserTabController(
        _: BrowserTabController,
        didFindPasswordFormInTabWithID tabID: String,
        frameID: String,
        urlString: String,
    ) {
        MainActor.assumeIsolated { onPasswordFormFound?(tabID, frameID, urlString) }
    }

    @objc(browserTabController:didSubmitPasswordInTabWithID:urlString:username:password:)
    nonisolated func browserTabController(
        _: BrowserTabController,
        didSubmitPasswordInTabWithID tabID: String,
        urlString: String,
        username: String,
        password: String,
    ) {
        MainActor.assumeIsolated { onPasswordSubmitted?(tabID, urlString, username, password) }
    }
}
