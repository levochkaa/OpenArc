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

    struct FindRequest: Equatable {
        let text: String
        let forward: Bool
        let matchCase: Bool
        let findNext: Bool
    }

    let hostView = NSView(frame: .zero)

    var onTabCreated: ((String, String, String, Bool) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)?
    var onLoadingStateChanged: ((String, Bool) -> Void)?
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)?
    var onDownloadUpdated: ((BrowserDownloadUpdate) -> Void)?

    private(set) var createdTabRequests = [CreatedTabRequest]()
    private(set) var selectedTabIDs = [String]()
    private(set) var deselectActiveTabCount = 0
    private(set) var activeTabNavigationURLStrings = [String]()
    private(set) var closedTabRequests = [CloseTabRequest]()
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
    private(set) var castCount = 0
    var webAppManifestPayloadJSON: String?
    private(set) var webAppManifestRequestCount = 0
    private(set) var zoomLevels = [Double]()
    private(set) var goBackCount = 0
    private(set) var goForwardCount = 0
    private(set) var prepareForCefShutdownCount = 0

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
            isActive: isActive
        )
        createdTabRequests.append(request)
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

    func selectTab(withID tabID: String) {
        activeTabID = tabID
        selectedTabIDs.append(tabID)
    }

    func deselectActiveTab() {
        activeTabID = nil
        deselectActiveTabCount += 1
    }

    func navigateActiveTab(toURLString urlString: String) {
        activeTabNavigationURLStrings.append(urlString)
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

    func captureFullPageActiveTabToPasteboard() {
        captureFullPageToPasteboardCount += 1
    }

    func pasteAndMatchStyleActiveTab() {
        pasteAndMatchStyleCount += 1
    }

    func printActiveTab() {
        printCount += 1
    }

    func castActiveTab() {
        castCount += 1
    }

    func requestActiveTabWebAppManifest() -> String? {
        webAppManifestRequestCount += 1
        return webAppManifestPayloadJSON
    }

    func setActiveTabZoomLevel(_ zoomLevel: Double) {
        zoomLevels.append(zoomLevel)
    }

    func findInActiveTab(text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        findRequests.append(
            FindRequest(
                text: text,
                forward: forward,
                matchCase: matchCase,
                findNext: findNext
            )
        )
    }

    func stopFindingInActiveTab(clearSelection: Bool) {
        stopFindingClearSelectionRequests.append(clearSelection)
    }

    func closeTab(withID tabID: String, forceClose: Bool) {
        closedTabRequests.append(CloseTabRequest(id: tabID, forceClose: forceClose))
    }

    func prepareForCefShutdown() {
        prepareForCefShutdownCount += 1
    }

    func emitUpdate(
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        faviconURLString: String? = nil
    ) {
        onTabUpdated?(id, title, urlString, faviconURLString)
    }

    func emitCreatedTab(
        id: String,
        title: String? = nil,
        urlString: String,
        isActive: Bool
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

    // MARK: Private

    private var pendingCreateRequests = [CreatedTabRequest]()
    private var nextTabNumber = 0
    private var activeTabID: String?

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
    // MARK: Lifecycle

    init(loadedSnapshot: BrowserTabSessionSnapshot? = nil) {
        self.loadedSnapshot = loadedSnapshot
    }

    // MARK: Internal

    var loadedSnapshot: BrowserTabSessionSnapshot?
    private(set) var savedSnapshots = [BrowserTabSessionSnapshot]()

    func loadSnapshot() -> BrowserTabSessionSnapshot? {
        loadedSnapshot
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        savedSnapshots.append(snapshot)
    }
}

// MARK: - InMemorySessionPreferencesStore

final class InMemorySessionPreferencesStore: BrowserSessionPreferencesStoring {
    // MARK: Lifecycle

    init(
        storedSelectedTabIndex: Int? = nil,
        storedSelectedSpaceIndex: Int? = nil,
        storedSidebarWidth: CGFloat? = nil,
        storedTemporaryTabLifetime: BrowserTemporaryTabLifetime = .defaultValue
    ) {
        self.storedSelectedTabIndex = storedSelectedTabIndex
        self.storedSelectedSpaceIndex = storedSelectedSpaceIndex
        self.storedSidebarWidth = storedSidebarWidth
        self.storedTemporaryTabLifetime = storedTemporaryTabLifetime
    }

    // MARK: Internal

    var storedSelectedTabIndex: Int?
    var storedSelectedSpaceIndex: Int?
    var storedSidebarWidth: CGFloat?
    var storedTemporaryTabLifetime: BrowserTemporaryTabLifetime

    private(set) var savedSelectedTabIndices = [Int?]()
    private(set) var savedSelectedSpaceIndices = [Int?]()
    private(set) var savedSidebarWidths = [CGFloat]()
    private(set) var savedTemporaryTabLifetimes = [BrowserTemporaryTabLifetime]()

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
    // MARK: Lifecycle

    init(suggestionsByQuery: [String: [String]] = [:]) {
        self.suggestionsByQuery = suggestionsByQuery
    }

    // MARK: Internal

    var suggestionsByQuery: [String: [String]]
    private(set) var requestedQueries = [String]()

    func suggestions(for query: String, maximumCount: Int) -> [String] {
        requestedQueries.append(query)
        return Array((suggestionsByQuery[query] ?? []).prefix(maximumCount))
    }
}

// MARK: - FakeBrowserExtensionManager

@MainActor final class FakeBrowserExtensionManager: BrowserExtensionManaging {
    // MARK: Lifecycle

    init(extensions: [BrowserExtension] = []) {
        self.extensions = extensions
    }

    // MARK: Internal

    var extensions: [BrowserExtension]
    var actionResults = [String: BrowserExtensionActionResult]()
    private(set) var actionRequests = [String]()
    private(set) var enabledStateRequests = [(id: String, isEnabled: Bool)]()
    private(set) var removedExtensionIDs = [String]()

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

    // MARK: Private

    private var nextPanelNumber = 0
    private var activePanelID: String?
}

// MARK: - FakeBrowserExtensionActionPopupDriver

@MainActor final class FakeBrowserExtensionActionPopupDriver: BrowserExtensionActionPopupDriving {
    // MARK: Internal

    let hostView = NSView(frame: .zero)

    private(set) var openedURLStrings = [String]()
    private(set) var closedPopupIDs = [String]()
    private(set) var closeAllPopupsCount = 0

    func openPopup(urlString: String) -> String {
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

    // MARK: Private

    private var nextPopupNumber = 0
}
