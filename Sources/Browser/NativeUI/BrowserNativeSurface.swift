import AppKit
import QuartzCore

// MARK: - BrowserNativeSurface

/// Shared AppKit surface. Dynamic colors are resolved again when the window appearance changes.
// swiftformat:disable:next preferFinalClasses
class BrowserNativeSurface: NSView {
    override var isFlipped: Bool { true }

    var fillColor = NSColor.clear { didSet { needsDisplay = true } }
    var strokeColor = NSColor.clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var roundsTopLeadingCorner = true { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 1 { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let path: NSBezierPath
        if roundsTopLeadingCorner || cornerRadius <= 0 {
            path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        } else {
            let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
            path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(
                from: NSPoint(x: rect.maxX, y: rect.minY),
                to: NSPoint(x: rect.maxX, y: rect.maxY),
                radius: radius
            )
            path.appendArc(
                from: NSPoint(x: rect.maxX, y: rect.maxY),
                to: NSPoint(x: rect.minX, y: rect.maxY),
                radius: radius
            )
            path.appendArc(
                from: NSPoint(x: rect.minX, y: rect.maxY),
                to: NSPoint(x: rect.minX, y: rect.minY),
                radius: radius
            )
            path.close()
        }
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}

// MARK: - BrowserNativeChromeButtonStyle

struct BrowserNativeChromeButtonStyle {
    static let chrome = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.chromeButtonSize,
        cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
        symbolSize: BrowserChromeLayout.chromeButtonSymbolSize,
        symbolWeight: .semibold,
        foreground: BrowserChromeColors.secondaryText,
        hoverBackground: BrowserChromeColors.rowHover
    )
    static let bookmark = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.bookmarksBarControlSize,
        cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius,
        symbolSize: BrowserChromeLayout.bookmarksBarIconSize,
        symbolWeight: .semibold,
        foreground: BrowserChromeColors.secondaryText,
        hoverBackground: BrowserChromeColors.rowHover
    )
    static let currentURL = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarCurrentURLButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCurrentURLButtonSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.currentURLText,
        hoverBackground: BrowserChromeColors.currentURLButtonHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale
    )
    static let sidebarClose = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarCloseButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCloseSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.rowCloseForeground,
        hoverBackground: BrowserChromeColors.rowCloseHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale
    )
    static let miniPlayer = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarMiniPlayerButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: 13,
        symbolWeight: .semibold,
        foreground: BrowserChromeColors.primaryText,
        hoverBackground: BrowserChromeColors.rowHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale
    )
    static let extensionClose = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.extensionSidePanelCloseButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCloseSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.rowCloseForeground,
        hoverBackground: BrowserChromeColors.rowCloseHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale
    )

    let size: CGFloat
    let cornerRadius: CGFloat
    let symbolSize: CGFloat
    let symbolWeight: NSFont.Weight
    let foreground: NSColor
    let hoverBackground: NSColor
    var pressedScale: CGFloat = 1
}

// MARK: - BrowserNativeChromeButton

/// Native target/action button with the same geometry and press treatment as browser chrome.
final class BrowserNativeChromeButton: NSButton {
    // MARK: Lifecycle

    init(
        symbol: String,
        title: String,
        style: BrowserNativeChromeButtonStyle = .chrome,
        pressEffect: PressEffect = .none,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbol
        self.style = style
        self.pressEffect = pressEffect
        self.onAction = action
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryChange)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: style.symbolSize, weight: style.symbolWeight))
        self.tooltipTitle = title
        setAccessibilityLabel(title)
        target = self
        self.action = #selector(activate)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    enum PressEffect { case none, up, down, left, right, compress, rotateClockwise }

    override var intrinsicContentSize: NSSize {
        NSSize(width: style.size, height: style.size)
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                hovered = false
                highlight(false)
                BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
            }
        }
    }

    override var isEnabled: Bool { didSet {
        if !isEnabled {
            highlight(false)
        }
        needsDisplay = true
    } }
    override var isHighlighted: Bool { didSet { updatePressAnimation() } }

    var onAction: () -> Void
    var pressEffect: PressEffect
    var tooltipTitle: String?
    var tooltipShortcut: BrowserKeyboardShortcut?
    var tooltipPlacement = BrowserTooltipPlacement.belowLeading

    var isSelected = false { didSet { needsDisplay = true } }
    /// A drag rests on the button, as on a Space's dock icon; it shows the
    /// hover background, since a drag sends no mouse-entered events.
    var isDropTarget = false {
        didSet {
            if oldValue != isDropTarget {
                hovered = isDropTarget
            }
        }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updatePressAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hovered = false
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with _: NSEvent) { hovered = true
        if let tooltipTitle {
            BrowserNativeTooltipPresenter.shared.begin(
                id: tooltipID,
                anchor: self,
                title: tooltipTitle,
                shortcut: tooltipShortcut,
                placement: tooltipPlacement
            )
        }
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) { hovered = false
        BrowserNativeTooltipPresenter.shared.end(id: tooltipID)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let progress = isEnabled ? pressProgress : 0
        if hoverProgress > 0 && isEnabled {
            style.hoverBackground.withAlphaComponent(style.hoverBackground.alphaComponent * hoverProgress).setFill()
            let backgroundCompression = style.pressedScale == 1 ? 0.05 : 1 - style.pressedScale
            let rect = bounds.insetBy(
                dx: bounds.width * backgroundCompression / 2 * progress,
                dy: bounds.height * backgroundCompression / 2 * progress
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: style.cornerRadius,
                yRadius: style.cornerRadius
            ).fill()
        }
        let foreground = isSelected ? BrowserChromeColors.primaryText : style.foreground
        contentTintColor = !isEnabled
            ? BrowserChromeColors.buttonDisabledForeground
            : foreground.blended(
                withFraction: min(max(progress, 0), 1),
                of: BrowserChromeColors.chromeButtonPressedForeground
            ) ?? foreground
        if let oldSymbolCell, symbolProgress < 1 {
            NSGraphicsContext.saveGraphicsState()
            let oldTransform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
            var transform = oldTransform
            transform.scale(1 - 0.42 * symbolProgress)
            transform.translate(x: -bounds.midX, y: -bounds.midY)
            (transform as NSAffineTransform).concat()
            NSGraphicsContext.current?.cgContext.setAlpha(max(1 - symbolProgress, 0))
            oldSymbolCell.drawInterior(withFrame: bounds, in: self)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        var effect = transform
        let rowScale = 1 - (1 - style.pressedScale) * progress
        effect.scale(rowScale * (0.58 + 0.42 * symbolProgress))
        switch pressEffect {
        case .up: effect.translate(x: 0, y: 2 * progress)
        case .down: effect.translate(x: 0, y: -2 * progress)
        case .left: effect.translate(x: -2 * progress, y: 0)
        case .right: effect.translate(x: 2 * progress, y: 0)
        case .rotateClockwise: effect.rotate(byDegrees: -90 * progress)
        case .compress: effect.scale(1 - (style.pressedScale == 1 ? 0.1 : 0) * progress)
        case .none: break
        }
        effect.translate(x: -bounds.midX, y: -bounds.midY)
        (effect as NSAffineTransform).concat()
        NSGraphicsContext.current?.cgContext.setAlpha(min(max(symbolProgress, 0), 1))
        cell?.drawInterior(withFrame: bounds, in: self)
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
    }

    func configureSymbol(_ name: String, title: String) {
        let changed = symbolName != name
        symbolName = name
        if changed, window != nil, ["link", "checkmark"].contains(name) {
            oldSymbolCell = cell?.copy() as? NSCell
            symbolProgress = 0
            symbolAnimation.start(.copy) { [weak self] progress in
                self?.symbolProgress = progress
                self?.needsDisplay = true
            } completion: { [weak self] in self?.oldSymbolCell = nil }
        }
        self.title = title
        image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: style.symbolSize, weight: style.symbolWeight))
        imagePosition = .imageOnly
        setAccessibilityLabel(title)
        tooltipTitle = title
    }

    // MARK: Private

    private var oldSymbolCell: NSCell?
    private var symbolName: String
    private var symbolProgress = 1.0
    private let symbolAnimation = BrowserNativeAnimation()
    private let style: BrowserNativeChromeButtonStyle
    private let tooltipID = UUID()
    private let pressAnimation = BrowserNativeAnimation()
    private let hoverAnimation = BrowserNativeAnimation()
    private var pressProgress = 0.0
    private var hoverProgress = 0.0
    private var pressTarget = false

    private var hoverTrackingArea: NSTrackingArea?

    private var hovered = false {
        didSet {
            guard oldValue != hovered else { return }
            let from = hoverProgress
            let to = hovered ? 1.0 : 0.0
            hoverAnimation.start(.hover) { [weak self] progress in
                self?.hoverProgress = from + (to - from) * progress
                self?.needsDisplay = true
            }
        }
    }

    private func updatePressAnimation() {
        let target = isEnabled && isHighlighted
        guard target != pressTarget else { return }
        pressTarget = target
        let from = pressProgress
        let to = target ? 1.0 : 0.0
        pressAnimation.start(.press) { [weak self] progress in
            self?.pressProgress = from + (to - from) * progress
            self?.needsDisplay = true
        }
    }

    @objc private func activate() {
        if isEnabled {
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
            // NSMenu runs a nested tracking loop; release before entering it.
            highlight(false)
            onAction()
            if let window {
                hovered = visibleRect.contains(convert(
                    window.convertPoint(fromScreen: NSEvent.mouseLocation),
                    from: nil
                ))
            }
        }
    }
}
