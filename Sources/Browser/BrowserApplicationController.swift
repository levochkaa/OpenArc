import AppKit
import SwiftUI

private final class BrowserWindowContentContainerView: NSView {
    static let defaultCornerRadius: CGFloat = 12

    var cornerRadius: CGFloat = defaultCornerRadius {
        didSet {
            guard cornerRadius != oldValue else {
                return
            }

            updateCornerRadius()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateCornerRadius()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateCornerRadius() {
        layer?.cornerRadius = cornerRadius
    }
}

private final class BrowserMainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

    private func updateWindowShape() {
        guard let containerView = contentView as? BrowserWindowContentContainerView else {
            return
        }

        containerView.cornerRadius = styleMask.contains(.fullScreen) ? 0 : BrowserWindowContentContainerView.defaultCornerRadius
    }
}

@objcMembers
@MainActor
public final class BrowserApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSUserInterfaceValidations {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var chromeModel: BrowserChromeModel?
    private var hasReceivedBrowserContext = false
    private var isTerminationRequested = false
    private var layoutIndependentKeyMonitor: Any?

    deinit {
        guard let layoutIndependentKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(layoutIndependentKeyMonitor)
    }

    public func createApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installMainMenu(for: app)
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
    }

    public func windowShouldClose(_: NSWindow) -> Bool {
        true
    }

    public func handleBrowserContextInitialized() {
        hasReceivedBrowserContext = true
        chromeModel?.handleContextReady()
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

    public func requestApplicationTermination(_: Any?) {
        guard !isTerminationRequested else {
            return
        }

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

    public func toggleSidebar(_: Any?) {
        chromeModel?.toggleSidebar()
    }

    public func createNewTab(_: Any?) {
        chromeModel?.toggleCommandBar()
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

    public func copySelectedTabLink(_: Any?) {
        chromeModel?.copySelectedTabLink()
    }

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
        case #selector(goBack(_:)):
            return chromeModel?.canGoBack ?? false
        case #selector(goForward(_:)):
            return chromeModel?.canGoForward ?? false
        case #selector(reloadCurrentTab(_:)), #selector(forceReloadCurrentTab(_:)):
            return chromeModel?.canReload ?? false
        case #selector(saveCurrentPage(_:)):
            return chromeModel?.canSavePage ?? false
        case #selector(copySelectedTabLink(_:)):
            return chromeModel?.canCopySelectedTabLink ?? false
        case #selector(clearTemporaryTabs(_:)):
            return chromeModel?.canClearTemporaryTabs ?? false
        default:
            return true
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
        let settingsItem = makeMenuItem(
            descriptor: BrowserCommands.openSettings,
            action: #selector(openSettings(_:))
        )
        appMenu.addItem(settingsItem)
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
            descriptor: BrowserCommands.newTab,
            action: #selector(createNewTab(_:))
        )
        fileMenu.addItem(newTabItem)

        let savePageItem = makeMenuItem(
            descriptor: BrowserCommands.savePage,
            action: #selector(saveCurrentPage(_:))
        )
        fileMenu.addItem(savePageItem)
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
                descriptor: BrowserCommands.copyLink,
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
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeStandardMenuItem(
                title: BrowserStrings.menuSelectAll,
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
        )
        editMenuItem.submenu = editMenu

        let viewMenu = NSMenu(title: BrowserStrings.menuView)
        let backItem = makeMenuItem(
            descriptor: BrowserCommands.goBack,
            action: #selector(goBack(_:))
        )
        viewMenu.addItem(backItem)

        let forwardItem = makeMenuItem(
            descriptor: BrowserCommands.goForward,
            action: #selector(goForward(_:))
        )
        viewMenu.addItem(forwardItem)

        viewMenu.addItem(.separator())

        let refreshItem = makeMenuItem(
            descriptor: BrowserCommands.reload,
            action: #selector(reloadCurrentTab(_:))
        )
        viewMenu.addItem(refreshItem)

        let forceRefreshItem = makeMenuItem(
            descriptor: BrowserCommands.forceReload,
            action: #selector(forceReloadCurrentTab(_:))
        )
        viewMenu.addItem(forceRefreshItem)

        viewMenu.addItem(.separator())

        let toggleSidebarItem = makeMenuItem(
            descriptor: BrowserCommands.toggleSidebar,
            action: #selector(toggleSidebar(_:))
        )
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(.separator())

        let clearTemporaryTabsItem = makeMenuItem(
            descriptor: BrowserCommands.clearTemporaryTabs,
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
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifiers
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

            if self.handleLayoutIndependentKeyEvent(event) {
                return nil
            }

            return event
        }
    }

    private func handleLayoutIndependentKeyEvent(_ event: NSEvent) -> Bool {
        guard let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return false
        }

        return performLayoutIndependentShortcutCommand(command)
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
        case .selectAll:
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case .quit:
            quitApplication(nil)
            return true
        case .openSettings:
            openSettings(nil)
            return true
        case .newTab:
            guard chromeModel?.canCreateTab ?? false else {
                return false
            }

            createNewTab(nil)
            return true
        case .savePage:
            guard chromeModel?.canSavePage ?? false else {
                return false
            }

            saveCurrentPage(nil)
            return true
        case .copyLink:
            guard chromeModel?.canCopySelectedTabLink ?? false else {
                return false
            }

            return chromeModel?.copySelectedTabLink() ?? false
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

    private func createMainWindow() {
        let sessionSnapshotURL = BrowserRuntimeConfiguration.currentConfiguration().map {
            URL(fileURLWithPath: $0.sessionStoragePath, isDirectory: true)
                .appendingPathComponent(BrowserTabSessionSnapshotStore.snapshotFileName, isDirectory: false)
        }
        let chromeModel = BrowserChromeModel(
            tabDriver: BrowserTabControllerDriver(),
            sessionSnapshotStore: BrowserTabSessionSnapshotStore(snapshotURL: sessionSnapshotURL),
            sessionPreferencesStore: BrowserSessionPreferencesStore(),
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

        let rootView = BrowserSettingsView(model: chromeModel)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

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
        settingsWindow.title = BrowserStrings.menuSettings
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.titleVisibility = .hidden
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.toolbarStyle = .preference
        settingsWindow.setContentSize(contentSize)
        settingsWindow.center()

        let contentView = NSView(frame: settingsWindow.contentRect(forFrameRect: settingsWindow.frame))
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        settingsWindow.contentView = contentView
        self.settingsWindow = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
