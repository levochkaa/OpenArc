import AppKit

// MARK: - BrowserAreaCaptureOverlay

/// Capture…: the page dims and the user drags out the part to copy.
/// Escape, a click without a drag or a click beside the page cancels. The
/// result is the outlined part as fractions of the page frame, y downward.
final class BrowserAreaCaptureOverlay: NSView {
    // MARK: Lifecycle

    init(pageFrame: CGRect) {
        self.pageFrame = pageFrame
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrowserStrings.captureAreaAccessibilityLabel)
        setAccessibilityIdentifier("browser.capture-area")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    /// Smaller drags count as a click.
    static let minimumSize: CGFloat = 4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    let pageFrame: CGRect
    private(set) var selection: CGRect?
    var onFinish: (CGRect?) -> Void = { _ in }

    override func draw(_: NSRect) {
        let dim = NSBezierPath(rect: pageFrame)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.28).setFill()
        dim.fill()
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(pageFrame, cursor: .crosshair)
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
            height: abs(point.y - start.y)
        )
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

    /// The outline as fractions of the page frame.
    func fraction(for rect: CGRect) -> CGRect {
        guard pageFrame.width > 0, pageFrame.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - pageFrame.minX) / pageFrame.width,
            y: (rect.minY - pageFrame.minY) / pageFrame.height,
            width: rect.width / pageFrame.width,
            height: rect.height / pageFrame.height
        )
    }

    func finish() {
        guard let selection, selection.width >= Self.minimumSize, selection.height >= Self.minimumSize else {
            onFinish(nil)
            return
        }
        onFinish(fraction(for: selection))
    }

    // MARK: Private

    private var start: CGPoint?

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, pageFrame.minX), pageFrame.maxX),
            y: min(max(point.y, pageFrame.minY), pageFrame.maxY)
        )
    }
}
