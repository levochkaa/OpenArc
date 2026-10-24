import AppKit
import Combine
import Foundation
import OSLog

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
        commandHandler: @escaping (BrowserCommandID, BrowserChromeModel) -> Void = { _, _ in },
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
        undoManager.canPerformTabAction = { [weak self] in
            guard let self else { return false }
            return canRegisterTabUndo && !isCompletingTabClose && !hasUncommittedSessionWrites &&
                !isApplyingRemoteSync &&
                !isArchiveOperationInFlight && pendingRemoteTabCreations.isEmpty
        }
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
        tabDriver.onTabCloseRequestFinished = { [weak self] tabID, requestID, outcome in
            self?.handleTabCloseRequestFinished(id: tabID, requestID: requestID, outcome: outcome)
        }
        tabDriver.onTabClosed = { [weak self] tabID in
            self?.handleClosedTab(id: tabID)
        }
        tabDriver.onTabFocused = { [weak self] tabID in
            self?.handleSplitPaneFocused(tabID)
        }
        tabDriver.onSplitResized = { [weak self] tabIDs, fractions in
            self?.handleSplitResize(tabIDs: tabIDs, fractions: fractions)
        }
        tabDriver.onSplitPaneLayout = { [weak self] tabIDs, frames in
            self?.handleSplitPaneLayout(tabIDs: tabIDs, frames: frames)
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
        reloadAutomaticTabArchivalSettings()
        syncCoordinator?.setExpiryScheduler(self)
        updateWindowTitle()
    }

    // MARK: Internal

    enum TabCloseReason {
        case manual
        case automaticExpiry
        case structuralRemoval
        case remoteProjection
        case undoRedo
    }

    nonisolated static let defaultSidebarWidth: CGFloat = 224
    nonisolated static let minSidebarWidth: CGFloat = defaultSidebarWidth
    /// The sidebar is capped at 500 pt. The minimum stays at the default,
    /// because the sidebar header has no compact layout.
    nonisolated static let maxSidebarWidth: CGFloat = 500
    nonisolated static let defaultExtensionSidePanelWidth: CGFloat = 360
    nonisolated static let minExtensionSidePanelWidth: CGFloat = 280
    nonisolated static let maxExtensionSidePanelWidth: CGFloat = 560
    nonisolated static let defaultNewTabURLString = "https://www.google.com"
    nonisolated static let automaticArchivalCheckInterval: TimeInterval = 60 * 60
    nonisolated static let appTabCapacity = 8
    nonisolated static let defaultSpaceID = BrowserSessionDefaults.defaultSpaceID
    nonisolated static let defaultSpaceIconName = BrowserSessionDefaults.defaultSpaceIconName
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
    @Published private(set) var tabSwitcherState: TabSwitcherState?
    @Published var isSidebarVisible = true
    @Published private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth
    @Published private(set) var temporaryTabLifetime: BrowserTemporaryTabLifetime
    @Published private(set) var automaticTabArchivalEnabled = false
    @Published private(set) var automaticArchivalSettingsError: String?
    @Published private(set) var archiveRevision = 0
    @Published private(set) var archiveError: String?
    @Published private(set) var isArchiveOperationInFlight = false
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
    /// Tabs whose video was sent to Picture in Picture on leaving them.
    private var pictureInPictureTabIDs = Set<String>()
    @Published private(set) var sessionPersistenceFailure: BrowserSessionPersistenceFailure?
    let hostView: NSView
    let userPreferencesStore: BrowserUserPreferencesStore
    let shortcutStore: BrowserShortcutStore
    let bookmarksModel: BrowserBookmarksModel
    let downloadsModel: BrowserDownloadsModel
    let windowMode: BrowserWindowMode
    let profile: BrowserProfile
    let undoManager = BrowserTabUndoManager()
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
            guard let self else { return }
            commandHandler(commandID, self)
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
            guard let self else { return }
            commandHandler(commandID, self)
        }
    )

    private(set) var isContextReady = false
    var isShuttingDown = false

    /// Last Split View layout sent to the engine. Only `syncSplitLayout()`
    /// changes it, so repeated selection inside one split sends nothing.
    var appliedSplitLayout: BrowserTabVisibleLayout?

    /// Tab that the next command bar result joins as a new Split View pane.
    /// `presentSplitViewCommandBar()` sets it; any other presentation or
    /// dismissal through the model clears it.
    var pendingSplitAnchorTabID: String?
    /// Where the pending pane goes relative to its anchor (Add Left/Right Split).
    var pendingSplitInsertion = SplitInsertion.end
    /// Expand Current Split: this pane alone fills the window until focus
    /// moves. UI-only, never persisted.
    var expandedSplitPaneTabID: String? {
        didSet {
            if oldValue != expandedSplitPaneTabID {
                syncSplitLayout()
            }
        }
    }

    /// Raw local Split View state. Only `BrowserChromeModel+SplitGroups.swift`
    /// mutates it; readers use `splitGroup(containingTabID:)`, which validates
    /// members against the current tabs.
    @Published var splitGroups = [SplitGroup]() {
        didSet {
            syncSplitLayout()
        }
    }

    /// UI-only: the visible split's pane frames in the engine host view, in pane
    /// order, as the engine last laid them out. Not published: it changes on
    /// every frame of a divider drag, and pane bars listen through
    /// `onSplitPaneLayoutChange` instead. Only `handleSplitPaneLayout` sets them.
    var splitPaneLayoutTabIDs = [String]()
    var splitPaneLayoutFrames = [CGRect]()
    var onSplitPaneLayoutChange: (() -> Void)?
    /// UI-only: the window's downloads list, toggled by View Downloads.
    var onToggleDownloads: (() -> Void)?
    /// UI-only mirror of the sidebar's tabs that stay visible in collapsed
    /// folders, so keyboard navigation counts the rows the sidebar shows.
    var sidebarRevealedPinnedTabIDsByFolderID = [String: Set<String>]()
    /// Muted tabs by sync ID, for this run only; a reopened dormant tab keeps it.
    /// Only `setTabMuted(_:id:)` writes it.
    @Published var mutedTabSyncIDs = Set<String>()
    /// UI-only: the window's site control center, opened by Open Extensions.
    var onOpenExtensions: (() -> Void)?
    /// UI-only: shows a hidden sidebar over the page for Reveal Current Tab.
    var onRevealSidebar: (() -> Void)?
    /// UI-only: bumped by `renameSelectedTab()`, the only writer, so the
    /// sidebar starts renaming the selected row.
    @Published var sidebarRenameRequestID = 0
    /// UI-only: bumped by `revealSelectedTabInSidebar()`, the only writer, so the
    /// sidebar scrolls the selected row into view.
    @Published var sidebarRevealRequestID = 0

    @Published private(set) var selectedTabID: String? {
        willSet {
            guard selectedTabID != newValue, canRecordViewingActivity else { return }
            // Every pane of a split is on screen while one member is focused.
            let ids = [selectedTabID, newValue].compactMap { $0 }.flatMap { splitPaneTabIDs(forTabID: $0) }
            for id in Set(ids) {
                guard tabs.first(where: { $0.id == id })?.creationState == .ready else { continue }
                touchTab(id: id)
            }
        }
        didSet {
            recordSplitFocus(tabID: selectedTabID)
            syncSplitLayout()
            refreshZoomFromEngine()
            updatePictureInPicture(leaving: oldValue, entering: selectedTabID)
        }
    }

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

    var usesSynchronizedAutomaticArchival: Bool {
        guard let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading else { return false }
        do { return try ownership.syncOwner() != nil } catch { return true }
    }

    var canConfigureAutomaticTabArchival: Bool {
        guard canBrowseArchive, sessionPreferencesStore is BrowserSQLiteSessionStore,
              let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading
        else { return false }
        return (try? ownership.syncOwner()) != nil
    }

    var canRetryAutomaticTabArchivalSettings: Bool {
        windowMode.persistsSession && !isShuttingDown && !hasDiscardedSessionForClosure &&
            pendingAutomaticArchivalSettingsRetry != nil
    }

    @discardableResult func retrySessionPersistence() -> Bool {
        guard !hasDiscardedSessionForClosure, !sessionWriteBuffer.isTerminal else { return false }
        if !sessionWriteBuffer.writes.isEmpty {
            let hasLocalWrite = sessionWriteBuffer.writes.contains {
                if case .local = $0.origin {
                    return true
                }
                return false
            }
            guard commitSessionWrites(sessionWriteBuffer.writes, schedulesPush: hasLocalWrite) else { return false }
        }
        if pendingHistoryRestore != nil {
            return retryHistoryRestore()
        }
        return sessionPersistenceFailure == nil
    }

    /// Closure preflight is reversible. Teardown must only run after it succeeds
    /// or the user explicitly chooses to discard the volatile session changes.
    @discardableResult func prepareSessionForClosure() -> Bool {
        guard !hasDiscardedSessionForClosure, isPersistenceEnabled else { return true }
        guard !sessionWriteBuffer.isTerminal else { return false }
        // Close/quit Retry uses this same preflight. A failed commit-first Undo
        // has no buffered snapshot, so ordinary snapshot persistence alone
        // cannot finish it or clear its failure.
        if pendingHistoryRestore != nil, !retrySessionPersistence() {
            return false
        }
        recordCurrentViewingActivity()
        persistCurrentSessionIfAllowed()
        isSessionClosurePrepared = !hasUncommittedSessionWrites
        return isSessionClosurePrepared
    }

    func discardUnsavedSessionForClosure() {
        hasDiscardedSessionForClosure = true
        pendingSessionCompletions.removeAll()
        pendingHistoryRestore = nil
        historyRestoreFailure = nil
        undoManager.removeAllActions()
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
            recordCurrentViewingActivity()
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
        syncCoordinator?.setRuntimeActive(false)
        syncCoordinator?.setExpiryScheduler(nil)
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

    /// Arc's sidebar can only join a persistent window that is not busy with
    /// restore or sync.
    var canImportArcSidebar: Bool {
        supportsSpaces && windowMode.persistsSession && !isShuttingDown && !isRestoringSession
            && !isApplyingRemoteSync && !isReconcilingRemoteProjection
    }

    /// Adds Arc's Spaces with their pinned tabs and folders, and its Favorites
    /// up to the app tile capacity. Imported tabs are dormant, like pinned tabs
    /// closed earlier: their pages load when first selected. The current Space
    /// and selection stay as they are.
    @discardableResult func importArcSidebar(_ sidebar: BrowserArcSidebar) -> BrowserArcSidebarImportResult {
        guard canImportArcSidebar else { return .init() }
        var result = BrowserArcSidebarImportResult()
        let now = dateProvider()

        func dormantTab(_ node: BrowserArcSidebar.Node, spaceID: String, folderID: String?, placement: BrowserTabPlacement)
            -> Tab?
        {
            guard case .tab(let title, let savedTitle, let urlString) = node else { return nil }
            let id = UUID().uuidString
            restoredTabCreationIDs.insert(id)
            return Tab(
                id: id,
                syncID: tabSyncIDProvider(),
                spaceID: spaceID,
                title: savedTitle ?? "",
                userTitleOverride: sanitizedUserTitleOverride(from: title),
                urlString: urlString,
                pinnedURLString: placement == .spacePinned ? normalizedPinnedURLString(from: urlString) : nil,
                placement: placement,
                pinnedFolderID: folderID,
                lastActivityAt: now
            )
        }

        func pinnedURLs(_ urls: [String]) -> Set<String> {
            Set(urls.map { comparablePinnedURLString(normalizedPinnedURLString(from: $0) ?? $0) })
        }
        // A Space imported before, with the same title and pinned pages, is skipped.
        let existing = spaces.map { space in
            (title: space.title, urls: pinnedURLs(tabs.filter { $0.spaceID == space.id && $0.placement == .spacePinned }
                    .map { $0.pinnedURLString ?? $0.urlString }))
        }
        for arcSpace in sidebar.spaces {
            let title = sanitizedSpaceTitle(from: arcSpace.title)
            let arcURLs = pinnedURLs(arcSpace.pinned.flatMap(\.tabs).compactMap { node in
                if case .tab(_, _, let url) = node { url } else { nil }
            })
            if let title, existing.contains(where: { $0.title == title && arcURLs.isSubset(of: $0.urls) }) {
                continue
            }
            var space = makeSpace()
            if let title {
                space.title = title
            }
            if let icon = arcSpace.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                space.systemImageName = icon
            }
            spaces.append(space)
            var folderChildren = [String: [BrowserSidebarItemID]]()
            func add(_ nodes: [BrowserArcSidebar.Node], folderID: String?) -> [BrowserSidebarItemID] {
                nodes.compactMap { node in
                    switch node {
                    case .tab:
                        guard let tab = dormantTab(node, spaceID: space.id, folderID: folderID, placement: .spacePinned)
                        else { return nil }
                        tabs.append(tab)
                        closedPinnedTabIDs.insert(tab.id)
                        result.pinnedTabCount += 1
                        return .tab(tab.id)
                    case .folder(let title, let icon, let children):
                        let id = uniquePinnedTabFolderID()
                        pinnedTabFolders.append(PinnedTabFolder(
                            id: id,
                            spaceID: space.id,
                            parentFolderID: folderID,
                            title: sanitizedPinnedTabFolderTitle(from: title) ?? BrowserStrings.pinnedTabFolderDefaultTitle,
                            systemImageName: icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 },
                            isExpanded: false
                        ))
                        result.folderCount += 1
                        folderChildren[id] = add(children, folderID: id)
                        return .folder(id)
                    }
                }
            }
            let roots = add(arcSpace.pinned, folderID: nil)
            var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
            tree.children[.pinned(space.id)] = roots
            for (folderID, children) in folderChildren {
                tree.children[.pinned(space.id, folderID: folderID)] = children
            }
            applyPinnedTree(tree)
            result.spaceCount += 1
        }

        if supportsAppTabs, let spaceID = selectedSpaceID ?? spaces.first?.id {
            var known = Set(appTabs.map { comparablePinnedURLString($0.urlString) })
            for node in sidebar.favorites where appTabs.count < Self.appTabCapacity {
                guard case .tab(_, _, let urlString) = node,
                      known.insert(comparablePinnedURLString(urlString)).inserted,
                      let tab = dormantTab(node, spaceID: spaceID, folderID: nil, placement: .app)
                else { continue }
                tabs.insert(tab, at: tabs.lastIndex { $0.placement == .app }.map { $0 + 1 } ?? 0)
                closedAppTabIDs.insert(tab.id)
                result.favoriteCount += 1
            }
        }

        if !result.isEmpty {
            persistCurrentSessionIfAllowed()
        }
        return result
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
            closeTab(id: tabID, registersUndo: false, reason: .structuralRemoval)
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
        recordExplicitViewingActivity(ids: [selectedTabID])
        selectedSpaceID = spaceID
        selectActiveTabForSelectedSpace()
        recordExplicitViewingActivity(ids: [selectedTabID])
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
        let originalTree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        let rootContainer = BrowserSidebarDropContainer.pinned(selectedSpaceID)
        let originalRoots = originalTree.items(in: rootContainer)
        let insertion = originalRoots.firstIndex { item in
            switch item {
            case .tab(let id): selectedTabIDs.contains(id)
            case .folder(let id): !selectedTabIDs.isDisjoint(with: originalTree.tabIDs(in: .pinned(
                    selectedSpaceID,
                    folderID: id
                )))
            }
        } ?? originalRoots.count

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
        var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        let moving = Set(selectedTabIDs.map(BrowserSidebarItemID.tab))
        var roots = originalRoots.filter { !moving.contains($0) }
        let rootIndex = originalRoots.prefix(insertion).filter { !moving.contains($0) }.count
        roots.insert(.folder(folderID), at: min(rootIndex, roots.count))
        tree.children[rootContainer] = roots
        tree.children[.pinned(selectedSpaceID, folderID: folderID)] = orderedTabs.map { .tab($0.id) }
        applyPinnedTree(tree)
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: Set(orderedTabs.map(\.id))))
        return folderID
    }

    /// Explicit deletion removes the folder's current subtree. Empty folders
    /// otherwise keep their identity when their last tab is moved or archived.
    @discardableResult func deletePinnedTabFolder(id folderID: String) -> Bool {
        guard pinnedTabFolders.contains(where: { $0.id == folderID }) else { return false }
        let removed = descendantPinnedTabFolderIDs(including: folderID)
        let wasPersistenceEnabled = isPersistenceEnabled
        isPersistenceEnabled = false
        for tabID in tabs.filter({ $0.placement == .spacePinned && $0.pinnedFolderID.map(removed.contains) == true })
            .map(\.id)
        {
            closeTab(id: tabID, registersUndo: false, reason: .structuralRemoval)
        }
        for (engineID, binding) in pendingRemoteTabCreations
            where binding.snapshot.placement == .spacePinned && binding.snapshot
            .pinnedFolderID
            .map(removed.contains) == true
        {
            pendingRemoteTabCreations.removeValue(forKey: engineID)
            discardedRemoteTabCreationIDs.insert(engineID)
            tabDriver.closeTab(withID: engineID, forceClose: true)
        }
        pinnedTabFolders.removeAll { removed.contains($0.id) }
        isPersistenceEnabled = wasPersistenceEnabled
        persistCurrentSessionIfAllowed()
        finishRemoteSyncProjectionIfReady()
        return true
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

        return navigateSelectedTab(toURLString: pinnedURLString)
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
        let snapshot = sidebarPlanningSnapshot()
        var payload = payload
        if case .folder(let id) = payload.primary {
            let visibleTree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
            let logicalTree = BrowserSidebarTabTree(snapshot: snapshot)
            guard let folder = logicalTree.folders[id] else { return nil }
            let container = BrowserSidebarDropContainer.pinned(folder.spaceID, folderID: id)
            let visibleIDs = Set(visibleTree.tabIDs(in: container))
            let logicalIDs = Set(logicalTree.tabIDs(in: container))
            // Native drags name visible descendants. Direct move plans can
            // already contain the pending identities from this same tree.
            guard payload.tabIDs == visibleIDs || payload.tabIDs == logicalIDs else { return nil }
            payload = .init(primary: payload.primary, tabIDs: logicalIDs)
        }
        return BrowserSidebarMovePlan
            .make(snapshot: snapshot, payload: payload, destination: destination) { tab, target in
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
        let updatesActivity =
            if case .tab = payload.primary {
                true
            } else {
                false
            }
        let plannedTabs = plan.tabs.map { tab in
            var tab = tab
            if updatesActivity, payload.tabIDs.contains(tab.id) {
                tab.lastActivityAt = advancedActivityDate(after: tab.lastActivityAt)
            }
            return tab
        }
        publishPlannedTabs(plannedTabs)
        pinnedTabFolders = plan.folders
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
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(for: payload))
        return true
    }

    func canMoveTab(
        withID tabID: String, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil
    ) -> Bool {
        indexedTabMovePlan(
            tabIDs: [tabID],
            placement: placement,
            sectionIndex: sectionIndex,
            targetSpaceID: targetSpaceID,
            targetPinnedFolderID: targetPinnedFolderID
        ) != nil
    }

    func canMoveTabs(
        withIDs tabIDs: Set<String>, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil
    ) -> Bool {
        tabIDs.count > 1 && indexedTabMovePlan(
            tabIDs: tabIDs,
            placement: placement,
            sectionIndex: sectionIndex,
            targetSpaceID: targetSpaceID,
            targetPinnedFolderID: targetPinnedFolderID
        ) != nil
    }

    func moveTab(
        withID tabID: String, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil
    ) {
        guard let plan = indexedTabMovePlan(
            tabIDs: [tabID],
            placement: placement,
            sectionIndex: sectionIndex,
            targetSpaceID: targetSpaceID,
            targetPinnedFolderID: targetPinnedFolderID
        )
        else { return }
        commitSidebarDrop(payload: plan.payload, destination: plan.destination)
    }

    func moveTabs(
        withIDs tabIDs: Set<String>, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil
    ) {
        guard tabIDs.count > 1,
              let plan = indexedTabMovePlan(
                  tabIDs: tabIDs,
                  placement: placement,
                  sectionIndex: sectionIndex,
                  targetSpaceID: targetSpaceID,
                  targetPinnedFolderID: targetPinnedFolderID
              )
        else { return }
        commitSidebarDrop(payload: plan.payload, destination: plan.destination)
    }

    func canMovePinnedTabFolder(
        withID folderID: String, toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil, targetParentFolderID: String? = nil
    ) -> Bool {
        indexedFolderMovePlan(
            folderID: folderID,
            index: rootSectionIndex,
            targetSpaceID: targetSpaceID,
            parentFolderID: targetParentFolderID
        ) != nil
    }

    func movePinnedTabFolder(
        withID folderID: String, toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil, targetParentFolderID: String? = nil
    ) {
        guard let plan = indexedFolderMovePlan(
            folderID: folderID,
            index: rootSectionIndex,
            targetSpaceID: targetSpaceID,
            parentFolderID: targetParentFolderID
        )
        else { return }
        commitSidebarDrop(payload: plan.payload, destination: plan.destination)
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

        if let sqlite = sessionPreferencesStore as? BrowserSQLiteSessionStore {
            do {
                try sqlite.saveTemporaryTabLifetimeStrict(lifetime)
            } catch {
                pendingAutomaticArchivalSettingsRetry = .localLifetime(lifetime)
                automaticArchivalSettingsError = BrowserStrings.settingsTemporaryTabsSaveFailed
                return
            }
        } else {
            sessionPreferencesStore.saveTemporaryTabLifetime(lifetime)
        }
        temporaryTabLifetime = lifetime
        if sessionPreferencesStore is BrowserSQLiteSessionStore {
            // A legacy lifetime change may repair a previously invalid value.
            // Validate the enabled flag as well before clearing its Retry state.
            reloadAutomaticTabArchivalSettings()
        } else {
            automaticArchivalSettingsError = nil
            pendingAutomaticArchivalSettingsRetry = nil
        }
        archiveExpiredTemporaryTabs()
    }

    /// The synced-profile picker expresses both enabled state and interval.
    /// Off remains editable while a session write or engine creation is pending.
    @discardableResult func setAutomaticTabArchival(lifetime: BrowserTemporaryTabLifetime?) -> Bool {
        guard canConfigureAutomaticTabArchival,
              let sqlite = sessionPreferencesStore as? BrowserSQLiteSessionStore else { return false }
        let chosen = lifetime ?? temporaryTabLifetime
        do {
            try sqlite.saveAutomaticTabArchival(enabled: lifetime != nil, lifetime: chosen)
            automaticTabArchivalEnabled = lifetime != nil
            temporaryTabLifetime = chosen
            automaticArchivalSettingsLoaded = true
            pendingAutomaticArchivalSettingsRetry = nil
            automaticArchivalSettingsError = nil
            syncCoordinator?.requestExpirySweep()
            return true
        } catch {
            pendingAutomaticArchivalSettingsRetry = .synchronized(lifetime)
            automaticArchivalSettingsError = BrowserStrings.settingsTemporaryTabsSaveFailed
            return false
        }
    }

    @discardableResult func reloadAutomaticTabArchivalSettings() -> Bool {
        guard windowMode.persistsSession, !isShuttingDown, !hasDiscardedSessionForClosure,
              let sqlite = sessionPreferencesStore as? BrowserSQLiteSessionStore else { return false }
        do {
            let settings = try sqlite.loadAutomaticTabArchivalSettings()
            automaticTabArchivalEnabled = settings.enabled
            temporaryTabLifetime = settings.lifetime
            automaticArchivalSettingsLoaded = true
            pendingAutomaticArchivalSettingsRetry = nil
            automaticArchivalSettingsError = nil
            syncCoordinator?.requestExpirySweep()
            return true
        } catch {
            automaticArchivalSettingsLoaded = false
            pendingAutomaticArchivalSettingsRetry = .reload
            automaticArchivalSettingsError = BrowserStrings.settingsTemporaryTabsLoadFailed
            return false
        }
    }

    @discardableResult func retryAutomaticTabArchivalSettings() -> Bool {
        guard canRetryAutomaticTabArchivalSettings, let pendingAutomaticArchivalSettingsRetry else { return false }
        switch pendingAutomaticArchivalSettingsRetry {
        case .reload: return reloadAutomaticTabArchivalSettings()
        case .synchronized(let lifetime): return setAutomaticTabArchival(lifetime: lifetime)
        case .localLifetime(let lifetime):
            setTemporaryTabLifetime(lifetime)
            return automaticArchivalSettingsError == nil
        }
    }

    func handleApplicationDidBecomeActive() {
        guard !isShuttingDown else { return }
        let becameActive = !isViewingActivityActive
        isViewingActivityActive = true
        syncCoordinator?.setRuntimeActive(true)
        if becameActive {
            persistCurrentViewingActivity()
        }
        archiveExpiredTemporaryTabs()
        bookmarksModel.reload()
        refreshBrowserExtensions()
        syncCoordinator?.schedulePull()
    }

    func handleApplicationWillResignActive() {
        guard isViewingActivityActive, !isShuttingDown else { return }
        persistCurrentViewingActivity()
        isViewingActivityActive = false
        syncCoordinator?.setRuntimeActive(false)
    }

    func updateProfilePresentation(profile: BrowserProfile, availableProfileCount: Int) {
        profileDisplayName = profile.displayName
        self.availableProfileCount = availableProfileCount
    }

    func archiveExpiredTemporaryTabs() {
        guard canAdmitLocalAutomaticArchive, localAutomaticArchiveCandidates.isEmpty,
              localAutomaticArchivalOwnershipAllowsClose() else { return }
        localAutomaticArchiveCandidates = Array(tabs.lazy
            .filter { self.isLocalAutomaticArchiveEligible($0) }
            .prefix(100)
            .map {
                LocalAutomaticArchiveCandidate(
                    id: $0.id, syncID: $0.syncID, spaceID: $0.spaceID, lastActivityAt: $0.lastActivityAt
                )
            })
        continueLocalAutomaticArchiveSweep()
    }

    func presentCommandBar() {
        guard canCreateTab else {
            return
        }

        pendingSplitAnchorTabID = nil
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

        pendingSplitAnchorTabID = nil
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
        pendingSplitAnchorTabID = nil
        commandBarModel.dismiss()
        currentPageCommandBarModel.dismiss()
    }

    /// Open Location edits the selected tab's URL, which is the focused pane in a split.
    var canOpenLocation: Bool { canCreateTab && selectedTab != nil && !isWebApp }

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

    /// Mute Tab / Unmute Tab.
    func setTabMuted(_ muted: Bool, id: String) {
        guard let tab = tabs.first(where: { $0.id == id }), mutedTabSyncIDs.contains(tab.syncID) != muted else { return }
        if muted {
            mutedTabSyncIDs.insert(tab.syncID)
        } else {
            mutedTabSyncIDs.remove(tab.syncID)
        }
        tabDriver.setAudioMuted(muted, forTabWithID: id)
    }

    /// Copy URL as Markdown: `[title](url)` for the selected tab.
    @discardableResult func copySelectedTabLinkAsMarkdown() -> Bool {
        guard let selectedTab, !selectedTab.urlString.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(
            BrowserMarkdownLink.text(title: selectedTab.displayTitle, urlString: selectedTab.urlString),
            forType: .string
        )
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

    /// The engine keeps zoom per site, so the shown value is read back from the
    /// selected page instead of being remembered per tab.
    func refreshZoomFromEngine() {
        let level = selectedTabID.flatMap { tabDriver.zoomLevel(forTabWithID: $0) } ?? 0
        let exact = 100 * pow(1.2, level)
        let percent = Self.zoomPercentages.min { abs(Double($0) - exact) < abs(Double($1) - exact) } ?? 100
        if zoomPercent != percent {
            zoomPercent = percent
        }
    }

    func zoomIn() {
        refreshZoomFromEngine()
        guard let nextPercent = Self.zoomPercentages.first(where: { $0 > zoomPercent }) else {
            return
        }

        setZoomPercent(nextPercent)
    }

    func zoomOut() {
        refreshZoomFromEngine()
        guard let previousPercent = Self.zoomPercentages.last(where: { $0 < zoomPercent }) else {
            return
        }

        setZoomPercent(previousPercent)
    }

    func resetZoom() {
        setZoomPercent(100)
    }

    /// Picture in Picture on leaving a tab: a playing video follows the
    /// user out of its tab and returns when they come back. Panes that stay on
    /// screen in a split and closing tabs are left alone.
    private func updatePictureInPicture(leaving oldID: String?, entering newID: String?) {
        guard oldID != newID else { return }
        if let newID, pictureInPictureTabIDs.remove(newID) != nil {
            tabDriver.setPictureInPicture(false, forTabWithID: newID)
        }
        guard userPreferencesStore.pictureInPictureEnabled, let oldID,
              tabs.contains(where: { $0.id == oldID }), !closingTabIDs.contains(oldID),
              !closedAppTabIDs.contains(oldID), !closedPinnedTabIDs.contains(oldID),
              !(newID.map { splitPaneTabIDs(forTabID: $0).contains(oldID) } ?? false)
        else { return }
        // Forget tabs that have closed since.
        pictureInPictureTabIDs.formIntersection(tabs.map(\.id))
        pictureInPictureTabIDs.insert(oldID)
        tabDriver.setPictureInPicture(true, forTabWithID: oldID)
    }

    var canShowDeveloperTools: Bool { canCreateTab && selectedTabID != nil && !isWebApp }

    @discardableResult func showDeveloperTools() -> Bool {
        guard canShowDeveloperTools else { return false }
        tabDriver.showDevToolsForActiveTab()
        return true
    }

    var canZoomIn: Bool { canCreateTab && selectedTabID != nil && zoomPercent < (Self.zoomPercentages.last ?? 100) }
    var canZoomOut: Bool { canCreateTab && selectedTabID != nil && zoomPercent > (Self.zoomPercentages.first ?? 100) }
    var canResetZoom: Bool { canCreateTab && selectedTabID != nil && zoomPercent != 100 }

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
            pendingTabCloseRequests.removeAll()
            localAutomaticArchiveCandidates.removeAll()
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
            if replacement.urlString != binding.snapshot.urlString {
                tabDriver.navigateTab(withID: engineID, toURLString: resolvedBrowserURLString(replacement.urlString))
            }
        }

        for tab in tabs where !seenSyncIDs.contains(tab.syncID)
            || ((closedAppTabIDs.contains(tab.id) || closedPinnedTabIDs.contains(tab.id))
                && remoteTabsByID[tab.syncID]?.placement != tab.placement)
        {
            closeTab(id: tab.id, forceClose: true, registersUndo: false, reason: .remoteProjection)
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

    @discardableResult func closeAppTabProcess(
        id: String,
        forceClose: Bool = false,
        engineAlreadyClosed: Bool = false
    ) -> Bool {
        guard
            !closingTabIDs.contains(id),
            let tab = tabs.first(where: { $0.id == id }),
            tab.placement == .app,
            !closedAppTabIDs.contains(id)
        else {
            return false
        }

        if !forceClose, !engineAlreadyClosed {
            guard !isShuttingDown else { return false }
            return requestConfirmedTabClose(
                id: id, registersUndo: false, actionName: BrowserStrings.tabArchiveAction,
                createsArchive: false, preservesPersistentTab: true, unloadsPersistentTab: true
            )
        }

        retireTabCreationCallbacks(id: id)
        closedAppTabIDs.insert(id)
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

        if !engineAlreadyClosed {
            tabDriver.closeTab(withID: id, forceClose: forceClose)
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    @discardableResult func closePinnedTabProcessOrReset(
        id: String,
        forceClose: Bool = false,
        engineAlreadyClosed: Bool = false
    ) -> Bool {
        guard
            !closingTabIDs.contains(id),
            let tab = tabs.first(where: { $0.id == id }),
            tab.placement == .spacePinned,
            let pinnedURLString = effectivePinnedURLString(forPinnedTab: tab),
            !closedPinnedTabIDs.contains(id)
        else {
            return false
        }

        if !forceClose, !engineAlreadyClosed {
            guard !isShuttingDown else { return false }
            return requestConfirmedTabClose(
                id: id, registersUndo: false, actionName: BrowserStrings.tabArchiveAction,
                createsArchive: false, preservesPersistentTab: true, unloadsPersistentTab: true
            )
        }

        retireTabCreationCallbacks(id: id)
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

        if !engineAlreadyClosed {
            tabDriver.closeTab(withID: id, forceClose: forceClose)
        }
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
            !blocksTabInteraction(id)
        else {
            return
        }
        if pendingTabCloseRequests[id]?.localAutomaticCandidate != nil {
            pendingTabCloseRequests[id]?.invalidatedAutomaticClose = true
        }

        let didRecordActivity = recordExplicitViewingActivity(ids: [selectedTabID, id])

        if closedAppTabIDs.contains(id), tab.placement == .app {
            reopenClosedAppTab(id: id)
            return
        }

        if closedPinnedTabIDs.contains(id), tab.placement == .spacePinned {
            reopenClosedPinnedTab(id: id)
            return
        }

        guard selectedTabID != id else {
            if didRecordActivity {
                persistCurrentSessionIfAllowed()
            }
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
        undoActionName: String = BrowserStrings.tabArchiveAction,
        reason: TabCloseReason = .manual
    ) -> Bool {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        // A remote/structural removal supersedes an outstanding local dialog.
        // It must not be rejected merely because that request owns the close ID.
        if forceClose || reason == .structuralRemoval || reason == .remoteProjection {
            if let superseded = pendingTabCloseRequests.removeValue(forKey: id) {
                closingTabIDs.remove(id)
                superseded.completion?(.removed)
                if superseded.localAutomaticCandidate != nil {
                    localAutomaticArchiveCandidates.removeAll()
                }
            }
        }
        guard !closingTabIDs.contains(id) else { return false }
        if reason == .manual, !forceClose, !isShuttingDown {
            // Capture the user's action once. Removing a persistent row remains
            // a logical removal even if its placement changes during approval.
            let archives = tabs[closingIndex].placement == .temporary
            return requestConfirmedTabClose(
                id: id, registersUndo: registersUndo, actionName: undoActionName,
                createsArchive: archives, preservesPersistentTab: archives,
                historyKind: archives ? .archive : .logicalRemoval
            )
        }
        return finishTabClose(
            id: id, forceClose: forceClose, requestsEngineClose: true,
            registersUndo: registersUndo, undoActionName: undoActionName
        )
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

    /// Split View edits persist like other local tree edits. The store keeps
    /// them out of sync because sync payloads never include split groups.
    func persistSplitGroupChange() {
        persistCurrentSessionIfAllowed()
    }

    func sendVisibleTabLayout(_ layout: BrowserTabVisibleLayout?) {
        tabDriver.setVisibleTabLayout(layout)
    }

    // MARK: Private

    private struct LocalAutomaticArchiveCandidate {
        let id: String
        let syncID: String
        let spaceID: String
        let lastActivityAt: Date
    }

    private struct PendingTabCloseRequest {
        let requestID: String
        let syncID: String
        let registersUndo: Bool
        let undoActionName: String
        let createsArchive: Bool
        let preservesPersistentTab: Bool
        let unloadsPersistentTab: Bool
        let historyKind: TabHistoryKind
        let localAutomaticCandidate: LocalAutomaticArchiveCandidate?
        var invalidatedAutomaticClose = false
        let completion: ((HistoryCloseResult) -> Void)?
    }

    private enum HistoryCloseResult {
        case closed(TabUndoSnapshot, archiveID: String?)
        case cancelled
        case removed
    }

    private enum TabHistoryKind: Equatable {
        case creation
        case archive
        case logicalRemoval
    }

    private struct PendingSessionCompletion {
        let write: BrowserSessionWrite
        let completion: () -> Void
    }

    private struct PendingHistoryRestore {
        let archiveID: String?
        let syncID: String
        let snapshot: TabUndoSnapshot
        let kind: TabHistoryKind
        let actionName: String
        let completion: (BrowserTabUndoManager.Outcome) -> Void
    }

    private struct PendingReopenedTabCreation {
        let previousID: String
        let titleAtRequest: String
    }

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

    private struct RemoteTabCreation {
        let snapshot: BrowserTabSessionSnapshotTab
        let generation: Int
    }

    private enum AutomaticArchivalSettingsRetry {
        case reload
        case synchronized(BrowserTemporaryTabLifetime?)
        case localLifetime(BrowserTemporaryTabLifetime)
    }

    private static let automaticArchivalLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser", category: "AutomaticArchival"
    )

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
    private let commandHandler: (BrowserCommandID, BrowserChromeModel) -> Void

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private var pendingTabCloseRequests = [String: PendingTabCloseRequest]()
    private var isCompletingTabClose = false
    private var localAutomaticArchiveCandidates = [LocalAutomaticArchiveCandidate]()
    private var isProcessingLocalAutomaticArchiveCandidates = false
    private var pendingSessionCompletions = [PendingSessionCompletion]()
    private var pendingHistoryRestore: PendingHistoryRestore?
    private var historyRestoreFailure: BrowserSessionPersistenceFailure?
    private var closedAppTabIDs = Set<String>()
    private var closedPinnedTabIDs = Set<String>()
    private var pendingReopenedAppTabCreations = [String: PendingReopenedTabCreation]()
    private var pendingReopenedPinnedTabCreations = [String: PendingReopenedTabCreation]()
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
    private var pendingHydratedTabCreationIDs = Set<String>()
    private var tabCreationUndoReferences = [String: TabCreationUndoReference]()
    private var automaticArchivalTimer: Timer?
    private var automaticArchivalSettingsLoaded = false
    private var pendingAutomaticArchivalSettingsRetry: AutomaticArchivalSettingsRetry?

    private var isViewingActivityActive = true
    private var recentlySelectedTabIDs = [String]()
    private var tabPreviewImagesByID = [String: NSImage]()
    private var tabSwitcherPresentationTask: Task<Void, Never>?
    private var tabSwitcherSessionID = UUID()
    private var webAppManifestLoadTask: Task<Void, Never>?

    private var canAdmitLocalAutomaticArchive: Bool {
        isContextReady && windowMode.persistsSession && isPersistenceEnabled && !isShuttingDown &&
            !hasDiscardedSessionForClosure && !hasUncommittedSessionWrites && !isRestoringSession &&
            !isApplyingRemoteSync && !isReconcilingRemoteProjection && !isArchiveOperationInFlight &&
            !isCompletingTabClose && !undoManager.isTabTransitionPending && pendingTabCloseRequests.isEmpty
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

    private func localAutomaticArchivalOwnershipAllowsClose() -> Bool {
        // A paused, signed-out or offline owner still requires conditional expiry.
        guard let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading else { return true }
        do {
            guard try ownership.syncOwner() == nil else {
                syncCoordinator?.requestExpirySweep()
                return false
            }
            return true
        } catch {
            Self.automaticArchivalLogger.error(
                "Skipping automatic archival because sync ownership could not be read: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func isLocalAutomaticArchiveEligible(_ tab: Tab) -> Bool {
        let now = dateProvider().timeIntervalSince1970
        let activity = tab.lastActivityAt.timeIntervalSince1970
        return now.isFinite && activity.isFinite && tab.spaceID == selectedSpaceID &&
            tab.placement == .temporary && tab.id != selectedTabID &&
            !(selectedTabID.map { splitPaneTabIDs(forTabID: $0).contains(tab.id) } ?? false) &&
            activity <= now - temporaryTabLifetime.timeInterval
    }

    private func continueLocalAutomaticArchiveSweep() {
        guard !isProcessingLocalAutomaticArchiveCandidates else { return }
        isProcessingLocalAutomaticArchiveCandidates = true
        defer { isProcessingLocalAutomaticArchiveCandidates = false }
        while !localAutomaticArchiveCandidates.isEmpty {
            guard canAdmitLocalAutomaticArchive, localAutomaticArchivalOwnershipAllowsClose() else {
                localAutomaticArchiveCandidates.removeAll()
                return
            }
            let candidate = localAutomaticArchiveCandidates.removeFirst()
            guard let tab = tabs.first(where: { $0.id == candidate.id && $0.syncID == candidate.syncID }),
                  tab.spaceID == candidate.spaceID, tab.lastActivityAt == candidate.lastActivityAt,
                  isLocalAutomaticArchiveEligible(tab) else { continue }
            _ = requestConfirmedTabClose(
                id: tab.id, registersUndo: false, actionName: BrowserStrings.tabArchiveAction,
                createsArchive: true, preservesPersistentTab: true, localAutomaticCandidate: candidate
            )
            // Inline engine-less outcomes continue this loop; a deferred result
            // resumes it after finishing its own transaction. Never stack sheets.
            if pendingTabCloseRequests[tab.id] != nil {
                return
            }
        }
    }

    @discardableResult private func requestConfirmedTabClose(
        id: String, registersUndo: Bool, actionName: String, createsArchive: Bool,
        preservesPersistentTab: Bool, unloadsPersistentTab: Bool = false,
        historyKind: TabHistoryKind = .archive,
        localAutomaticCandidate: LocalAutomaticArchiveCandidate? = nil,
        completion: ((HistoryCloseResult) -> Void)? = nil
    ) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), !closingTabIDs.contains(id) else { return false }
        if closedAppTabIDs.contains(id) || closedPinnedTabIDs.contains(id) {
            // The logical persistent tab outlives its unloaded native record.
            // Logical removal and Undo Create need no missing-engine request.
            if preservesPersistentTab, tab.placement != .temporary {
                completion?(.removed)
                return true
            }
            return finishTabClose(
                id: id, forceClose: false, requestsEngineClose: false,
                registersUndo: registersUndo, undoActionName: actionName,
                createsArchive: createsArchive, historyKind: historyKind, completion: completion
            )
        }
        let requestID = UUID().uuidString
        pendingTabCloseRequests[id] = PendingTabCloseRequest(
            requestID: requestID, syncID: tab.syncID, registersUndo: registersUndo,
            undoActionName: actionName, createsArchive: createsArchive,
            preservesPersistentTab: preservesPersistentTab, unloadsPersistentTab: unloadsPersistentTab,
            historyKind: historyKind,
            localAutomaticCandidate: localAutomaticCandidate,
            completion: completion
        )
        closingTabIDs.insert(id)
        guard tabDriver.requestCloseTab(withID: id, requestID: requestID) else {
            if pendingTabCloseRequests[id]?.requestID == requestID {
                pendingTabCloseRequests.removeValue(forKey: id)
                closingTabIDs.remove(id)
            }
            return false
        }
        return true
    }

    @discardableResult private func finishTabClose(
        id: String, forceClose: Bool, requestsEngineClose: Bool,
        registersUndo: Bool, undoActionName: String, createsArchive: Bool = false,
        historyKind: TabHistoryKind = .archive,
        completion: ((HistoryCloseResult) -> Void)? = nil
    ) -> Bool {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let closingTab = tabs[closingIndex]
        let undoSnapshot = tabUndoSnapshot(forClosingTabAt: closingIndex)
        let precloseSnapshot: BrowserTabSessionSnapshot? = createsArchive && canBrowseArchive && closingTab
            .placement == .temporary
            ? (isApplyingRemoteSync ? snapshotPreservingPendingRemoteCreations() : currentSessionSnapshot())
            : nil
        let archivedTab = precloseSnapshot?.tabs.first { $0.id == closingTab.syncID }
        let archiveEntry = archivedTab.map {
            BrowserTabArchiveEntry(
                id: UUID().uuidString, tab: $0, archivedAt: dateProvider().timeIntervalSince1970,
                title: closingTab.title
            )
        }
        let closingTabWasSelected = selectedTabID == id
        closingTabIDs.insert(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: closingTab))

        let wasCompletingTabClose = isCompletingTabClose
        isCompletingTabClose = true
        tabs.removeAll { $0.id == id }
        // A logical tab can close before its allocation placeholder arrives.
        // Retain the retired identity so repeated late callbacks cannot recreate it.
        retireTabCreationCallbacks(id: id)
        closedAppTabIDs.remove(id)
        closedPinnedTabIDs.remove(id)
        removeTabFromSwitcherTracking(id)
        tabCreationUndoReferences.removeValue(forKey: id)?.currentTabID = nil
        clearSelectedTab(id, forSpaceID: closingTab.spaceID)

        if closingTabWasSelected {
            let fallbackTabID = fallbackTabID(afterClosingDormantTab: closingTab, excluding: [id])
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

        if requestsEngineClose {
            tabDriver.closeTab(withID: id, forceClose: forceClose)
        } else {
            closingTabIDs.remove(id)
        }
        updateWindowTitle()
        // Reserve normal history in the order of the user's logical actions.
        // Failed persistence gates execution, not registration: a later New Tab
        // must stay above this Close even if its write also retries this batch.
        if registersUndo, let undoSnapshot {
            registerTabCloseUndo(
                undoSnapshot, archiveID: archiveEntry?.id, kind: historyKind, actionName: undoActionName
            )
        }
        let didCommit: () -> Void = { [weak self] in
            guard let self, let undoSnapshot else { return }
            if archiveEntry != nil {
                archiveRevision &+= 1
            }
            completion?(.closed(undoSnapshot, archiveID: archiveEntry?.id))
        }
        if isContextReady, isPersistenceEnabled, !isRestoringSession, !isReconcilingRemoteProjection {
            let snapshot: BrowserTabSessionSnapshot
            if isApplyingRemoteSync {
                snapshot = snapshotPreservingPendingRemoteCreations()
                remoteProjectionSnapshot = snapshot
                hasLocalChangesDuringRemoteProjection = true
            } else {
                snapshot = currentSessionSnapshot()
            }
            _ = persistSessionWrite(
                .init(
                    snapshot: snapshot,
                    origin: .local(syncMove: nil),
                    archiveAction: archiveEntry.map { .insert($0) },
                    // The live URL can differ from SQLite's remote projection
                    // while other engines are pending. Normalize inside this
                    // Archive action, after its receipt check, so retry cannot
                    // replay a stale prefix after the deletion already committed.
                    archiveProjectionSnapshot: isApplyingRemoteSync ? precloseSnapshot : nil
                ),
                schedulesPush: !isApplyingRemoteSync,
                onCommit: didCommit
            )
        } else {
            didCommit()
        }
        isCompletingTabClose = wasCompletingTabClose
        return true
    }

    private func indexedFolderMovePlan(
        folderID: String, index: Int, targetSpaceID: String?, parentFolderID: String?
    ) -> BrowserSidebarMovePlan? {
        let tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
        guard let folder = tree.folders[folderID],
              targetSpaceID != nil || parentFolderID != nil || folder.spaceID == selectedSpaceID else { return nil }
        let spaceID = parentFolderID.flatMap { tree.folders[$0]?.spaceID }
            ?? targetSpaceID ?? selectedSpaceID ?? folder.spaceID
        let container = BrowserSidebarDropContainer.pinned(spaceID, folderID: parentFolderID)
        let siblings = tree.items(in: container).filter { $0 != .folder(folderID) }
        let index = min(max(index, 0), siblings.count)
        return sidebarMovePlan(
            payload: .init(
                primary: .folder(folderID),
                tabIDs: Set(tree.tabIDs(in: .pinned(folder.spaceID, folderID: folderID)))
            ),
            destination: .init(container: container, beforeItem: index < siblings.count ? siblings[index] : nil)
        )
    }

    private func indexedTabMovePlan(
        tabIDs: Set<String>, placement: BrowserTabPlacement, sectionIndex: Int,
        targetSpaceID: String?, targetPinnedFolderID: String?
    ) -> BrowserSidebarMovePlan? {
        guard let primary = tabs.first(where: { tabIDs.contains($0.id) })?.id else { return nil }
        let candidate = tabIDs.count == 1
            ? reorderedTabs(
                movingTabID: primary,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID
            )
            : reorderedTabs(
                movingTabIDs: tabIDs,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID
            )
        guard let candidate, candidate != tabs,
              let moved = candidate.first(where: { $0.id == primary }) else { return nil }
        // Index APIs retain their historical flattened-tab addressing. Resolve it
        // once to a typed sibling anchor; the actual mutation uses the shared tree.
        let unrankedTabs = candidate.map { tab in var tab = tab
            tab.pinnedSiblingRank = nil
            return tab
        }
        let unrankedFolders = pinnedTabFolders.map { folder in
            var folder = folder
            folder.pinnedSiblingRank = nil
            return folder
        }
        let inferred = BrowserSidebarTabTree(snapshot: sidebarSnapshot.replacingTabs(
            unrankedTabs,
            pinnedTabFolders: unrankedFolders
        ))
        let container: BrowserSidebarDropContainer =
            switch placement {
            case .app: .app
            case .temporary: .temporary(moved.spaceID)
            case .spacePinned: .pinned(moved.spaceID, folderID: moved.pinnedFolderID)
            }
        let siblings = inferred.items(in: container)
        let moving = Set(tabIDs.map(BrowserSidebarItemID.tab))
        guard let last = siblings.lastIndex(where: { moving.contains($0) }) else { return nil }
        let before = siblings.dropFirst(last + 1).first { !moving.contains($0) }
        return sidebarMovePlan(
            payload: .init(primary: .tab(primary), tabIDs: tabIDs),
            destination: .init(container: container, beforeItem: before)
        )
    }

    private func applyPinnedTree(_ value: BrowserSidebarTabTree) {
        var tree = value
        var logicalTabs = sidebarPlanningSnapshot().allTabs
        tree.assignPinnedRanks(to: &logicalTabs)
        pinnedTabFolders = pinnedTabFolders.compactMap { tree.folders[$0.id] }
        let byID = Dictionary(uniqueKeysWithValues: logicalTabs.map { ($0.id, $0) })
        publishPlannedTabs(tree.orderedTabIDs().compactMap { byID[$0] })
    }

    /// Pending remote identities occupy real sibling slots before their logical
    /// engine callback. They participate in planning without appearing as tabs.
    private func sidebarPlanningSnapshot() -> BrowserSidebarSnapshot {
        guard !pendingRemoteTabCreations.isEmpty else { return sidebarSnapshot }
        let hydrated = Dictionary(uniqueKeysWithValues: tabs.map { ($0.syncID, $0) })
        let pending = Dictionary(uniqueKeysWithValues: pendingRemoteTabCreations.compactMap { engineID, binding in
            binding.snapshot.id.map { ($0, engineID) }
        })
        let logicalTabs = snapshotPreservingPendingRemoteCreations().tabs.compactMap { snapshot -> Tab? in
            guard let syncID = snapshot.id else { return nil }
            if let tab = hydrated[syncID] {
                return tab
            }
            guard let engineID = pending[syncID] else { return nil }
            return Tab(
                id: engineID, syncID: syncID, spaceID: snapshot.spaceID ?? Self.defaultSpaceID,
                title: "", userTitleOverride: snapshot.userTitleOverride, urlString: snapshot.urlString,
                pinnedURLString: snapshot.pinnedURLString, placement: snapshot.placement,
                pinnedFolderID: snapshot.pinnedFolderID, pinnedSiblingRank: snapshot.pinnedSiblingRank,
                lastActivityAt: lastActivityDate(from: snapshot) ?? dateProvider()
            )
        }
        return sidebarSnapshot.replacingTabs(logicalTabs)
    }

    private func publishPlannedTabs(_ logicalTabs: [Tab]) {
        let pendingIDs = Set(pendingRemoteTabCreations.keys)
        tabs = logicalTabs.filter { !pendingIDs.contains($0.id) }
        let snapshots = logicalTabs.map { tab in
            if let original = pendingRemoteTabCreations[tab.id]?.snapshot {
                return BrowserTabSessionSnapshotTab(
                    id: original.id, urlString: original.urlString, pinnedURLString: original.pinnedURLString,
                    userTitleOverride: original.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: original.lastActivityTimestamp,
                    pinnedSiblingRank: tab.pinnedSiblingRank
                )
            }
            return BrowserTabSessionSnapshotTab(
                id: tab.syncID, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970,
                pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: tab.title.isEmpty ? nil : tab.title
            )
        }
        for (tab, snapshot) in zip(logicalTabs, snapshots) {
            guard let binding = pendingRemoteTabCreations[tab.id] else { continue }
            pendingRemoteTabCreations[tab.id] = RemoteTabCreation(snapshot: snapshot, generation: binding.generation)
        }
        if let projection = remoteProjectionSnapshot {
            remoteProjectionSnapshot = BrowserTabSessionSnapshot(
                spaces: projection.spaces, pinnedTabFolders: projection.pinnedTabFolders, tabs: snapshots
            )
        }
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
        tab.pinnedSiblingRank = snapshot.placement == .spacePinned ? snapshot.pinnedSiblingRank : nil
        if let activity = lastActivityDate(from: snapshot), activity.timeIntervalSince1970.isFinite {
            // The shared projection already reconciled canonical and pending
            // activity. Keep it when publishing the live-engine projection.
            tab.lastActivityAt = activity
        }
        if tab.creationState != .ready, !tab.hasPendingLocalNavigation,
           tab.urlString != snapshot.urlString
        {
            tabDriver.navigateTab(withID: tab.id, toURLString: resolvedBrowserURLString(snapshot.urlString))
            tab.urlString = snapshot.urlString
            tab.title = ""
            tab.faviconURLString = nil
        }
        // Attached engines keep their live URL/history. Before attachment a
        // remote URL initializes the page unless the user already chose a target.
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
            id: id, syncID: syncID, spaceID: Self.defaultSpaceID,
            title: urlString == binding.snapshot.urlString ? title : "",
            urlString: binding.snapshot.urlString,
            lastActivityAt: lastActivityDate(from: binding.snapshot) ?? dateProvider()
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
        splitGroups = restoredSplitGroups(from: snapshot)
        let selectedSpaceIndex = sessionPreferencesStore.loadSelectedSpaceIndex(
            spaceCount: spaces.count
        ) ?? 0
        selectedSpaceID = spaces.indices.contains(selectedSpaceIndex) ? spaces[selectedSpaceIndex].id : spaces.first?.id
        pendingRestoredSelectedTabIndex = sessionPreferencesStore.loadSelectedTabIndex(
            tabCount: snapshot.tabs.count
        )
        pendingRestoredSpaces = snapshot.spaces ?? []
        let splitMemberSyncIDs = Set((snapshot.splitGroups ?? []).flatMap(\.tabIDs))
        for (index, tabSnapshot) in snapshot.tabs.enumerated() {
            let placement = tabSnapshot.placement
            // Pinned tabs come back unloaded, with their last title,
            // and load when first shown. The shown tab and split panes load now;
            // Favorites, a handful of app tiles that often notify, stay loaded.
            let restoresUnloaded = placement == .spacePinned && index != pendingRestoredSelectedTabIndex
                && !(tabSnapshot.id.map(splitMemberSyncIDs.contains) ?? false)
            let engineID = restoresUnloaded
                ? UUID().uuidString
                : tabDriver.createTab(
                    withURLString: tabSnapshot.urlString,
                    makeActive: index == pendingRestoredSelectedTabIndex
                )
            restoredTabCreationIDs.insert(engineID)
            if restoresUnloaded {
                closedPinnedTabIDs.insert(engineID)
            }
            tabs.append(Tab(
                id: engineID,
                syncID: tabSnapshot.id ?? tabSyncIDProvider(),
                spaceID: tabSnapshot.spaceID ?? selectedSpaceID ?? Self.defaultSpaceID,
                title: tabSnapshot.pageTitle ?? "",
                userTitleOverride: tabSnapshot.userTitleOverride,
                urlString: tabSnapshot.urlString,
                pinnedURLString: placement == .spacePinned
                    ? normalizedPinnedURLString(from: tabSnapshot.pinnedURLString ?? tabSnapshot.urlString)
                    : nil,
                placement: placement,
                pinnedFolderID: tabSnapshot.pinnedFolderID,
                pinnedSiblingRank: tabSnapshot.pinnedSiblingRank,
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

    private func syncMoveIntent(for payload: BrowserSidebarDragPayload) -> BrowserSyncMoveIntent? {
        switch payload.primary {
        case .folder(let id): BrowserSyncMoveIntent(items: [.init(entityType: .folder, entityID: id)])
        case .tab: syncMoveIntent(forTabIDs: payload.tabIDs)
        }
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
        guard isContextReady, isPersistenceEnabled, !isRestoringSession, !isReconcilingRemoteProjection,
              !isCompletingTabClose
        else {
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

    @discardableResult private func persistSessionWrite(
        _ write: BrowserSessionWrite, schedulesPush: Bool,
        onCommit: (() -> Void)? = nil
    ) -> Bool {
        isSessionClosurePrepared = false
        guard isPersistenceEnabled, !hasDiscardedSessionForClosure, !sessionWriteBuffer.isTerminal else { return false }
        if let onCommit {
            pendingSessionCompletions.append(.init(write: write, completion: onCommit))
        }
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
        sessionPersistenceFailure = historyRestoreFailure
        if wasBlocked, !hasUncommittedSessionWrites {
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
        let completed = pendingSessionCompletions.filter { writes.contains($0.write) }
        pendingSessionCompletions.removeAll { writes.contains($0.write) }
        for action in completed {
            action.completion()
        }
        return true
    }

    private func publishSessionPersistenceFailure() {
        sessionPersistenceFailure = sessionWriteBuffer.failure ?? historyRestoreFailure
        deferredRemoteSyncSnapshot = nil
        syncCoordinator?.setLocalPersistenceBlocked(true)
    }

    private func snapshotPreservingPendingRemoteCreations() -> BrowserTabSessionSnapshot {
        let current = currentSessionSnapshot()
        guard let remoteProjectionSnapshot else { return current }
        var mergedTabs = current.tabs
        let pendingByID = Dictionary(uniqueKeysWithValues: pendingRemoteTabCreations.values.compactMap { binding in
            binding.snapshot.id.map { ($0, binding.snapshot) }
        })
        // Place pending creations before their next surviving remote sibling.
        // Existing tabs keep the user's current relative order, including moves
        // and deletions performed while the engine creates remote tabs.
        for (index, tab) in remoteProjectionSnapshot.tabs.enumerated().reversed() {
            guard let id = tab.id, let pending = pendingByID[id] else { continue }
            let followingIDs = remoteProjectionSnapshot.tabs.dropFirst(index + 1).compactMap(\.id)
            let insertion = followingIDs.lazy
                .compactMap { nextID in
                    mergedTabs.firstIndex { $0.id == nextID }
                }
                .first ?? mergedTabs.count
            mergedTabs.insert(pending, at: insertion)
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
            tabs: mergedTabs,
            splitGroups: current.splitGroups
        )
    }

    private func currentSessionSnapshot() -> BrowserTabSessionSnapshot {
        if !isRestoringSession {
            pruneSplitGroupsIfNeeded()
        }
        var tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
        var snapshotTabs = tabs
        // Pending remote tabs may not have a model row yet. Preserve known ranks
        // so a metadata save cannot compact their still-occupied sibling slots.
        tree.assignPinnedRanks(to: &snapshotTabs, preservingExistingRanks: true)
        return BrowserTabSessionSnapshot(
            spaces: spaces.map { space in
                BrowserSpaceSessionSnapshot(
                    id: space.id,
                    title: space.title,
                    systemImageName: space.systemImageName,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                    selectedTabIndex: selectedTabIndex(inSpace: space.id)
                )
            },
            pinnedTabFolders: pinnedTabFolders.compactMap { tree.folders[$0.id] }.map { folder in
                BrowserPinnedTabFolderSessionSnapshot(
                    id: folder.id,
                    spaceID: folder.spaceID,
                    parentFolderID: folder.parentFolderID,
                    title: folder.title,
                    systemImageName: folder.systemImageName,
                    isExpanded: folder.isExpanded,
                    pinnedSiblingRank: folder.pinnedSiblingRank
                )
            },
            tabs: snapshotTabs.map { tab in
                BrowserTabSessionSnapshotTab(
                    id: tab.syncID,
                    urlString: tab.urlString,
                    pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride,
                    placement: tab.placement,
                    spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID,
                    lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970,
                    pinnedSiblingRank: tab.pinnedSiblingRank,
                    pageTitle: tab.title.isEmpty ? nil : tab.title
                )
            },
            splitGroups: splitGroupSessionSnapshots()
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
        // The returned ID already identifies a logical tab. Persist it before
        // another user action can target it, independently of the allocation callback.
        handleCreatedTab(id: tabID, title: "", urlString: resolvedURLString, isActive: true)
        pendingHydratedTabCreationIDs.insert(tabID)
    }

    private func openResolvedSelectionInNewTab(_ resolvedURLString: String) {
        let pending = takePendingSplitAnchor()
        createTab(withURLString: resolvedURLString)
        if let pending, let tabID = selectedTabID, tabID != pending.anchorID {
            openInSplitView(tabID: tabID, anchorTabID: pending.anchorID, insertion: pending.insertion)
        }
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

        if let pending = takePendingSplitAnchor(), openInSplitView(
            tabID: tab.id,
            anchorTabID: pending.anchorID,
            insertion: pending.insertion
        ) {
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

        navigateSelectedTab(toURLString: urlString)
    }

    @discardableResult private func navigateSelectedTab(toURLString urlString: String) -> Bool {
        guard canCreateTab, let index = selectedTabIndex else { return false }
        let resolvedURL = resolvedBrowserURLString(urlString)
        let id = tabs[index].id
        guard tabDriver.navigateTab(withID: id, toURLString: resolvedURL) else { return false }
        guard tabs[index].creationState != .ready || pendingTabCloseRequests[id]?.localAutomaticCandidate != nil
        else { return true }

        // Preserve the intent even if there is no engine yet, the process exits,
        // or creation is refused. Engine callbacks are not the durable owner.
        tabs[index].hasPendingLocalNavigation = true
        if tabs[index].urlString != resolvedURL {
            tabs[index].urlString = resolvedURL
            tabs[index].title = ""
            tabs[index].faviconURLString = nil
            tabs[index].lastActivityAt = advancedActivityDate(after: tabs[index].lastActivityAt)
            invalidateSelectedTabWebAppInstallMetadata()
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
        }
        if tabs[index].creationState == .failed {
            retrySelectedTabCreation()
        }
        return true
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
        case .toggleSplitOrientation:
            splitOrientationToggleTitle
        case .toggleSidebarPosition:
            sidebarPositionToggleTitle
        case .expandCurrentSplit:
            isSelectedSplitPaneExpanded ? BrowserStrings.menuShowAllSplitPanes : BrowserStrings.menuExpandCurrentSplit
        case .toggleSiteToolbar:
            siteToolbarToggleTitle
        case .togglePinTab:
            pinToggleTitle
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
        case .openLocation:
            canOpenLocation
        case .zoomIn:
            canZoomIn
        case .zoomOut:
            canZoomOut
        case .resetZoom:
            canResetZoom
        case .stopLoading:
            canStopLoading
        case .developerTools:
            canShowDeveloperTools
        case .restoreLastClosedTab:
            canRestoreLastClosedTab
        case .newIncognitoWindow:
            !isShuttingDown
        case .openHistory:
            canCreateTab && !isShuttingDown
        case .toggleBookmark:
            selectedTab?.urlString.isEmpty == false
        case .archiveTab:
            canArchiveSelectedTab
        case .viewArchive:
            canBrowseArchive
        case .clearArchive:
            canBrowseArchive && !isArchiveOperationInFlight
        case .savePage:
            canSavePage
        case .printPage:
            canPrintPage
        case .copyLink, .copyLinkAsMarkdown:
            canCopySelectedTabLink
        case .findInPage:
            canPresentFindInPage
        case .findAndReplace, .jumpToSelection:
            false
        case .findNext, .findPrevious:
            canStepThroughFindMatches
        case .clearTemporaryTabs:
            canClearTemporaryTabs
        case .viewDownloads:
            onToggleDownloads != nil
        case .togglePinTab:
            canTogglePinSelectedTab
        case .duplicateTab:
            selectedTabID.map { canDuplicateTab(id: $0) } ?? false
        case .renameTab:
            canRenameSelectedTab
        case .resetTabToPinnedURL:
            canResetSelectedTabToPinnedURL
        case .collapseAllFolders:
            canSetActiveSpaceFoldersExpanded(false)
        case .expandAllFolders:
            canSetActiveSpaceFoldersExpanded(true)
        case .newSpace:
            supportsSpaces && !isShuttingDown
        case .newFolder:
            canCreateFolderFromSelectedTab
        case .captureFullPage:
            canCreateTab && selectedTabID != nil
        case .selectNextTab, .selectPreviousTab, .goToLastSidebarItem:
            !sidebarItemTabIDs.isEmpty
        case .selectNextTabAlternate, .selectPreviousTabAlternate:
            // The command bar lists Next/Previous Tab once.
            false
        case .selectNextSpace, .selectPreviousSpace:
            supportsSpaces && spaces.count > 1
        case .revealCurrentTab:
            canRevealSelectedTab
        case .openExtensions:
            canOpenExtensions
        case .goToSidebarItem1, .goToSidebarItem2, .goToSidebarItem3, .goToSidebarItem4,
             .goToSidebarItem5, .goToSidebarItem6, .goToSidebarItem7, .goToSidebarItem8:
            sidebarItemTabIDs.count > commandID.sidebarItemIndex
        case .goBack:
            canGoBack
        case .goForward:
            canGoForward
        case .clearCacheAndRefresh, .clearCookiesAndRefresh, .forceReload, .reload:
            canReload
        case .addSplitView:
            canAddSplitView
        case .closeSplitPane, .separateSplitView, .separateTabFromSplit, .toggleSplitOrientation:
            selectedSplitGroup != nil && !isShuttingDown
        case .focusSplitPane1, .focusSplitPane2, .focusSplitPane3, .focusSplitPane4:
            selectedSplitGroup.map { splitPaneTabIDs(of: $0).count > commandID.splitPaneIndex } == true
        case .focusNextSplitPane, .focusPreviousSplitPane, .expandCurrentSplit:
            selectedSplitGroup != nil
        case .toggleSidebar:
            true
        case .toggleSidebarPosition:
            !isWebApp
        case .toggleBookmarksBar:
            true
        case .toggleSiteToolbar:
            !isWebApp
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
            pinnedSiblingRank: undoSnapshot.tab.pinnedSiblingRank,
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
            pinnedSiblingRank: tab.pinnedSiblingRank,
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
        pendingReopenedAppTabCreations[newTabID] = .init(previousID: id, titleAtRequest: tab.title)
        tabs[index] = reidentifiedAppTab(
            from: tab,
            id: newTabID,
            lastActivityAt: advancedActivityDate(after: tab.lastActivityAt)
        )
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

        // A tab closed by the user was reset to its pinned URL; one restored
        // unloaded keeps the page it showed last.
        let urlString = tab.urlString.isEmpty ? pinnedURLString : tab.urlString
        let newTabID = tabDriver.createTab(
            withURLString: resolvedBrowserURLString(urlString),
            makeActive: true
        )
        pendingReopenedPinnedTabCreations[newTabID] = .init(previousID: id, titleAtRequest: tab.title)
        tabs[index] = reidentifiedPinnedTab(
            from: tab,
            id: newTabID,
            urlString: urlString,
            lastActivityAt: advancedActivityDate(after: tab.lastActivityAt)
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

    private func handleReopenedPersistentTabCreated(id: String, title: String, urlString: String) {
        // Reopen publishes its logical identity and selection before allocation.
        // A delayed placeholder must not replay its old placement or selection,
        // nor revive an engine that has already completed another unload.
        guard let creation = pendingReopenedAppTabCreations[id] ?? pendingReopenedPinnedTabCreations[id] else { return }
        // Archive controls also depend on the pending binding. Publish its
        // completion even if newer metadata makes the title callback obsolete.
        objectWillChange.send()
        retireTabCreationCallbacks(id: id)
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].title == creation.titleAtRequest, tabs[index].urlString == urlString else { return }
        tabs[index].title = title
        updateWindowTitle()
    }

    private func replaceTabRuntimeReferences(
        oldID: String, newID: String, spaceID: String, selectsInSpace: Bool = true
    ) {
        if selectedTabID == oldID {
            selectedTabID = newID
        }

        for index in spaces.indices where spaces[index].selectedTabID == oldID {
            spaces[index].selectedTabID = newID
        }
        if selectsInSpace {
            setSelectedTabID(newID, forSpaceID: spaceID)
        }

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

    private func registerTabCreationUndo(_ reference: TabCreationUndoReference, actionName: String) {
        guard canRegisterTabUndo else { return }
        undoManager.registerTabAction(creationUndoAction(reference, actionName: actionName))
    }

    private func registerTabCloseUndo(
        _ snapshot: TabUndoSnapshot, archiveID: String?, kind: TabHistoryKind, actionName: String
    ) {
        guard canRegisterTabUndo else { return }
        undoManager.registerTabAction(historyRestoreAction(
            snapshot, archiveID: archiveID, kind: kind, actionName: actionName
        ))
    }

    private func creationUndoAction(
        _ reference: TabCreationUndoReference, actionName: String
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self else { completion(.cancelled)
                return
            }
            guard let id = reference.currentTabID, tabs.contains(where: { $0.id == id }) else {
                completion(.committed(inverse: nil))
                return
            }
            let admitted = requestConfirmedTabClose(
                id: id, registersUndo: false, actionName: actionName,
                createsArchive: false, preservesPersistentTab: false, historyKind: .creation
            ) { [weak self] result in
                guard let self else { completion(.cancelled)
                    return
                }
                switch result {
                case .cancelled: completion(.cancelled)
                case .removed: completion(.committed(inverse: nil))
                case .closed(let snapshot, _):
                    completion(.committed(inverse: historyRestoreAction(
                        snapshot, archiveID: nil, kind: .creation, actionName: actionName
                    )))
                }
            }
            if !admitted {
                completion(.cancelled)
            }
        }
    }

    private func archiveRedoAction(syncID: String, actionName: String) -> BrowserTabUndoManager.Action {
        closeRedoAction(syncID: syncID, kind: .archive, actionName: actionName)
    }

    private func logicalRemovalRedoAction(syncID: String, actionName: String) -> BrowserTabUndoManager.Action {
        closeRedoAction(syncID: syncID, kind: .logicalRemoval, actionName: actionName)
    }

    private func closeRedoAction(
        syncID: String, kind: TabHistoryKind, actionName: String
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self else { completion(.cancelled)
                return
            }
            guard let tab = tabs.first(where: { $0.syncID == syncID }),
                  kind == .logicalRemoval || tab.placement == .temporary
            else {
                completion(.committed(inverse: nil))
                return
            }
            let admitted = requestConfirmedTabClose(
                id: tab.id, registersUndo: false, actionName: actionName,
                createsArchive: kind == .archive, preservesPersistentTab: kind == .archive,
                historyKind: kind
            ) { [weak self] result in
                guard let self else { completion(.cancelled)
                    return
                }
                switch result {
                case .cancelled: completion(.cancelled)
                case .removed: completion(.committed(inverse: nil))
                case .closed(let snapshot, let archiveID):
                    completion(.committed(inverse: historyRestoreAction(
                        snapshot, archiveID: archiveID, kind: kind, actionName: actionName
                    )))
                }
            }
            if !admitted {
                completion(.cancelled)
            }
        }
    }

    private func historyRestoreAction(
        _ snapshot: TabUndoSnapshot, archiveID: String?, kind: TabHistoryKind, actionName: String
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self, pendingHistoryRestore == nil, canCreateTab,
                  !hasUncommittedSessionWrites
            else { completion(.cancelled)
                return
            }
            pendingHistoryRestore = PendingHistoryRestore(
                archiveID: archiveID, syncID: tabSyncIDProvider(), snapshot: snapshot,
                kind: kind, actionName: actionName, completion: completion
            )
            _ = retryHistoryRestore()
        }
    }

    /// A failed restore has not changed the live tree. Retry keeps its identities
    /// and rebuilds the snapshot from current edits instead of buffering a stale
    /// full snapshot that could erase later tabs or consume the entry twice.
    @discardableResult private func retryHistoryRestore() -> Bool {
        guard let request = pendingHistoryRestore, canCreateTab, isPersistenceEnabled,
              !hasDiscardedSessionForClosure, sessionWriteBuffer.writes.isEmpty,
              !isRestoringSession, !isApplyingRemoteSync, !isReconcilingRemoteProjection,
              !isArchiveOperationInFlight, pendingRemoteTabCreations.isEmpty else { return false }
        do {
            let original = request.snapshot.tab
            var archived: BrowserTabArchiveEntry?
            if let archiveID = request.archiveID {
                guard let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else {
                    throw BrowserTabArchiveError.unsupportedStore
                }
                guard let entry = try archive.loadArchiveEntry(id: archiveID) else {
                    archiveError = BrowserStrings.archiveEntryMissing
                    finishHistoryRestore(request, outcome: .committed(inverse: nil))
                    archiveRevision &+= 1
                    return true
                }
                archived = entry
            }
            let destination: String
            if spaces.contains(where: { $0.id == original.spaceID }) {
                destination = original.spaceID
            } else if request.archiveID == nil, let fallback = selectedSpaceID ?? spaces.first?.id {
                destination = fallback
            } else {
                archiveError = BrowserStrings.archiveDestinationMissing
                finishHistoryRestore(request, outcome: .cancelled)
                return false
            }
            guard !request.syncID.isEmpty, request.syncID != original.syncID,
                  !tabs.contains(where: { $0.syncID == request.syncID })
            else {
                throw BrowserTabArchiveError.restoredTabIDNotFresh
            }
            let now = dateProvider().timeIntervalSince1970.rounded(.down)
            guard now.isFinite else { throw BrowserTabArchiveError.invalidEntry }
            let placement = archived == nil ? original.placement : .temporary
            let folderID = placement == .spacePinned && pinnedTabFolders
                .contains(where: { $0.id == original.pinnedFolderID && $0.spaceID == destination })
                ? original.pinnedFolderID
                : nil
            let restored = BrowserTabSessionSnapshotTab(
                id: request.syncID, urlString: archived?.tab.urlString ?? original.urlString,
                pinnedURLString: placement == .spacePinned ? original.pinnedURLString : nil,
                userTitleOverride: archived?.tab.userTitleOverride ?? original.userTitleOverride,
                placement: placement, spaceID: destination, pinnedFolderID: folderID,
                lastActivityTimestamp: now,
                pinnedSiblingRank: destination == original.spaceID && folderID == original.pinnedFolderID
                    ? original.pinnedSiblingRank
                    : nil,
                pageTitle: archived?.tab.pageTitle ?? original.pageTitle
            )
            let shouldSelect = request.snapshot.wasSelectedTab || selectedTabID == nil
            let outgoing = shouldSelect && canRecordExplicitViewingActivity && selectedTab?.creationState == .ready
                ? selectedTab
                : nil
            let outgoingDate = outgoing.map { advancedActivityDate(after: $0.lastActivityAt) }
            let current = currentSessionSnapshot()
            var nextTabs = current.tabs.map { tab in
                guard tab.id == outgoing?.syncID, let outgoingDate else { return tab }
                return BrowserTabSessionSnapshotTab(
                    id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: outgoingDate.timeIntervalSince1970,
                    pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: tab.pageTitle
                )
            }
            let insertionIndex = min(max(request.snapshot.insertionIndex, 0), nextTabs.count)
            nextTabs.insert(restored, at: insertionIndex)
            let next = BrowserTabSessionSnapshot(
                spaces: current.spaces?.map { space in
                    let selectedID: String?
                    if space.id == destination, request.snapshot.wasSelectedInSpace || shouldSelect {
                        selectedID = request.syncID
                    } else {
                        let runtimeID = spaces.first { $0.id == space.id }?.selectedTabID
                        selectedID = tabs.first { $0.id == runtimeID }?.syncID
                    }
                    let members = nextTabs.filter { $0.spaceID == space.id }
                    let visible = members.filter { $0.placement == .spacePinned } + members
                        .filter { $0.placement == .temporary }
                    return BrowserSpaceSessionSnapshot(
                        id: space.id, title: space.title, systemImageName: space.systemImageName,
                        isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                        selectedTabIndex: visible.firstIndex { $0.id == selectedID }
                    )
                }, pinnedTabFolders: current.pinnedTabFolders, tabs: nextTabs, splitGroups: current.splitGroups
            )
            try sessionSnapshotStore.writeSessionBatch([.init(
                snapshot: next, origin: .local(syncMove: nil),
                archiveAction: request.archiveID.map { .restore(archiveID: $0, tabID: request.syncID) }
            )])
            isSessionClosurePrepared = false
            let reference = publishHistoryRestoration(
                request, restored: restored, insertionIndex: insertionIndex,
                shouldSelect: shouldSelect, outgoing: outgoing, outgoingDate: outgoingDate
            )
            archiveError = nil
            if request.archiveID != nil {
                archiveRevision &+= 1
            }
            sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
            sessionPreferencesStore.saveSelectedTabIndex(next.tabs.firstIndex { $0.id == selectedTab?.syncID })
            syncCoordinator?.schedulePush(snapshot: next)
            let inverse: BrowserTabUndoManager.Action =
                switch request.kind {
                case .creation: creationUndoAction(reference, actionName: request.actionName)
                case .archive: archiveRedoAction(syncID: request.syncID, actionName: request.actionName)
                case .logicalRemoval: logicalRemovalRedoAction(syncID: request.syncID, actionName: request.actionName)
                }
            finishHistoryRestore(request, outcome: .committed(inverse: inverse))
            return true
        } catch {
            if error as? BrowserTabArchiveError == .entryMissing || error as? BrowserTabArchiveError ==
                .archiveAlreadyRestored
            {
                archiveError = BrowserStrings.archiveEntryMissing
                finishHistoryRestore(request, outcome: .committed(inverse: nil))
                archiveRevision &+= 1
                return true
            }
            var classification = BrowserSessionWriteBuffer()
            classification.recordFailure(error)
            historyRestoreFailure = classification.failure
            publishSessionPersistenceFailure()
            return false
        }
    }

    private func finishHistoryRestore(_ request: PendingHistoryRestore, outcome: BrowserTabUndoManager.Outcome) {
        pendingHistoryRestore = nil
        let wasBlocked = hasUncommittedSessionWrites
        historyRestoreFailure = nil
        sessionPersistenceFailure = sessionWriteBuffer.failure
        if wasBlocked, !hasUncommittedSessionWrites {
            deferredRemoteSyncSnapshot = nil
            syncCoordinator?.setLocalPersistenceBlocked(false)
            syncCoordinator?.schedulePull()
        }
        request.completion(outcome)
    }

    private func publishHistoryRestoration(
        _ request: PendingHistoryRestore, restored: BrowserTabSessionSnapshotTab, insertionIndex: Int,
        shouldSelect: Bool, outgoing: Tab?, outgoingDate: Date?
    ) -> TabCreationUndoReference {
        let wasRestoringSession = isRestoringSession
        isRestoringSession = true
        defer { isRestoringSession = wasRestoringSession }
        if let outgoingDate, let index = tabs.firstIndex(where: { $0.id == outgoing?.id }) {
            tabs[index].lastActivityAt = outgoingDate
        }
        let runtimeID = tabDriver.createTab(
            withURLString: resolvedBrowserURLString(restored.urlString), makeActive: shouldSelect
        )
        restoredTabCreationIDs.insert(runtimeID)
        let tab = Tab(
            id: runtimeID, syncID: request.syncID, spaceID: restored.spaceID ?? request.snapshot.tab.spaceID,
            title: request.snapshot.tab.title, userTitleOverride: restored.userTitleOverride,
            urlString: restored.urlString, pinnedURLString: restored.pinnedURLString,
            faviconURLString: request.snapshot.tab.faviconURLString, placement: restored.placement,
            pinnedFolderID: restored.pinnedFolderID, pinnedSiblingRank: restored.pinnedSiblingRank,
            lastActivityAt: Date(timeIntervalSince1970: restored.lastActivityTimestamp ?? 0)
        )
        tabs.insert(tab, at: min(insertionIndex, tabs.count))
        let reference = request.snapshot.creationUndoReference ?? TabCreationUndoReference(tabID: runtimeID)
        reference.currentTabID = runtimeID
        tabCreationUndoReferences[runtimeID] = reference
        if request.snapshot.wasSelectedInSpace || shouldSelect {
            setSelectedTabID(runtimeID, forSpaceID: tab.spaceID)
        }
        if shouldSelect {
            selectedSpaceID = tab.spaceID
            selectedTabID = runtimeID
            findResultMatchCount = nil
            recordSelectedTab(runtimeID)
        }
        updateWindowTitle()
        return reference
    }
}

// MARK: - Durable Archive

extension BrowserChromeModel {
    var canBrowseArchive: Bool {
        windowMode.persistsSession && isPersistenceEnabled && !isShuttingDown && !hasDiscardedSessionForClosure &&
            sessionSnapshotStore is any BrowserTabArchiveStoring
    }

    var canRestoreArchivedTab: Bool {
        canBrowseArchive && canCreateTab && !isArchiveOperationInFlight && !hasUncommittedSessionWrites &&
            !undoManager.isTabTransitionPending &&
            !isRestoringSession && !isApplyingRemoteSync && !isReconcilingRemoteProjection &&
            deferredRemoteSyncSnapshot == nil && pendingRemoteTabCreations.isEmpty &&
            pendingCreatedTabContexts.isEmpty && pendingHydratedTabCreationIDs.isEmpty &&
            pendingReopenedAppTabCreations.isEmpty && pendingReopenedPinnedTabCreations.isEmpty
    }

    func loadArchivedTabs(
        query: String, before: BrowserTabArchiveCursor? = nil, limit: Int = 50
    ) async throws -> BrowserTabArchivePage {
        guard canBrowseArchive, let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try await archive.searchArchivePage(query: query, before: before, limit: limit)
    }

    func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        guard canBrowseArchive, let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try await archive.archiveClearBoundary()
    }

    @discardableResult func deleteArchivedTab(id: String) async -> Bool {
        guard canBrowseArchive, !isArchiveOperationInFlight,
              let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else { return false }
        isArchiveOperationInFlight = true
        archiveError = nil
        defer { isArchiveOperationInFlight = false }
        do {
            _ = try await archive.removeArchiveEntry(id: id)
            archiveRevision &+= 1
            return true
        } catch {
            archiveError = BrowserStrings.archiveActionFailed
            return false
        }
    }

    @discardableResult func clearArchive(through boundary: BrowserTabArchiveBoundary) async -> Bool {
        guard canBrowseArchive, !isArchiveOperationInFlight,
              let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else { return false }
        isArchiveOperationInFlight = true
        archiveError = nil
        defer { isArchiveOperationInFlight = false }
        do {
            _ = try await archive.clearArchive(through: boundary)
            archiveRevision &+= 1
            return true
        } catch {
            archiveError = BrowserStrings.archiveActionFailed
            return false
        }
    }

    func syncArchiveDidChange() {
        guard canBrowseArchive else { return }
        archiveRevision &+= 1
    }

    /// Commit the new identity and consume its recovery entry together before
    /// allocating an engine. Failed storage has no optimistic state to replay:
    /// an explicit Retry rebuilds this action against the latest live snapshot.
    @discardableResult func restoreArchivedTab(id: String, toSpaceID: String? = nil) -> String? {
        guard canRestoreArchivedTab, let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else {
            archiveError = BrowserStrings.archiveUnavailable
            return nil
        }
        isArchiveOperationInFlight = true
        archiveError = nil
        defer { isArchiveOperationInFlight = false }
        do {
            guard let entry = try archive.loadArchiveEntry(id: id) else {
                archiveError = BrowserStrings.archiveEntryMissing
                archiveRevision &+= 1
                return nil
            }
            guard let destination = toSpaceID ?? entry.tab.spaceID,
                  spaces.contains(where: { $0.id == destination })
            else {
                archiveError = BrowserStrings.archiveDestinationMissing
                return nil
            }
            let syncID = tabSyncIDProvider()
            guard !syncID.isEmpty, syncID != entry.tab.id, !tabs.contains(where: { $0.syncID == syncID })
            else { throw BrowserTabArchiveError.restoredTabIDNotFresh }
            let now = dateProvider().timeIntervalSince1970.rounded(.down)
            guard now.isFinite else { throw BrowserTabArchiveError.invalidEntry }
            let snapshot = currentSessionSnapshot()
            let outgoing = canRecordExplicitViewingActivity && selectedTab?.creationState == .ready ? selectedTab : nil
            let outgoingDate = outgoing.map { advancedActivityDate(after: $0.lastActivityAt) }
            let restored = BrowserTabSessionSnapshotTab(
                id: syncID, urlString: entry.tab.urlString, userTitleOverride: entry.tab.userTitleOverride,
                placement: .temporary, spaceID: destination, lastActivityTimestamp: now, pageTitle: entry.tab.pageTitle
            )
            let nextTabs = snapshot.tabs.map { tab in
                guard tab.id == outgoing?.syncID, let outgoingDate else { return tab }
                return BrowserTabSessionSnapshotTab(
                    id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: outgoingDate.timeIntervalSince1970,
                    pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: tab.pageTitle
                )
            } + [restored]
            let next = BrowserTabSessionSnapshot(
                spaces: snapshot.spaces?.map { space in
                    guard space.id == destination else { return space }
                    return BrowserSpaceSessionSnapshot(
                        id: space.id, title: space.title, systemImageName: space.systemImageName,
                        isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                        selectedTabIndex: nextTabs.filter { $0.spaceID == destination && $0.placement != .app }
                            .count - 1
                    )
                }, pinnedTabFolders: snapshot.pinnedTabFolders, tabs: nextTabs, splitGroups: snapshot.splitGroups
            )
            // Archive transitions cannot be buffered independently of the live
            // tree: a later full snapshot could otherwise drop a consumed restore.
            try sessionSnapshotStore.writeSessionBatch([.init(
                snapshot: next, origin: .local(syncMove: nil), archiveAction: .restore(archiveID: id, tabID: syncID)
            )])
            isSessionClosurePrepared = false
            publishArchivedTab(entry: entry, restored: restored, outgoing: outgoing, outgoingDate: outgoingDate)
            archiveRevision &+= 1
            sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
            sessionPreferencesStore.saveSelectedTabIndex(next.tabs.firstIndex { $0.id == syncID })
            syncCoordinator?.schedulePush(snapshot: next)
            return syncID
        } catch {
            archiveError = (error as? BrowserTabArchiveError) == .entryMissing ||
                (error as? BrowserTabArchiveError) == .archiveAlreadyRestored
                ? BrowserStrings.archiveEntryMissing
                : BrowserStrings.archiveRestoreFailed
            return nil
        }
    }

    private func publishArchivedTab(
        entry: BrowserTabArchiveEntry, restored: BrowserTabSessionSnapshotTab, outgoing: Tab?, outgoingDate: Date?
    ) {
        guard let syncID = restored.id, let destination = restored.spaceID,
              let activity = restored.lastActivityTimestamp else { return }
        // Suppress incidental selection persistence during this synchronous
        // publication; its complete snapshot already committed with the receipt.
        isRestoringSession = true
        defer { isRestoringSession = false }
        if let outgoingDate, let index = tabs.firstIndex(where: { $0.id == outgoing?.id }) {
            tabs[index].lastActivityAt = outgoingDate
        }
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()
        dismissFindBar()
        invalidateSelectedTabWebAppInstallMetadata()
        let runtimeID = tabDriver.createTab(
            withURLString: resolvedBrowserURLString(restored.urlString),
            makeActive: true
        )
        restoredTabCreationIDs.insert(runtimeID)
        tabs.append(Tab(
            id: runtimeID, syncID: syncID, spaceID: destination, title: entry.title ?? "",
            userTitleOverride: restored.userTitleOverride, urlString: restored.urlString,
            placement: .temporary, lastActivityAt: Date(timeIntervalSince1970: activity)
        ))
        selectedSpaceID = destination
        selectedTabID = runtimeID
        setSelectedTabID(runtimeID, forSpaceID: destination)
        findResultMatchCount = nil
        recordSelectedTab(runtimeID)
        updateWindowTitle()
    }
}

// MARK: BrowserSyncExpiryScheduling

extension BrowserChromeModel: BrowserSyncExpiryScheduling {
    func expirySchedulingState() -> BrowserSyncExpirySchedulingState? {
        guard canBrowseArchive, automaticArchivalSettingsLoaded, !isArchiveOperationInFlight,
              isViewingActivityActive, isContextReady, isPersistenceEnabled, !isShuttingDown,
              !isRestoringSession, !isApplyingRemoteSync, !isReconcilingRemoteProjection,
              deferredRemoteSyncSnapshot == nil, pendingRemoteTabCreations.isEmpty,
              pendingCreatedTabContexts.isEmpty, pendingHydratedTabCreationIDs.isEmpty,
              pendingReopenedAppTabCreations.isEmpty, pendingReopenedPinnedTabCreations.isEmpty,
              !hasUncommittedSessionWrites, pendingTabCloseRequests.isEmpty,
              tabs
                  .allSatisfy({
                      $0.creationState == .ready || closedAppTabIDs.contains($0.id) || closedPinnedTabIDs
                          .contains($0.id) })
        else { return nil }
        let visibleIDs = Set(selectedTabID.map { splitPaneTabIDs(forTabID: $0) } ?? [])
        let protectedIDs = Set(tabs.filter { visibleIDs.contains($0.id) }.map(\.syncID))
        guard let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading else { return nil }
        let owner: BrowserSyncOwner?
        do { owner = try ownership.syncOwner() } catch { return nil }
        return .init(
            inactiveForSeconds: owner != nil && automaticTabArchivalEnabled
                ? Int(temporaryTabLifetime.timeInterval)
                : nil,
            protectedTabIDs: protectedIDs
        )
    }

    func refreshExpiryActivity() -> Bool {
        guard expirySchedulingState() != nil else { return false }
        persistCurrentViewingActivity()
        return !hasUncommittedSessionWrites
    }
}

@MainActor private extension BrowserChromeModel {
    var canRecordViewingActivity: Bool {
        canRecordExplicitViewingActivity && !isApplyingRemoteSync
    }

    var canRecordExplicitViewingActivity: Bool {
        isViewingActivityActive && isContextReady && isPersistenceEnabled && !isShuttingDown &&
            !isRestoringSession && !isReconcilingRemoteProjection
    }

    @discardableResult func recordExplicitViewingActivity(ids: [String?]) -> Bool {
        guard canRecordExplicitViewingActivity else { return false }
        var changed = false
        for id in Set(ids.compactMap { $0 }) {
            if touchTab(id: id) {
                changed = true
            }
        }
        return changed
    }

    func advancedActivityDate(after previous: Date) -> Date {
        let now = dateProvider().timeIntervalSince1970.rounded(.down)
        guard now.isFinite else { return previous }
        let old = previous.timeIntervalSince1970
        return !old.isFinite || now > old ? Date(timeIntervalSince1970: now) : previous
    }

    @discardableResult func recordCurrentViewingActivity() -> Bool {
        guard canRecordExplicitViewingActivity, let selectedTabID,
              selectedTab?.creationState == .ready
        else { return false }
        return touchTab(id: selectedTabID)
    }

    func persistCurrentViewingActivity() {
        if recordCurrentViewingActivity() {
            persistCurrentSessionIfAllowed()
        }
    }

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
        if let splitSiblingID = splitSiblingTabID(afterClosing: closingTab, excluding: []) {
            return splitSiblingID
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
        if let splitSiblingID = splitSiblingTabID(
            afterClosing: closingTab,
            excluding: excludedTabIDs.union(closedPinnedTabIDs)
        ) {
            return splitSiblingID
        }
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
        if pendingHydratedTabCreationIDs.remove(id) != nil {
            if let index = tabs.firstIndex(where: { $0.id == id }),
               tabs[index].title.isEmpty, tabs[index].urlString == urlString
            {
                tabs[index].title = title
                updateWindowTitle()
            }
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
        if pendingReopenedPinnedTabCreations[id] != nil || pendingReopenedAppTabCreations[id] != nil {
            handleReopenedPersistentTabCreated(id: id, title: title, urlString: urlString)
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
                pinnedSiblingRank: undoSnapshot?.tab.pinnedSiblingRank,
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
            tabs[index].lastActivityAt = advancedActivityDate(after: tabs[index].lastActivityAt)
            didChangePersistentURL = true
            if id == selectedTabID {
                invalidateSelectedTabWebAppInstallMetadata()
                // Another site may have its own zoom.
                refreshZoomFromEngine()
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

    private func blocksTabInteraction(_ id: String) -> Bool {
        closingTabIDs.contains(id) && pendingTabCloseRequests[id]?.localAutomaticCandidate == nil
    }

    private func retireTabCreationCallbacks(id: String) {
        restoredTabCreationIDs.insert(id)
        pendingCreatedTabContexts.removeValue(forKey: id)
        pendingHydratedTabCreationIDs.remove(id)
        pendingReopenedAppTabCreations = pendingReopenedAppTabCreations
            .filter { $0.key != id && $0.value.previousID != id }
        pendingReopenedPinnedTabCreations = pendingReopenedPinnedTabCreations
            .filter { $0.key != id && $0.value.previousID != id }
    }

    private func replaceRuntimeAfterPreservedClose(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasCompleting = isCompletingTabClose
        isCompletingTabClose = true
        defer { isCompletingTabClose = wasCompleting }
        let selected = selectedTabID == tab.id
        let newID = tabDriver.createTab(withURLString: resolvedBrowserURLString(tab.urlString), makeActive: selected)
        // Both old and replacement allocation callbacks are placeholders. Neither
        // may manufacture another logical identity after a late/duplicate reply.
        retireTabCreationCallbacks(id: tab.id)
        restoredTabCreationIDs.insert(newID)
        closedAppTabIDs.remove(tab.id)
        closedPinnedTabIDs.remove(tab.id)
        tabs[index] = Tab(
            id: newID, syncID: tab.syncID, spaceID: tab.spaceID, title: tab.title,
            userTitleOverride: tab.userTitleOverride, urlString: tab.urlString,
            pinnedURLString: tab.pinnedURLString, faviconURLString: tab.faviconURLString,
            placement: tab.placement, pinnedFolderID: tab.pinnedFolderID,
            pinnedSiblingRank: tab.pinnedSiblingRank, lastActivityAt: tab.lastActivityAt
        )
        replaceTabRuntimeReferences(oldID: tab.id, newID: newID, spaceID: tab.spaceID, selectsInSpace: false)
        if selected {
            findResultMatchCount = nil
            invalidateSelectedTabWebAppInstallMetadata()
        }
        updateWindowTitle()
        // Runtime replacement changes no persistent identity, content or order.
    }

    private func handleTabCloseRequestFinished(id: String, requestID: String, outcome: BrowserTabCloseOutcome) {
        guard let request = pendingTabCloseRequests[id], request.requestID == requestID else { return }
        pendingTabCloseRequests.removeValue(forKey: id)
        closingTabIDs.remove(id)
        defer {
            if request.localAutomaticCandidate != nil {
                continueLocalAutomaticArchiveSweep()
            }
        }
        guard outcome == .closed else {
            request.completion?(.cancelled)
            return
        }
        guard !isShuttingDown, let tab = tabs.first(where: { $0.id == id }), tab.syncID == request.syncID else {
            request.completion?(.removed)
            return
        }
        if let candidate = request.localAutomaticCandidate {
            guard !request.invalidatedAutomaticClose, canAdmitLocalAutomaticArchive,
                  localAutomaticArchivalOwnershipAllowsClose(), tab.spaceID == candidate.spaceID,
                  tab.lastActivityAt == candidate.lastActivityAt, isLocalAutomaticArchiveEligible(tab)
            else {
                replaceRuntimeAfterPreservedClose(tab)
                return
            }
        }
        if request.unloadsPersistentTab, tab.placement == .temporary {
            // Unpinning while the page confirms must not turn an unload into a
            // deletion. Preserve the new logical state and replace its engine.
            replaceRuntimeAfterPreservedClose(tab)
            request.completion?(.removed)
            return
        }
        if tab.placement == .temporary || !request.preservesPersistentTab {
            // Capture current metadata and selection only after the final engine
            // callback. Cancellation never mutates the session or Undo history.
            finishTabClose(
                id: id, forceClose: false, requestsEngineClose: false,
                registersUndo: request.registersUndo, undoActionName: request.undoActionName,
                createsArchive: request.createsArchive, historyKind: request.historyKind,
                completion: request.completion
            )
        } else {
            // Pin/Favorite may have arrived while the page's dialog was open.
            // Keep that persistent identity; its already-closed engine is dormant.
            let wasCompletingTabClose = isCompletingTabClose
            isCompletingTabClose = true
            if tab.placement == .app {
                closeAppTabProcess(id: id, engineAlreadyClosed: true)
            } else {
                closePinnedTabProcessOrReset(id: id, engineAlreadyClosed: true)
            }
            isCompletingTabClose = wasCompletingTabClose
            persistCurrentSessionIfAllowed()
            request.completion?(.removed)
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
            return
        }

        if closedPinnedTabIDs.contains(id), closedTab?.placement == .spacePinned {
            updateWindowTitle()
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
        if isShuttingDown {
            // The driver acknowledges ready after this callback. Closing the
            // record first keeps that ACK from enabling its initial load.
            // Pending remote records may not have a logical tab yet.
            if state == .ready {
                tabDriver.closeTab(withID: id, forceClose: true)
            }
            return
        }
        guard !closingTabIDs.contains(id) || pendingTabCloseRequests[id] != nil,
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
        if state == .ready {
            tabs[index].hasPendingLocalNavigation = false
            if mutedTabSyncIDs.contains(tabs[index].syncID) {
                tabDriver.setAudioMuted(true, forTabWithID: id)
            }
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

    @discardableResult func touchTab(id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let updated = advancedActivityDate(after: tabs[index].lastActivityAt)
        guard updated != tabs[index].lastActivityAt else { return false }
        tabs[index].lastActivityAt = updated
        return true
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
                isExpanded: snapshot.isExpanded,
                pinnedSiblingRank: snapshot.pinnedSiblingRank
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
        let candidate = selectedTabIDForSpace.flatMap { tabID -> String? in
            guard tabs.contains(where: { $0.id == tabID && $0.spaceID == selectedSpaceID }) else {
                return nil
            }
            return tabID
        } ?? sidebarTabs(forSpaceID: selectedSpaceID).first?.id
        // An unloaded tab has no page to show: the Space's remembered tab, or
        // its first, loads through the same path as a click.
        if let candidate, closedPinnedTabIDs.contains(candidate) || closedAppTabIDs.contains(candidate) {
            selectTab(id: candidate)
            if let selectedTabID, tabs.first(where: { $0.id == selectedTabID })?.spaceID == selectedSpaceID {
                return
            }
        }
        let fallbackTabID = candidate

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
}

@MainActor private extension BrowserChromeModel {
    func tabSwitcherEntries() -> [TabSwitcherEntry] {
        pruneTabSwitcherTracking()

        guard
            let selectedTabID,
            tabs.contains(where: { $0.id == selectedTabID }),
            !blocksTabInteraction(selectedTabID),
            !closedAppTabIDs.contains(selectedTabID),
            !closedPinnedTabIDs.contains(selectedTabID)
        else {
            return []
        }

        var seenTabIDs = Set<String>()
        var orderedTabIDs = [String]()

        func appendTabID(_ tabID: String) {
            guard
                !blocksTabInteraction(tabID),
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
                    && !blocksTabInteraction($0.id)
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
            !blocksTabInteraction(tabID),
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
            .subtracting(closingTabIDs.filter { blocksTabInteraction($0) })
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
            !blocksTabInteraction(selectedTabID),
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
    /// Pane position of a Switch to Split Pane command, counted from 0.
    var splitPaneIndex: Int {
        switch self {
        case .focusSplitPane2: 1
        case .focusSplitPane3: 2
        case .focusSplitPane4: 3
        default: 0
        }
    }

    var commandBarSearchAliases: [String] {
        switch self {
        case .openSettings:
            ["settings", "preferences", "app settings", "native settings"]
        case .setAsDefaultBrowser:
            ["default browser", "set default browser", "make default browser"]
        case .newTab:
            ["new tab", "open tab", "create tab"]
        case .openLocation:
            ["open location", "edit url", "edit address", "current url", "address bar"]
        case .restoreLastClosedTab:
            ["restore tab", "reopen tab", "reopen closed tab", "last closed tab", "undo close tab"]
        case .zoomIn:
            ["zoom in", "bigger", "larger text"]
        case .zoomOut:
            ["zoom out", "smaller", "smaller text"]
        case .resetZoom:
            ["actual size", "reset zoom", "zoom 100"]
        case .stopLoading:
            ["stop", "stop loading"]
        case .developerTools:
            ["developer tools", "devtools", "inspect", "web inspector", "console"]
        case .newIncognitoWindow:
            ["incognito", "private window", "new private window"]
        case .openHistory:
            ["history", "open history", "browser history"]
        case .toggleBookmark:
            ["bookmark", "add bookmark", "remove bookmark", "star"]
        case .archiveTab:
            ["archive tab", "close tab", "close current tab"]
        case .viewArchive:
            ["view archive", "open archive", "archived tabs", "restore closed tabs"]
        case .clearArchive:
            ["clear archive", "empty archive", "delete archived tabs"]
        case .savePage:
            ["save page", "save as", "download page"]
        case .printPage:
            ["print page", "print current page"]
        case .copyLink:
            ["copy link", "copy url", "copy address", "copy current url"]
        case .copyLinkAsMarkdown:
            ["copy markdown", "markdown link", "copy url as markdown", "copy link as markdown"]
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
        case .viewDownloads:
            ["downloads", "view downloads", "show downloads", "downloaded files"]
        case .togglePinTab:
            ["pin tab", "unpin tab", "pin", "unpin"]
        case .duplicateTab:
            ["duplicate tab", "duplicate", "copy tab"]
        case .renameTab:
            ["rename tab", "rename"]
        case .resetTabToPinnedURL:
            ["reset tab", "original url", "pinned url", "back to pinned url"]
        case .collapseAllFolders:
            ["collapse folders", "collapse all folders", "close folders"]
        case .expandAllFolders:
            ["expand folders", "expand all folders", "open folders"]
        case .newSpace:
            ["new space", "create space", "add space"]
        case .newFolder:
            ["new folder", "create folder", "folder"]
        case .captureFullPage:
            ["capture", "screenshot", "capture full page", "full page screenshot"]
        case .selectNextTab:
            ["next tab", "select next tab"]
        case .selectPreviousTab:
            ["previous tab", "select previous tab"]
        case .selectNextTabAlternate, .selectPreviousTabAlternate:
            []
        case .revealCurrentTab:
            ["reveal current tab", "reveal tab", "show tab in sidebar", "find tab in sidebar"]
        case .openExtensions:
            ["extensions", "open extensions", "site controls", "control center"]
        case .selectNextSpace:
            ["next space", "switch space"]
        case .selectPreviousSpace:
            ["previous space", "switch space"]
        case .goToSidebarItem1, .goToSidebarItem2, .goToSidebarItem3, .goToSidebarItem4,
             .goToSidebarItem5, .goToSidebarItem6, .goToSidebarItem7, .goToSidebarItem8:
            ["tab \(sidebarItemIndex + 1)", "sidebar item \(sidebarItemIndex + 1)", "go to tab"]
        case .goToLastSidebarItem:
            ["last tab", "last sidebar item"]
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
        case .addSplitView:
            ["split view", "add split view", "new split", "split screen", "side by side"]
        case .closeSplitPane:
            ["close split pane", "close pane", "close split"]
        case .separateTabFromSplit:
            ["separate page", "separate tab", "remove from split", "unsplit tab"]
        case .separateSplitView:
            ["separate all tabs", "exit split view", "end split view", "unsplit"]
        case .toggleSplitOrientation:
            ["convert split", "vertical split", "horizontal split", "rotate split", "split orientation"]
        case .focusSplitPane1, .focusSplitPane2, .focusSplitPane3, .focusSplitPane4:
            ["split pane \(splitPaneIndex + 1)", "switch split pane", "focus pane"]
        case .focusNextSplitPane:
            ["next split pane", "next pane"]
        case .expandCurrentSplit:
            ["expand split", "maximize pane", "expand pane", "show all split panes"]
        case .focusPreviousSplitPane:
            ["previous split pane", "previous pane"]
        case .toggleSidebar:
            ["sidebar", "toggle sidebar", "show sidebar", "hide sidebar"]
        case .toggleSidebarPosition:
            ["sidebar right", "sidebar left", "move sidebar", "sidebar position", "right sidebar"]
        case .toggleBookmarksBar:
            ["bookmarks bar", "bookmark bar", "toggle bookmarks bar", "show bookmarks bar", "hide bookmarks bar"]
        case .toggleSiteToolbar:
            ["toolbar", "url bar", "address bar", "show toolbar", "hide toolbar"]
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
        case .openLocation:
            "link"
        case .restoreLastClosedTab:
            "arrow.uturn.backward.circle"
        case .zoomIn:
            "plus.magnifyingglass"
        case .zoomOut:
            "minus.magnifyingglass"
        case .resetZoom:
            "1.magnifyingglass"
        case .stopLoading:
            "xmark"
        case .developerTools:
            "hammer"
        case .newIncognitoWindow:
            "eye.slash"
        case .openHistory:
            "clock.arrow.circlepath"
        case .toggleBookmark:
            "star"
        case .archiveTab, .viewArchive:
            "archivebox"
        case .clearArchive:
            "trash"
        case .savePage:
            "square.and.arrow.down"
        case .printPage:
            "printer"
        case .copyLink:
            "link"
        case .copyLinkAsMarkdown:
            "text.badge.plus"
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
        case .viewDownloads:
            "arrow.down.circle"
        case .togglePinTab:
            "pin"
        case .duplicateTab:
            "plus.square.on.square"
        case .renameTab:
            "pencil"
        case .resetTabToPinnedURL:
            "arrow.uturn.backward"
        case .collapseAllFolders:
            "folder"
        case .expandAllFolders:
            "folder.fill"
        case .newSpace:
            "plus.rectangle.on.rectangle"
        case .newFolder:
            "folder.badge.plus"
        case .captureFullPage:
            "camera.viewfinder"
        case .selectNextTab:
            "arrow.down.square"
        case .selectPreviousTab, .selectPreviousTabAlternate:
            "arrow.up.square"
        case .selectNextTabAlternate:
            "arrow.down.square"
        case .revealCurrentTab:
            "scope"
        case .openExtensions:
            "puzzlepiece.extension"
        case .selectNextSpace:
            "arrow.right.square"
        case .selectPreviousSpace:
            "arrow.left.square"
        case .goToSidebarItem1, .goToSidebarItem2, .goToSidebarItem3, .goToSidebarItem4,
             .goToSidebarItem5, .goToSidebarItem6, .goToSidebarItem7, .goToSidebarItem8:
            "\(sidebarItemIndex + 1).circle"
        case .goToLastSidebarItem:
            "9.circle"
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
        case .addSplitView:
            "rectangle.split.2x1"
        case .closeSplitPane:
            "xmark.rectangle"
        case .separateSplitView, .separateTabFromSplit:
            "rectangle.on.rectangle"
        case .toggleSplitOrientation:
            "rectangle.split.1x2"
        case .focusSplitPane1, .focusSplitPane2, .focusSplitPane3, .focusSplitPane4:
            "\(splitPaneIndex + 1).square"
        case .focusNextSplitPane:
            "arrow.right.square"
        case .expandCurrentSplit:
            "arrow.up.left.and.arrow.down.right"
        case .focusPreviousSplitPane:
            "arrow.left.square"
        case .toggleSidebar:
            "sidebar.left"
        case .toggleSidebarPosition:
            "sidebar.right"
        case .toggleBookmarksBar:
            "book"
        case .toggleSiteToolbar:
            "menubar.rectangle"
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
        case "=":
            ["=", "equals", "plus"]
        case "-":
            ["-", "minus", "hyphen"]
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

// MARK: - BrowserMarkdownLink

enum BrowserMarkdownLink {
    /// A Markdown link whose title cannot end the link text early. An empty
    /// title falls back to the URL.
    static func text(title: String, urlString: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed.isEmpty ? urlString : trimmed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let destination = urlString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        return "[\(label)](\(destination))"
    }
}

