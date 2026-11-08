// BrowserSessionTestDoubles.swift

import AppKit
import CoreGraphics
import Foundation

// MARK: - FakeBrowserTabDriver

@MainActor final class FakeBrowserTabDriver: BrowserTabDriving {
    // MARK: Internal

    struct CreatedTabRequest: Equatable {
        let id: String
        let urlString: String
        let makeActive: Bool
        let isActive: Bool
    }

    struct CloseTabRequest: Equatable {
        let id: String
        let forceClose: Bool
    }

    struct ConfirmedCloseRequest: Equatable {
        let id: String
        let requestID: String
    }

    struct RetryCreationRequest: Equatable {
        let id: String
        let urlString: String
    }

    struct TargetedNavigationRequest: Equatable {
        let id: String
        let urlString: String
    }

    struct FindRequest: Equatable {
        let text: String
        let forward: Bool
        let matchCase: Bool
        let findNext: Bool
    }

    let hostView = NSView(frame: .zero)

    var onTabCreated: ((String, String, String, Bool) -> Void)?
    var onTabCreationStateChanged: ((String, BrowserTabCreationState) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onDownloadWithoutPage: ((String) -> Void)?
    var onStatusChanged: ((String, String) -> Void)?
    var onTabCloseRequestFinished: ((String, String, BrowserTabCloseOutcome) -> Void)?
    var onTabCloseConfirmationPresented: ((String) -> Void)?
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
    var profileCachePathForNewTabs: String?
    private(set) var createdTabProfilePaths = [String?]()
    var onPeekClosedByUser: ((String, Bool) -> Void)?
    var onSitePermissionRequested: ((BrowserSitePermissionRequest) -> Void)?
    var onSitePermissionRequestDismissed: ((Int) -> Void)?
    var onPeekSitePermissionAnswered: ((Int, Bool?) -> Void)?
    var onMediaStateChanged: ((String, BrowserTabMediaState?) -> Void)?
    var onCaptureChanged: ((String, Bool) -> Void)?
    var onPeekPagesChanged: (([String: String]) -> Void)?
    private(set) var evaluatedScripts = [(tabID: String, code: String)]()
    var onRenderProcessTerminated: ((String, Int) -> Void)?
    private(set) var mediaControls = [(tabID: String, action: BrowserMediaAction)]()
    private(set) var sitePermissionResolutions = [(id: Int, allowed: Bool?)]()
    private(set) var peekSitePermissionRequests = [BrowserSitePermissionRequest]()
    private(set) var peekURLs = [String]()

    private(set) var createdTabRequests = [CreatedTabRequest]()
    private(set) var retryCreationRequests = [RetryCreationRequest]()
    var retryTabCreationAdmissionResult = true
    private(set) var targetedNavigationRequests = [TargetedNavigationRequest]()
    var targetedNavigationAdmissionResult = true
    private(set) var selectedTabIDs = [String]()
    private(set) var visibleTabLayouts = [BrowserTabVisibleLayout?]()
    private(set) var deselectActiveTabCount = 0
    private(set) var activeTabNavigationURLStrings = [String]()
    private(set) var closedTabRequests = [CloseTabRequest]()
    private(set) var confirmedCloseRequests = [ConfirmedCloseRequest]()
    var automaticallyConfirmsCloseRequests = true
    var closeRequestAdmissionResult = true
    private(set) var saveSuggestedNames = [String?]()
    private(set) var captureFullPageToPasteboardCount = 0
    private(set) var pasteAndMatchStyleCount = 0
    private(set) var findRequests = [FindRequest]()
    private(set) var stopFindingClearSelectionRequests = [Bool]()
    private(set) var reloadCount = 0
    private(set) var forceReloadCount = 0
    private(set) var clearCacheAndReloadCount = 0
    private(set) var clearCookiesAndReloadCount = 0
    private(set) var stopLoadingCount = 0
    private(set) var printCount = 0
    private(set) var devToolsCount = 0
    private(set) var pictureInPictureRequests = [(tabID: String, active: Bool)]()
    private(set) var castCount = 0
    var webAppManifestPayloadJSON: String?
    var selectedText: String?
    private(set) var webAppManifestRequestCount = 0
    private(set) var zoomLevels = [Double]()
    private(set) var audioMuteRequests = [(tabID: String, muted: Bool)]()
    private(set) var goBackCount = 0
    private(set) var goForwardCount = 0
    private(set) var prepareForCefShutdownCount = 0

    private(set) var littleWindowURLs = [String]()
    private(set) var signInWindowURLs = [String]()

    private(set) var newLittleWindowCount = 0

    private(set) var closePeeksCount = 0

    /// Engine zoom per tab; tests may share a value to mimic per-site zoom.
    var zoomLevelsByTabID = [String: Double]()

    private(set) var regionCaptures = [CGRect]()
    private(set) var pageActions = [Selector]()
    private(set) var pageFocusCount = 0
    var pageActionResult = true

    /// Site settings by URL; `.default` removes one.
    var siteSettingsByURL = [String: [BrowserSiteSettingKind: BrowserSiteSettingValue]]()

    private(set) var pictureInPictureToggleCount = 0

    var onAddressFormFound: ((String, String, String) -> Void)?
    var onCardFormFound: ((String, String, String) -> Void)?
    var onAddressSubmitted: ((String, String, String) -> Void)?
    private(set) var filledAddresses = [(json: String, frameID: String, origin: String)]()
    var onPasswordFormFound: ((String, String, String) -> Void)?
    var onPasswordSubmitted: ((String, String, String, String) -> Void)?
    private(set) var filledPasswords = [(username: String, password: String, frameID: String, origin: String)]()

    var rendererProcessIDs = [String: Int32]()
    var openPeekSessions = Set<Int>()

    // MARK: Private

    var reportedExtensionTabs = [BrowserExtensionTabReport]()
    var warmTabIDs = [String]()
    var reportedExtensionWindowFocus = false
    var tabIDsByBrowserIdentifier = [Int32: String]()
    var translationRequests = [(tabID: String, language: String)]()
    var nextTranslationStart = BrowserPageTranslationStart.unavailable
    var revertedTranslations = [String]()
    var currentTranslationState = BrowserPageTranslationState.none

    var importedCookies = [BrowserImportedCookie]()
    var devToolsMethods = [String]()
    var devToolsResults = [String: String]()
    var mainFrameFills = [(username: String, password: String)]()

    var onPageFullscreenChanged: ((String, Bool) -> Void)?
    var onTabOpenedFromTab: ((String, String) -> Void)?
    var searchEngineName: (() -> String?)?
    private(set) var exitPageFullscreenCount = 0

    /// Pages this window can give to another window, by tab ID; others close instead.
    var detachablePageTabIDs = Set<String>()
    private(set) var detachedPageTabIDs = [String]()
    private(set) var adoptedPages = [(id: String, page: String, makeActive: Bool)]()

    /// What a picture of a moving page comes back as.
    var movedPagePicture: Data?

    var certificateChain = [Data]()

    private(set) var canceledDownloadIDs = [String]()

    private var pendingCreateRequests = [CreatedTabRequest]()
    private var nextTabNumber = 0
    private var activeTabID: String?

    func exitPageFullscreen() {
        exitPageFullscreenCount += 1
    }

    func rendererProcessIDsByTabID() -> [String: Int32] { rendererProcessIDs }

    func executeDevTools(
        method: String,
        paramsJSON _: String,
        tabID _: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        devToolsMethods.append(method)
        completion(devToolsResults[method] ?? "{}")
    }

    @discardableResult func importCookies(_ cookies: [BrowserImportedCookie]) -> Int {
        importedCookies.append(contentsOf: cookies)
        return cookies.count
    }

    func fillPasswordInMainFrame(username: String, password: String, origin _: String, tabID _: String) -> Bool {
        mainFrameFills.append((username, password))
        return true
    }

    func setWarmTabs(_ tabIDs: [String]) {
        warmTabIDs = tabIDs
    }

    func reportExtensionTabs(windowKey _: String, focused: Bool, tabs: [BrowserExtensionTabReport]) {
        reportedExtensionTabs = tabs
        reportedExtensionWindowFocus = focused
    }

    func tabID(forBrowserIdentifier browserIdentifier: Int32) -> String? { tabIDsByBrowserIdentifier[browserIdentifier]
    }

    func translateTab(withID tabID: String, toLanguage language: String) -> BrowserPageTranslationStart {
        translationRequests.append((tabID, language))
        return nextTranslationStart
    }

    func revertTranslation(ofTabWithID tabID: String) {
        revertedTranslations.append(tabID)
    }

    func translationState(ofTabWithID _: String) -> BrowserPageTranslationState { currentTranslationState }

    func fillAddress(json: String, frameID: String, origin: String, tabID _: String) {
        filledAddresses.append((json, frameID, origin))
    }

    @discardableResult func sendActionToActivePage(_ action: Selector) -> Bool {
        pageActions.append(action)
        return pageActionResult
    }

    func focusActivePage() {
        pageFocusCount += 1
    }

    func showPeek(withURLString urlString: String) {
        peekURLs.append(urlString)
    }

    func showNewLittleWindow() {
        newLittleWindowCount += 1
    }

    func createTab(withURLString urlString: String, makeActive: Bool) -> String {
        nextTabNumber += 1
        let tabID = "tab-\(nextTabNumber)"
        let isActive = makeActive || activeTabID == nil
        if isActive {
            activeTabID = tabID
        }
        let request = CreatedTabRequest(
            id: tabID,
            urlString: urlString,
            makeActive: makeActive,
            isActive: isActive,
        )
        createdTabRequests.append(request)
        createdTabProfilePaths.append(profileCachePathForNewTabs)
        pendingCreateRequests.append(request)
        return tabID
    }

    func flushPendingCreateEvents() {
        let pendingRequests = pendingCreateRequests
        pendingCreateRequests.removeAll()

        for request in pendingRequests {
            onTabCreated?(request.id, defaultTitle(for: request.urlString), request.urlString, request.isActive)
        }
    }

    func retryTabCreation(withID tabID: String, urlString: String) -> Bool {
        retryCreationRequests.append(RetryCreationRequest(id: tabID, urlString: urlString))
        return retryTabCreationAdmissionResult
    }

    func emitTabCreationState(id: String, state: BrowserTabCreationState) {
        onTabCreationStateChanged?(id, state)
    }

    func selectTab(withID tabID: String) {
        activeTabID = tabID
        selectedTabIDs.append(tabID)
    }

    func setVisibleTabLayout(_ layout: BrowserTabVisibleLayout?) {
        visibleTabLayouts.append(layout)
    }

    /// Simulates CEF reporting focus in a visible split pane.
    func simulateTabFocus(_ tabID: String) {
        onTabFocused?(tabID)
    }

    /// Simulates the engine laying out the visible split's panes.
    func simulateSplitPaneLayout(_ tabIDs: [String], frames: [CGRect]) {
        onSplitPaneLayout?(tabIDs, frames)
    }

    /// Simulates the end of a divider drag in the visible split.
    func simulateSplitResize(_ tabIDs: [String], fractions: [Double]) {
        onSplitResized?(tabIDs, fractions)
    }

    func deselectActiveTab() {
        activeTabID = nil
        deselectActiveTabCount += 1
    }

    func navigateActiveTab(toURLString urlString: String) {
        activeTabNavigationURLStrings.append(urlString)
    }

    func navigateTab(withID tabID: String, toURLString urlString: String) -> Bool {
        targetedNavigationRequests.append(TargetedNavigationRequest(id: tabID, urlString: urlString))
        guard targetedNavigationAdmissionResult else { return false }
        if activeTabID == tabID {
            activeTabNavigationURLStrings.append(urlString)
        }
        return true
    }

    func goBackActiveTab() {
        goBackCount += 1
    }

    func goForwardActiveTab() {
        goForwardCount += 1
    }

    func reloadActiveTab() {
        reloadCount += 1
    }

    func reloadActiveTabIgnoringCache() {
        forceReloadCount += 1
    }

    func clearCacheAndReloadActiveTab() {
        clearCacheAndReloadCount += 1
    }

    func clearCookiesAndReloadActiveTab() {
        clearCookiesAndReloadCount += 1
    }

    func stopLoadingActiveTab() {
        stopLoadingCount += 1
    }

    func saveActiveTab(withSuggestedName suggestedName: String?) {
        saveSuggestedNames.append(suggestedName)
    }

    func cancelDownload(id: String) {
        canceledDownloadIDs.append(id)
    }

    func captureActiveTabPicture(completion: @escaping @MainActor (Data?) -> Void) {
        completion(nil)
    }

    func captureFullPageActiveTabToPasteboard() {
        captureFullPageToPasteboardCount += 1
    }

    func captureActiveTabRegionToPasteboard(fraction: CGRect) {
        regionCaptures.append(fraction)
    }

    func pasteAndMatchStyleActiveTab() {
        pasteAndMatchStyleCount += 1
    }

    func printActiveTab() {
        printCount += 1
    }

    func inspectElementsInActiveTab() {}
    func showJavaScriptConsoleForActiveTab() {}
    func navigationEntriesForActiveTab(completion: @escaping @MainActor ([BrowserNavigationEntry], Int) -> Void) {
        completion([], 0)
    }

    func goToHistoryOffsetInActiveTab(_: Int) {}
    func setMediaVolume(_: Double, forTabWithID _: String) {}
    func fillPassword(username: String, password: String, frameID: String, origin: String, tabID _: String) {
        filledPasswords.append((username, password, frameID, origin))
    }

    func evaluateJavaScript(
        _ code: String,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        evaluatedScripts.append((tabID, code))
        completion(nil)
    }

    func showNetworkInspectorForActiveTab() {}

    func showDevToolsForActiveTab() {
        devToolsCount += 1
    }

    func showLittleWindow(withURLString urlString: String) {
        littleWindowURLs.append(urlString)
    }

    func showSignInWindow(withURLString urlString: String) {
        signInWindowURLs.append(urlString)
    }

    func closePeeks() {
        closePeeksCount += 1
    }

    func togglePictureInPictureInActiveTab() {
        pictureInPictureToggleCount += 1
    }

    func setPictureInPicture(_ active: Bool, forTabWithID tabID: String) {
        pictureInPictureRequests.append((tabID, active))
    }

    func castActiveTab() {
        castCount += 1
    }

    func activeTabCertificateChain() -> [Data] {
        certificateChain
    }

    func requestActiveTabWebAppManifest() -> String? {
        webAppManifestRequestCount += 1
        return webAppManifestPayloadJSON
    }

    func requestActiveTabSelectedText() -> String? {
        selectedText
    }

    func setActiveTabZoomLevel(_ zoomLevel: Double) {
        zoomLevels.append(zoomLevel)
        if let activeTabID {
            zoomLevelsByTabID[activeTabID] = zoomLevel
        }
    }

    func zoomLevel(forTabWithID tabID: String) -> Double? {
        zoomLevelsByTabID[tabID]
    }

    func setAudioMuted(_ muted: Bool, forTabWithID tabID: String) {
        audioMuteRequests.append((tabID, muted))
    }

    func resolveSitePermissionRequest(_ id: Int, allowed: Bool?) {
        sitePermissionResolutions.append((id, allowed))
    }

    func controlMedia(_ action: BrowserMediaAction, inTabWithID tabID: String) {
        mediaControls.append((tabID, action))
    }

    func isPeekSessionOpen(_ sessionID: Int) -> Bool {
        openPeekSessions.contains(sessionID)
    }

    func hostPrompt(_: NSView, height _: CGFloat, inPeekSession sessionID: Int) -> Bool {
        openPeekSessions.contains(sessionID)
    }

    func showPeekSitePermissionRequests(_ requests: [BrowserSitePermissionRequest]) {
        peekSitePermissionRequests = requests
    }

    func siteSettings(forURLString urlString: String) -> [BrowserSiteSettingKind: BrowserSiteSettingValue] {
        siteSettingsByURL[urlString] ?? [:]
    }

    func setSiteSetting(
        _ kind: BrowserSiteSettingKind,
        value: BrowserSiteSettingValue,
        forURLString urlString: String,
    ) {
        siteSettingsByURL[urlString, default: [:]][kind] = value == .default ? nil : value
    }

    func findInActiveTab(text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        findRequests.append(
            FindRequest(
                text: text,
                forward: forward,
                matchCase: matchCase,
                findNext: findNext,
            ),
        )
    }

    func stopFindingInActiveTab(clearSelection: Bool) {
        stopFindingClearSelectionRequests.append(clearSelection)
    }

    func closeTab(withID tabID: String, forceClose: Bool) {
        closedTabRequests.append(CloseTabRequest(id: tabID, forceClose: forceClose))
    }

    func detachPage(ofTabWithID tabID: String) -> BrowserTabPageHandoff? {
        guard detachablePageTabIDs.contains(tabID) else { return nil }
        detachedPageTabIDs.append(tabID)
        return BrowserTabPageHandoff(page: tabID as NSString, canGoBack: true, canGoForward: false, isLoading: false)
    }

    func capturePicture(of _: BrowserTabPageHandoff, completion: @escaping @MainActor (Data?) -> Void) {
        completion(movedPagePicture)
    }

    func adoptPage(_ handoff: BrowserTabPageHandoff, makeActive: Bool) -> String? {
        let id = UUID().uuidString
        adoptedPages.append((id, String(describing: handoff.page), makeActive))
        return id
    }

    func requestCloseTab(withID tabID: String, requestID: String) -> Bool {
        guard closeRequestAdmissionResult else { return false }
        confirmedCloseRequests.append(ConfirmedCloseRequest(id: tabID, requestID: requestID))
        closedTabRequests.append(CloseTabRequest(id: tabID, forceClose: false))
        if automaticallyConfirmsCloseRequests {
            emitCloseRequestOutcome(id: tabID, requestID: requestID, outcome: .closed)
        }
        return true
    }

    /// Normal completion preserves the bridge's outcome-before-close ordering.
    /// Suppressing the generic event permits isolated stale-token delivery.
    func emitCloseRequestOutcome(
        id: String, requestID: String, outcome: BrowserTabCloseOutcome, emitsClosedEvent: Bool = true,
    ) {
        onTabCloseRequestFinished?(id, requestID, outcome)
        if outcome == .closed, emitsClosedEvent {
            onTabClosed?(id)
        }
    }

    func prepareForCefShutdown() {
        prepareForCefShutdownCount += 1
    }

    func emitUpdate(
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        faviconURLString: String? = nil,
    ) {
        onTabUpdated?(id, title, urlString, faviconURLString)
    }

    func emitCreatedTab(
        id: String,
        title: String? = nil,
        urlString: String,
        isActive: Bool,
    ) {
        if isActive {
            activeTabID = id
        }
        onTabCreated?(id, title ?? defaultTitle(for: urlString), urlString, isActive)
    }

    func emitClose(id: String) {
        onTabClosed?(id)
    }

    func emitNavigationStateChange(id: String, canGoBack: Bool, canGoForward: Bool) {
        onNavigationStateChanged?(id, canGoBack, canGoForward)
    }

    func emitLoadingStateChange(id: String, isLoading: Bool) {
        onLoadingStateChanged?(id, isLoading)
    }

    func emitFindResult(id: String, matchCount: Int, activeMatchOrdinal: Int = 0, finalUpdate: Bool = true) {
        onFindResultChanged?(id, matchCount, activeMatchOrdinal, finalUpdate)
    }

    func emitDownloadUpdate(_ update: BrowserDownloadUpdate) {
        onDownloadUpdated?(update)
    }

    private func defaultTitle(for urlString: String) -> String {
        guard
            let url = URL(string: urlString),
            let host = url.host,
            !host.isEmpty
        else {
            return BrowserStrings.newTabTitle
        }

        return host
    }
}

// MARK: - InMemorySessionSnapshotStore

final class InMemorySessionSnapshotStore: BrowserTabSessionSnapshotStoring {
    // MARK: Internal

    var loadedSnapshot: BrowserTabSessionSnapshot?
    private(set) var savedSnapshots = [BrowserTabSessionSnapshot]()
    private(set) var savedSyncMoves = [BrowserSyncMoveIntent]()
    var sessionWriteError: Error?
    private(set) var attemptedSessionWriteBatches = [[BrowserSessionWrite]]()
    private(set) var savedSessionWriteBatches = [[BrowserSessionWrite]]()

    init(loadedSnapshot: BrowserTabSessionSnapshot? = nil) {
        self.loadedSnapshot = loadedSnapshot
    }

    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws {
        attemptedSessionWriteBatches.append(writes)
        if let sessionWriteError {
            throw sessionWriteError
        }
        savedSessionWriteBatches.append(writes)
        for write in writes {
            switch write.origin {
            case .local(let syncMove):
                if let syncMove {
                    saveSnapshot(write.snapshot, syncMove: syncMove)
                } else {
                    saveSnapshot(write.snapshot)
                }
            case .remoteProjection: savedSnapshots.append(write.snapshot)
            }
        }
    }

    func loadSnapshot() -> BrowserTabSessionSnapshot? {
        loadedSnapshot
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        savedSnapshots.append(snapshot)
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot, syncMove: BrowserSyncMoveIntent) {
        savedSyncMoves.append(syncMove)
        saveSnapshot(snapshot)
    }
}

// MARK: - InMemorySessionPreferencesStore

final class InMemorySessionPreferencesStore: BrowserSessionPreferencesStoring {
    // MARK: Internal

    var storedSelectedTabIndex: Int?
    var storedSelectedSpaceIndex: Int?
    var storedSidebarWidth: CGFloat?
    var storedTemporaryTabLifetime: BrowserTemporaryTabLifetime

    private(set) var savedSelectedTabIndices = [Int?]()
    private(set) var savedSelectedSpaceIndices = [Int?]()
    private(set) var savedSidebarWidths = [CGFloat]()
    private(set) var savedTemporaryTabLifetimes = [BrowserTemporaryTabLifetime]()

    init(
        storedSelectedTabIndex: Int? = nil,
        storedSelectedSpaceIndex: Int? = nil,
        storedSidebarWidth: CGFloat? = nil,
        storedTemporaryTabLifetime: BrowserTemporaryTabLifetime = .defaultValue,
    ) {
        self.storedSelectedTabIndex = storedSelectedTabIndex
        self.storedSelectedSpaceIndex = storedSelectedSpaceIndex
        self.storedSidebarWidth = storedSidebarWidth
        self.storedTemporaryTabLifetime = storedTemporaryTabLifetime
    }

    func loadSelectedTabIndex(tabCount: Int) -> Int? {
        guard tabCount > 0, let storedSelectedTabIndex else {
            return nil
        }

        return min(max(storedSelectedTabIndex, 0), tabCount - 1)
    }

    func saveSelectedTabIndex(_ index: Int?) {
        storedSelectedTabIndex = index
        savedSelectedTabIndices.append(index)
    }

    func loadSelectedSpaceIndex(spaceCount: Int) -> Int? {
        guard spaceCount > 0, let storedSelectedSpaceIndex else {
            return nil
        }

        return min(max(storedSelectedSpaceIndex, 0), spaceCount - 1)
    }

    func saveSelectedSpaceIndex(_ index: Int?) {
        storedSelectedSpaceIndex = index
        savedSelectedSpaceIndices.append(index)
    }

    func loadSidebarWidth(minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard let storedSidebarWidth else {
            return nil
        }

        return min(max(storedSidebarWidth, minimum), maximum)
    }

    func saveSidebarWidth(_ width: CGFloat) {
        storedSidebarWidth = width
        savedSidebarWidths.append(width)
    }

    func loadTemporaryTabLifetime() -> BrowserTemporaryTabLifetime {
        storedTemporaryTabLifetime
    }

    func saveTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime) {
        storedTemporaryTabLifetime = lifetime
        savedTemporaryTabLifetimes.append(lifetime)
    }
}

// MARK: - FakeSuggestionProvider

final class FakeSuggestionProvider: BrowserSuggestionProviding, @unchecked Sendable {
    // MARK: Internal

    var suggestionsByQuery: [String: [String]]
    private(set) var requestedQueries = [String]()

    init(suggestionsByQuery: [String: [String]] = [:]) {
        self.suggestionsByQuery = suggestionsByQuery
    }

    func suggestions(for query: String, maximumCount: Int) -> [String] {
        requestedQueries.append(query)
        return Array((suggestionsByQuery[query] ?? []).prefix(maximumCount))
    }
}

// MARK: - FakeBrowserExtensionManager

@MainActor final class FakeBrowserExtensionManager: BrowserExtensionManaging {
    // MARK: Internal

    var extensions: [BrowserExtension]
    var actionResults = [String: BrowserExtensionActionResult]()
    private(set) var actionRequests = [String]()
    private(set) var enabledStateRequests = [(id: String, isEnabled: Bool)]()
    private(set) var removedExtensionIDs = [String]()

    init(extensions: [BrowserExtension] = []) {
        self.extensions = extensions
    }

    func installedExtensions() -> [BrowserExtension] {
        extensions
    }

    func runAction(id: String) -> BrowserExtensionActionResult {
        actionRequests.append(id)
        return actionResults[id] ?? .failed
    }

    func setExtension(id: String, isEnabled: Bool) -> Bool {
        enabledStateRequests.append((id: id, isEnabled: isEnabled))

        guard let index = extensions.firstIndex(where: { $0.id == id }) else {
            return false
        }

        extensions[index].isEnabled = isEnabled
        return true
    }

    func removeExtension(id: String) -> Bool {
        removedExtensionIDs.append(id)

        guard extensions.contains(where: { $0.id == id }) else {
            return false
        }

        extensions.removeAll { $0.id == id }
        return true
    }
}

// MARK: - FakeBrowserExtensionSidePanelDriver

@MainActor final class FakeBrowserExtensionSidePanelDriver: BrowserExtensionSidePanelDriving {
    // MARK: Internal

    let hostView = NSView(frame: .zero)
    var onPanelClosed: ((String) -> Void)?

    private(set) var openedURLStrings = [String]()
    private(set) var closedPanelIDs = [String]()
    private(set) var closeAllPanelsCount = 0

    // MARK: Private

    private var nextPanelNumber = 0
    private var activePanelID: String?

    func openPanel(urlString: String) -> String {
        openedURLStrings.append(urlString)
        nextPanelNumber += 1
        let panelID = "panel-\(nextPanelNumber)"
        activePanelID = panelID
        return panelID
    }

    func closePanel(id: String) {
        closedPanelIDs.append(id)
        if activePanelID == id {
            activePanelID = nil
        }
    }

    func closeAllPanels() {
        closeAllPanelsCount += 1
        activePanelID = nil
    }

    func emitClose(id: String) {
        if activePanelID == id {
            activePanelID = nil
        }
        onPanelClosed?(id)
    }
}

// MARK: - FakeBrowserExtensionActionPopupDriver

@MainActor final class FakeBrowserExtensionActionPopupDriver: BrowserExtensionActionPopupDriving {
    // MARK: Internal

    let hostView = NSView(frame: .zero)
    var onContentSizeChange: ((NSSize) -> Void)?

    private(set) var openedURLStrings = [String]()
    private(set) var closedPopupIDs = [String]()
    private(set) var closeAllPopupsCount = 0

    // MARK: Private

    private var nextPopupNumber = 0

    func openPopup(urlString: String, activeTab _: BrowserExtensionPopupPage?) -> String {
        openedURLStrings.append(urlString)
        nextPopupNumber += 1
        return "popup-\(nextPopupNumber)"
    }

    func closePopup(id: String) {
        closedPopupIDs.append(id)
    }

    func closeAllPopups() {
        closeAllPopupsCount += 1
    }
}
