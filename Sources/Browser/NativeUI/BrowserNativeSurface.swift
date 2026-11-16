// BrowserNativeSurface.swift

import AppKit
import QuartzCore

// MARK: - CGRect + insetClamped

extension CGRect {
    /// `insetBy` for subview frames: a rect smaller than its insets, such as a
    /// view's bounds before its first layout, collapses to an empty rect at its
    /// center. `insetBy` returns `CGRect.null` there, whose infinite origin
    /// Auto Layout rejects with "exceeds internal limits".
    func insetClamped(dx: CGFloat, dy: CGFloat) -> CGRect {
        let width = max(size.width - 2 * dx, 0)
        let height = max(size.height - 2 * dy, 0)
        return CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
    }
}

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
    static let findBar = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.findBarButtonSize,
        cornerRadius: BrowserChromeLayout.findBarCornerRadius,
        symbolSize: BrowserChromeLayout.findBarButtonSymbolSize,
        symbolWeight: .heavy,
        foreground: BrowserChromeColors.findBarControl,
        hoverBackground: BrowserChromeColors.findBarControlHover,
        disabledForeground: BrowserChromeColors.findBarControlDisabled,
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
    )
    static let sidebarDockSpace = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarChromeButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarChromeButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarChromeSymbolSize,
        symbolWeight: .regular,
        foreground: BrowserChromeColors.sidebarDockForeground,
        hoverBackground: BrowserChromeColors.sidebarChromeHover,
        pressedForeground: BrowserChromeColors.sidebarChromePressedForeground,
        pressedScale: 0.95,
        hoverCurve: .standard,
        pressCurve: .dockPress,
    )
    static let sidebarDockAction = BrowserNativeChromeButtonStyle(
        size: BrowserChromeLayout.sidebarChromeButtonSize,
        cornerRadius: BrowserChromeLayout.sidebarChromeButtonCornerRadius,
        symbolSize: BrowserChromeLayout.sidebarChromeSymbolSize,
        symbolWeight: .regular,
        foreground: BrowserChromeColors.sidebarChromeForeground,
        hoverBackground: BrowserChromeColors.sidebarChromeHover,
        pressedForeground: BrowserChromeColors.sidebarChromePressedForeground,
        pressedScale: 0.95,
        usesDrawnGlyphs: true,
        hoverCurve: .standard,
        pressCurve: .dockPress,
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
        symbolWeight: .semibold,
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
    /// Close beside the small window bar's field: a filled square.
    static let commandBarClose = BrowserNativeChromeButtonStyle(
        size: 24,
        cornerRadius: 6,
        symbolSize: 11,
        symbolWeight: .semibold,
        foreground: NSColor.labelColor.withAlphaComponent(0.6),
        hoverBackground: NSColor.labelColor.withAlphaComponent(0.06),
        restingBackground: NSColor.labelColor.withAlphaComponent(0.085),
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
    /// A fill shown without hover, under the hover one.
    var restingBackground: NSColor?
    var pressedForeground: NSColor?
    var disabledForeground: NSColor?
    var pressedScale: CGFloat = 1
    var compressesBackground = true
    /// Plus and cross as 2 pt bars rather than symbols.
    var usesDrawnGlyphs = false
    /// Draws its cross and minus as two bars that turn into each other.
    var drawsCloseBars = false
    var hoverCurve = BrowserNativeAnimation.Curve.hover
    var pressCurve = BrowserNativeAnimation.Curve.press
}

// MARK: - BrowserNativeBarGlyph

/// Plus and cross drawn from two 14 x 2 pt rounded bars.
enum BrowserNativeBarGlyph {
    /// A Space without its own icon shows as a dot in the dock.
    static let spaceDot = "space.dot"
    /// Site controls: two sliders in a rounded square, with round caps and
    /// ring knobs.
    static let siteControls = "openarc.site-controls"

    /// Site controls for a symbol of `pointSize`, a little taller than the
    /// symbol's square so it reads at the same weight as the link beside it.
    static func siteControlsImage(pointSize: CGFloat) -> NSImage {
        let side = (pointSize * 16 / 14).rounded()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let unit = rect.width / 16
            let line = 1.5 * unit
            NSColor.black.setStroke()
            let frame = NSBezierPath(
                roundedRect: rect.insetBy(dx: line / 2, dy: line / 2),
                xRadius: 4.6 * unit,
                yRadius: 4.6 * unit,
            )
            frame.lineWidth = line
            frame.stroke()
            let sliders: [(y: CGFloat, knob: CGFloat)] = [(10.5, 9.8), (5.5, 6.2)]
            for slider in sliders {
                let y = slider.y * unit
                let bar = NSBezierPath()
                bar.move(to: NSPoint(x: 4.2 * unit, y: y))
                bar.line(to: NSPoint(x: 11.8 * unit, y: y))
                bar.lineWidth = line
                bar.lineCapStyle = .round
                bar.stroke()
                let knob = NSRect(
                    x: slider.knob * unit - 1.6 * unit,
                    y: y - 1.6 * unit,
                    width: 3.2 * unit,
                    height: 3.2 * unit,
                )
                // The bar stops at the ring, which stays hollow.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: knob.insetBy(dx: -line / 2, dy: -line / 2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                let ring = NSBezierPath(ovalIn: knob)
                ring.lineWidth = line
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

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

// MARK: - BrowserNativeChromeButtonCell

/// A button's tracking loop highlights the cell without telling the button.
private final class BrowserNativeChromeButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? BrowserNativeChromeButton)?.cellDidChangeHighlight()
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

    override class var cellClass: AnyClass? {
        get { BrowserNativeChromeButtonCell.self }
        set {}
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

    /// Called when a press ends, after its tracking loop.
    var onRelease: (() -> Void)?

    var onAction: () -> Void
    var pressEffect: PressEffect
    var tooltipTitle: String?
    var tooltipShortcut: BrowserKeyboardShortcut?
    /// A right click that shows something other than a menu.
    var onSecondaryClick: (() -> Void)?
    /// A press held past half a second, instead of the action.
    var onLongPress: (() -> Void)?
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

    private var didLongPress = false

    // MARK: Private

    private let closeBars = [CALayer(), CALayer()]
    /// The angle of the close bars: 45° is a cross, 0° a minus.
    private var closeBarsAngle = CGFloat.pi / 4
    private var oldSymbol: NSBitmapImageRep?
    private var restingSymbol: NSBitmapImageRep?
    private var pressedSymbol: NSBitmapImageRep?
    private var symbolName: String
    /// The symbol image `configureSymbol` set last and the title it was made for.
    private var symbolImage: (image: NSImage, title: String)?
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
            hoverAnimation.start(style.hoverCurve) { [weak self] progress in
                self?.hoverProgress = from + (to - from) * progress
                self?.needsDisplay = true
            }
        }
    }

    /// Reload and Stop dissolve into each other in place.
    private var symbolCrossfades: Bool { ["xmark", "arrow.clockwise"].contains(symbolName) }

    private var restingTint: NSColor {
        isSelected ? BrowserChromeColors.primaryText : style.foreground
    }

    private var pressedTint: NSColor {
        style.pressedForeground ?? BrowserChromeColors.chromeButtonPressedForeground
    }

    /// The check replaces the link quickly, slowing down. The link's return is gentler.
    private var symbolOutProgress: CGFloat {
        if symbolCrossfades {
            return symbolProgress
        }
        if symbolName == "checkmark" {
            let linear = min(symbolProgress / 0.25, 1)
            return 1 - pow(1 - linear, 2)
        }
        let linear = min(symbolProgress / 0.4, 1)
        return linear * linear * (3 - 2 * linear)
    }

    /// The new symbol arrives after a pause, slowing into place. The link is back sooner.
    private var symbolInProgress: CGFloat {
        if symbolCrossfades {
            return symbolProgress
        }
        let start = symbolName == "checkmark" ? 0.45 : 0.11
        let linear = min(max((symbolProgress - start) / (1 - start), 0), 1)
        return 1 - pow(1 - linear, 3)
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
        self.symbolImage = image.map { ($0, title) }
        self.tooltipTitle = title
        setAccessibilityLabel(title)
        target = self
        self.action = #selector(activate)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        didLongPress = false
        var hold: DispatchWorkItem?
        if onLongPress != nil {
            let work = DispatchWorkItem { [weak self] in
                self?.didLongPress = true
                self?.onLongPress?()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            hold = work
        }
        super.mouseDown(with: event)
        hold?.cancel()
        onRelease?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else {
            super.rightMouseDown(with: event)
            return
        }
        if isEnabled {
            onSecondaryClick()
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
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if hovered {
            // A new area does not know the pointer is inside and would never report it leaving.
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        // An area replaced while the pointer crosses it reports nothing.
        if hovered, let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            endHover()
        }
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

    override func mouseExited(with _: NSEvent) { endHover() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let progress = isEnabled ? pressProgress : 0
        if let resting = style.restingBackground {
            resting.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: style.cornerRadius, yRadius: style.cornerRadius).fill()
        }
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
        let foreground = restingTint
        contentTintColor = !isEnabled
            ? style.disabledForeground ?? BrowserChromeColors.buttonDisabledForeground
            : foreground.blended(
                withFraction: min(max(progress, 0), 1),
                of: style.pressedForeground ?? BrowserChromeColors.chromeButtonPressedForeground,
            ) ?? foreground
        if let oldSymbol, symbolProgress < 1 {
            NSGraphicsContext.saveGraphicsState()
            let oldTransform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
            var transform = oldTransform
            transform.scale(symbolCrossfades ? 1 : 1 - 0.8 * symbolOutProgress)
            transform.translate(x: -bounds.midX, y: -bounds.midY)
            (transform as NSAffineTransform).concat()
            draw(snapshot: oldSymbol, alpha: 1 - symbolOutProgress)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        var effect = transform
        let rowScale = 1 - (1 - style.pressedScale) * progress
        effect.scale(rowScale * (symbolCrossfades ? 1 : 0.2 + 0.8 * symbolInProgress))
        switch pressEffect {
        case .up: effect.translate(x: 0, y: 2 * progress)
        case .down: effect.translate(x: 0, y: -2 * progress)
        case .left: effect.translate(x: -2 * progress, y: 0)
        case .right: effect.translate(x: 2 * progress, y: 0)
        case .rotateClockwise: effect.rotate(byDegrees: 90 * progress)
        case .compress: effect.scale(1 - (style.pressedScale == 1 ? 0.1 : 0) * progress)
        case .none: break
        }
        effect.translate(x: -bounds.midX, y: -bounds.midY)
        (effect as NSAffineTransform).concat()
        syncCloseBars()
        if !drawsCloseBarsNow {
            let alpha = symbolCrossfades ? symbolProgress : min(symbolInProgress * 2, 1)
            if progress != 0 || symbolProgress < 1, let restingSymbol {
                draw(snapshot: restingSymbol, alpha: alpha)
                if let pressedSymbol {
                    draw(snapshot: pressedSymbol, alpha: alpha * progress)
                }
            } else {
                cell?.drawInterior(withFrame: bounds, in: self)
            }
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
        if symbol == BrowserNativeBarGlyph.siteControls {
            return BrowserNativeBarGlyph.siteControlsImage(pointSize: style.symbolSize)
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
        restingSymbol = nil
        pressedSymbol = nil
        image = BrowserNativeBarGlyph.image(symbol: symbolName, rotation: degrees)
    }

    func configureSymbol(_ name: String, title: String) {
        let changed = symbolName != name
        // Sidebar refreshes reconfigure every row; making a symbol image is slow.
        if !changed, let symbolImage, symbolImage.title == title, image === symbolImage.image { return }
        symbolName = name
        let dissolves = changed && !style.drawsCloseBars && symbolCrossfades
        if changed, window != nil, dissolves || ["link", "checkmark"].contains(name) {
            oldSymbol = snapshotOfSymbol(tint: restingTint)
            symbolProgress = 0
            let curve: BrowserNativeAnimation.Curve = dissolves
                ? .reloadDissolve
                : name == "checkmark" ? .copy : .copyReset
            symbolAnimation.start(curve) { [weak self] progress in
                self?.symbolProgress = progress
                self?.needsDisplay = true
            } completion: { [weak self] in self?.oldSymbol = nil }
        }
        if changed {
            updateCloseBars(animated: window != nil)
        }
        self.title = title
        image = Self.image(symbol: name, title: title, style: style)
        symbolImage = image.map { ($0, title) }
        imagePosition = .imageOnly
        setAccessibilityLabel(title)
        tooltipTitle = title
        if changed {
            pressedSymbol = nil
            restingSymbol = symbolProgress < 1 ? snapshotOfSymbol(tint: restingTint) : nil
        }
    }

    fileprivate func cellDidChangeHighlight() { updatePressAnimation() }

    private func endHover() {
        hovered = false
        BrowserNativeTooltipPresenter.shared.end(id: tooltipID)
        needsDisplay = true
    }

    /// AppKit places a symbol differently once the context is scaled, so a symbol in
    /// motion draws this picture of itself at rest.
    private func snapshotOfSymbol(tint: NSColor) -> NSBitmapImageRep? {
        guard window != nil, let cell, let picture = bitmapImageRepForCachingDisplay(in: bounds),
              let context = NSGraphicsContext(bitmapImageRep: picture)?.cgContext
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        contentTintColor = tint
        cell.drawInterior(withFrame: bounds, in: self)
        return picture
    }

    private func draw(snapshot: NSBitmapImageRep, alpha: CGFloat) {
        guard alpha > 0 else { return }
        snapshot.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: alpha,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)],
        )
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
        if target {
            restingSymbol = snapshotOfSymbol(tint: restingTint)
            pressedSymbol = snapshotOfSymbol(tint: pressedTint)
        }
        let from = pressProgress
        let to = target ? 1.0 : 0.0
        pressAnimation.start(style.pressCurve) { [weak self] progress in
            self?.pressProgress = from + (to - from) * progress
            self?.needsDisplay = true
        }
    }

    @objc private func activate() {
        if isEnabled {
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
            // NSMenu runs a nested tracking loop; release before entering it.
            highlight(false)
            if !didLongPress {
                onAction()
            }
            if let window {
                hovered = visibleRect.contains(convert(
                    window.convertPoint(fromScreen: NSEvent.mouseLocation),
                    from: nil,
                ))
            }
        }
    }
}
