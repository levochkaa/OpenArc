// BrowserNativeExtensionControls.swift

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
        onTogglePinned: @escaping () -> Void,
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
                action: {},
            )
        }
        let allSites = BrowserNativeMenus.add(BrowserStrings.extensionsSiteAccessAllSites, to: access, action: {})
        allSites.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        access.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsSiteAccessLearnMore, to: access, action: {})
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsRemoveFromOpenArc, to: menu, action: onRemove)
        BrowserNativeMenus.add(
            isPinned ? BrowserStrings.extensionsUnpinAction : BrowserStrings.extensionsPinAction,
            to: menu,
            action: onTogglePinned,
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
    // MARK: Private

    private let tile: Bool
    private let sidebar: Bool
    private let icon = NSImageView()

    init(tile: Bool, sidebar: Bool = false) {
        self.tile = tile
        self.sidebar = sidebar
        super.init(frame: .zero)
        pressedScale = tile ? 1 : BrowserChromeLayout.sidebarCloseButtonPressedScale
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
                accessibilityDescription: nil,
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
                    weight: .semibold,
                ))
            icon.contentTintColor = .labelColor
            icon.alphaValue = 1
            setAccessibilityLabel(BrowserStrings.extensionsAddAction)
            setAccessibilityIdentifier("browser.extensions.add")
        }
        interactionChanged()
    }
}

// MARK: - BrowserExtensionActionPopupViewController

/// The popover controller owns exactly one engine popup lifetime.
final class BrowserExtensionActionPopupViewController: NSViewController {
    // MARK: Private

    private let popup: BrowserExtensionActionPopup
    private var closed = false

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
            ],
        )
        preferredContentSize = NSSize(
            width: BrowserChromeLayout.extensionActionPopupWidth,
            height: BrowserChromeLayout.extensionActionPopupHeight,
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
}
