import AppKit
import Combine
import Foundation

// MARK: - BrowserInternalPageRouting

enum BrowserInternalPageRouting {
    static let settingsURL = URL(string: "tb://settings/")!
    static let historyURL = URL(string: "tb://history")!
    static let bookmarksURL = URL(string: "tb://bookmarks/")!
}

// MARK: - BrowserWindowMode

enum BrowserWindowMode: Equatable {
    case normal
    case incognito
    case webApp(BrowserWebAppConfiguration)

    // MARK: Internal

    var isIncognito: Bool {
        self == .incognito
    }

    var isWebApp: Bool {
        guard case .webApp = self else {
            return false
        }

        return true
    }

    var persistsSession: Bool {
        !isIncognito && !isWebApp
    }

    var telemetryValue: String {
        switch self {
        case .normal:
            "normal"
        case .incognito:
            "incognito"
        case .webApp:
            "web_app"
        }
    }
}

// MARK: - BrowserChromeModel

@MainActor final class BrowserChromeModel: NSObject, ObservableObject, BrowserSyncSnapshotApplying {
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
        bookmarksModel: BrowserBookmarksModel? = nil,
        historyStore: BrowserHistorySearching = BrowserEmptyHistoryStore(),
        downloadsModel: BrowserDownloadsModel? = nil,
        extensionManager: any BrowserExtensionManaging,
        extensionSidePanelDriver: (any BrowserExtensionSidePanelDriving)? = nil,
        extensionActionPopupDriver: (any BrowserExtensionActionPopupDriving)? = nil,
        syncCoordinator: BrowserSyncCoordinating? = nil,
        windowMode: BrowserWindowMode = .normal,
        profile: BrowserProfile = .defaultProfile,
        availableProfileCount: Int = 1,
        dateProvider: @escaping () -> Date = Date.init,
        spaceIDProvider: @escaping () -> String = { UUID().uuidString },
        tabSyncIDProvider: @escaping () -> String = { UUID().uuidString },
        commandHandler: @escaping (BrowserCommandID) -> Void = { _ in },
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
        self.bookmarksModel = bookmarksModel ?? BrowserBookmarksModel()
        self.historyStore = historyStore
        self.downloadsModel = downloadsModel ?? BrowserDownloadsModel()
        self.navigationResolver = navigationResolver ?? BrowserNavigationResolver(
            searchEngineProvider: { userPreferencesStore.searchEngine }
        )
        self.extensionManager = extensionManager
        self.extensionSidePanelDriver = extensionSidePanelDriver
        self.extensionActionPopupDriver = extensionActionPopupDriver
        self.syncCoordinator = syncCoordinator
        self.windowMode = windowMode
        self.profile = profile
        self.profileDisplayName = profile.displayName
        self.availableProfileCount = availableProfileCount
        self.isPersistenceEnabled = windowMode.persistsSession
        self.temporaryTabLifetime = sessionPreferencesStore.loadTemporaryTabLifetime()
        self.pinnedExtensionIDs = userPreferencesStore.pinnedExtensionIDs
        self.dateProvider = dateProvider
        self.spaceIDProvider = spaceIDProvider
        self.tabSyncIDProvider = tabSyncIDProvider
        self.commandHandler = commandHandler
        self.windowTitleHandler = windowTitleHandler
        self.allTabsClosedHandler = allTabsClosedHandler
        self.hostView = tabDriver.hostView

        super.init()
        undoManager.groupsByEvent = false
        tabDriver.onTabCreated = { [weak self] tabID, title, urlString, isActive in
            self?.handleCreatedTab(id: tabID, title: title, urlString: urlString, isActive: isActive)
        }
        tabDriver.onTabCreationStateChanged = { [weak self] tabID, state in
            self?.handleTabCreationStateChange(id: tabID, state: state)
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
        tabDriver.onDownloadUpdated = { [weak self] update in
            self?.handleDownloadUpdate(update)
        }
        extensionSidePanelDriver?.onPanelClosed = { [weak self] panelID in
            self?.handleExtensionSidePanelClosed(panelID: panelID)
        }
        updateWindowTitle()
    }

    // MARK: Internal

    nonisolated static let defaultSidebarWidth: CGFloat = 224
    nonisolated static let minSidebarWidth: CGFloat = defaultSidebarWidth
    nonisolated static let maxSidebarWidth: CGFloat = defaultSidebarWidth * 2
    nonisolated static let defaultExtensionSidePanelWidth: CGFloat = 360
    nonisolated static let minExtensionSidePanelWidth: CGFloat = 280
    nonisolated static let maxExtensionSidePanelWidth: CGFloat = 560
    nonisolated static let defaultNewTabURLString = "https://www.google.com"
    nonisolated static let automaticArchivalCheckInterval: TimeInterval = 60 * 60
    nonisolated static let appTabCapacity = 8
    nonisolated static let defaultSpaceID = "default-space"
    nonisolated static let defaultSpaceIconName = "square.grid.2x2"
    nonisolated static let tabSwitcherMaximumEntries = 5
    nonisolated static let tabSwitcherPresentationDelayNanoseconds: UInt64 = 180_000_000
    nonisolated static let zoomPercentages = [
        25,
        33,
        50,
        67,
        75,
        80,
        90,
        100,
        110,
        125,
        150,
        175,
        200,
        250,
        300,
        400,
        500,
    ]

    @Published private(set) var tabs = [Tab]()
    @Published private(set) var spaces = [Space]()
    @Published private(set) var pinnedTabFolders = [PinnedTabFolder]()
    @Published private(set) var selectedSpaceID: String?
    @Published private(set) var selectedTabID: String?
    @Published private(set) var tabSwitcherState: TabSwitcherState?
    @Published var isSidebarVisible = true
    @Published private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth
    @Published private(set) var temporaryTabLifetime: BrowserTemporaryTabLifetime
    @Published private(set) var isFindBarPresented = false
    @Published private(set) var findBarFocusRequest = 0
    @Published private(set) var findResultMatchCount: Int?
    @Published private(set) var browserExtensions = [BrowserExtension]()
    @Published private(set) var extensionSidePanel: BrowserExtensionSidePanel?
    @Published private(set) var extensionSidePanelWidth = BrowserChromeModel.defaultExtensionSidePanelWidth
    @Published private(set) var pinnedExtensionIDs = [String]()
    @Published private(set) var selectedTabWebAppInstallMetadata: BrowserWebAppInstallMetadata?
    @Published private(set) var profileDisplayName: String
    @Published private(set) var availableProfileCount: Int
    @Published private(set) var zoomPercent = 100
    @Published private(set) var sessionPersistenceFailure: BrowserSessionPersistenceFailure?
    let hostView: NSView
    let userPreferencesStore: BrowserUserPreferencesStore
    let shortcutStore: BrowserShortcutStore
    let bookmarksModel: BrowserBookmarksModel
    let downloadsModel: BrowserDownloadsModel
    let windowMode: BrowserWindowMode
    let profile: BrowserProfile
    let undoManager = UndoManager()
    lazy var commandBarModel = BrowserCommandBarModel(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        localSuggestionProvider: { [weak self] query, maximumCount in
            self?.localCommandSuggestions(for: query, maximumCount: maximumCount) ?? []
        },
        remoteSuggestionsEnabledProvider: { [weak self] in
            self?.canLoadRemoteSearchSuggestions ?? false
        },
        aiSearchProviderProvider: { [weak self] in
            self?.userPreferencesStore.aiSearchProvider ?? .chatGPT
        },
        submitHandler: { [weak self] resolvedURLString in
            self?.openResolvedSelectionInNewTab(resolvedURLString)
        },
        openTabHandler: { [weak self] tabIDs in
            self?.openCommandBarTabSelection(tabIDs: tabIDs)
        },
        commandHandler: { [weak self] commandID in
            self?.commandHandler(commandID)
        }
    )
    lazy var currentPageCommandBarModel = BrowserCommandBarModel(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        localSuggestionProvider: { [weak self] query, maximumCount in
            self?.localCommandSuggestions(for: query, maximumCount: maximumCount) ?? []
        },
        remoteSuggestionsEnabledProvider: { [weak self] in
            self?.canLoadRemoteSearchSuggestions ?? false
        },
        aiSearchProviderProvider: { [weak self] in
            self?.userPreferencesStore.aiSearchProvider ?? .chatGPT
        },
        submitHandler: { [weak self] resolvedURLString in
            self?.navigateSelectedTab(toURLString: resolvedURLString)
        },
        openTabHandler: { [weak self] tabIDs in
            self?.openCommandBarTabSelection(tabIDs: tabIDs)
        },
        commandHandler: { [weak self] commandID in
            self?.commandHandler(commandID)
        }
    )

    private(set) var isContextReady = false
    var isShuttingDown = false

    var hasUncommittedSessionWrites: Bool {
        !hasDiscardedSessionForClosure && (!sessionWriteBuffer.writes.isEmpty || sessionPersistenceFailure != nil)
    }

    var extensionSidePanelHostView: NSView? {
        extensionSidePanelDriver?.hostView
    }

    var extensionActionPopupHostView: NSView? {
        extensionActionPopupDriver?.hostView
    }

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

    var selectedTabCreationState: BrowserTabCreationState? {
        selectedTab?.creationState
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

    var canCastPage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canCopySelectedTabLink: Bool {
        selectedTab != nil
    }

    var canInstallSelectedSiteAsApp: Bool {
        guard
            !windowMode.isIncognito,
            !windowMode.isWebApp,
            let pageURL = selectedTab?.pageURL,
            let selectedTabWebAppInstallMetadata,
            selectedTabWebAppInstallMetadata.manifestURL != nil
        else {
            return false
        }

        return selectedTabWebAppInstallMetadata.sourcePageURL == pageURL
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

    var isIncognito: Bool {
        windowMode.isIncognito
    }

    var isWebApp: Bool {
        windowMode.isWebApp
    }

    var currentTab: Tab? {
        selectedTab
    }

    var showsProfileIndicator: Bool {
        !windowMode.isIncognito && !windowMode.isWebApp && availableProfileCount > 1
    }

    var supportsSpaces: Bool {
        !windowMode.isIncognito && !windowMode.isWebApp
    }

    var supportsAppTabs: Bool {
        !windowMode.isIncognito && !windowMode.isWebApp
    }

    var appTabs: [Tab] {
        guard supportsAppTabs else {
            return []
        }

        return tabs.filter { $0.placement == .app }
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

    @discardableResult func retrySessionPersistence() -> Bool {
        guard !hasDiscardedSessionForClosure, !sessionWriteBuffer.isTerminal else { return false }
        guard !sessionWriteBuffer.writes.isEmpty else { return sessionPersistenceFailure == nil }
        let hasLocalWrite = sessionWriteBuffer.writes.contains {
            if case .local = $0.origin {
                return true
            }
            return false
        }
        return commitSessionWrites(sessionWriteBuffer.writes, schedulesPush: hasLocalWrite)
    }

    /// Closure preflight is reversible. Teardown must only run after it succeeds
    /// or the user explicitly chooses to discard the volatile session changes.
    @discardableResult func prepareSessionForClosure() -> Bool {
        guard !hasDiscardedSessionForClosure, isPersistenceEnabled else { return true }
        guard !sessionWriteBuffer.isTerminal else { return false }
        persistCurrentSessionIfAllowed()
        isSessionClosurePrepared = !hasUncommittedSessionWrites
        return isSessionClosurePrepared
    }

    func discardUnsavedSessionForClosure() {
        hasDiscardedSessionForClosure = true
        isPersistenceEnabled = false
        deferredRemoteSyncSnapshot = nil
        syncCoordinator?.setLocalPersistenceBlocked(true)
    }

    func sessionRecoverySnapshot() -> BrowserTabSessionSnapshot {
        isApplyingRemoteSync ? snapshotPreservingPendingRemoteCreations() : currentSessionSnapshot()
    }

    func webAppInstallMetadata(for tab: Tab) -> BrowserWebAppInstallMetadata? {
        guard
            tab.id == selectedTabID,
            let pageURL = tab.pageURL,
            let selectedTabWebAppInstallMetadata,
            selectedTabWebAppInstallMetadata.sourcePageURL == pageURL,
            selectedTabWebAppInstallMetadata.manifestURL != nil
        else {
            return nil
        }

        return selectedTabWebAppInstallMetadata
    }

    func waitForPendingWebAppManifestLoad() async {
        await webAppManifestLoadTask?.value
    }

    func handleContextReady() {
        guard !isContextReady else {
            return
        }

        isContextReady = true
        restoreSidebarWidthIfNeeded()
        bookmarksModel.reload()
        refreshBrowserExtensions()
        startAutomaticArchivalTimerIfNeeded()

        if drainDeferredRemoteSyncSnapshot() {
            syncCoordinator?.schedulePull()
            return
        }

        if restoreSessionIfAvailable() {
            syncCoordinator?.schedulePull()
            return
        }

        ensureDefaultSpace()
        ensureInitialTab()
        archiveExpiredTemporaryTabs()
        syncCoordinator?.schedulePull()
    }

    func prepareForTermination() {
        guard !isShuttingDown else {
            return
        }

        // Close/quit already performed a reversible preflight. Do not introduce
        // an unguarded second write after the controller approved destruction.
        if !isSessionClosurePrepared, !hasDiscardedSessionForClosure {
            persistCurrentSessionIfAllowed()
        }
        guard !hasUncommittedSessionWrites else { return }
        automaticArchivalTimer?.invalidate()
        automaticArchivalTimer = nil
        webAppManifestLoadTask?.cancel()
        webAppManifestLoadTask = nil
        undoManager.removeAllActions()
        extensionSidePanelDriver?.closeAllPanels()
        extensionActionPopupDriver?.closeAllPopups()
        extensionSidePanel = nil
        persistSidebarWidthPreferenceIfAllowed()
        isShuttingDown = true
        isPersistenceEnabled = false
    }

    func prepareForCefShutdown() {
        prepareForTermination()
        tabDriver.prepareForCefShutdown()
    }

    func createNewTab() {
        createTab(withURLString: newTabURLString)
    }

    func openURLInNewTab(_ url: URL) {
        createTab(withURLString: url.absoluteString)
    }

    func openBookmark(urlString: String) {
        BrowserTelemetry.captureUsage(.bookmarkOpened, properties: telemetryProperties)
        navigateSelectedTabOrOpenNewTab(toURLString: urlString)
    }

    @discardableResult func addSelectedTabBookmark() -> Bool {
        guard let selectedTab, !selectedTab.urlString.isEmpty else {
            return false
        }

        return bookmarksModel.addBookmark(
            title: selectedTab.displayTitle,
            urlString: selectedTab.urlString
        )
    }

    @discardableResult func toggleSelectedTabBookmark() -> Bool {
        guard let selectedTab, !selectedTab.urlString.isEmpty else {
            return false
        }

        return bookmarksModel.toggleBookmark(
            title: selectedTab.displayTitle,
            urlString: selectedTab.urlString
        )
    }

    @discardableResult func renameBookmark(id: String, title: String) -> Bool {
        bookmarksModel.renameBookmark(id: id, title: title)
    }

    @discardableResult func updateBookmarkAddress(id: String, urlString: String) -> Bool {
        bookmarksModel.updateBookmarkAddress(id: id, urlString: urlString)
    }

    @discardableResult func moveBookmark(id: String, toFolderID: String?) -> Bool {
        bookmarksModel.moveBookmark(id: id, toFolderID: toFolderID)
    }

    @discardableResult func createBookmarkFolder(title: String) -> String? {
        bookmarksModel.createFolder(title: title)
    }

    @discardableResult func createBookmarkFolderAndMoveBookmark(title: String, bookmarkID: String) -> Bool {
        bookmarksModel.createFolderAndMoveBookmark(title: title, bookmarkID: bookmarkID)
    }

    @discardableResult func deleteBookmark(id: String) -> Bool {
        bookmarksModel.deleteBookmark(id: id)
    }

    func openBookmarks(_ urlStrings: [String]) {
        for urlString in urlStrings where !urlString.isEmpty {
            createTab(withURLString: urlString)
        }
    }

    func openBookmarksManager() {
        openURLInNewTab(BrowserInternalPageRouting.bookmarksURL)
    }

    @discardableResult func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult {
        bookmarksModel.importBookmarks(from: source)
    }

    func isBookmarked(urlString: String) -> Bool {
        bookmarksModel.containsBookmark(urlString: urlString)
    }

    func createNewSpace() {
        guard supportsSpaces else {
            return
        }

        let space = makeSpace()
        spaces.append(space)
        selectSpace(id: space.id)
        BrowserTelemetry.captureUsage(.spaceCreated, properties: telemetryProperties)
        persistCurrentSessionIfAllowed()
    }

    func canDeleteSpace(id spaceID: String) -> Bool {
        supportsSpaces && spaces.count > 1 && spaces.contains { $0.id == spaceID }
    }

    @discardableResult func deleteSpace(id spaceID: String) -> Bool {
        guard
            canDeleteSpace(id: spaceID),
            let spaceIndex = spaces.firstIndex(where: { $0.id == spaceID })
        else {
            return false
        }

        let fallbackSpaceID = fallbackSpaceID(afterDeletingSpaceAt: spaceIndex)
        if selectedSpaceID == spaceID {
            selectedSpaceID = fallbackSpaceID
            if selectedTab?.placement != .app {
                selectActiveTabForSelectedSpace()
            }
        }

        let wasPersistenceEnabled = isPersistenceEnabled
        isPersistenceEnabled = false
        for tabID in tabs.filter({ $0.spaceID == spaceID && $0.placement != .app }).map(\.id) {
            closeTab(id: tabID, registersUndo: false)
        }
        for (engineID, binding) in pendingRemoteTabCreations
            where binding.snapshot.spaceID == spaceID && binding.snapshot.placement != .app
        {
            pendingRemoteTabCreations.removeValue(forKey: engineID)
            discardedRemoteTabCreationIDs.insert(engineID)
            tabDriver.closeTab(withID: engineID, forceClose: true)
        }
        isPersistenceEnabled = wasPersistenceEnabled

        if let fallbackSpaceID {
            for index in tabs.indices where tabs[index].placement == .app && tabs[index].spaceID == spaceID {
                // Favorites are global. Their remembered Space only provides a
                // valid selection/restore context; it does not own their lifetime.
                tabs[index].spaceID = fallbackSpaceID
            }
        }
        spaces.removeAll { $0.id == spaceID }
        pinnedTabFolders.removeAll { $0.spaceID == spaceID }
        if selectedSpaceID == spaceID || selectedSpaceID == nil {
            selectedSpaceID = spaces.first?.id
            selectActiveTabForSelectedSpace()
        }
        if let selectedTab, selectedTab.placement == .app {
            setSelectedTabID(selectedTab.id, forSpaceID: selectedSpaceID)
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        finishRemoteSyncProjectionIfReady()
        return true
    }

    func selectSpace(id spaceID: String) {
        guard supportsSpaces else {
            return
        }

        guard
            spaces.contains(where: { $0.id == spaceID }),
            selectedSpaceID != spaceID
        else {
            return
        }

        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()
        selectedSpaceID = spaceID
        selectActiveTabForSelectedSpace()
        BrowserTelemetry.captureUsage(.spaceSelected, properties: telemetryProperties)
        persistCurrentSessionIfAllowed()
    }

    func selectNextSpace() {
        guard supportsSpaces else {
            return
        }

        selectAdjacentSpace(offset: 1)
    }

    func selectPreviousSpace() {
        guard supportsSpaces else {
            return
        }

        selectAdjacentSpace(offset: -1)
    }

    func toggleActiveSpacePinnedSectionCollapsed() {
        guard supportsSpaces else {
            return
        }

        guard let index = selectedSpaceIndex else {
            return
        }

        spaces[index].isPinnedSectionCollapsed.toggle()
        persistCurrentSessionIfAllowed()
    }

    func setTitle(_ title: String?, forSpaceID spaceID: String) {
        guard supportsSpaces else {
            return
        }

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
        guard supportsSpaces else {
            return
        }

        guard
            let index = spaces.firstIndex(where: { $0.id == spaceID }),
            spaces[index].systemImageName != systemImageName
        else {
            return
        }

        spaces[index].systemImageName = systemImageName
        persistCurrentSessionIfAllowed()
    }

    @discardableResult func createPinnedTabFolder(containingTabIDs tabIDs: Set<String>) -> String? {
        guard let selectedSpaceID else {
            return nil
        }

        let selectedTabIDs = Set(tabIDs)
        let orderedTabs = (spacePinnedTabs + temporaryTabs).filter { selectedTabIDs.contains($0.id) }
        guard !orderedTabs.isEmpty else {
            return nil
        }

        let folderID = uniquePinnedTabFolderID()
        let folder = PinnedTabFolder(
            id: folderID,
            spaceID: selectedSpaceID,
            parentFolderID: nil,
            title: BrowserStrings.pinnedTabFolderDefaultTitle,
            systemImageName: nil,
            isExpanded: true
        )

        var updatedPinnedTabs = spacePinnedTabs.filter { !selectedTabIDs.contains($0.id) }
        let firstSelectedIndex = spacePinnedTabs.firstIndex { selectedTabIDs.contains($0.id) } ?? updatedPinnedTabs
            .count
        let folderTabs = orderedTabs.map { tab in
            var updatedTab = tab
            updatedTab.spaceID = selectedSpaceID
            updatedTab.placement = .spacePinned
            updatedTab.pinnedURLString = effectivePinnedURLString(forPinnedTab: updatedTab)
            updatedTab.pinnedFolderID = folderID
            return updatedTab
        }
        updatedPinnedTabs.insert(contentsOf: folderTabs, at: min(firstSelectedIndex, updatedPinnedTabs.count))

        pinnedTabFolders.append(folder)
        tabs = tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: tabsBySpaceID(
                replacing: updatedPinnedTabs,
                for: .spacePinned,
                inSpaceID: selectedSpaceID
            ),
            temporaryTabsBySpaceID: tabsBySpaceID(for: .temporary, removingTabIDs: selectedTabIDs),
            appTabs: appTabs
        )
        removeEmptyPinnedTabFolders()
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: Set(orderedTabs.map(\.id))))
        return folderID
    }

    func togglePinnedTabFolderExpanded(id folderID: String) {
        guard let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }) else {
            return
        }

        pinnedTabFolders[index].isExpanded.toggle()
        persistCurrentSessionIfAllowed()
    }

    func setTitle(_ title: String?, forPinnedTabFolderID folderID: String) {
        guard let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }) else {
            return
        }

        let sanitizedTitle = sanitizedPinnedTabFolderTitle(from: title) ?? BrowserStrings
            .pinnedTabFolderDefaultTitle
        guard pinnedTabFolders[index].title != sanitizedTitle else {
            return
        }

        pinnedTabFolders[index].title = sanitizedTitle
        persistCurrentSessionIfAllowed()
    }

    func setIcon(_ systemImageName: String?, forPinnedTabFolderID folderID: String) {
        guard
            let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }),
            pinnedTabFolders[index].systemImageName != systemImageName
        else {
            return
        }

        pinnedTabFolders[index].systemImageName = systemImageName
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

    @discardableResult func resetPinnedTabToPinnedURL(id tabID: String) -> Bool {
        guard
            let tab = tabs.first(where: { $0.id == tabID }),
            tab.placement == .spacePinned,
            let pinnedURLString = effectivePinnedURLString(forPinnedTab: tab)
        else {
            return false
        }

        if closedPinnedTabIDs.contains(tabID) {
            selectTab(id: tabID)
            return true
        }

        if selectedTabID != tabID {
            selectTab(id: tabID)
        }

        guard selectedTabID == tabID else {
            return false
        }

        guard !areEquivalentPinnedURLStrings(tab.urlString, pinnedURLString) else {
            return true
        }

        tabDriver.navigateActiveTab(toURLString: resolvedBrowserURLString(pinnedURLString))
        return true
    }

    @discardableResult func replacePinnedURLWithCurrent(forTabID tabID: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return false
        }

        return setPinnedURLString(tab.urlString, forTabID: tabID)
    }

    @discardableResult func setPinnedURLString(_ urlString: String?, forTabID tabID: String) -> Bool {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            tabs[index].placement == .spacePinned,
            let normalizedURLString = normalizedPinnedURLString(from: urlString)
        else {
            return false
        }

        guard tabs[index].pinnedURLString != normalizedURLString else {
            return false
        }

        tabs[index].pinnedURLString = normalizedURLString
        persistCurrentSessionIfAllowed()
        return true
    }

    func sidebarMovePlan(
        payload: BrowserSidebarDragPayload,
        destination: BrowserSidebarDropDestination
    ) -> BrowserSidebarMovePlan? {
        guard supportsAppTabs || destination.container.section != .app else { return nil }
        return BrowserSidebarMovePlan
            .make(snapshot: sidebarSnapshot, payload: payload, destination: destination) { tab, target in
                guard self.canMoveTab(tab, to: target.section.placement) else { return nil }
                var moved = tab
                moved.placement = target.section.placement
                if let spaceID = target.spaceID {
                    moved.spaceID = spaceID
                }
                moved.pinnedFolderID = target.folderID
                moved.pinnedURLString = self.pinnedURLString(for: tab, movingTo: target.section.placement)
                return moved
            }
    }

    /// Revalidate by stable IDs at release, then publish one final order.
    @discardableResult func commitSidebarDrop(
        payload: BrowserSidebarDragPayload,
        destination: BrowserSidebarDropDestination
    ) -> Bool {
        guard let plan = sidebarMovePlan(payload: payload, destination: destination) else { return false }
        let oldTabs = tabs
        let activeMovedID = selectedTabID.flatMap { payload.tabIDs.contains($0) ? $0 : nil }
        let now = dateProvider()
        let updatesActivity =
            if case .tab = payload.primary {
                true
            } else {
                false
            }
        tabs = plan.tabs.map { tab in
            var tab = tab
            if updatesActivity, payload.tabIDs.contains(tab.id) {
                tab.lastActivityAt = now
            }
            return tab
        }
        pinnedTabFolders = plan.folders
        removeEmptyPinnedTabFolders()
        for id in payload.tabIDs {
            guard let moved = tabs.first(where: { $0.id == id }) else { continue }
            if moved.placement != .app {
                closedAppTabIDs.remove(id)
            }
            if moved.placement != .spacePinned {
                closedPinnedTabIDs.remove(id)
            }
            if moved.placement != .app, let old = oldTabs.first(where: { $0.id == id }) {
                let wasSourceSelection = spaces.first(where: { $0.id == old.spaceID })?.selectedTabID == id
                if old.spaceID != moved.spaceID, wasSourceSelection {
                    clearSelectedTab(id, forSpaceID: old.spaceID)
                }
                if activeMovedID == id || (wasSourceSelection && moved.spaceID != selectedSpaceID) {
                    setSelectedTabID(id, forSpaceID: moved.spaceID)
                }
            }
        }
        if activeMovedID != nil {
            selectActiveTabForSelectedSpace()
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: payload.tabIDs))
        return true
    }

    func canMoveTab(
        withID tabID: String,
        toPlacement placement: BrowserTabPlacement,
        atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil
    ) -> Bool {
        guard
            let reorderedTabs = reorderedTabs(
                movingTabID: tabID,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID
            )
        else {
            return false
        }

        return reorderedTabs != tabs
    }

    func canMoveTabs(
        withIDs tabIDs: Set<String>,
        toPlacement placement: BrowserTabPlacement,
        atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil
    ) -> Bool {
        guard
            let reorderedTabs = reorderedTabs(
                movingTabIDs: tabIDs,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID
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
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil
    ) {
        guard
            let movingTab = tabs.first(where: { $0.id == tabID }),
            var reorderedTabs = reorderedTabs(
                movingTabID: tabID,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID
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
        removeEmptyPinnedTabFolders()
        if
            let movedTab = tabs.first(where: { $0.id == tabID }),
            movedTab.placement != .app
        {
            closedAppTabIDs.remove(tabID)
            if wasSelectedInSourceSpace {
                clearSelectedTab(tabID, forSpaceID: movingTab.spaceID)
                setSelectedTabID(tabID, forSpaceID: movedTab.spaceID)
            }
        }
        if
            let movedTab = tabs.first(where: { $0.id == tabID }),
            movedTab.placement != .spacePinned
        {
            closedPinnedTabIDs.remove(tabID)
        }
        if selectedTabID == tabID {
            selectActiveTabForSelectedSpace()
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: [tabID]))
    }

    func moveTabs(
        withIDs tabIDs: Set<String>,
        toPlacement placement: BrowserTabPlacement,
        atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil
    ) {
        let movingTabIDs = Set(tabIDs)
        guard
            movingTabIDs.count > 1,
            var reorderedTabs = reorderedTabs(
                movingTabIDs: movingTabIDs,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID
            ),
            reorderedTabs != tabs
        else {
            return
        }

        let now = dateProvider()
        for index in reorderedTabs.indices where movingTabIDs.contains(reorderedTabs[index].id) {
            reorderedTabs[index].lastActivityAt = now
        }

        let selectedMovedTabID = selectedTabID.flatMap { movingTabIDs.contains($0) ? $0 : nil }
        tabs = reorderedTabs
        removeEmptyPinnedTabFolders()

        if
            let selectedMovedTabID,
            let movedTab = tabs.first(where: { $0.id == selectedMovedTabID }),
            movedTab.placement != .app
        {
            setSelectedTabID(selectedMovedTabID, forSpaceID: movedTab.spaceID)
        }
        for tabID in movingTabIDs where tabs.first(where: { $0.id == tabID })?.placement != .spacePinned {
            closedPinnedTabIDs.remove(tabID)
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: movingTabIDs))
    }

    func canMovePinnedTabFolder(
        withID folderID: String,
        toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil,
        targetParentFolderID: String? = nil
    ) -> Bool {
        guard
            let folder = pinnedTabFolders.first(where: { $0.id == folderID }),
            let reorderedTabs = reorderedTabs(
                movingPinnedTabFolderID: folderID,
                toRootSectionIndex: rootSectionIndex,
                targetSpaceID: targetSpaceID,
                targetParentFolderID: targetParentFolderID
            )
        else {
            return false
        }

        let resolvedTargetSpaceID = targetParentFolderID
            .flatMap { parentFolderID in pinnedTabFolders.first { $0.id == parentFolderID }?.spaceID }
            ?? targetSpaceID
            ?? selectedSpaceID
            ?? folder.spaceID
        return reorderedTabs != tabs
            || folder.parentFolderID != targetParentFolderID
            || folder.spaceID != resolvedTargetSpaceID
    }

    func movePinnedTabFolder(
        withID folderID: String,
        toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil,
        targetParentFolderID: String? = nil
    ) {
        guard
            let folderIndex = pinnedTabFolders.firstIndex(where: { $0.id == folderID }),
            let reorderedTabs = reorderedTabs(
                movingPinnedTabFolderID: folderID,
                toRootSectionIndex: rootSectionIndex,
                targetSpaceID: targetSpaceID,
                targetParentFolderID: targetParentFolderID
            )
        else {
            return
        }

        let resolvedTargetSpaceID = targetParentFolderID
            .flatMap { parentFolderID in pinnedTabFolders.first { $0.id == parentFolderID }?.spaceID }
            ?? targetSpaceID
            ?? selectedSpaceID
            ?? pinnedTabFolders[folderIndex].spaceID
        guard reorderedTabs != tabs
            || pinnedTabFolders[folderIndex].parentFolderID != targetParentFolderID
            || pinnedTabFolders[folderIndex].spaceID != resolvedTargetSpaceID
        else {
            return
        }

        let movedFolderIDs = descendantPinnedTabFolderIDs(including: folderID)
        for index in pinnedTabFolders.indices where movedFolderIDs.contains(pinnedTabFolders[index].id) {
            pinnedTabFolders[index].spaceID = resolvedTargetSpaceID
        }
        pinnedTabFolders[folderIndex].parentFolderID = targetParentFolderID
        if targetParentFolderID != nil {
            pinnedTabFolders[folderIndex].isExpanded = true
        }
        tabs = reorderedTabs
        let movedTabIDs = Set(tabs.filter {
            $0.placement == .spacePinned && $0.pinnedFolderID.map { movedFolderIDs.contains($0) } == true
        }
        .map(\.id))
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: movedTabIDs))
    }

    func clearTemporaryTabs(includingActiveTab: Bool = true) {
        let activeTemporaryTabID = includingActiveTab || selectedTab?.placement != .temporary
            ? nil
            : selectedTabID
        let temporaryTabIDs = temporaryTabs
            .map(\.id)
            .filter { $0 != activeTemporaryTabID }
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
        bookmarksModel.reload()
        refreshBrowserExtensions()
        syncCoordinator?.schedulePull()
    }

    func updateProfilePresentation(profile: BrowserProfile, availableProfileCount: Int) {
        profileDisplayName = profile.displayName
        self.availableProfileCount = availableProfileCount
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
            closeTab(id: tabID, registersUndo: false)
        }
    }

    func presentCommandBar() {
        guard canCreateTab else {
            return
        }

        bookmarksModel.reload()
        dismissFindBar()
        currentPageCommandBarModel.dismiss()
        commandBarModel.present()
        BrowserTelemetry.captureUsage(.commandBarPresented, properties: telemetryProperties)
    }

    func toggleCommandBar() {
        guard canCreateTab else {
            return
        }

        if commandBarModel.isPresented {
            commandBarModel.dismiss()
        } else {
            bookmarksModel.reload()
            dismissFindBar()
            currentPageCommandBarModel.dismiss()
            commandBarModel.present()
            BrowserTelemetry.captureUsage(.commandBarPresented, properties: telemetryProperties)
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

        bookmarksModel.reload()
        dismissFindBar()
        commandBarModel.dismiss()
        currentPageCommandBarModel.present(initialQuery: selectedTab.urlString)
        BrowserTelemetry.captureUsage(.currentPageCommandBarPresented, properties: telemetryProperties)
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
        BrowserTelemetry.captureUsage(.findPresented, properties: telemetryProperties)
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
        if selectedTabCreationState == .failed {
            retrySelectedTabCreation()
            return
        }

        tabDriver.reloadActiveTab()
        BrowserTelemetry.captureUsage(.tabReloaded, properties: telemetryProperties)
    }

    @discardableResult func retrySelectedTabCreation() -> Bool {
        guard canCreateTab, let index = selectedTabIndex,
              tabs[index].creationState == .failed,
              !closedAppTabIDs.contains(tabs[index].id),
              !closedPinnedTabIDs.contains(tabs[index].id),
              !closingTabIDs.contains(tabs[index].id)
        else { return false }

        let tab = tabs[index]
        // Retry only the runtime allocation. The logical tab and its durable
        // snapshot/outbox remain unchanged, including selection and undo IDs.
        tabs[index].creationState = .creating
        guard tabDriver.retryTabCreation(withID: tab.id, urlString: resolvedBrowserURLString(tab.urlString)) else {
            tabs[index].creationState = .failed
            return false
        }
        return true
    }

    func forceReloadCurrentTab() {
        guard canReload else {
            return
        }
        if selectedTabCreationState == .failed {
            retrySelectedTabCreation()
            return
        }

        tabDriver.reloadActiveTabIgnoringCache()
        BrowserTelemetry.captureUsage(
            .tabReloaded,
            properties: telemetryProperties.merging(["force": "true"]) { _, new in new }
        )
    }

    func clearCacheAndRefreshCurrentTab() {
        guard canReload else {
            return
        }

        tabDriver.clearCacheAndReloadActiveTab()
        BrowserTelemetry.captureUsage(
            .tabReloaded,
            properties: telemetryProperties.merging(["clear_cache": "true"]) { _, new in new }
        )
    }

    func clearCookiesAndRefreshCurrentTab() {
        guard canReload else {
            return
        }

        tabDriver.clearCookiesAndReloadActiveTab()
        BrowserTelemetry.captureUsage(
            .tabReloaded,
            properties: telemetryProperties.merging(["clear_cookies": "true"]) { _, new in new }
        )
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

    @discardableResult func captureFullPageSelectedTabToPasteboard() -> Bool {
        guard selectedTabID != nil else {
            return false
        }

        tabDriver.captureFullPageActiveTabToPasteboard()
        return true
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
        removeUnavailablePinnedExtensionsIfNeeded()
        closeExtensionSidePanelIfNeeded()
    }

    func openExtensionsManager() {
        openURLInNewTab(URL(string: BrowserExtensionRouting.extensionsURLString)!)
    }

    @discardableResult func openExtension(id: String) -> BrowserExtensionActionPopup? {
        guard
            isContextReady,
            let browserExtension = browserExtensions.first(where: { $0.id == id }),
            browserExtension.isEnabled
        else {
            return nil
        }

        switch extensionManager.runAction(id: id) {
        case .popup(let urlString):
            guard let extensionActionPopupDriver else {
                return nil
            }

            let popupID = extensionActionPopupDriver.openPopup(urlString: urlString)
            return BrowserExtensionActionPopup(
                id: popupID,
                extensionID: browserExtension.id,
                title: browserExtension.name,
                hostView: extensionActionPopupDriver.hostView,
                closeHandler: { [weak extensionActionPopupDriver] in
                    extensionActionPopupDriver?.closePopup(id: popupID)
                }
            )
        case .sidePanel:
            openExtensionSidePanel(id: id)
            return nil
        case .handled:
            if browserExtension.sidePanelURLString != nil {
                openExtensionSidePanel(id: id)
            }
            return nil
        case .failed:
            if browserExtension.sidePanelURLString != nil {
                openExtensionSidePanel(id: id)
            }
            return nil
        }
    }

    func openExtensionDetails(id: String) {
        openURLInNewTab(URL(string: BrowserExtensionRouting.detailsURLString(forExtensionID: id))!)
    }

    func openExtensionStore() {
        openURLInNewTab(URL(string: BrowserExtensionRouting.chromeWebStoreURLString)!)
    }

    func openExtensionStore(id: String) {
        openURLInNewTab(URL(string: BrowserExtensionRouting.chromeWebStoreURLString(forExtensionID: id))!)
    }

    @discardableResult func setExtension(id: String, isEnabled: Bool) -> Bool {
        guard extensionManager.setExtension(id: id, isEnabled: isEnabled) else {
            return false
        }

        refreshBrowserExtensions()
        return true
    }

    @discardableResult func openExtensionSidePanel(id: String) -> Bool {
        guard
            isContextReady,
            let extensionSidePanelDriver,
            let browserExtension = browserExtensions.first(where: { $0.id == id }),
            browserExtension.isEnabled,
            let urlString = browserExtension.sidePanelURLString
        else {
            return false
        }

        let panelID = extensionSidePanelDriver.openPanel(urlString: urlString)
        extensionSidePanel = BrowserExtensionSidePanel(
            panelID: panelID,
            extensionID: browserExtension.id,
            title: browserExtension.name,
            urlString: urlString,
            iconData: browserExtension.iconData
        )
        return true
    }

    func closeExtensionSidePanel() {
        guard let sidePanel = extensionSidePanel else {
            return
        }

        extensionSidePanel = nil
        extensionSidePanelDriver?.closePanel(id: sidePanel.panelID)
    }

    @discardableResult func removeExtension(id: String) -> Bool {
        guard extensionManager.removeExtension(id: id) else {
            return false
        }

        setExtension(id: id, isPinned: false)
        refreshBrowserExtensions()
        return true
    }

    func isExtensionPinned(id: String) -> Bool {
        pinnedExtensionIDs.contains(id)
    }

    @discardableResult func setExtension(id: String, isPinned: Bool) -> Bool {
        let isCurrentlyPinned = pinnedExtensionIDs.contains(id)
        guard isCurrentlyPinned != isPinned else {
            return false
        }

        var updatedIDs = pinnedExtensionIDs.filter { $0 != id }
        if isPinned {
            updatedIDs.append(id)
        }
        setPinnedExtensionIDs(updatedIDs)
        return true
    }

    @discardableResult func toggleExtensionPinned(id: String) -> Bool {
        setExtension(id: id, isPinned: !isExtensionPinned(id: id))
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

    func zoomIn() {
        guard let nextPercent = Self.zoomPercentages.first(where: { $0 > zoomPercent }) else {
            return
        }

        setZoomPercent(nextPercent)
    }

    func zoomOut() {
        guard let previousPercent = Self.zoomPercentages.last(where: { $0 < zoomPercent }) else {
            return
        }

        setZoomPercent(previousPercent)
    }

    func resetZoom() {
        setZoomPercent(100)
    }

    func setZoomPercent(_ percent: Int) {
        guard canCreateTab, selectedTabID != nil, Self.zoomPercentages.contains(percent) else {
            return
        }

        zoomPercent = percent
        let zoomLevel = log(Double(percent) / 100) / log(1.2)
        tabDriver.setActiveTabZoomLevel(zoomLevel)
    }

    func castCurrentPage() {
        guard canCastPage else {
            return
        }

        tabDriver.castActiveTab()
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
            closeTab(id: tabID, registersUndo: false)
        }
    }

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        guard !isShuttingDown else { return }
        guard !hasUncommittedSessionWrites, !hasDiscardedSessionForClosure else {
            // The coordinator must gate its durable commit too. Never retain a
            // stale projection to replay over successfully retried local actions.
            deferredRemoteSyncSnapshot = nil
            return
        }
        guard isContextReady, !isRestoringSession else {
            deferredRemoteSyncSnapshot = snapshot
            return
        }

        isApplyingRemoteSync = true
        isReconcilingRemoteProjection = true
        remoteProjectionGeneration += 1
        remoteProjectionSnapshot = snapshot
        hasCreatedInitialTab = true
        let previousSpaceSelections = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.selectedTabID) })
        var seenSyncIDs = Set<String>()
        let remoteTabs = snapshot.tabs.filter { tab in
            guard let id = tab.id, !id.isEmpty else { return false }
            return seenSyncIDs.insert(id).inserted
        }
        let remoteTabsByID = Dictionary(uniqueKeysWithValues: remoteTabs.compactMap { tab in
            tab.id.map { ($0, tab) }
        })

        for (engineID, binding) in pendingRemoteTabCreations {
            guard let replacement = remoteTabsByID[binding.snapshot.id ?? ""] else {
                pendingRemoteTabCreations.removeValue(forKey: engineID)
                discardedRemoteTabCreationIDs.insert(engineID)
                tabDriver.closeTab(withID: engineID, forceClose: true)
                continue
            }
            pendingRemoteTabCreations[engineID] = RemoteTabCreation(
                snapshot: replacement, generation: remoteProjectionGeneration
            )
        }

        for tab in tabs where !seenSyncIDs.contains(tab.syncID)
            || ((closedAppTabIDs.contains(tab.id) || closedPinnedTabIDs.contains(tab.id))
                && remoteTabsByID[tab.syncID]?.placement != tab.placement)
        {
            closeTab(id: tab.id, forceClose: true, registersUndo: false)
        }

        let restoredSpaces = snapshot.spaces?.isEmpty != false ? [] : restoredSpaces(from: snapshot)
        needsRemoteFallbackPublication = restoredSpaces.isEmpty
        if needsRemoteFallbackPublication {
            // Concurrent deletion can remove every space. The old default ID
            // may be tombstoned; this is a new local parent that must be queued.
            spaces = [makeDefaultSpace(id: UUID().uuidString)]
            hasLocalChangesDuringRemoteProjection = true
        } else {
            spaces = restoredSpaces
        }
        pinnedTabFolders = restoredPinnedTabFolders(from: snapshot)
        selectedSpaceID = selectedSpaceID.flatMap { selectedSpaceID in
            spaces.contains(where: { $0.id == selectedSpaceID }) ? selectedSpaceID : nil
        } ?? spaces.first?.id

        for index in tabs.indices {
            guard let remoteTab = remoteTabsByID[tabs[index].syncID] else { continue }
            var tab = tabs[index]
            applyRemoteTabMetadata(remoteTab, to: &tab)
            tabs[index] = tab
        }
        for index in spaces.indices {
            spaces[index].selectedTabID = previousSpaceSelections[spaces[index].id] ?? nil
        }

        let existingSyncIDs = Set(tabs.map(\.syncID))
        let pendingSyncIDs = Set(pendingRemoteTabCreations.values.compactMap(\.snapshot.id))
        for remoteTab in remoteTabs {
            guard let syncID = remoteTab.id,
                  !existingSyncIDs.contains(syncID), !pendingSyncIDs.contains(syncID)
            else { continue }
            let engineID = tabDriver.createTab(withURLString: remoteTab.urlString, makeActive: false)
            pendingRemoteTabCreations[engineID] = RemoteTabCreation(
                snapshot: remoteTab, generation: remoteProjectionGeneration
            )
        }
        isReconcilingRemoteProjection = false
        finishRemoteSyncProjectionIfReady()
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

        guard let selectedTab = tabs.first(where: { $0.id == selectedTabID }) else {
            return false
        }

        if selectedTab.placement == .app {
            return closeAppTabProcess(id: selectedTabID)
        }

        if selectedTab.placement == .spacePinned, effectivePinnedURLString(forPinnedTab: selectedTab) != nil {
            return closePinnedTabProcessOrReset(id: selectedTabID)
        }

        return closeTab(id: selectedTabID)
    }

    @discardableResult func closeAppTabProcess(id: String, forceClose: Bool = false) -> Bool {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            tab.placement == .app,
            !closedAppTabIDs.contains(id)
        else {
            return false
        }

        closedAppTabIDs.insert(id)
        removeTabFromSwitcherTracking(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: tab))

        if selectedTabID == id {
            clearSelectedTab(id, forSpaceID: tab.spaceID)
            let fallbackTabID = fallbackTabID(afterClosingTab: tab) ?? sidebarTabsForSelectedSpace().first?.id
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                setSelectedTabID(fallbackTabID, forSpaceID: tab.spaceID)
                recordSelectedTab(fallbackTabID)
                runFind(forward: true, findNext: false)
            } else {
                tabDriver.deselectActiveTab()
            }
        }

        tabDriver.closeTab(withID: id, forceClose: forceClose)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    @discardableResult func closePinnedTabProcessOrReset(id: String, forceClose: Bool = false) -> Bool {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            tab.placement == .spacePinned,
            let pinnedURLString = effectivePinnedURLString(forPinnedTab: tab),
            !closedPinnedTabIDs.contains(id)
        else {
            return false
        }

        if !areEquivalentPinnedURLStrings(tab.urlString, pinnedURLString),
           let index = tabs.firstIndex(where: { $0.id == id })
        {
            tabs[index].title = ""
            tabs[index].urlString = pinnedURLString
            tabs[index].faviconURLString = nil
            tabs[index].canGoBack = false
            tabs[index].canGoForward = false
            tabs[index].isLoading = false
        }

        closedPinnedTabIDs.insert(id)
        removeTabFromSwitcherTracking(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: tab))

        if selectedTabID == id {
            clearSelectedTab(id, forSpaceID: tab.spaceID)
            let fallbackTabID = fallbackTabID(afterClosingDormantTab: tab, excluding: [id])
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                setSelectedTabID(fallbackTabID, forSpaceID: tab.spaceID)
                recordSelectedTab(fallbackTabID)
                runFind(forward: true, findNext: false)
            } else {
                tabDriver.deselectActiveTab()
            }
        }

        tabDriver.closeTab(withID: id, forceClose: forceClose)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    func removeAppTabFavorite(id: String) {
        if closedAppTabIDs.contains(id), let tab = tabs.first(where: { $0.id == id }) {
            tabs.removeAll { $0.id == id }
            closedAppTabIDs.remove(id)
            removeTabFromSwitcherTracking(id)
            clearSelectedTab(id, forSpaceID: tab.spaceID)
            removeEmptyPinnedTabFolders()
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
            return
        }

        moveTab(
            withID: id,
            toPlacement: .temporary,
            atSectionIndex: temporaryTabs.count
        )
    }

    func hasTabsBelow(id: String) -> Bool {
        !tabIDsBelowInSidebarOrder(forTabID: id).isEmpty
    }

    func selectTab(id: String) {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            !closingTabIDs.contains(id)
        else {
            return
        }

        if closedAppTabIDs.contains(id), tab.placement == .app {
            reopenClosedAppTab(id: id)
            return
        }

        if closedPinnedTabIDs.contains(id), tab.placement == .spacePinned {
            reopenClosedPinnedTab(id: id)
            return
        }

        guard selectedTabID != id else {
            return
        }

        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()

        if tab.spaceID != selectedSpaceID {
            selectedSpaceID = tab.spaceID
        }
        selectedTabID = id
        setSelectedTabID(id, forSpaceID: tab.spaceID)
        findResultMatchCount = nil
        tabDriver.selectTab(withID: id)
        scheduleSelectedTabWebAppManifestLoad()
        touchTab(id: id)
        recordSelectedTab(id)
        updateWindowTitle()
        BrowserTelemetry.captureUsage(.tabSelected, properties: telemetryProperties(for: tab))
        persistCurrentSessionIfAllowed()
        runFind(forward: true, findNext: false)
    }

    @discardableResult func advanceTabSwitcher(reverse: Bool = false) -> Bool {
        if var state = tabSwitcherState, !state.entries.isEmpty {
            let selectedIndex = state.entries.firstIndex { $0.id == state.selectedTabID } ?? 0
            let offset = reverse ? -1 : 1
            let nextIndex = (selectedIndex + offset + state.entries.count) % state.entries.count
            state.selectedTabID = state.entries[nextIndex].id
            tabSwitcherState = state
            return true
        }

        captureSelectedTabPreviewIfNeeded()
        let entries = tabSwitcherEntries()
        guard entries.count > 1 else {
            return false
        }

        let initialSelectionIndex = reverse ? entries.count - 1 : 1
        tabSwitcherState = TabSwitcherState(
            entries: entries,
            selectedTabID: entries[initialSelectionIndex].id,
            isVisible: false
        )
        scheduleTabSwitcherPresentation()
        return true
    }

    @discardableResult func commitTabSwitcher() -> Bool {
        guard let state = tabSwitcherState else {
            return false
        }

        clearTabSwitcherState()
        if selectedTabID != state.selectedTabID {
            selectTab(id: state.selectedTabID)
        }
        return true
    }

    @discardableResult func cancelTabSwitcher() -> Bool {
        guard tabSwitcherState != nil else {
            return false
        }

        clearTabSwitcherState()
        return true
    }

    @discardableResult func closeTab(
        id: String,
        forceClose: Bool = false,
        registersUndo: Bool = true,
        undoActionName: String = BrowserStrings.tabArchiveAction
    ) -> Bool {
        guard
            let closingIndex = tabs.firstIndex(where: { $0.id == id }),
            !closingTabIDs.contains(id)
        else {
            return false
        }

        let closingTab = tabs[closingIndex]
        let undoSnapshot = tabUndoSnapshot(forClosingTabAt: closingIndex)
        let closingTabWasSelected = selectedTabID == id
        closingTabIDs.insert(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: closingTab))

        tabs.removeAll { $0.id == id }
        closedAppTabIDs.remove(id)
        closedPinnedTabIDs.remove(id)
        pendingReopenedAppTabIDs = pendingReopenedAppTabIDs.filter { $0.value != id && $0.key != id }
        pendingReopenedPinnedTabIDs = pendingReopenedPinnedTabIDs.filter { $0.value != id && $0.key != id }
        removeTabFromSwitcherTracking(id)
        tabCreationUndoReferences.removeValue(forKey: id)?.currentTabID = nil
        clearSelectedTab(id, forSpaceID: closingTab.spaceID)
        removeEmptyPinnedTabFolders()

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
                recordSelectedTab(fallbackTabID)
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
        if registersUndo, let undoSnapshot {
            registerTabArchiveUndo(undoSnapshot, actionName: undoActionName)
        }
        return true
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

    func setExtensionSidePanelWidth(_ width: CGFloat) {
        let clampedWidth = min(max(width, Self.minExtensionSidePanelWidth), Self.maxExtensionSidePanelWidth)
        guard extensionSidePanelWidth != clampedWidth else {
            return
        }
        extensionSidePanelWidth = clampedWidth
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
        let undoSnapshot: TabUndoSnapshot?
    }

    private final class TabCreationUndoReference {
        // MARK: Lifecycle

        init(tabID: String) {
            self.currentTabID = tabID
        }

        // MARK: Internal

        var currentTabID: String?
    }

    private struct TabUndoSnapshot {
        let tab: Tab
        let insertionIndex: Int
        let wasSelectedTab: Bool
        let wasSelectedInSpace: Bool
        let creationUndoReference: TabCreationUndoReference?
    }

    private struct PinnedRootItem {
        let firstSectionIndex: Int
        let afterSectionIndex: Int
    }

    private struct RemoteTabCreation {
        let snapshot: BrowserTabSessionSnapshotTab
        let generation: Int
    }

    private let tabDriver: BrowserTabDriving
    private let sessionSnapshotStore: BrowserTabSessionSnapshotStoring
    private let sessionPreferencesStore: BrowserSessionPreferencesStoring
    private let newTabURLString: String
    private let commandBarSuggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
    private let historyStore: BrowserHistorySearching
    private let extensionManager: any BrowserExtensionManaging
    private let extensionSidePanelDriver: (any BrowserExtensionSidePanelDriving)?
    private let extensionActionPopupDriver: (any BrowserExtensionActionPopupDriving)?
    private let syncCoordinator: BrowserSyncCoordinating?
    private let windowTitleHandler: (String) -> Void
    private let allTabsClosedHandler: () -> Void
    private let dateProvider: () -> Date
    private let spaceIDProvider: () -> String
    private let tabSyncIDProvider: () -> String
    private let commandHandler: (BrowserCommandID) -> Void

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private var closedAppTabIDs = Set<String>()
    private var closedPinnedTabIDs = Set<String>()
    private var pendingReopenedAppTabIDs = [String: String]()
    private var pendingReopenedPinnedTabIDs = [String: String]()
    private var isPersistenceEnabled = true
    private var sessionWriteBuffer = BrowserSessionWriteBuffer()
    private var hasDiscardedSessionForClosure = false
    private var isSessionClosurePrepared = false
    private var isRestoringSession = false
    private var isApplyingRemoteSync = false
    private var deferredRemoteSyncSnapshot: BrowserTabSessionSnapshot?
    private var remoteProjectionSnapshot: BrowserTabSessionSnapshot?
    private var remoteProjectionGeneration = 0
    private var isReconcilingRemoteProjection = false
    private var hasLocalChangesDuringRemoteProjection = false
    private var needsRemoteFallbackPublication = false
    private var pendingRemoteTabCreations = [String: RemoteTabCreation]()
    private var discardedRemoteTabCreationIDs = Set<String>()
    private var pendingRestoredSelectedTabIndex: Int?
    private var restoredTabCreationIDs = Set<String>()
    private var pendingRestoredSpaces = [BrowserSpaceSessionSnapshot]()
    private var pendingCreatedTabContexts = [String: PendingCreatedTabContext]()
    private var tabCreationUndoReferences = [String: TabCreationUndoReference]()
    private var automaticArchivalTimer: Timer?
    private var recentlySelectedTabIDs = [String]()
    private var tabPreviewImagesByID = [String: NSImage]()
    private var tabSwitcherPresentationTask: Task<Void, Never>?
    private var tabSwitcherSessionID = UUID()
    private var webAppManifestLoadTask: Task<Void, Never>?

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

    private var telemetryProperties: [String: String] {
        [
            "profile": profile.isDefault ? "default" : "custom",
            "window_mode": windowMode.telemetryValue,
            "space_count": "\(spaces.count)",
            "tab_count": "\(tabs.count)",
        ]
    }

    private var canRegisterTabUndo: Bool {
        isContextReady && isPersistenceEnabled && !isRestoringSession && !isShuttingDown
    }

    private func applyRemoteTabMetadata(_ snapshot: BrowserTabSessionSnapshotTab, to tab: inout Tab) {
        tab.spaceID = snapshot.spaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil }
            ?? spaces.first?.id ?? Self.defaultSpaceID
        tab.placement = snapshot.placement
        tab.userTitleOverride = sanitizedUserTitleOverride(from: snapshot.userTitleOverride)
        tab.pinnedURLString = snapshot.placement == .spacePinned
            ? normalizedPinnedURLString(from: snapshot.pinnedURLString ?? snapshot.urlString)
            : nil
        tab.pinnedFolderID = snapshot.placement == .spacePinned ? snapshot.pinnedFolderID : nil
        // Existing engines keep their live URL, title, navigation stack and loading
        // state. A remote URL initializes a new identity; it does not navigate a live page.
    }

    private func finishRemoteSyncProjectionIfReady() {
        guard isApplyingRemoteSync, !isReconcilingRemoteProjection,
              let snapshot = remoteProjectionSnapshot
        else { return }

        var remoteOrder = [String: Int]()
        for (index, tab) in snapshot.tabs.enumerated() {
            if let id = tab.id, remoteOrder[id] == nil {
                remoteOrder[id] = index
            }
        }
        tabs = tabs.enumerated()
            .sorted { lhs, rhs in
                let left = remoteOrder[lhs.element.syncID] ?? snapshot.tabs.count + lhs.offset
                let right = remoteOrder[rhs.element.syncID] ?? snapshot.tabs.count + rhs.offset
                return left < right
            }
            .map(\.element)
        guard pendingRemoteTabCreations.isEmpty else { return }
        removeInvalidPinnedTabFolderAssignments()

        for index in spaces.indices {
            let visibleTabs = sidebarTabs(forSpaceID: spaces[index].id)
            if let selectedID = spaces[index].selectedTabID, visibleTabs.contains(where: { $0.id == selectedID }) {
                continue
            }
            let remoteIndex = snapshot.spaces?.first { $0.id == spaces[index].id }?.selectedTabIndex
            spaces[index].selectedTabID = remoteIndex.flatMap {
                visibleTabs.indices.contains($0) ? visibleTabs[$0].id : nil
            } ?? visibleTabs.first?.id
        }
        if let selectedTab = tabs.first(where: { $0.id == selectedTabID }) {
            selectedSpaceID = selectedTab.spaceID
            setSelectedTabID(selectedTab.id, forSpaceID: selectedTab.spaceID)
        } else {
            selectActiveTabForSelectedSpace()
        }
        updateWindowTitle()
        let origin: BrowserSessionWrite.Origin = needsRemoteFallbackPublication
            ? .local(syncMove: nil)
            : .remoteProjection
        let schedulesPush = hasLocalChangesDuringRemoteProjection || needsRemoteFallbackPublication
        needsRemoteFallbackPublication = false
        remoteProjectionSnapshot = nil
        isApplyingRemoteSync = false
        hasLocalChangesDuringRemoteProjection = false
        _ = persistSessionWrite(.init(snapshot: currentSessionSnapshot(), origin: origin), schedulesPush: schedulesPush)
    }

    @discardableResult private func drainDeferredRemoteSyncSnapshot() -> Bool {
        guard !hasUncommittedSessionWrites, !hasDiscardedSessionForClosure else {
            deferredRemoteSyncSnapshot = nil
            return false
        }
        guard isContextReady, !isRestoringSession, let snapshot = deferredRemoteSyncSnapshot else { return false }
        deferredRemoteSyncSnapshot = nil
        applyRemoteSyncSnapshot(snapshot)
        return true
    }

    private func handleRemoteCreatedTab(id: String, title: String, urlString: String) -> Bool {
        if discardedRemoteTabCreationIDs.remove(id) != nil {
            tabDriver.closeTab(withID: id, forceClose: true)
            return true
        }
        guard let binding = pendingRemoteTabCreations.removeValue(forKey: id) else { return false }
        guard binding.generation == remoteProjectionGeneration, let syncID = binding.snapshot.id else {
            tabDriver.closeTab(withID: id, forceClose: true)
            return true
        }
        var tab = Tab(
            id: id, syncID: syncID, spaceID: Self.defaultSpaceID, title: title,
            urlString: urlString, lastActivityAt: lastActivityDate(from: binding.snapshot) ?? dateProvider()
        )
        applyRemoteTabMetadata(binding.snapshot, to: &tab)
        tabs.append(tab)
        finishRemoteSyncProjectionIfReady()
        return true
    }

    private func telemetryProperties(for tab: Tab) -> [String: String] {
        var properties = telemetryProperties
        properties["placement"] = tab.placement.rawValue
        properties["is_selected"] = selectedTabID == tab.id ? "true" : "false"
        properties["is_internal_page"] = Self.internalPage(for: tab.urlString) == nil ? "false" : "true"
        if let scheme = URL(string: tab.urlString)?.scheme {
            properties["scheme"] = scheme.lowercased()
        }
        return properties
    }

    private func handleExtensionSidePanelClosed(panelID: String) {
        guard extensionSidePanel?.panelID == panelID else {
            return
        }

        extensionSidePanel = nil
    }

    private func closeExtensionSidePanelIfNeeded() {
        guard let sidePanel = extensionSidePanel else {
            return
        }

        guard
            let browserExtension = browserExtensions.first(where: { $0.id == sidePanel.extensionID }),
            browserExtension.isEnabled,
            browserExtension.sidePanelURLString == sidePanel.urlString
        else {
            closeExtensionSidePanel()
            return
        }

        extensionSidePanel = BrowserExtensionSidePanel(
            panelID: sidePanel.panelID,
            extensionID: browserExtension.id,
            title: browserExtension.name,
            urlString: sidePanel.urlString,
            iconData: browserExtension.iconData
        )
    }

    private func removeUnavailablePinnedExtensionsIfNeeded() {
        guard !browserExtensions.isEmpty else {
            return
        }

        let availableExtensionIDs = Set(browserExtensions.map(\.id))
        let availablePinnedExtensionIDs = pinnedExtensionIDs.filter(availableExtensionIDs.contains)
        guard availablePinnedExtensionIDs != pinnedExtensionIDs else {
            return
        }

        setPinnedExtensionIDs(availablePinnedExtensionIDs)
    }

    private func setPinnedExtensionIDs(_ ids: [String]) {
        var seen = Set<String>()
        let normalizedIDs = ids.filter { id in
            guard !id.isEmpty, !seen.contains(id) else {
                return false
            }

            seen.insert(id)
            return true
        }

        pinnedExtensionIDs = normalizedIDs
        userPreferencesStore.pinnedExtensionIDs = normalizedIDs
    }

    private func ensureInitialTab() {
        guard canCreateTab, !hasCreatedInitialTab else {
            return
        }

        ensureDefaultSpace()
        hasCreatedInitialTab = true
        createTab(withURLString: newTabURLString, registersUndo: false)
    }

    private func restoreSessionIfAvailable() -> Bool {
        guard windowMode.persistsSession else {
            return false
        }

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
        pinnedTabFolders = restoredPinnedTabFolders(from: snapshot)
        let selectedSpaceIndex = sessionPreferencesStore.loadSelectedSpaceIndex(
            spaceCount: spaces.count
        ) ?? 0
        selectedSpaceID = spaces.indices.contains(selectedSpaceIndex) ? spaces[selectedSpaceIndex].id : spaces.first?.id
        pendingRestoredSelectedTabIndex = sessionPreferencesStore.loadSelectedTabIndex(
            tabCount: snapshot.tabs.count
        )
        pendingRestoredSpaces = snapshot.spaces ?? []
        for (index, tabSnapshot) in snapshot.tabs.enumerated() {
            let engineID = tabDriver.createTab(
                withURLString: tabSnapshot.urlString,
                makeActive: index == pendingRestoredSelectedTabIndex
            )
            restoredTabCreationIDs.insert(engineID)
            let placement = tabSnapshot.placement
            tabs.append(Tab(
                id: engineID,
                syncID: tabSnapshot.id ?? tabSyncIDProvider(),
                spaceID: tabSnapshot.spaceID ?? selectedSpaceID ?? Self.defaultSpaceID,
                title: "",
                userTitleOverride: tabSnapshot.userTitleOverride,
                urlString: tabSnapshot.urlString,
                pinnedURLString: placement == .spacePinned
                    ? normalizedPinnedURLString(from: tabSnapshot.pinnedURLString ?? tabSnapshot.urlString)
                    : nil,
                placement: placement,
                pinnedFolderID: tabSnapshot.pinnedFolderID,
                lastActivityAt: lastActivityDate(from: tabSnapshot) ?? dateProvider()
            ))
        }
        // The driver returns the logical identity immediately. Its later created
        // callback is a placeholder notification, not CEF readiness. Restored
        // state must be complete before user actions or remote snapshots arrive.
        finishSessionRestoreIfNeeded()
        return true
    }

    private func restoreSidebarWidthIfNeeded() {
        guard isPersistenceEnabled else {
            return
        }

        guard let storedSidebarWidth = sessionPreferencesStore.loadSidebarWidth(
            minimum: Self.minSidebarWidth,
            maximum: Self.maxSidebarWidth
        ) else {
            return
        }

        sidebarWidth = storedSidebarWidth
    }

    private func finishSessionRestoreIfNeeded() {
        guard isRestoringSession else {
            return
        }

        removeInvalidPinnedTabFolderAssignments()
        removeEmptyPinnedTabFolders()
        restoreSelectedTabsForSpaces()
        selectActiveTabForSelectedSpace()

        pendingRestoredSelectedTabIndex = nil
        pendingRestoredSpaces.removeAll()
        isRestoringSession = false
        updateWindowTitle()

        guard !drainDeferredRemoteSyncSnapshot() else { return }
        persistCurrentSessionIfAllowed()
        archiveExpiredTemporaryTabs()
    }

    private func syncMoveIntent(forTabIDs tabIDs: Set<String>) -> BrowserSyncMoveIntent? {
        let syncIDs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.syncID) })
        let orderedIDs = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
            .orderedTabIDs()
            .filter { tabIDs.contains($0) }
            .compactMap { syncIDs[$0] }
        return orderedIDs.isEmpty ? nil : BrowserSyncMoveIntent(tabIDs: orderedIDs)
    }

    private func persistCurrentSessionIfAllowed(syncMove: BrowserSyncMoveIntent? = nil) {
        guard isContextReady, isPersistenceEnabled, !isRestoringSession, !isReconcilingRemoteProjection else {
            return
        }

        let snapshot: BrowserTabSessionSnapshot
        if isApplyingRemoteSync {
            snapshot = snapshotPreservingPendingRemoteCreations()
            remoteProjectionSnapshot = snapshot
            hasLocalChangesDuringRemoteProjection = true
        } else {
            snapshot = currentSessionSnapshot()
        }
        _ = persistSessionWrite(
            .init(snapshot: snapshot, origin: .local(syncMove: syncMove)),
            schedulesPush: !isApplyingRemoteSync
        )
    }

    @discardableResult private func persistSessionWrite(_ write: BrowserSessionWrite, schedulesPush: Bool) -> Bool {
        isSessionClosurePrepared = false
        guard isPersistenceEnabled, !hasDiscardedSessionForClosure, !sessionWriteBuffer.isTerminal else { return false }
        if !sessionWriteBuffer.writes.isEmpty {
            guard sessionWriteBuffer.append(write) else {
                publishSessionPersistenceFailure()
                return false
            }
            return commitSessionWrites(sessionWriteBuffer.writes, schedulesPush: schedulesPush)
        }
        return commitSessionWrites([write], schedulesPush: schedulesPush)
    }

    @discardableResult private func commitSessionWrites(_ writes: [BrowserSessionWrite], schedulesPush: Bool) -> Bool {
        guard !writes.isEmpty, !sessionWriteBuffer.isTerminal, !hasDiscardedSessionForClosure else { return false }
        let wasBlocked = hasUncommittedSessionWrites
        do {
            try sessionSnapshotStore.writeSessionBatch(writes)
        } catch {
            if sessionWriteBuffer.writes.isEmpty {
                for write in writes where !sessionWriteBuffer.isTerminal {
                    sessionWriteBuffer.append(write)
                }
            }
            sessionWriteBuffer.recordFailure(error)
            publishSessionPersistenceFailure()
            return false
        }
        sessionWriteBuffer.clearAfterSuccess()
        sessionPersistenceFailure = nil
        if wasBlocked {
            deferredRemoteSyncSnapshot = nil
            syncCoordinator?.setLocalPersistenceBlocked(false)
            syncCoordinator?.schedulePull()
        }
        // Preferences remain a separate best-effort store. They are only written
        // after the snapshot/outbox commits; this does not make them atomic with it.
        sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
        let selectedSyncID = selectedTab?.syncID
        if let snapshot = writes.last?.snapshot {
            sessionPreferencesStore.saveSelectedTabIndex(snapshot.tabs.firstIndex { $0.id == selectedSyncID })
            if schedulesPush, !isApplyingRemoteSync {
                syncCoordinator?.schedulePush(snapshot: snapshot)
            }
        }
        return true
    }

    private func publishSessionPersistenceFailure() {
        sessionPersistenceFailure = sessionWriteBuffer.failure
        deferredRemoteSyncSnapshot = nil
        syncCoordinator?.setLocalPersistenceBlocked(true)
    }

    private func snapshotPreservingPendingRemoteCreations() -> BrowserTabSessionSnapshot {
        let current = currentSessionSnapshot()
        guard let remoteProjectionSnapshot else { return current }
        var mergedTabs = current.tabs
        let pendingIDs = Set(pendingRemoteTabCreations.values.compactMap(\.snapshot.id))
        // Place pending creations before their next surviving remote sibling.
        // Existing tabs keep the user's current relative order, including moves
        // and deletions performed while the engine creates remote tabs.
        for (index, tab) in remoteProjectionSnapshot.tabs.enumerated().reversed() {
            guard let id = tab.id, pendingIDs.contains(id) else { continue }
            let followingIDs = remoteProjectionSnapshot.tabs.dropFirst(index + 1).compactMap(\.id)
            let insertion = followingIDs.lazy
                .compactMap { nextID in
                    mergedTabs.firstIndex { $0.id == nextID }
                }
                .first ?? mergedTabs.count
            mergedTabs.insert(tab, at: insertion)
        }
        let spaceSnapshots = current.spaces?.map { space in
            let selectedID = spaces.first { $0.id == space.id }?.selectedTabID
            let selectedSyncID = tabs.first { $0.id == selectedID }?.syncID
            let inSpace = mergedTabs.filter { $0.spaceID == space.id }
            let visible = inSpace.filter { $0.placement == .spacePinned }
                + inSpace.filter { $0.placement == .temporary }
            return BrowserSpaceSessionSnapshot(
                id: space.id, title: space.title, systemImageName: space.systemImageName,
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                selectedTabIndex: visible.firstIndex { $0.id == selectedSyncID }
            )
        }
        return BrowserTabSessionSnapshot(
            spaces: spaceSnapshots,
            pinnedTabFolders: current.pinnedTabFolders,
            tabs: mergedTabs
        )
    }

    private func currentSessionSnapshot() -> BrowserTabSessionSnapshot {
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
            pinnedTabFolders: pinnedTabFolders.map { folder in
                BrowserPinnedTabFolderSessionSnapshot(
                    id: folder.id,
                    spaceID: folder.spaceID,
                    parentFolderID: folder.parentFolderID,
                    title: folder.title,
                    systemImageName: folder.systemImageName,
                    isExpanded: folder.isExpanded
                )
            },
            tabs: tabs.map { tab in
                BrowserTabSessionSnapshotTab(
                    id: tab.syncID,
                    urlString: tab.urlString,
                    pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride,
                    placement: tab.placement,
                    spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID,
                    lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970
                )
            }
        )
    }

    private func updateWindowTitle() {
        let title = tabs.first(where: { $0.id == selectedTabID })?.displayTitle ?? BrowserStrings.applicationName
        windowTitleHandler(title)
    }

    private func createTab(
        withURLString urlString: String,
        registersUndo: Bool = true,
        undoActionName: String = BrowserStrings.menuNewTab
    ) {
        guard canCreateTab else {
            return
        }

        ensureDefaultSpace()
        guard let selectedSpaceID else {
            return
        }

        captureSelectedTabPreviewIfNeeded()
        let resolvedURLString = resolvedBrowserURLString(urlString)
        let tabID = tabDriver.createTab(withURLString: resolvedURLString, makeActive: true)
        let context = PendingCreatedTabContext(
            spaceID: selectedSpaceID,
            placement: .temporary,
            undoSnapshot: nil
        )
        applyCreatedTabContext(context, toTabID: tabID)
        if registersUndo, canRegisterTabUndo {
            let creationUndoReference = TabCreationUndoReference(tabID: tabID)
            tabCreationUndoReferences[tabID] = creationUndoReference
            registerTabCreationUndo(creationUndoReference, actionName: undoActionName)
        }
        selectedTabID = tabID
        setSelectedTabID(tabID, forSpaceID: selectedSpaceID)
        findResultMatchCount = nil
        updateWindowTitle()
    }

    private func openResolvedSelectionInNewTab(_ resolvedURLString: String) {
        createTab(withURLString: resolvedURLString)
    }

    private func openCommandBarTabSelection(tabIDs: [String]) {
        let candidateTabs = tabIDs.compactMap { tabID in
            tabs.first { $0.id == tabID }
        }
        let tab = candidateTabs.first { candidate in
            candidate.placement == .spacePinned && candidate.pinnedFolderID != nil
        } ?? candidateTabs.first

        guard let tab else {
            return
        }

        selectTab(id: tab.id)
    }

    private func navigateSelectedTabOrOpenNewTab(toURLString urlString: String) {
        guard canCreateTab else {
            return
        }

        if selectedTabID == nil {
            createTab(withURLString: urlString)
            return
        }

        tabDriver.navigateActiveTab(toURLString: resolvedBrowserURLString(urlString))
    }

    private func navigateSelectedTab(toURLString urlString: String) {
        guard canCreateTab, selectedTabID != nil else {
            return
        }

        tabDriver.navigateActiveTab(toURLString: resolvedBrowserURLString(urlString))
    }

    private func localCommandSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, maximumCount > 0 else {
            return []
        }

        var suggestions = [BrowserCommandSuggestion]()
        suggestions.append(
            contentsOf: commandActionSuggestions(
                for: trimmedQuery,
                maximumCount: maximumCount
            )
        )

        let remainingAfterCommands = maximumCount - suggestions.count
        if remainingAfterCommands > 0 {
            suggestions.append(
                contentsOf: internalPageSuggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterCommands
                )
            )
        }

        let remainingAfterInternalPages = maximumCount - suggestions.count
        if remainingAfterInternalPages > 0 {
            suggestions.append(
                contentsOf: openTabSuggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterInternalPages
                )
            )
        }

        let remainingAfterTabs = maximumCount - suggestions.count
        if remainingAfterTabs > 0 {
            suggestions.append(
                contentsOf: bookmarksModel.suggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterTabs
                )
            )
        }

        let remainingAfterBookmarks = maximumCount - suggestions.count
        if remainingAfterBookmarks > 0 {
            suggestions.append(
                contentsOf: historyStore.suggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterBookmarks
                )
            )
        }

        return Array(suggestions.prefix(maximumCount))
    }

    private func commandActionSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0 else {
            return []
        }

        let normalizedQuery = normalizedCommandSearchText(query)
        return BrowserCommandID.allCases
            .filter(isCommandBarActionAvailable)
            .filter { commandID in
                commandSearchText(for: commandID).contains(normalizedQuery)
            }
            .prefix(maximumCount)
            .map { commandID in
                let descriptor = shortcutStore.descriptor(for: commandID)
                return BrowserCommandSuggestion(
                    kind: .command,
                    displayText: commandDisplayText(for: commandID, descriptor: descriptor),
                    commandID: commandID,
                    shortcut: descriptor.shortcut.isAssigned ? descriptor.shortcut : nil
                )
            }
    }

    private func commandDisplayText(for commandID: BrowserCommandID, descriptor: BrowserCommandDescriptor) -> String {
        switch commandID {
        case .toggleBookmarksBar:
            userPreferencesStore.bookmarksBarVisible
                ? BrowserStrings.bookmarksHideBarAction
                : BrowserStrings.settingsShowBookmarksBar
        default:
            descriptor.menuTitle
        }
    }

    private func commandSearchText(for commandID: BrowserCommandID) -> String {
        let descriptor = shortcutStore.descriptor(for: commandID)
        return ([
            descriptor.menuTitle,
            descriptor.helpTitle,
            commandID.rawValue,
        ] + commandID.commandBarSearchAliases + descriptor.shortcut.commandBarSearchAliases)
            .map(normalizedCommandSearchText)
            .joined(separator: " ")
    }

    private func isCommandBarActionAvailable(_ commandID: BrowserCommandID) -> Bool {
        switch commandID {
        case .openSettings, .setAsDefaultBrowser:
            true
        case .newTab:
            canCreateTab
        case .newIncognitoWindow:
            !isShuttingDown
        case .openHistory:
            canCreateTab && !isShuttingDown
        case .toggleBookmark:
            selectedTab?.urlString.isEmpty == false
        case .archiveTab:
            canArchiveSelectedTab
        case .savePage:
            canSavePage
        case .printPage:
            canPrintPage
        case .copyLink:
            canCopySelectedTabLink
        case .findInPage:
            canPresentFindInPage
        case .findAndReplace, .jumpToSelection:
            false
        case .findNext, .findPrevious:
            canStepThroughFindMatches
        case .clearTemporaryTabs:
            canClearTemporaryTabs
        case .goBack:
            canGoBack
        case .goForward:
            canGoForward
        case .clearCacheAndRefresh, .clearCookiesAndRefresh, .forceReload, .reload:
            canReload
        case .toggleSidebar:
            true
        case .toggleBookmarksBar:
            true
        }
    }

    private func internalPageSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0 else {
            return []
        }

        let normalizedQuery = normalizedCommandSearchText(query)
        let pages = [
            (
                title: "Open Settings",
                detail: "tb://settings",
                aliases: ["settings", "chrome://settings", "arc://settings", "dia://settings"],
                urlString: "tb://settings/"
            ),
            (
                title: "Open Bookmarks",
                detail: "tb://bookmarks",
                aliases: ["bookmarks", "chrome://bookmarks", "arc://bookmarks", "dia://bookmarks"],
                urlString: "tb://bookmarks/"
            ),
            (
                title: "Open History",
                detail: "tb://history",
                aliases: ["history", "chrome://history", "arc://history", "dia://history"],
                urlString: "tb://history"
            ),
            (
                title: "Open Extensions",
                detail: "tb://extensions",
                aliases: ["extensions", "chrome://extensions", "arc://extensions", "dia://extensions"],
                urlString: "tb://extensions/"
            ),
            (
                title: "Open Passwords",
                detail: "tb://password-manager/passwords",
                aliases: [
                    "passwords",
                    "password manager",
                    "password-manager",
                    "chrome://password-manager/passwords",
                    "arc://password-manager/passwords",
                    "dia://password-manager/passwords",
                ],
                urlString: "tb://password-manager/passwords"
            ),
        ]

        return pages
            .filter { page in
                normalizedCommandSearchText(page.title).contains(normalizedQuery)
                    || normalizedCommandSearchText(page.detail).contains(normalizedQuery)
                    || page.aliases.contains { normalizedCommandSearchText($0).contains(normalizedQuery) }
            }
            .prefix(maximumCount)
            .map { page in
                BrowserCommandSuggestion(
                    kind: .url,
                    displayText: page.title,
                    detailText: page.detail,
                    resolvedURLString: page.urlString
                )
            }
    }

    private func openTabSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let normalizedQuery = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        return activeSpaceTabs
            .filter { tab in
                tab.id != selectedTabID
                    && (
                        normalizedCommandSearchText(tab.displayTitle).contains(normalizedQuery)
                            || normalizedCommandSearchText(tab.urlString).contains(normalizedQuery)
                    )
            }
            .prefix(maximumCount)
            .map { tab in
                BrowserCommandSuggestion(
                    kind: .openTab,
                    displayText: tab.displayTitle,
                    detailText: BrowserURLDisplayFormatter.displayString(for: tab.urlString),
                    resolvedURLString: tab.urlString,
                    tabIDs: [tab.id]
                )
            }
    }

    private func normalizedCommandSearchText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func resolvedBrowserURLString(_ urlString: String) -> String {
        BrowserInternalURLNormalizer.canonicalURLString(for: urlString) ?? urlString
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

    private func applyCreatedTabContext(_ context: PendingCreatedTabContext, toTabID tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            pendingCreatedTabContexts[tabID] = context
            return
        }

        guard let undoSnapshot = context.undoSnapshot else {
            tabs[index].spaceID = context.spaceID
            tabs[index].placement = context.placement
            tabs[index].pinnedURLString = pinnedURLString(for: tabs[index], movingTo: context.placement)
            return
        }

        tabs[index] = restoredTab(from: undoSnapshot, id: tabID)
        moveTab(id: tabID, toGlobalIndex: undoSnapshot.insertionIndex)
        restoreCreationUndoReference(from: undoSnapshot, toTabID: tabID)
        restoreSelection(from: undoSnapshot, toTabID: tabID)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func restoredTab(from undoSnapshot: TabUndoSnapshot, id: String) -> Tab {
        Tab(
            id: id,
            // Explicit undo creates a new incarnation. Reusing the deleted
            // identity would let stale offline changes undo a server tombstone.
            syncID: tabSyncIDProvider(),
            spaceID: undoSnapshot.tab.spaceID,
            title: undoSnapshot.tab.title,
            userTitleOverride: undoSnapshot.tab.userTitleOverride,
            urlString: undoSnapshot.tab.urlString,
            pinnedURLString: undoSnapshot.tab.pinnedURLString,
            faviconURLString: undoSnapshot.tab.faviconURLString,
            placement: undoSnapshot.tab.placement,
            pinnedFolderID: undoSnapshot.tab.pinnedFolderID,
            lastActivityAt: undoSnapshot.tab.lastActivityAt
        )
    }

    private func reidentifiedAppTab(
        from tab: Tab,
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        lastActivityAt: Date? = nil
    ) -> Tab {
        Tab(
            id: id,
            syncID: tab.syncID,
            spaceID: tab.spaceID,
            title: title ?? tab.title,
            userTitleOverride: tab.userTitleOverride,
            urlString: urlString ?? tab.urlString,
            pinnedURLString: nil,
            faviconURLString: tab.faviconURLString,
            placement: .app,
            pinnedFolderID: nil,
            lastActivityAt: lastActivityAt ?? tab.lastActivityAt
        )
    }

    private func reidentifiedPinnedTab(
        from tab: Tab,
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        lastActivityAt: Date? = nil
    ) -> Tab {
        Tab(
            id: id,
            syncID: tab.syncID,
            spaceID: tab.spaceID,
            title: title ?? tab.title,
            userTitleOverride: tab.userTitleOverride,
            urlString: urlString ?? tab.urlString,
            pinnedURLString: effectivePinnedURLString(forPinnedTab: tab),
            faviconURLString: tab.faviconURLString,
            placement: .spacePinned,
            pinnedFolderID: tab.pinnedFolderID,
            lastActivityAt: lastActivityAt ?? tab.lastActivityAt
        )
    }

    private func reopenClosedAppTab(id: String) {
        guard
            canCreateTab,
            let index = tabs.firstIndex(where: { $0.id == id }),
            tabs[index].placement == .app,
            closedAppTabIDs.contains(id)
        else {
            return
        }

        let tab = tabs[index]
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()

        let newTabID = tabDriver.createTab(
            withURLString: resolvedBrowserURLString(tab.urlString),
            makeActive: true
        )
        pendingReopenedAppTabIDs[newTabID] = id
        tabs[index] = reidentifiedAppTab(from: tab, id: newTabID, lastActivityAt: dateProvider())
        closedAppTabIDs.remove(id)
        replaceTabRuntimeReferences(oldID: id, newID: newTabID, spaceID: tab.spaceID)

        selectedSpaceID = tab.spaceID
        selectedTabID = newTabID
        findResultMatchCount = nil
        setSelectedTabID(newTabID, forSpaceID: tab.spaceID)
        recordSelectedTab(newTabID)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func reopenClosedPinnedTab(id: String) {
        guard
            canCreateTab,
            let index = tabs.firstIndex(where: { $0.id == id }),
            tabs[index].placement == .spacePinned,
            closedPinnedTabIDs.contains(id),
            let pinnedURLString = effectivePinnedURLString(forPinnedTab: tabs[index])
        else {
            return
        }

        let tab = tabs[index]
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()

        let newTabID = tabDriver.createTab(
            withURLString: resolvedBrowserURLString(pinnedURLString),
            makeActive: true
        )
        pendingReopenedPinnedTabIDs[newTabID] = id
        tabs[index] = reidentifiedPinnedTab(
            from: tab,
            id: newTabID,
            urlString: pinnedURLString,
            lastActivityAt: dateProvider()
        )
        closedPinnedTabIDs.remove(id)
        replaceTabRuntimeReferences(oldID: id, newID: newTabID, spaceID: tab.spaceID)

        selectedSpaceID = tab.spaceID
        selectedTabID = newTabID
        findResultMatchCount = nil
        setSelectedTabID(newTabID, forSpaceID: tab.spaceID)
        recordSelectedTab(newTabID)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func handleReopenedPinnedTabCreated(
        id: String,
        previousID: String,
        title: String,
        urlString: String
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id || $0.id == previousID }) else {
            return false
        }

        let tab = tabs[index]
        tabs[index] = reidentifiedPinnedTab(
            from: tab,
            id: id,
            title: title,
            urlString: urlString,
            lastActivityAt: tab.lastActivityAt
        )
        closedPinnedTabIDs.remove(previousID)
        closedPinnedTabIDs.remove(id)
        replaceTabRuntimeReferences(oldID: previousID, newID: id, spaceID: tab.spaceID)

        if selectedTabID == id {
            recordSelectedTab(id)
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    private func handleReopenedAppTabCreated(
        id: String,
        previousID: String,
        title: String,
        urlString: String
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id || $0.id == previousID }) else {
            return false
        }

        let tab = tabs[index]
        tabs[index] = reidentifiedAppTab(
            from: tab,
            id: id,
            title: title,
            urlString: urlString,
            lastActivityAt: tab.lastActivityAt
        )
        closedAppTabIDs.remove(previousID)
        closedAppTabIDs.remove(id)
        replaceTabRuntimeReferences(oldID: previousID, newID: id, spaceID: tab.spaceID)

        if selectedTabID == id {
            recordSelectedTab(id)
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    private func replaceTabRuntimeReferences(oldID: String, newID: String, spaceID: String) {
        if selectedTabID == oldID {
            selectedTabID = newID
        }

        for index in spaces.indices where spaces[index].selectedTabID == oldID {
            spaces[index].selectedTabID = newID
        }
        setSelectedTabID(newID, forSpaceID: spaceID)

        recentlySelectedTabIDs = recentlySelectedTabIDs.map { $0 == oldID ? newID : $0 }
        if let previewImage = tabPreviewImagesByID.removeValue(forKey: oldID) {
            tabPreviewImagesByID[newID] = previewImage
        }
        if let creationUndoReference = tabCreationUndoReferences.removeValue(forKey: oldID) {
            creationUndoReference.currentTabID = newID
            tabCreationUndoReferences[newID] = creationUndoReference
        }
        clearTabSwitcherState()
    }

    private func moveTab(id tabID: String, toGlobalIndex insertionIndex: Int) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tab = tabs.remove(at: currentIndex)
        let targetIndex = min(max(insertionIndex, 0), tabs.count)
        tabs.insert(tab, at: targetIndex)
    }

    private func restoreSelection(from undoSnapshot: TabUndoSnapshot, toTabID tabID: String) {
        let tabSpaceID = undoSnapshot.tab.spaceID
        if undoSnapshot.wasSelectedInSpace {
            setSelectedTabID(tabID, forSpaceID: tabSpaceID)
        }

        guard undoSnapshot.wasSelectedTab || selectedTabID == nil else {
            return
        }

        selectedSpaceID = tabSpaceID
        selectedTabID = tabID
        findResultMatchCount = nil
        setSelectedTabID(tabID, forSpaceID: tabSpaceID)
        recordSelectedTab(tabID)
    }

    private func restoreCreationUndoReference(from undoSnapshot: TabUndoSnapshot, toTabID tabID: String) {
        guard let creationUndoReference = undoSnapshot.creationUndoReference else {
            return
        }

        creationUndoReference.currentTabID = tabID
        tabCreationUndoReferences[tabID] = creationUndoReference
    }

    private func tabUndoSnapshot(forClosingTabAt closingIndex: Int) -> TabUndoSnapshot? {
        guard tabs.indices.contains(closingIndex) else {
            return nil
        }

        let tab = tabs[closingIndex]
        return TabUndoSnapshot(
            tab: tab,
            insertionIndex: closingIndex,
            wasSelectedTab: selectedTabID == tab.id,
            wasSelectedInSpace: spaces.first { $0.id == tab.spaceID }?.selectedTabID == tab.id,
            creationUndoReference: tabCreationUndoReferences[tab.id]
        )
    }

    private func registerTabUndo(actionName: String, registration: () -> Void) {
        guard canRegisterTabUndo else {
            return
        }

        let managesGroup = undoManager.groupingLevel == 0
        if managesGroup {
            undoManager.beginUndoGrouping()
        }
        registration()
        undoManager.setActionName(actionName)
        if managesGroup {
            undoManager.endUndoGrouping()
        }
    }

    private func registerTabCreationUndo(
        _ creationUndoReference: TabCreationUndoReference,
        actionName: String
    ) {
        registerTabUndo(actionName: actionName) {
            undoManager.registerUndo(withTarget: self) { target in
                target.undoCreatedTab(creationUndoReference, actionName: actionName)
            }
        }
    }

    private func registerTabArchiveUndo(_ undoSnapshot: TabUndoSnapshot, actionName: String) {
        registerTabUndo(actionName: actionName) {
            undoManager.registerUndo(withTarget: self) { target in
                target.undoArchivedTab(undoSnapshot, actionName: actionName)
            }
        }
    }

    private func undoCreatedTab(
        _ creationUndoReference: TabCreationUndoReference,
        actionName: String
    ) {
        guard
            let tabID = creationUndoReference.currentTabID,
            let undoSnapshot = closeTabForUndoRedo(id: tabID)
        else {
            return
        }

        registerTabUndo(actionName: actionName) {
            undoManager.registerUndo(withTarget: self) { target in
                target.redoCreatedTab(from: undoSnapshot, actionName: actionName)
            }
        }
    }

    private func redoCreatedTab(from undoSnapshot: TabUndoSnapshot, actionName: String) {
        guard let tabID = restoreTab(from: undoSnapshot) else {
            return
        }

        let creationUndoReference = undoSnapshot.creationUndoReference ?? TabCreationUndoReference(tabID: tabID)
        creationUndoReference.currentTabID = tabID
        tabCreationUndoReferences[tabID] = creationUndoReference
        registerTabCreationUndo(creationUndoReference, actionName: actionName)
    }

    private func undoArchivedTab(_ undoSnapshot: TabUndoSnapshot, actionName: String) {
        guard let tabID = restoreTab(from: undoSnapshot) else {
            return
        }

        registerTabUndo(actionName: actionName) {
            undoManager.registerUndo(withTarget: self) { target in
                target.redoArchivedTab(id: tabID, actionName: actionName)
            }
        }
    }

    private func redoArchivedTab(id tabID: String, actionName: String) {
        guard let undoSnapshot = closeTabForUndoRedo(id: tabID) else {
            return
        }

        registerTabArchiveUndo(undoSnapshot, actionName: actionName)
    }

    private func closeTabForUndoRedo(id tabID: String) -> TabUndoSnapshot? {
        guard
            let closingIndex = tabs.firstIndex(where: { $0.id == tabID }),
            !closingTabIDs.contains(tabID),
            let undoSnapshot = tabUndoSnapshot(forClosingTabAt: closingIndex)
        else {
            return nil
        }

        guard closeTab(id: tabID, registersUndo: false) else {
            return nil
        }

        return undoSnapshot
    }

    private func restoreTab(from undoSnapshot: TabUndoSnapshot) -> String? {
        guard canCreateTab else {
            return nil
        }

        ensureDefaultSpace()
        let context = PendingCreatedTabContext(
            spaceID: undoSnapshot.tab.spaceID,
            placement: undoSnapshot.tab.placement,
            undoSnapshot: undoSnapshot
        )
        let tabID = tabDriver.createTab(
            withURLString: undoSnapshot.tab.urlString,
            makeActive: undoSnapshot.wasSelectedTab
        )
        applyCreatedTabContext(context, toTabID: tabID)
        restoreCreationUndoReference(from: undoSnapshot, toTabID: tabID)
        if undoSnapshot.wasSelectedTab {
            selectedSpaceID = undoSnapshot.tab.spaceID
            selectedTabID = tabID
            setSelectedTabID(tabID, forSpaceID: undoSnapshot.tab.spaceID)
            findResultMatchCount = nil
        }
        updateWindowTitle()
        return tabID
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

    func normalizedPinnedURLString(from urlString: String?) -> String? {
        guard let urlString else {
            return nil
        }

        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return nil
        }

        if let canonicalInternalURLString = BrowserInternalURLNormalizer.canonicalURLString(for: trimmedURLString) {
            return canonicalInternalURLString
        }

        if
            let components = URLComponents(string: trimmedURLString),
            components.scheme?.isEmpty == false,
            let url = components.url
        {
            return url.absoluteString
        }

        guard let resolution = navigationResolver.resolve(trimmedURLString), resolution.kind == .url else {
            return nil
        }

        return resolution.resolvedURLString
    }

    func effectivePinnedURLString(forPinnedTab tab: Tab) -> String? {
        guard tab.placement == .spacePinned else {
            return nil
        }

        return normalizedPinnedURLString(from: tab.pinnedURLString ?? tab.urlString)
    }

    func pinnedURLString(for tab: Tab, movingTo placement: BrowserTabPlacement) -> String? {
        guard placement == .spacePinned else {
            return nil
        }

        if tab.placement == .spacePinned, let pinnedURLString = normalizedPinnedURLString(from: tab.pinnedURLString) {
            return pinnedURLString
        }

        return normalizedPinnedURLString(from: tab.urlString)
    }

    func areEquivalentPinnedURLStrings(_ lhs: String, _ rhs: String) -> Bool {
        comparablePinnedURLString(lhs) == comparablePinnedURLString(rhs)
    }

    func comparablePinnedURLString(_ urlString: String) -> String {
        let resolvedURLString = resolvedBrowserURLString(urlString)
        guard var components = URLComponents(string: resolvedURLString) else {
            return resolvedURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }
        return components.url?.absoluteString ?? resolvedURLString.lowercased()
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

    func fallbackTabID(afterClosingDormantTab closingTab: Tab, excluding excludedTabIDs: Set<String>) -> String? {
        let visibleTabs = sidebarTabs(forSpaceID: closingTab.spaceID)
            .filter { !excludedTabIDs.contains($0.id) && !closedPinnedTabIDs.contains($0.id) }
        let previousSidebarOrder = sidebarTabs(forSpaceID: closingTab.spaceID, including: closingTab)
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
        guard let host = BrowserInternalURLNormalizer.host(for: urlString) else {
            return nil
        }

        switch host {
        case BrowserInternalURLNormalizer.settingsHost:
            return .settings
        case BrowserInternalURLNormalizer.extensionsHost:
            return .extensions
        case BrowserInternalURLNormalizer.historyHost:
            return .history
        case BrowserInternalURLNormalizer.passwordManagerHost:
            return .passwordManager
        case BrowserInternalURLNormalizer.bookmarksHost:
            return .bookmarks
        default:
            return .chromiumWebUI
        }
    }

    func handleCreatedTab(id: String, title: String, urlString: String, isActive: Bool) {
        if handleRemoteCreatedTab(id: id, title: title, urlString: urlString) {
            return
        }
        if restoredTabCreationIDs.contains(id) {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else {
                // Keep the identity until model teardown so even duplicate late
                // callbacks cannot recreate a tab deleted during startup. The
                // placeholder callback does not create an engine; its earlier
                // close already canceled the controller's pending record.
                return
            }
            if tabs[index].title.isEmpty, tabs[index].urlString == urlString {
                tabs[index].title = title
                updateWindowTitle()
            }
            return
        }
        if
            let previousID = pendingReopenedPinnedTabIDs.removeValue(forKey: id),
            handleReopenedPinnedTabCreated(id: id, previousID: previousID, title: title, urlString: urlString)
        {
            return
        }

        if
            let previousID = pendingReopenedAppTabIDs.removeValue(forKey: id),
            handleReopenedAppTabCreated(id: id, previousID: previousID, title: title, urlString: urlString)
        {
            return
        }

        guard !tabs.contains(where: { $0.id == id }) else { return }
        let pendingContext = pendingCreatedTabContexts.removeValue(forKey: id)
        let undoSnapshot = pendingContext?.undoSnapshot
        let fallbackSpaceID = selectedSpaceID ?? spaces.first?.id ?? Self.defaultSpaceID
        let tabSpaceID = undoSnapshot?.tab.spaceID ?? pendingContext?.spaceID ?? fallbackSpaceID
        if spaces.isEmpty {
            spaces = [makeDefaultSpace()]
            selectedSpaceID = tabSpaceID
        }
        let restoredPlacement = undoSnapshot?.tab.placement ?? pendingContext?
            .placement ?? .temporary
        let restoredPinnedURLString = undoSnapshot?.tab.pinnedURLString
        let tabPinnedURLString = restoredPlacement == .spacePinned
            ? normalizedPinnedURLString(from: restoredPinnedURLString ?? urlString)
            : nil
        tabs.append(
            Tab(
                id: id,
                syncID: undoSnapshot?.tab.syncID ?? tabSyncIDProvider(),
                spaceID: tabSpaceID,
                title: undoSnapshot?.tab.title ?? title,
                userTitleOverride: undoSnapshot?.tab.userTitleOverride,
                urlString: undoSnapshot?.tab.urlString ?? urlString,
                pinnedURLString: tabPinnedURLString,
                faviconURLString: undoSnapshot?.tab.faviconURLString,
                placement: restoredPlacement,
                pinnedFolderID: undoSnapshot?.tab.pinnedFolderID,
                lastActivityAt: undoSnapshot?.tab.lastActivityAt ?? dateProvider()
            )
        )

        if let pendingContext {
            applyCreatedTabContext(pendingContext, toTabID: id)
        } else {
            if isActive || selectedTabID == nil {
                selectedTabID = id
                findResultMatchCount = nil
            }
            if selectedTabID == id {
                setSelectedTabID(id, forSpaceID: tabSpaceID)
            }
        }

        if selectedTabID == id {
            recordSelectedTab(id)
        }

        if let tab = tabs.first(where: { $0.id == id }) {
            BrowserTelemetry.captureUsage(.tabCreated, properties: telemetryProperties(for: tab))
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

    func handleDownloadUpdate(_ update: BrowserDownloadUpdate) {
        downloadsModel.apply(update)
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
            if id == selectedTabID {
                invalidateSelectedTabWebAppInstallMetadata()
            }
        }

        if let faviconURLString {
            tabs[index].faviconURLString = faviconURLString
        }

        updateWindowTitle()

        if didChangePersistentURL {
            BrowserTelemetry.captureUsage(.tabNavigated, properties: telemetryProperties(for: tabs[index]))
            persistCurrentSessionIfAllowed()
        }
    }

    func handleClosedTab(id: String) {
        if discardedRemoteTabCreationIDs.contains(id) {
            return
        }
        closingTabIDs.remove(id)
        let closedTab = tabs.first { $0.id == id }
        // An already-removed or unknown identity has no model change to save.
        // Duplicate close receipts must not echo a finished remote projection.
        if closedTab == nil {
            return
        }
        if closedAppTabIDs.contains(id), closedTab?.placement == .app {
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
            return
        }

        if closedPinnedTabIDs.contains(id), closedTab?.placement == .spacePinned {
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
            return
        }

        if closedTab != nil {
            tabs.removeAll { $0.id == id }
        }
        closedAppTabIDs.remove(id)
        closedPinnedTabIDs.remove(id)
        removeTabFromSwitcherTracking(id)
        if let closedTab {
            clearSelectedTab(id, forSpaceID: closedTab.spaceID)
        }
        removeEmptyPinnedTabFolders()

        if selectedTabID == id {
            selectedTabID = fallbackTabID(afterClosingTab: closedTab) ?? sidebarTabsForSelectedSpace().first?.id
            if let selectedTabID {
                tabDriver.selectTab(withID: selectedTabID)
                scheduleSelectedTabWebAppManifestLoad()
                setSelectedTabID(selectedTabID, forSpaceID: selectedSpaceID)
                recordSelectedTab(selectedTabID)
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

    func handleTabCreationStateChange(id: String, state: BrowserTabCreationState) {
        guard !isShuttingDown, !closingTabIDs.contains(id),
              !closedAppTabIDs.contains(id), !closedPinnedTabIDs.contains(id),
              let index = tabs.firstIndex(where: { $0.id == id })
        else { return }

        switch (tabs[index].creationState, state) {
        case (.creating, .failed), (.creating, .ready), (.failed, .creating):
            tabs[index].creationState = state
        default:
            // Duplicates and obsolete outcomes cannot regress an attached page
            // or revive a refused attempt. Only explicit Retry starts another.
            return
        }
        if state == .failed {
            tabs[index].isLoading = false
            tabs[index].canGoBack = false
            tabs[index].canGoForward = false
        }
    }

    func handleLoadingStateChange(id: String, isLoading: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        tabs[index].isLoading = isLoading
        guard id == selectedTabID else {
            return
        }

        if isLoading {
            invalidateSelectedTabWebAppInstallMetadata()
        } else {
            scheduleSelectedTabWebAppManifestLoad()
        }
    }

    private func invalidateSelectedTabWebAppInstallMetadata() {
        webAppManifestLoadTask?.cancel()
        webAppManifestLoadTask = nil
        selectedTabWebAppInstallMetadata = nil
    }

    private func scheduleSelectedTabWebAppManifestLoad() {
        invalidateSelectedTabWebAppInstallMetadata()
        guard
            isContextReady,
            !windowMode.isIncognito,
            !windowMode.isWebApp,
            let tab = selectedTab,
            !tab.isLoading,
            let pageURL = tab.pageURL
        else {
            return
        }

        let tabID = tab.id
        let fallbackTitle = tab.displayTitle
        let fallbackIconURL = tab.faviconURL
        webAppManifestLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            let payloadJSON = await tabDriver.requestActiveTabWebAppManifest()
            guard !Task.isCancelled else {
                return
            }

            let metadata = BrowserWebAppManifestParser.installMetadata(
                payloadJSON: payloadJSON,
                fallbackPageURL: pageURL,
                fallbackTitle: fallbackTitle,
                fallbackIconURL: fallbackIconURL
            )
            guard
                metadata.manifestURL != nil,
                selectedTabID == tabID,
                selectedTab?.pageURL == pageURL
            else {
                return
            }

            selectedTabWebAppInstallMetadata = metadata
        }
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

    func makeDefaultSpace(id: String = BrowserChromeModel.defaultSpaceID) -> Space {
        Space(
            id: id,
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

    func restoredPinnedTabFolders(from snapshot: BrowserTabSessionSnapshot) -> [PinnedTabFolder] {
        guard let folderSnapshots = snapshot.pinnedTabFolders, !folderSnapshots.isEmpty else {
            return []
        }

        let validSpaceIDs = Set(spaces.map(\.id))
        let validFolderSpaceIDsByID = folderSnapshots.reduce(into: [String: String]()) { result, snapshot in
            result[snapshot.id] = result[snapshot.id] ?? snapshot.spaceID
        }
        var seenIDs = Set<String>()
        return folderSnapshots.compactMap { snapshot -> PinnedTabFolder? in
            let id = snapshot.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenIDs.contains(id), validSpaceIDs.contains(snapshot.spaceID) else {
                return nil
            }

            let parentFolderID: String? =
                if let snapshotParentFolderID = snapshot.parentFolderID,
                snapshotParentFolderID != id,
                validFolderSpaceIDsByID[snapshotParentFolderID] == snapshot.spaceID {
                    snapshotParentFolderID
                } else {
                    nil
                }
            seenIDs.insert(id)
            return PinnedTabFolder(
                id: id,
                spaceID: snapshot.spaceID,
                parentFolderID: parentFolderID,
                title: sanitizedPinnedTabFolderTitle(from: snapshot.title)
                    ?? BrowserStrings.pinnedTabFolderDefaultTitle,
                systemImageName: snapshot.systemImageName,
                isExpanded: snapshot.isExpanded
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
            captureSelectedTabPreviewIfNeeded()
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

        if selectedTabID != fallbackTabID {
            captureSelectedTabPreviewIfNeeded()
        }
        selectedTabID = fallbackTabID
        findResultMatchCount = nil

        if let fallbackTabID {
            setSelectedTabID(fallbackTabID, forSpaceID: selectedSpaceID)
            tabDriver.selectTab(withID: fallbackTabID)
            recordSelectedTab(fallbackTabID)
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

    func fallbackSpaceID(afterDeletingSpaceAt index: Int) -> String? {
        guard spaces.count > 1 else {
            return nil
        }

        let fallbackIndex = index < spaces.count - 1 ? index + 1 : index - 1
        return spaces[fallbackIndex].id
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
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil
    ) -> [Tab]? {
        guard supportsAppTabs || placement != .app else {
            return nil
        }

        guard
            let movingTab = tabs.first(where: { $0.id == movingTabID })
        else {
            return nil
        }

        if targetSpaceID == nil, movingTab.placement != .app, movingTab.spaceID != selectedSpaceID {
            return nil
        }

        let targetFolder = targetPinnedFolderID.flatMap { folderID in
            pinnedTabFolders.first { $0.id == folderID }
        }
        guard targetPinnedFolderID == nil || targetFolder != nil else {
            return nil
        }

        let resolvedTargetSpaceID = targetFolder?.spaceID ?? targetSpaceID ?? selectedSpaceID ?? movingTab.spaceID
        guard placement == .app || spaces.contains(where: { $0.id == resolvedTargetSpaceID }) else {
            return nil
        }
        guard targetFolder == nil || placement == .spacePinned else {
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
        updatedTab.pinnedURLString = pinnedURLString(for: movingTab, movingTo: placement)
        updatedTab.pinnedFolderID = placement == .spacePinned ? targetPinnedFolderID : nil

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
            let destinationIndex =
                if let targetPinnedFolderID {
                    pinnedFolderChildInsertionIndex(
                        requestedSectionIndex,
                        in: updatedSpacePinnedTabs,
                        folderID: targetPinnedFolderID
                    )
                } else {
                    adjustedSectionIndex(
                        requestedSectionIndex,
                        movingWithinTargetSection: movingWithinTargetSection,
                        sourceSectionIndex: sourceSectionIndex,
                        sectionCount: updatedSpacePinnedTabs.count
                    )
                }
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

    func reorderedTabs(
        movingTabIDs tabIDs: Set<String>,
        toPlacement placement: BrowserTabPlacement,
        requestedSectionIndex: Int,
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil
    ) -> [Tab]? {
        guard placement == .spacePinned else {
            return nil
        }

        let movingTabIDs = Set(tabIDs)
        let movingTabs = tabs.filter { movingTabIDs.contains($0.id) }
        guard movingTabs.count == movingTabIDs.count, movingTabs.count > 1 else {
            return nil
        }

        if targetSpaceID == nil,
           movingTabs.contains(where: { $0.placement != .app && $0.spaceID != selectedSpaceID })
        {
            return nil
        }

        let targetFolder = targetPinnedFolderID.flatMap { folderID in
            pinnedTabFolders.first { $0.id == folderID }
        }
        guard targetPinnedFolderID == nil || targetFolder != nil else {
            return nil
        }

        let resolvedTargetSpaceID = targetFolder?.spaceID ?? targetSpaceID ?? selectedSpaceID ?? movingTabs[0].spaceID
        guard spaces.contains(where: { $0.id == resolvedTargetSpaceID }) else {
            return nil
        }
        guard movingTabs.allSatisfy({ canMoveTab($0, to: placement) }) else {
            return nil
        }

        let movingWithinTargetSection = movingTabs.allSatisfy {
            $0.placement == placement && $0.spaceID == resolvedTargetSpaceID
        }
        let sourceSectionTabs = tabs(for: placement, inSpaceID: resolvedTargetSpaceID)
        let sourceSectionIndices = sourceSectionTabs.enumerated().compactMap { index, tab -> Int? in
            movingTabIDs.contains(tab.id) ? index : nil
        }
        let removedBeforeTarget = movingWithinTargetSection
            ? sourceSectionIndices.filter { $0 < requestedSectionIndex }.count
            : 0

        var updatedSpacePinnedTabsBySpaceID = tabsBySpaceID(for: .spacePinned, removingTabIDs: movingTabIDs)
        var targetPinnedTabs = updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] ?? []
        let destinationIndex =
            if let targetPinnedFolderID {
                pinnedFolderChildInsertionIndex(
                    requestedSectionIndex,
                    in: targetPinnedTabs,
                    folderID: targetPinnedFolderID
                )
            } else {
                min(max(requestedSectionIndex - removedBeforeTarget, 0), targetPinnedTabs.count)
            }
        let movedTabs = movingTabs.map { tab in
            var updatedTab = tab
            updatedTab.spaceID = resolvedTargetSpaceID
            updatedTab.placement = placement
            updatedTab.pinnedURLString = pinnedURLString(for: tab, movingTo: placement)
            updatedTab.pinnedFolderID = targetPinnedFolderID
            return updatedTab
        }
        targetPinnedTabs.insert(contentsOf: movedTabs, at: destinationIndex)
        updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] = targetPinnedTabs

        return tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: updatedSpacePinnedTabsBySpaceID,
            temporaryTabsBySpaceID: tabsBySpaceID(for: .temporary, removingTabIDs: movingTabIDs),
            appTabs: appTabs.filter { !movingTabIDs.contains($0.id) }
        )
    }

    func reorderedTabs(
        movingPinnedTabFolderID folderID: String,
        toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil,
        targetParentFolderID: String? = nil
    ) -> [Tab]? {
        guard let folder = pinnedTabFolders.first(where: { $0.id == folderID }) else {
            return nil
        }

        let targetParentFolder = targetParentFolderID.flatMap { parentFolderID in
            pinnedTabFolders.first { $0.id == parentFolderID }
        }
        guard targetParentFolderID == nil || targetParentFolder != nil else {
            return nil
        }
        guard targetParentFolderID == nil || !descendantPinnedTabFolderIDs(including: folderID).contains(
            targetParentFolderID ?? ""
        ) else {
            return nil
        }

        if targetSpaceID == nil, targetParentFolderID == nil, folder.spaceID != selectedSpaceID {
            return nil
        }

        let resolvedTargetSpaceID = targetParentFolder?.spaceID ?? targetSpaceID ?? selectedSpaceID ?? folder.spaceID
        guard spaces.contains(where: { $0.id == resolvedTargetSpaceID }) else {
            return nil
        }

        let movingFolderIDs = descendantPinnedTabFolderIDs(including: folderID)
        let movingChildren = tabs.filter {
            $0.spaceID == folder.spaceID
                && $0.placement == .spacePinned
                && $0.pinnedFolderID.map { movingFolderIDs.contains($0) } == true
        }
        guard !movingChildren.isEmpty else {
            return nil
        }

        var updatedSpacePinnedTabsBySpaceID = tabsBySpaceID(
            for: .spacePinned,
            removingTabIDs: Set(movingChildren.map(\.id))
        )
        var targetPinnedTabs = updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] ?? []
        let destinationIndex: Int
        if let targetParentFolderID {
            destinationIndex = pinnedFolderChildInsertionIndex(
                rootSectionIndex,
                in: targetPinnedTabs,
                folderID: targetParentFolderID
            )
        } else {
            let targetRootItems = pinnedRootItems(from: targetPinnedTabs, inSpaceID: resolvedTargetSpaceID)
            let clampedRootIndex = min(max(rootSectionIndex, 0), targetRootItems.count)
            destinationIndex = targetRootItems.dropFirst(clampedRootIndex).first?.firstSectionIndex
                ?? targetPinnedTabs.count
        }

        let movedChildren = movingChildren.map { tab in
            var updatedTab = tab
            updatedTab.spaceID = resolvedTargetSpaceID
            updatedTab.placement = .spacePinned
            return updatedTab
        }
        targetPinnedTabs.insert(contentsOf: movedChildren, at: destinationIndex)
        updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] = targetPinnedTabs

        return tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: updatedSpacePinnedTabsBySpaceID,
            temporaryTabsBySpaceID: tabsBySpaceID(for: .temporary, removingTabIDs: Set(movingChildren.map(\.id))),
            appTabs: appTabs.filter { tab in
                !movingChildren.contains { $0.id == tab.id }
            }
        )
    }
}

@MainActor private extension BrowserChromeModel {
    func tabSwitcherEntries() -> [TabSwitcherEntry] {
        pruneTabSwitcherTracking()

        guard
            let selectedTabID,
            tabs.contains(where: { $0.id == selectedTabID }),
            !closingTabIDs.contains(selectedTabID),
            !closedAppTabIDs.contains(selectedTabID),
            !closedPinnedTabIDs.contains(selectedTabID)
        else {
            return []
        }

        var seenTabIDs = Set<String>()
        var orderedTabIDs = [String]()

        func appendTabID(_ tabID: String) {
            guard
                !closingTabIDs.contains(tabID),
                !closedAppTabIDs.contains(tabID),
                !closedPinnedTabIDs.contains(tabID),
                seenTabIDs.insert(tabID).inserted
            else {
                return
            }

            orderedTabIDs.append(tabID)
        }

        appendTabID(selectedTabID)
        recentlySelectedTabIDs.forEach(appendTabID)

        let fallbackTabs = tabs
            .filter {
                !seenTabIDs.contains($0.id)
                    && !closingTabIDs.contains($0.id)
                    && !closedAppTabIDs.contains($0.id)
                    && !closedPinnedTabIDs.contains($0.id)
            }
            .sorted { lhs, rhs in
                lhs.lastActivityAt > rhs.lastActivityAt
            }
        fallbackTabs.map(\.id).forEach(appendTabID)

        return orderedTabIDs
            .compactMap { tabID in
                tabs.first { $0.id == tabID }
            }
            .prefix(Self.tabSwitcherMaximumEntries)
            .map { tab in
                TabSwitcherEntry(tab: tab, previewImage: tabPreviewImagesByID[tab.id])
            }
    }

    func scheduleTabSwitcherPresentation() {
        tabSwitcherPresentationTask?.cancel()

        let sessionID = UUID()
        tabSwitcherSessionID = sessionID
        tabSwitcherPresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.tabSwitcherPresentationDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.presentTabSwitcher(sessionID: sessionID)
        }
    }

    func presentTabSwitcher(sessionID: UUID) {
        guard tabSwitcherSessionID == sessionID, var state = tabSwitcherState else {
            return
        }

        state.isVisible = true
        tabSwitcherState = state
    }

    func clearTabSwitcherState() {
        tabSwitcherPresentationTask?.cancel()
        tabSwitcherPresentationTask = nil
        tabSwitcherSessionID = UUID()
        tabSwitcherState = nil
    }

    func recordSelectedTab(_ tabID: String?) {
        guard
            let tabID,
            tabs.contains(where: { $0.id == tabID }),
            !closingTabIDs.contains(tabID),
            !closedPinnedTabIDs.contains(tabID)
        else {
            return
        }

        recentlySelectedTabIDs.removeAll { $0 == tabID }
        recentlySelectedTabIDs.insert(tabID, at: 0)
        pruneTabSwitcherTracking()
    }

    func removeTabFromSwitcherTracking(_ tabID: String) {
        recentlySelectedTabIDs.removeAll { $0 == tabID }
        tabPreviewImagesByID.removeValue(forKey: tabID)

        guard var state = tabSwitcherState else {
            return
        }

        state.entries.removeAll { $0.id == tabID }
        if state.entries.isEmpty {
            clearTabSwitcherState()
        } else if !state.entries.contains(where: { $0.id == state.selectedTabID }) {
            state.selectedTabID = state.entries.first?.id ?? state.selectedTabID
            tabSwitcherState = state
        }
    }

    func pruneTabSwitcherTracking() {
        let openTabIDs = Set(tabs.map(\.id))
            .subtracting(closingTabIDs)
            .subtracting(closedAppTabIDs)
            .subtracting(closedPinnedTabIDs)
        recentlySelectedTabIDs.removeAll { !openTabIDs.contains($0) }

        for tabID in Array(tabPreviewImagesByID.keys) where !openTabIDs.contains(tabID) {
            tabPreviewImagesByID.removeValue(forKey: tabID)
        }
    }

    func captureSelectedTabPreviewIfNeeded() {
        guard
            let selectedTabID,
            !closingTabIDs.contains(selectedTabID),
            !closedAppTabIDs.contains(selectedTabID),
            !closedPinnedTabIDs.contains(selectedTabID),
            let previewImage = BrowserTabPreviewCapture.image(for: hostView)
        else {
            return
        }

        tabPreviewImagesByID[selectedTabID] = previewImage
    }

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
        guard supportsAppTabs || placement != .app else {
            return false
        }

        guard placement == .app, tab.placement != .app else {
            return true
        }

        return appTabs.count < Self.appTabCapacity
    }

    func tabsBySpaceID(
        for placement: BrowserTabPlacement,
        removingTabID tabID: String
    ) -> [String: [Tab]] {
        tabsBySpaceID(for: placement, removingTabIDs: [tabID])
    }

    func tabsBySpaceID(
        for placement: BrowserTabPlacement,
        removingTabIDs tabIDs: Set<String>
    ) -> [String: [Tab]] {
        spaces.reduce(into: [:]) { result, space in
            result[space.id] = tabs(for: placement, inSpaceID: space.id)
                .filter { !tabIDs.contains($0.id) }
        }
    }

    func tabsBySpaceID(
        replacing replacementTabs: [Tab],
        for placement: BrowserTabPlacement,
        inSpaceID spaceID: String
    ) -> [String: [Tab]] {
        var result = tabsBySpaceID(for: placement, removingTabIDs: [])
        result[spaceID] = replacementTabs
        return result
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

    func pinnedFolderChildInsertionIndex(
        _ requestedChildIndex: Int,
        in pinnedTabs: [Tab],
        folderID: String
    ) -> Int {
        let childIndices = pinnedTabs.indices.filter { pinnedTabs[$0].pinnedFolderID == folderID }
        guard !childIndices.isEmpty else {
            return pinnedTabs.count
        }

        let clampedChildIndex = min(max(requestedChildIndex, 0), childIndices.count)
        if clampedChildIndex < childIndices.count {
            return childIndices[clampedChildIndex]
        }

        return childIndices[childIndices.count - 1] + 1
    }

    private func pinnedRootItems(from pinnedTabs: [Tab], inSpaceID spaceID: String) -> [PinnedRootItem] {
        let foldersByID = Dictionary(uniqueKeysWithValues: pinnedTabFolders.filter { $0.spaceID == spaceID }.map {
            ($0.id, $0)
        })
        var seenFolderIDs = Set<String>()
        return pinnedTabs.indices.compactMap { index -> PinnedRootItem? in
            let tab = pinnedTabs[index]
            guard
                let folderID = tab.pinnedFolderID,
                let folder = foldersByID[folderID]
            else {
                return PinnedRootItem(firstSectionIndex: index, afterSectionIndex: index + 1)
            }

            guard folder.parentFolderID == nil else {
                return nil
            }

            guard !seenFolderIDs.contains(folderID) else {
                return nil
            }

            seenFolderIDs.insert(folderID)
            let childCount = pinnedTabs.filter { tab in
                tab.pinnedFolderID.map { descendantPinnedTabFolderIDs(including: folderID).contains($0) } == true
            }
            .count
            return PinnedRootItem(firstSectionIndex: index, afterSectionIndex: index + childCount)
        }
    }

    func descendantPinnedTabFolderIDs(including folderID: String) -> Set<String> {
        var result = Set<String>()

        func appendDescendants(of folderID: String) {
            guard !result.contains(folderID) else {
                return
            }

            result.insert(folderID)
            for childFolder in pinnedTabFolders where childFolder.parentFolderID == folderID {
                appendDescendants(of: childFolder.id)
            }
        }

        appendDescendants(of: folderID)
        return result
    }

    func uniquePinnedTabFolderID() -> String {
        var id = UUID().uuidString
        while pinnedTabFolders.contains(where: { $0.id == id }) {
            id = UUID().uuidString
        }
        return id
    }

    func removeInvalidPinnedTabFolderAssignments() {
        let folderSpaceIDsByID = Dictionary(uniqueKeysWithValues: pinnedTabFolders.map { ($0.id, $0.spaceID) })
        for index in pinnedTabFolders.indices {
            guard let parentFolderID = pinnedTabFolders[index].parentFolderID else {
                continue
            }

            guard parentFolderID != pinnedTabFolders[index].id,
                  folderSpaceIDsByID[parentFolderID] == pinnedTabFolders[index].spaceID,
                  !descendantPinnedTabFolderIDs(including: pinnedTabFolders[index].id).contains(parentFolderID)
            else {
                pinnedTabFolders[index].parentFolderID = nil
                continue
            }
        }

        for index in tabs.indices {
            tabs[index].pinnedURLString =
                if tabs[index].placement == .spacePinned {
                    effectivePinnedURLString(forPinnedTab: tabs[index])
                } else {
                    nil
                }

            guard let folderID = tabs[index].pinnedFolderID else {
                continue
            }

            guard
                tabs[index].placement == .spacePinned,
                folderSpaceIDsByID[folderID] == tabs[index].spaceID
            else {
                tabs[index].pinnedFolderID = nil
                continue
            }
        }
    }

    func removeEmptyPinnedTabFolders() {
        var folderIDsWithChildren = Set(tabs.compactMap { tab -> String? in
            tab.placement == .spacePinned ? tab.pinnedFolderID : nil
        })
        var didAddParent = true
        while didAddParent {
            didAddParent = false
            for folder in pinnedTabFolders {
                guard let parentFolderID = folder.parentFolderID,
                      folderIDsWithChildren.contains(folder.id),
                      !folderIDsWithChildren.contains(parentFolderID)
                else {
                    continue
                }

                folderIDsWithChildren.insert(parentFolderID)
                didAddParent = true
            }
        }
        pinnedTabFolders.removeAll { !folderIDsWithChildren.contains($0.id) }
    }

    func sanitizedPinnedTabFolderTitle(from title: String?) -> String? {
        guard let title else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    func lastActivityDate(from snapshotTab: BrowserTabSessionSnapshotTab) -> Date? {
        guard let lastActivityTimestamp = snapshotTab.lastActivityTimestamp else {
            return nil
        }

        return Date(timeIntervalSince1970: lastActivityTimestamp)
    }
}

// MARK: - Command Bar Actions

extension BrowserCommandID {
    var commandBarSearchAliases: [String] {
        switch self {
        case .openSettings:
            ["settings", "preferences", "app settings", "native settings"]
        case .setAsDefaultBrowser:
            ["default browser", "set default browser", "make default browser"]
        case .newTab:
            ["new tab", "open tab", "create tab"]
        case .newIncognitoWindow:
            ["incognito", "private window", "new private window"]
        case .openHistory:
            ["history", "open history", "browser history"]
        case .toggleBookmark:
            ["bookmark", "add bookmark", "remove bookmark", "star"]
        case .archiveTab:
            ["archive tab", "close tab", "close current tab"]
        case .savePage:
            ["save page", "save as", "download page"]
        case .printPage:
            ["print page", "print current page"]
        case .copyLink:
            ["copy link", "copy url", "copy address", "copy current url"]
        case .findInPage:
            ["find", "find in page", "search page"]
        case .findAndReplace:
            ["find replace", "find and replace", "replace"]
        case .findNext:
            ["find next", "next match", "next result"]
        case .findPrevious:
            ["find previous", "previous match", "previous result"]
        case .jumpToSelection:
            ["jump selection", "jump to selection"]
        case .clearTemporaryTabs:
            ["clear temporary tabs", "clear temp tabs", "temporary tabs"]
        case .goBack:
            ["back", "go back", "previous page"]
        case .goForward:
            ["forward", "go forward", "next page"]
        case .reload:
            ["reload", "refresh", "soft refresh"]
        case .forceReload:
            ["force reload", "force refresh", "hard reload", "hard refresh", "reload ignoring cache", "ignore cache"]
        case .clearCacheAndRefresh:
            ["clear cache", "clear cache refresh", "clear cache and refresh", "empty cache", "empty cache and refresh"]
        case .clearCookiesAndRefresh:
            [
                "clear cookies",
                "clear cookies refresh",
                "clear cookies and refresh",
                "delete cookies",
                "delete cookies and refresh",
            ]
        case .toggleSidebar:
            ["sidebar", "toggle sidebar", "show sidebar", "hide sidebar"]
        case .toggleBookmarksBar:
            ["bookmarks bar", "bookmark bar", "toggle bookmarks bar", "show bookmarks bar", "hide bookmarks bar"]
        }
    }

    var commandBarSystemImageName: String {
        switch self {
        case .openSettings:
            "gearshape"
        case .setAsDefaultBrowser:
            "globe"
        case .newTab:
            "plus"
        case .newIncognitoWindow:
            "eye.slash"
        case .openHistory:
            "clock.arrow.circlepath"
        case .toggleBookmark:
            "star"
        case .archiveTab:
            "archivebox"
        case .savePage:
            "square.and.arrow.down"
        case .printPage:
            "printer"
        case .copyLink:
            "link"
        case .findInPage:
            "doc.text.magnifyingglass"
        case .findAndReplace:
            "arrow.triangle.2.circlepath"
        case .findNext:
            "chevron.down"
        case .findPrevious:
            "chevron.up"
        case .jumpToSelection:
            "text.cursor"
        case .clearTemporaryTabs:
            "xmark.circle"
        case .goBack:
            "chevron.left"
        case .goForward:
            "chevron.right"
        case .reload:
            "arrow.clockwise"
        case .forceReload:
            "arrow.clockwise.circle"
        case .clearCacheAndRefresh:
            "externaldrive"
        case .clearCookiesAndRefresh:
            "trash"
        case .toggleSidebar:
            "sidebar.left"
        case .toggleBookmarksBar:
            "book"
        }
    }
}

extension BrowserKeyboardShortcut {
    var commandBarSearchAliases: [String] {
        guard isAssigned else {
            return []
        }

        let modifierPhrases = commandBarModifierSearchPhrases
        let keyAliases = commandBarKeySearchAliases
        var aliases = [
            displayText,
            keyCaps.joined(separator: " "),
        ]

        for keyAlias in keyAliases {
            for modifierPhrase in modifierPhrases {
                aliases.append("\(modifierPhrase) \(keyAlias)")
                aliases.append("\(modifierPhrase)+\(keyAlias)")
            }
        }

        return aliases
    }

    private var commandBarModifierSearchPhrases: [String] {
        var phrases = [""]

        if modifiers.contains(.control) {
            phrases = phrases.appendingModifierSearchAliases(["control", "ctrl"])
        }

        if modifiers.contains(.option) {
            phrases = phrases.appendingModifierSearchAliases(["option", "alt"])
        }

        if modifiers.contains(.shift) {
            phrases = phrases.appendingModifierSearchAliases(["shift"])
        }

        if modifiers.contains(.command) {
            phrases = phrases.appendingModifierSearchAliases(["command", "cmd"])
        }

        return phrases.filter { !$0.isEmpty }
    }

    private var commandBarKeySearchAliases: [String] {
        switch keyEquivalent {
        case ",":
            [",", "comma"]
        case "[":
            ["[", "left bracket", "open bracket"]
        case "]":
            ["]", "right bracket", "close bracket"]
        case "♡":
            ["heart"]
        default:
            [keyEquivalent.lowercased()]
        }
    }
}

private extension [String] {
    func appendingModifierSearchAliases(_ aliases: [String]) -> [String] {
        flatMap { phrase in
            aliases.map { alias in
                phrase.isEmpty ? alias : "\(phrase) \(alias)"
            }
        }
    }
}

// MARK: - BrowserTabPreviewCapture

private enum BrowserTabPreviewCapture {
    // MARK: Internal

    @MainActor static func image(for view: NSView) -> NSImage? {
        guard
            view.bounds.width >= minimumCaptureDimension,
            view.bounds.height >= minimumCaptureDimension
        else {
            return nil
        }

        return viewSnapshot(for: view).flatMap {
            BrowserImageThumbnailer.resizedImage($0, maximumPixelWidth: maximumPreviewPixelWidth)
        }
    }

    // MARK: Private

    private static let maximumPreviewPixelWidth: CGFloat = 960
    private static let minimumCaptureDimension: CGFloat = 24

    @MainActor private static func viewSnapshot(for view: NSView) -> NSImage? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }

        view.cacheDisplay(in: view.bounds, to: bitmap)

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}
