// BrowserAreaCaptureOverlay.swift

import AppKit

// MARK: - BrowserAreaCaptureOverlay

/// Capture…: the page turns gray and the user drags out the part to capture,
/// or clicks the element under the pointer, which shows in color in a dark
/// frame. Escape, a click with no element under it or a click beside the page
/// cancels. The result is the part as fractions of the page frame, y downward.
final class BrowserAreaCaptureOverlay: NSView {
    // MARK: Internal

    /// Smaller drags count as a click.
    static let minimumSize: CGFloat = 4
    static let elementFrameWidth: CGFloat = 4

    // MARK: Private

    private static let frameColor = NSColor(srgbRed: 22 / 255, green: 28 / 255, blue: 47 / 255, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A drag outlines; it never moves the window, even under the title bar.
    override var mouseDownCanMoveWindow: Bool { false }

    let pageFrame: CGRect
    private(set) var selection: CGRect?
    /// The element under the pointer, in view coordinates.
    private(set) var hoveredElement: CGRect?
    var onFinish: (CGRect?) -> Void = { _ in }
    /// The pointer rests at this point of the page, as fractions; the owner
    /// answers with `showHoveredElement(fraction:)`.
    var onHover: (CGPoint) -> Void = { _ in }

    /// The page as it looks now, filling the page frame: gray around the
    /// outline and in color inside it.
    var pagePicture: CGImage? {
        didSet {
            backdrop = pagePicture.flatMap(BrowserCaptureImaging.backdrop)
            needsDisplay = true
        }
    }

    private var start: CGPoint?
    private var backdrop: CGImage?
    private var tracking: NSTrackingArea?
    private let hint = BrowserAreaCaptureHint()

    init(pageFrame: CGRect) {
        self.pageFrame = pageFrame
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrowserStrings.captureAreaAccessibilityLabel)
        setAccessibilityIdentifier("browser.capture-area")
        addSubview(hint)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A drag in a window behind others still outlines, from its first press.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = hint.preferredSize
        hint.frame = CGRect(
            x: pageFrame.midX - size.width / 2,
            y: pageFrame.maxY - 36 - size.height,
            width: size.width,
            height: size.height,
        )
    }

    override func draw(_: NSRect) {
        let highlight = selection ?? hoveredElement
        if let backdrop, let pagePicture {
            NSGraphicsContext.current?.cgContext.saveGState()
            drawImage(backdrop, in: pageFrame)
            if let highlight {
                drawImage(pagePicture, in: pageFrame, clippedTo: highlight)
            }
            NSGraphicsContext.current?.cgContext.restoreGState()
        } else {
            let dim = NSBezierPath(rect: pageFrame)
            if let highlight {
                dim.append(NSBezierPath(rect: highlight))
                dim.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(1 - BrowserCaptureImaging.backdropBrightness).setFill()
            dim.fill()
        }
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        } else if let hoveredElement {
            drawElementFrame(around: hoveredElement)
        }
    }

    override func resetCursorRects() {
        addCursorRect(pageFrame, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard start == nil, pageFrame.contains(point) else {
            showHoveredElement(fraction: nil)
            return
        }
        onHover(fractionPoint(point))
    }

    override func mouseExited(with _: NSEvent) {
        showHoveredElement(fraction: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard pageFrame.contains(point) else {
            onFinish(nil)
            return
        }
        start = point
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        selection = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y),
        )
        hint.isHidden = true
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        finish()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_: Any?) {
        onFinish(nil)
    }

    func showHoveredElement(fraction: CGRect?) {
        guard start == nil else { return }
        let rect = fraction.map {
            CGRect(
                x: pageFrame.minX + $0.minX * pageFrame.width,
                y: pageFrame.minY + $0.minY * pageFrame.height,
                width: $0.width * pageFrame.width,
                height: $0.height * pageFrame.height,
            ).intersection(pageFrame)
        }
        let element = rect.flatMap { $0.width >= Self.minimumSize && $0.height >= Self.minimumSize ? $0 : nil }
        guard element != hoveredElement else { return }
        hoveredElement = element
        needsDisplay = true
    }

    /// The outline as fractions of the page frame.
    func fraction(for rect: CGRect) -> CGRect {
        guard pageFrame.width > 0, pageFrame.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - pageFrame.minX) / pageFrame.width,
            y: (rect.minY - pageFrame.minY) / pageFrame.height,
            width: rect.width / pageFrame.width,
            height: rect.height / pageFrame.height,
        )
    }

    /// A drag captures its outline; a click captures the element under it.
    func finish() {
        let pressed = start
        start = nil
        if let selection, selection.width >= Self.minimumSize, selection.height >= Self.minimumSize {
            onFinish(fraction(for: selection))
        } else if pressed != nil, let hoveredElement {
            onFinish(fraction(for: hoveredElement))
        } else {
            onFinish(nil)
        }
    }

    private func fractionPoint(_ point: CGPoint) -> CGPoint {
        guard pageFrame.width > 0, pageFrame.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - pageFrame.minX) / pageFrame.width,
            y: (point.y - pageFrame.minY) / pageFrame.height,
        )
    }

    /// Draws a picture that fills `frame`, the right way up in this flipped view.
    private func drawImage(_ image: CGImage, in frame: CGRect, clippedTo clip: CGRect? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if let clip {
            context.clip(to: clip)
        }
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }

    /// The hovered element's dark frame, with a camera on its leading edge.
    private func drawElementFrame(around rect: CGRect) {
        let width = Self.elementFrameWidth
        let outer = NSBezierPath(
            roundedRect: rect.insetBy(dx: -width, dy: -width),
            xRadius: width + 2,
            yRadius: width + 2,
        )
        outer.append(NSBezierPath(rect: rect))
        outer.windingRule = .evenOdd
        Self.frameColor.setFill()
        outer.fill()
        let badge = CGRect(
            x: rect.minX - width - 10,
            y: rect.minY + min(rect.height / 2, 40) - 10,
            width: 20,
            height: 20,
        )
        Self.frameColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let rim = NSBezierPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        rim.lineWidth = 1
        rim.stroke()
        if let camera = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.white])))
        {
            let size = camera.size
            camera.draw(in: CGRect(
                x: badge.midX - size.width / 2,
                y: badge.midY - size.height / 2,
                width: size.width,
                height: size.height,
            ))
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, pageFrame.minX), pageFrame.maxX),
            y: min(max(point.y, pageFrame.minY), pageFrame.maxY),
        )
    }
}

// MARK: - BrowserAreaCaptureHint

/// "Click or drag to capture a portion of this page" at the page's bottom.
private final class BrowserAreaCaptureHint: BrowserNativeSurface {
    // MARK: Private

    private let label = NSTextField(labelWithString: BrowserStrings.captureAreaHint)

    // MARK: Internal

    var preferredSize: CGSize {
        CGSize(width: ceil(label.intrinsicContentSize.width) + 52, height: 66)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = .white
        strokeColor = NSColor(srgbRed: 0.8, green: 0.78, blue: 0.9, alpha: 1)
        strokeWidth = 1
        cornerRadius = 14
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor(srgbRed: 93 / 255, green: 55 / 255, blue: 169 / 255, alpha: 1)
        label.alignment = .center
        addSubview(label)
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: 0.45, green: 0.35, blue: 0.75, alpha: 0.45)
            shadow.shadowBlurRadius = 40
            return shadow
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label.stringValue)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20)
    }
}
