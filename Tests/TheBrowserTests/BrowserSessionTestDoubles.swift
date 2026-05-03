import AppKit
import CoreGraphics
import Foundation

@MainActor
final class FakeBrowserTabDriver: BrowserTabDriving {
    struct CreatedTabRequest: Equatable {
        let id: String
        let urlString: String
        let makeActive: Bool
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

    var onTabCreated: ((String, String, String) -> Void)?
    var onTabUpdated: ((String, String?, String?, String?) -> Void)?
    var onTabClosed: ((String) -> Void)?
    var onNavigationStateChanged: ((String, Bool, Bool) -> Void)?
    var onLoadingStateChanged: ((String, Bool) -> Void)?
    var onFindResultChanged: ((String, Int, Int, Bool) -> Void)?

    private(set) var createdTabRequests: [CreatedTabRequest] = []
    private(set) var selectedTabIDs: [String] = []
    private(set) var deselectActiveTabCount = 0
    private(set) var activeTabNavigationURLStrings: [String] = []
    private(set) var closedTabRequests: [CloseTabRequest] = []
    private(set) var saveSuggestedNames: [String?] = []
    private(set) var pasteAndMatchStyleCount = 0
    private(set) var findRequests: [FindRequest] = []
    private(set) var stopFindingClearSelectionRequests: [Bool] = []
    private(set) var reloadCount = 0
    private(set) var forceReloadCount = 0
    private(set) var stopLoadingCount = 0
    private(set) var printCount = 0
    private(set) var goBackCount = 0
    private(set) var goForwardCount = 0

    private var pendingCreateRequests: [CreatedTabRequest] = []
    private var nextTabNumber = 0

    func createTab(withURLString urlString: String, makeActive: Bool) -> String {
        nextTabNumber += 1
        let tabID = "tab-\(nextTabNumber)"
        let request = CreatedTabRequest(id: tabID, urlString: urlString, makeActive: makeActive)
        createdTabRequests.append(request)
        pendingCreateRequests.append(request)
        return tabID
    }

    func flushPendingCreateEvents() {
        let pendingRequests = pendingCreateRequests
        pendingCreateRequests.removeAll()

        for request in pendingRequests {
            onTabCreated?(request.id, defaultTitle(for: request.urlString), request.urlString)
        }
    }

    func selectTab(withID tabID: String) {
        selectedTabIDs.append(tabID)
    }

    func deselectActiveTab() {
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

    func stopLoadingActiveTab() {
        stopLoadingCount += 1
    }

    func saveActiveTab(withSuggestedName suggestedName: String?) {
        saveSuggestedNames.append(suggestedName)
    }

    func pasteAndMatchStyleActiveTab() {
        pasteAndMatchStyleCount += 1
    }

    func printActiveTab() {
        printCount += 1
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

    func emitUpdate(
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        faviconURLString: String? = nil
    ) {
        onTabUpdated?(id, title, urlString, faviconURLString)
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

final class InMemorySessionSnapshotStore: BrowserTabSessionSnapshotStoring {
    var loadedSnapshot: BrowserTabSessionSnapshot?
    private(set) var savedSnapshots: [BrowserTabSessionSnapshot] = []

    init(loadedSnapshot: BrowserTabSessionSnapshot? = nil) {
        self.loadedSnapshot = loadedSnapshot
    }

    func loadSnapshot() -> BrowserTabSessionSnapshot? {
        loadedSnapshot
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        savedSnapshots.append(snapshot)
    }
}

final class InMemorySessionPreferencesStore: BrowserSessionPreferencesStoring {
    var storedSelectedTabIndex: Int?
    var storedSelectedSpaceIndex: Int?
    var storedSidebarWidth: CGFloat?
    var storedTemporaryTabLifetime: BrowserTemporaryTabLifetime

    private(set) var savedSelectedTabIndices: [Int?] = []
    private(set) var savedSelectedSpaceIndices: [Int?] = []
    private(set) var savedSidebarWidths: [CGFloat] = []
    private(set) var savedTemporaryTabLifetimes: [BrowserTemporaryTabLifetime] = []

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

final class FakeSuggestionProvider: BrowserSuggestionProviding {
    var suggestionsByQuery: [String: [String]]
    private(set) var requestedQueries: [String] = []

    init(suggestionsByQuery: [String: [String]] = [:]) {
        self.suggestionsByQuery = suggestionsByQuery
    }

    func suggestions(for query: String, maximumCount: Int) async -> [String] {
        requestedQueries.append(query)
        return Array((suggestionsByQuery[query] ?? []).prefix(maximumCount))
    }
}

@MainActor
final class FakeBrowserExtensionManager: BrowserExtensionManaging {
    var extensions: [BrowserExtension]
    private(set) var enabledStateRequests: [(id: String, isEnabled: Bool)] = []
    private(set) var removedExtensionIDs: [String] = []

    init(extensions: [BrowserExtension] = []) {
        self.extensions = extensions
    }

    func installedExtensions() -> [BrowserExtension] {
        extensions
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
