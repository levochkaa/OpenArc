// BrowserFolderIconView.swift

import AppKit

/// A folder drawn in layers so it can swing open in perspective: flat while collapsed,
/// tilted open while its tabs show.
final class BrowserFolderIconView: NSView {
    // MARK: Internal

    static let side: CGFloat = 17

    // MARK: Private

    /// Flat, with the perspective the tilt swings through.
    private static let flat: CATransform3D = {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 350
        return transform
    }()

    private static let backTilted = CATransform3D(
        m11: 0.848048, m12: 0, m13: -0.529919, m14: 0.00151406,
        m21: 0.248782, m22: 0.882948, m23: 0.398134, m24: -0.00113753,
        m31: 0.467891, m32: -0.469472, m33: 0.748782, m34: -0.00213938,
        m41: 3, m42: 0, m43: 0, m44: 1,
    )

    private static let frontTilted = CATransform3D(
        m11: 0.848048, m12: 0, m13: -0.529919, m14: 0.00151406,
        m21: -0.26496, m22: 0.866025, m23: -0.424024, m24: 0.0012115,
        m31: 0.458924, m32: 0.5, m33: 0.734431, m34: -0.00209837,
        m41: 3, m42: 0, m43: 0, m44: 1,
    )

    private static let backPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 0))
        path.addLine(to: CGPoint(x: 7, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 2))
        path.addLine(to: CGPoint(x: 15, y: 2))
        path.addCurve(
            to: CGPoint(x: 17, y: 4),
            control1: CGPoint(x: 16.1046, y: 2),
            control2: CGPoint(x: 17, y: 2.89543),
        )
        path.addLine(to: CGPoint(x: 17, y: 15))
        path.addCurve(
            to: CGPoint(x: 15, y: 17),
            control1: CGPoint(x: 17, y: 16.1046),
            control2: CGPoint(x: 16.1046, y: 17),
        )
        path.addLine(to: CGPoint(x: 2, y: 17))
        path.addCurve(
            to: CGPoint(x: 0, y: 15),
            control1: CGPoint(x: 0.895431, y: 17),
            control2: CGPoint(x: 0, y: 16.1046),
        )
        path.addLine(to: CGPoint(x: 0, y: 2))
        path.addCurve(
            to: CGPoint(x: 2, y: 0),
            control1: CGPoint(x: 0, y: 0.895431),
            control2: CGPoint(x: 0.895431, y: 0),
        )
        path.closeSubpath()
        return path
    }()

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    private(set) var isTilted = false

    private let back = CAShapeLayer()
    private let backShade = CAGradientLayer()
    private let front = CALayer()
    private let frontPanel = CAShapeLayer()
    private let frontShade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        back.path = Self.backPath
        back.lineWidth = 1.5
        back.anchorPoint = CGPoint(x: 0, y: 1)
        back.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        backShade.frame = back.bounds
        backShade.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.36).cgColor,
        ]
        backShade.startPoint = .zero
        backShade.endPoint = CGPoint(x: 0.6, y: 1)
        backShade.opacity = 0.2
        let backMask = CAShapeLayer()
        backMask.path = Self.backPath
        backMask.frame = back.bounds
        backShade.mask = backMask
        back.addSublayer(backShade)

        front.anchorPoint = CGPoint(x: 0, y: 1)
        front.bounds = CGRect(x: 0, y: 0, width: Self.side, height: 13)
        frontPanel.frame = front.bounds
        frontPanel.path = CGPath(
            roundedRect: front.bounds,
            cornerWidth: 2,
            cornerHeight: 2,
            transform: nil,
        )
        frontPanel.lineWidth = 1.5
        frontShade.frame = front.bounds
        frontShade.cornerRadius = 2
        frontShade.masksToBounds = true
        frontShade.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.15).cgColor,
        ]
        frontShade.startPoint = CGPoint(x: 0.1, y: 0)
        frontShade.endPoint = CGPoint(x: 0.9, y: 1)
        frontShade.opacity = 0
        frontPanel.addSublayer(frontShade)
        front.addSublayer(frontPanel)

        back.transform = Self.flat
        front.transform = Self.flat
        layer?.addSublayer(back)
        layer?.addSublayer(front)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutActions {
            let hinge = CGPoint(x: (bounds.width - Self.side) / 2, y: (bounds.height + Self.side) / 2)
            back.position = hinge
            front.position = hinge
            let scale = window?.backingScaleFactor ?? 2
            for sublayer in [back, backShade, front, frontPanel, frontShade] {
                sublayer.contentsScale = scale
            }
        }
    }

    func setColors(stroke: NSColor, backFill: NSColor, frontFill: NSColor) {
        withoutActions {
            back.strokeColor = stroke.cgColor
            back.fillColor = backFill.cgColor
            frontPanel.strokeColor = stroke.cgColor
            frontPanel.fillColor = frontFill.cgColor
        }
    }

    func setTilted(_ tilted: Bool, animated: Bool) {
        guard tilted != isTilted else { return }
        isTilted = tilted
        let move = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let changes: [(CALayer, String, Any?, Any)] = [
            (back, "transform", NSValue(caTransform3D: back.transform), NSValue(caTransform3D: tilted
                    ? Self.backTilted
                    : Self.flat)),
            (front, "transform", NSValue(caTransform3D: front.transform), NSValue(caTransform3D: tilted
                    ? Self.frontTilted
                    : Self.flat)),
            (backShade, "opacity", backShade.opacity, Float(tilted ? 1 : 0.2)),
            (frontShade, "opacity", frontShade.opacity, Float(tilted ? 1 : 0)),
        ]
        for (target, keyPath, from, to) in changes {
            if move {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = target.presentation()?.value(forKeyPath: keyPath) ?? from
                animation.toValue = to
                animation.duration = 0.25
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                target.add(animation, forKey: keyPath)
            }
            withoutActions { target.setValue(to, forKeyPath: keyPath) }
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
