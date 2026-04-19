import AppKit
import SwiftUI

@objcMembers
@MainActor
public final class BrowserApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSUserInterfaceValidations {
    private var window: NSWindow?
    private var chromeModel: BrowserChromeModel?
    private var hasReceivedBrowserContext = false
    private var isTerminationRequested = false

    public func createApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installMainMenu(for: app)
        app.delegate = self
        createMainWindow()
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestApplicationTermination(sender)
        return .terminateCancel
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    @objc
    public func handleBrowserContextInitialized() {
        hasReceivedBrowserContext = true
        chromeModel?.handleContextReady()
    }

    @objc
    public func handleApplicationWillTerminate() {
        chromeModel?.isShuttingDown = true
    }

    @objc
    public func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    @objc
    public func requestApplicationTermination(_ sender: Any?) {
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

    @objc
    public func toggleSidebar(_ sender: Any?) {
        chromeModel?.toggleSidebar()
    }

    @objc
    public func createNewTab(_ sender: Any?) {
        chromeModel?.createNewTab()
    }

    @objc
    public func goBack(_ sender: Any?) {
        chromeModel?.goBack()
    }

    @objc
    public func goForward(_ sender: Any?) {
        chromeModel?.goForward()
    }

    @objc
    public func reloadCurrentTab(_ sender: Any?) {
        chromeModel?.reloadCurrentTab()
    }

    @objc
    public func forceReloadCurrentTab(_ sender: Any?) {
        chromeModel?.forceReloadCurrentTab()
    }

    @objc
    public func saveCurrentPage(_ sender: Any?) {
        chromeModel?.saveCurrentPage()
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
        default:
            return true
        }
    }

    private func installMainMenu(for app: NSApplication) {
        let menubar = NSMenu()
        let appMenuItem = NSMenuItem()
        let fileMenuItem = NSMenuItem()
        let viewMenuItem = NSMenuItem()
        fileMenuItem.title = "File"
        viewMenuItem.title = "View"
        menubar.addItem(appMenuItem)
        menubar.addItem(fileMenuItem)
        menubar.addItem(viewMenuItem)
        app.mainMenu = menubar

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let newTabItem = NSMenuItem(
            title: "New Tab",
            action: #selector(createNewTab(_:)),
            keyEquivalent: "t"
        )
        newTabItem.target = self
        fileMenu.addItem(newTabItem)

        let savePageItem = NSMenuItem(
            title: "Save Page As...",
            action: #selector(saveCurrentPage(_:)),
            keyEquivalent: "s"
        )
        savePageItem.target = self
        savePageItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(savePageItem)
        fileMenuItem.submenu = fileMenu

        let viewMenu = NSMenu(title: "View")
        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(goBack(_:)),
            keyEquivalent: "["
        )
        backItem.target = self
        viewMenu.addItem(backItem)

        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(goForward(_:)),
            keyEquivalent: "]"
        )
        forwardItem.target = self
        viewMenu.addItem(forwardItem)

        viewMenu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(reloadCurrentTab(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        viewMenu.addItem(refreshItem)

        let forceRefreshItem = NSMenuItem(
            title: "Force Refresh",
            action: #selector(forceReloadCurrentTab(_:)),
            keyEquivalent: "r"
        )
        forceRefreshItem.target = self
        forceRefreshItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(forceRefreshItem)

        viewMenu.addItem(.separator())

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)
        viewMenuItem.submenu = viewMenu
    }

    private func createMainWindow() {
        let chromeModel = BrowserChromeModel { [weak self] title in
            self?.window?.title = title
        } allTabsClosedHandler: {}
        self.chromeModel = chromeModel

        let rootView = BrowserRootView(model: chromeModel)
            .ignoresSafeArea(.container, edges: .top)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.safeAreaRegions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TheBrowser"
        window.delegate = self
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
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
}
