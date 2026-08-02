import AppKit
import Combine
import Settings
import SwiftUI

// MARK: - BrowserApplicationController

@objcMembers
@MainActor public final class BrowserApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate,
NSUserInterfaceValidations {
    // MARK: Lifecycle

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
        configureUpdateControllerIfNeeded()
        installMainMenu(for: app)
        observeShortcutStore()
        observeAppearancePreference()
        installLayoutIndependentKeyMonitor()
        startBatterySaverController()
        app.delegate = self
        createMainWindow()
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

    public func applicationDidBecomeActive(_: Notification) {
        for chromeModel in allChromeModels {
            chromeModel.handleApplicationDidBecomeActive()
        }
        BrowserTelemetry.captureUsage(.appBecameActive)
        refreshSetAsDefaultBrowserMenuItem()
    }

    public func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            openAboutLink(url)
        }
    }

    public func windowShouldClose(_: NSWindow) -> Bool {
        true
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

        if let index = profileWindowSessions.firstIndex(where: { $0.window === closedWindow }) {
            let session = profileWindowSessions.remove(at: index)
            session.chromeModel.prepareForTermination()
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
        openPendingNavigationURLsIfPossible()
    }

    public func handleApplicationWillTerminate() {
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
        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            activeChromeModel?.toggleSidebar()
        }
    }

    public func toggleBookmarksBar(_: Any?) {
        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            userPreferencesStore.bookmarksBarVisible.toggle()
        }
    }

    public func createNewTab(_: Any?) {
        activeChromeModel?.toggleCommandBar()
    }

    public func createNewIncognitoWindow(_: Any?) {
        createIncognitoWindow(copyingFullscreenFrom: activeBrowserWindow)
    }

    public func openHistory(_: Any?) {
        openBrowserInternalPage(BrowserInternalPageRouting.historyURL)
    }

    public func toggleCurrentPageBookmark(_: Any?) {
        activeChromeModel?.toggleSelectedTabBookmark()
    }

    public func archiveCurrentTab(_: Any?) {
        activeChromeModel?.archiveSelectedTab()
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
        _ = activeChromeModel?.presentFindInPage()
    }

    public func findAndReplace(_: Any?) {}

    public func findNextInPage(_: Any?) {
        activeChromeModel?.findNextInPage()
    }

    public func findPreviousInPage(_: Any?) {
        activeChromeModel?.findPreviousInPage()
    }

    public func useSelectionToFind(_: Any?) {}

    public func jumpToSelection(_: Any?) {}

    public func clearTemporaryTabs(_: Any?) {
        activeChromeModel?.clearTemporaryTabs()
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else {
            return true
        }

        switch action {
        case #selector(createNewTab(_:)):
            return activeChromeModel?.canCreateTab ?? false
        case #selector(createNewIncognitoWindow(_:)):
            return !isTerminationRequested
        case #selector(openHistory(_:)):
            return activeChromeModel != nil && !isTerminationRequested
        case #selector(archiveCurrentTab(_:)):
            return activeChromeModel?.canArchiveSelectedTab ?? false
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
        case #selector(pasteAndMatchStyle(_:)):
            return activeChromeModel?.canPasteAndMatchStyle ?? true
        case #selector(printCurrentPage(_:)):
            return activeChromeModel?.canPrintPage ?? false
        case #selector(copySelectedTabLink(_:)):
            return activeChromeModel?.canCopySelectedTabLink ?? false
        case #selector(findInPage(_:)):
            return activeChromeModel?.canPresentFindInPage ?? false
        case #selector(findNextInPage(_:)), #selector(findPreviousInPage(_:)):
            return activeChromeModel?.canStepThroughFindMatches ?? false
        case #selector(findAndReplace(_:)), #selector(jumpToSelection(_:)), #selector(useSelectionToFind(_:)):
            return false
        case #selector(clearTemporaryTabs(_:)):
            return activeChromeModel?.canClearTemporaryTabs ?? false
        case #selector(toggleBookmarksBar(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.state = userPreferencesStore.bookmarksBarVisible ? .on : .off
            }
            return true
        case #selector(setAsDefaultBrowser(_:)):
            return updateSetAsDefaultBrowserMenuItem(item as? NSMenuItem)
        case #selector(checkForUpdates(_:)):
            return updateController?.canCheckForUpdates ?? false
        default:
            return true
        }
    }

    // MARK: Private

    private var aboutWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?
    private var incognitoWindowSessions = [BrowserIncognitoWindowSession]()
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
    private var didConfirmTerminationWarning = false
    private var layoutIndependentKeyMonitor: Any?
    private var shortcutStoreCancellable: AnyCancellable?
    private var appearancePreferenceCancellable: AnyCancellable?
    private var profileStoreCancellable: AnyCancellable?

    private var shouldPresentQuitWarning: Bool {
        guard !didConfirmTerminationWarning, !isQuitWarningPresented else {
            return false
        }

        return BrowserQuitWarningPolicy(
            warnsBeforeQuitting: userPreferencesStore.warnBeforeQuitting,
            openTabCount: allChromeModels.reduce(0) { $0 + $1.tabs.count }
        ).shouldWarn
    }

    private var allChromeModels: [BrowserChromeModel] {
        profileWindowSessions.map(\.chromeModel) + incognitoWindowSessions.map(\.chromeModel)
    }

    private var activeChromeModel: BrowserChromeModel? {
        if let session = activeIncognitoWindowSession {
            return session.chromeModel
        }

        return activeProfileWindowSession?.chromeModel ?? profileWindowSessions.first?.chromeModel
    }

    private var activeBrowserWindow: NSWindow? {
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
        isTerminationRequested = true
        handleApplicationWillTerminate()
        for session in profileWindowSessions {
            session.window.orderOut(nil)
        }
        for session in incognitoWindowSessions {
            session.window.orderOut(nil)
        }
        DispatchQueue.main.async {
            if BrowserHasOpenBrowsers() != 0 {
                BrowserCloseAllBrowsers()
                return
            }

            NSApp.stop(nil)
        }
    }

    private func tearDownBrowserWindowSessions() {
        let windows = profileWindowSessions.map(\.window) + incognitoWindowSessions.map(\.window)
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
        app.mainMenu = menubar

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        let aboutItem = NSMenuItem(
            title: BrowserStrings.aboutMenuItem(appName: appName),
            action: #selector(openAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .openSettings),
            action: #selector(openSettings(_:))
        )
        appMenu.addItem(settingsItem)

        let checkForUpdatesItem = NSMenuItem(
            title: BrowserStrings.menuCheckForUpdates,
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        appMenu.addItem(checkForUpdatesItem)

        let setAsDefaultBrowserItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .setAsDefaultBrowser),
            action: #selector(setAsDefaultBrowser(_:))
        )
        setAsDefaultBrowserMenuItem = setAsDefaultBrowserItem
        updateSetAsDefaultBrowserMenuItem(setAsDefaultBrowserItem)
        appMenu.addItem(setAsDefaultBrowserItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: BrowserStrings.quitMenuItem(appName: appName),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: BrowserStrings.menuFile)
        let newTabItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newTab),
            action: #selector(createNewTab(_:))
        )
        fileMenu.addItem(newTabItem)

        let newIncognitoWindowItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .newIncognitoWindow),
            action: #selector(createNewIncognitoWindow(_:))
        )
        fileMenu.addItem(newIncognitoWindowItem)
        fileMenu.addItem(.separator())

        let toggleBookmarkItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleBookmark),
            action: #selector(toggleCurrentPageBookmark(_:))
        )
        fileMenu.addItem(toggleBookmarkItem)

        let archiveTabItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .archiveTab),
            action: #selector(archiveCurrentTab(_:))
        )
        fileMenu.addItem(archiveTabItem)

        let savePageItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .savePage),
            action: #selector(saveCurrentPage(_:))
        )
        fileMenu.addItem(savePageItem)

        let printItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .printPage),
            action: #selector(printCurrentPage(_:))
        )
        fileMenu.addItem(printItem)
        fileMenuItem.submenu = fileMenu

        let editMenu = NSMenu(title: BrowserStrings.menuEdit)
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuUndo,
                action: #selector(UndoManager.undo),
                keyEquivalent: "z"
            )
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuRedo,
                action: #selector(UndoManager.redo),
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuCut,
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x"
            )
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuCopy,
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c"
            )
        )
        editMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .copyLink),
                action: #selector(copySelectedTabLink(_:))
            )
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuPaste,
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
        )
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuPasteAndMatchStyle,
                action: #selector(pasteAndMatchStyle(_:)),
                keyEquivalent: "v",
                modifiers: [.command, .shift],
                target: self
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuSelectAll,
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
        )
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem()
        findMenuItem.title = BrowserStrings.menuFindTitle
        editMenu.addItem(findMenuItem)
        let findMenu = NSMenu(title: BrowserStrings.menuFindTitle)
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findInPage),
                action: #selector(findInPage(_:))
            )
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findAndReplace),
                action: #selector(findAndReplace(_:))
            )
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findNext),
                action: #selector(findNextInPage(_:))
            )
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .findPrevious),
                action: #selector(findPreviousInPage(_:))
            )
        )
        findMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuUseSelectionToFind,
                action: #selector(useSelectionToFind(_:)),
                keyEquivalent: "",
                target: self
            )
        )
        findMenu.addItem(
            makeMenuItem(
                descriptor: shortcutStore.descriptor(for: .jumpToSelection),
                action: #selector(jumpToSelection(_:))
            )
        )
        findMenuItem.submenu = findMenu
        editMenuItem.submenu = editMenu

        let viewMenu = NSMenu(title: BrowserStrings.menuView)
        let backItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .goBack),
            action: #selector(goBack(_:))
        )
        viewMenu.addItem(backItem)

        let forwardItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .goForward),
            action: #selector(goForward(_:))
        )
        viewMenu.addItem(forwardItem)

        let historyItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .openHistory),
            action: #selector(openHistory(_:))
        )
        viewMenu.addItem(historyItem)

        viewMenu.addItem(.separator())

        let refreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .reload),
            action: #selector(reloadCurrentTab(_:))
        )
        viewMenu.addItem(refreshItem)

        let forceRefreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .forceReload),
            action: #selector(forceReloadCurrentTab(_:))
        )
        viewMenu.addItem(forceRefreshItem)

        let clearCacheAndRefreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .clearCacheAndRefresh),
            action: #selector(clearCacheAndRefreshCurrentTab(_:))
        )
        viewMenu.addItem(clearCacheAndRefreshItem)

        let clearCookiesAndRefreshItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .clearCookiesAndRefresh),
            action: #selector(clearCookiesAndRefreshCurrentTab(_:))
        )
        viewMenu.addItem(clearCookiesAndRefreshItem)

        viewMenu.addItem(.separator())

        let toggleSidebarItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleSidebar),
            action: #selector(toggleSidebar(_:))
        )
        viewMenu.addItem(toggleSidebarItem)

        let toggleBookmarksBarItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleBookmarksBar),
            action: #selector(toggleBookmarksBar(_:))
        )
        toggleBookmarksBarItem.state = userPreferencesStore.bookmarksBarVisible ? .on : .off
        viewMenu.addItem(toggleBookmarksBarItem)
        viewMenu.addItem(.separator())

        let clearTemporaryTabsItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .clearTemporaryTabs),
            action: #selector(clearTemporaryTabs(_:))
        )
        viewMenu.addItem(clearTemporaryTabsItem)
        viewMenuItem.submenu = viewMenu
    }

    private func makeMenuItem(descriptor: BrowserCommandDescriptor, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: descriptor.menuTitle,
            action: action,
            keyEquivalent: descriptor.shortcut.keyEquivalent
        )
        item.keyEquivalentModifierMask = descriptor.shortcut.modifiers
        item.target = self
        return item
    }

    private func makeStandardMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
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
        if let spaceIndex = BrowserSpaceShortcuts.spaceIndex(
            forPhysicalKeyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
            return selectSpace(at: spaceIndex)
        }

        guard let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            shortcutResolver: shortcutStore
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

    private func performLayoutIndependentShortcutCommand(
        _ command: BrowserLayoutIndependentShortcutCommand
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
        case .openSettings:
            openSettings(nil)
            return true
        case .setAsDefaultBrowser:
            guard !defaultBrowserService.isDefaultBrowser else {
                return false
            }

            setAsDefaultBrowser(nil)
            return true
        case .newTab:
            guard activeChromeModel?.canCreateTab ?? false else {
                return false
            }

            createNewTab(nil)
            return true
        case .newIncognitoWindow:
            createNewIncognitoWindow(nil)
            return true
        case .openHistory:
            guard activeChromeModel != nil, !isTerminationRequested else {
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
            return activeChromeModel?.archiveSelectedTab() ?? false
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
            return false
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
        case .toggleSidebar:
            guard activeChromeModel != nil else {
                return false
            }

            toggleSidebar(nil)
            return true
        case .toggleBookmarksBar:
            toggleBookmarksBar(nil)
            return true
        }
    }

    private func performPasteAndMatchStyle(_ sender: Any?) -> Bool {
        if NSApp.sendAction(
            #selector(NSTextView.pasteAsPlainText(_:)),
            to: nil,
            from: sender ?? self
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
            }
        }
    }

    private func configureUpdateControllerIfNeeded() {
        guard updateController == nil else {
            return
        }

        updateController = BrowserUpdateController(preferencesStore: userPreferencesStore)
    }

    private func startBatterySaverController() {
        guard batterySaverController == nil else {
            return
        }

        let controller = BrowserBatterySaverController(preferencesStore: userPreferencesStore)
        batterySaverController = controller
        controller.start()
    }

    private func presentSettingsWindow() {
        guard
            let profileStore,
            let profileSession = activeProfileWindowSession ?? profileWindowSessions.first
        else {
            return
        }

        if let settingsWindowController {
            settingsWindowController.show()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindowController = SettingsWindowController(
            panes: settingsPanes(
                model: profileSession.chromeModel,
                profileStore: profileStore,
                currentProfileID: profileSession.profile.id,
                accountStore: profileSession.accountStore
            ),
            style: .toolbarItems,
            animated: false,
            hidesToolbarForSingleItem: false
        )
        self.settingsWindowController = settingsWindowController
        settingsWindowController.show()

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
        accountStore: BrowserAccountStore?
    ) -> [SettingsPaneConvertible] {
        BrowserSettingsPane.allCases.map { pane in
            Settings.Pane(
                identifier: Settings.PaneIdentifier(pane.rawValue),
                title: pane.title,
                toolbarIcon: NSImage(
                    systemSymbolName: pane.systemImageName,
                    accessibilityDescription: pane.title
                ) ?? NSImage()
            ) {
                BrowserSettingsView(
                    model: model,
                    profileStore: profileStore,
                    currentProfileID: currentProfileID,
                    accountStore: accountStore,
                    pane: pane,
                    openProfile: { [weak self] profile in
                        self?.openProfile(profile)
                    },
                    openURL: { [weak self] url in
                        self?.openBrowserInternalPage(url)
                    }
                )
            }
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
                y: parentFrame.midY - childFrame.height / 2
            )
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
            copyingFullscreenFrom: nil
        )
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
            copyingFullscreenFrom: activeBrowserWindow
        )
    }

    private func createProfileWindow(
        for profile: BrowserProfile,
        runtimeConfiguration: BrowserRuntimeConfiguration,
        copyingFullscreenFrom sourceWindow: NSWindow?
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
            runtimeConfiguration: runtimeConfiguration
        )
        let sessionSnapshotURL = sessionStorageDirectoryURL
            .appendingPathComponent(BrowserTabSessionSnapshotStore.snapshotFileName, isDirectory: false)
        let sqliteSessionStore = try? BrowserSQLiteSessionStore(
            databaseURL: sessionStorageDirectoryURL
                .appendingPathComponent(BrowserSQLiteSessionStore.databaseFileName, isDirectory: false)
        )
        let profileDirectoryCandidates = BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
            profileDirectoryURL: profileDirectoryURL
        )
        let bookmarksModel = BrowserBookmarksModel(
            store: BrowserChromiumBookmarkStore(profileDirectoryCandidates: profileDirectoryCandidates)
        )
        let historyStore = BrowserChromiumHistoryStore(profileDirectoryCandidates: profileDirectoryCandidates)
        let authSessionStore = BrowserAuthSessionStore(profileID: profile.isDefault ? nil : profile.id)
        let syncClient = BrowserSyncConfiguration.current().map { configuration in
            BrowserRemoteSyncClient(configuration: configuration)
        }
        let syncCoordinator: BrowserSyncService? =
            if let sqliteSessionStore, let syncClient {
                BrowserSyncService(
                    localStore: sqliteSessionStore,
                    remoteClient: syncClient,
                    authSessionStore: authSessionStore
                )
            } else {
                nil
            }
        let accountStore = BrowserAccountStore(
            syncClient: syncClient,
            authSessionStore: authSessionStore
        )
        let chromeModel = BrowserChromeModel(
            tabDriver: BrowserTabControllerDriver(profileCachePath: profileDirectoryURL.path),
            sessionSnapshotStore: sqliteSessionStore ?? BrowserTabSessionSnapshotStore(snapshotURL: sessionSnapshotURL),
            sessionPreferencesStore: sqliteSessionStore ?? BrowserSessionPreferencesStore(),
            userPreferencesStore: userPreferencesStore,
            shortcutStore: shortcutStore,
            bookmarksModel: bookmarksModel,
            historyStore: historyStore,
            extensionManager: BrowserChromiumExtensionManager(profileDirectoryURL: profileDirectoryURL),
            extensionSidePanelDriver: BrowserExtensionSidePanelController(profileCachePath: profileDirectoryURL.path),
            extensionActionPopupDriver: BrowserExtensionActionPopupController(profileCachePath: profileDirectoryURL
                .path),
            syncCoordinator: syncCoordinator,
            profile: profile,
            availableProfileCount: profileStore?.profiles.count ?? 1,
            commandHandler: { [weak self] commandID in
                _ = self?.performLayoutIndependentShortcutCommand(commandID.layoutIndependentCommand)
            },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )
        syncCoordinator?.setSnapshotApplier(chromeModel)

        let rootView = BrowserRootView(model: chromeModel, updateController: updateController)
            .ignoresSafeArea(.container, edges: .top)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.safeAreaRegions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let window = BrowserMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = windowTitle(for: profile)
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
        let session = BrowserProfileWindowSession(
            window: window,
            chromeModel: chromeModel,
            accountStore: accountStore,
            profile: profile
        )
        profileWindowSessions.append(session)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        BrowserTelemetry.captureUsage(
            .profileWindowOpened,
            properties: [
                "profile": profile.isDefault ? "default" : "custom",
                "profile_count": "\(profileStore?.profiles.count ?? 1)",
            ]
        )
        updateProfilePresentationForOpenWindows()

        if hasReceivedBrowserContext {
            chromeModel.handleContextReady()
            openPendingNavigationURLsIfPossible()
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
        runtimeConfiguration: BrowserRuntimeConfiguration
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

    private func createIncognitoWindow(copyingFullscreenFrom sourceWindow: NSWindow?) {
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
                        .appendingPathComponent(sourceProfile.directoryName, isDirectory: true)
                )
            } else {
                []
            }
        let bookmarksModel = BrowserBookmarksModel(
            store: BrowserChromiumBookmarkStore(profileDirectoryCandidates: profileDirectoryCandidates)
        )
        let ephemeralSessionStore = BrowserEphemeralSessionStore()
        let chromeModel = BrowserChromeModel(
            tabDriver: BrowserTabControllerDriver(usesEphemeralRequestContext: true),
            sessionSnapshotStore: ephemeralSessionStore,
            sessionPreferencesStore: ephemeralSessionStore,
            userPreferencesStore: userPreferencesStore,
            shortcutStore: shortcutStore,
            bookmarksModel: bookmarksModel,
            historyStore: BrowserEmptyHistoryStore(),
            extensionManager: BrowserEmptyExtensionManager(),
            windowMode: .incognito,
            commandHandler: { [weak self] commandID in
                _ = self?.performLayoutIndependentShortcutCommand(commandID.layoutIndependentCommand)
            },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )

        let rootView = BrowserRootView(model: chromeModel, updateController: updateController)
            .ignoresSafeArea(.container, edges: .top)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.safeAreaRegions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let window = BrowserMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = BrowserStrings.menuNewIncognitoWindow
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
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if hasReceivedBrowserContext {
            chromeModel.handleContextReady()
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
        let hostingView = NSHostingView(rootView: rootView)

        let contentSize = NSSize(
            width: BrowserAboutLayout.windowWidth,
            height: BrowserAboutLayout.windowHeight
        )
        let aboutWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow.title = BrowserStrings.aboutWindowTitle(appName: info.applicationName)
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.titleVisibility = .hidden
        aboutWindow.titlebarAppearsTransparent = true
        aboutWindow.isMovableByWindowBackground = true
        aboutWindow.setContentSize(contentSize)
        aboutWindow.center()
        aboutWindow.contentView = hostingView
        aboutWindow.delegate = self

        self.aboutWindow = aboutWindow
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openAboutLink(_ url: URL) {
        let targetSession = activeProfileWindowSession ?? profileWindowSessions.first
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
