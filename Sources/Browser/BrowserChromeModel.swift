import AppKit
import Combine
import Foundation

enum BrowserInternalPageRouting {
    static let settingsURL = URL(string: "tb://settings/")!
}

@MainActor
final class BrowserChromeModel: NSObject, ObservableObject {
    nonisolated static let defaultSidebarWidth: CGFloat = 224
    nonisolated static let minSidebarWidth: CGFloat = defaultSidebarWidth
    nonisolated static let maxSidebarWidth: CGFloat = defaultSidebarWidth * 2
    nonisolated static let defaultNewTabURLString = "https://www.google.com"
    nonisolated static let automaticArchivalCheckInterval: TimeInterval = 60 * 60

    struct Tab: Identifiable, Equatable {
        let id: String
        var title: String
        var userTitleOverride: String?
        var urlString: String
        var faviconURLString: String?
        var isPinned = false
        var lastActivityAt = Date()
        var canGoBack = false
        var canGoForward = false
        var isLoading = false

        var displayTitle: String {
            let trimmedUserTitleOverride = userTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedUserTitleOverride.isEmpty {
                return trimmedUserTitleOverride
            }

            return pageTitle
        }

        var pageTitle: String {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }

            if
                let url = URL(string: urlString),
                let host = url.host,
                !host.isEmpty
            {
                return host
            }

            return BrowserStrings.newTabTitle
        }

        var faviconURL: URL? {
            if
                let faviconURLString,
                let faviconURL = URL(string: faviconURLString)
            {
                return faviconURL
            }

            guard
                !urlString.isEmpty,
                let encodedURL = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else {
                return nil
            }

            return URL(string: "https://www.google.com/s2/favicons?sz=64&domain_url=\(encodedURL)")
        }

        var pageURL: URL? {
            URL(string: urlString)
        }
    }

    enum BrowserInternalPage: Equatable {
        case settings
        case extensions
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedTabID: String?
    @Published var isSidebarVisible = true
    @Published private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth
    @Published private(set) var temporaryTabLifetime: BrowserTemporaryTabLifetime
    @Published private(set) var isFindBarPresented = false
    @Published private(set) var findBarFocusRequest = 0
    @Published private(set) var findResultMatchCount: Int?
    @Published private(set) var browserExtensions: [BrowserExtension] = []
    @Published var findQuery = "" {
        didSet {
            guard findQuery != oldValue else {
                return
            }

            handleFindQueryChange()
        }
    }

    let hostView: NSView
    lazy var commandBarModel: BrowserCommandBarModel = .init(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        submitHandler: { [weak self] resolvedURLString in
            self?.openResolvedSelectionInNewTab(resolvedURLString)
        }
    )
    lazy var currentPageCommandBarModel: BrowserCommandBarModel = .init(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        submitHandler: { [weak self] resolvedURLString in
            self?.navigateSelectedTab(toURLString: resolvedURLString)
        }
    )

    private let tabDriver: BrowserTabDriving
    private let sessionSnapshotStore: BrowserTabSessionSnapshotStoring
    private let sessionPreferencesStore: BrowserSessionPreferencesStoring
    private let newTabURLString: String
    private let commandBarSuggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
    private let extensionManager: any BrowserExtensionManaging
    private let windowTitleHandler: (String) -> Void
    private let allTabsClosedHandler: () -> Void
    private let dateProvider: () -> Date

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private var isPersistenceEnabled = true
    private var isRestoringSession = false
    private var pendingRestoredSelectedTabIndex: Int?
    private var pendingRestoredTabs: [BrowserTabSessionSnapshotTab] = []
    private var remainingRestoredTabCreations = 0
    private var automaticArchivalTimer: Timer?

    private(set) var isContextReady = false
    var isShuttingDown = false

    var canCreateTab: Bool {
        isContextReady && !isShuttingDown
    }

    var canReload: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canStopLoading: Bool {
        canCreateTab && (selectedTab?.isLoading ?? false)
    }

    var canSavePage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canPasteAndMatchStyle: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canFindInPage: Bool {
        canCreateTab && selectedTab != nil
    }

    var canPresentFindInPage: Bool {
        canFindInPage
    }

    var canStepThroughFindMatches: Bool {
        canFindInPage && isFindBarPresented && !findQuery.isEmpty && findResultMatchCount != 0
    }

    var canPrintPage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canCopySelectedTabLink: Bool {
        selectedTab != nil
    }

    var selectedTabUsesWindowedBrowser: Bool {
        guard let selectedTab else {
            return false
        }

        return Self.usesWindowedBrowser(for: selectedTab.urlString)
    }

    var selectedTabInternalPage: BrowserInternalPage? {
        selectedTab.flatMap { Self.internalPage(for: $0.urlString) }
    }

    var canArchiveSelectedTab: Bool {
        selectedTab != nil && !isShuttingDown
    }

    var canClearTemporaryTabs: Bool {
        hasTemporaryTabs && !isShuttingDown
    }

    var canGoBack: Bool {
        selectedTab?.canGoBack ?? false
    }

    var canGoForward: Bool {
        selectedTab?.canGoForward ?? false
    }

    var hasTabs: Bool {
        !tabs.isEmpty
    }

    var pinnedTabs: [Tab] {
        tabs.filter(\.isPinned)
    }

    var temporaryTabs: [Tab] {
        tabs.filter { !$0.isPinned }
    }

    var hasTemporaryTabs: Bool {
        tabs.contains { !$0.isPinned }
    }

    init(
        tabDriver: BrowserTabDriving,
        sessionSnapshotStore: BrowserTabSessionSnapshotStoring,
        sessionPreferencesStore: BrowserSessionPreferencesStoring,
        newTabURLString: String = BrowserChromeModel.defaultNewTabURLString,
        commandBarSuggestionProvider: BrowserSuggestionProviding = BrowserGoogleSuggestionService(),
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver(),
        extensionManager: any BrowserExtensionManaging,
        dateProvider: @escaping () -> Date = Date.init,
        windowTitleHandler: @escaping (String) -> Void,
        allTabsClosedHandler: @escaping () -> Void
    ) {
        self.tabDriver = tabDriver
        self.sessionSnapshotStore = sessionSnapshotStore
        self.sessionPreferencesStore = sessionPreferencesStore
        self.newTabURLString = newTabURLString
        self.commandBarSuggestionProvider = commandBarSuggestionProvider
        self.navigationResolver = navigationResolver
        self.extensionManager = extensionManager
        temporaryTabLifetime = sessionPreferencesStore.loadTemporaryTabLifetime()
        self.dateProvider = dateProvider
        self.windowTitleHandler = windowTitleHandler
        self.allTabsClosedHandler = allTabsClosedHandler
        hostView = tabDriver.hostView

        super.init()
        tabDriver.onTabCreated = { [weak self] tabID, title, urlString in
            self?.handleCreatedTab(id: tabID, title: title, urlString: urlString)
        }
        tabDriver.onTabUpdated = { [weak self] tabID, title, urlString, faviconURLString in
            self?.handleUpdatedTab(
                id: tabID,
                title: title,
                urlString: urlString,
                faviconURLString: faviconURLString
            )
        }
        tabDriver.onTabClosed = { [weak self] tabID in
            self?.handleClosedTab(id: tabID)
        }
        tabDriver.onNavigationStateChanged = { [weak self] tabID, canGoBack, canGoForward in
            self?.handleNavigationStateChange(
                id: tabID,
                canGoBack: canGoBack,
                canGoForward: canGoForward
            )
        }
        tabDriver.onLoadingStateChanged = { [weak self] tabID, isLoading in
            self?.handleLoadingStateChange(id: tabID, isLoading: isLoading)
        }
        tabDriver.onFindResultChanged = { [weak self] tabID, matchCount, activeMatchOrdinal, finalUpdate in
            self?.handleFindResult(
                id: tabID,
                matchCount: matchCount,
                activeMatchOrdinal: activeMatchOrdinal,
                finalUpdate: finalUpdate
            )
        }
        updateWindowTitle()
    }

    func handleContextReady() {
        guard !isContextReady else {
            return
        }

        isContextReady = true
        restoreSidebarWidthIfNeeded()
        refreshBrowserExtensions()
        startAutomaticArchivalTimerIfNeeded()

        if restoreSessionIfAvailable() {
            return
        }

        ensureInitialTab()
        archiveExpiredTemporaryTabs()
    }

    func prepareForTermination() {
        guard !isShuttingDown else {
            return
        }

        automaticArchivalTimer?.invalidate()
        automaticArchivalTimer = nil
        persistSidebarWidthPreferenceIfAllowed()
        persistCurrentSessionIfAllowed()
        isShuttingDown = true
        isPersistenceEnabled = false
    }

    func createNewTab() {
        createTab(withURLString: newTabURLString)
    }

    func openURLInNewTab(_ url: URL) {
        createTab(withURLString: url.absoluteString)
    }

    func togglePinned(forTabID tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return
        }

        let targetPinnedState = !tab.isPinned
        let targetSectionIndex = targetPinnedState ? pinnedTabs.count : temporaryTabs.count
        moveTab(withID: tabID, toPinnedState: targetPinnedState, atSectionIndex: targetSectionIndex)
    }

    func canMoveTab(withID tabID: String, toPinnedState isPinned: Bool, atSectionIndex sectionIndex: Int) -> Bool {
        guard
            let reorderedTabs = reorderedTabs(
                movingTabID: tabID,
                toPinnedState: isPinned,
                requestedSectionIndex: sectionIndex
            )
        else {
            return false
        }

        return reorderedTabs != tabs
    }

    func moveTab(withID tabID: String, toPinnedState isPinned: Bool, atSectionIndex sectionIndex: Int) {
        guard
            var reorderedTabs = reorderedTabs(
                movingTabID: tabID,
                toPinnedState: isPinned,
                requestedSectionIndex: sectionIndex
            ),
            reorderedTabs != tabs
        else {
            return
        }

        if let movedTabIndex = reorderedTabs.firstIndex(where: { $0.id == tabID }) {
            reorderedTabs[movedTabIndex].lastActivityAt = dateProvider()
        }

        tabs = reorderedTabs
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    func clearTemporaryTabs() {
        let temporaryTabIDs = temporaryTabs.map(\.id)
        for tabID in temporaryTabIDs {
            closeTab(id: tabID)
        }
    }

    func setTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime) {
        guard temporaryTabLifetime != lifetime else {
            return
        }

        temporaryTabLifetime = lifetime
        sessionPreferencesStore.saveTemporaryTabLifetime(lifetime)
        archiveExpiredTemporaryTabs()
    }

    func handleApplicationDidBecomeActive() {
        archiveExpiredTemporaryTabs()
        refreshBrowserExtensions()
    }

    func archiveExpiredTemporaryTabs() {
        guard isContextReady, !isShuttingDown else {
            return
        }

        let cutoffDate = dateProvider().addingTimeInterval(-temporaryTabLifetime.timeInterval)
        let tabIDsToArchive = tabs.compactMap { tab -> String? in
            guard
                !tab.isPinned,
                tab.id != selectedTabID,
                tab.lastActivityAt <= cutoffDate
            else {
                return nil
            }

            return tab.id
        }

        for tabID in tabIDsToArchive {
            closeTab(id: tabID)
        }
    }

    func presentCommandBar() {
        guard canCreateTab else {
            return
        }

        dismissFindBar()
        currentPageCommandBarModel.dismiss()
        commandBarModel.present()
    }

    func toggleCommandBar() {
        guard canCreateTab else {
            return
        }

        if commandBarModel.isPresented {
            commandBarModel.dismiss()
        } else {
            dismissFindBar()
            currentPageCommandBarModel.dismiss()
            commandBarModel.present()
        }
    }

    func dismissCommandBar() {
        commandBarModel.dismiss()
        currentPageCommandBarModel.dismiss()
    }

    func presentCurrentPageCommandBar() {
        guard
            canCreateTab,
            let selectedTab
        else {
            return
        }

        dismissFindBar()
        commandBarModel.dismiss()
        currentPageCommandBarModel.present(initialQuery: selectedTab.urlString)
    }

    func presentFindBar() {
        guard canFindInPage else {
            return
        }

        commandBarModel.dismiss()
        currentPageCommandBarModel.dismiss()
        isFindBarPresented = true
        findBarFocusRequest += 1
        findResultMatchCount = nil
        runFind(forward: true, findNext: false)
    }

    func presentFindInPage() -> Bool {
        guard canPresentFindInPage else {
            return false
        }

        presentFindBar()
        return isFindBarPresented
    }

    func dismissFindBar() {
        guard isFindBarPresented else {
            return
        }

        isFindBarPresented = false
        findResultMatchCount = nil
        tabDriver.stopFindingInActiveTab(clearSelection: true)
    }

    func findNextInPage() {
        guard canStepThroughFindMatches else {
            return
        }

        runFind(forward: true, findNext: true)
    }

    func findPreviousInPage() {
        guard canStepThroughFindMatches else {
            return
        }

        runFind(forward: false, findNext: true)
    }

    func reloadCurrentTab() {
        guard canReload else {
            return
        }

        tabDriver.reloadActiveTab()
    }

    func forceReloadCurrentTab() {
        guard canReload else {
            return
        }

        tabDriver.reloadActiveTabIgnoringCache()
    }

    func stopLoadingCurrentTab() {
        guard canStopLoading else {
            return
        }

        tabDriver.stopLoadingActiveTab()
    }

    func saveCurrentPage() {
        guard canSavePage, let selectedTab else {
            return
        }

        tabDriver.saveActiveTab(withSuggestedName: selectedTab.pageTitle)
    }

    @discardableResult
    func pasteAndMatchStyleCurrentTab() -> Bool {
        guard canPasteAndMatchStyle else {
            return false
        }

        tabDriver.pasteAndMatchStyleActiveTab()
        return true
    }

    func printCurrentPage() {
        guard canPrintPage else {
            return
        }

        tabDriver.printActiveTab()
    }

    @discardableResult
    func copySelectedTabLink() -> Bool {
        guard let selectedTabID else {
            return false
        }

        return copyTabLink(forTabID: selectedTabID)
    }

    @discardableResult
    func copyTabLink(forTabID tabID: String) -> Bool {
        guard
            let urlString = tabURLString(forTabID: tabID),
            !urlString.isEmpty
        else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(urlString, forType: .string)
    }

    func refreshBrowserExtensions() {
        browserExtensions = extensionManager.installedExtensions()
    }

    func openExtensionsManager() {
        openURLInNewTab(URL(string: BrowserExtensionRouting.extensionsURLString)!)
    }

    func openExtensionDetails(id: String) {
        openURLInNewTab(URL(string: BrowserExtensionRouting.detailsURLString(forExtensionID: id))!)
    }

    func openExtensionStore() {
        openURLInNewTab(URL(string: BrowserExtensionRouting.chromeWebStoreURLString)!)
    }

    @discardableResult
    func setExtension(id: String, isEnabled: Bool) -> Bool {
        guard extensionManager.setExtension(id: id, isEnabled: isEnabled) else {
            return false
        }

        refreshBrowserExtensions()
        return true
    }

    @discardableResult
    func removeExtension(id: String) -> Bool {
        guard extensionManager.removeExtension(id: id) else {
            return false
        }

        refreshBrowserExtensions()
        return true
    }

    func goBack() {
        guard canGoBack else {
            return
        }

        tabDriver.goBackActiveTab()
    }

    func goForward() {
        guard canGoForward else {
            return
        }

        tabDriver.goForwardActiveTab()
    }

    func closeAllTabs() {
        let openTabIDs = tabs.map(\.id)
        if isShuttingDown {
            closingTabIDs.formUnion(openTabIDs)
            for tabID in openTabIDs {
                tabDriver.closeTab(withID: tabID, forceClose: true)
            }
            return
        }

        for tabID in openTabIDs {
            closeTab(id: tabID)
        }
    }

    func closeTabsBelow(id: String) {
        for tabID in tabIDsBelowInSidebarOrder(forTabID: id) {
            closeTab(id: tabID)
        }
    }

    @discardableResult
    func archiveSelectedTab() -> Bool {
        guard canArchiveSelectedTab, let selectedTabID else {
            return false
        }

        closeTab(id: selectedTabID)
        return true
    }

    func hasTabsBelow(id: String) -> Bool {
        !tabIDsBelowInSidebarOrder(forTabID: id).isEmpty
    }

    func selectTab(id: String) {
        guard
            tabs.contains(where: { $0.id == id }),
            selectedTabID != id,
            !closingTabIDs.contains(id)
        else {
            return
        }

        dismissCommandBar()

        selectedTabID = id
        findResultMatchCount = nil
        tabDriver.selectTab(withID: id)
        touchTab(id: id)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        runFind(forward: true, findNext: false)
    }

    func closeTab(id: String, forceClose: Bool = false) {
        guard
            let closingIndex = tabs.firstIndex(where: { $0.id == id }),
            !closingTabIDs.contains(id)
        else {
            return
        }

        let isReplacingLastTab = tabs.count == 1 && !isShuttingDown
        closingTabIDs.insert(id)

        if isReplacingLastTab {
            let replacementID = tabDriver.createTab(withURLString: newTabURLString, makeActive: true)
            selectedTabID = replacementID
            findResultMatchCount = nil
        } else if selectedTabID == id {
            let fallbackTabID = fallbackTabID(afterClosingIndex: closingIndex)
            let fallbackUsesWindowedBrowser = fallbackTabID.map { tabUsesWindowedBrowser(id: $0) } ?? false
            if fallbackUsesWindowedBrowser {
                dismissFindBar()
            }
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                if !fallbackUsesWindowedBrowser {
                    runFind(forward: true, findNext: false)
                }
            }
        }

        tabs.removeAll { $0.id == id }
        tabDriver.closeTab(withID: id, forceClose: forceClose)
        updateWindowTitle()

        if !isReplacingLastTab {
            persistCurrentSessionIfAllowed()
        }
    }

    func setUserTitleOverride(_ titleOverride: String?, forTabID tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let sanitizedTitleOverride = sanitizedUserTitleOverride(from: titleOverride)
        guard tabs[index].userTitleOverride != sanitizedTitleOverride else {
            return
        }

        tabs[index].userTitleOverride = sanitizedTitleOverride
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func setSidebarWidth(_ width: CGFloat) {
        let clampedWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
        guard sidebarWidth != clampedWidth else {
            return
        }
        sidebarWidth = clampedWidth
    }

    func persistSidebarWidthPreferenceIfAllowed() {
        guard isContextReady, isPersistenceEnabled, !isRestoringSession else {
            return
        }

        sessionPreferencesStore.saveSidebarWidth(sidebarWidth)
    }

    private func ensureInitialTab() {
        guard canCreateTab, !hasCreatedInitialTab else {
            return
        }

        hasCreatedInitialTab = true
        createTab(withURLString: newTabURLString)
    }

    private func restoreSessionIfAvailable() -> Bool {
        guard
            let snapshot = sessionSnapshotStore.loadSnapshot(),
            !snapshot.tabURLStrings.isEmpty
        else {
            return false
        }

        isRestoringSession = true
        hasCreatedInitialTab = true
        pendingRestoredSelectedTabIndex = sessionPreferencesStore.loadSelectedTabIndex(
            tabCount: snapshot.tabs.count
        )
        pendingRestoredTabs = snapshot.tabs
        remainingRestoredTabCreations = snapshot.tabs.count

        for (index, tabSnapshot) in snapshot.tabs.enumerated() {
            _ = tabDriver.createTab(withURLString: tabSnapshot.urlString, makeActive: index == 0)
        }

        return true
    }

    private func restoreSidebarWidthIfNeeded() {
        guard let storedSidebarWidth = sessionPreferencesStore.loadSidebarWidth(
            minimum: Self.minSidebarWidth,
            maximum: Self.maxSidebarWidth
        ) else {
            return
        }

        sidebarWidth = storedSidebarWidth
    }

    private func finishSessionRestoreIfNeeded() {
        guard isRestoringSession, remainingRestoredTabCreations == 0 else {
            return
        }

        if
            let selectedTabIndex = pendingRestoredSelectedTabIndex,
            tabs.indices.contains(selectedTabIndex)
        {
            let restoredTabID = tabs[selectedTabIndex].id
            selectedTabID = restoredTabID
            tabDriver.selectTab(withID: restoredTabID)
        } else {
            selectedTabID = tabs.first?.id
        }

        pendingRestoredSelectedTabIndex = nil
        pendingRestoredTabs.removeAll()
        isRestoringSession = false
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        archiveExpiredTemporaryTabs()
    }

    private func persistCurrentSessionIfAllowed() {
        guard isContextReady, isPersistenceEnabled, !isRestoringSession else {
            return
        }

        sessionSnapshotStore.saveSnapshot(
            BrowserTabSessionSnapshot(
                tabs: tabs.map { tab in
                    BrowserTabSessionSnapshotTab(
                        urlString: tab.urlString,
                        userTitleOverride: tab.userTitleOverride,
                        isPinned: tab.isPinned,
                        lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970
                    )
                }
            )
        )
        sessionPreferencesStore.saveSelectedTabIndex(selectedTabIndex)
    }

    private func updateWindowTitle() {
        let title = tabs.first(where: { $0.id == selectedTabID })?.displayTitle ?? BrowserStrings.applicationName
        windowTitleHandler(title)
    }

    private var selectedTab: Tab? {
        guard let selectedTabID else {
            return nil
        }

        return tabs.first(where: { $0.id == selectedTabID })
    }

    private var selectedTabIndex: Int? {
        guard let selectedTabID else {
            return nil
        }

        return tabs.firstIndex(where: { $0.id == selectedTabID })
    }

    private func createTab(withURLString urlString: String) {
        guard canCreateTab else {
            return
        }

        let tabID = tabDriver.createTab(withURLString: urlString, makeActive: true)
        selectedTabID = tabID
        findResultMatchCount = nil
        updateWindowTitle()
    }

    private func openResolvedSelectionInNewTab(_ resolvedURLString: String) {
        createTab(withURLString: resolvedURLString)
    }

    private func navigateSelectedTab(toURLString urlString: String) {
        guard canCreateTab, selectedTabID != nil else {
            return
        }

        tabDriver.navigateActiveTab(toURLString: urlString)
    }

    private func tabURLString(forTabID tabID: String) -> String? {
        tabs.first(where: { $0.id == tabID })?.urlString
    }

    private func tabIDsBelowInSidebarOrder(forTabID tabID: String) -> [String] {
        let sidebarTabIDs = (pinnedTabs + temporaryTabs).map(\.id)
        guard let tabIndex = sidebarTabIDs.firstIndex(of: tabID) else {
            return []
        }

        return Array(sidebarTabIDs.dropFirst(tabIndex + 1))
    }
}

@MainActor
private extension BrowserChromeModel {
    func startAutomaticArchivalTimerIfNeeded() {
        guard automaticArchivalTimer == nil else {
            return
        }

        automaticArchivalTimer = Timer.scheduledTimer(
            withTimeInterval: Self.automaticArchivalCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.archiveExpiredTemporaryTabs()
            }
        }
    }

    func sanitizedUserTitleOverride(from titleOverride: String?) -> String? {
        guard let titleOverride else {
            return nil
        }

        let trimmedTitleOverride = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitleOverride.isEmpty ? nil : trimmedTitleOverride
    }

    func fallbackTabID(afterClosingIndex closingIndex: Int) -> String? {
        let nextIndex = closingIndex + 1
        if tabs.indices.contains(nextIndex) {
            return tabs[nextIndex].id
        }

        let previousIndex = closingIndex - 1
        if tabs.indices.contains(previousIndex) {
            return tabs[previousIndex].id
        }

        return nil
    }

    func tabUsesWindowedBrowser(id: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return false
        }

        return Self.usesWindowedBrowser(for: tab.urlString)
    }

    static func usesWindowedBrowser(for _: String) -> Bool {
        false
    }

    static func internalPage(for urlString: String) -> BrowserInternalPage? {
        if urlString.caseInsensitiveCompare("about:settings") == .orderedSame {
            return .settings
        }

        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        guard scheme == "tb" || scheme == "chrome" else {
            return nil
        }

        switch host {
        case "settings":
            return .settings
        case "extensions":
            return .extensions
        default:
            return nil
        }
    }

    func handleCreatedTab(id: String, title: String, urlString: String) {
        let restoredTab = isRestoringSession && !pendingRestoredTabs.isEmpty ? pendingRestoredTabs.removeFirst() : nil
        tabs.append(
            Tab(
                id: id,
                title: title,
                userTitleOverride: restoredTab?.userTitleOverride,
                urlString: urlString,
                faviconURLString: nil,
                isPinned: restoredTab?.isPinned ?? false,
                lastActivityAt: restoredTab.flatMap(lastActivityDate(from:)) ?? dateProvider()
            )
        )

        if selectedTabID == nil {
            selectedTabID = id
        }

        if isRestoringSession {
            remainingRestoredTabCreations = max(remainingRestoredTabCreations - 1, 0)
            finishSessionRestoreIfNeeded()
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func handleFindQueryChange() {
        findResultMatchCount = nil
        guard isFindBarPresented else {
            return
        }

        runFind(forward: true, findNext: false)
    }

    private func runFind(forward: Bool, findNext: Bool) {
        guard canFindInPage, isFindBarPresented else {
            return
        }

        if !findNext {
            findResultMatchCount = nil
        }

        guard !findQuery.isEmpty else {
            tabDriver.stopFindingInActiveTab(clearSelection: true)
            return
        }

        tabDriver.findInActiveTab(
            text: findQuery,
            forward: forward,
            matchCase: false,
            findNext: findNext
        )
    }

    func handleFindResult(
        id: String,
        matchCount: Int,
        activeMatchOrdinal _: Int,
        finalUpdate: Bool
    ) {
        guard id == selectedTabID, isFindBarPresented, !findQuery.isEmpty else {
            return
        }

        if finalUpdate || matchCount > 0 {
            findResultMatchCount = max(matchCount, 0)
        }
    }

    func handleUpdatedTab(
        id: String,
        title: String?,
        urlString: String?,
        faviconURLString: String?
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        var didChangePersistentURL = false

        if let title {
            tabs[index].title = title
        }

        if let urlString, tabs[index].urlString != urlString {
            tabs[index].urlString = urlString
            tabs[index].lastActivityAt = dateProvider()
            didChangePersistentURL = true
        }

        if let faviconURLString {
            tabs[index].faviconURLString = faviconURLString
        }

        updateWindowTitle()

        if didChangePersistentURL {
            persistCurrentSessionIfAllowed()
        }
    }

    func handleClosedTab(id: String) {
        closingTabIDs.remove(id)
        if tabs.contains(where: { $0.id == id }) {
            tabs.removeAll { $0.id == id }
        }

        if selectedTabID == id {
            selectedTabID = tabs.first?.id
            if let selectedTabID {
                tabDriver.selectTab(withID: selectedTabID)
            }
        }

        var shouldPersist = true
        if tabs.isEmpty, selectedTabID == nil {
            selectedTabID = nil
            hasCreatedInitialTab = false

            if isShuttingDown {
                allTabsClosedHandler()
            } else if isContextReady {
                shouldPersist = false
                ensureInitialTab()
            }
        }

        updateWindowTitle()

        if shouldPersist {
            persistCurrentSessionIfAllowed()
        }
    }

    func handleNavigationStateChange(id: String, canGoBack: Bool, canGoForward: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        tabs[index].canGoBack = canGoBack
        tabs[index].canGoForward = canGoForward
    }

    func handleLoadingStateChange(id: String, isLoading: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        tabs[index].isLoading = isLoading
    }

    func touchTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        tabs[index].lastActivityAt = dateProvider()
    }
}

@MainActor
extension BrowserChromeModel {
    func reorderedTabs(
        movingTabID: String,
        toPinnedState isPinned: Bool,
        requestedSectionIndex: Int
    ) -> [Tab]? {
        guard let movingTab = tabs.first(where: { $0.id == movingTabID }) else {
            return nil
        }

        let movingWithinTargetSection = movingTab.isPinned == isPinned
        let sourceSectionTabs = movingTab.isPinned ? pinnedTabs : temporaryTabs
        let sourceSectionIndex = sourceSectionTabs.firstIndex(where: { $0.id == movingTabID })

        var updatedPinnedTabs = pinnedTabs.filter { $0.id != movingTabID }
        var updatedTemporaryTabs = temporaryTabs.filter { $0.id != movingTabID }
        var updatedTab = movingTab
        updatedTab.isPinned = isPinned

        if isPinned {
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedPinnedTabs.count
            )
            updatedPinnedTabs.insert(updatedTab, at: destinationIndex)
        } else {
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedTemporaryTabs.count
            )
            updatedTemporaryTabs.insert(updatedTab, at: destinationIndex)
        }

        return updatedPinnedTabs + updatedTemporaryTabs
    }
}

@MainActor
private extension BrowserChromeModel {
    func adjustedSectionIndex(
        _ requestedSectionIndex: Int,
        movingWithinTargetSection: Bool,
        sourceSectionIndex: Int?,
        sectionCount: Int
    ) -> Int {
        var adjustedSectionIndex = max(requestedSectionIndex, 0)

        if
            movingWithinTargetSection,
            let sourceSectionIndex,
            sourceSectionIndex < adjustedSectionIndex
        {
            adjustedSectionIndex -= 1
        }

        return min(max(adjustedSectionIndex, 0), sectionCount)
    }

    func lastActivityDate(from snapshotTab: BrowserTabSessionSnapshotTab) -> Date? {
        guard let lastActivityTimestamp = snapshotTab.lastActivityTimestamp else {
            return nil
        }

        return Date(timeIntervalSince1970: lastActivityTimestamp)
    }
}
