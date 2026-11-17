// BrowserProtectedVideoPromptView.swift

import AppKit

/// Offers a Chromium page whose protected video Chromium refused in WebKit,
/// over the page's top right corner.
@MainActor @objc final class BrowserProtectedVideoPromptView: NSView {
    // MARK: Internal

    @objc static let width: CGFloat = 340
    @objc static let height: CGFloat = 112

    override var isFlipped: Bool { true }

    @objc var onOpenInWebKit: (() -> Void)?
    @objc var onStay: (() -> Void)?
    @objc var onNeverAsk: (() -> Void)?

    // MARK: Private

    private let panel = BrowserNativeMaterialPanel()
    private let title = BrowserNativeControls.label(
        "",
        size: 13,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
    )
    private let detail = BrowserNativeControls.label(
        "",
        size: 12,
        weight: .regular,
        color: BrowserChromeColors.secondaryText,
        wraps: true,
    )
    private var buttons = [BrowserActionButton]()

    @objc init(host: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        panel.cornerRadius = 12
        addSubview(panel)
        title.stringValue = BrowserStrings.protectedVideoPromptTitle
        detail.stringValue = String(format: BrowserStrings.protectedVideoPromptDetail, host)
        detail.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        self.buttons = [
            BrowserActionButton(BrowserStrings.protectedVideoPromptNever) { [weak self] in self?.onNeverAsk?() },
            BrowserActionButton(BrowserStrings.protectedVideoPromptStay) { [weak self] in self?.onStay?() },
            BrowserActionButton(BrowserStrings.protectedVideoPromptOpen) { [weak self] in self?.onOpenInWebKit?() },
        ]
        for view in [title, detail] + buttons {
            panel.contentView.addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrowserStrings.protectedVideoPromptTitle)
        setAccessibilityIdentifier("browser.protected-video-prompt")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let padding: CGFloat = 14
        title.frame = NSRect(x: padding, y: 12, width: bounds.width - padding * 2, height: 17)
        detail.frame = NSRect(x: padding, y: 31, width: bounds.width - padding * 2, height: 32)
        var x = bounds.width - padding
        for button in buttons.reversed() {
            let width = ceil(button.intrinsicContentSize.width) + 8
            x -= width
            button.frame = NSRect(x: x, y: bounds.height - 40, width: width, height: 28)
            x -= 6
        }
    }
}
