// BrowserNativeUpdateToastView.swift

import AppKit

final class BrowserNativeUpdateToastView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onInstall: () -> Void = {}
    var onDismiss: () -> Void = {}

    // MARK: Private

    private let material = NSVisualEffectView()
    private let outline = BrowserNativeSurface()
    private let icon = NSImageView()
    private let title = BrowserNativeControls.label("", size: 12, weight: .semibold)
    private let message = BrowserNativeControls.label("", size: 11, color: .secondaryLabelColor, wraps: true)
    private let install = BrowserNativePressableView()
    private let actionTitle = BrowserNativeControls.label("", size: 11, weight: .semibold)
    private let close = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.updateDismissAction,
        style: .sidebarClose,
        pressEffect: .compress,
        action: {},
    )

    private var actionWidth: CGFloat { ceil(actionTitle.intrinsicContentSize.width) + 16 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .active
        addSubview(material)
        outline.cornerRadius = 8
        outline.strokeColor = NSColor.labelColor.withAlphaComponent(0.08)
        addSubview(outline)
        for subview in [icon, title, message, install, close] {
            outline.addSubview(subview)
        }
        icon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: 12,
                weight: .semibold,
            ))
        icon.contentTintColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        install.addSubview(actionTitle)
        install.cornerRadius = 6
        install.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
        install.onClick = { [weak self] _ in self?.onInstall() }
        close.onAction = { [weak self] in self?.onDismiss() }
        close.tooltipTitle = nil
        setAccessibilityIdentifier("browser.update.toast")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        install.setAccessibilityIdentifier("browser.update.install")
        close.setAccessibilityIdentifier("browser.update.dismiss")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        material.frame = bounds
        outline.frame = bounds
        icon.frame = NSRect(x: 10, y: (bounds.height - 18) / 2, width: 18, height: 18)
        close.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 20) / 2, width: 20, height: 20)
        install.frame = NSRect(
            x: close.frame.minX - 8 - actionWidth,
            y: (bounds.height - 26) / 2,
            width: actionWidth,
            height: 26,
        )
        actionTitle.frame = NSRect(x: 8, y: 5, width: max(actionWidth - 16, 0), height: 16)
        let textWidth = max(install.frame.minX - 8 - 36, 0)
        title.frame = NSRect(x: 36, y: 9, width: textWidth, height: 16)
        message.frame = NSRect(x: 36, y: 27, width: textWidth, height: max(bounds.height - 36, 0))
    }

    func update(_ toast: BrowserUpdateToast) {
        title.stringValue = toast.title
        message.stringValue = toast.message
        actionTitle.stringValue = toast.actionTitle
        install.setAccessibilityLabel(toast.actionTitle)
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        let textWidth = max(width - 20 - 18 - 20 - actionWidth - 8 * 4, 1)
        let measured = (message.stringValue as NSString)
            .boundingRect(
                with: NSSize(width: max(textWidth - 4, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: message.font!],
            )
            .height
        return max(16 + 2 + min(ceil(measured) + 2, 30), 26) + 18
    }
}
