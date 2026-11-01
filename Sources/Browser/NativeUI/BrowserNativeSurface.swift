// BrowserNativeSurface.swift

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
    /// The top leading corner's radius while `roundsTopLeadingCorner` is off.
    var topLeadingCornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
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
            let leading = min(topLeadingCornerRadius, radius)
            path.move(to: NSPoint(x: rect.minX, y: rect.minY + leading))
            if leading > 0 {
                path.appendArc(
                    from: NSPoint(x: rect.minX, y: rect.minY),
                    to: NSPoint(x: rect.minX + leading, y: rect.minY),
                    radius: leading,
                )
            }
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(
                from: NSPoint(x: rect.maxX, y: rect.minY),
                to: NSPoint(x: rect.maxX, y: rect.maxY),
                radius: radius,
            )
            path.appendArc(
                from: NSPoint(x: rect.maxX, y: rect.maxY),
                to: NSPoint(x: rect.minX, y: rect.maxY),
                radius: radius,
            )
            path.appendArc(
                from: NSPoint(x: rect.minX, y: rect.maxY),
                to: NSPoint(x: rect.minX, y: rect.minY + leading),
                radius: radius,
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
        hoverBackground: BrowserChromeColors.rowHover,
    )
    static let sidebarNavigation = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarChromeButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarChromeButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarChromeSymbolSize,
        symbolWeight: .regular,
        foreground: BrowserChromeColors.sidebarChromeForeground,
        hoverBackground: BrowserChromeColors.sidebarChromeHover,
        pressedBackground: BrowserChromeColors.sidebarChromePressed,
        pressedForeground: BrowserChromeColors.sidebarChromePressedForeground,
        disabledForeground: BrowserChromeColors.sidebarChromeDisabledForeground,
        compressesBackground: false,
    )
    static let sidebarDockSpace = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarChromeButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarChromeButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarChromeSymbolSize,
        symbolWeight: .regular,
        foreground: BrowserChromeColors.sidebarDockForeground,
        hoverBackground: BrowserChromeColors.sidebarChromeHover,
        pressedBackground: BrowserChromeColors.sidebarChromePressed,
        pressedForeground: BrowserChromeColors.sidebarChromePressedForeground,
        compressesBackground: false,
    )
    static let sidebarDockAction = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarChromeButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarChromeButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarChromeSymbolSize,
        symbolWeight: .regular,
        foreground: BrowserChromeColors.sidebarChromeForeground,
        hoverBackground: BrowserChromeColors.sidebarChromeHover,
        pressedBackground: BrowserChromeColors.sidebarChromePressed,
        pressedForeground: BrowserChromeColors.sidebarChromePressedForeground,
        compressesBackground: false,
        usesDrawnGlyphs: true,
    )
    static let bookmark = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.bookmarksBarControlSize,
        cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius,
        symbolSize: BrowserChromeLayout.bookmarksBarIconSize,
        symbolWeight: .semibold,
        foreground: BrowserChromeColors.secondaryText,
        hoverBackground: BrowserChromeColors.rowHover,
    )
    static let currentURL = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarCurrentURLButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCurrentURLButtonSymbolSize,
        symbolWeight: .regular,
        foreground: BrowserChromeColors.sidebarChromeForeground,
        hoverBackground: BrowserChromeColors.currentURLButtonHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale,
    )
    static let sidebarClose = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarCloseButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCloseSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.rowCloseForeground,
        hoverBackground: BrowserChromeColors.rowCloseHover,
        pressedBackground: BrowserChromeColors.sidebarChromePressed,
        pressedForeground: BrowserChromeColors.sidebarChromePressedForeground,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale,
        usesDrawnGlyphs: true,
        drawsCloseBars: true,
    )
    static let miniPlayer = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarMiniPlayerButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: 13,
        symbolWeight: .semibold,
        foreground: BrowserChromeColors.primaryText,
        hoverBackground: BrowserChromeColors.rowHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale,
    )
    static let extensionClose = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.extensionSidePanelCloseButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarCloseSymbolSize,
        symbolWeight: .bold,
        foreground: BrowserChromeColors.rowCloseForeground,
        hoverBackground: BrowserChromeColors.rowCloseHover,
        pressedScale: BrowserChromeLayout.sidebarCloseButtonPressedScale,
    )

    let size: CGFloat
    let cornerRadius: CGFloat
    let symbolSize: CGFloat
    let symbolWeight: NSFont.Weight
    let foreground: NSColor
    let hoverBackground: NSColor
    var pressedBackground: NSColor?
    var pressedForeground: NSColor?
    var disabledForeground: NSColor?
    var pressedScale: CGFloat = 1
    var compressesBackground = true
    /// Plus and cross as 2 pt bars rather than symbols.
    var usesDrawnGlyphs = false
    /// Draws its cross and minus as two bars that turn into each other.
    var drawsCloseBars = false
}

// MARK: - BrowserNativeBarGlyph

/// Plus and cross drawn from two 14 x 2 pt rounded bars.
enum BrowserNativeBarGlyph {
    /// A Space without its own icon shows as a dot in the dock.
    static let spaceDot = "space.dot"

    static func image(symbol: String, rotation extra: CGFloat = 0) -> NSImage? {
        if symbol == spaceDot {
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            image.isTemplate = true
            return image
        }
        let rotation: CGFloat
        switch symbol {
        case "plus": rotation = extra
        case "xmark": rotation = 45
        default: return nil
        }
        let side: CGFloat = 14
        let thickness: CGFloat = 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: rotation)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            NSColor.black.setFill()
            let bar = NSRect(x: 0, y: (side - thickness) / 2, width: side, height: thickness)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            let post = NSRect(x: (side - thickness) / 2, y: 0, width: thickness, height: side)
            NSBezierPath(roundedRect: post, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - BrowserNativeChromeButton

/// Native target/action button with the same geometry and press treatment as browser chrome.
final class BrowserNativeChromeButton: NSButton {
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

    // MARK: Private

    private let closeBars = [CALayer(), CALayer()]
    /// The angle of the close bars: 45° is a cross, 0° a minus.
    private var closeBarsAngle = CGFloat.pi / 4
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

    private var drawsCloseBarsNow: Bool {
        style.drawsCloseBars && ["xmark", "minus"].contains(symbolName)
    }

    init(
        symbol: String,
        title: String,
        style: BrowserNativeChromeButtonStyle = .chrome,
        pressEffect: PressEffect = .none,
        action: @escaping () -> Void,
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
        image = Self.image(symbol: symbol, title: title, style: style)
        self.tooltipTitle = title
        setAccessibilityLabel(title)
        target = self
        self.action = #selector(activate)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
            owner: self,
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
                placement: tooltipPlacement,
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
            let hoverAlpha = style.hoverBackground.alphaComponent
            let pressedAlpha = style.pressedBackground?.alphaComponent ?? hoverAlpha
            style.hoverBackground
                .withAlphaComponent(
                    (hoverAlpha + (pressedAlpha - hoverAlpha) * progress) * hoverProgress,
                )
                .setFill()
            let backgroundCompression = !style.compressesBackground
                ? 0
                : style.pressedScale == 1 ? 0.05 : 1 - style.pressedScale
            let rect = bounds.insetBy(
                dx: bounds.width * backgroundCompression / 2 * progress,
                dy: bounds.height * backgroundCompression / 2 * progress,
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: style.cornerRadius,
                yRadius: style.cornerRadius,
            ).fill()
        }
        let foreground = isSelected ? BrowserChromeColors.primaryText : style.foreground
        contentTintColor = !isEnabled
            ? style.disabledForeground ?? BrowserChromeColors.buttonDisabledForeground
            : foreground.blended(
                withFraction: min(max(progress, 0), 1),
                of: style.pressedForeground ?? BrowserChromeColors.chromeButtonPressedForeground,
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
        syncCloseBars()
        if !drawsCloseBarsNow {
            cell?.drawInterior(withFrame: bounds, in: self)
        }
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
    }

    private static func image(symbol: String, title: String, style: BrowserNativeChromeButtonStyle) -> NSImage? {
        if let glyph = BrowserNativeBarGlyph.image(symbol: symbol),
           style.usesDrawnGlyphs || symbol == BrowserNativeBarGlyph.spaceDot
        {
            return glyph
        }
        return BrowserIconImage.image(
            named: symbol,
            pointSize: style.symbolSize,
            weight: style.symbolWeight,
            description: title,
        )
    }

    /// Turns a drawn plus by some degrees.
    func setBarGlyphRotation(_ degrees: CGFloat) {
        image = BrowserNativeBarGlyph.image(symbol: symbolName, rotation: degrees)
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
        if changed {
            updateCloseBars(animated: window != nil)
        }
        self.title = title
        image = Self.image(symbol: name, title: title, style: style)
        imagePosition = .imageOnly
        setAccessibilityLabel(title)
        tooltipTitle = title
    }

    /// Keeps the bars on the button's layer, so they turn smoothly even while the main
    /// thread is busy switching tabs.
    private func syncCloseBars() {
        guard style.drawsCloseBars else { return }
        wantsLayer = true
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in closeBars.enumerated() {
            if bar.superlayer == nil {
                bar.cornerRadius = 1
                bar.bounds = CGRect(x: 0, y: 0, width: 14, height: 2)
                bar.setValue(index == 0 ? closeBarsAngle : -closeBarsAngle, forKeyPath: "transform.rotation.z")
                layer.addSublayer(bar)
            }
            bar.position = CGPoint(x: bounds.midX, y: bounds.midY)
            bar.isHidden = !drawsCloseBarsNow
            bar.backgroundColor = (contentTintColor ?? style.foreground).cgColor
            bar.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }

    private func updateCloseBars(animated: Bool) {
        guard style.drawsCloseBars, ["xmark", "minus"].contains(symbolName) else { return }
        syncCloseBars()
        let target = symbolName == "minus" ? 0 : CGFloat.pi / 4
        closeBarsAngle = target
        let moves = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, bar) in closeBars.enumerated() {
            let angle = index == 0 ? target : -target
            if moves {
                let spring = CASpringAnimation(keyPath: "transform.rotation.z")
                spring.mass = 1
                spring.stiffness = 438.649
                spring.damping = 25.1327
                spring.fromValue = bar.presentation()?.value(forKeyPath: "transform.rotation.z")
                spring.toValue = angle
                spring.duration = spring.settlingDuration
                bar.add(spring, forKey: "turn")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.setValue(angle, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
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
                    from: nil,
                ))
            }
        }
    }
}
