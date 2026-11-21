// BrowserMobileAppBackdrop.swift

import UIKit

// MARK: - BrowserMobileAppBackdrop

/// The app's own dark backdrop: deep blue, lighter across the middle, with a
/// warm glow from the right edge. It shows when no page is open and behind
/// the tab switcher's cards.
final class BrowserMobileAppBackdrop: UIView {
    // MARK: Private

    private static let baseStops: [(location: CGFloat, color: UIColor)] = [
        (0, color(28, 27, 47)),
        (0.33, color(29, 28, 47)),
        (0.5, color(37, 35, 49)),
        (0.6, color(41, 39, 50)),
        (0.72, color(36, 36, 51)),
        (1, color(34, 34, 51)),
    ]

    private static let glowColor = color(57, 33, 34)
    /// In units of the view's size.
    private static let glowCenter = CGPoint(x: 1, y: 0.54)
    private static let glowRadii = CGSize(width: 0.8, height: 0.6)

    // MARK: Internal

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = Self.color(28, 27, 47)
        contentMode = .redraw
        isUserInteractionEnabled = false
        accessibilityIdentifier = "browser.appBackdrop"
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        let size = bounds.size
        if let base = CGGradient(
            colorsSpace: space, colors: Self.baseStops.map(\.color.cgColor) as CFArray,
            locations: Self.baseStops.map(\.location),
        ) {
            context.drawLinearGradient(
                base, start: .zero, end: CGPoint(x: 0, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation],
            )
        }
        // The glow is an ellipse centred on the right edge, fading linearly.
        guard let glow = CGGradient(
            colorsSpace: space,
            colors: [Self.glowColor.cgColor, Self.glowColor.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1],
        ) else { return }
        context.saveGState()
        context.translateBy(x: size.width * Self.glowCenter.x, y: size.height * Self.glowCenter.y)
        context.scaleBy(x: size.width * Self.glowRadii.width, y: size.height * Self.glowRadii.height)
        context.drawRadialGradient(
            glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [],
        )
        context.restoreGState()
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}
