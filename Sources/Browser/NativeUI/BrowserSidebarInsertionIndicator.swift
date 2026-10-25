// BrowserSidebarInsertionIndicator.swift

import AppKit

/// A single insertion cue with a hollow leading ring in the row margin, as in
/// sidebar drags. The dragged row may cover the middle of the gap; its text is never
/// crossed by the line, and the line starts at the ring's outer edge.
final class BrowserSidebarInsertionIndicator: NSView {
    // MARK: Private

    private static let ringDiameter = BrowserChromeLayout.sidebarDropIndicatorThickness * 3
    private static let ringLineWidth = BrowserChromeLayout.sidebarDropIndicatorThickness * 0.75

    // MARK: Internal

    override var isFlipped: Bool { true }

    private(set) var lineFrame: CGRect?
    private(set) var visibleLineSegments = [CGRect]()

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let color = BrowserChromeColors.sidebarDropIndicator
        let inset = Self.ringLineWidth / 2
        let ring = NSBezierPath(ovalIn: CGRect(
            x: inset,
            y: inset,
            width: Self.ringDiameter - Self.ringLineWidth,
            height: Self.ringDiameter - Self.ringLineWidth,
        ))
        ring.lineWidth = Self.ringLineWidth
        color.setStroke()
        ring.stroke()
        color.setFill()
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
        let diameter = Self.ringDiameter
        frame = CGRect(x: line.minX - 12, y: line.midY - diameter / 2, width: line.width + 12, height: diameter)
        let strokeMinX = frame.minX + diameter - Self.ringLineWidth / 2
        let stroke = CGRect(
            x: strokeMinX,
            y: line.minY,
            width: max(line.maxX - strokeMinX, 0),
            height: thickness,
        )
        visibleLineSegments =
            if let preview, preview.intersects(stroke) {
                [
                    CGRect(
                        x: stroke.minX,
                        y: stroke.minY,
                        width: max(min(preview.minX, stroke.maxX) - stroke.minX, 0),
                        height: thickness,
                    ),
                    CGRect(
                        x: max(preview.maxX, stroke.minX),
                        y: stroke.minY,
                        width: max(stroke.maxX - max(preview.maxX, stroke.minX), 0),
                        height: thickness,
                    ),
                ].filter { $0.width > 0 }
            } else {
                [stroke]
            }
        needsDisplay = true
    }
}
