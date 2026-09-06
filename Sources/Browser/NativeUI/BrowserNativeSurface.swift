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
    var strokeWidth: CGFloat = 1 { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
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
    static let sidebarClose = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarCloseButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCloseSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.rowCloseForeground,
        hoverBackground: BrowserChromeColors.rowCloseHover
    )
    static let extensionClose = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.extensionSidePanelCloseButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCloseSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.rowCloseForeground,
        hoverBackground: BrowserChromeColors.rowCloseHover
    )

    let size: CGFloat
    let cornerRadius: CGFloat
    let symbolSize: CGFloat
    let symbolWeight: NSFont.Weight
    let foreground: NSColor
    let hoverBackground: NSColor
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
        self.style = style
        self.pressEffect = pressEffect
        self.onAction = action
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: style.symbolSize, weight: style.symbolWeight))
        toolTip = title
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

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    var onAction: () -> Void

    var isSelected = false { didSet { needsDisplay = true } }

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
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) { hovered = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let pressed = isEnabled && isHighlighted
        if hovered && isEnabled {
            style.hoverBackground.setFill()
            let rect = pressed ? bounds.insetBy(dx: bounds.width * 0.025, dy: bounds.height * 0.025) : bounds
            NSBezierPath(
                roundedRect: rect,
                xRadius: style.cornerRadius,
                yRadius: style.cornerRadius
            ).fill()
        }
        contentTintColor = !isEnabled
            ? BrowserChromeColors.buttonDisabledForeground
            : pressed
                ? BrowserChromeColors.chromeButtonPressedForeground
                : isSelected ? BrowserChromeColors.primaryText : style.foreground
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        var effect = transform
        if pressed {
            switch pressEffect {
            case .up: effect.translate(x: 0, y: 2)
            case .down: effect.translate(x: 0, y: -2)
            case .left: effect.translate(x: -2, y: 0)
            case .right: effect.translate(x: 2, y: 0)
            case .rotateClockwise: effect.rotate(byDegrees: -90)
            case .compress: effect.scale(0.9)
            case .none: break
            }
        }
        effect.translate(x: -bounds.midX, y: -bounds.midY)
        (effect as NSAffineTransform).concat()
        cell?.drawInterior(withFrame: bounds, in: self)
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
    }

    // MARK: Private

    private let style: BrowserNativeChromeButtonStyle
    private let pressEffect: PressEffect
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?

    @objc private func activate() {
        if isEnabled {
            onAction()
        }
    }
}
