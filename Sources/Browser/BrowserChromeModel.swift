import AppKit
import Combine
import Foundation

// MARK: - BrowserInternalPageRouting

enum BrowserInternalPageRouting {
    static let settingsURL = URL(string: "tb://settings/")!
}

// MARK: - BrowserChromeModel

@MainActor final class BrowserChromeModel: NSObject, ObservableObject {
    // MARK: Lifecycle

    init(
        tabDriver: BrowserTabDriving,
        sessionSnapshotStore: BrowserTabSessionSnapshotStoring,
        sessionPreferencesStore: BrowserSessionPreferencesStoring,
        newTabURLString: String = BrowserChromeModel.defaultNewTabURLString,
        commandBarSuggestionProvider: BrowserSuggestionProviding = BrowserGoogleSuggestionService(),
        navigationResolver: BrowserNavigationResolver? = nil,
        userPreferencesStore: BrowserUserPreferencesStore = BrowserUserPreferencesStore(),
        shortcutStore: BrowserShortcutStore = BrowserShortcutStore(),
        extensionManager: any BrowserExtensionManaging,
        dateProvider: @escaping () -> Date = Date.init,
        spaceIDProvider: @escaping () -> String = { UUID().uuidString },
        windowTitleHandler: @escaping (String) -> Void,
        allTabsClosedHandler: @escaping () -> Void
    ) {
        self.tabDriver = tabDriver
        self.sessionSnapshotStore = sessionSnapshotStore
        self.sessionPreferencesStore = sessionPreferencesStore
        self.newTabURLString = newTabURLString
        self.commandBarSuggestionProvider = commandBarSuggestionProvider
        self.userPreferencesStore = userPreferencesStore
        self.shortcutStore = shortcutStore
        self.navigationResolver = navigationResolver ?? BrowserNavigationResolver(
            searchEngineProvider: { userPreferencesStore.searchEngine }
        )
        self.extensionManager = extensionManager
        self.temporaryTabLifetime = sessionPreferencesStore.loadTemporaryTabLifetime()
        self.dateProvider = dateProvider
        self.spaceIDProvider = spaceIDProvider
        self.windowTitleHandler = windowTitleHandler
        self.allTabsClosedHandler = allTabsClosedHandler
        self.hostView = tabDriver.hostView

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

    // MARK: Internal

    struct Tab: Identifiable, Equatable {
        let id: String
        var spaceID: String
        var title: String
        var userTitleOverride: String?
        var urlString: String
        var faviconURLString: String?
        var placement = BrowserTabPlacement.temporary
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

    struct Space: Identifiable, Equatable {
        let id: String
        var title: String
        var systemImageName: String
        var isPinnedSectionCollapsed: Bool
        var selectedTabID: String?
    }

    enum BrowserInternalPage: Equatable {
        case settings
        case extensions
        case passwordManager
    }

    nonisolated static let defaultSidebarWidth: CGFloat = 224
    nonisolated static let minSidebarWidth: CGFloat = defaultSidebarWidth
    nonisolated static let maxSidebarWidth: CGFloat = defaultSidebarWidth * 2
    nonisolated static let defaultNewTabURLString = "https://www.google.com"
    nonisolated static let automaticArchivalCheckInterval: TimeInterval = 60 * 60
    nonisolated static let appTabCapacity = 8
    nonisolated static let defaultSpaceID = "default-space"
    nonisolated static let defaultSpaceIconName = "square.grid.2x2"

    @Published private(set) var tabs = [Tab]()
    @Published private(set) var spaces = [Space]()
    @Published private(set) var selectedSpaceID: String?
    @Published private(set) var selectedTabID: String?
    @Published var isSidebarVisible = true
    @Published private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth
    @Published private(set) var temporaryTabLifetime: BrowserTemporaryTabLifetime
    @Published private(set) var isFindBarPresented = false
    @Published private(set) var findBarFocusRequest = 0
    @Published private(set) var findResultMatchCount: Int?
    @Published private(set) var browserExtensions = [BrowserExtension]()
    let hostView: NSView
    let userPreferencesStore: BrowserUserPreferencesStore
    let shortcutStore: BrowserShortcutStore
    lazy var commandBarModel = BrowserCommandBarModel(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        remoteSuggestionsEnabledProvider: { [weak self] in
            self?.canLoadRemoteSearchSuggestions ?? false
        },
        submitHandler: { [weak self] resolvedURLString in
            self?.openResolvedSelectionInNewTab(resolvedURLString)
        }
    )
    lazy var currentPageCommandBarModel = BrowserCommandBarModel(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        remoteSuggestionsEnabledProvider: { [weak self] in
            self?.canLoadRemoteSearchSuggestions ?? false
        },
        submitHandler: { [weak self] resolvedURLString in
            self?.navigateSelectedTab(toURLString: resolvedURLString)
        }
    )

    private(set) var isContextReady = false
    var isShuttingDown = false

    @Published var findQuery = "" {
        didSet {
            guard findQuery != oldValue else {
                return
            }

            handleFindQueryChange()
        }
    }

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

    var canLoadRemoteSearchSuggestions: Bool {
        userPreferencesStore.searchEngineSuggestionsEnabled && userPreferencesStore.searchEngine == .google
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

    var appTabs: [Tab] {
        tabs.filter { $0.placement == .app }
    }

    var activeSpace: Space? {
        guard let selectedSpaceID else {
            return nil
        }

        return spaces.first { $0.id == selectedSpaceID }
    }

    var activeSpaceTabs: [Tab] {
        guard let selectedSpaceID else {
            return []
        }

        return tabs.filter { $0.spaceID == selectedSpaceID }
    }

    var pinnedTabs: [Tab] {
        spacePinnedTabs
    }

    var spacePinnedTabs: [Tab] {
        activeSpaceTabs.filter { $0.placement == .spacePinned }
    }

    var temporaryTabs: [Tab] {
        activeSpaceTabs.filter { $0.placement == .temporary }
    }

    var hasTemporaryTabs: Bool {
        !temporaryTabs.isEmpty
    }

    var isActiveSpacePinnedSectionCollapsed: Bool {
        activeSpace?.isPinnedSectionCollapsed ?? false
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

        ensureDefaultSpace()
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

    func createNewSpace() {
        let space = makeSpace()
        spaces.append(space)
        selectSpace(id: space.id)
        persistCurrentSessionIfAllowed()
    }

    func selectSpace(id spaceID: String) {
        guard
            spaces.contains(where: { $0.id == spaceID }),
            selectedSpaceID != spaceID
        else {
            return
        }

        dismissCommandBar()
        selectedSpaceID = spaceID
        selectActiveTabForSelectedSpace()
        persistCurrentSessionIfAllowed()
    }

    func selectNextSpace() {
        selectAdjacentSpace(offset: 1)
    }

    func selectPreviousSpace() {
        selectAdjacentSpace(offset: -1)
    }

    func toggleActiveSpacePinnedSectionCollapsed() {
        guard let index = selectedSpaceIndex else {
            return
        }

        spaces[index].isPinnedSectionCollapsed.toggle()
        persistCurrentSessionIfAllowed()
    }

    func setTitle(_ title: String?, forSpaceID spaceID: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else {
            return
        }

        let sanitizedTitle = sanitizedSpaceTitle(from: title) ?? defaultSpaceTitle(forDisplayIndex: index + 1)
        guard spaces[index].title != sanitizedTitle else {
            return
        }

        spaces[index].title = sanitizedTitle
        persistCurrentSessionIfAllowed()
    }

    func setIcon(_ systemImageName: String, forSpaceID spaceID: String) {
        guard
            let index = spaces.firstIndex(where: { $0.id == spaceID }),
            spaces[index].systemImageName != systemImageName
        else {
            return
        }

        spaces[index].systemImageName = systemImageName
        persistCurrentSessionIfAllowed()
    }

    func togglePinned(forTabID tabID: String) {
        guard
            let tab = tabs.first(where: { $0.id == tabID }),
            tab.spaceID == selectedSpaceID
        else {
            return
        }

        let targetPlacement: BrowserTabPlacement = tab.placement == .spacePinned ? .temporary : .spacePinned
        let targetSectionIndex = tabCount(for: targetPlacement)
        moveTab(withID: tabID, toPlacement: targetPlacement, atSectionIndex: targetSectionIndex)
    }

    func canMoveTab(
        withID tabID: String,
        toPlacement placement: BrowserTabPlacement,
        atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil
    ) -> Bool {
        guard
            let reorderedTabs = reorderedTabs(
                movingTabID: tabID,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID
            )
        else {
            return false
        }

        return reorderedTabs != tabs
    }

    func moveTab(
        withID tabID: String,
        toPlacement placement: BrowserTabPlacement,
        atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil
    ) {
        guard
            let movingTab = tabs.first(where: { $0.id == tabID }),
            var reorderedTabs = reorderedTabs(
                movingTabID: tabID,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID
            ),
            reorderedTabs != tabs
        else {
            return
        }

        let wasSelectedInSourceSpace = spaces.first { $0.id == movingTab.spaceID }?.selectedTabID == tabID
            || selectedTabID == tabID

        if let movedTabIndex = reorderedTabs.firstIndex(where: { $0.id == tabID }) {
            reorderedTabs[movedTabIndex].lastActivityAt = dateProvider()
        }

        tabs = reorderedTabs
        if
            let movedTab = tabs.first(where: { $0.id == tabID }),
            movedTab.placement != .app
        {
            if wasSelectedInSourceSpace {
                clearSelectedTab(tabID, forSpaceID: movingTab.spaceID)
                setSelectedTabID(tabID, forSpaceID: movedTab.spaceID)
            }
        }
        if selectedTabID == tabID {
            selectActiveTabForSelectedSpace()
        }
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
        let activeSpaceID = selectedSpaceID
        let tabIDsToArchive = tabs.compactMap { tab -> String? in
            guard
                tab.spaceID == activeSpaceID,
                tab.placement == .temporary,
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

    @discardableResult func pasteAndMatchStyleCurrentTab() -> Bool {
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

    @discardableResult func copySelectedTabLink() -> Bool {
        guard let selectedTabID else {
            return false
        }

        return copyTabLink(forTabID: selectedTabID)
    }

    @discardableResult func copyTabLink(forTabID tabID: String) -> Bool {
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

    @discardableResult func setExtension(id: String, isEnabled: Bool) -> Bool {
        guard extensionManager.setExtension(id: id, isEnabled: isEnabled) else {
            return false
        }

        refreshBrowserExtensions()
        return true
    }

    @discardableResult func removeExtension(id: String) -> Bool {
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

    @discardableResult func archiveSelectedTab() -> Bool {
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
            let tab = tabs.first(where: { $0.id == id }),
            tab.spaceID == selectedSpaceID,
            selectedTabID != id,
            !closingTabIDs.contains(id)
        else {
            return
        }

        dismissCommandBar()

        selectedTabID = id
        setSelectedTabID(id, forSpaceID: tab.spaceID)
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

        let closingTab = tabs[closingIndex]
        let closingTabWasSelected = selectedTabID == id
        closingTabIDs.insert(id)

        tabs.removeAll { $0.id == id }
        clearSelectedTab(id, forSpaceID: closingTab.spaceID)

        if closingTabWasSelected {
            let fallbackTabID = fallbackTabID(afterClosingTab: closingTab)
            let fallbackUsesWindowedBrowser = fallbackTabID.map { tabUsesWindowedBrowser(id: $0) } ?? false
            if fallbackUsesWindowedBrowser {
                dismissFindBar()
            }
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                setSelectedTabID(fallbackTabID, forSpaceID: closingTab.spaceID)
                if !fallbackUsesWindowedBrowser {
                    runFind(forward: true, findNext: false)
                }
            } else {
                tabDriver.deselectActiveTab()
            }
        } else if selectedTabID == id {
            selectedTabID = nil
        }

        tabDriver.closeTab(withID: id, forceClose: forceClose)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
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

    // MARK: Private

    private struct PendingCreatedTabContext {
        let spaceID: String
        let placement: BrowserTabPlacement
    }

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
    private let spaceIDProvider: () -> String

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private var isPersistenceEnabled = true
    private var isRestoringSession = false
    private var pendingRestoredSelectedTabIndex: Int?
    private var pendingRestoredTabs = [BrowserTabSessionSnapshotTab]()
    private var pendingRestoredSpaces = [BrowserSpaceSessionSnapshot]()
    private var pendingCreatedTabContexts = [String: PendingCreatedTabContext]()
    private var remainingRestoredTabCreations = 0
    private var automaticArchivalTimer: Timer?

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

    private var selectedSpaceIndex: Int? {
        guard let selectedSpaceID else {
            return nil
        }

        return spaces.firstIndex(where: { $0.id == selectedSpaceID })
    }

    private func ensureInitialTab() {
        guard canCreateTab, !hasCreatedInitialTab else {
            return
        }

        ensureDefaultSpace()
        hasCreatedInitialTab = true
        createTab(withURLString: newTabURLString)
    }

    private func restoreSessionIfAvailable() -> Bool {
        guard userPreferencesStore.restoreWindowsOnLaunch else {
            return false
        }

        guard let snapshot = sessionSnapshotStore.loadSnapshot() else {
            return false
        }

        let restoredSpaces = restoredSpaces(from: snapshot)
        guard !restoredSpaces.isEmpty || !snapshot.tabs.isEmpty else {
            return false
        }

        isRestoringSession = true
        hasCreatedInitialTab = true
        spaces = restoredSpaces.isEmpty ? [makeDefaultSpace()] : restoredSpaces
        let selectedSpaceIndex = sessionPreferencesStore.loadSelectedSpaceIndex(
            spaceCount: spaces.count
        ) ?? 0
        selectedSpaceID = spaces.indices.contains(selectedSpaceIndex) ? spaces[selectedSpaceIndex].id : spaces.first?.id
        pendingRestoredSelectedTabIndex = sessionPreferencesStore.loadSelectedTabIndex(
            tabCount: snapshot.tabs.count
        )
        pendingRestoredSpaces = snapshot.spaces ?? []
        pendingRestoredTabs = snapshot.tabs
        remainingRestoredTabCreations = snapshot.tabs.count

        guard !snapshot.tabs.isEmpty else {
            finishSessionRestoreIfNeeded()
            return true
        }

        for (index, tabSnapshot) in snapshot.tabs.enumerated() {
            _ = tabDriver.createTab(
                withURLString: tabSnapshot.urlString,
                makeActive: index == pendingRestoredSelectedTabIndex
            )
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

        restoreSelectedTabsForSpaces()
        selectActiveTabForSelectedSpace()

        pendingRestoredSelectedTabIndex = nil
        pendingRestoredTabs.removeAll()
        pendingRestoredSpaces.removeAll()
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
                spaces: spaces.map { space in
                    BrowserSpaceSessionSnapshot(
                        id: space.id,
                        title: space.title,
                        systemImageName: space.systemImageName,
                        isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                        selectedTabIndex: selectedTabIndex(inSpace: space.id)
                    )
                },
                tabs: tabs.map { tab in
                    BrowserTabSessionSnapshotTab(
                        urlString: tab.urlString,
                        userTitleOverride: tab.userTitleOverride,
                        placement: tab.placement,
                        spaceID: tab.spaceID,
                        lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970
                    )
                }
            )
        )
        sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
        sessionPreferencesStore.saveSelectedTabIndex(selectedTabIndex)
    }

    private func updateWindowTitle() {
        let title = tabs.first(where: { $0.id == selectedTabID })?.displayTitle ?? BrowserStrings.applicationName
        windowTitleHandler(title)
    }

    private func createTab(withURLString urlString: String) {
        guard canCreateTab else {
            return
        }

        ensureDefaultSpace()
        guard let selectedSpaceID else {
            return
        }

        let tabID = tabDriver.createTab(withURLString: urlString, makeActive: true)
        let context = PendingCreatedTabContext(spaceID: selectedSpaceID, placement: .temporary)
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].spaceID = selectedSpaceID
            tabs[index].placement = context.placement
        } else {
            pendingCreatedTabContexts[tabID] = context
        }
        selectedTabID = tabID
        setSelectedTabID(tabID, forSpaceID: selectedSpaceID)
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
        let sidebarTabIDs = (appTabs + spacePinnedTabs + temporaryTabs).map(\.id)
        guard let tabIndex = sidebarTabIDs.firstIndex(of: tabID) else {
            return []
        }

        return Array(sidebarTabIDs.dropFirst(tabIndex + 1))
    }
}

@MainActor private extension BrowserChromeModel {
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

    func fallbackTabID(afterClosingTab closingTab: Tab?) -> String? {
        guard let closingTab else {
            return sidebarTabsForSelectedSpace().first?.id
        }

        let visibleTabs = sidebarTabs(forSpaceID: closingTab.spaceID)
        let previousSidebarOrder = sidebarTabs(
            forSpaceID: closingTab.spaceID,
            including: closingTab
        )
        guard let closingIndex = previousSidebarOrder.firstIndex(where: { $0.id == closingTab.id }) else {
            return visibleTabs.first?.id
        }

        if visibleTabs.indices.contains(closingIndex) {
            return visibleTabs[closingIndex].id
        }

        let previousIndex = closingIndex - 1
        if visibleTabs.indices.contains(previousIndex) {
            return visibleTabs[previousIndex].id
        }

        return visibleTabs.first?.id
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
        case "password-manager":
            return .passwordManager
        default:
            return nil
        }
    }

    func handleCreatedTab(id: String, title: String, urlString: String) {
        let restoredTab = isRestoringSession && !pendingRestoredTabs.isEmpty ? pendingRestoredTabs.removeFirst() : nil
        let pendingContext = pendingCreatedTabContexts.removeValue(forKey: id)
        let fallbackSpaceID = selectedSpaceID ?? spaces.first?.id ?? Self.defaultSpaceID
        let tabSpaceID = restoredTab?.spaceID ?? pendingContext?.spaceID ?? fallbackSpaceID
        if spaces.isEmpty {
            spaces = [makeDefaultSpace()]
            selectedSpaceID = tabSpaceID
        }
        tabs.append(
            Tab(
                id: id,
                spaceID: tabSpaceID,
                title: title,
                userTitleOverride: restoredTab?.userTitleOverride,
                urlString: urlString,
                faviconURLString: nil,
                placement: restoredTab?.placement ?? pendingContext?.placement ?? .temporary,
                lastActivityAt: restoredTab.flatMap(lastActivityDate(from:)) ?? dateProvider()
            )
        )

        if selectedTabID == nil {
            selectedTabID = id
        }
        if selectedTabID == id {
            setSelectedTabID(id, forSpaceID: tabSpaceID)
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
        let closedTab = tabs.first { $0.id == id }
        if closedTab != nil {
            tabs.removeAll { $0.id == id }
        }
        if let closedTab {
            clearSelectedTab(id, forSpaceID: closedTab.spaceID)
        }

        if selectedTabID == id {
            selectedTabID = fallbackTabID(afterClosingTab: closedTab) ?? sidebarTabsForSelectedSpace().first?.id
            if let selectedTabID {
                tabDriver.selectTab(withID: selectedTabID)
                setSelectedTabID(selectedTabID, forSpaceID: selectedSpaceID)
            } else {
                tabDriver.deselectActiveTab()
            }
        }

        if tabs.isEmpty, selectedTabID == nil {
            selectedTabID = nil

            if isShuttingDown {
                allTabsClosedHandler()
            }
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed()
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

    func ensureDefaultSpace() {
        guard spaces.isEmpty else {
            if selectedSpaceID == nil {
                selectedSpaceID = spaces.first?.id
            }
            return
        }

        let defaultSpace = makeDefaultSpace()
        spaces = [defaultSpace]
        selectedSpaceID = defaultSpace.id
    }

    func makeDefaultSpace() -> Space {
        Space(
            id: Self.defaultSpaceID,
            title: defaultSpaceTitle(forDisplayIndex: 1),
            systemImageName: Self.defaultSpaceIconName,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil
        )
    }

    func makeSpace() -> Space {
        Space(
            id: uniqueSpaceID(),
            title: defaultSpaceTitle(forDisplayIndex: spaces.count + 1),
            systemImageName: Self.defaultSpaceIconName,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil
        )
    }

    func uniqueSpaceID() -> String {
        var id = spaceIDProvider()
        while spaces.contains(where: { $0.id == id }) {
            id = spaceIDProvider()
        }
        return id
    }

    func restoredSpaces(from snapshot: BrowserTabSessionSnapshot) -> [Space] {
        guard let spaceSnapshots = snapshot.spaces, !spaceSnapshots.isEmpty else {
            return [makeDefaultSpace()]
        }

        var seenIDs = Set<String>()
        return spaceSnapshots.enumerated().compactMap { index, snapshot -> Space? in
            let id = snapshot.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenIDs.contains(id) else {
                return nil
            }

            seenIDs.insert(id)
            return Space(
                id: id,
                title: sanitizedSpaceTitle(from: snapshot.title) ?? defaultSpaceTitle(forDisplayIndex: index + 1),
                systemImageName: snapshot.systemImageName.isEmpty
                    ? Self.defaultSpaceIconName
                    : snapshot
                        .systemImageName,
                isPinnedSectionCollapsed: snapshot.isPinnedSectionCollapsed,
                selectedTabID: nil
            )
        }
    }

    func restoreSelectedTabsForSpaces() {
        for index in spaces.indices {
            let spaceID = spaces[index].id
            let visibleTabs = sidebarTabs(forSpaceID: spaceID)
            let selectedIndex = pendingRestoredSpaces.first { $0.id == spaceID }?.selectedTabIndex

            spaces[index].selectedTabID =
                if
                    let selectedIndex,
                    visibleTabs.indices.contains(selectedIndex)
                {
                    visibleTabs[selectedIndex].id
                } else if
                    spaceID == selectedSpaceID,
                    let legacySelectedTabIndex = pendingRestoredSelectedTabIndex,
                    tabs.indices.contains(legacySelectedTabIndex),
                    tabs[legacySelectedTabIndex].spaceID == spaceID
                {
                    tabs[legacySelectedTabIndex].id
                } else {
                    visibleTabs.first?.id
                }
        }
    }

    func selectActiveTabForSelectedSpace() {
        guard let selectedSpaceID else {
            selectedTabID = nil
            tabDriver.deselectActiveTab()
            updateWindowTitle()
            return
        }

        let selectedTabIDForSpace = spaces.first { $0.id == selectedSpaceID }?.selectedTabID
        let fallbackTabID = selectedTabIDForSpace.flatMap { tabID -> String? in
            guard tabs.contains(where: { $0.id == tabID && $0.spaceID == selectedSpaceID }) else {
                return nil
            }
            return tabID
        } ?? sidebarTabs(forSpaceID: selectedSpaceID).first?.id

        selectedTabID = fallbackTabID
        findResultMatchCount = nil

        if let fallbackTabID {
            setSelectedTabID(fallbackTabID, forSpaceID: selectedSpaceID)
            tabDriver.selectTab(withID: fallbackTabID)
            runFind(forward: true, findNext: false)
        } else {
            tabDriver.deselectActiveTab()
        }

        updateWindowTitle()
    }

    func selectAdjacentSpace(offset: Int) {
        guard
            spaces.count > 1,
            let selectedSpaceIndex
        else {
            return
        }

        let nextIndex = (selectedSpaceIndex + offset + spaces.count) % spaces.count
        selectSpace(id: spaces[nextIndex].id)
    }

    func setSelectedTabID(_ tabID: String?, forSpaceID spaceID: String?) {
        guard
            let spaceID,
            let index = spaces.firstIndex(where: { $0.id == spaceID })
        else {
            return
        }

        spaces[index].selectedTabID = tabID
    }

    func clearSelectedTab(_ tabID: String, forSpaceID spaceID: String) {
        guard
            let index = spaces.firstIndex(where: { $0.id == spaceID }),
            spaces[index].selectedTabID == tabID
        else {
            return
        }

        spaces[index].selectedTabID = nil
    }

    func sidebarTabsForSelectedSpace() -> [Tab] {
        guard let selectedSpaceID else {
            return []
        }

        return sidebarTabs(forSpaceID: selectedSpaceID)
    }

    func sidebarTabs(forSpaceID spaceID: String, including extraTab: Tab? = nil) -> [Tab] {
        var spaceTabs = tabs.filter { $0.spaceID == spaceID && $0.placement != .app }
        if let extraTab, !spaceTabs.contains(where: { $0.id == extraTab.id }) {
            spaceTabs.append(extraTab)
        }

        return spaceTabs
            .filter { $0.placement == .spacePinned }
            + spaceTabs.filter { $0.placement == .temporary }
    }

    func selectedTabIndex(inSpace spaceID: String) -> Int? {
        guard
            let selectedTabID = spaces.first(where: { $0.id == spaceID })?.selectedTabID,
            let index = sidebarTabs(forSpaceID: spaceID).firstIndex(where: { $0.id == selectedTabID })
        else {
            return nil
        }

        return index
    }

    func defaultSpaceTitle(forDisplayIndex displayIndex: Int) -> String {
        BrowserStrings.defaultSpaceTitle(index: displayIndex)
    }

    func sanitizedSpaceTitle(from title: String?) -> String? {
        guard let title else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }
}

@MainActor extension BrowserChromeModel {
    func reorderedTabs(
        movingTabID: String,
        toPlacement placement: BrowserTabPlacement,
        requestedSectionIndex: Int,
        targetSpaceID: String? = nil
    ) -> [Tab]? {
        guard
            let movingTab = tabs.first(where: { $0.id == movingTabID })
        else {
            return nil
        }

        if targetSpaceID == nil, movingTab.placement != .app, movingTab.spaceID != selectedSpaceID {
            return nil
        }

        let resolvedTargetSpaceID = targetSpaceID ?? selectedSpaceID ?? movingTab.spaceID
        guard placement == .app || spaces.contains(where: { $0.id == resolvedTargetSpaceID }) else {
            return nil
        }

        guard canMoveTab(movingTab, to: placement) else {
            return nil
        }

        let movingWithinTargetSection = movingTab.placement == placement
            && (placement == .app || movingTab.spaceID == resolvedTargetSpaceID)
        let sourceSectionTabs = tabs(
            for: movingTab.placement,
            inSpaceID: movingTab.placement == .app ? nil : movingTab.spaceID
        )
        let sourceSectionIndex = sourceSectionTabs.firstIndex(where: { $0.id == movingTabID })

        var updatedAppTabs = appTabs.filter { $0.id != movingTabID }
        var updatedSpacePinnedTabsBySpaceID = tabsBySpaceID(for: .spacePinned, removingTabID: movingTabID)
        var updatedTemporaryTabsBySpaceID = tabsBySpaceID(for: .temporary, removingTabID: movingTabID)
        var updatedTab = movingTab
        updatedTab.placement = placement
        if placement != .app {
            updatedTab.spaceID = resolvedTargetSpaceID
        }

        switch placement {
        case .app:
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedAppTabs.count
            )
            updatedAppTabs.insert(updatedTab, at: destinationIndex)
        case .spacePinned:
            var updatedSpacePinnedTabs = updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] ?? []
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedSpacePinnedTabs.count
            )
            updatedSpacePinnedTabs.insert(updatedTab, at: destinationIndex)
            updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] = updatedSpacePinnedTabs
        case .temporary:
            var updatedTemporaryTabs = updatedTemporaryTabsBySpaceID[resolvedTargetSpaceID] ?? []
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedTemporaryTabs.count
            )
            updatedTemporaryTabs.insert(updatedTab, at: destinationIndex)
            updatedTemporaryTabsBySpaceID[resolvedTargetSpaceID] = updatedTemporaryTabs
        }

        return tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: updatedSpacePinnedTabsBySpaceID,
            temporaryTabsBySpaceID: updatedTemporaryTabsBySpaceID,
            appTabs: updatedAppTabs
        )
    }
}

@MainActor private extension BrowserChromeModel {
    func tabCount(for placement: BrowserTabPlacement) -> Int {
        tabs(for: placement).count
    }

    func tabs(for placement: BrowserTabPlacement) -> [Tab] {
        tabs(for: placement, inSpaceID: selectedSpaceID)
    }

    func tabs(for placement: BrowserTabPlacement, inSpaceID spaceID: String?) -> [Tab] {
        switch placement {
        case .app:
            appTabs
        case .spacePinned:
            tabs.filter { $0.spaceID == spaceID && $0.placement == .spacePinned }
        case .temporary:
            tabs.filter { $0.spaceID == spaceID && $0.placement == .temporary }
        }
    }

    func canMoveTab(_ tab: Tab, to placement: BrowserTabPlacement) -> Bool {
        guard placement == .app, tab.placement != .app else {
            return true
        }

        return appTabs.count < Self.appTabCapacity
    }

    func tabsBySpaceID(
        for placement: BrowserTabPlacement,
        removingTabID tabID: String
    ) -> [String: [Tab]] {
        spaces.reduce(into: [:]) { result, space in
            result[space.id] = tabs(for: placement, inSpaceID: space.id)
                .filter { $0.id != tabID }
        }
    }

    func tabsByReplacingTabs(
        spacePinnedTabsBySpaceID: [String: [Tab]],
        temporaryTabsBySpaceID: [String: [Tab]],
        appTabs: [Tab]
    ) -> [Tab] {
        var result = appTabs
        for space in spaces {
            result.append(contentsOf: spacePinnedTabsBySpaceID[space.id] ?? [])
            result.append(contentsOf: temporaryTabsBySpaceID[space.id] ?? [])
        }

        let knownSpaceIDs = Set(spaces.map(\.id))
        result.append(contentsOf: tabs.filter { !knownSpaceIDs.contains($0.spaceID) && $0.placement != .app })
        return result
    }

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
