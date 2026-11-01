// BrowserApplicationController.swift

import AppKit
import Combine
import CoreServices
import Settings

// MARK: - BrowserApplicationController

@objcMembers
@MainActor public final class BrowserApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate,
NSMenuDelegate, NSUserInterfaceValidations {
    // MARK: Private

    private static let spacesMenuIdentifier = NSUserInterfaceItemIdentifier("browser.menu.spaces")
    private static let extensionsMenuIdentifier = NSUserInterfaceItemIdentifier("browser.menu.extensions")
    private static let spaceProfileItemIdentifier = NSUserInterfaceItemIdentifier("browser.menu.space-profile")
    private static let spaceListEndIdentifier = NSUserInterfaceItemIdentifier("browser.menu.spaces.list-end")
    private static let installWebAppMenuItemIdentifier = NSUserInterfaceItemIdentifier(
        "browser.install-web-app",
    )

    private static var applicationInfo: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "OpenArc \(version) (\(build))\nmacOS \(system)"
    }

    private var aboutWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?
    private var lastLiveFolderRefresh = Date.distantPast
    private var archiveWindowControllers = [ObjectIdentifier: BrowserArchiveWindowController]()
    private var webAppWindowSession: BrowserWebAppWindowSession?
    private var incognitoWindowSessions = [BrowserIncognitoWindowSession]()
    private var windowGroups = [String: BrowserProfileWindowGroup]()
    private var didRecordAdditionalWindows = false
    private var profileWindowSessions = [BrowserProfileWindowSession]()
    private var profileStore: BrowserProfileStore?
    private var updateController: BrowserUpdateController?
    private let userPreferencesStore = BrowserUserPreferencesStore()
    private let shortcutStore = BrowserShortcutStore()
    private var batterySaverController: BrowserBatterySaverController?
    private let defaultBrowserService = BrowserDefaultBrowserService()
    private weak var setAsDefaultBrowserMenuItem: NSMenuItem?
    private var pendingNavigationURLs = [URL]()
    private var hasReceivedBrowserContext = false
    private var isTerminationRequested = false
    private var isQuitWarningPresented = false
    private var isSessionClosureConfirmationPresented = false
    private var didConfirmTerminationWarning = false
    private var layoutIndependentKeyMonitor: Any?
    private var shortcutStoreCancellable: AnyCancellable?
    private var reservedShortcutMonitor: Any?
    private var appearancePreferenceCancellable: AnyCancellable?
    private var littleWindowHotKeyCancellable: AnyCancellable?
    private weak var lastKeyProfileWindow: NSWindow?
    /// Option-Command-N from any app, when turned on in Settings.
    private var littleWindowHotKey: BrowserGlobalHotKey?
    private var profileStoreCancellable: AnyCancellable?
    private let webAppConfiguration: BrowserWebAppConfiguration?

    /// Browser windows in front-to-back order.
    var appleScriptWindows: [BrowserScriptWindow] {
        let sessions: [(NSWindow, BrowserChromeModel)] = profileWindowSessions.map { ($0.window, $0.chromeModel) }
            + incognitoWindowSessions.map { ($0.window, $0.chromeModel) }
        return NSApp.orderedWindows.compactMap { window in
            sessions.first { $0.0 === window }.map { BrowserScriptWindow(window: $0.0, model: $0.1) }
        }
    }

    /// The application's tabs only take new ones, which open in the small window.
    var appleScriptTabs: [BrowserScriptTab] { [] }

    private var shouldPresentQuitWarning: Bool {
        guard webAppConfiguration == nil, !didConfirmTerminationWarning, !isQuitWarningPresented else {
            return false
        }

        return BrowserQuitWarningPolicy(
            warnsBeforeQuitting: userPreferencesStore.warnBeforeQuitting,
            openTabCount: allChromeModels.reduce(0) { $0 + $1.tabs.count },
        ).shouldWarn
    }

    private var allChromeModels: [BrowserChromeModel] {
        let webAppModels = webAppWindowSession.map { [$0.chromeModel] } ?? []
        return webAppModels + profileWindowSessions.map(\.chromeModel) + incognitoWindowSessions.map(\.chromeModel)
    }

    private var activeChromeModel: BrowserChromeModel? {
        // An Archive is an auxiliary document surface, and Peek shows its own
        // page. Page commands must not target an unrelated browser window behind it.
        if focusedArchiveWindowController != nil || NSApp.keyWindow is BrowserPeekPanel {
            return nil
        }
        if let webAppWindowSession {
            return webAppWindowSession.chromeModel
        }

        if let session = activeIncognitoWindowSession {
            return session.chromeModel
        }

        return activeProfileWindowSession?.chromeModel ?? profileWindowSessions.first?.chromeModel
    }

    private var archiveContextModel: BrowserChromeModel? {
        focusedArchiveWindowController?.model ?? activeChromeModel
    }

    /// The small window opens from the window behind a card or small window too,
    /// where page commands are off, and from the last used profile window while
    /// another app is active.
    private var littleWindowModel: BrowserChromeModel? {
        let lastUsed = profileWindowSessions.first { $0.window === lastKeyProfileWindow }
        return (activeProfileWindowSession ?? lastUsed ?? profileWindowSessions.first)?.chromeModel
    }

    private var focusedArchiveWindowController: BrowserArchiveWindowController? {
        var candidate = NSApp.keyWindow
        while let window = candidate {
            if let archive = archiveWindowControllers.values.first(where: { $0.window === window }) {
                return archive
            }
            candidate = window.sheetParent ?? window.parent
        }
        return nil
    }

    private var activeBrowserWindow: NSWindow? {
        if let webAppWindowSession {
            return webAppWindowSession.window
        }

        if let session = activeIncognitoWindowSession {
            return session.window
        }

        return activeProfileWindowSession?.window ?? profileWindowSessions.first?.window
    }

    private var activeProfileWindowSession: BrowserProfileWindowSession? {
        profileWindowSession(containing: NSApp.keyWindow)
            ?? profileWindowSession(containing: NSApp.mainWindow)
    }

    private var activeIncognitoWindowSession: BrowserIncognitoWindowSession? {
        incognitoWindowSession(containing: NSApp.keyWindow)
            ?? incognitoWindowSession(containing: NSApp.mainWindow)
    }

    override public init() {
        self.webAppConfiguration = BrowserWebAppConfiguration.current()
        super.init()
    }

    isolated deinit {
        guard let layoutIndependentKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(layoutIndependentKeyMonitor)
    }

    // MARK: Public

    public func createApplication() {
        BrowserTelemetry.startIfConfigured()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if webAppConfiguration == nil {
            configureUpdateControllerIfNeeded()
        }
        installMainMenu(for: app)
        if webAppConfiguration == nil, userPreferencesStore.appIcon != .standard {
            userPreferencesStore.appIcon.apply()
        }
        observeShortcutStore()
        observeAppearancePreference()
        installLayoutIndependentKeyMonitor()
        installReservedShortcutMonitor()
        startBatterySaverController()
        app.delegate = self
        if let webAppConfiguration {
            createWebAppWindow(configuration: webAppConfiguration)
        } else {
            createMainWindow()
        }
        app.finishLaunching()
        updateController?.start()
        BrowserTelemetry.captureUsage(.appBecameActive)
        app.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestApplicationTermination(sender)
        return .terminateCancel
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == Self.spacesMenuIdentifier {
            updateSpacesMenu(menu)
            return
        }
        if menu.identifier == Self.extensionsMenuIdentifier {
            updateExtensionsMenu(menu)
            return
        }
        guard let installWebAppItem = menu.items.first(where: {
            $0.identifier == Self.installWebAppMenuItemIdentifier
        }) else {
            return
        }

        updateInstallWebAppMenuItem(installWebAppItem)
    }

    public func applicationDidBecomeActive(_: Notification) {
        for chromeModel in allChromeModels {
            chromeModel.handleApplicationDidBecomeActive()
        }
        refreshLiveFoldersIfDue()
        BrowserTelemetry.captureUsage(.appBecameActive)
        if webAppConfiguration == nil {
            refreshSetAsDefaultBrowserMenuItem()
        }
    }

    public func applicationWillResignActive(_: Notification) {
        for chromeModel in allChromeModels {
            chromeModel.handleApplicationWillResignActive()
        }
    }

    public func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            openAboutLink(url)
        }
    }

    public func windowShouldClose(_ window: NSWindow) -> Bool {
        let model = profileWindowSessions.first { $0.window === window }?.chromeModel
            ?? incognitoWindowSessions.first { $0.window === window }?.chromeModel
            ?? (webAppWindowSession?.window === window ? webAppWindowSession?.chromeModel : nil)
        guard let model else { return true }
        guard BrowserSessionClosureGuard.prepare(models: { [model] }, confirmation: confirmUnsavedSessionClosure) else {
            return false
        }
        model.prepareForTermination()
        return true
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              profileWindowSessions.contains(where: { $0.window === window })
        else { return }
        lastKeyProfileWindow = window
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else {
            return
        }

        if closedWindow === settingsWindowController?.window {
            settingsWindowController = nil
            return
        }

        if closedWindow === aboutWindow {
            aboutWindow = nil
            return
        }

        if closedWindow === webAppWindowSession?.window {
            webAppWindowSession?.chromeModel.prepareForTermination()
            webAppWindowSession = nil
            return
        }

        if let index = profileWindowSessions.firstIndex(where: { $0.window === closedWindow }) {
            let session = profileWindowSessions.remove(at: index)
            archiveWindowControllers.removeValue(forKey: ObjectIdentifier(session.chromeModel))?.close()
            session.chromeModel.prepareForTermination()
            removeFromWindowGroup(session)
            updateProfilePresentationForOpenWindows()
            return
        }

        guard let index = incognitoWindowSessions.firstIndex(where: { $0.window === closedWindow }) else {
            return
        }

        let session = incognitoWindowSessions.remove(at: index)
        session.chromeModel.prepareForTermination()
    }

    public func handleBrowserContextInitialized() {
        hasReceivedBrowserContext = true
        for chromeModel in allChromeModels {
            chromeModel.handleContextReady()
        }
        restoreAdditionalWindows()
        openPendingNavigationURLsIfPossible()
    }

    public func handleApplicationWillTerminate() {
        recordAdditionalWindows()
        batterySaverController?.stop()
        for chromeModel in allChromeModels {
            chromeModel.prepareForTermination()
        }
    }

    public func prepareForCefShutdown() {
        let chromeModels = allChromeModels
        handleApplicationWillTerminate()
        for chromeModel in chromeModels {
            chromeModel.prepareForCefShutdown()
        }
        NSApp.delegate = nil
        removeLayoutIndependentKeyMonitor()
        tearDownWindow(settingsWindowController?.window)
        settingsWindowController = nil
        tearDownWindow(aboutWindow)
        aboutWindow = nil
        tearDownBrowserWindowSessions()
        pendingNavigationURLs.removeAll()
        profileStoreCancellable = nil
        shortcutStoreCancellable = nil
        appearancePreferenceCancellable = nil
        littleWindowHotKeyCancellable = nil
        littleWindowHotKey = nil
        profileStore = nil
        updateController = nil
        batterySaverController = nil
    }

    public func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    public func openSettings(_: Any?) {
        presentSettingsWindow()
    }

    public func openAbout(_: Any?) {
        presentAboutWindow()
    }

    public func checkForUpdates(_ sender: Any?) {
        updateController?.checkForUpdates(sender)
    }

    public func setAsDefaultBrowser(_: Any?) {
        guard !defaultBrowserService.isDefaultBrowser else {
            refreshSetAsDefaultBrowserMenuItem()
            return
        }

        defaultBrowserService.setAsDefaultBrowser()
        refreshSetAsDefaultBrowserMenuItem()
    }

    public func requestApplicationTermination(_ sender: Any?) {
        guard !isTerminationRequested else {
            return
        }

        if shouldPresentQuitWarning {
            presentQuitWarning(sender)
            return
        }

        beginApplicationTermination()
    }

    public func toggleSidebar(_: Any?) {
        guard activeChromeModel?.isWebApp != true else {
            return
        }

        activeChromeModel?.toggleSidebar()
    }

    public func toggleBookmarksBar(_: Any?) {
        userPreferencesStore.bookmarksBarVisible.toggle()
    }

    public func toggleSidebarPosition(_: Any?) {
        userPreferencesStore.sidebarPosition = userPreferencesStore.sidebarPosition.opposite
    }

    public func toggleSiteToolbar(_: Any?) {
        userPreferencesStore.siteURLToolbarEnabled.toggle()
    }

    public func stopLoadingCurrentTab(_: Any?) {
        activeChromeModel?.stopLoadingCurrentTab()
    }

    public func showDeveloperTools(_: Any?) {
        activeChromeModel?.showDeveloperTools()
    }

    public func viewSource(_: Any?) {
        activeChromeModel?.viewSourceOfSelectedTab()
    }

    public func zoomIn(_: Any?) {
        activeChromeModel?.zoomIn()
    }

    public func zoomOut(_: Any?) {
        activeChromeModel?.zoomOut()
    }

    public func resetZoom(_: Any?) {
        activeChromeModel?.resetZoom()
    }

    public func restoreLastClosedTab(_: Any?) {
        activeChromeModel?.restoreLastClosedTab()
    }

    public func openLocation(_: Any?) {
        guard activeChromeModel?.canOpenLocation == true else { return }
        activeChromeModel?.presentCurrentPageCommandBar()
    }

    public func viewDownloads(_: Any?) {
        activeChromeModel?.toggleDownloads()
    }

    public func inspectElements(_: Any?) {
        activeChromeModel?.inspectElements()
    }

    public func showJavaScriptConsole(_: Any?) {
        activeChromeModel?.showJavaScriptConsole()
    }

    public func viewLibrary(_: Any?) {
        activeChromeModel?.toggleLibrary()
    }

    // MARK: AppleScript

    public func application(_: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "appleScriptWindows" || key == "appleScriptTabs"
    }

    public func shareCurrentTab(_: Any?) {
        activeChromeModel?.shareSelectedTab()
    }

    public func manageSpaces(_: Any?) {
        activeChromeModel?.openSpacesInLibrary()
    }

    public func editSpaceTheme(_: Any?) {
        guard let model = activeChromeModel, let spaceID = model.selectedSpaceID else { return }
        model.onEditSpaceTheme?(spaceID)
    }

    public func renameSpace(_: Any?) {
        activeChromeModel?.sidebarSpaceRenameRequestID &+= 1
    }

    public func togglePinnedTabsCollapsed(_: Any?) {
        activeChromeModel?.toggleActiveSpacePinnedSectionCollapsed()
    }

    public func castCurrentPage(_: Any?) {
        activeChromeModel?.castCurrentPage()
    }

    public func showNetworkInspector(_: Any?) {
        activeChromeModel?.showNetworkInspector()
    }

    public func chooseAppearance(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let preference = BrowserAppearancePreference(rawValue: raw)
        else { return }
        userPreferencesStore.appearancePreference = preference
    }

    public func toggleDeveloperMode(_: Any?) {
        activeChromeModel?.toggleDeveloperMode()
    }

    public func toggleJavaScriptFromAppleEvents(_: Any?) {
        userPreferencesStore.allowsJavaScriptFromAppleEvents.toggle()
    }

    public func toggleStayOnTop(_: Any?) {
        guard let window = activeBrowserWindow else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    public func selectNextSpace(_: Any?) {
        activeChromeModel?.selectNextSpace()
    }

    public func selectPreviousSpace(_: Any?) {
        activeChromeModel?.selectPreviousSpace()
    }

    public func togglePinTab(_: Any?) {
        activeChromeModel?.togglePinSelectedTab()
    }

    public func duplicateTab(_: Any?) {
        activeChromeModel?.duplicateSelectedTab()
    }

    public func renameTab(_: Any?) {
        activeChromeModel?.renameSelectedTab()
    }

    public func resetTabToPinnedURL(_: Any?) {
        activeChromeModel?.resetSelectedTabToPinnedURL()
    }

    public func resetSpaceTabs(_: Any?) {
        activeChromeModel?.resetSpaceTabs()
    }

    public func collapseAllFolders(_: Any?) {
        activeChromeModel?.setActiveSpaceFoldersExpanded(false)
    }

    public func expandAllFolders(_: Any?) {
        activeChromeModel?.setActiveSpaceFoldersExpanded(true)
    }

    public func createFolderFromSelectedTab(_: Any?) {
        activeChromeModel?.createFolderFromSelectedTab()
    }

    public func captureFullPage(_: Any?) {
        activeChromeModel?.captureFullPageSelectedTabToPasteboard()
    }

    public func capturePortrait(_: Any?) {
        activeChromeModel?.beginPortraitCapture()
    }

    public func captureArea(_: Any?) {
        activeChromeModel?.beginAreaCapture()
    }

    public func createNewSpace(_: Any?) {
        activeChromeModel?.beginCreatingSpace()
    }

    /// A Spaces menu item; its tag is the Space's position.
    public func selectSpaceFromMenu(_ sender: Any?) {
        _ = selectSpace(at: (sender as? NSMenuItem)?.tag ?? 0)
    }

    public func openExtensions(_: Any?) {
        activeChromeModel?.openExtensionsControlCenter()
    }

    public func revealCurrentTab(_: Any?) {
        activeChromeModel?.revealSelectedTabInSidebar()
    }

    public func copySelectedTabLinkAsMarkdown(_: Any?) {
        activeChromeModel?.copySelectedTabLinkAsMarkdown()
    }

    public func copySelectedTextAsQuoteLink(_: Any?) {
        guard let model = activeChromeModel else { return }
        Task { @MainActor in
            if await !model.copySelectedTextAsQuoteLink() {
                NSSound.beep()
            }
        }
    }

    public func selectNextTab(_: Any?) {
        activeChromeModel?.selectAdjacentSidebarItem(offset: 1)
    }

    public func selectPreviousTab(_: Any?) {
        activeChromeModel?.selectAdjacentSidebarItem(offset: -1)
    }

    /// The menu item's tag is the sidebar position, counted from 0.
    public func goToSidebarItem(_ sender: Any?) {
        activeChromeModel?.selectSidebarItem(at: (sender as? NSMenuItem)?.tag ?? 0)
    }

    public func goToLastSidebarItem(_: Any?) {
        activeChromeModel?.selectLastSidebarItem()
    }

    public func createNewTab(_: Any?) {
        guard activeChromeModel?.isWebApp != true else {
            return
        }

        activeChromeModel?.toggleCommandBar()
    }

    public func togglePictureInPicture(_: Any?) {
        activeChromeModel?.togglePictureInPicture()
    }

    public func createNewWindow(_: Any?) {
        openNewWindow()
    }

    public func createBlankWindow(_: Any?) {
        createIncognitoWindow(copyingFullscreenFrom: activeBrowserWindow, blank: true)
    }

    public func createNewIncognitoWindow(_: Any?) {
        createIncognitoWindow(copyingFullscreenFrom: activeBrowserWindow)
    }

    public func createNewLittleWindow(_: Any?) {
        littleWindowModel?.openNewLittleWindow()
    }

    public func openHistory(_: Any?) {
        openBrowserInternalPage(BrowserInternalPageRouting.historyURL)
    }

    public func toggleCurrentPageBookmark(_: Any?) {
        activeChromeModel?.toggleSelectedTabBookmark()
    }

    public func archiveCurrentTab(_: Any?) {
        guard !closeActiveAuxiliaryWindow() else { return }
        activeChromeModel?.archiveSelectedTab()
    }

    public func showArchive(_: Any?) {
        guard let model = archiveContextModel else { return }
        _ = performArchiveCommand(.viewArchive, from: model)
    }

    public func clearArchive(_: Any?) {
        guard let model = archiveContextModel else { return }
        _ = performArchiveCommand(.clearArchive, from: model)
    }

    public func goBack(_: Any?) {
        activeChromeModel?.goBack()
    }

    public func goForward(_: Any?) {
        activeChromeModel?.goForward()
    }

    public func reloadCurrentTab(_: Any?) {
        activeChromeModel?.reloadCurrentTab()
    }

    public func forceReloadCurrentTab(_: Any?) {
        activeChromeModel?.forceReloadCurrentTab()
    }

    public func clearCacheAndRefreshCurrentTab(_: Any?) {
        activeChromeModel?.clearCacheAndRefreshCurrentTab()
    }

    public func clearCookiesAndRefreshCurrentTab(_: Any?) {
        activeChromeModel?.clearCookiesAndRefreshCurrentTab()
    }

    public func saveCurrentPage(_: Any?) {
        activeChromeModel?.saveCurrentPage()
    }

    public func addSplitView(_: Any?) {
        activeChromeModel?.presentSplitViewCommandBar()
    }

    public func closeSplitPane(_: Any?) {
        activeChromeModel?.closeFocusedSplitPane()
    }

    public func separateTabFromSplit(_: Any?) {
        activeChromeModel?.separateSelectedTabFromSplit()
    }

    public func separateSplitView(_: Any?) {
        activeChromeModel?.separateSelectedSplitGroup()
    }

    public func toggleSplitOrientation(_: Any?) {
        activeChromeModel?.toggleSelectedSplitOrientation()
    }

    public func expandCurrentSplit(_: Any?) {
        activeChromeModel?.toggleExpandedSplitPane()
    }

    public func pasteAndMatchStyle(_ sender: Any?) {
        _ = performPasteAndMatchStyle(sender)
    }

    public func printCurrentPage(_: Any?) {
        activeChromeModel?.printCurrentPage()
    }

    public func copySelectedTabLink(_: Any?) {
        activeChromeModel?.copySelectedTabLink()
    }

    public func findInPage(_: Any?) {
        if let archive = focusedArchiveWindowController {
            archive.archiveController.focusSearch()
            return
        }
        _ = activeChromeModel?.presentFindInPage()
    }

    public func findAndReplace(_: Any?) {}

    public func findNextInPage(_: Any?) {
        activeChromeModel?.findNextInPage()
    }

    public func findPreviousInPage(_: Any?) {
        activeChromeModel?.findPreviousInPage()
    }

    public func useSelectionToFind(_: Any?) {
        activeChromeModel?.useSelectionForFind()
    }

    public func jumpToSelection(_: Any?) {
        activeChromeModel?.jumpToSelection()
    }

    public func clearTemporaryTabs(_: Any?) {
        activeChromeModel?.clearTemporaryTabs()
    }

    public func installCurrentSiteAsApp(_: Any?) {
        presentWebAppInstallationPrompt()
    }

    public func showCurrentWebAppInfo(_: Any?) {
        presentCurrentWebAppInfo()
    }

    public func openCurrentWebAppInBrowser(_: Any?) {
        openCurrentWebAppPageInBrowser()
    }

    public func uninstallCurrentWebApp(_: Any?) {
        presentCurrentWebAppUninstallPrompt()
    }

    public func toggleWebAppToolbarInFullscreen(_: Any?) {
        guard let preferences = webAppWindowSession?.preferences else {
            return
        }

        preferences.alwaysShowsToolbarInFullscreen.toggle()
        installMainMenu(for: NSApp)
    }

    public func toggleWebAppAlwaysShowsFullURLs(_: Any?) {
        guard let preferences = webAppWindowSession?.preferences else {
            return
        }

        preferences.alwaysShowsFullURLs.toggle()
        installMainMenu(for: NSApp)
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else {
            return true
        }

        switch action {
        case #selector(createNewTab(_:)):
            return activeChromeModel?.canCreateTab == true && activeChromeModel?.isWebApp != true
        case #selector(stopLoadingCurrentTab(_:)):
            return activeChromeModel?.canStopLoading ?? false
        case #selector(showDeveloperTools(_:)):
            return activeChromeModel?.canShowDeveloperTools ?? false
        case #selector(viewSource(_:)):
            return activeChromeModel?.canViewSource ?? false
        case #selector(zoomIn(_:)):
            return activeChromeModel?.canZoomIn ?? false
        case #selector(zoomOut(_:)):
            return activeChromeModel?.canZoomOut ?? false
        case #selector(resetZoom(_:)):
            return activeChromeModel?.canResetZoom ?? false
        case #selector(restoreLastClosedTab(_:)):
            return activeChromeModel?.canRestoreLastClosedTab ?? false
        case #selector(openLocation(_:)):
            return activeChromeModel?.canOpenLocation ?? false
        case #selector(createNewWindow(_:)):
            return !isTerminationRequested
        case #selector(togglePictureInPicture(_:)):
            if let title = activeChromeModel?.pictureInPictureMenuTitle {
                (item as? NSMenuItem)?.title = title
            }
            return activeChromeModel?.canTogglePictureInPicture ?? false
        case #selector(createNewIncognitoWindow(_:)):
            return !isTerminationRequested
        case #selector(createNewLittleWindow(_:)):
            return !isTerminationRequested && littleWindowModel?.canOpenLittleWindow == true
        case #selector(openHistory(_:)):
            return activeChromeModel != nil && !isTerminationRequested
        case #selector(archiveCurrentTab(_:)):
            return focusedArchiveWindowController != nil || activeChromeModel?.canArchiveSelectedTab == true
        case #selector(showArchive(_:)):
            return !isTerminationRequested && archiveContextModel?.canBrowseArchive == true
        case #selector(clearArchive(_:)):
            return !isTerminationRequested && archiveContextModel?.canBrowseArchive == true &&
                archiveContextModel?.isArchiveOperationInFlight == false
        case #selector(goBack(_:)):
            return activeChromeModel?.canGoBack ?? false
        case #selector(goForward(_:)):
            return activeChromeModel?.canGoForward ?? false
        case #selector(clearCacheAndRefreshCurrentTab(_:)),
             #selector(clearCookiesAndRefreshCurrentTab(_:)),
             #selector(forceReloadCurrentTab(_:)),
             #selector(reloadCurrentTab(_:)):
            return activeChromeModel?.canReload ?? false
        case #selector(saveCurrentPage(_:)):
            return activeChromeModel?.canSavePage ?? false
        case #selector(addSplitView(_:)):
            return activeChromeModel?.isWebApp != true && activeChromeModel?.canAddSplitView == true
        case #selector(closeSplitPane(_:)),
             #selector(separateSplitView(_:)),
             #selector(separateTabFromSplit(_:)):
            return activeChromeModel?.selectedSplitGroup != nil
        case #selector(toggleSplitOrientation(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = activeChromeModel?.splitOrientationToggleTitle
                    ?? BrowserStrings.splitConvertToVerticalAction
            }
            return activeChromeModel?.selectedSplitGroup != nil
        case #selector(expandCurrentSplit(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = activeChromeModel?.isSelectedSplitPaneExpanded == true
                    ? BrowserStrings.menuShowAllSplitPanes
                    : BrowserStrings.menuExpandCurrentSplit
            }
            return activeChromeModel?.selectedSplitGroup != nil
        case #selector(pasteAndMatchStyle(_:)):
            return activeChromeModel?.canPasteAndMatchStyle ?? true
        case #selector(printCurrentPage(_:)):
            return activeChromeModel?.canPrintPage ?? false
        case #selector(copySelectedTabLink(_:)):
            return activeChromeModel?.canCopySelectedTabLink ?? false
        case #selector(findInPage(_:)):
            return focusedArchiveWindowController != nil || activeChromeModel?.canPresentFindInPage == true
        case #selector(findNextInPage(_:)),
             #selector(findPreviousInPage(_:)):
            return activeChromeModel?.canStepThroughFindMatches ?? false
        case #selector(findAndReplace(_:)):
            return false
        case #selector(jumpToSelection(_:)):
            return activeChromeModel?.canFindInPage ?? false
        case #selector(useSelectionToFind(_:)):
            return activeChromeModel?.canPresentFindInPage ?? false
        case #selector(clearTemporaryTabs(_:)):
            return activeChromeModel?.canClearTemporaryTabs ?? false
        case #selector(installCurrentSiteAsApp(_:)):
            if let menuItem = item as? NSMenuItem {
                updateInstallWebAppMenuItem(menuItem)
            }
            return activeChromeModel?.canInstallSelectedSiteAsApp ?? false
        case #selector(openCurrentWebAppInBrowser(_:)),
             #selector(showCurrentWebAppInfo(_:)),
             #selector(toggleWebAppAlwaysShowsFullURLs(_:)),
             #selector(toggleWebAppToolbarInFullscreen(_:)),
             #selector(uninstallCurrentWebApp(_:)):
            return webAppWindowSession != nil && !isTerminationRequested
        case #selector(toggleDeveloperMode(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = activeChromeModel?.isDeveloperModeOn == true
                    ? BrowserStrings.menuTurnOffDeveloperMode
                    : BrowserStrings.menuTurnOnDeveloperMode
            }
            return activeChromeModel?.canToggleDeveloperMode ?? false
        case #selector(toggleJavaScriptFromAppleEvents(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.state = userPreferencesStore.allowsJavaScriptFromAppleEvents ? .on : .off
            }
            return true
        case #selector(toggleStayOnTop(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.state = activeBrowserWindow?.level == .floating ? .on : .off
            }
            return activeBrowserWindow != nil
        case #selector(chooseAppearance(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.state = menuItem.representedObject as? String == userPreferencesStore.appearancePreference
                    .rawValue ? .on : .off
            }
            return true
        case #selector(togglePinnedTabsCollapsed(_:)):
            if let menuItem = item as? NSMenuItem, let model = activeChromeModel {
                menuItem.title = model.isActiveSpacePinnedSectionCollapsed
                    ? BrowserStrings.menuExpandPinnedTabs
                    : BrowserStrings.menuCollapsePinnedTabs
            }
            return activeChromeModel?.supportsSpaces == true
        case #selector(editSpaceTheme(_:)), #selector(manageSpaces(_:)), #selector(renameSpace(_:)):
            return activeChromeModel.map { !$0.isWebApp && $0.supportsSpaces } ?? false
        case #selector(castCurrentPage(_:)):
            return activeChromeModel?.canCastPage ?? false
        case #selector(showNetworkInspector(_:)):
            return activeChromeModel?.canShowDeveloperTools ?? false
        case #selector(shareCurrentTab(_:)):
            return activeChromeModel?.currentTab != nil
        case #selector(toggleBookmarksBar(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.state = userPreferencesStore.bookmarksBarVisible ? .on : .off
            }
            return true
        case #selector(toggleSiteToolbar(_:)):
            if let menuItem = item as? NSMenuItem, let model = activeChromeModel {
                menuItem.title = model.siteToolbarToggleTitle
            }
            return activeChromeModel?.isWebApp == false
        case #selector(selectNextSpace(_:)),
             #selector(selectPreviousSpace(_:)):
            return activeChromeModel.map { !$0.isWebApp && $0.supportsSpaces && $0.spaces.count > 1 } ?? false
        case #selector(openExtensions(_:)):
            return activeChromeModel?.canOpenExtensions ?? false
        case #selector(togglePinTab(_:)):
            if let menuItem = item as? NSMenuItem, let model = activeChromeModel {
                menuItem.title = model.pinToggleTitle
            }
            return activeChromeModel?.canTogglePinSelectedTab ?? false
        case #selector(duplicateTab(_:)):
            return activeChromeModel.map { model in model.selectedTabID.map(model.canDuplicateTab) ?? false } ?? false
        case #selector(renameTab(_:)):
            return activeChromeModel?.canRenameSelectedTab ?? false
        case #selector(resetTabToPinnedURL(_:)):
            return activeChromeModel?.canResetSelectedTabToPinnedURL ?? false
        case #selector(resetSpaceTabs(_:)):
            return activeChromeModel?.canResetSpaceTabs() ?? false
        case #selector(collapseAllFolders(_:)):
            return activeChromeModel?.canSetActiveSpaceFoldersExpanded(false) ?? false
        case #selector(expandAllFolders(_:)):
            return activeChromeModel?.canSetActiveSpaceFoldersExpanded(true) ?? false
        case #selector(createFolderFromSelectedTab(_:)):
            return activeChromeModel?.canCreateFolderFromSelectedTab ?? false
        case #selector(captureFullPage(_:)):
            return activeChromeModel.map { $0.canCreateTab && $0.selectedTabID != nil } ?? false
        case #selector(captureArea(_:)),
             #selector(capturePortrait(_:)):
            return activeChromeModel?.canCaptureArea ?? false
        case #selector(createNewSpace(_:)):
            return activeChromeModel.map { $0.supportsSpaces && !$0.isWebApp } ?? false
        case #selector(selectSpaceFromMenu(_:)):
            if let menuItem = item as? NSMenuItem, let model = activeChromeModel {
                menuItem.state = model.spaces.indices.contains(menuItem.tag)
                    && model.spaces[menuItem.tag].id == model.selectedSpaceID ? .on : .off
            }
            return activeChromeModel?.supportsSpaces ?? false
        case #selector(revealCurrentTab(_:)):
            return activeChromeModel?.canRevealSelectedTab ?? false
        case #selector(copySelectedTabLinkAsMarkdown(_:)):
            return activeChromeModel?.canCopySelectedTabLink ?? false
        case #selector(copySelectedTextAsQuoteLink(_:)):
            return activeChromeModel?.canCopySelectedTextAsQuoteLink ?? false
        case #selector(viewDownloads(_:)):
            return activeChromeModel?.onToggleDownloads != nil
        case #selector(toggleSidebar(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = activeChromeModel?.isSidebarVisible == false
                    ? BrowserStrings.menuShowSidebar
                    : BrowserStrings.menuHideSidebar
            }
            return activeChromeModel != nil
        case #selector(viewLibrary(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = activeChromeModel?.librarySection == nil
                    ? BrowserStrings.menuViewLibrary
                    : BrowserStrings.menuCloseLibrary
            }
            return activeChromeModel?.supportsSpaces ?? false
        case #selector(goToLastSidebarItem(_:)),
             #selector(selectNextTab(_:)),
             #selector(selectPreviousTab(_:)):
            return activeChromeModel.map { !$0.isWebApp && !$0.sidebarItemTabIDs.isEmpty } ?? false
        case #selector(goToSidebarItem(_:)):
            let index = (item as? NSMenuItem)?.tag ?? 0
            return activeChromeModel.map { !$0.isWebApp && $0.sidebarItemTabIDs.count > index } ?? false
        case #selector(toggleSidebarPosition(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = userPreferencesStore.sidebarPosition == .left
                    ? BrowserStrings.menuMoveSidebarRight
                    : BrowserStrings.menuMoveSidebarLeft
            }
            return activeChromeModel?.isWebApp != true
        case #selector(setAsDefaultBrowser(_:)):
            return updateSetAsDefaultBrowserMenuItem(item as? NSMenuItem)
        case #selector(checkForUpdates(_:)):
            return updateController?.canCheckForUpdates ?? false
        default:
            return true
        }
    }

    func insertInAppleScriptTabs(_ tab: BrowserScriptTab) {
        guard let url = tab.pendingURLString.flatMap(URL.init(string:)) else {
            littleWindowModel?.openNewLittleWindow()
            return
        }
        littleWindowModel?.openInLittleWindow(url)
    }

    func insertInAppleScriptWindows(_ scriptWindow: BrowserScriptWindow) {
        if scriptWindow.mode == "incognito" {
            createIncognitoWindow(copyingFullscreenFrom: nil)
            if let session = incognitoWindowSessions.last {
                scriptWindow.attach(window: session.window, model: session.chromeModel)
            }
        } else if openNewWindow(), let session = profileWindowSessions.last {
            scriptWindow.attach(window: session.window, model: session.chromeModel)
        }
    }

    /// GitHub's list changes slowly: coming back to the app looks again, at most every few minutes.
    private func refreshLiveFoldersIfDue() {
        guard Date().timeIntervalSince(lastLiveFolderRefresh) > 300 else { return }
        lastLiveFolderRefresh = Date()
        for session in profileWindowSessions {
            session.chromeModel.refreshGitHubLiveFolders()
        }
    }

    @nonobjc private func showArchive(for model: BrowserChromeModel) -> BrowserArchiveWindowController? {
        guard !isTerminationRequested, model.canBrowseArchive,
              profileWindowSessions.contains(where: { $0.chromeModel === model }) else { return nil }
        let key = ObjectIdentifier(model)
        if let existing = archiveWindowControllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = BrowserArchiveWindowController(model: model)
        controller.onClose = { [weak self] in self?.archiveWindowControllers.removeValue(forKey: key) }
        controller.onRestore = { [weak self, weak model] in
            guard let self, let model,
                  let window = profileWindowSessions.first(where: { $0.chromeModel === model })?.window else { return }
            window.makeKeyAndOrderFront(nil)
        }
        archiveWindowControllers[key] = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func profileWindowSession(containing candidateWindow: NSWindow?) -> BrowserProfileWindowSession? {
        var currentWindow = candidateWindow
        while let window = currentWindow {
            if let session = profileWindowSessions.first(where: { $0.window === window }) {
                return session
            }
            currentWindow = window.parent
        }

        return nil
    }

    private func incognitoWindowSession(containing candidateWindow: NSWindow?) -> BrowserIncognitoWindowSession? {
        var currentWindow = candidateWindow
        while let window = currentWindow {
            if let session = incognitoWindowSessions.first(where: { $0.window === window }) {
                return session
            }
            currentWindow = window.parent
        }

        return nil
    }

    private func beginApplicationTermination() {
        guard !isSessionClosureConfirmationPresented else { return }
        guard BrowserSessionClosureGuard.prepare(
            models: { allChromeModels },
            confirmation: confirmUnsavedSessionClosure,
        ) else {
            didConfirmTerminationWarning = false
            return
        }
        isTerminationRequested = true
        handleApplicationWillTerminate()
        for session in profileWindowSessions {
            session.window.orderOut(nil)
        }
        for session in incognitoWindowSessions {
            session.window.orderOut(nil)
        }
        webAppWindowSession?.window.orderOut(nil)
        DispatchQueue.main.async {
            if BrowserHasOpenBrowsers() != 0 {
                BrowserCloseAllBrowsers()
                return
            }

            NSApp.stop(nil)
        }
    }

    private func confirmUnsavedSessionClosure(_ models: [BrowserChromeModel]) -> BrowserSessionClosureGuard.Decision {
        guard !isSessionClosureConfirmationPresented else { return .cancel }
        isSessionClosureConfirmationPresented = true
        defer { isSessionClosureConfirmationPresented = false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BrowserStrings.sessionRecoveryCloseTitle
        alert.informativeText = BrowserStrings.sessionRecoveryCloseMessage
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        let retry = alert.addButton(withTitle: BrowserStrings.sessionRecoveryRetry)
        retry.isEnabled = models.allSatisfy { $0.sessionPersistenceFailure?.isRetryable == true }
        alert.addButton(withTitle: BrowserStrings.sessionRecoveryCloseWithoutSaving)
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .retry
        case .alertThirdButtonReturn: return .discardUnsaved
        default: return .cancel
        }
    }

    private func tearDownBrowserWindowSessions() {
        let windows = (webAppWindowSession.map { [$0.window] } ?? [])
            + profileWindowSessions.map(\.window)
            + incognitoWindowSessions.map(\.window)
        webAppWindowSession = nil
        let archiveControllers = Array(archiveWindowControllers.values)
        archiveWindowControllers.removeAll()
        for controller in archiveControllers {
            controller.close()
        }
        profileWindowSessions.removeAll()
        incognitoWindowSessions.removeAll()

        for window in windows {
            tearDownWindow(window)
        }
    }

    private func tearDownWindow(_ window: NSWindow?) {
        guard let window else {
            return
        }

        window.delegate = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    private func removeLayoutIndependentKeyMonitor() {
        guard let layoutIndependentKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(layoutIndependentKeyMonitor)
        self.layoutIndependentKeyMonitor = nil
    }

    private func installMainMenu(for app: NSApplication) {
        if let webAppWindowSession {
            installWebAppMainMenu(for: app, session: webAppWindowSession)
            return
        }

        let menubar = NSMenu()
        let appMenuItem = NSMenuItem()
        let fileMenuItem = NSMenuItem()
        let editMenuItem = NSMenuItem()
        let viewMenuItem = NSMenuItem()
        fileMenuItem.title = BrowserStrings.menuFile
        editMenuItem.title = BrowserStrings.menuEdit
        viewMenuItem.title = BrowserStrings.menuView
        menubar.addItem(appMenuItem)
        menubar.addItem(fileMenuItem)
        menubar.addItem(editMenuItem)
        menubar.addItem(viewMenuItem)
        let spacesMenuItem = NSMenuItem()
        spacesMenuItem.title = BrowserStrings.menuSpaces
        menubar.addItem(spacesMenuItem)
        let tabsMenuItem = NSMenuItem()
        tabsMenuItem.title = BrowserStrings.menuTabs
        menubar.addItem(tabsMenuItem)
        addArchiveMenu(to: menubar)
        addExtensionsMenu(to: menubar)
        addWindowMenu(to: menubar, app: app)
        addLibraryItems(toWindowMenuOf: app)
        addHelpMenu(to: menubar, app: app)
        app.mainMenu = menubar

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        let aboutItem = NSMenuItem(
            title: BrowserStrings.aboutMenuItem(appName: appName),
            action: #selector(openAbout(_:)),
            keyEquivalent: "",
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .openSettings),
            action: #selector(openSettings(_:)),
        )
        appMenu.addItem(settingsItem)

        let checkForUpdatesItem = NSMenuItem(
            title: BrowserStrings.menuCheckForUpdates,
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: "",
        )
        checkForUpdatesItem.target = self
        appMenu.addItem(checkForUpdatesItem)

        let setAsDefaultBrowserItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .setAsDefaultBrowser),
            action: #selector(setAsDefaultBrowser(_:)),
        )
        setAsDefaultBrowserMenuItem = setAsDefaultBrowserItem
        updateSetAsDefaultBrowserMenuItem(setAsDefaultBrowserItem)
        appMenu.addItem(setAsDefaultBrowserItem)
        appMenu.addItem(BrowserNativeMenuItem(BrowserStrings.menuImportFromBrowser) { [weak self] in
            self?.presentSettingsWindow(pane: .general)
        })
        addStandardApplicationItems(to: appMenu, app: app, appName: appName)
        let quitItem = NSMenuItem(
            title: BrowserStrings.quitMenuItem(appName: appName),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q",
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: BrowserStrings.menuFile)
        fileMenu.delegate = self
        let newTabItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newTab),
            action: #selector(createNewTab(_:)),
        )
        fileMenu.addItem(newTabItem)
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .openLocation),
            action: #selector(openLocation(_:)),
        ))
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .restoreLastClosedTab),
            action: #selector(restoreLastClosedTab(_:)),
        ))

        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newWindow),
            action: #selector(createNewWindow(_:)),
        ))
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .blankWindow),
            action: #selector(createBlankWindow(_:)),
        ))
        let newIncognitoWindowItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newIncognitoWindow),
            action: #selector(createNewIncognitoWindow(_:)),
        )
        fileMenu.addItem(newIncognitoWindowItem)
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newLittleWindow),
            action: #selector(createNewLittleWindow(_:)),
        ))
        // Command-W archives the tab, so the window closes with Shift-Command-W.
        fileMenu.addItem(makeStandardMenuItem(
            title: BrowserStrings.webAppCloseWindowAction,
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: standardKey("w", [.command, .shift]),
            modifiers: [.command, .shift],
        ))
        fileMenu.addItem(.separator())

        let toggleBookmarkItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleBookmark),
            action: #selector(toggleCurrentPageBookmark(_:)),
        )
        fileMenu.addItem(toggleBookmarkItem)

        let archiveTabItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .archiveTab),
            action: #selector(archiveCurrentTab(_:)),
        )
        fileMenu.addItem(archiveTabItem)
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .shareTab),
            action: #selector(shareCurrentTab(_:)),
        ))
        fileMenu.addItem(BrowserNativeMenuItem(BrowserStrings.menuNewProfile) { [weak self] in
            self?.presentSettingsWindow(pane: .profiles)
        })

        let savePageItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .savePage),
            action: #selector(saveCurrentPage(_:)),
        )
        fileMenu.addItem(savePageItem)
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .captureArea),
            action: #selector(captureArea(_:)),
        ))
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .captureFullPage),
            action: #selector(captureFullPage(_:)),
        ))
        fileMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .capturePortrait),
            action: #selector(capturePortrait(_:)),
        ))

        let installWebAppItem = NSMenuItem(
            title: BrowserStrings.webAppInstallAction,
            action: #selector(installCurrentSiteAsApp(_:)),
            keyEquivalent: "",
        )
        installWebAppItem.identifier = Self.installWebAppMenuItemIdentifier
        installWebAppItem.target = self
        updateInstallWebAppMenuItem(installWebAppItem)
        fileMenu.addItem(installWebAppItem)

        let printItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .printPage),
            action: #selector(printCurrentPage(_:)),
        )
        fileMenu.addItem(printItem)
        fileMenuItem.submenu = fileMenu

        let editMenu = NSMenu(title: BrowserStrings.menuEdit)
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuUndo,
                action: #selector(UndoManager.undo),
                keyEquivalent: "z",
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuRedo,
                action: #selector(UndoManager.redo),
                keyEquivalent: "z",
                modifiers: [.command, .shift],
            ),
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuCut,
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x",
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuCopy,
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c",
            ),
        )
        editMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .copyLink),
                action: #selector(copySelectedTabLink(_:)),
            ),
        )
        editMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .copyLinkAsMarkdown),
                action: #selector(copySelectedTabLinkAsMarkdown(_:)),
            ),
        )
        editMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .copyLinkAsQuote),
                action: #selector(copySelectedTextAsQuoteLink(_:)),
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuPaste,
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v",
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuPasteAndMatchStyle,
                action: #selector(pasteAndMatchStyle(_:)),
                keyEquivalent: "v",
                modifiers: [.command, .shift],
                target: self,
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuDelete,
                action: #selector(NSText.delete(_:)),
                keyEquivalent: "",
                modifiers: [],
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuSelectAll,
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a",
            ),
        )
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem()
        findMenuItem.title = BrowserStrings.menuFindTitle
        editMenu.addItem(findMenuItem)
        let findMenu = NSMenu(title: BrowserStrings.menuFindTitle)
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findInPage),
                action: #selector(findInPage(_:)),
            ),
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findAndReplace),
                action: #selector(findAndReplace(_:)),
            ),
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findNext),
                action: #selector(findNextInPage(_:)),
            ),
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findPrevious),
                action: #selector(findPreviousInPage(_:)),
            ),
        )
        findMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuUseSelectionToFind,
                action: #selector(useSelectionToFind(_:)),
                keyEquivalent: "",
                target: self,
            ),
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .jumpToSelection),
                action: #selector(jumpToSelection(_:)),
            ),
        )
        findMenuItem.submenu = findMenu
        addTextServicesMenus(to: editMenu)
        editMenuItem.submenu = editMenu

        let viewMenu = NSMenu(title: BrowserStrings.menuView)
        addAppearanceMenu(to: viewMenu)
        viewMenu.addItem(.separator())
        let toggleSidebarItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleSidebar),
            action: #selector(toggleSidebar(_:)),
        )
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleSidebarPosition),
            action: #selector(toggleSidebarPosition(_:)),
        ))
        viewMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleSiteToolbar),
            action: #selector(toggleSiteToolbar(_:)),
        ))
        let toggleBookmarksBarItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleBookmarksBar),
            action: #selector(toggleBookmarksBar(_:)),
        )
        toggleBookmarksBarItem.state = userPreferencesStore.bookmarksBarVisible ? .on : .off
        viewMenu.addItem(toggleBookmarksBarItem)
        let collapsePinnedItem = NSMenuItem(
            title: BrowserStrings.menuCollapsePinnedTabs,
            action: #selector(togglePinnedTabsCollapsed(_:)),
            keyEquivalent: "",
        )
        collapsePinnedItem.target = self
        viewMenu.addItem(collapsePinnedItem)
        viewMenu.addItem(.separator())

        viewMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .stopLoading),
            action: #selector(stopLoadingCurrentTab(_:)),
        ))
        let refreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .reload),
            action: #selector(reloadCurrentTab(_:)),
        )
        viewMenu.addItem(refreshItem)

        let forceRefreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .forceReload),
            action: #selector(forceReloadCurrentTab(_:)),
        )
        viewMenu.addItem(forceRefreshItem)

        let clearCacheAndRefreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .clearCacheAndRefresh),
            action: #selector(clearCacheAndRefreshCurrentTab(_:)),
        )
        viewMenu.addItem(clearCacheAndRefreshItem)

        let clearCookiesAndRefreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .clearCookiesAndRefresh),
            action: #selector(clearCookiesAndRefreshCurrentTab(_:)),
        )
        viewMenu.addItem(clearCookiesAndRefreshItem)

        viewMenu.addItem(.separator())

        for (commandID, action) in [
            (BrowserCommandID.addSplitView, #selector(addSplitView(_:))),
            (.closeSplitPane, #selector(closeSplitPane(_:))),
            (.separateTabFromSplit, #selector(separateTabFromSplit(_:))),
            (.separateSplitView, #selector(separateSplitView(_:))),
            (.toggleSplitOrientation, #selector(toggleSplitOrientation(_:))),
            (.expandCurrentSplit, #selector(expandCurrentSplit(_:))),
        ] {
            viewMenu.addItem(makeMenuItem(descriptor: shortcutStore.descriptor(for: commandID), action: action))
        }

        viewMenu.addItem(.separator())
        for (commandID, action) in [
            (BrowserCommandID.resetZoom, #selector(resetZoom(_:))),
            (.zoomIn, #selector(zoomIn(_:))),
            (.zoomOut, #selector(zoomOut(_:))),
        ] {
            viewMenu.addItem(makeMenuItem(descriptor: shortcutStore.descriptor(for: commandID), action: action))
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .togglePictureInPicture),
            action: #selector(togglePictureInPicture(_:)),
        ))
        let castItem = NSMenuItem(
            title: BrowserStrings.menuCast,
            action: #selector(castCurrentPage(_:)),
            keyEquivalent: "",
        )
        castItem.target = self
        viewMenu.addItem(castItem)
        addDeveloperMenu(to: viewMenu)
        viewMenu.addItem(.separator())
        viewMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .openExtensions),
            action: #selector(openExtensions(_:)),
        ))
        viewMenuItem.submenu = viewMenu

        // Tabs menu with OpenArc's tab actions.
        let tabsMenu = NSMenu(title: BrowserStrings.menuTabs)
        for (commandID, action) in [
            (BrowserCommandID.togglePinTab, #selector(togglePinTab(_:))),
            (.duplicateTab, #selector(duplicateTab(_:))),
            (.renameTab, #selector(renameTab(_:))),
            (.resetTabToPinnedURL, #selector(resetTabToPinnedURL(_:))),
        ] {
            tabsMenu.addItem(makeMenuItem(descriptor: shortcutStore.descriptor(for: commandID), action: action))
        }
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .selectNextTab),
            action: #selector(selectNextTab(_:)),
        ))
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .selectPreviousTab),
            action: #selector(selectPreviousTab(_:)),
        ))
        for (commandID, action) in [
            (BrowserCommandID.selectNextTabAlternate, #selector(selectNextTab(_:))),
            (.selectPreviousTabAlternate, #selector(selectPreviousTab(_:))),
        ] {
            let item = makeMenuItem(descriptor: shortcutStore.descriptor(for: commandID), action: action)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            tabsMenu.addItem(item)
        }
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .revealCurrentTab),
            action: #selector(revealCurrentTab(_:)),
        ))
        // Go to Sidebar Item has no visible menu entry; the hidden
        // items keep their key equivalents ahead of the page.
        let sidebarItemCommands: [BrowserCommandID] = [
            .goToSidebarItem1, .goToSidebarItem2, .goToSidebarItem3, .goToSidebarItem4,
            .goToSidebarItem5, .goToSidebarItem6, .goToSidebarItem7, .goToSidebarItem8,
        ]
        for commandID in sidebarItemCommands {
            let item = makeMenuItem(
                descriptor: shortcutStore.descriptor(for: commandID),
                action: #selector(goToSidebarItem(_:)),
            )
            item.tag = commandID.sidebarItemIndex
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            tabsMenu.addItem(item)
        }
        let lastSidebarItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .goToLastSidebarItem),
            action: #selector(goToLastSidebarItem(_:)),
        )
        lastSidebarItem.isHidden = true
        lastSidebarItem.allowsKeyEquivalentWhenHidden = true
        tabsMenu.addItem(lastSidebarItem)
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newFolder),
            action: #selector(createFolderFromSelectedTab(_:)),
        ))
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .collapseAllFolders),
            action: #selector(collapseAllFolders(_:)),
        ))
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .expandAllFolders),
            action: #selector(expandAllFolders(_:)),
        ))
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .clearTemporaryTabs),
            action: #selector(clearTemporaryTabs(_:)),
        ))
        tabsMenuItem.submenu = tabsMenu

        // Spaces menu: next/previous, then one item per Space, filled
        // when the menu opens.
        let spacesMenu = NSMenu(title: BrowserStrings.menuSpaces)
        spacesMenu.identifier = Self.spacesMenuIdentifier
        spacesMenu.delegate = self
        spacesMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newSpace),
            action: #selector(createNewSpace(_:)),
        ))
        for (title, action) in [
            (BrowserStrings.spaceEditThemeAction, #selector(editSpaceTheme(_:))),
            (BrowserStrings.menuRenameSpace, #selector(renameSpace(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            spacesMenu.addItem(item)
        }
        let changeProfileItem = NSMenuItem(title: BrowserStrings.menuChangeProfile, action: nil, keyEquivalent: "")
        changeProfileItem.identifier = Self.spaceProfileItemIdentifier
        changeProfileItem.submenu = NSMenu(title: BrowserStrings.menuChangeProfile)
        spacesMenu.addItem(changeProfileItem)
        spacesMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .selectNextSpace),
            action: #selector(selectNextSpace(_:)),
        ))
        spacesMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .selectPreviousSpace),
            action: #selector(selectPreviousSpace(_:)),
        ))
        spacesMenu.addItem(.separator())
        spacesMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .manageSpaces),
            action: #selector(manageSpaces(_:)),
        ))
        spacesMenu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .resetSpaceTabs),
            action: #selector(resetSpaceTabs(_:)),
        ))
        spacesMenuItem.submenu = spacesMenu
    }

    /// Archive holds the page's history and the archived tabs.
    private func addArchiveMenu(to menubar: NSMenu) {
        let menu = NSMenu(title: BrowserStrings.menuArchive)
        for (commandID, action) in [
            (BrowserCommandID.goBack, #selector(goBack(_:))),
            (.goForward, #selector(goForward(_:))),
            (.openHistory, #selector(openHistory(_:))),
        ] {
            menu.addItem(makeMenuItem(descriptor: shortcutStore.descriptor(for: commandID), action: action))
        }
        menu.addItem(.separator())
        for item in BrowserArchiveCommandRouting.menuItems(
            shortcutResolver: shortcutStore,
            viewAction: #selector(showArchive(_:)),
            clearAction: #selector(clearArchive(_:)),
            target: self,
        ) {
            menu.addItem(item)
        }
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        menubar.addItem(item)
    }

    /// One item per extension, filled when the menu opens.
    private func addExtensionsMenu(to menubar: NSMenu) {
        let menu = NSMenu(title: BrowserStrings.menuExtensions)
        menu.identifier = Self.extensionsMenuIdentifier
        menu.delegate = self
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        menubar.addItem(item)
    }

    private func updateExtensionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model = activeChromeModel else { return }
        model.refreshBrowserExtensions()
        for browserExtension in model.browserExtensions where browserExtension.isEnabled {
            let item = BrowserNativeMenuItem(browserExtension.name) { [weak model] in
                model?.requestExtensionOpen(id: browserExtension.id)
            }
            item.image = browserExtension.iconData.flatMap { NSImage(data: $0) }
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.extensionsAddAction) { [weak model] in
            model?.openExtensionStore()
        })
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.menuManageExtensions) { [weak model] in
            model?.openExtensionsManager()
        })
    }

    /// Stay On Top and the Library's sections, above the window list AppKit adds.
    private func addLibraryItems(toWindowMenuOf app: NSApplication) {
        guard let menu = app.windowsMenu else { return }
        let stayOnTop = NSMenuItem(
            title: BrowserStrings.menuStayOnTop,
            action: #selector(toggleStayOnTop(_:)),
            keyEquivalent: "",
        )
        stayOnTop.target = self
        menu.insertItem(stayOnTop, at: 0)
        let index = menu.items.lastIndex(where: \.isSeparatorItem) ?? menu.items.count
        var items = [NSMenuItem.separator()]
        items.append(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .viewLibrary),
            action: #selector(viewLibrary(_:)),
        ))
        items.append(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .viewDownloads),
            action: #selector(viewDownloads(_:)),
        ))
        items.append(BrowserNativeMenuItem(BrowserStrings.menuViewMedia) { [weak self] in
            self?.activeChromeModel?.openLibrary(section: .media)
        })
        for (offset, item) in items.enumerated() {
            menu.insertItem(item, at: index + offset)
        }
    }

    private func addHelpMenu(to menubar: NSMenu, app: NSApplication) {
        let menu = NSMenu(title: BrowserStrings.menuHelp)
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.menuKeyboardShortcuts) { [weak self] in
            self?.presentSettingsWindow(pane: .shortcuts)
        })
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.menuContactTeam) {
            if let url = URL(string: "mailto:support@openarc.su") {
                NSWorkspace.shared.open(url)
            }
        })
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.menuReportIssue) {
            if let url = URL(string: "https://github.com/levochkaa/OpenArc/issues") {
                NSWorkspace.shared.open(url)
            }
        })
        menu.addItem(.separator())
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.menuRevealData) {
            guard let path = BrowserRuntimeConfiguration.currentConfiguration()?.rootCachePath else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
        })
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.menuCopyInfo) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.applicationInfo, forType: .string)
        })
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        menubar.addItem(item)
        app.helpMenu = menu
    }

    /// The system's text services, for fields in pages and in the app.
    private func addTextServicesMenus(to editMenu: NSMenu) {
        func add(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let submenu = NSMenu(title: title)
            for (itemTitle, action, key, modifiers) in items {
                submenu.addItem(makeStandardMenuItem(
                    title: itemTitle,
                    action: action,
                    keyEquivalent: key,
                    modifiers: modifiers,
                ))
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            editMenu.addItem(item)
        }
        add(BrowserStrings.menuSpellingAndGrammar, [
            (
                BrowserStrings.menuShowSpelling,
                #selector(NSText.showGuessPanel(_:)),
                ":",
                [.command],
            ),
            (BrowserStrings.menuCheckDocument, #selector(NSText.checkSpelling(_:)), ";", [.command]),
            (
                BrowserStrings.menuCheckSpellingWhileTyping,
                #selector(NSTextView.toggleContinuousSpellChecking(_:)),
                "",
                [],
            ),
            (BrowserStrings.menuCheckGrammar, #selector(NSTextView.toggleGrammarChecking(_:)), "", []),
            (
                BrowserStrings.menuCorrectSpelling,
                #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
                "",
                [],
            ),
        ])
        add(BrowserStrings.menuSubstitutions, [
            (
                BrowserStrings.menuShowSubstitutions,
                #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
                "",
                [],
            ),
            (BrowserStrings.menuSmartCopyPaste, #selector(NSTextView.toggleSmartInsertDelete(_:)), "", []),
            (BrowserStrings.menuSmartQuotes, #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), "", []),
            (BrowserStrings.menuSmartDashes, #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), "", []),
            (BrowserStrings.menuSmartLinks, #selector(NSTextView.toggleAutomaticLinkDetection(_:)), "", []),
            (BrowserStrings.menuDataDetectors, #selector(NSTextView.toggleAutomaticDataDetection(_:)), "", []),
            (BrowserStrings.menuTextReplacement, #selector(NSTextView.toggleAutomaticTextReplacement(_:)), "", []),
        ])
        add(BrowserStrings.menuTransformations, [
            (BrowserStrings.menuMakeUpperCase, #selector(NSResponder.uppercaseWord(_:)), "", []),
            (BrowserStrings.menuMakeLowerCase, #selector(NSResponder.lowercaseWord(_:)), "", []),
            (BrowserStrings.menuCapitalize, #selector(NSResponder.capitalizeWord(_:)), "", []),
        ])
        add(BrowserStrings.menuSpeech, [
            (BrowserStrings.menuStartSpeaking, #selector(NSTextView.startSpeaking(_:)), "", []),
            (BrowserStrings.menuStopSpeaking, #selector(NSTextView.stopSpeaking(_:)), "", []),
        ])
    }

    /// Automatic, Light or Dark, for the whole app and the pages in it.
    private func addAppearanceMenu(to viewMenu: NSMenu) {
        let menu = NSMenu(title: BrowserStrings.menuAppearance)
        for preference in BrowserAppearancePreference.allCases {
            let item = NSMenuItem(
                title: preference.title,
                action: #selector(chooseAppearance(_:)),
                keyEquivalent: "",
            )
            item.representedObject = preference.rawValue
            item.target = self
            menu.addItem(item)
        }
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        viewMenu.addItem(item)
    }

    private func addDeveloperMenu(to viewMenu: NSMenu) {
        let menu = NSMenu(title: BrowserStrings.menuDeveloper)
        for (commandID, action) in [
            (BrowserCommandID.viewSource, #selector(viewSource(_:))),
            (.developerTools, #selector(showDeveloperTools(_:))),
            (.inspectElements, #selector(inspectElements(_:))),
            (.javaScriptConsole, #selector(showJavaScriptConsole(_:))),
        ] {
            menu.addItem(makeMenuItem(descriptor: shortcutStore.descriptor(for: commandID), action: action))
        }
        let javaScript = NSMenuItem(
            title: BrowserStrings.menuAllowJavaScriptFromAppleEvents,
            action: #selector(toggleJavaScriptFromAppleEvents(_:)),
            keyEquivalent: "",
        )
        javaScript.target = self
        let network = NSMenuItem(
            title: BrowserStrings.menuNetworkInspector,
            action: #selector(showNetworkInspector(_:)),
            keyEquivalent: "",
        )
        network.target = self
        menu.addItem(network)
        menu.addItem(javaScript)
        menu.addItem(makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleDeveloperMode),
            action: #selector(toggleDeveloperMode(_:)),
        ))
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        viewMenu.addItem(item)
    }

    /// Rebuilds the Space list after the first separator of the Spaces menu.
    private func updateSpacesMenu(_ menu: NSMenu) {
        updateSpaceProfileMenu(menu)
        for item in menu.items
            where item.action == #selector(selectSpaceFromMenu(_:)) || item.identifier == Self.spaceListEndIdentifier
        {
            menu.removeItem(item)
        }
        guard let model = activeChromeModel, model.supportsSpaces, !model.spaces.isEmpty,
              let separator = menu.items.firstIndex(where: \.isSeparatorItem)
        else { return }
        var position = separator + 1
        for (index, space) in model.spaces.enumerated() {
            let shortcut = BrowserSpaceShortcuts.shortcut(forSpaceIndex: index)
            let item = NSMenuItem(
                title: space.title,
                action: #selector(selectSpaceFromMenu(_:)),
                keyEquivalent: shortcut?.keyEquivalent ?? "",
            )
            item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
            item.image = BrowserIconImage.image(named: space.systemImageName, pointSize: 13)
            item.tag = index
            item.target = self
            menu.insertItem(item, at: position)
            position += 1
        }
        let end = NSMenuItem.separator()
        end.identifier = Self.spaceListEndIdentifier
        menu.insertItem(end, at: position)
    }

    private func updateSpaceProfileMenu(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.identifier == Self.spaceProfileItemIdentifier }),
              let submenu = item.submenu
        else { return }
        submenu.removeAllItems()
        guard let model = activeChromeModel, let spaceID = model.selectedSpaceID,
              let profiles = model.profileDirectories?.profiles(), !profiles.isEmpty
        else {
            item.isEnabled = false
            return
        }
        item.isEnabled = true
        let selected = model.profileDirectory(forSpaceID: spaceID)
        for profile in profiles {
            let choice = BrowserNativeMenuItem(profile.displayName) { [weak model] in
                model?.setProfile(profile.id, forSpaceID: spaceID)
            }
            choice.state = profile.id == selected ? .on : .off
            submenu.addItem(choice)
        }
    }

    private func installWebAppMainMenu(for app: NSApplication, session: BrowserWebAppWindowSession) {
        let menubar = NSMenu()
        let appMenuItem = NSMenuItem()
        let fileMenuItem = NSMenuItem()
        let editMenuItem = NSMenuItem()
        let viewMenuItem = NSMenuItem()
        let historyMenuItem = NSMenuItem()
        fileMenuItem.title = BrowserStrings.menuFile
        editMenuItem.title = BrowserStrings.menuEdit
        viewMenuItem.title = BrowserStrings.menuView
        historyMenuItem.title = BrowserStrings.menuHistory
        menubar.addItem(appMenuItem)
        menubar.addItem(fileMenuItem)
        menubar.addItem(editMenuItem)
        menubar.addItem(viewMenuItem)
        menubar.addItem(historyMenuItem)
        addWindowMenu(to: menubar, app: app)
        app.mainMenu = menubar

        let appMenu = NSMenu()
        let appInfoItem = NSMenuItem(
            title: BrowserStrings.webAppInfoAction,
            action: #selector(showCurrentWebAppInfo(_:)),
            keyEquivalent: "",
        )
        appInfoItem.target = self
        appMenu.addItem(appInfoItem)
        addStandardApplicationItems(to: appMenu, app: app, appName: session.configuration.name)
        let quitItem = NSMenuItem(
            title: BrowserStrings.quitMenuItem(appName: session.configuration.name),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q",
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: BrowserStrings.menuFile)
        let openInBrowserItem = NSMenuItem(
            title: BrowserStrings.webAppOpenInBrowserAction,
            action: #selector(openCurrentWebAppInBrowser(_:)),
            keyEquivalent: "",
        )
        openInBrowserItem.target = self
        fileMenu.addItem(openInBrowserItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .printPage),
                action: #selector(printCurrentPage(_:)),
            ),
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.webAppCloseWindowAction,
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w",
            ),
        )
        fileMenuItem.submenu = fileMenu

        let editMenu = NSMenu(title: BrowserStrings.menuEdit)
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuUndo,
                action: #selector(UndoManager.undo),
                keyEquivalent: "z",
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuRedo,
                action: #selector(UndoManager.redo),
                keyEquivalent: "z",
                modifiers: [.command, .shift],
            ),
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeStandardMenuItem(title: BrowserStrings.menuCut, action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuCopy,
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c",
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuPaste,
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v",
            ),
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuPasteAndMatchStyle,
                action: #selector(pasteAndMatchStyle(_:)),
                keyEquivalent: "v",
                modifiers: [.command, .shift],
                target: self,
            ),
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuSelectAll,
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a",
            ),
        )
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem()
        findMenuItem.title = BrowserStrings.menuFindTitle
        let findMenu = NSMenu(title: BrowserStrings.menuFindTitle)
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findInPage),
                action: #selector(findInPage(_:)),
            ),
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findNext),
                action: #selector(findNextInPage(_:)),
            ),
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findPrevious),
                action: #selector(findPreviousInPage(_:)),
            ),
        )
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)
        editMenuItem.submenu = editMenu

        let viewMenu = NSMenu(title: BrowserStrings.menuView)
        viewMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .reload),
                action: #selector(reloadCurrentTab(_:)),
            ),
        )
        viewMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .forceReload),
                action: #selector(forceReloadCurrentTab(_:)),
            ),
        )
        viewMenu.addItem(.separator())
        let toolbarItem = NSMenuItem(
            title: BrowserStrings.webAppAlwaysShowToolbarInFullscreen,
            action: #selector(toggleWebAppToolbarInFullscreen(_:)),
            keyEquivalent: "",
        )
        toolbarItem.target = self
        toolbarItem.state = session.preferences.alwaysShowsToolbarInFullscreen ? .on : .off
        viewMenu.addItem(toolbarItem)
        let fullURLItem = NSMenuItem(
            title: BrowserStrings.webAppAlwaysShowFullURLs,
            action: #selector(toggleWebAppAlwaysShowsFullURLs(_:)),
            keyEquivalent: "",
        )
        fullURLItem.target = self
        fullURLItem.state = session.preferences.alwaysShowsFullURLs ? .on : .off
        viewMenu.addItem(fullURLItem)
        viewMenuItem.submenu = viewMenu

        let historyMenu = NSMenu(title: BrowserStrings.menuHistory)
        historyMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .goBack),
                action: #selector(goBack(_:)),
            ),
        )
        historyMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .goForward),
                action: #selector(goForward(_:)),
            ),
        )
        historyMenuItem.submenu = historyMenu
    }

    /// Services and the Hide items every Mac app menu has, ending with the
    /// separator before Quit.
    /// A standard item keeps its key unless a command already uses it.
    private func standardKey(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> String {
        shortcutStore.command(using: BrowserKeyboardShortcut(key, modifiers: modifiers)) == nil ? key : ""
    }

    private func addStandardApplicationItems(to menu: NSMenu, app: NSApplication, appName: String) {
        menu.addItem(.separator())
        let servicesItem = NSMenuItem(title: BrowserStrings.menuServices, action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: BrowserStrings.menuServices)
        servicesItem.submenu = servicesMenu
        app.servicesMenu = servicesMenu
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(makeStandardMenuItem(
            title: BrowserStrings.hideMenuItem(appName: appName),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: standardKey("h"),
        ))
        menu.addItem(makeStandardMenuItem(
            title: BrowserStrings.menuHideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: standardKey("h", [.command, .option]),
            modifiers: [.command, .option],
        ))
        menu.addItem(makeStandardMenuItem(
            title: BrowserStrings.menuShowAll,
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "",
            modifiers: [],
        ))
        menu.addItem(.separator())
    }

    /// The system Window menu: Minimize, Zoom and Bring All to Front. As the
    /// app's windows menu, AppKit adds the window list and tiling items.
    private func addWindowMenu(to menubar: NSMenu, app: NSApplication) {
        let windowMenuItem = NSMenuItem()
        windowMenuItem.title = BrowserStrings.menuWindow
        let windowMenu = NSMenu(title: BrowserStrings.menuWindow)
        windowMenu.addItem(makeStandardMenuItem(
            title: BrowserStrings.menuMinimize,
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: standardKey("m"),
        ))
        windowMenu.addItem(makeStandardMenuItem(
            title: BrowserStrings.menuZoom,
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "",
            modifiers: [],
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeStandardMenuItem(
            title: BrowserStrings.menuBringAllToFront,
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "",
            modifiers: [],
        ))
        windowMenuItem.submenu = windowMenu
        menubar.addItem(windowMenuItem)
        app.windowsMenu = windowMenu
    }

    private func makeMenuItem(descriptor: BrowserCommandDescriptor, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: descriptor.menuTitle,
            action: action,
            keyEquivalent: descriptor.shortcut.keyEquivalent,
        )
        item.keyEquivalentModifierMask = descriptor.shortcut.modifiers
        item.target = self
        return item
    }

    private func updateInstallWebAppMenuItem(_ menuItem: NSMenuItem) {
        let canInstallSelectedSiteAsApp = activeChromeModel?.canInstallSelectedSiteAsApp ?? false
        menuItem.isHidden = !canInstallSelectedSiteAsApp
        menuItem.isEnabled = canInstallSelectedSiteAsApp
    }

    private func makeStandardMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil,
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent,
        )
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func installLayoutIndependentKeyMonitor() {
        guard layoutIndependentKeyMonitor == nil else {
            return
        }

        layoutIndependentKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            if handleLayoutIndependentKeyEvent(event) {
                return nil
            }

            return event
        }
    }

    private func handleLayoutIndependentKeyEvent(_ event: NSEvent) -> Bool {
        if BrowserShortcutCaptureNSView.handleRecordingEvent(event) {
            return true
        }
        if let panel = NSApp.keyWindow as? BrowserPeekPanel, panel.handleShortcut(event) {
            return true
        }

        if let spaceIndex = BrowserSpaceShortcuts.spaceIndex(
            forPhysicalKeyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
        ) {
            return selectSpace(at: spaceIndex)
        }

        guard let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            shortcutResolver: shortcutStore,
        ) else {
            return false
        }

        return performLayoutIndependentShortcutCommand(command)
    }

    private func selectSpace(at index: Int) -> Bool {
        guard
            let chromeModel = activeChromeModel,
            chromeModel.supportsSpaces,
            chromeModel.spaces.indices.contains(index)
        else {
            return false
        }

        chromeModel.selectSpace(id: chromeModel.spaces[index].id)
        return true
    }

    private func closeActiveAuxiliaryWindow() -> Bool {
        // A Peek card is a child of its browser window; Command-W closes the
        // card, not the tab behind it.
        if let panel = NSApp.keyWindow as? BrowserPeekPanel {
            panel.performClose(nil)
            return true
        }
        var candidate = NSApp.keyWindow
        while let window = candidate {
            if archiveWindowControllers.values.contains(where: { $0.window === window }) {
                // A confirmation sheet belongs to this auxiliary window; Cmd+W
                // must never fall through to Close Tab on its profile window.
                window.performClose(nil)
                return true
            }
            if window === aboutWindow || window === settingsWindowController?.window {
                window.performClose(nil)
                return true
            }
            candidate = window.sheetParent ?? window.parent
        }
        // A window of no browser session, such as Developer Tools, closes itself;
        // Command-W must not archive a tab of a window behind it.
        if let window = NSApp.keyWindow {
            var root = window
            while let parent = root.sheetParent ?? root.parent {
                root = parent
            }
            let isBrowserWindow = profileWindowSessions.contains { $0.window === root }
                || incognitoWindowSessions.contains { $0.window === root }
                || webAppWindowSession?.window === root
            if !isBrowserWindow {
                window.performClose(nil)
                return true
            }
        }
        return false
    }

    @nonobjc private func performCommandBarCommand(_ command: BrowserCommandID, from owner: BrowserChromeModel) {
        _ =
            switch command {
            case .clearArchive,
                 .viewArchive:
                performArchiveCommand(command, from: owner)
            default:
                performLayoutIndependentShortcutCommand(command.layoutIndependentCommand)
            }
    }

    @nonobjc private func performArchiveCommand(_ command: BrowserCommandID, from owner: BrowserChromeModel) -> Bool {
        BrowserArchiveCommandRouting.perform(
            command,
            from: owner,
            registeredOwners: profileWindowSessions.map(\.chromeModel),
            isTerminating: isTerminationRequested,
            present: { [weak self] model in self?.showArchive(for: model)?.archiveController },
        )
    }

    private func performLayoutIndependentShortcutCommand(
        _ command: BrowserLayoutIndependentShortcutCommand,
    ) -> Bool {
        switch command {
        case .undo:
            return NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: self)
        case .redo:
            return NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: self)
        case .cut:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case .copy:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case .paste:
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case .pasteAndMatchStyle:
            return performPasteAndMatchStyle(self)
        case .selectAll:
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case .quit:
            quitApplication(nil)
            return true
        case .hideApplication:
            NSApp.hide(nil)
            return true
        case .hideOtherApplications:
            NSApp.hideOtherApplications(nil)
            return true
        case .minimizeWindow:
            guard let window = NSApp.keyWindow, window.styleMask.contains(.miniaturizable) else { return false }
            window.performMiniaturize(nil)
            return true
        case .closeWindow:
            guard let window = NSApp.keyWindow else { return false }
            window.performClose(nil)
            return true
        case .openSettings:
            guard webAppWindowSession == nil else {
                return false
            }

            openSettings(nil)
            return true
        case .setAsDefaultBrowser:
            guard webAppWindowSession == nil, !defaultBrowserService.isDefaultBrowser else {
                return false
            }

            setAsDefaultBrowser(nil)
            return true
        case .newTab:
            guard activeChromeModel?.isWebApp != true, activeChromeModel?.canCreateTab ?? false else {
                return false
            }

            createNewTab(nil)
            return true
        case .restoreLastClosedTab:
            return activeChromeModel?.restoreLastClosedTab() ?? false
        case .stopLoading:
            guard let model = activeChromeModel, model.canStopLoading else { return false }
            model.stopLoadingCurrentTab()
            return true
        case .inspectElements:
            return activeChromeModel?.inspectElements() ?? false
        case .javaScriptConsole:
            return activeChromeModel?.showJavaScriptConsole() ?? false
        case .manageSpaces:
            return activeChromeModel?.openSpacesInLibrary() ?? false
        case .addBottomSplit:
            activeChromeModel?.presentSplitViewCommandBar(insertion: .after, orientation: .vertical)
            return true
        case .addTopSplit:
            activeChromeModel?.presentSplitViewCommandBar(insertion: .before, orientation: .vertical)
            return true
        case .addRightSplit:
            activeChromeModel?.presentSplitViewCommandBar(insertion: .after, orientation: .horizontal)
            return true
        case .addLeftSplit:
            activeChromeModel?.presentSplitViewCommandBar(insertion: .before, orientation: .horizontal)
            return true
        case .capturePortrait:
            return activeChromeModel?.beginPortraitCapture() ?? false
        case .blankWindow:
            createIncognitoWindow(copyingFullscreenFrom: activeBrowserWindow, blank: true)
            return true
        case .viewMedia:
            return activeChromeModel.map { $0.openLibrary(section: .media)
                return true
            } ?? false
        case .networkInspector:
            return activeChromeModel?.showNetworkInspector() ?? false
        case .toggleDeveloperMode:
            return activeChromeModel.map { $0.toggleDeveloperMode()
                return true
            } ?? false
        case .editSpaceTheme:
            return activeChromeModel
                .flatMap { model in model.selectedSpaceID.map { model.onEditSpaceTheme?($0) } } != nil
        case .togglePictureInPicture:
            return activeChromeModel?.togglePictureInPicture() ?? false
        case .muteAllTabs:
            return activeChromeModel?.setAllTabsMuted(true) ?? false
        case .unmuteAllTabs:
            return activeChromeModel?.setAllTabsMuted(false) ?? false
        case .shareTab:
            return activeChromeModel?.shareSelectedTab() ?? false
        case .developerTools:
            return activeChromeModel?.showDeveloperTools() ?? false
        case .viewSource:
            return activeChromeModel?.viewSourceOfSelectedTab() ?? false
        case .zoomIn:
            guard let model = activeChromeModel, model.canZoomIn else { return false }
            model.zoomIn()
            return true
        case .zoomOut:
            guard let model = activeChromeModel, model.canZoomOut else { return false }
            model.zoomOut()
            return true
        case .resetZoom:
            guard let model = activeChromeModel, model.canResetZoom else { return false }
            model.resetZoom()
            return true
        case .openLocation:
            guard let model = activeChromeModel, model.canOpenLocation else {
                return false
            }

            model.presentCurrentPageCommandBar()
            return true
        case .newWindow:
            return openNewWindow()
        case .newIncognitoWindow:
            guard webAppWindowSession == nil else {
                return false
            }

            createNewIncognitoWindow(nil)
            return true
        case .newLittleWindow:
            guard !isTerminationRequested else { return false }
            return littleWindowModel?.openNewLittleWindow() ?? false
        case .openHistory:
            guard webAppWindowSession == nil, activeChromeModel != nil, !isTerminationRequested else {
                return false
            }

            openHistory(nil)
            return true
        case .toggleBookmark:
            guard activeChromeModel?.selectedTabID != nil else {
                return false
            }

            toggleCurrentPageBookmark(nil)
            return true
        case .archiveTab:
            if closeActiveAuxiliaryWindow() {
                return true
            }
            if let webAppWindowSession {
                webAppWindowSession.window.performClose(nil)
                return true
            }

            return activeChromeModel?.archiveSelectedTab() ?? false
        case .viewArchive:
            guard let model = archiveContextModel else { return false }
            return performArchiveCommand(.viewArchive, from: model)
        case .clearArchive:
            guard let model = archiveContextModel else { return false }
            return performArchiveCommand(.clearArchive, from: model)
        case .savePage:
            guard activeChromeModel?.canSavePage ?? false else {
                return false
            }

            saveCurrentPage(nil)
            return true
        case .printPage:
            guard activeChromeModel?.canPrintPage ?? false else {
                return false
            }

            printCurrentPage(nil)
            return true
        case .copyLink:
            guard activeChromeModel?.canCopySelectedTabLink ?? false else {
                return false
            }

            return activeChromeModel?.copySelectedTabLink() ?? false
        case .findInPage:
            if let archive = focusedArchiveWindowController {
                archive.archiveController.focusSearch()
                return true
            }
            guard activeChromeModel?.canPresentFindInPage ?? false else {
                return false
            }

            return activeChromeModel?.presentFindInPage() ?? false
        case .findAndReplace:
            return false
        case .findNextInPage:
            guard activeChromeModel?.canStepThroughFindMatches ?? false else {
                return false
            }

            findNextInPage(nil)
            return true
        case .findPreviousInPage:
            guard activeChromeModel?.canStepThroughFindMatches ?? false else {
                return false
            }

            findPreviousInPage(nil)
            return true
        case .jumpToSelection:
            return activeChromeModel?.jumpToSelection() ?? false
        case .clearTemporaryTabs:
            guard activeChromeModel?.canClearTemporaryTabs ?? false else {
                return false
            }

            clearTemporaryTabs(nil)
            return true
        case .goBack:
            guard activeChromeModel?.canGoBack ?? false else {
                return false
            }

            goBack(nil)
            return true
        case .goForward:
            guard activeChromeModel?.canGoForward ?? false else {
                return false
            }

            goForward(nil)
            return true
        case .reload:
            guard activeChromeModel?.canReload ?? false else {
                return false
            }

            reloadCurrentTab(nil)
            return true
        case .forceReload:
            guard activeChromeModel?.canReload ?? false else {
                return false
            }

            forceReloadCurrentTab(nil)
            return true
        case .clearCacheAndRefresh:
            guard activeChromeModel?.canReload ?? false else {
                return false
            }

            clearCacheAndRefreshCurrentTab(nil)
            return true
        case .clearCookiesAndRefresh:
            guard activeChromeModel?.canReload ?? false else {
                return false
            }

            clearCookiesAndRefreshCurrentTab(nil)
            return true
        case .addSplitView:
            guard activeChromeModel?.isWebApp != true, activeChromeModel?.canAddSplitView == true else {
                return false
            }

            addSplitView(nil)
            return true
        case .closeSplitPane:
            return activeChromeModel?.closeFocusedSplitPane() ?? false
        case .separateTabFromSplit:
            return activeChromeModel?.separateSelectedTabFromSplit() ?? false
        case .separateSplitView:
            return activeChromeModel?.separateSelectedSplitGroup() ?? false
        case .toggleSplitOrientation:
            return activeChromeModel?.toggleSelectedSplitOrientation() ?? false
        case .expandCurrentSplit:
            return activeChromeModel?.toggleExpandedSplitPane() ?? false
        case .focusSplitPane1:
            return activeChromeModel?.focusSplitPane(at: 0) ?? false
        case .focusSplitPane2:
            return activeChromeModel?.focusSplitPane(at: 1) ?? false
        case .focusSplitPane3:
            return activeChromeModel?.focusSplitPane(at: 2) ?? false
        case .focusSplitPane4:
            return activeChromeModel?.focusSplitPane(at: 3) ?? false
        case .focusNextSplitPane:
            return activeChromeModel?.focusAdjacentSplitPane(offset: 1) ?? false
        case .focusPreviousSplitPane:
            return activeChromeModel?.focusAdjacentSplitPane(offset: -1) ?? false
        case .toggleSidebar:
            guard activeChromeModel != nil else {
                return false
            }

            toggleSidebar(nil)
            return true
        case .toggleSidebarPosition:
            guard activeChromeModel?.isWebApp == false else { return false }
            toggleSidebarPosition(nil)
            return true
        case .toggleBookmarksBar:
            toggleBookmarksBar(nil)
            return true
        case .toggleSiteToolbar:
            guard activeChromeModel?.isWebApp == false else { return false }
            toggleSiteToolbar(nil)
            return true
        case .viewDownloads:
            return activeChromeModel?.toggleDownloads() ?? false
        case .viewLibrary:
            activeChromeModel?.toggleLibrary()
            return activeChromeModel != nil
        case .selectNextSpace,
             .selectPreviousSpace:
            guard let model = activeChromeModel, !model.isWebApp, model.supportsSpaces, model.spaces.count > 1 else {
                return false
            }

            command == .selectNextSpace ? model.selectNextSpace() : model.selectPreviousSpace()
            return true
        case .copyLinkAsMarkdown:
            return activeChromeModel?.copySelectedTabLinkAsMarkdown() ?? false
        case .copyLinkAsQuote:
            guard activeChromeModel?.canCopySelectedTextAsQuoteLink == true else { return false }
            copySelectedTextAsQuoteLink(nil)
            return true
        case .revealCurrentTab:
            return activeChromeModel?.revealSelectedTabInSidebar() ?? false
        case .openExtensions:
            return activeChromeModel?.openExtensionsControlCenter() ?? false
        case .togglePinTab:
            return activeChromeModel?.togglePinSelectedTab() ?? false
        case .duplicateTab:
            return activeChromeModel?.duplicateSelectedTab() ?? false
        case .renameTab:
            return activeChromeModel?.renameSelectedTab() ?? false
        case .resetTabToPinnedURL:
            return activeChromeModel?.resetSelectedTabToPinnedURL() ?? false
        case .setAllFoldersExpanded(let expanded):
            return activeChromeModel?.setActiveSpaceFoldersExpanded(expanded) ?? false
        case .resetSpaceTabs:
            return activeChromeModel?.resetSpaceTabs() ?? false
        case .newSpace:
            guard let model = activeChromeModel, model.supportsSpaces, !model.isWebApp else { return false }
            model.beginCreatingSpace()
            return true
        case .newFolder:
            return activeChromeModel?.createFolderFromSelectedTab() ?? false
        case .captureFullPage:
            return activeChromeModel?.captureFullPageSelectedTabToPasteboard() ?? false
        case .captureArea:
            return activeChromeModel?.beginAreaCapture() ?? false
        case .selectNextTab:
            guard activeChromeModel?.isWebApp == false else { return false }
            return activeChromeModel?.selectAdjacentSidebarItem(offset: 1) ?? false
        case .selectPreviousTab:
            guard activeChromeModel?.isWebApp == false else { return false }
            return activeChromeModel?.selectAdjacentSidebarItem(offset: -1) ?? false
        case .goToSidebarItem(let index):
            guard activeChromeModel?.isWebApp == false else { return false }
            return activeChromeModel?.selectSidebarItem(at: index) ?? false
        case .goToLastSidebarItem:
            guard activeChromeModel?.isWebApp == false else { return false }
            return activeChromeModel?.selectLastSidebarItem() ?? false
        }
    }

    private func performPasteAndMatchStyle(_ sender: Any?) -> Bool {
        if NSApp.sendAction(
            #selector(NSTextView.pasteAsPlainText(_:)),
            to: nil,
            from: sender ?? self,
        ) {
            return true
        }

        return activeChromeModel?.pasteAndMatchStyleCurrentTab() ?? false
    }

    private func presentQuitWarning(_ sender: Any?) {
        isQuitWarningPresented = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BrowserStrings.settingsQuitWarningTitle
        alert.informativeText = BrowserStrings.settingsQuitWarningMessage
        alert.addButton(withTitle: BrowserStrings.settingsQuitWarningQuit)
        alert.addButton(withTitle: BrowserStrings.settingsQuitWarningCancel)

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else {
                return
            }

            isQuitWarningPresented = false
            guard response == .alertFirstButtonReturn else {
                return
            }

            didConfirmTerminationWarning = true
            requestApplicationTermination(sender)
        }

        if let activeBrowserWindow, activeBrowserWindow.isVisible {
            alert.beginSheetModal(for: activeBrowserWindow, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func observeShortcutStore() {
        shortcutStoreCancellable = shortcutStore.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                installMainMenu(for: NSApp)
                refreshSetAsDefaultBrowserMenuItem()
                refreshLittleWindowHotKey(enabled: userPreferencesStore.opensLittleWindowFromAnyApp)
            }
        }
    }

    private func configureUpdateControllerIfNeeded() {
        guard updateController == nil else {
            return
        }

        updateController = BrowserUpdateController(preferencesStore: userPreferencesStore)
    }

    /// What a page's context menu needs from the application.
    private func connectPageCommands(to model: BrowserChromeModel) {
        model.onSavePageRequest = { [weak self] in self?.saveCurrentPage(nil) }
        model.onOpenLinkInIncognito = { [weak self] url in
            guard let self else { return }
            createIncognitoWindow(copyingFullscreenFrom: activeBrowserWindow, firstURL: url)
        }
    }

    /// Pages cannot keep these keys anyway, and asking the page first costs a few frames
    /// before a tab's row or a new window can start to move.
    private func installReservedShortcutMonitor() {
        reservedShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == .command || modifiers == [.command, .shift],
                  ["w", "t", "n"].contains(event.charactersIgnoringModifiers?.lowercased()),
                  NSApp.modalWindow == nil, event.window?.attachedSheet == nil
            else { return event }
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? nil : event
        }
    }

    private func startBatterySaverController() {
        guard batterySaverController == nil else {
            return
        }

        let controller = BrowserBatterySaverController(preferencesStore: userPreferencesStore)
        batterySaverController = controller
        controller.start()
    }

    private func presentSettingsWindow(pane: BrowserSettingsPane? = nil) {
        guard
            let profileStore,
            let profileSession = activeProfileWindowSession ?? profileWindowSessions.first
        else {
            return
        }

        if let settingsWindowController {
            settingsWindowController.show(pane: pane.map { Settings.PaneIdentifier($0.rawValue) })
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindowController = SettingsWindowController(
            panes: settingsPanes(
                model: profileSession.chromeModel,
                profileStore: profileStore,
                currentProfileID: profileSession.profile.id,
                accountStore: profileSession.accountStore,
            ),
            style: .toolbarItems,
            animated: false,
            hidesToolbarForSingleItem: false,
        )
        self.settingsWindowController = settingsWindowController
        settingsWindowController.show(pane: pane.map { Settings.PaneIdentifier($0.rawValue) })

        if let settingsWindow = settingsWindowController.window {
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.collectionBehavior = [.fullScreenAuxiliary]
            settingsWindow.delegate = self
            center(settingsWindow, over: profileSession.window)
            profileSession.window.addChildWindow(settingsWindow, ordered: .above)
        }
    }

    private func settingsPanes(
        model: BrowserChromeModel,
        profileStore: BrowserProfileStore,
        currentProfileID: String,
        accountStore: BrowserAccountStore?,
    ) -> [SettingsPane] {
        BrowserSettingsPane.available.map { pane in
            BrowserSettingsViewController(
                model: model,
                profileStore: profileStore,
                currentProfileID: currentProfileID,
                accountStore: accountStore,
                pane: pane,
                canDeleteProfile: { [weak self] profile in
                    guard let self else { return false }
                    return !profileWindowSessions.contains {
                        $0.profile.id == profile.id || $0.chromeModel.spaceProfilesByID.values.contains(profile.id)
                    }
                },
                openProfile: { [weak self] profile in self?.openProfile(profile) },
                openURL: { [weak self] url in self?.openBrowserInternalPage(url) },
            )
        }
    }

    private func center(_ childWindow: NSWindow, over parentWindow: NSWindow?) {
        guard let parentWindow else {
            childWindow.center()
            return
        }

        let parentFrame = parentWindow.frame
        let childFrame = childWindow.frame
        childWindow.setFrameOrigin(
            NSPoint(
                x: parentFrame.midX - childFrame.width / 2,
                y: parentFrame.midY - childFrame.height / 2,
            ),
        )
    }

    private func createMainWindow() {
        guard let runtimeConfiguration = BrowserRuntimeConfiguration.currentConfiguration() else {
            return
        }

        let rootCacheURL = URL(fileURLWithPath: runtimeConfiguration.rootCachePath, isDirectory: true)
        let profileStore = BrowserProfileStore(rootCacheURL: rootCacheURL)
        self.profileStore = profileStore
        observeProfileStore(profileStore)
        createProfileWindow(
            for: profileStore.defaultProfile,
            runtimeConfiguration: runtimeConfiguration,
            copyingFullscreenFrom: nil,
        )
    }

    private func createWebAppWindow(configuration: BrowserWebAppConfiguration) {
        guard let runtimeConfiguration = BrowserRuntimeConfiguration.currentConfiguration() else {
            return
        }

        let rootCacheURL = URL(fileURLWithPath: runtimeConfiguration.rootCachePath, isDirectory: true)
        let profile = configuration.profile
        let profileDirectoryURL = rootCacheURL.appendingPathComponent(profile.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)

        let profileDirectoryCandidates = BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
            profileDirectoryURL: profileDirectoryURL,
        )
        let bookmarksModel = BrowserBookmarksModel(
            store: BrowserChromiumBookmarkStore(profileDirectoryCandidates: profileDirectoryCandidates),
        )
        let historyStore = BrowserChromiumHistoryStore(profileDirectoryCandidates: profileDirectoryCandidates)
        let ephemeralSessionStore = BrowserEphemeralSessionStore()
        weak var windowReference: NSWindow?
        let chromeModel = BrowserChromeModel(
            tabDriver: BrowserTabControllerDriver(profileCachePath: profileDirectoryURL.path),
            sessionSnapshotStore: ephemeralSessionStore,
            sessionPreferencesStore: ephemeralSessionStore,
            newTabURLString: configuration.startURL.absoluteString,
            userPreferencesStore: userPreferencesStore,
            shortcutStore: shortcutStore,
            bookmarksModel: bookmarksModel,
            historyStore: historyStore,
            extensionManager: BrowserChromiumExtensionManager(profileDirectoryURL: profileDirectoryURL),
            extensionSidePanelDriver: BrowserExtensionSidePanelController(profileCachePath: profileDirectoryURL.path),
            extensionActionPopupDriver: BrowserExtensionActionPopupController(profileCachePath: profileDirectoryURL
                .path),
            windowMode: .webApp(configuration),
            profile: profile,
            commandHandler: { [weak self] commandID, owner in
                self?.performCommandBarCommand(commandID, from: owner)
            },
            windowTitleHandler: { title in
                windowReference?.title = title
            },
            allTabsClosedHandler: {
                windowReference?.performClose(nil)
            },
        )
        let preferences = BrowserWebAppPreferences(identifier: configuration.identifier)
        let actions = BrowserWebAppViewActions(
            showAppInfo: { [weak self] in
                self?.presentCurrentWebAppInfo()
            },
            openInBrowser: { [weak self] in
                self?.openCurrentWebAppPageInBrowser()
            },
            uninstall: { [weak self] in
                self?.presentCurrentWebAppUninstallPrompt()
            },
        )
        let rootView = BrowserWebAppRootView(
            model: chromeModel,
            configuration: configuration,
            preferences: preferences,
            actions: actions,
        )
        let hostingView = rootView
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let window = BrowserMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: BrowserWebAppLayout.windowStyleMask,
            backing: .buffered,
            defer: false,
        )
        windowReference = window
        window.title = configuration.name
        window.delegate = self
        window.browserUndoManager = chromeModel.undoManager
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.configureBrowserChrome()
        window.center()

        let contentView = BrowserWindowContentContainerView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let session = BrowserWebAppWindowSession(
            window: window,
            chromeModel: chromeModel,
            configuration: configuration,
            preferences: preferences,
        )
        webAppWindowSession = session
        installMainMenu(for: NSApp)
        window.contentView = contentView
        let bundleIcon = NSWorkspace.shared.icon(forFile: configuration.bundleURL.path)
        bundleIcon.size = NSSize(
            width: BrowserImageThumbnailer.macOSApplicationIconCanvasSize,
            height: BrowserImageThumbnailer.macOSApplicationIconCanvasSize,
        )
        NSApp.applicationIconImage = bundleIcon
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if hasReceivedBrowserContext {
            chromeModel.handleContextReady()
        }
    }

    private func openProfile(_ profile: BrowserProfile) {
        if let session = profileWindowSessions.first(where: { $0.profile.id == profile.id }) {
            session.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let runtimeConfiguration = BrowserRuntimeConfiguration.currentConfiguration() else {
            return
        }

        createProfileWindow(
            for: profile,
            runtimeConfiguration: runtimeConfiguration,
            copyingFullscreenFrom: activeBrowserWindow,
        )
    }

    /// Opens another window of the active profile, with the same Spaces and its own pages.
    @discardableResult private func openNewWindow() -> Bool {
        guard !isTerminationRequested,
              let runtimeConfiguration = BrowserRuntimeConfiguration.currentConfiguration()
        else { return false }
        let lastUsed = profileWindowSessions.first { $0.window === lastKeyProfileWindow }
        guard let source = activeProfileWindowSession ?? lastUsed ?? profileWindowSessions.first else {
            createProfileWindow(
                for: profileStore?.defaultProfile ?? .defaultProfile,
                runtimeConfiguration: runtimeConfiguration,
                copyingFullscreenFrom: nil,
            )
            return true
        }
        createProfileWindow(
            for: source.profile,
            runtimeConfiguration: runtimeConfiguration,
            copyingFullscreenFrom: source.window,
            besides: source,
        )
        return true
    }

    /// Remembers the open extra windows once, before quitting starts closing them.
    private func recordAdditionalWindows() {
        guard !didRecordAdditionalWindows else { return }
        didRecordAdditionalWindows = true
        let records = profileWindowSessions.filter(\.chromeModel.isAdditionalWindow).map { session in
            BrowserAdditionalWindowRecord(
                profileID: session.profile.id,
                frame: NSStringFromRect(session.window.frame),
                spaceID: session.chromeModel.selectedSpaceID,
                selectedTabSyncID: session.chromeModel.selectedTabSyncID,
            )
        }
        BrowserAdditionalWindowRecord.save(records, to: .standard)
    }

    private func restoreAdditionalWindows() {
        let records = BrowserAdditionalWindowRecord.load(from: .standard)
        BrowserAdditionalWindowRecord.save([], to: .standard)
        guard userPreferencesStore.restoreWindowsOnLaunch,
              let runtimeConfiguration = BrowserRuntimeConfiguration.currentConfiguration()
        else { return }
        for record in records {
            guard let source = profileWindowSessions.first(where: { $0.profile.id == record.profileID }) else {
                continue
            }
            createProfileWindow(
                for: source.profile,
                runtimeConfiguration: runtimeConfiguration,
                copyingFullscreenFrom: nil,
                besides: source,
                restoring: record,
            )
        }
        profileWindowSessions.first?.window.makeKeyAndOrderFront(nil)
    }

    private func removeFromWindowGroup(_ session: BrowserProfileWindowSession) {
        guard let group = windowGroups[session.profile.id] else { return }
        group.remove(session.chromeModel)
        if group.models.count < 2 {
            group.models.forEach(group.remove)
            windowGroups[session.profile.id] = nil
        }
    }

    private func createProfileWindow(
        for profile: BrowserProfile,
        runtimeConfiguration: BrowserRuntimeConfiguration,
        copyingFullscreenFrom sourceWindow: NSWindow?,
        besides source: BrowserProfileWindowSession? = nil,
        restoring record: BrowserAdditionalWindowRecord? = nil,
    ) {
        configureUpdateControllerIfNeeded()
        guard let updateController else {
            return
        }

        let rootCacheURL = URL(fileURLWithPath: runtimeConfiguration.rootCachePath, isDirectory: true)
        let profileDirectoryURL = profileStore?.profileDirectoryURL(for: profile)
            ?? rootCacheURL.appendingPathComponent(profile.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)

        let sessionStorageDirectoryURL = profileSessionStorageDirectoryURL(
            for: profile,
            runtimeConfiguration: runtimeConfiguration,
        )
        let sessionSnapshotURL = sessionStorageDirectoryURL
            .appendingPathComponent(BrowserTabSessionSnapshotStore.snapshotFileName, isDirectory: false)
        let sqliteSessionStore: BrowserSQLiteSessionStore? = source != nil ? nil : try? BrowserSQLiteSessionStore(
            databaseURL: sessionStorageDirectoryURL
                .appendingPathComponent(BrowserSQLiteSessionStore.databaseFileName, isDirectory: false),
        )
        let profileDirectoryCandidates = BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
            profileDirectoryURL: profileDirectoryURL,
        )
        let bookmarksModel = BrowserBookmarksModel(
            store: BrowserChromiumBookmarkStore(profileDirectoryCandidates: profileDirectoryCandidates),
        )
        let historyStore = BrowserChromiumHistoryStore(profileDirectoryCandidates: profileDirectoryCandidates)
        let authSessionStore = BrowserAuthSessionStore(namespace: profile.isDefault
            ? .defaultProfile
            : .profile(profile.id))
        let syncClient = BrowserHostedService.isEnabled && source == nil
            ? BrowserSyncConfiguration.current().map { BrowserRemoteSyncClient(configuration: $0) }
            : nil
        let syncCoordinator: BrowserSyncService? =
            if let sqliteSessionStore, let syncClient {
                BrowserSyncService(
                    localStore: sqliteSessionStore,
                    remoteClient: syncClient,
                    authSessionStore: authSessionStore,
                    runtimeActive: false,
                    errorReporter: { error, phase in
                        BrowserTelemetry.captureError(error, event: phase == .push ? .syncPushFailed : .syncPullFailed)
                    },
                )
            } else {
                nil
            }
        let accountStore = source?.accountStore ?? BrowserAccountStore(
            syncClient: syncClient,
            authSessionStore: authSessionStore,
            syncCoordinator: syncCoordinator,
            webSignInService: BrowserWebSignInService(),
            deviceIdentity: .init(name: Host.current().localizedName ?? "Mac", platform: "macOS"),
        )
        let sessionStore: BrowserTabSessionSnapshotStoring =
            if let shared = source?.chromeModel.sharedSessionStore {
                shared
            } else if let sqliteSessionStore {
                sqliteSessionStore
            } else {
                BrowserTabSessionSnapshotStore(snapshotURL: sessionSnapshotURL)
            }
        // Each window remembers its own Space and sidebar width.
        let preferencesStore: BrowserSessionPreferencesStoring =
            if source != nil {
                BrowserEphemeralSessionStore()
            } else if let sqliteSessionStore {
                sqliteSessionStore
            } else {
                BrowserSessionPreferencesStore()
            }
        let chromeModel = BrowserChromeModel(
            tabDriver: BrowserTabControllerDriver(profileCachePath: profileDirectoryURL.path),
            sessionSnapshotStore: sessionStore,
            sessionPreferencesStore: preferencesStore,
            userPreferencesStore: userPreferencesStore,
            shortcutStore: shortcutStore,
            bookmarksModel: source?.chromeModel.bookmarksModel ?? bookmarksModel,
            historyStore: historyStore,
            extensionManager: BrowserChromiumExtensionManager(profileDirectoryURL: profileDirectoryURL),
            extensionSidePanelDriver: BrowserExtensionSidePanelController(profileCachePath: profileDirectoryURL.path),
            extensionActionPopupDriver: BrowserExtensionActionPopupController(profileCachePath: profileDirectoryURL
                .path),
            syncCoordinator: syncCoordinator,
            profile: profile,
            availableProfileCount: profileStore?.profiles.count ?? 1,
            commandHandler: { [weak self] commandID, owner in
                self?.performCommandBarCommand(commandID, from: owner)
            },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        syncCoordinator?.setSnapshotApplier(chromeModel)
        chromeModel.liveFolderFetcher = BrowserGitHubLiveFolderFetcher(
            browser: BrowserHiddenPageBrowser(profileCachePath: profileDirectoryURL.path),
        )
        if let source {
            let group = windowGroups[profile.id] ?? BrowserProfileWindowGroup()
            windowGroups[profile.id] = group
            group.add(source.chromeModel)
            group.add(chromeModel)
            chromeModel.isAdditionalWindow = true
            chromeModel.firstSpaceID = record?.spaceID ?? source.chromeModel.selectedSpaceID
            chromeModel.setSidebarWidth(source.chromeModel.sidebarWidth)
        }
        if NSApp.isActive {
            chromeModel.handleApplicationDidBecomeActive()
        } else {
            chromeModel.handleApplicationWillResignActive()
        }

        let rootView = BrowserRootView(model: chromeModel, updateController: updateController)
        let hostingView = rootView
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let window = BrowserMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = windowTitle(for: profile)
        window.delegate = self
        window.browserUndoManager = chromeModel.undoManager
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.configureBrowserChrome()

        if let record {
            window.setFrame(NSRectFromString(record.frame), display: false)
        } else if let sourceWindow, !sourceWindow.styleMask.contains(.fullScreen) {
            let sourceFrame = sourceWindow.frame
            window.setFrameOrigin(NSPoint(x: sourceFrame.minX + 28, y: sourceFrame.minY - 28))
        } else {
            window.center()
        }

        let contentView = BrowserWindowContentContainerView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let shouldEnterFullscreen = sourceWindow?.styleMask.contains(.fullScreen) == true
        let session = BrowserProfileWindowSession(
            window: window,
            chromeModel: chromeModel,
            accountStore: accountStore,
            profile: profile,
        )
        connectPageCommands(to: chromeModel)
        if let store = profileStore {
            chromeModel.profileDirectories = BrowserSpaceProfileDirectories(
                windowProfile: profile.id,
                profiles: { store.profiles },
                cachePath: { directory in
                    store.profile(withID: directory).map { store.profileDirectoryURL(for: $0).path }
                },
                createProfile: { store.createProfile().id },
            )
        }
        profileWindowSessions.append(session)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        BrowserTelemetry.captureUsage(
            .profileWindowOpened,
            properties: [
                "profile": profile.isDefault ? "default" : "custom",
                "profile_count": "\(profileStore?.profiles.count ?? 1)",
            ],
        )
        updateProfilePresentationForOpenWindows()

        if hasReceivedBrowserContext {
            chromeModel.handleContextReady()
            openPendingNavigationURLsIfPossible()
            if let syncID = record?.selectedTabSyncID {
                chromeModel.selectTab(syncID: syncID)
            } else if source != nil, record == nil {
                chromeModel.presentCommandBar()
            }
        }

        if shouldEnterFullscreen {
            DispatchQueue.main.async {
                guard !window.styleMask.contains(.fullScreen) else {
                    return
                }

                window.toggleFullScreen(nil)
            }
        }
    }

    private func profileSessionStorageDirectoryURL(
        for profile: BrowserProfile,
        runtimeConfiguration: BrowserRuntimeConfiguration,
    ) -> URL {
        let sessionStorageURL = URL(fileURLWithPath: runtimeConfiguration.sessionStoragePath, isDirectory: true)
        guard !profile.isDefault else {
            return sessionStorageURL
        }

        return sessionStorageURL.appendingPathComponent(profile.directoryName, isDirectory: true)
    }

    private func observeProfileStore(_ profileStore: BrowserProfileStore) {
        profileStoreCancellable = profileStore.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateProfilePresentationForOpenWindows()
            }
        }
    }

    private func observeAppearancePreference() {
        appearancePreferenceCancellable = userPreferencesStore.$appearancePreference.sink { [weak self] preference in
            self?.applyAppearancePreference(preference)
        }
        guard webAppConfiguration == nil else { return }
        littleWindowHotKeyCancellable = userPreferencesStore.$opensLittleWindowFromAnyApp.sink { [weak self] enabled in
            self?.refreshLittleWindowHotKey(enabled: enabled)
        }
    }

    /// New Small Window's shortcut, as customized, from any app.
    private func refreshLittleWindowHotKey(enabled: Bool) {
        littleWindowHotKey = nil
        guard enabled, webAppConfiguration == nil else { return }
        littleWindowHotKey = BrowserGlobalHotKey
            .make(for: shortcutStore.shortcut(for: .newLittleWindow)) { [weak self] in
                guard let self, !isTerminationRequested,
                      littleWindowModel?.openNewLittleWindow() == true else { return }
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private func applyAppearancePreference(_ preference: BrowserAppearancePreference) {
        let appearance = preference.nsAppearanceName.flatMap(NSAppearance.init(named:))
        NSApp.appearance = appearance

        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    private func updateProfilePresentationForOpenWindows() {
        let profileCount = profileStore?.profiles.count ?? 1
        for session in profileWindowSessions {
            let profile = profileStore?.profile(withID: session.profile.id) ?? session.profile
            session.chromeModel.updateProfilePresentation(profile: profile, availableProfileCount: profileCount)
            session.window.title = windowTitle(for: profile)
        }
    }

    private func windowTitle(for profile: BrowserProfile) -> String {
        guard profileStore?.profiles.count ?? 1 > 1 else {
            return BrowserStrings.applicationName
        }

        return "\(BrowserStrings.applicationName) - \(profile.displayName)"
    }

    private func createIncognitoWindow(
        copyingFullscreenFrom sourceWindow: NSWindow?,
        firstURL: URL? = nil,
        blank: Bool = false,
    ) {
        configureUpdateControllerIfNeeded()
        guard let updateController else {
            return
        }

        let runtimeConfiguration = BrowserRuntimeConfiguration.currentConfiguration()
        let sourceProfile = activeProfileWindowSession?.profile ?? profileStore?.defaultProfile
        let profileDirectoryCandidates: [URL] =
            if
                let runtimeConfiguration,
                let sourceProfile
            {
                BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
                    profileDirectoryURL: profileStore?.profileDirectoryURL(for: sourceProfile)
                        ?? URL(fileURLWithPath: runtimeConfiguration.rootCachePath, isDirectory: true)
                        .appendingPathComponent(sourceProfile.directoryName, isDirectory: true),
                )
            } else {
                []
            }
        let bookmarksModel = BrowserBookmarksModel(
            store: BrowserChromiumBookmarkStore(profileDirectoryCandidates: profileDirectoryCandidates),
        )
        let ephemeralSessionStore = BrowserEphemeralSessionStore()
        // A blank window browses as its profile; an incognito one leaves nothing behind.
        let blankProfilePath = blank ? profileDirectoryCandidates.first?.path : nil
        let chromeModel = BrowserChromeModel(
            tabDriver: blankProfilePath.map { BrowserTabControllerDriver(profileCachePath: $0) }
                ?? BrowserTabControllerDriver(usesEphemeralRequestContext: true),
            sessionSnapshotStore: ephemeralSessionStore,
            sessionPreferencesStore: ephemeralSessionStore,
            userPreferencesStore: userPreferencesStore,
            shortcutStore: shortcutStore,
            bookmarksModel: bookmarksModel,
            historyStore: blank
                ? BrowserChromiumHistoryStore(profileDirectoryCandidates: profileDirectoryCandidates)
                : BrowserEmptyHistoryStore(),
            extensionManager: BrowserEmptyExtensionManager(),
            windowMode: blank ? .blank : .incognito,
            commandHandler: { [weak self] commandID, owner in
                self?.performCommandBarCommand(commandID, from: owner)
            },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        chromeModel.firstTabURLString = firstURL?.absoluteString

        let rootView = BrowserRootView(model: chromeModel, updateController: updateController)
        let hostingView = rootView
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let window = BrowserMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = blank ? BrowserStrings.menuBlankWindow : BrowserStrings.menuNewIncognitoWindow
        window.delegate = self
        window.browserUndoManager = chromeModel.undoManager
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.configureBrowserChrome()

        if let sourceWindow, !sourceWindow.styleMask.contains(.fullScreen) {
            let sourceFrame = sourceWindow.frame
            window.setFrameOrigin(NSPoint(x: sourceFrame.minX + 28, y: sourceFrame.minY - 28))
        } else {
            window.center()
        }

        let contentView = BrowserWindowContentContainerView(frame: window.contentRect(forFrameRect: window.frame))
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let shouldEnterFullscreen = sourceWindow?.styleMask.contains(.fullScreen) == true
        let session = BrowserIncognitoWindowSession(window: window, chromeModel: chromeModel)
        incognitoWindowSessions.append(session)
        connectPageCommands(to: chromeModel)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if hasReceivedBrowserContext {
            chromeModel.handleContextReady()
            if blank {
                chromeModel.presentCommandBar()
            }
        }

        if shouldEnterFullscreen {
            DispatchQueue.main.async {
                guard !window.styleMask.contains(.fullScreen) else {
                    return
                }

                window.toggleFullScreen(nil)
            }
        }
    }

    private func presentWebAppInstallationPrompt() {
        guard
            let chromeModel = activeChromeModel,
            chromeModel.canInstallSelectedSiteAsApp,
            let tab = chromeModel.currentTab,
            tab.pageURL != nil,
            let metadata = chromeModel.webAppInstallMetadata(for: tab),
            let window = activeBrowserWindow
        else {
            return
        }

        presentWebAppInstallationPrompt(
            tab: tab,
            metadata: metadata,
            window: window,
        )
    }

    private func presentWebAppInstallationPrompt(
        tab: BrowserChromeModel.Tab,
        metadata: BrowserWebAppInstallMetadata,
        window: NSWindow,
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = BrowserStrings.webAppInstallPromptTitle
        alert.informativeText = BrowserStrings.webAppInstallPromptMessage
        alert.addButton(withTitle: BrowserStrings.webAppInstallButton)
        alert.addButton(withTitle: BrowserStrings.cancelAction)

        let nameField = NSTextField(string: metadata.preferredName(fallbackTitle: tab.displayTitle))
        nameField.placeholderString = tab.displayTitle
        nameField.selectText(nil)
        nameField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = nameField

        alert.beginSheetModal(for: window) { [weak self, weak nameField] response in
            guard response == .alertFirstButtonReturn, let self, let nameField else {
                return
            }

            installWebApp(tab: tab, metadata: metadata, name: nameField.stringValue)
        }
    }

    private func installWebApp(
        tab: BrowserChromeModel.Tab,
        metadata: BrowserWebAppInstallMetadata,
        name: String,
    ) {
        guard
            let profileSession = activeProfileWindowSession ?? profileWindowSessions.first,
            let applicationsDirectoryURL = BrowserWebAppBundleInstaller.defaultApplicationsDirectoryURL()
        else {
            presentWebAppOperationError(BrowserWebAppInstallationError.applicationsDirectoryUnavailable)
            return
        }

        let hostBundleURL = Bundle.main.bundleURL
        let profile = profileSession.profile

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let manifestIconData = await BrowserWebAppIconLoader.loadBundleIconData(from: metadata.iconURL)
            await BrowserFaviconCache.shared.loadImageIfNeeded(from: tab.faviconURL)
            let fallbackIconData = BrowserFaviconCache.shared
                .image(for: tab.faviconURL)
                .flatMap(BrowserWebAppBundleIconEncoder.icnsData(from:))
            let request = BrowserWebAppInstallRequest(
                name: name,
                metadata: metadata,
                profile: profile,
                bundleIconData: manifestIconData ?? fallbackIconData,
            )

            do {
                let installedApp = try BrowserWebAppBundleInstaller(
                    hostBundleURL: hostBundleURL,
                    applicationsDirectoryURL: applicationsDirectoryURL,
                ).install(request)
                _ = NSWorkspace.shared.setIcon(nil, forFile: installedApp.bundleURL.path)
                _ = LSRegisterURL(installedApp.bundleURL as CFURL, true)

                let openConfiguration = NSWorkspace.OpenConfiguration()
                openConfiguration.activates = true
                openConfiguration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(
                    at: installedApp.bundleURL,
                    configuration: openConfiguration,
                ) { [weak self] _, error in
                    guard let error else {
                        return
                    }

                    DispatchQueue.main.async {
                        self?.presentWebAppOperationError(error)
                    }
                }
            } catch {
                presentWebAppOperationError(error)
            }
        }
    }

    private func presentCurrentWebAppInfo() {
        guard let session = webAppWindowSession else {
            return
        }

        let currentURL = session.chromeModel.currentTab?.pageURL ?? session.configuration.startURL
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = session.configuration.name
        alert.informativeText = [
            currentURL.absoluteString,
            session.configuration.scopeURL.absoluteString,
            BrowserStrings.webAppInfoInstalledWith,
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: BrowserStrings.webAppInfoDoneAction)
        alert.beginSheetModal(for: session.window)
    }

    private func openCurrentWebAppPageInBrowser() {
        guard let session = webAppWindowSession else {
            return
        }

        let pageURL = session.chromeModel.currentTab?.pageURL ?? session.configuration.startURL
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        NSWorkspace.shared.open(
            [pageURL],
            withApplicationAt: session.configuration.hostBundleURL,
            configuration: openConfiguration,
        ) { [weak self] _, error in
            guard let error else {
                return
            }

            DispatchQueue.main.async {
                self?.presentWebAppOperationError(error)
            }
        }
    }

    private func presentCurrentWebAppUninstallPrompt() {
        guard let session = webAppWindowSession else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BrowserStrings.webAppUninstallPromptTitle
        alert.informativeText = BrowserStrings.webAppUninstallPromptMessage(session.configuration.name)
        alert.addButton(withTitle: BrowserStrings.webAppUninstallButton)
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        alert.beginSheetModal(for: session.window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }

            recycleCurrentWebApp(session)
        }
    }

    private func recycleCurrentWebApp(_ session: BrowserWebAppWindowSession) {
        NSWorkspace.shared.recycle([session.configuration.bundleURL]) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.presentWebAppOperationError(error)
                    return
                }

                NSApp.terminate(nil)
            }
        }
    }

    private func presentWebAppOperationError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.messageText = BrowserStrings.webAppOperationFailedTitle
        if let window = activeBrowserWindow, window.isVisible {
            alert.beginSheetModal(for: window)
            return
        }

        alert.runModal()
    }

    private func presentAboutWindow() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let info = BrowserAboutInfo.current()
        let rootView = BrowserAboutView(info: info) { [weak self] url in
            self?.openAboutLink(url)
        }

        let contentSize = NSSize(
            width: BrowserAboutLayout.windowWidth,
            height: BrowserAboutLayout.windowHeight,
        )
        let aboutWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        aboutWindow.title = BrowserStrings.aboutWindowTitle(appName: info.applicationName)
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.titleVisibility = .hidden
        aboutWindow.titlebarAppearsTransparent = true
        aboutWindow.isMovableByWindowBackground = true
        aboutWindow.setContentSize(contentSize)
        aboutWindow.center()
        aboutWindow.contentView = rootView
        aboutWindow.delegate = self

        self.aboutWindow = aboutWindow
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openAboutLink(_ url: URL) {
        if let route = BrowserLinkRouter.route(for: url, in: userPreferencesStore.linkRoutes),
           openRoutedLink(url, to: route.destination)
        {
            return
        }
        let targetSession = activeProfileWindowSession ?? profileWindowSessions.first
        if let model = targetSession?.chromeModel, model.opensExternalLinksInLittleWindow,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        {
            model.openInLittleWindow(url)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if targetSession?.chromeModel.canCreateTab == true {
            targetSession?.chromeModel.openURLInNewTab(url)
            targetSession?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if targetSession != nil, !isTerminationRequested {
            pendingNavigationURLs.append(url)
            return
        }

        NSWorkspace.shared.open(url)
    }

    /// Applies a link route. False when the Space's window is closed or cannot
    /// take the link, which then opens as usual.
    private func openRoutedLink(_ url: URL, to destination: BrowserLinkRoute.Destination) -> Bool {
        guard !isTerminationRequested else { return false }
        switch destination {
        case .space(let profileID, let spaceID):
            guard let session = profileWindowSessions.first(where: { $0.profile.id == profileID }),
                  session.chromeModel.openURL(url, inSpaceWithID: spaceID)
            else { return false }
            session.window.makeKeyAndOrderFront(nil)
        case .littleWindow:
            guard let model = (activeProfileWindowSession ?? profileWindowSessions.first)?.chromeModel,
                  model.canOpenLittleWindow
            else { return false }
            model.openInLittleWindow(url)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func openBrowserInternalPage(_ url: URL) {
        let targetChromeModel = activeChromeModel
        let targetWindow = activeBrowserWindow

        if targetChromeModel?.canCreateTab == true {
            targetChromeModel?.openURLInNewTab(url)
            targetWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if targetChromeModel != nil, !isTerminationRequested {
            pendingNavigationURLs.append(url)
        }
    }

    private func openPendingNavigationURLsIfPossible() {
        let targetSession = activeProfileWindowSession ?? profileWindowSessions.first
        guard targetSession?.chromeModel.canCreateTab == true, !pendingNavigationURLs.isEmpty else {
            return
        }

        let urls = pendingNavigationURLs
        pendingNavigationURLs.removeAll()

        for url in urls {
            // A link that arrived before the window was ready still follows its rule.
            if let route = BrowserLinkRouter.route(for: url, in: userPreferencesStore.linkRoutes),
               openRoutedLink(url, to: route.destination)
            {
                continue
            }
            targetSession?.chromeModel.openURLInNewTab(url)
        }

        targetSession?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult private func updateSetAsDefaultBrowserMenuItem(_ item: NSMenuItem?) -> Bool {
        let isDefaultBrowser = defaultBrowserService.isDefaultBrowser
        item?.state = isDefaultBrowser ? .on : .off
        return !isDefaultBrowser
    }

    private func refreshSetAsDefaultBrowserMenuItem() {
        setAsDefaultBrowserMenuItem?.isEnabled = updateSetAsDefaultBrowserMenuItem(setAsDefaultBrowserMenuItem)
    }
}
