import AppKit
import Combine
import Foundation
import OSLog

private enum BrowserChromeCommandDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        category: "Commands"
    )

    static func rect(_ rect: CGRect) -> String {
        String(
            format: "(x:%.1f y:%.1f w:%.1f h:%.1f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }
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

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedTabID: String?
    @Published var isSidebarVisible = true
    @Published private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth
    @Published private(set) var temporaryTabLifetime: BrowserTemporaryTabLifetime

    let hostView: NSView
    lazy var commandBarModel: BrowserCommandBarModel = .init(
        suggestionProvider: commandBarSuggestionProvider,
        navigationResolver: navigationResolver,
        submitHandler: { [weak self] resolvedURLString in
            self?.openResolvedSelectionInNewTab(resolvedURLString)
        }
    )

    private let tabDriver: BrowserTabDriving
    private let sessionSnapshotStore: BrowserTabSessionSnapshotStoring
    private let sessionPreferencesStore: BrowserSessionPreferencesStoring
    private let newTabURLString: String
    private let commandBarSuggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
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

    var canCopySelectedTabLink: Bool {
        selectedTab != nil
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
        updateWindowTitle()
    }

    func handleContextReady() {
        guard !isContextReady else {
            return
        }

        isContextReady = true
        restoreSidebarWidthIfNeeded()
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
        persistCurrentSessionIfAllowed()
        isShuttingDown = true
        isPersistenceEnabled = false
    }

    func createNewTab() {
        createTab(withURLString: newTabURLString)
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

        commandBarModel.present()
    }

    func toggleCommandBar() {
        guard canCreateTab else {
            return
        }

        if commandBarModel.isPresented {
            commandBarModel.dismiss()
        } else {
            commandBarModel.present()
        }
    }

    func dismissCommandBar() {
        commandBarModel.dismiss()
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

    func hasTabsBelow(id: String) -> Bool {
        !tabIDsBelowInSidebarOrder(forTabID: id).isEmpty
    }

    func selectTab(id: String) {
        guard
            selectedTabID != id,
            !closingTabIDs.contains(id),
            tabs.contains(where: { $0.id == id })
        else {
            return
        }

        if commandBarModel.isPresented {
            commandBarModel.dismiss()
        }

        selectedTabID = id
        tabDriver.selectTab(withID: id)
        touchTab(id: id)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
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
        } else if selectedTabID == id {
            let fallbackTabID = fallbackTabID(afterClosingIndex: closingIndex)
            selectedTabID = fallbackTabID
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
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
        let nextVisibility = !isSidebarVisible
        let message = String(
            format: "toggleSidebar current=%@ next=%@ width=%.1f hostFrame=%@ hostBounds=%@",
            String(isSidebarVisible),
            String(nextVisibility),
            sidebarWidth,
            BrowserChromeCommandDiagnostics.rect(hostView.frame),
            BrowserChromeCommandDiagnostics.rect(hostView.bounds)
        )
        BrowserChromeCommandDiagnostics.logger.notice(
            "\(message, privacy: .public)"
        )
        isSidebarVisible = nextVisibility
    }

    func setSidebarWidth(_ width: CGFloat) {
        let clampedWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
        guard sidebarWidth != clampedWidth else {
            return
        }

        let message = String(
            format: "setSidebarWidth old=%.1f new=%.1f visible=%@ hostFrame=%@ hostBounds=%@",
            sidebarWidth,
            clampedWidth,
            String(isSidebarVisible),
            BrowserChromeCommandDiagnostics.rect(hostView.frame),
            BrowserChromeCommandDiagnostics.rect(hostView.bounds)
        )
        BrowserChromeCommandDiagnostics.logger.notice(
            "\(message, privacy: .public)"
        )
        sidebarWidth = clampedWidth
        persistCurrentSessionIfAllowed()
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
        sessionPreferencesStore.saveSidebarWidth(sidebarWidth)
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
        updateWindowTitle()
    }

    private func openResolvedSelectionInNewTab(_ resolvedURLString: String) {
        createTab(withURLString: resolvedURLString)
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
