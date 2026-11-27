// BrowserMobileWorkspace.swift

import Foundation
import UIKit

// MARK: - BrowserMobileTab

struct BrowserMobileTab: Identifiable, Equatable {
    let id: String
    let runtimeID: String
    var urlString: String
    var title: String
    var state: BrowserMobilePageState
    var spaceID: String?
    var placement = BrowserTabPlacement.temporary
    var pinnedFolderID: String?
    var userTitleOverride: String?
    /// A private tab lives only in this window's memory: it is never saved,
    /// synced or archived, and its page keeps website data in memory only.
    var isPrivate = false
}

// MARK: - BrowserMobileWorkspace

@MainActor final class BrowserMobileWorkspace {
    // MARK: Private

    private static let blankURL = URL(string: "about:blank")!

    // MARK: Internal

    var onChange: (() -> Void)?
    private(set) var tabs = [BrowserMobileTab]()
    private(set) var selectedTabID: String? {
        didSet {
            guard let selectedTabID, !keepsRecentOrder, recentTabIDs.first != selectedTabID else { return }
            recentTabIDs.removeAll { $0 == selectedTabID }
            recentTabIDs.insert(selectedTabID, at: 0)
            let privateIDs = Set(tabs.filter(\.isPrivate).map(\.id))
            scenePreferences?.set(recentTabIDs.filter { !privateIDs.contains($0) }, forKey: selectionKey + ".recent")
        }
    }

    /// Tabs this window showed, the latest first.
    private(set) var recentTabIDs = [String]()
    private(set) var isRestoring = false
    private(set) var isReady = false
    private(set) var sessionError: String?
    private(set) var navigationError: String?
    private(set) var javaScriptDialog: BrowserMobileJavaScriptDialog?
    private(set) var httpAuthentication: BrowserMobileHTTPAuthentication?
    private(set) var profileDocument: BrowserMobileProfileDocument?
    private(set) var selectedSpaceID: String?
    /// Counts links that other apps opened here, so the UI shows each page
    /// instead of the search it opens on launch.
    private(set) var openedLinkCount = 0
    /// Search opens pages in private tabs. It lasts while the window is open.
    var isIncognito = false

    /// Set while a selection leaves the switcher's order as it is.
    private var keepsRecentOrder = false

    private let engine: any BrowserMobileEngine
    private let store: (any BrowserMobileSessionStoring)?
    private let navigationResolver: BrowserNavigationResolver
    private var hasRestored = false
    private var isClosed = false
    private var pendingSave: BrowserMobileSession?
    private var lastSaved: BrowserMobileSession?
    private var saveWorker: Task<Void, Never>?
    private var saveFailed = false
    private var isJavaScriptDialogPresentationActive = false
    private var isSyncActive = false
    private var isSceneAttached = false
    private var isActivityActive = false
    private let selectionLeaseOwner = UUID()
    private var expiryHydrationCheck: (@MainActor () -> Bool)?
    private var profileLoader: (@MainActor () async throws -> BrowserMobileProfileDocument)?
    private var sceneID = ""
    private var scenePreferences: UserDefaults?
    private var documentObserver: UUID?
    private var downloadsObserver: UUID?
    private var applyingDocument = false
    private var registeredRuntimeIDs = Set<String>()
    private var adoptedPopupRuntimeID: String?
    private var unloadedPersistentIDs = Set<String>()
    /// Links from other apps that arrived before the tabs were restored.
    private var pendingOpenedLinks = [URL]()

    var syncSession: BrowserMobileSyncSession? { profileDocument?.syncSession }
    var downloads: BrowserMobileDownloads? { profileDocument?.downloads }

    var spaces: [BrowserSpaceSessionSnapshot] { profileDocument?.snapshot.spaces ?? [] }
    /// Every tab of this window: the mobile tabs and the window's private
    /// tabs. Space tabs open as mobile tabs and never show here themselves.
    var visibleTabs: [BrowserMobileTab] { tabs }

    var selectedTab: BrowserMobileTab? { tabs.first { $0.id == selectedTabID } }

    /// The tabs of the account's Spaces, as the Spaces picker lists them.
    /// They have no page here: opening one makes a mobile tab.
    var spaceTabs: [BrowserMobileTab] {
        (profileDocument?.snapshot.tabs ?? []).compactMap { record in
            guard let id = record.id else { return nil }
            let unavailable = BrowserMobileSession.allowedURL(record.urlString) == nil
            return BrowserMobileTab(
                id: id, runtimeID: "", urlString: record.urlString, title: record.pageTitle ?? "",
                state: BrowserMobilePageState(
                    url: URL(string: record.urlString),
                    error: unavailable ? "This address is unavailable on this device." : nil,
                ),
                spaceID: record.spaceID, placement: record.placement, pinnedFolderID: record.pinnedFolderID,
                userTitleOverride: record.userTitleOverride,
            )
        }
    }

    /// The tabs a phone's switcher lists, the oldest first: the ones this
    /// window showed by last selection, after them the rest by activity.
    var switcherTabs: [BrowserMobileTab] {
        let recentRank = Dictionary(recentTabIDs.enumerated().map { ($1, $0) }) { first, _ in first }
        let activity = Dictionary(
            (profileDocument?.mobileTabs ?? []).map { entry in
                (entry.id, entry.record.lastActivityAt?.timeIntervalSince1970 ?? 0)
            },
        ) { first, _ in first }
        let order = Dictionary(tabs.enumerated().map { ($1.id, $0) }) { first, _ in first }
        return tabs.filter { tab in
            tab.placement == .temporary
                || (recentRank[tab.id] != nil && !unloadedPersistentIDs.contains(tab.id))
        }
        .sorted { lhs, rhs in
            switch (recentRank[lhs.id], recentRank[rhs.id]) {
            case (let left?, let right?): return left > right
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil):
                let left = activity[lhs.id] ?? 0
                let right = activity[rhs.id] ?? 0
                return left == right ? order[lhs.id, default: 0] < order[rhs.id, default: 0] : left < right
            }
        }
    }

    var supportsArchive: Bool { profileDocument?.supportsArchive == true }
    var canRestoreArchivedTab: Bool { canEdit && profileDocument?.canRestoreArchivedTab == true }
    var canManageArchive: Bool { canEdit && profileDocument?.canManageArchive == true }
    var isArchiveOperationInFlight: Bool { profileDocument?.isArchiveOperationInFlight == true }
    var archiveError: String? { profileDocument?.archiveError }
    var archiveRevision: Int { profileDocument?.archiveRevision ?? 0 }
    var automaticTabArchivalEnabled: Bool { profileDocument?.automaticTabArchivalEnabled ?? false }
    var temporaryTabLifetime: BrowserTemporaryTabLifetime { profileDocument?.temporaryTabLifetime ?? .defaultValue }
    var automaticTabArchivalError: String? { profileDocument?.automaticTabArchivalError }
    var canConfigureAutomaticTabArchival: Bool {
        canEdit && profileDocument?.supportsAutomaticTabArchival == true && profileDocument?.canManageArchive == true
    }

    var canFindInPage: Bool {
        guard isReady, !isClosed, !isRestoring, javaScriptDialog == nil, httpAuthentication == nil,
              let tab = selectedTab, tab.state.error == nil, tab.urlString != "about:blank"
        else { return false }
        return engine.canFindInPage(id: tab.runtimeID)
    }

    var isFindInPageVisible: Bool { engine.isFindInPageVisible }

    /// The WebKit engine whose pages run extensions, if this workspace has one.
    var extensionEngine: BrowserWebKitEngine? { engine as? BrowserWebKitEngine }

    var pageZoom: CGFloat {
        get { selectedTab.map { engine.pageZoom(id: $0.runtimeID) } ?? 1 }
        set { selectedTab.map { engine.setPageZoom(id: $0.runtimeID, newValue) } }
    }

    var prefersDesktopSite: Bool {
        get { selectedTab.map { engine.prefersDesktopSite(id: $0.runtimeID) } ?? false }
        set { selectedTab.map { engine.setPrefersDesktopSite(id: $0.runtimeID, newValue) } }
    }

    /// Reader Mode for the selected tab.
    var isReading: Bool {
        get { selectedTab?.state.isReading ?? false }
        set { selectedTab.map { engine.setReading(id: $0.runtimeID, newValue) } }
    }

    private var canEdit: Bool {
        isReady && !isClosed && !isRestoring && (profileDocument?.canEdit ?? true)
    }

    private var selectionKey: String { "mobile.scene." + Data(sceneID.utf8).base64EncodedString() }

    init(
        engine: any BrowserMobileEngine, store: any BrowserMobileSessionStoring,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver(),
    ) {
        self.engine = engine
        self.store = store
        self.navigationResolver = navigationResolver
        engine.onEvent = { [weak self] event in self?.receive(event) }
        engine.onPopupCreated = { [weak self] runtimeID, url in self?.adoptPopup(runtimeID: runtimeID, url: url) }
    }

    init(
        engine: any BrowserMobileEngine, sceneID: String,
        profileLoader: @escaping @MainActor () async throws -> BrowserMobileProfileDocument,
        preferences: UserDefaults = .standard,
        navigationResolver: BrowserNavigationResolver = BrowserNavigationResolver(),
    ) {
        self.engine = engine
        self.store = nil
        self.navigationResolver = navigationResolver
        self.profileLoader = profileLoader
        self.sceneID = sceneID
        self.scenePreferences = preferences
        engine.onEvent = { [weak self] event in self?.receive(event) }
        engine.onPopupCreated = { [weak self] runtimeID, url in self?.adoptPopup(runtimeID: runtimeID, url: url) }
    }

    /// A Favorite or pinned Space tab with this address, which Pin added or a computer holds.
    func pinnedSpaceTabID(urlString: String) -> String? {
        profileDocument?.snapshot.tabs.first { $0.placement != .temporary && $0.urlString == urlString }?.id
    }

    /// Adds the selected page to a Space, as a Favorite or a pinned tab. The
    /// mobile tab stays where it is.
    @discardableResult func pinSelectedTab(
        spaceID: String? = nil, placement: BrowserTabPlacement = .spacePinned, pinnedFolderID: String? = nil,
    ) -> String? {
        guard canEdit, let profileDocument, let tab = selectedTab, !tab.isPrivate,
              BrowserMobileSession.allowedURL(tab.urlString) != nil, tab.urlString != "about:blank",
              let space = spaceID ?? selectedSpaceID ?? spaces.first?.id,
              let id = profileDocument.createTab(
                  urlString: tab.urlString, spaceID: space, placement: placement, pinnedFolderID: pinnedFolderID,
              ) else { return nil }
        if !tab.title.isEmpty {
            profileDocument.setPageTitle(tabID: id, title: tab.title)
        }
        return id
    }

    func pageText(completion: @escaping @MainActor (BrowserMobilePageText?) -> Void) {
        guard let tab = selectedTab else { return completion(nil) }
        engine.pageText(id: tab.runtimeID, completion: completion)
    }

    /// Puts translations into the tab `pageText` was read from, unless it changed since.
    func applyTranslatedText(tabID: String, start: Int, texts: [String]) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        engine.applyTranslatedText(id: tab.runtimeID, start: start, texts: texts)
    }

    func restoreOriginalText() {
        selectedTab.map { engine.restoreOriginalText(id: $0.runtimeID) }
    }

    /// Opens a page's link in a new tab next to the current one; in the
    /// background, the current tab stays selected.
    func openLinkInNewTab(_ url: URL, inBackground: Bool) {
        guard canEdit, let url = BrowserMobileSession.allowedURL(url.absoluteString) else { return }
        // A link from a private page stays private.
        if selectedTab?.isPrivate == true {
            insertPrivateTab(url: url, selects: !inBackground)
            notify()
            return
        }
        guard inBackground else {
            insertNewTab(url: url)
            notify()
            return
        }
        if let profileDocument {
            _ = profileDocument.createMobileTab(urlString: url.absoluteString)
            return
        }
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: UUID().uuidString,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url),
        )
        tabs.append(tab)
        enqueueCurrentSession()
        engine.createTab(id: tab.runtimeID, url: url)
        notify()
    }

    @discardableResult func setAutomaticTabArchival(lifetime: BrowserTemporaryTabLifetime?) -> Bool {
        guard canConfigureAutomaticTabArchival else { return false }
        return profileDocument?.setAutomaticTabArchival(lifetime: lifetime) ?? false
    }

    func reloadAutomaticTabArchivalSettings() {
        profileDocument?.reloadAutomaticTabArchivalSettings()
        notify()
    }

    func archivePage(before: BrowserTabArchiveCursor? = nil, limit: Int = 50) throws -> BrowserTabArchivePage {
        guard let profileDocument else { throw BrowserTabArchiveError.unsupportedStore }
        return try profileDocument.archivePage(before: before, limit: limit)
    }

    func searchArchivePage(
        query: String, before: BrowserTabArchiveCursor? = nil, limit: Int = 50,
    ) async throws -> BrowserTabArchivePage {
        guard let profileDocument else { throw BrowserTabArchiveError.unsupportedStore }
        return try await profileDocument.searchArchivePage(query: query, before: before, limit: limit)
    }

    func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        guard let profileDocument else { throw BrowserTabArchiveError.unsupportedStore }
        return try await profileDocument.archiveClearBoundary()
    }

    @discardableResult func deleteArchivedTab(id: String) async -> Bool {
        guard canManageArchive, let profileDocument else { return false }
        return await profileDocument.deleteArchivedTab(id: id)
    }

    @discardableResult func clearArchive(through boundary: BrowserTabArchiveBoundary) async -> Bool {
        guard canManageArchive, let profileDocument else { return false }
        return await profileDocument.clearArchive(through: boundary)
    }

    /// Opens an archived tab again as a new mobile tab.
    @discardableResult func restoreArchivedTab(id: String) -> String? {
        guard canRestoreArchivedTab,
              let restoredID = profileDocument?.restoreArchivedMobileTab(archiveID: id)
        else { return nil }
        selectTab(id: restoredID)
        return restoredID
    }

    /// Opens a Space tab from the account's computers as a mobile tab, or
    /// selects the mobile tab already showing its address.
    @discardableResult func openSpaceTab(id: String) -> String? {
        guard canEdit, let profileDocument,
              let record = profileDocument.snapshot.tabs.first(where: { $0.id == id })
        else { return nil }
        guard let url = BrowserMobileSession.allowedURL(record.urlString) else {
            navigationError = "This address is unavailable on this device."
            notify()
            return nil
        }
        if let open = tabs.first(where: { !$0.isPrivate && $0.urlString == url.absoluteString }) {
            selectTab(id: open.id)
            return open.id
        }
        navigationError = nil
        guard let tabID = profileDocument.createMobileTab(
            urlString: url.absoluteString, title: record.userTitleOverride ?? record.pageTitle,
        ) else { return nil }
        selectTab(id: tabID)
        return tabID
    }

    @discardableResult func presentFindInPage() -> Bool {
        guard canFindInPage, let tab = selectedTab else { return false }
        return engine.presentFindInPage(id: tab.runtimeID)
    }

    func dismissFindInPage() { engine.dismissFindInPage() }

    func restore() async {
        guard !isClosed, !hasRestored, !isRestoring else { return }
        if profileLoader != nil {
            await restoreProfile()
            return
        }
        isRestoring = true
        sessionError = nil
        notify()
        do {
            let saved = try await store?.load()
            guard !isClosed else { isRestoring = false
                return
            }
            try saved?.validate()
            let logicalTabs = saved?.tabs ?? []
            tabs = logicalTabs.map {
                BrowserMobileTab(
                    id: $0.id,
                    runtimeID: UUID().uuidString,
                    urlString: $0.urlString,
                    title: $0.title,
                    state: BrowserMobilePageState(url: URL(string: $0.urlString)),
                )
            }
            selectedTabID = saved?.selectedTabID ?? tabs.first?.id
            lastSaved = saved
            hasRestored = true
            // Register every identity before the first engine call. Engine
            // state events are allowed to arrive synchronously from create.
            let restoringTabs = tabs
            for tab in restoringTabs {
                guard !isClosed else { break }
                engine.createTab(id: tab.runtimeID, url: URL(string: tab.urlString)!)
            }
            guard !isClosed else { isRestoring = false
                return
            }
            isRestoring = false
            isReady = true
            if tabs.isEmpty {
                insertNewTab(url: Self.blankURL)
            } else {
                engine.selectTab(id: selectedTab?.runtimeID)
            }
            enqueueCurrentSession()
            notify()
            openPendingLinks()
        } catch {
            guard !isClosed else { isRestoring = false
                return
            }
            isRestoring = false
            isReady = false
            sessionError = error.localizedDescription
            notify()
        }
    }

    /// Opens a link that another app handed over, as the default browser
    /// does: in a new tab that takes the selection, or in an empty one.
    func openLinkFromAnotherApp(_ url: URL) {
        guard let url = BrowserMobileSession.allowedURL(url.absoluteString), url.scheme != "about" else { return }
        guard canEdit else {
            if !isReady, !isClosed { pendingOpenedLinks.append(url) }
            return
        }
        openedLinkCount += 1
        if let tab = selectedTab, !tab.isPrivate, tab.urlString == "about:blank", tab.state.error == nil {
            submit(url.absoluteString)
            return
        }
        navigationError = nil
        insertNewTab(url: url)
        notify()
    }

    func newTab() {
        guard canEdit else { return }
        navigationError = nil
        insertNewTab(url: Self.blankURL)
        notify()
    }

    /// Opens what the user typed in a new tab, so the current page stays.
    func submitInNewTab(_ input: String) {
        guard canEdit else { return }
        guard let resolution = navigationResolver.resolve(input),
              let url = BrowserMobileSession.allowedURL(resolution.resolvedURLString)
        else {
            navigationError = "This address cannot be opened in this browser. Use an HTTP or HTTPS address."
            notify()
            return
        }
        navigationError = nil
        if let tab = selectedTab, !tab.isPrivate, tab.urlString == "about:blank", tab.state.error == nil {
            submit(input)
            return
        }
        insertNewTab(url: url)
        notify()
    }

    /// Opens what the user typed in a new private tab.
    func submitInNewPrivateTab(_ input: String) {
        guard canEdit else { return }
        guard let resolution = navigationResolver.resolve(input),
              let url = BrowserMobileSession.allowedURL(resolution.resolvedURLString)
        else {
            navigationError = "This address cannot be opened in this browser. Use an HTTP or HTTPS address."
            notify()
            return
        }
        navigationError = nil
        insertPrivateTab(url: url, selects: true)
        notify()
    }

    func snapshot(
        tabID: String, rect: CGRect? = nil, width: CGFloat, completion: @escaping @MainActor (UIImage?) -> Void,
    ) {
        guard let tab = tabs.first(where: { $0.id == tabID }), registeredRuntimeIDs.contains(tab.runtimeID)
            || profileDocument == nil
        else {
            completion(nil)
            return
        }
        engine.snapshot(id: tab.runtimeID, rect: rect, width: width, completion: completion)
    }

    func setObscuredInsets(_ insets: UIEdgeInsets) { engine.setObscuredInsets(insets) }

    func scrollView(tabID: String) -> UIScrollView? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        return engine.scrollView(id: tab.runtimeID)
    }

    func iconURLs(tabID: String, completion: @escaping @MainActor ([URL]) -> Void) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            completion([])
            return
        }
        engine.iconURLs(id: tab.runtimeID, completion: completion)
    }

    func submit(_ input: String) {
        guard canEdit else { return }
        guard let resolution = navigationResolver.resolve(input),
              let url = BrowserMobileSession.allowedURL(resolution.resolvedURLString)
        else {
            navigationError = "This address cannot be opened in this browser. Use an HTTP or HTTPS address."
            notify()
            return
        }
        navigationError = nil
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].isPrivate {
            if tabs[index].urlString != url.absoluteString {
                tabs[index].title = ""
                tabs[index].state.title = ""
            }
            tabs[index].urlString = url.absoluteString
            tabs[index].state.url = url
            tabs[index].state.error = nil
            engine.navigate(id: tabs[index].runtimeID, url: url)
            notify()
            return
        }
        if let profileDocument {
            guard let tab = selectedTab else {
                insertNewTab(url: url)
                notify()
                return
            }
            if tab.urlString == url.absoluteString, registeredRuntimeIDs.contains(tab.runtimeID) {
                engine.navigate(id: tab.runtimeID, url: url)
            } else {
                // Reconciliation owns exactly one create/navigation after the
                // document accepts the action, including unsupported URL recovery.
                if !profileDocument.updateMobileTab(id: tab.id, urlString: url.absoluteString) {
                    navigationError = profileDocument.mobileTabError
                }
            }
            notify()
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            insertNewTab(url: url)
            notify()
            return
        }
        let runtimeID = tabs[index].runtimeID
        if tabs[index].urlString != url.absoluteString {
            tabs[index].title = ""
            tabs[index].state.title = ""
        }
        tabs[index].urlString = url.absoluteString
        tabs[index].state.url = url
        tabs[index].state.error = nil
        enqueueCurrentSession()
        engine.navigate(id: runtimeID, url: url)
        notify()
    }

    func selectTab(id: String) {
        guard canEdit, tabs.contains(where: { $0.id == id }) else { return }
        let previousID = selectedTabID
        unloadedPersistentIDs.remove(id)
        selectedTabID = id
        cancelJavaScriptDialogIfSelectionChanged()
        navigationError = nil
        enqueueCurrentSession()
        selectCurrentRuntime()
        recordSelectionActivity(previousID: previousID)
        notify()
    }

    /// Selects a tab without making it the newest in the switcher, as a
    /// swipe along the bar moves through the row without reordering it.
    func selectTabInPlace(id: String) {
        keepsRecentOrder = true
        defer { keepsRecentOrder = false }
        selectTab(id: id)
    }

    /// The Space the Spaces picker shows. The selected tab stays.
    func selectSpace(id: String) {
        guard canEdit, spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        saveSceneSelection()
        notify()
    }

    /// Closes the tab; returns the archive entry's ID when it went to the
    /// archive, to restore it by.
    @discardableResult func closeTab(id: String) -> String? {
        guard canEdit, let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let previousID = selectedTabID
        defer {
            if selectedTabID != previousID {
                recordSelectionActivity(previousID: previousID)
            }
        }
        if tab.isPrivate {
            // Closing discards it: nothing is archived or saved.
            removePrivateTab(tab)
            engine.closeTab(id: tab.runtimeID)
            return nil
        }
        if let profileDocument {
            let current = profileDocument.mobileTab(id: id)
            let title = current?.record.urlString == tab.urlString ? tab.title : nil
            let archiveID = profileDocument.closeMobileTab(id: id, displayTitle: title)
            if profileDocument.mobileTab(id: id) != nil {
                navigationError = profileDocument.archiveError ?? profileDocument.mobileTabError
                updateProfileError()
                notify()
                return nil
            }
            return archiveID
        }
        removeTab(runtimeID: tab.runtimeID)
        engine.closeTab(id: tab.runtimeID)
        return nil
    }

    func goBack() {
        guard canEdit, let tab = selectedTab, tab.state.canGoBack else { return }
        engine.goBack(id: tab.runtimeID)
    }

    func goForward() {
        guard canEdit, let tab = selectedTab, tab.state.canGoForward else { return }
        engine.goForward(id: tab.runtimeID)
    }

    func reload() {
        guard canEdit, let tab = selectedTab else { return }
        engine.reload(id: tab.runtimeID)
    }

    func reloadOrStop() {
        guard canEdit, let tab = selectedTab else { return }
        if tab.state.isLoading {
            engine.stop(id: tab.runtimeID)
        } else {
            engine.reload(id: tab.runtimeID)
        }
    }

    func setSyncActive(_ active: Bool) {
        if !active {
            // A page's last changes go up before the app may be suspended.
            profileDocument?.flushMobileTabSync()
        }
        isSyncActive = active && !isClosed
        syncSession?.setSceneActive(isSyncActive, sceneID: sceneID)
    }

    /// Attachment outlives foreground activity. A background window still owns
    /// its selection; a retained but disconnected workspace does not.
    func setSceneAttached(_ attached: Bool) {
        let next = attached && !isClosed
        guard isSceneAttached != next else { return }
        if !next {
            setActivityActive(false)
        }
        isSceneAttached = next
        updateSelectionLease()
    }

    func setExpiryHydrationCheck(_ check: @escaping @MainActor () -> Bool) {
        expiryHydrationCheck = check
        updateSelectionLease()
    }

    func setActivityActive(_ active: Bool) {
        let next = active && isSceneAttached && !isClosed
        guard isActivityActive != next else { return }
        // Record both arrival and departure. A tab used for hours must not look
        // idle immediately after switching away or backgrounding its window.
        if isActivityActive {
            recordSelectionActivity()
        }
        isActivityActive = next
        if next {
            recordSelectionActivity()
        }
        updateSelectionLease()
    }

    func setJavaScriptDialogPresentationActive(_ active: Bool) {
        let next = active && !isClosed
        let changed = isJavaScriptDialogPresentationActive != next
        isJavaScriptDialogPresentationActive = next
        if !isJavaScriptDialogPresentationActive {
            cancelJavaScriptDialog()
            cancelHTTPAuthentication()
        }
        engine.setJavaScriptDialogPresentationActive(isJavaScriptDialogPresentationActive)
        if changed {
            notify()
        }
    }

    func resolveJavaScriptDialog(id: UUID, response: BrowserMobileJavaScriptDialogResponse) {
        guard let dialog = javaScriptDialog, dialog.id == id else { return }
        let mayRespond = canEdit && isJavaScriptDialogPresentationActive
            && selectedTab?.runtimeID == dialog.runtimeID
        javaScriptDialog = nil
        engine.resolveJavaScriptDialog(id: id, response: mayRespond ? response : .cancel)
        notify()
    }

    func resolveHTTPAuthentication(id: UUID, response: BrowserMobileHTTPAuthenticationResponse) {
        guard let request = httpAuthentication, request.id == id else { return }
        let mayRespond = canEdit && isJavaScriptDialogPresentationActive && javaScriptDialog == nil
            && selectedTab?.runtimeID == request.runtimeID
        httpAuthentication = nil
        engine.resolveHTTPAuthentication(id: id, response: mayRespond ? response : .cancel)
        notify()
    }

    func cancelHTTPAuthentication() {
        guard let request = httpAuthentication else { return }
        httpAuthentication = nil
        engine.resolveHTTPAuthentication(id: request.id, response: .cancel)
        notify()
    }

    @discardableResult func retryPersistence() async -> Bool {
        if !hasRestored {
            await restore()
            return isReady
        }
        if let profileDocument {
            let succeeded = profileDocument.retryPersistence()
            updateProfileError()
            notify()
            return succeeded
        }
        saveFailed = false
        sessionError = nil
        startSaveWorker()
        notify()
        return await flushPersistence()
    }

    @discardableResult func flushPersistence() async -> Bool {
        if let profileDocument {
            return !profileDocument.hasUncommittedWrites
        }
        startSaveWorker()
        while let worker = saveWorker {
            await worker.value
        }
        return hasRestored && pendingSave == nil && sessionError == nil
    }

    @discardableResult func shutdown() async -> Bool {
        if !isClosed {
            setSceneAttached(false)
            isClosed = true
            isReady = false
            setJavaScriptDialogPresentationActive(false)
            setSyncActive(false)
            engine.onEvent = nil
            engine.onPopupCreated = nil
            if let documentObserver {
                profileDocument?.removeObserver(documentObserver)
            }
            documentObserver = nil
            if let downloadsObserver {
                downloads?.removeObserver(downloadsObserver)
            }
            downloadsObserver = nil
            engine.shutdown()
            notify()
        }
        return await flushPersistence()
    }

    private func openPendingLinks() {
        let links = pendingOpenedLinks
        pendingOpenedLinks = []
        links.forEach(openLinkFromAnotherApp)
    }

    private func restoreProfile() async {
        guard let profileLoader else { return }
        isRestoring = true
        sessionError = nil
        notify()
        do {
            let document = try await profileLoader()
            guard !isClosed else { isRestoring = false
                return
            }
            profileDocument = document
            engine.setDownloads(document.downloads)
            downloadsObserver = document.downloads?.observe { [weak self] in self?.notify() }
            selectedSpaceID = scenePreferences?.string(forKey: selectionKey + ".space")
            recentTabIDs = scenePreferences?.stringArray(forKey: selectionKey + ".recent") ?? []
            selectedTabID = scenePreferences?.string(forKey: selectionKey + ".tab")
            if selectedSpaceID == nil {
                let filename = Data(sceneID.utf8).base64EncodedString().replacing("/", with: "_") + ".json"
                let importedID = BrowserMobileProfileRegistry.legacySpaceID(filename: filename)
                if document.snapshot.spaces?.contains(where: { $0.id == importedID }) == true {
                    selectedSpaceID = importedID
                }
            }
            if selectedTabID.map({ document.mobileTab(id: $0) == nil }) ?? true {
                selectedTabID = recentTabIDs.first { document.mobileTab(id: $0) != nil } ?? document.mobileTabs.last?.id
            }
            hasRestored = true
            isRestoring = false
            isReady = true
            documentObserver = document.observe { [weak self] snapshot in self?.applyProfile(snapshot) }
            ensureMobileTab()
            recordSelectionActivity()
            syncSession?.setSceneActive(isSyncActive, sceneID: sceneID)
            openPendingLinks()
        } catch {
            isRestoring = false
            guard !isClosed else { return }
            isReady = false
            sessionError = error.localizedDescription
            notify()
        }
    }

    /// Mirrors the document's mobile tabs; the Space snapshot only feeds the
    /// Spaces picker.
    private func applyProfile(_: BrowserTabSessionSnapshot) {
        guard !isClosed, let profileDocument else { return }
        applyingDocument = true
        defer { applyingDocument = false }
        let previous = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let privateTabs = tabs.filter(\.isPrivate)
        let oldSelectionIndex = visibleTabs.firstIndex { $0.id == selectedTabID } ?? 0
        tabs = profileDocument.mobileTabs.map { entry in
            let id = entry.id
            let record = entry.record
            var tab = previous[id] ?? BrowserMobileTab(
                id: id, runtimeID: adoptedPopupRuntimeID ?? UUID().uuidString,
                urlString: record.urlString, title: record.title ?? "",
                state: BrowserMobilePageState(url: URL(string: record.urlString)),
            )
            if previous[id] == nil, adoptedPopupRuntimeID != nil {
                registeredRuntimeIDs.insert(tab.runtimeID)
            }
            if tab.urlString != record.urlString {
                tab.title = ""
            }
            tab.urlString = record.urlString
            if tab.title.isEmpty, let title = record.title {
                // The title another device read, until this page reports its own.
                tab.title = title
            }
            if BrowserMobileSession.allowedURL(record.urlString) == nil {
                tab.state = BrowserMobilePageState(
                    url: URL(string: record.urlString),
                    error: "This address is unavailable on this device.",
                )
            }
            return tab
        }
        // Private tabs are not in the document; they stay as they are.
        tabs += privateTabs
        let surviving = Set(tabs.map(\.id))
        unloadedPersistentIDs.formIntersection(surviving)
        for tab in previous.values where !surviving.contains(tab.id) {
            if registeredRuntimeIDs.remove(tab.runtimeID) != nil {
                engine.closeTab(id: tab.runtimeID)
            }
        }
        if !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first?.id
        }
        if !visibleTabs.contains(where: { $0.id == selectedTabID }) {
            let visible = visibleTabs.filter { !unloadedPersistentIDs.contains($0.id) }
            let recent = recentTabIDs.first { id in visible.contains { $0.id == id } }
            selectedTabID = recent ?? (visible.isEmpty ? nil : visible[min(oldSelectionIndex, visible.count - 1)].id)
        }
        cancelJavaScriptDialogIfSelectionChanged()
        // Register all logical identities before WebKit can call back synchronously.
        for tab in tabs {
            guard !unloadedPersistentIDs.contains(tab.id) else { continue }
            guard let url = BrowserMobileSession.allowedURL(tab.urlString) else {
                if registeredRuntimeIDs.remove(tab.runtimeID) != nil {
                    engine.closeTab(id: tab.runtimeID)
                    if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                        // An engine ID cannot be reused after close.
                        let old = tabs[index]
                        tabs[index] = BrowserMobileTab(
                            id: old.id,
                            runtimeID: UUID().uuidString,
                            urlString: old.urlString,
                            title: old.title,
                            state: old.state,
                            spaceID: old.spaceID,
                            placement: old.placement,
                            pinnedFolderID: old.pinnedFolderID,
                            userTitleOverride: old.userTitleOverride,
                        )
                    }
                }
                continue
            }
            if registeredRuntimeIDs.insert(tab.runtimeID).inserted {
                engine.createTab(id: tab.runtimeID, url: url)
            } else if previous[tab.id]?.urlString != tab.urlString, previous[tab.id] != nil {
                engine.navigate(id: tab.runtimeID, url: url)
            }
        }
        updateProfileError()
        saveSceneSelection()
        selectCurrentRuntime()
        if tabs.isEmpty {
            // A window always holds a tab, also after other devices closed them all.
            DispatchQueue.main.async { [weak self] in self?.ensureMobileTab() }
        }
        notify()
    }

    /// Opens a blank tab when the window has none. It stays on this device
    /// until it opens a page.
    private func ensureMobileTab() {
        guard profileDocument != nil, tabs.isEmpty, canEdit else { return }
        insertNewTab(url: Self.blankURL)
        notify()
    }

    private func saveSceneSelection() {
        scenePreferences?.set(selectedSpaceID, forKey: selectionKey + ".space")
        if selectedTab?.isPrivate != true {
            scenePreferences?.set(selectedTabID, forKey: selectionKey + ".tab")
        }
        updateSelectionLease()
    }

    private func updateSelectionLease() {
        guard let profileDocument else { return }
        if isSceneAttached {
            profileDocument.updateSelectionLease(owner: selectionLeaseOwner, selectedTabID: selectedTabID)
            profileDocument.updateExpiryLease(
                owner: selectionLeaseOwner, isActive: isActivityActive, isHydrated: isReady && !isRestoring,
                hydrationCheck: { [weak self] in
                    guard let self, isReady, !isRestoring, !isClosed else { return false }
                    return expiryHydrationCheck?() ?? true
                },
            )
        } else {
            profileDocument.removeSelectionLease(owner: selectionLeaseOwner)
        }
    }

    private func recordSelectionActivity(previousID: String? = nil) {
        guard isActivityActive, isReady, !isClosed, !isRestoring else { return }
        profileDocument?.recordActivity(tabIDs: Set([previousID, selectedTabID].compactMap(\.self)))
    }

    private func selectCurrentRuntime() {
        if profileDocument != nil, let tab = selectedTab,
           !unloadedPersistentIDs.contains(tab.id), !registeredRuntimeIDs.contains(tab.runtimeID),
           let url = BrowserMobileSession.allowedURL(tab.urlString)
        {
            registeredRuntimeIDs.insert(tab.runtimeID)
            engine.createTab(id: tab.runtimeID, url: url)
        }
        let id = selectedTab?.runtimeID
        engine.selectTab(id: profileDocument == nil || id.map(registeredRuntimeIDs.contains) == true ? id : nil)
    }

    private func updateProfileError() {
        guard let failure = profileDocument?.persistenceFailure else { sessionError = nil
            return
        }
        sessionError = failure.isRetryable
            ? "Changes could not be saved. Retry before closing the browser."
            : "Changes could not be saved. Keep this window open to preserve your unsaved work."
    }

    private func insertNewTab(url: URL) {
        if let profileDocument {
            guard let id = profileDocument.createMobileTab(urlString: url.absoluteString) else {
                navigationError = profileDocument.mobileTabError
                return
            }
            selectTab(id: id)
            return
        }
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: UUID().uuidString,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url),
        )
        tabs.append(tab)
        selectedTabID = tab.id
        cancelJavaScriptDialogIfSelectionChanged()
        enqueueCurrentSession()
        engine.createTab(id: tab.runtimeID, url: url)
        if tabs.contains(where: { $0.id == tab.id }) {
            engine.selectTab(id: tab.runtimeID)
        }
    }

    private func insertPrivateTab(url: URL, selects: Bool) {
        let runtimeID = UUID().uuidString
        appendPrivateTab(runtimeID: runtimeID, url: url, selects: selects)
        engine.createPrivateTab(id: runtimeID, url: url)
        if selects, selectedTab?.runtimeID == runtimeID {
            engine.selectTab(id: runtimeID)
        }
    }

    /// Adds a private tab to this window only; the profile document and the
    /// saved session never hear of it.
    private func appendPrivateTab(runtimeID: String, url: URL, selects: Bool) {
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: runtimeID,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url),
            isPrivate: true,
        )
        tabs.append(tab)
        registeredRuntimeIDs.insert(runtimeID)
        guard selects else { return }
        let previousID = selectedTabID
        selectedTabID = tab.id
        cancelJavaScriptDialogIfSelectionChanged()
        recordSelectionActivity(previousID: previousID)
    }

    private func removePrivateTab(_ tab: BrowserMobileTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        registeredRuntimeIDs.remove(tab.runtimeID)
        recentTabIDs.removeAll { $0 == tab.id }
        if selectedTabID == tab.id {
            let candidates = profileDocument == nil
                ? tabs
                : visibleTabs.filter { !unloadedPersistentIDs.contains($0.id) }
            let recent = recentTabIDs.first { id in candidates.contains { $0.id == id } }
            selectedTabID = recent ?? candidates.last?.id
        }
        cancelJavaScriptDialogIfSelectionChanged()
        if profileDocument == nil, tabs.isEmpty, canEdit {
            insertNewTab(url: Self.blankURL)
        } else {
            enqueueCurrentSession()
            selectCurrentRuntime()
        }
        notify()
    }

    private func adoptPopup(runtimeID: String, url: URL?) {
        guard !tabs.contains(where: { $0.runtimeID == runtimeID }) else { return }
        guard canEdit else { engine.closeTab(id: runtimeID)
            return
        }
        guard let url = BrowserMobileSession.allowedURL((url ?? Self.blankURL).absoluteString) else {
            navigationError = "This popup address cannot be opened in this browser."
            engine.closeTab(id: runtimeID)
            notify()
            return
        }
        if engine.isPrivateTab(id: runtimeID) {
            appendPrivateTab(runtimeID: runtimeID, url: url, selects: true)
            engine.selectTab(id: runtimeID)
            notify()
            return
        }
        if let profileDocument {
            adoptedPopupRuntimeID = runtimeID
            defer { adoptedPopupRuntimeID = nil }
            if let id = profileDocument.createMobileTab(urlString: url.absoluteString) {
                selectTab(id: id)
            } else {
                engine.closeTab(id: runtimeID)
            }
            return
        }
        let tab = BrowserMobileTab(
            id: UUID().uuidString,
            runtimeID: runtimeID,
            urlString: url.absoluteString,
            title: "",
            state: BrowserMobilePageState(url: url),
        )
        tabs.append(tab)
        selectedTabID = tab.id
        cancelJavaScriptDialogIfSelectionChanged()
        navigationError = nil
        enqueueCurrentSession()
        engine.selectTab(id: runtimeID)
        notify()
    }

    private func receive(_ event: BrowserMobileEngineEvent) {
        guard !isClosed else { return }
        switch event {
        case .state(let runtimeID, let state):
            guard let index = tabs.firstIndex(where: { $0.runtimeID == runtimeID }) else { return }
            let previousURL = tabs[index].urlString
            let previousTitle = tabs[index].title
            tabs[index].state = state
            if let url = state.url, BrowserMobileSession.allowedURL(url.absoluteString) != nil {
                if previousURL != url.absoluteString {
                    tabs[index].title = ""
                }
                tabs[index].urlString = url.absoluteString
            }
            if !state.title.isEmpty {
                tabs[index].title = state.title
            }
            if !tabs[index].isPrivate, previousURL != tabs[index].urlString || previousTitle != tabs[index].title {
                if let profileDocument {
                    if !applyingDocument, previousURL != tabs[index].urlString {
                        profileDocument.updateMobileTab(id: tabs[index].id, urlString: tabs[index].urlString)
                    }
                    if !applyingDocument, previousTitle != tabs[index].title, !tabs[index].title.isEmpty {
                        profileDocument.setMobileTabTitle(id: tabs[index].id, title: tabs[index].title)
                        // Space tabs never load here, so the open page names the ones at its address.
                        let address = tabs[index].urlString
                        for record in profileDocument.snapshot.tabs where record.urlString == address {
                            if let id = record.id {
                                profileDocument.setPageTitle(tabID: id, title: tabs[index].title)
                            }
                        }
                    }
                } else {
                    enqueueCurrentSession()
                }
            }
            notify()
        case .closed(let runtimeID):
            if let tab = tabs.first(where: { $0.runtimeID == runtimeID && $0.isPrivate }) {
                removePrivateTab(tab)
            } else if let profileDocument {
                guard registeredRuntimeIDs.remove(runtimeID) != nil,
                      let tab = tabs.first(where: { $0.runtimeID == runtimeID }) else { return }
                // A page that closes itself goes without an Archive entry.
                profileDocument.closeMobileTab(id: tab.id, archives: false)
            } else {
                removeTab(runtimeID: runtimeID)
            }
        case .javaScriptDialogRequested(let dialog):
            guard canEdit, isJavaScriptDialogPresentationActive, httpAuthentication == nil,
                  selectedTab?.runtimeID == dialog.runtimeID
            else {
                engine.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
                return
            }
            if let current = javaScriptDialog {
                if current.id != dialog.id {
                    engine.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
                }
                return
            }
            javaScriptDialog = dialog
            notify()
        case .openInNewTab(let url, let inBackground):
            openLinkInNewTab(url, inBackground: inBackground)
        case .activateRequested(let runtimeID):
            guard let tab = tabs.first(where: { $0.runtimeID == runtimeID }) else { return }
            selectTab(id: tab.id)
        case .javaScriptDialogFinished(let id):
            guard javaScriptDialog?.id == id else { return }
            javaScriptDialog = nil
            notify()
        case .httpAuthenticationRequested(let request):
            guard canEdit, isJavaScriptDialogPresentationActive, javaScriptDialog == nil,
                  selectedTab?.runtimeID == request.runtimeID
            else {
                engine.resolveHTTPAuthentication(id: request.id, response: .cancel)
                return
            }
            if let current = httpAuthentication {
                if current.id != request.id {
                    engine.resolveHTTPAuthentication(id: request.id, response: .cancel)
                }
                return
            }
            engine.dismissFindInPage()
            httpAuthentication = request
            notify()
        case .httpAuthenticationFinished(let id):
            guard httpAuthentication?.id == id else { return }
            httpAuthentication = nil
            notify()
        }
    }

    private func removeTab(runtimeID: String) {
        guard let index = tabs.firstIndex(where: { $0.runtimeID == runtimeID }) else { return }
        let removed = tabs.remove(at: index)
        if selectedTabID == removed.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        cancelJavaScriptDialogIfSelectionChanged()
        if tabs.isEmpty, canEdit {
            insertNewTab(url: Self.blankURL)
        } else {
            enqueueCurrentSession()
            engine.selectTab(id: selectedTab?.runtimeID)
        }
        notify()
    }

    private func cancelJavaScriptDialogIfSelectionChanged() {
        if let dialog = javaScriptDialog, dialog.runtimeID != selectedTab?.runtimeID {
            cancelJavaScriptDialog()
        }
        if let request = httpAuthentication, request.runtimeID != selectedTab?.runtimeID {
            cancelHTTPAuthentication()
        }
    }

    private func cancelJavaScriptDialog() {
        guard let dialog = javaScriptDialog else { return }
        javaScriptDialog = nil
        engine.resolveJavaScriptDialog(id: dialog.id, response: .cancel)
        notify()
    }

    private func snapshot() -> BrowserMobileSession {
        let saved = tabs.filter { !$0.isPrivate }
        let savedIDs = Set(saved.map(\.id))
        // While a private tab shows, the saved selection is the saved tab shown last.
        let selected = selectedTabID.flatMap { savedIDs.contains($0) ? $0 : nil }
            ?? recentTabIDs.first { savedIDs.contains($0) } ?? saved.last?.id
        return BrowserMobileSession(
            tabs: saved.map { .init(id: $0.id, urlString: $0.urlString, title: $0.title) },
            selectedTabID: selected,
        )
    }

    private func enqueueCurrentSession() {
        guard hasRestored, !isRestoring else { return }
        if let profileDocument {
            saveSceneSelection()
            if !applyingDocument, let tab = selectedTab, !tab.isPrivate {
                profileDocument.updateMobileTab(id: tab.id, urlString: tab.urlString)
            }
            return
        }
        let latest = snapshot()
        if latest == pendingSave || (pendingSave == nil && saveWorker == nil && latest == lastSaved) {
            return
        }
        pendingSave = latest
        startSaveWorker()
    }

    private func startSaveWorker() {
        guard hasRestored, !saveFailed, pendingSave != nil, saveWorker == nil else { return }
        // One retained worker and one replaceable pending snapshot bound memory
        // and prevent an older asynchronous save from finishing after a newer one.
        saveWorker = Task { await self.drainSaves() }
    }

    private func drainSaves() async {
        while let session = pendingSave {
            pendingSave = nil
            do {
                try await store?.save(session)
                lastSaved = session
                sessionError = nil
            } catch {
                if pendingSave == nil {
                    pendingSave = session
                }
                saveFailed = true
                sessionError = error.localizedDescription
                break
            }
        }
        saveWorker = nil
        notify()
    }

    private func notify() { onChange?() }
}
