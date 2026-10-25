import AppKit

// MARK: - BrowserSadTabView

/// Page for a tab whose renderer crashed: "Tab crashed. Maybe reload
/// the page?" with "reload" as a link, and Chromium's error code below.
final class BrowserSadTabView: BrowserNativeSurface, NSTextViewDelegate {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = BrowserChromeColors.contentBackground
        strokeWidth = 0
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        icon.contentTintColor = BrowserChromeColors.secondaryText
        message.isEditable = false
        message.isSelectable = true
        message.drawsBackground = false
        message.textContainerInset = .zero
        message.textContainer?.lineFragmentPadding = 0
        message.delegate = self
        message.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        message.setAccessibilityIdentifier("browser.sad-tab.message")
        code.alignment = .center
        code.setAccessibilityIdentifier("browser.sad-tab.error-code")
        for view in [icon, message, code] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.sad-tab")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    /// The address of the message's "reload" link.
    static let reloadLink = URL(string: "openarc-sad-tab:reload")!

    override var isFlipped: Bool { true }

    var onReload: () -> Void = {}

    private(set) var errorCode = 0

    override func layout() {
        super.layout()
        let width = min(max(bounds.width - 48, 0), 360)
        message.frame.size.width = width
        message.layoutManager?.ensureLayout(for: message.textContainer!)
        let textHeight = message.layoutManager.map { manager in
            ceil(manager.usedRect(for: message.textContainer!).height)
        } ?? 17
        let codeHeight: CGFloat = code.isHidden ? 0 : 16
        let total = 32 + 12 + textHeight + (code.isHidden ? 0 : 6 + codeHeight)
        var y = (bounds.height - total) / 2
        icon.frame = NSRect(x: (bounds.width - 32) / 2, y: y, width: 32, height: 32)
        y += 32 + 12
        message.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: textHeight)
        y += textHeight + 6
        code.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: codeHeight)
    }

    func update(errorCode: Int) {
        self.errorCode = errorCode
        let link = BrowserStrings.sadTabReloadLink
        let text = String(format: BrowserStrings.sadTabMessage, link)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: BrowserChromeColors.primaryText,
            .paragraphStyle: paragraph,
        ])
        if let range = text.range(of: link) {
            attributed.addAttribute(.link, value: Self.reloadLink, range: NSRange(range, in: text))
        }
        message.textStorage?.setAttributedString(attributed)
        setAccessibilityLabel(text)
        code.stringValue = String(format: BrowserStrings.sadTabErrorCode, errorCode)
        code.isHidden = errorCode == 0
        needsLayout = true
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        guard (link as? URL) == Self.reloadLink else { return false }
        onReload()
        return true
    }

    // MARK: Private

    private let icon = NSImageView()
    private let message = NSTextView()
    private let code = BrowserNativeControls.label("", size: 11, color: BrowserChromeColors.secondaryText)
}
