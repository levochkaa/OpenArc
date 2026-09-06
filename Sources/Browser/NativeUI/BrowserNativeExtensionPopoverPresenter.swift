import AppKit

/// Shared extension popovers for browser chrome and installed web-app windows.
@MainActor final class BrowserNativeExtensionPopoverPresenter: NSObject, NSPopoverDelegate {
    // MARK: Lifecycle

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
    }

    isolated deinit { popupController?.close() }

    // MARK: Internal

    var onPresentationChanged: () -> Void = {}

    var isPresented: Bool { center.isShown || action?.isShown == true }

    func refresh() { centerController.refresh() }
    func showControlCenter(relativeTo anchor: NSView, preferredEdge: NSRectEdge) {
        self.anchor = anchor
        self.preferredEdge = preferredEdge
        model.refreshBrowserExtensions()
        _ = centerController.view
        centerController.refresh()
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
        let popover = BrowserNativePopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popupController = controller
        action = popover
        anchor.isHidden = false
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        onPresentationChanged()
    }

    func close() {
        center.performClose(nil)
        let old = action
        action = nil
        old?.delegate = nil
        popupController?.close()
        popupController = nil
        old?.performClose(nil)
        onPresentationChanged()
    }

    func popoverDidClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover, popover === action {
            popupController?.close()
            popupController = nil
            action = nil
        }
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
            }
        )
    }

    // MARK: Private

    private let model: BrowserChromeModel
    private let centerController: BrowserSiteControlCenterViewController
    private let center = BrowserNativePopover()
    private var action: BrowserNativePopover?
    private var popupController: BrowserExtensionActionPopupViewController?
    private weak var anchor: NSView?
    private var preferredEdge = NSRectEdge.minY
}
