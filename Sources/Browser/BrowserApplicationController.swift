import AppKit
import SwiftUI

@objcMembers
@MainActor
public final class BrowserApplicationController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var chromeModel: BrowserChromeModel?
    private var hasReceivedBrowserContext = false

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
        .terminateNow
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        chromeModel?.isShuttingDown = true
        NSApp.terminate(sender)
        return false
    }

    @objc
    public func handleBrowserContextInitialized() {
        hasReceivedBrowserContext = true
        chromeModel?.handleContextReady()
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
    public func reloadCurrentTab(_ sender: Any?) {
        chromeModel?.reloadCurrentTab()
    }

    @objc
    public func forceReloadCurrentTab(_ sender: Any?) {
        chromeModel?.forceReloadCurrentTab()
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
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
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
        fileMenuItem.submenu = fileMenu

        let viewMenu = NSMenu(title: "View")
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
        }
        self.chromeModel = chromeModel

        let hostingView = NSHostingView(rootView: BrowserRootView(model: chromeModel))
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
