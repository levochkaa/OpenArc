// BrowserFindBarNSView.swift

import AppKit

/// Owns find-panel layout and editing. Search state and engine commands remain in BrowserChromeModel.
/// The bar is one flat surface: a magnifier and the query, then the match count
/// or "Not Found", the step buttons and Close behind a divider.
final class BrowserFindBarNSView: NSView, NSTextFieldDelegate {
    // MARK: Internal

    /// What the bar says about the matches of the current query.
    enum Result: Equatable {
        case none
        case matches(active: Int?, count: Int)
        case notFound
    }

    override var isFlipped: Bool { true }

    let queryField = BrowserFindNSTextField()
    let previousButton = BrowserNativeChromeButton(
        symbol: "arrow.up",
        title: BrowserStrings.findBarPreviousMatch,
        style: .findBar,
        pressEffect: .up,
        action: {},
    )
    let nextButton = BrowserNativeChromeButton(
        symbol: "arrow.down",
        title: BrowserStrings.findBarNextMatch,
        style: .findBar,
        pressEffect: .down,
        action: {},
    )
    let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.findBarClose,
        style: .findBar,
        pressEffect: .compress,
        action: {},
    )
    let countLabel = NSTextField(labelWithString: "")
    let notFoundLabel = NSTextField(labelWithString: BrowserStrings.findBarNotFound.localizedUppercase)
    let divider = BrowserNativeSurface()
    var onQueryChanged: (String) -> Void = { _ in }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onDismiss: () -> Void = {}

    // MARK: Private

    private let panel = BrowserNativeSurface()
    private let symbol = NSImageView()
    private var blockedLeadingInset: CGFloat = 0
    private var result = Result.none

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("browser.find.overlay")
        panel.fillColor = BrowserChromeColors.findBarFill
        panel.cornerRadius = BrowserChromeLayout.findBarCornerRadius
        panel.strokeWidth = 0
        panel.wantsLayer = true
        panel.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
        addSubview(panel)
        symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: BrowserChromeLayout.findBarSymbolSize, weight: .medium))
        symbol.contentTintColor = BrowserChromeColors.findBarSymbol
        symbol.setAccessibilityElement(false)
        panel.addSubview(symbol)
        queryField.delegate = self
        queryField.placeholderAttributedString = NSAttributedString(
            string: BrowserStrings.findBarPlaceholder,
            attributes: [
                .font: BrowserFindNSTextField.textFont,
                .foregroundColor: BrowserChromeColors.findBarPlaceholder,
            ],
        )
        queryField.setAccessibilityLabel(BrowserStrings.findBarPlaceholder)
        queryField.setAccessibilityIdentifier("browser.find.query")
        panel.addSubview(queryField)
        countLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        countLabel.textColor = BrowserChromeColors.findBarControl
        countLabel.alignment = .right
        countLabel.setAccessibilityIdentifier("browser.find.count")
        notFoundLabel.font = .systemFont(ofSize: 10, weight: .bold)
        notFoundLabel.textColor = BrowserChromeColors.findBarNotFound
        notFoundLabel.alignment = .right
        notFoundLabel.setAccessibilityIdentifier("browser.find.not_found")
        divider.fillColor = BrowserChromeColors.findBarDivider
        divider.strokeWidth = 0
        for view in [countLabel, notFoundLabel, divider] as [NSView] {
            panel.addSubview(view)
        }
        previousButton.onAction = { [weak self] in self?.onPrevious() }
        nextButton.onAction = { [weak self] in self?.onNext() }
        closeButton.onAction = { [weak self] in self?.onDismiss() }
        for button in [previousButton, nextButton, closeButton] {
            panel.addSubview(button)
        }
        previousButton.setAccessibilityIdentifier("browser.find.previous")
        nextButton.setAccessibilityIdentifier("browser.find.next")
        closeButton.setAccessibilityIdentifier("browser.find.close")
        queryField.nextKeyView = previousButton
        previousButton.nextKeyView = nextButton
        nextButton.nextKeyView = closeButton
        closeButton.nextKeyView = queryField
        panel.isHidden = true
        applyResult()
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
        let height = BrowserChromeLayout.findBarHeight
        panel.frame = NSRect(
            x: bounds.width - BrowserChromeLayout.findBarTrailingInset - width,
            y: BrowserChromeLayout.findBarTopInset,
            width: width,
            height: height,
        )

        let buttonSize = BrowserChromeLayout.findBarButtonSize
        func button(_ button: NSView, centeredAt inset: CGFloat) {
            button.frame = NSRect(
                x: width - inset - buttonSize / 2,
                y: (height - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize,
            )
        }
        button(closeButton, centeredAt: BrowserChromeLayout.findBarCloseCenterInset)
        button(nextButton, centeredAt: BrowserChromeLayout.findBarNextCenterInset)
        button(previousButton, centeredAt: BrowserChromeLayout.findBarPreviousCenterInset)
        let dividerHeight = BrowserChromeLayout.findBarDividerHeight
        let dividerX = width - BrowserChromeLayout.findBarDividerInset
        divider.frame = NSRect(x: dividerX, y: (height - dividerHeight) / 2, width: 1, height: dividerHeight)

        let labelHeight: CGFloat = 16
        let arrowGlyphHalfWidth: CGFloat = 5.25
        let countMaxX = width - BrowserChromeLayout.findBarPreviousCenterInset - arrowGlyphHalfWidth
            - BrowserChromeLayout.findBarCountGap
        let countWidth = ceil(countLabel.attributedStringValue.size().width) + 4
        countLabel.frame = NSRect(
            x: countMaxX - countWidth + 3.5,
            y: (height - labelHeight) / 2 + 1.5,
            width: countWidth,
            height: labelHeight,
        )
        // The label's cell draws its bold capitals 3.5 pt inside its frame.
        let notFoundMaxX = dividerX - BrowserChromeLayout.findBarNotFoundGap + 3.5
        let notFoundWidth = ceil(notFoundLabel.attributedStringValue.size().width) + 4
        notFoundLabel.frame = NSRect(
            x: notFoundMaxX - notFoundWidth,
            y: (height - 13) / 2 + 0.5,
            width: notFoundWidth,
            height: 13,
        )

        let symbolSize: CGFloat = 16
        symbol.frame = NSRect(
            x: BrowserChromeLayout.findBarSymbolLeading - 1.25,
            y: (height - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize,
        )
        let queryTrailing =
            switch result {
            case .matches: countLabel.frame.minX - 8
            case .notFound: notFoundLabel.frame.minX - 8
            case .none: (divider.isHidden ? closeButton.frame.minX : dividerX) - 8
            }
        // The cell draws its text 2 pt inside its frame.
        let queryX = BrowserChromeLayout.findBarTextLeading - 2
        queryField.frame = NSRect(x: queryX, y: (height - 18) / 2, width: max(queryTrailing - queryX, 0), height: 18)
    }

    func update(
        query: String,
        isPresented: Bool,
        canStep: Bool,
        result: Result,
        focusRequestID: Int,
        blockedLeadingInset: CGFloat,
    ) {
        self.blockedLeadingInset = blockedLeadingInset
        panel.isHidden = !isPresented
        previousButton.isEnabled = canStep
        nextButton.isEnabled = canStep
        divider.isHidden = query.isEmpty
        if self.result != result {
            self.result = result
            applyResult()
        }
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
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious()
            } else {
                onNext()
            }
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

    private func applyResult() {
        switch result {
        case .none:
            countLabel.isHidden = true
            notFoundLabel.isHidden = true
            previousButton.isHidden = true
            nextButton.isHidden = true
        case .matches(let active, let count):
            countLabel.stringValue = active.map { "\($0)/\(count)" } ?? "\(count)"
            countLabel.isHidden = false
            notFoundLabel.isHidden = true
            previousButton.isHidden = false
            nextButton.isHidden = false
        case .notFound:
            countLabel.isHidden = true
            notFoundLabel.isHidden = false
            previousButton.isHidden = true
            nextButton.isHidden = true
        }
        needsLayout = true
    }
}
