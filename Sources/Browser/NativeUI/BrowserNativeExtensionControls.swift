import AppKit
import Combine

// MARK: - BrowserNativeExtensionMenus

@MainActor enum BrowserNativeExtensionMenus {
    static func menu(
        for browserExtension: BrowserExtension,
        isPinned: Bool,
        currentHost: String?,
        onOpenStore: @escaping () -> Void,
        onOpenDetails: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onTogglePinned: @escaping () -> Void
    ) -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(browserExtension.name, to: menu, action: onOpenStore)
        menu.addItem(.separator())
        let access = BrowserNativeMenus.submenu(BrowserStrings.extensionsSiteAccessMenu, in: menu)
        BrowserNativeMenus.add(BrowserStrings.extensionsSiteAccessOnClick, to: access, action: {})
        if let currentHost, !currentHost.isEmpty {
            BrowserNativeMenus.add(
                String(format: BrowserStrings.extensionsSiteAccessCurrentSite, currentHost),
                to: access,
                action: {}
            )
        }
        let allSites = BrowserNativeMenus.add(BrowserStrings.extensionsSiteAccessAllSites, to: access, action: {})
        allSites.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        access.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsSiteAccessLearnMore, to: access, action: {})
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsRemoveFromTheBrowser, to: menu, action: onRemove)
        BrowserNativeMenus.add(
            isPinned ? BrowserStrings.extensionsUnpinAction : BrowserStrings.extensionsPinAction,
            to: menu,
            action: onTogglePinned
        )
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsManageExtension, to: menu, action: onOpenDetails)
        BrowserNativeMenus.add(BrowserStrings.extensionsViewWebPermissions, to: menu, action: onOpenDetails)
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsInspectPopup, to: menu, enabled: false, action: {})
        return menu
    }
}

// MARK: - BrowserNativeExtensionButton

final class BrowserNativeExtensionButton: BrowserNativePressableView {
    // MARK: Lifecycle

    init(tile: Bool, sidebar: Bool = false) {
        self.tile = tile
        self.sidebar = sidebar
        super.init(frame: .zero)
        addSubview(icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        cornerRadius = tile
            ? BrowserChromeLayout.extensionTileCornerRadius
            : sidebar
                ? BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius
                : BrowserChromeLayout.chromeButtonCornerRadius
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func interactionChanged() {
        super.interactionChanged()
        fillColor = tile
            ? .controlBackgroundColor
            : isHovered ? (sidebar ? BrowserChromeColors.currentURLButtonHover : BrowserChromeColors.rowHover) : .clear
    }

    override func layout() {
        super.layout()
        let size = tile
            ? BrowserChromeLayout.extensionTileIconSize
            : BrowserChromeLayout.sidebarCurrentURLExtensionIconSize
        icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }

    func update(_ browserExtension: BrowserExtension?) {
        if let browserExtension {
            let decodedIcon = browserExtension.iconImage
            icon.image = decodedIcon ?? NSImage(
                systemSymbolName: "puzzlepiece.extension",
                accessibilityDescription: nil
            )
            icon.contentTintColor = decodedIcon == nil
                ? (sidebar ? BrowserChromeColors.currentURLText : BrowserChromeColors.secondaryText)
                : nil
            icon.alphaValue = browserExtension.isEnabled ? 1 : 0.38
            setAccessibilityLabel(browserExtension.name)
            setAccessibilityIdentifier("browser.extensions.\(tile ? "tile" : "pinned").\(browserExtension.id)")
            tooltipTitle = tile ? nil : browserExtension.name
        } else {
            icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(
                    pointSize: BrowserChromeLayout.extensionTileIconSize,
                    weight: .semibold
                ))
            icon.contentTintColor = .labelColor
            icon.alphaValue = 1
            setAccessibilityLabel(BrowserStrings.extensionsAddAction)
            setAccessibilityIdentifier("browser.extensions.add")
        }
        interactionChanged()
    }

    // MARK: Private

    private let tile: Bool
    private let sidebar: Bool
    private let icon = NSImageView()
}

// MARK: - BrowserSiteControlCenterViewController

final class BrowserSiteControlCenterViewController: NSViewController {
    // MARK: Lifecycle

    init(model: BrowserChromeModel) { self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    var onManage: () -> Void = {}
    var onAdd: () -> Void = {}
    var onSelectExtension: (String) -> Void = { _ in }
    var menuForExtension: (BrowserExtension) -> NSMenu = { _ in NSMenu() }

    override func loadView() {
        view = root
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier("browser.extensions.control-center")
        root.addSubview(heading)
        root.addSubview(manage)
        manage.isBordered = false
        manage.bezelStyle = .inline
        manage.font = .systemFont(ofSize: 12, weight: .medium)
        manage.contentTintColor = .linkColor
        manage.setAccessibilityIdentifier("browser.extensions.manage")
        manage.onAction = { [weak self] in self?.onManage() }
        observation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let items = BrowserExtensionControlCenterModel.gridItems(for: model.browserExtensions)
        let ids = Set(items.map(\.id))
        for id in Set(tiles.keys).subtracting(ids) {
            tiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        let padding = BrowserChromeLayout.siteControlPopoverPadding
        let width = BrowserChromeLayout.siteControlPopoverWidth
        let tileSize = BrowserChromeLayout.extensionTileSize
        preferredContentSize = NSSize(
            width: width,
            height: padding * 2 + 18 + BrowserChromeLayout.siteControlPopoverSpacing + tileSize
        )
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        heading.frame = NSRect(x: padding, y: padding, width: 170, height: 18)
        let manageWidth = ceil(manage.intrinsicContentSize.width)
        manage.frame = NSRect(x: width - padding - manageWidth, y: padding - 2, width: manageWidth, height: 22)
        for (index, item) in items.enumerated() {
            let tile = tiles[item.id] ?? BrowserNativeExtensionButton(tile: true)
            if tiles[item.id] == nil {
                tiles[item.id] = tile
                root.addSubview(tile)
            }
            switch item.kind {
            case .installed(let browserExtension):
                tile.update(browserExtension)
                tile.onClick = { [weak self] _ in self?.onSelectExtension(browserExtension.id) }
                tile.menuProvider = { [weak self] in self?.menuForExtension(browserExtension) ?? NSMenu() }
            case .add:
                tile.update(nil)
                tile.onClick = { [weak self] _ in self?.onAdd() }
                tile.menuProvider = nil
            }
            tile.frame = NSRect(
                x: padding + CGFloat(index) * (tileSize + BrowserChromeLayout.extensionGridSpacing),
                y: padding + 18 + BrowserChromeLayout.siteControlPopoverSpacing,
                width: tileSize,
                height: tileSize
            )
        }
    }

    // MARK: Private

    private let model: BrowserChromeModel
    private let root = BrowserNativeSurface()
    private let heading = BrowserNativeControls.label(
        BrowserStrings.extensionsSectionTitle,
        size: 13,
        weight: .semibold
    )
    private let manage = BrowserActionButton(BrowserStrings.extensionsManageAction, action: {})
    private var tiles = [String: BrowserNativeExtensionButton]()
    private var observation: AnyCancellable?
}

// MARK: - BrowserExtensionActionPopupViewController

/// The popover controller owns exactly one engine popup lifetime.
final class BrowserExtensionActionPopupViewController: NSViewController {
    // MARK: Lifecycle

    init(popup: BrowserExtensionActionPopup) { self.popup = popup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        if !closed {
            popup.close()
        }
    }

    // MARK: Internal

    override func loadView() {
        let clip = BrowserViewportClipView(hostView: popup.hostView)
        clip.updateClipping(
            cornerRadius: BrowserChromeLayout.extensionActionPopupCornerRadius,
            maskedCorners: [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        )
        preferredContentSize = NSSize(
            width: BrowserChromeLayout.extensionActionPopupWidth,
            height: BrowserChromeLayout.extensionActionPopupHeight
        )
        clip.frame = NSRect(origin: .zero, size: preferredContentSize)
        clip.setAccessibilityIdentifier("browser.extensions.action-popup")
        view = clip
    }

    override func viewDidDisappear() { super.viewDidDisappear()
        close()
    }

    func close() { guard !closed else { return }
        closed = true
        popup.close()
    }

    // MARK: Private

    private let popup: BrowserExtensionActionPopup
    private var closed = false
}
