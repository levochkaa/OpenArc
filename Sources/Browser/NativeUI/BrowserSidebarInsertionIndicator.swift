import AppKit

/// A single insertion cue with a leading endpoint in the row margin. The dragged
/// row may cover the middle of the gap; its text is never crossed by the line.
final class BrowserSidebarInsertionIndicator: NSView {
    override var isFlipped: Bool { true }

    private(set) var lineFrame: CGRect?
    private(set) var visibleLineSegments = [CGRect]()

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        BrowserChromeColors.sidebarDropIndicator.setFill()
        let diameter = BrowserChromeLayout.sidebarDropIndicatorThickness * 2
        NSBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        for segment in visibleLineSegments {
            let local = segment.offsetBy(dx: -frame.minX, dy: -frame.minY)
            NSBezierPath(roundedRect: local, xRadius: local.height / 2, yRadius: local.height / 2).fill()
        }
    }

    func update(line: CGRect?, occluding preview: CGRect?) {
        lineFrame = line
        guard let line else { visibleLineSegments.removeAll()
            isHidden = true
            return
        }
        isHidden = false
        let thickness = BrowserChromeLayout.sidebarDropIndicatorThickness
        let diameter = thickness * 2
        frame = CGRect(x: line.minX - 12, y: line.midY - diameter / 2, width: line.width + 12, height: diameter)
        let stroke = CGRect(
            x: frame.minX + diameter / 2,
            y: line.minY,
            width: line.maxX - frame.minX - diameter / 2,
            height: thickness
        )
        visibleLineSegments =
            if let preview, preview.intersects(stroke) {
                [
                    CGRect(
                        x: stroke.minX,
                        y: stroke.minY,
                        width: max(min(preview.minX, stroke.maxX) - stroke.minX, 0),
                        height: thickness
                    ),
                    CGRect(
                        x: max(preview.maxX, stroke.minX),
                        y: stroke.minY,
                        width: max(stroke.maxX - max(preview.maxX, stroke.minX), 0),
                        height: thickness
                    ),
                ].filter { $0.width > 0 }
            } else {
                [stroke]
            }
        needsDisplay = true
    }
}
