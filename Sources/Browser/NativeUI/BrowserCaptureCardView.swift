// BrowserCaptureCardView.swift

import AppKit

// MARK: - BrowserCaptureCardAction

/// What the capture card's Send To menu does with the picture.
enum BrowserCaptureCardAction: Equatable, CaseIterable {
    case toggleLibrary
    case copy
    case save
    case sendMessage
    case edit
    case retake
    case newEasel
}

// MARK: - BrowserCaptureCardMenu

/// The Send To menu's rows, its filter and the keyboard selection.
struct BrowserCaptureCardMenu: Equatable {
    enum Entry: Equatable {
        case item(BrowserCaptureCardAction)
        case divider
    }

    static let layout: [Entry] = [
        .item(.toggleLibrary), .item(.copy), .item(.save), .item(.sendMessage), .divider,
        .item(.edit), .item(.retake), .divider,
        .item(.newEasel),
    ]

    var isSavedToLibrary = false
    var canSaveToLibrary = true
    var canCreateEasel = false

    private(set) var filter = ""
    private(set) var selection: BrowserCaptureCardAction?

    /// The rows shown: all of them, or the ones whose title holds the typed text.
    var entries: [Entry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Self.layout }
        return Self.layout.filter {
            guard case .item(let action) = $0 else { return false }
            return title(for: action).lowercased().contains(query)
        }
    }

    var enabledActions: [BrowserCaptureCardAction] {
        entries.compactMap {
            guard case .item(let action) = $0, isEnabled(action) else { return nil }
            return action
        }
    }

    func title(for action: BrowserCaptureCardAction) -> String {
        switch action {
        case .toggleLibrary: isSavedToLibrary
            ? BrowserStrings.captureCardSavedToLibrary
            : BrowserStrings.captureCardSaveToLibrary
        case .copy: BrowserStrings.captureCardCopy
        case .save: BrowserStrings.captureCardSave
        case .sendMessage: BrowserStrings.captureCardSendMessage
        case .edit: BrowserStrings.captureCardEdit
        case .retake: BrowserStrings.captureCardRetake
        case .newEasel: BrowserStrings.captureCardNewEasel
        }
    }

    func symbol(for action: BrowserCaptureCardAction) -> String {
        switch action {
        case .toggleLibrary: isSavedToLibrary ? "checkmark.circle.fill" : "circle"
        case .copy: "doc.on.doc.fill"
        case .save: "square.and.arrow.down.fill"
        case .sendMessage: "message.fill"
        case .edit: "pencil.circle"
        case .retake: "arrow.counterclockwise"
        case .newEasel: "plus"
        }
    }

    func isEnabled(_ action: BrowserCaptureCardAction) -> Bool {
        switch action {
        case .toggleLibrary: canSaveToLibrary
        case .newEasel: canCreateEasel
        default: true
        }
    }

    /// Typing keeps the first match selected.
    mutating func setFilter(_ text: String) {
        filter = text
        let actions = enabledActions
        if let selection, actions.contains(selection) {
            return
        }
        selection = text.isEmpty ? nil : actions.first
    }

    mutating func select(_ action: BrowserCaptureCardAction?) {
        guard let action else {
            selection = nil
            return
        }
        if enabledActions.contains(action) {
            selection = action
        }
    }

    /// Arrow keys walk the enabled rows and stop at the ends.
    mutating func moveSelection(by delta: Int) {
        let actions = enabledActions
        guard !actions.isEmpty else {
            selection = nil
            return
        }
        guard let selection, let index = actions.firstIndex(of: selection) else {
            selection = delta > 0 ? actions.first : actions.last
            return
        }
        self.selection = actions[min(max(index + delta, 0), actions.count - 1)]
    }
}

// MARK: - BrowserCaptureCardView

/// After a capture: the page turns gray behind the captured picture, which
/// sits in a dark frame with the Send To menu beside it. Escape or a click on
/// the gray page closes it.
final class BrowserCaptureCardView: NSView, NSTextFieldDelegate {
    // MARK: Internal

    static let menuWidth: CGFloat = 273
    static let frameWidth: CGFloat = 4
    static let gap: CGFloat = 10
    static let rowHeight: CGFloat = 32
    static let rowStride: CGFloat = 40

    // MARK: Private

    private static let menuColor = NSColor(srgbRed: 18 / 255, green: 15 / 255, blue: 44 / 255, alpha: 1)
    private static let frameColor = NSColor(srgbRed: 22 / 255, green: 28 / 255, blue: 47 / 255, alpha: 1)
    private static let fieldColor = NSColor(srgbRed: 35 / 255, green: 32 / 255, blue: 59 / 255, alpha: 1)
    private static let dividerColor = NSColor(srgbRed: 34 / 255, green: 32 / 255, blue: 59 / 255, alpha: 1)
    private static let selectionColor = NSColor(srgbRed: 49 / 255, green: 57 / 255, blue: 251 / 255, alpha: 1)
    private static let textColor = NSColor(srgbRed: 232 / 255, green: 231 / 255, blue: 234 / 255, alpha: 1)
    private static let placeholderColor = NSColor(srgbRed: 156 / 255, green: 154 / 255, blue: 167 / 255, alpha: 1)
    private static let iconColor = NSColor(srgbRed: 88 / 255, green: 86 / 255, blue: 106 / 255, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    let pageFrame: CGRect
    private(set) var pictureFrame: CGRect
    private(set) var sendToMenu: BrowserCaptureCardMenu {
        didSet {
            guard sendToMenu != oldValue else { return }
            if sendToMenu.entries != oldValue.entries || sendToMenu.isSavedToLibrary != oldValue.isSavedToLibrary
                || sendToMenu.canCreateEasel != oldValue.canCreateEasel
            {
                rebuildRows()
            } else {
                updateRowSelection()
            }
        }
    }

    var onAction: (BrowserCaptureCardAction) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    private let backdropView = NSImageView()
    private let frameView = BrowserNativeSurface()
    private let pictureView = NSImageView()
    private let menuPanel = BrowserCaptureCardMenuPanel()
    private let fieldBackground = BrowserNativeSurface()
    private let field = NSTextField()
    private var rowViews = [BrowserCaptureCardRow]()
    private var dividers = [BrowserNativeSurface]()

    var picture: NSImage? { pictureView.image }

    init(picture: NSImage, pictureFrame: CGRect, pageFrame: CGRect, backdrop: NSImage?, menu: BrowserCaptureCardMenu) {
        self.pictureFrame = pictureFrame
        self.pageFrame = pageFrame
        self.sendToMenu = menu
        super.init(frame: .zero)
        wantsLayer = true
        backdropView.image = backdrop
        backdropView.imageScaling = .scaleAxesIndependently
        backdropView.wantsLayer = true
        backdropView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(1 - BrowserCaptureImaging.backdropBrightness)
            .cgColor
        addSubview(backdropView)

        frameView.fillColor = Self.frameColor
        frameView.strokeWidth = 0
        frameView.cornerRadius = 5
        frameView.shadow = Self.shadow()
        addSubview(frameView)
        pictureView.image = picture
        pictureView.imageScaling = .scaleProportionallyUpOrDown
        pictureView.wantsLayer = true
        pictureView.layer?.cornerRadius = 2
        pictureView.layer?.masksToBounds = true
        frameView.addSubview(pictureView)

        menuPanel.fillColor = Self.menuColor
        menuPanel.strokeWidth = 0
        menuPanel.cornerRadius = 6
        menuPanel.shadow = Self.shadow()
        menuPanel.setAccessibilityElement(true)
        menuPanel.setAccessibilityRole(.menu)
        menuPanel.setAccessibilityLabel(BrowserStrings.captureCardSendTo)
        addSubview(menuPanel)
        fieldBackground.fillColor = Self.fieldColor
        fieldBackground.strokeWidth = 0
        fieldBackground.cornerRadius = 6
        menuPanel.addSubview(fieldBackground)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = Self.textColor
        field.placeholderAttributedString = NSAttributedString(
            string: BrowserStrings.captureCardSendTo,
            attributes: [.foregroundColor: Self.placeholderColor, .font: NSFont.systemFont(ofSize: 14)],
        )
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityIdentifier("browser.capture-card.field")
        fieldBackground.addSubview(field)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrowserStrings.captureCardAccessibilityLabel)
        setAccessibilityIdentifier("browser.capture-card")
        rebuildRows()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        backdropView.frame = pageFrame
        frameView.frame = pictureFrame.insetBy(dx: -Self.frameWidth, dy: -Self.frameWidth)
        pictureView.frame = CGRect(
            x: Self.frameWidth,
            y: Self.frameWidth,
            width: pictureFrame.width,
            height: pictureFrame.height,
        )
        let height = Self.menuHeight(for: sendToMenu)
        menuPanel.frame = Self.menuFrame(besidePictureFrame: pictureFrame, height: height, page: pageFrame)
        fieldBackground.frame = CGRect(x: 10.5, y: 13, width: Self.menuWidth - 21, height: 30)
        field.frame = CGRect(x: 8.5, y: 6, width: fieldBackground.frame.width - 17, height: 18)
        var y: CGFloat = 54
        var rowIndex = 0
        var dividerIndex = 0
        for entry in sendToMenu.entries {
            switch entry {
            case .item:
                guard rowIndex < rowViews.count else { break }
                rowViews[rowIndex].frame = CGRect(x: 10.5, y: y, width: Self.menuWidth - 21, height: Self.rowHeight)
                rowIndex += 1
                y += Self.rowStride
            case .divider:
                guard dividerIndex < dividers.count else { break }
                dividers[dividerIndex].frame = CGRect(x: 10.5, y: y, width: Self.menuWidth - 21, height: 1)
                dividerIndex += 1
                y += 8
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusField()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if menuPanel.frame.contains(point) || frameView.frame.contains(point) {
            return
        }
        onDismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_: Any?) {
        onDismiss()
    }

    /// Where the menu goes: beside the frame on the trailing side, or the
    /// leading side when the page has no room there, top-aligned and kept on the page.
    static func menuFrame(besidePictureFrame frame: CGRect, height: CGFloat, page: CGRect) -> CGRect {
        let outer = frame.insetBy(dx: -frameWidth, dy: -frameWidth)
        var x = outer.maxX + gap
        if x + menuWidth > page.maxX - gap, outer.minX - gap - menuWidth >= page.minX + gap {
            x = outer.minX - gap - menuWidth
        }
        x = min(max(x, page.minX + gap), page.maxX - gap - menuWidth)
        let y = min(max(outer.minY, page.minY + gap), page.maxY - gap - height)
        return CGRect(x: x, y: y, width: menuWidth, height: height)
    }

    /// A picture with no place on the page, such as an image from the page's
    /// menu: centered together with the menu, a little above the middle.
    static func centeredPictureFrame(size: CGSize, page: CGRect, windowTop: CGFloat) -> CGRect {
        let total = size.width + frameWidth * 2 + gap + menuWidth
        let x = page.midX - total / 2 + frameWidth
        let y = (windowTop + page.maxY) / 2 - size.height / 2
        return CGRect(x: x, y: max(y, page.minY + gap + frameWidth), width: size.width, height: size.height)
    }

    /// The picture for a capture as large as `pixelSize`, kept off the page's edges.
    static func pictureSize(pixelSize: CGSize, page: CGRect) -> CGSize {
        BrowserCaptureImaging.fittedSize(
            pixelSize: pixelSize,
            in: CGSize(
                width: max(page.width - menuWidth - gap * 3 - frameWidth * 2, 80),
                height: max(page.height * 0.8, 80),
            ),
        )
    }

    static func menuHeight(for menu: BrowserCaptureCardMenu) -> CGFloat {
        var y: CGFloat = 54
        let entries = menu.entries
        guard !entries.isEmpty else { return y }
        for entry in entries {
            switch entry {
            case .item: y += rowStride
            case .divider: y += 8
            }
        }
        return y - (rowStride - rowHeight) + 11
    }

    private static func shadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        return shadow
    }

    func setSavedToLibrary(_ saved: Bool) {
        sendToMenu.isSavedToLibrary = saved
    }

    func replacePicture(_ image: NSImage) {
        pictureView.image = image
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_: Notification) {
        sendToMenu.setFilter(field.stringValue)
        needsLayout = true
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            sendToMenu.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            sendToMenu.moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let selection = sendToMenu.selection {
                onAction(selection)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss()
            return true
        default:
            return false
        }
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        dividers.forEach { $0.removeFromSuperview() }
        rowViews = []
        dividers = []
        for entry in sendToMenu.entries {
            switch entry {
            case .item(let action):
                let row = BrowserCaptureCardRow(action: action)
                row.configure(
                    title: sendToMenu.title(for: action),
                    symbol: sendToMenu.symbol(for: action),
                    enabled: sendToMenu.isEnabled(action),
                    textColor: Self.textColor,
                    iconColor: Self.iconColor,
                )
                row.onHover = { [weak self] in self?.sendToMenu.select(action) }
                row.onClick = { [weak self] in
                    guard let self, sendToMenu.isEnabled(action) else { return }
                    onAction(action)
                }
                menuPanel.addSubview(row)
                rowViews.append(row)
            case .divider:
                let divider = BrowserNativeSurface()
                divider.strokeWidth = 0
                divider.fillColor = Self.dividerColor
                menuPanel.addSubview(divider)
                dividers.append(divider)
            }
        }
        updateRowSelection()
        needsLayout = true
    }

    private func updateRowSelection() {
        for row in rowViews {
            row.setSelected(row.action == sendToMenu.selection, fill: Self.selectionColor)
        }
    }
}

// MARK: - BrowserCaptureCardMenuPanel

/// Takes clicks between its rows so they never reach the gray page.
private final class BrowserCaptureCardMenuPanel: BrowserNativeSurface {
    override func mouseDown(with _: NSEvent) {}
}

// MARK: - BrowserCaptureCardRow

private final class BrowserCaptureCardRow: BrowserNativeSurface {
    // MARK: Internal

    let action: BrowserCaptureCardAction
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}

    // MARK: Private

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var isEnabled = true
    private var isSelected = false
    private var textColor = NSColor.white
    private var iconColor = NSColor.gray

    init(action: BrowserCaptureCardAction) {
        self.action = action
        super.init(frame: .zero)
        strokeWidth = 0
        cornerRadius = 6
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 7, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(x: 32.5, y: (bounds.height - 18) / 2, width: bounds.width - 40, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        if isEnabled { onHover() }
    }

    override func mouseDown(with _: NSEvent) {}
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick()
        return true
    }

    func configure(title: String, symbol: String, enabled: Bool, textColor: NSColor, iconColor: NSColor) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        isEnabled = enabled
        self.textColor = textColor
        self.iconColor = iconColor
        alphaValue = enabled ? 1 : 0.35
        setAccessibilityLabel(title)
        setAccessibilityEnabled(enabled)
        applyColors()
    }

    func setSelected(_ selected: Bool, fill: NSColor) {
        isSelected = selected
        fillColor = selected ? fill : .clear
        setAccessibilitySelected(selected)
        applyColors()
    }

    private func applyColors() {
        label.textColor = textColor
        icon.contentTintColor = isSelected ? NSColor.white.withAlphaComponent(0.6) : iconColor
    }
}
