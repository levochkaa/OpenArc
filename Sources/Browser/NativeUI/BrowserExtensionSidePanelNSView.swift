import AppKit
import QuartzCore

final class BrowserExtensionSidePanelNSView: NSView {
    // MARK: Lifecycle

    init(hostView: NSView) {
        self.viewport = BrowserViewportClipView(hostView: hostView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(viewport)
        loading.fillColor = BrowserChromeColors.contentBackground
        addSubview(loading)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = BrowserChromeColors.primaryText
        title.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        for view in [icon, title, closeButton] {
            addSubview(view)
        }
        closeButton.onAction = { [weak self] in self?.onClose() }
        closeButton.setAccessibilityIdentifier("browser.extension-panel.close")
        setAccessibilityIdentifier("browser.extension-panel")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    var onClose: () -> Void = {}
    let viewport: BrowserViewportClipView
    let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.extensionsCloseSidePanel,
        style: .extensionClose,
        pressEffect: .compress,
        action: {}
    )

    override func layout() {
        super.layout()
        let height = BrowserChromeLayout.extensionSidePanelHeaderHeight
        let inset = BrowserChromeLayout.extensionSidePanelHeaderHorizontalPadding
        let iconSize = BrowserChromeLayout.extensionSidePanelHeaderIconSize
        icon.frame = NSRect(x: inset, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        let closeSize = BrowserChromeLayout.extensionSidePanelCloseButtonSize
        closeButton.frame = NSRect(
            x: max(bounds.width - inset - closeSize, 0),
            y: (height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        title.frame = NSRect(
            x: icon.frame.maxX + 8,
            y: (height - 16) / 2,
            width: max(closeButton.frame.minX - icon.frame.maxX - 16, 0),
            height: 16
        )
        viewport.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
        loading.frame = viewport.frame
    }

    func update(
        sidePanel: BrowserExtensionSidePanel,
        hostView: NSView,
        isContextReady: Bool,
        usesWindowContentInsets: Bool
    ) {
        viewport.update(hostView: hostView)
        let radius = usesWindowContentInsets ? BrowserChromeLayout.leadingContentCornerRadius : 0
        layer?.cornerRadius = radius
        viewport.updateClipping(
            cornerRadius: radius,
            maskedCorners: usesWindowContentInsets
                ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : []
        )
        loading.isHidden = isContextReady
        title.stringValue = sidePanel.title
        if let image = sidePanel.iconImage {
            icon.image = image
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(
                    pointSize: BrowserChromeLayout.extensionSidePanelHeaderIconSize,
                    weight: .medium
                ))
            icon.contentTintColor = BrowserChromeColors.primaryText
        }
    }

    // MARK: Private

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let loading = BrowserNativeSurface()
}
