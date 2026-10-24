import AppKit

// MARK: - BrowserSitePermissionPromptView

/// A page's permission request over the top of its page: the origin, what it
/// asks for, and Block or Allow.
final class BrowserSitePermissionPromptView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(panel)
        panel.cornerRadius = 12
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityIdentifier("browser.site-permission.title")
        close.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: BrowserStrings.sitePermissionDismiss
        )?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        close.isBordered = false
        close.contentTintColor = BrowserChromeColors.secondaryText
        close.toolTip = BrowserStrings.sitePermissionDismiss
        close.setAccessibilityIdentifier("browser.site-permission.dismiss")
        block.setAccessibilityIdentifier("browser.site-permission.block")
        allow.setAccessibilityIdentifier("browser.site-permission.allow")
        for view in [title, close, block, allow] as [NSView] {
            panel.contentView.addSubview(view)
        }
        panel.contentView.addSubview(rows)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.site-permission")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    static let width: CGFloat = 320

    override var isFlipped: Bool { true }

    private(set) var request: BrowserSitePermissionRequest?
    var onAnswer: (Int, Bool) -> Void = { _, _ in }
    var onDismiss: (Int) -> Void = { _ in }

    /// The height the request needs at `width`.
    var fittingHeight: CGFloat {
        Self.padding * 2 + 20 + 12 + CGFloat(rows.arrangedSubviews.count) * 24 + 12 + 30
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        panel.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let padding = Self.padding
        let width = bounds.width - padding * 2
        close.frame = NSRect(x: bounds.width - padding - 16, y: padding + 2, width: 16, height: 16)
        title.frame = NSRect(x: padding, y: padding, width: max(close.frame.minX - 8 - padding, 0), height: 20)
        let rowsHeight = CGFloat(rows.arrangedSubviews.count) * 24 - 8
        rows.frame = NSRect(x: padding, y: title.frame.maxY + 12, width: width, height: max(rowsHeight, 0))
        let buttonY = rows.frame.maxY + 20
        let allowWidth = max(allow.intrinsicContentSize.width, 72)
        let blockWidth = max(block.intrinsicContentSize.width, 72)
        allow.frame = NSRect(x: bounds.width - padding - allowWidth, y: buttonY, width: allowWidth, height: 30)
        block.frame = NSRect(x: allow.frame.minX - 8 - blockWidth, y: buttonY, width: blockWidth, height: 30)
    }

    func update(request: BrowserSitePermissionRequest) {
        guard request != self.request else { return }
        self.request = request
        title.stringValue = BrowserStrings.sitePermissionPromptTitle(request.displayOrigin)
        setAccessibilityLabel(title.stringValue)
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for kind in request.kinds {
            let icon = NSImageView(image: NSImage(
                systemSymbolName: kind.systemImageName,
                accessibilityDescription: nil
            ) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            icon.contentTintColor = BrowserChromeColors.primaryText
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let label = BrowserNativeControls.label(kind.title, size: 13, color: BrowserChromeColors.primaryText)
            label.lineBreakMode = .byTruncatingTail
            let row = BrowserNativeControls.stack([icon, label], orientation: .horizontal, spacing: 8)
            row.heightAnchor.constraint(equalToConstant: 16).isActive = true
            row.setAccessibilityIdentifier("browser.site-permission.kind.\(kind.rawValue)")
            rows.addArrangedSubview(row)
        }
        needsLayout = true
    }

    // MARK: Private

    private static let padding: CGFloat = 16

    private let panel = BrowserNativeMaterialPanel()
    private let title = BrowserNativeControls.label(
        "",
        size: 13,
        weight: .semibold,
        color: BrowserChromeColors.primaryText
    )
    private let rows = NSStackView()
    private lazy var close = BrowserActionButton("") { [weak self] in
        guard let id = self?.request?.id else { return }
        self?.onDismiss(id)
    }

    private lazy var block = BrowserActionButton(BrowserStrings.sitePermissionBlock) { [weak self] in
        guard let id = self?.request?.id else { return }
        self?.onAnswer(id, false)
    }

    private lazy var allow = BrowserActionButton(BrowserStrings.sitePermissionAllow) { [weak self] in
        guard let id = self?.request?.id else { return }
        self?.onAnswer(id, true)
    }
}
