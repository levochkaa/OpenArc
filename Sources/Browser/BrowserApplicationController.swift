import AppKit
import Combine
import SwiftUI

// MARK: - BrowserWindowContentContainerView

private final class BrowserWindowContentContainerView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateCornerRadius()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    static let defaultCornerRadius: CGFloat = BrowserWindowGeometry.windowCornerRadius

    var cornerRadius: CGFloat = defaultCornerRadius {
        didSet {
            guard cornerRadius != oldValue else {
                return
            }

            updateCornerRadius()
        }
    }

    // MARK: Private

    private func updateCornerRadius() {
        layer?.cornerRadius = cornerRadius
    }
}

// MARK: - BrowserMainWindow

private final class BrowserMainWindow: NSWindow {
    // MARK: Internal

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override var styleMask: NSWindow.StyleMask {
        didSet {
            updateWindowShape()
        }
    }

    override var contentView: NSView? {
        didSet {
            updateWindowShape()
        }
    }

    func configureBrowserChrome() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior.insert(.fullScreenPrimary)
        updateWindowShape()
    }

    // MARK: Private

    private func updateWindowShape() {
        guard let containerView = contentView as? BrowserWindowContentContainerView else {
            return
        }

        containerView.cornerRadius = styleMask.contains(.fullScreen)
            ? 0
            : BrowserWindowContentContainerView.defaultCornerRadius
    }
}

// MARK: - BrowserApplicationController

@objcMembers
@MainActor public final class BrowserApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate,
NSUserInterfaceValidations {
    // MARK: Lifecycle

    deinit {
        guard let layoutIndependentKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(layoutIndependentKeyMonitor)
    }

    // MARK: Public

    public func createApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installMainMenu(for: app)
        observeShortcutStore()
        installLayoutIndependentKeyMonitor()
        app.delegate = self
        createMainWindow()
        app.finishLaunching()
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
        chromeModel?.handleApplicationDidBecomeActive()
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

    public func handleBrowserContextInitialized() {
        hasReceivedBrowserContext = true
        chromeModel?.handleContextReady()
        openPendingNavigationURLsIfPossible()
    }

    public func handleApplicationWillTerminate() {
        chromeModel?.prepareForTermination()
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
        chromeModel?.toggleSidebar()
    }

    public func createNewTab(_: Any?) {
        chromeModel?.toggleCommandBar()
    }

    public func openHistory(_: Any?) {
        openBrowserInternalPage(BrowserInternalPageRouting.historyURL)
    }

    public func archiveCurrentTab(_: Any?) {
        chromeModel?.archiveSelectedTab()
    }

    public func goBack(_: Any?) {
        chromeModel?.goBack()
    }

    public func goForward(_: Any?) {
        chromeModel?.goForward()
    }

    public func reloadCurrentTab(_: Any?) {
        chromeModel?.reloadCurrentTab()
    }

    public func forceReloadCurrentTab(_: Any?) {
        chromeModel?.forceReloadCurrentTab()
    }

    public func saveCurrentPage(_: Any?) {
        chromeModel?.saveCurrentPage()
    }

    public func pasteAndMatchStyle(_ sender: Any?) {
        _ = performPasteAndMatchStyle(sender)
    }

    public func printCurrentPage(_: Any?) {
        chromeModel?.printCurrentPage()
    }

    public func copySelectedTabLink(_: Any?) {
        chromeModel?.copySelectedTabLink()
    }

    public func findInPage(_: Any?) {
        _ = chromeModel?.presentFindInPage()
    }

    public func findAndReplace(_: Any?) {}

    public func findNextInPage(_: Any?) {
        chromeModel?.findNextInPage()
    }

    public func findPreviousInPage(_: Any?) {
        chromeModel?.findPreviousInPage()
    }

    public func useSelectionToFind(_: Any?) {}

    public func jumpToSelection(_: Any?) {}

    public func clearTemporaryTabs(_: Any?) {
        chromeModel?.clearTemporaryTabs()
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else {
            return true
        }

        switch action {
        case #selector(createNewTab(_:)):
            return chromeModel?.canCreateTab ?? false
        case #selector(openHistory(_:)):
            return chromeModel != nil && !isTerminationRequested
        case #selector(archiveCurrentTab(_:)):
            return chromeModel?.canArchiveSelectedTab ?? false
        case #selector(goBack(_:)):
            return chromeModel?.canGoBack ?? false
        case #selector(goForward(_:)):
            return chromeModel?.canGoForward ?? false
        case #selector(forceReloadCurrentTab(_:)), #selector(reloadCurrentTab(_:)):
            return chromeModel?.canReload ?? false
        case #selector(saveCurrentPage(_:)):
            return chromeModel?.canSavePage ?? false
        case #selector(pasteAndMatchStyle(_:)):
            return chromeModel?.canPasteAndMatchStyle ?? true
        case #selector(printCurrentPage(_:)):
            return chromeModel?.canPrintPage ?? false
        case #selector(copySelectedTabLink(_:)):
            return chromeModel?.canCopySelectedTabLink ?? false
        case #selector(findInPage(_:)):
            return chromeModel?.canPresentFindInPage ?? false
        case #selector(findNextInPage(_:)), #selector(findPreviousInPage(_:)):
            return chromeModel?.canStepThroughFindMatches ?? false
        case #selector(findAndReplace(_:)), #selector(jumpToSelection(_:)), #selector(useSelectionToFind(_:)):
            return false
        case #selector(clearTemporaryTabs(_:)):
            return chromeModel?.canClearTemporaryTabs ?? false
        case #selector(setAsDefaultBrowser(_:)):
            return updateSetAsDefaultBrowserMenuItem(item as? NSMenuItem)
        default:
            return true
        }
    }

    // MARK: Private

    private var window: NSWindow?
    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var chromeModel: BrowserChromeModel?
    private let userPreferencesStore = BrowserUserPreferencesStore()
    private let shortcutStore = BrowserShortcutStore()
    private let defaultBrowserService = BrowserDefaultBrowserService()
    private weak var setAsDefaultBrowserMenuItem: NSMenuItem?
    private var pendingNavigationURLs = [URL]()
    private var hasReceivedBrowserContext = false
    private var isTerminationRequested = false
    private var isQuitWarningPresented = false
    private var didConfirmTerminationWarning = false
    private var layoutIndependentKeyMonitor: Any?
    private var shortcutStoreCancellable: AnyCancellable?

    private var shouldPresentQuitWarning: Bool {
        guard !didConfirmTerminationWarning, !isQuitWarningPresented else {
            return false
        }

        return BrowserQuitWarningPolicy(
            warnsBeforeQuitting: userPreferencesStore.warnBeforeQuitting,
            openTabCount: chromeModel?.tabs.count ?? 0
        ).shouldWarn
    }

    private func beginApplicationTermination() {
        isTerminationRequested = true
        handleApplicationWillTerminate()
        window?.orderOut(nil)
        DispatchQueue.main.async {
            if BrowserHasOpenBrowsers() != 0 {
                BrowserCloseAllBrowsers()
                return
            }

            NSApp.stop(nil)
        }
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

        viewMenu.addItem(.separator())

        let toggleSidebarItem = makeMenuItem(
            descriptor: shortcutStore.descriptor(for: .toggleSidebar),
            action: #selector(toggleSidebar(_:))
        )
        viewMenu.addItem(toggleSidebarItem)
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
        guard let chromeModel, chromeModel.spaces.indices.contains(index) else {
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
            guard chromeModel?.canCreateTab ?? false else {
                return false
            }

            createNewTab(nil)
            return true
        case .openHistory:
            guard chromeModel != nil, !isTerminationRequested else {
                return false
            }

            openHistory(nil)
            return true
        case .archiveTab:
            return chromeModel?.archiveSelectedTab() ?? false
        case .savePage:
            guard chromeModel?.canSavePage ?? false else {
                return false
            }

            saveCurrentPage(nil)
            return true
        case .printPage:
            guard chromeModel?.canPrintPage ?? false else {
                return false
            }

            printCurrentPage(nil)
            return true
        case .copyLink:
            guard chromeModel?.canCopySelectedTabLink ?? false else {
                return false
            }

            return chromeModel?.copySelectedTabLink() ?? false
        case .findInPage:
            guard chromeModel?.canPresentFindInPage ?? false else {
                return false
            }

            return chromeModel?.presentFindInPage() ?? false
        case .findAndReplace:
            return false
        case .findNextInPage:
            guard chromeModel?.canStepThroughFindMatches ?? false else {
                return false
            }

            findNextInPage(nil)
            return true
        case .findPreviousInPage:
            guard chromeModel?.canStepThroughFindMatches ?? false else {
                return false
            }

            findPreviousInPage(nil)
            return true
        case .jumpToSelection:
            return false
        case .clearTemporaryTabs:
            guard chromeModel?.canClearTemporaryTabs ?? false else {
                return false
            }

            clearTemporaryTabs(nil)
            return true
        case .goBack:
            guard chromeModel?.canGoBack ?? false else {
                return false
            }

            goBack(nil)
            return true
        case .goForward:
            guard chromeModel?.canGoForward ?? false else {
                return false
            }

            goForward(nil)
            return true
        case .reload:
            guard chromeModel?.canReload ?? false else {
                return false
            }

            reloadCurrentTab(nil)
            return true
        case .forceReload:
            guard chromeModel?.canReload ?? false else {
                return false
            }

            forceReloadCurrentTab(nil)
            return true
        case .toggleSidebar:
            guard chromeModel != nil else {
                return false
            }

            toggleSidebar(nil)
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

        return chromeModel?.pasteAndMatchStyleCurrentTab() ?? false
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

        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
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

    private func presentSettingsWindow() {
        guard let chromeModel else {
            return
        }

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = BrowserSettingsView(model: chromeModel) { [weak self] url in
            self?.openBrowserInternalPage(url)
        }
        let hostingView = NSHostingView(rootView: rootView)
        let contentSize = NSSize(
            width: BrowserSettingsLayout.windowWidth,
            height: BrowserSettingsLayout.windowHeight
        )
        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        settingsWindow.title = BrowserStrings.settingsWindowTitle
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.titleVisibility = .hidden
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.isMovableByWindowBackground = true
        settingsWindow.collectionBehavior = [.fullScreenAuxiliary]
        settingsWindow.setContentSize(contentSize)
        settingsWindow.contentView = hostingView

        center(settingsWindow, over: window)
        if let window {
            window.addChildWindow(settingsWindow, ordered: .above)
        }

        self.settingsWindow = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        let sessionSnapshotURL = BrowserRuntimeConfiguration.currentConfiguration().map {
            URL(fileURLWithPath: $0.sessionStoragePath, isDirectory: true)
                .appendingPathComponent(BrowserTabSessionSnapshotStore.snapshotFileName, isDirectory: false)
        }
        let chromeModel = BrowserChromeModel(
            tabDriver: BrowserTabControllerDriver(),
            sessionSnapshotStore: BrowserTabSessionSnapshotStore(snapshotURL: sessionSnapshotURL),
            sessionPreferencesStore: BrowserSessionPreferencesStore(),
            userPreferencesStore: userPreferencesStore,
            shortcutStore: shortcutStore,
            extensionManager: BrowserChromiumExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )
        self.chromeModel = chromeModel

        let rootView = BrowserRootView(model: chromeModel)
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
        window.title = BrowserStrings.applicationName
        window.delegate = self
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
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

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        self.window = window

        if hasReceivedBrowserContext {
            chromeModel.handleContextReady()
            openPendingNavigationURLsIfPossible()
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

        self.aboutWindow = aboutWindow
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openAboutLink(_ url: URL) {
        if chromeModel?.canCreateTab == true {
            chromeModel?.openURLInNewTab(url)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if chromeModel != nil, !isTerminationRequested {
            pendingNavigationURLs.append(url)
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func openBrowserInternalPage(_ url: URL) {
        if chromeModel?.canCreateTab == true {
            chromeModel?.openURLInNewTab(url)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if chromeModel != nil, !isTerminationRequested {
            pendingNavigationURLs.append(url)
        }
    }

    private func openPendingNavigationURLsIfPossible() {
        guard chromeModel?.canCreateTab == true, !pendingNavigationURLs.isEmpty else {
            return
        }

        let urls = pendingNavigationURLs
        pendingNavigationURLs.removeAll()

        for url in urls {
            chromeModel?.openURLInNewTab(url)
        }

        window?.makeKeyAndOrderFront(nil)
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
