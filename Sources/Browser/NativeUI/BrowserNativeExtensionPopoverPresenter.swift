// BrowserNativeExtensionPopoverPresenter.swift

import AppKit
import SecurityInterface

/// Shared extension popovers for browser chrome and installed web-app windows.
@MainActor final class BrowserNativeExtensionPopoverPresenter: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private static let actionWindowOffset = NSPoint(x: 40, y: 10)
    private static let actionTitleBarHeight: CGFloat = 32

    // MARK: Internal

    var onPresentationChanged: () -> Void = {}

    // MARK: Private

    private let model: BrowserChromeModel
    private let centerController: BrowserSiteControlCenterViewController
    private let center = BrowserNativePopover()
    private var action: NSPanel?
    private var outsideClickMonitor: Any?
    private var popupController: BrowserExtensionActionPopupViewController?
    private weak var anchor: NSView?
    private var preferredEdge = NSRectEdge.minY

    var isPresented: Bool { center.isShown || action?.isVisible == true }

    init(model: BrowserChromeModel) {
        self.model = model
        self.centerController = BrowserSiteControlCenterViewController(model: model)
        super.init()
        center.behavior = .transient
        center.delegate = self
        center.contentViewController = centerController
        centerController.onManage = { [weak self] in self?.close()
            model.openExtensionsManager()
        }
        centerController.onAdd = { [weak self] in self?.close()
            model.openExtensionStore()
        }
        centerController.onSelectExtension = { [weak self] id in
            guard let self, let anchor else { return }
            openExtension(id: id, relativeTo: anchor, preferredEdge: preferredEdge)
        }
        centerController.menuForExtension = { [weak self] in self?.menu(for: $0) ?? NSMenu() }
        centerController.onAction = { [weak self] action in
            self?.close()
            let urlString = model.currentTab?.urlString ?? ""
            switch action {
            case .copyURL: _ = model.copySelectedTabLink()
            case .capture: _ = model.beginAreaCapture()
            case .captureFullPage: _ = model.captureFullPageSelectedTabToPasteboard()
            case .clearCache: model.clearCacheAndRefreshCurrentTab()
            case .clearCookies: model.clearCookiesAndRefreshCurrentTab()
            case .allSiteSettings: model.openAllSiteSettings(forURLString: urlString)
            case .showCertificate:
                Self.showCertificate(model.certificateChainOfSelectedTab(), for: self?.anchor?.window)
            }
        }
    }

    isolated deinit { popupController?.close() }

    /// The system's certificate panel over the window, with the chain to its root
    /// above the certificate.
    private static func showCertificate(_ chain: [Data], for window: NSWindow?) {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return }
        let panel = SFCertificatePanel.shared() ?? SFCertificatePanel()
        if let window {
            panel.beginSheet(
                for: window,
                modalDelegate: nil,
                didEnd: nil,
                contextInfo: nil,
                certificates: certificates,
                showGroup: true,
            )
        } else {
            panel.runModal(forCertificates: certificates, showGroup: true)
        }
    }

    private static func place(_ panel: NSPanel, contentSize: NSSize, in parent: NSWindow?, content: NSView?) {
        let bar = actionTitleBarHeight
        let size = NSSize(width: contentSize.width, height: contentSize.height + bar)
        var origin = panel.frame.origin
        if let parent {
            origin = NSPoint(
                x: parent.frame.minX + actionWindowOffset.x,
                y: parent.frame.maxY - actionWindowOffset.y - size.height,
            )
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        content?.frame = NSRect(origin: .zero, size: contentSize)
    }

    func refresh() { centerController.refresh() }
    func showControlCenter(relativeTo anchor: NSView, preferredEdge: NSRectEdge) {
        self.anchor = anchor
        self.preferredEdge = preferredEdge
        model.refreshBrowserExtensions()
        _ = centerController.view
        centerController.reloadSiteSettings()
        center.contentSize = centerController.preferredContentSize
        center.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        onPresentationChanged()
    }

    func openExtension(id: String, relativeTo anchor: NSView, preferredEdge: NSRectEdge) {
        let popup = model.openExtension(id: id)
        close()
        guard let popup else { return }
        self.anchor = anchor
        self.preferredEdge = preferredEdge
        let controller = BrowserExtensionActionPopupViewController(popup: popup)
        _ = controller.view
        // A small titled window of the page's size, near the browser window's corner.
        // A click anywhere else in the app closes it.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let container = NSView(frame: NSRect(origin: .zero, size: controller.preferredContentSize))
        container.addSubview(controller.view)
        panel.contentView = container
        let parent = anchor.window
        popup.onContentSizeChange = { [weak panel, weak controller] size in
            controller?.preferredContentSize = size
            guard let panel else { return }
            Self.place(panel, contentSize: size, in: parent, content: controller?.view)
        }
        popupController = controller
        action = panel
        anchor.isHidden = false
        Self.place(panel, contentSize: controller.preferredContentSize, in: parent, content: controller.view)
        parent?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .rightMouseDown,
        ]) { [weak self] event in
            guard let self, event.window !== action else { return event }
            close()
            return event
        }
        onPresentationChanged()
    }

    func close() {
        center.performClose(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        let old = action
        action = nil
        old?.delegate = nil
        popupController?.close()
        popupController = nil
        old?.parent?.removeChildWindow(old!)
        old?.orderOut(nil)
        onPresentationChanged()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === action else { return }
        close()
    }

    func popoverDidClose(_: Notification) {
        onPresentationChanged()
    }

    func menu(for browserExtension: BrowserExtension) -> NSMenu {
        let model = model
        let host = (model.currentTab?.urlString)
            .flatMap { URL(string: $0)?.host }
            .map { BrowserURLDisplayFormatter.hostDisplayString(forHost: $0) }
        return BrowserNativeExtensionMenus.menu(
            for: browserExtension,
            isPinned: model.pinnedExtensionIDs.contains(browserExtension.id),
            currentHost: host,
            onOpenStore: { [weak self] in self?.close()
                model.openExtensionStore(id: browserExtension.id)
            },
            onOpenDetails: { [weak self] in self?.close()
                model.openExtensionDetails(id: browserExtension.id)
            },
            onRemove: { [weak self] in self?.close()
                model.removeExtension(id: browserExtension.id)
            },
            onTogglePinned: { model.toggleExtensionPinned(id: browserExtension.id)
            },
        )
    }
}
