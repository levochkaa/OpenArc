// BrowserFindBarNSView.swift

import AppKit

/// Owns find-panel layout and editing. Search state and engine commands remain in BrowserChromeModel.
final class BrowserFindBarNSView: NSView, NSTextFieldDelegate {
    // MARK: Internal

    override var isFlipped: Bool { true }

    let queryField = BrowserFindNSTextField()
    let previousButton = BrowserNativeChromeButton(
        symbol: "chevron.up",
        title: BrowserStrings.findBarPreviousMatch,
        pressEffect: .up,
        action: {},
    )
    let nextButton = BrowserNativeChromeButton(
        symbol: "chevron.down",
        title: BrowserStrings.findBarNextMatch,
        pressEffect: .down,
        action: {},
    )
    let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.findBarClose,
        pressEffect: .compress,
        action: {},
    )
    var onQueryChanged: (String) -> Void = { _ in }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onDismiss: () -> Void = {}

    // MARK: Private

    private let visibility = BrowserNativeVisibilityAnimation()
    private let panel = NSVisualEffectView()
    private let tint = BrowserNativeSurface()
    private let fieldBackground = BrowserNativeSurface()
    private let symbol = NSImageView()
    private var blockedLeadingInset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("browser.find.overlay")
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = BrowserChromeLayout.findBarCornerRadius
        panel.layer?.masksToBounds = true
        addSubview(panel)
        tint.fillColor = BrowserChromeColors.findBarPanelTint
        tint.strokeColor = BrowserChromeColors.findBarPanelBorder
        tint.cornerRadius = BrowserChromeLayout.findBarCornerRadius
        panel.addSubview(tint)
        fieldBackground.fillColor = BrowserChromeColors.findBarFieldTint
        fieldBackground.cornerRadius = BrowserChromeLayout.findBarFieldCornerRadius
        tint.addSubview(fieldBackground)
        symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: BrowserChromeLayout.findBarSymbolSize, weight: .semibold))
        symbol.contentTintColor = BrowserChromeColors.secondaryText
        symbol.setAccessibilityElement(false)
        tint.addSubview(symbol)
        queryField.delegate = self
        queryField.placeholderString = BrowserStrings.findBarPlaceholder
        queryField.setAccessibilityLabel(BrowserStrings.findBarPlaceholder)
        queryField.setAccessibilityIdentifier("browser.find.query")
        fieldBackground.addSubview(queryField)
        previousButton.onAction = { [weak self] in self?.onPrevious() }
        nextButton.onAction = { [weak self] in self?.onNext() }
        closeButton.onAction = { [weak self] in self?.onDismiss() }
        for button in [previousButton, nextButton, closeButton] {
            tint.addSubview(button)
        }
        previousButton.setAccessibilityIdentifier("browser.find.previous")
        nextButton.setAccessibilityIdentifier("browser.find.next")
        closeButton.setAccessibilityIdentifier("browser.find.close")
        queryField.nextKeyView = previousButton
        previousButton.nextKeyView = nextButton
        nextButton.nextKeyView = closeButton
        closeButton.nextKeyView = queryField
        panel.isHidden = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !panel.isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let available = max(bounds.width - max(blockedLeadingInset, 0) - BrowserChromeLayout.findBarTrailingInset, 0)
        let width = min(BrowserChromeLayout.findBarWidth, available)
        panel.frame = NSRect(
            x: bounds.width - BrowserChromeLayout.findBarTrailingInset - width,
            y: BrowserChromeLayout.findBarTopInset,
            width: width,
            height: BrowserChromeLayout.findBarHeight,
        )
        tint.frame = panel.bounds
        let spacing = BrowserChromeLayout.findBarContentSpacing
        let padding = BrowserChromeLayout.findBarHorizontalPadding
        let buttonSize = BrowserChromeLayout.chromeButtonSize
        let y = (panel.bounds.height - buttonSize) / 2
        let symbolWidth = BrowserChromeLayout.commandBarSymbolWidth
        let fieldWidth = min(
            BrowserChromeLayout.findBarFieldWidth,
            max(width - padding * 2 - symbolWidth - spacing * 4 - buttonSize * 3, 0),
        )
        let contentWidth = symbolWidth + fieldWidth + spacing * 4 + buttonSize * 3
        let startX = max((width - contentWidth) / 2, padding)
        symbol.frame = NSRect(x: startX, y: y, width: symbolWidth, height: buttonSize)
        let fieldX = symbol.frame.maxX + spacing
        fieldBackground.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: buttonSize)
        queryField.frame = NSRect(x: 8, y: 5, width: max(fieldWidth - 16, 0), height: 18)
        var x = fieldBackground.frame.maxX + spacing
        for button in [previousButton, nextButton, closeButton] {
            button.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize + spacing
        }
    }

    func update(query: String, isPresented: Bool, canStep: Bool, focusRequestID: Int, blockedLeadingInset: CGFloat) {
        self.blockedLeadingInset = blockedLeadingInset
        visibility.setVisible(isPresented, view: panel, curve: .easeOut(0.12))
        previousButton.isEnabled = canStep
        nextButton.isEnabled = canStep
        queryField.sync(text: query, shouldFocus: isPresented, focusRequestID: focusRequestID)
        needsLayout = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === queryField else { return }
        onQueryChanged(queryField.stringValue)
    }

    func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onNext()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss()
            return true
        case #selector(NSResponder.selectAll(_:)):
            textView.selectAll(nil)
            return true
        default: return false
        }
    }
}
