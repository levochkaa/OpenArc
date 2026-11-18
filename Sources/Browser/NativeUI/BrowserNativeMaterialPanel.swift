// BrowserNativeMaterialPanel.swift

import AppKit

/// Shared material, outline and shadow for floating browser controls.
final class BrowserNativeMaterialPanel: NSView {
    /// Site search flash curves: keyframe times in 60 Hz frames from the
    /// frame the chip appears, with the value at each.
    private enum Flash {
        static let tintAlpha: CGFloat = 0.2
        static let tintFrames: [Double] = [0, 2, 4, 6, 9, 12, 17, 23, 31, 41, 50, 67]
        static let tintOpacity: [Double] = [1, 1, 0.94, 0.86, 0.74, 0.62, 0.53, 0.39, 0.28, 0.18, 0.12, 0]
        static let glowDelay: CFTimeInterval = 3.0 / 60
        static let glowFrames: [Double] = [0, 6, 10, 17, 27, 37, 47, 60]
        static let glowOpacity: [Double] = [0.59, 0.7, 0.73, 0.71, 0.59, 0.39, 0.21, 0]
        static let glowRadius: [Double] = [5, 24, 45, 74, 120, 163, 206, 264]
        static let scaleDelay: CFTimeInterval = 1.0 / 60
        static let scaleFrames: [Double] = Array(0...11).map(Double.init)
        /// How far the card dips toward `smallestScale`.
        static let scaleDepth: [Double] = [0, 0.16, 0.38, 0.53, 0.81, 1, 0.81, 0.56, 0.34, 0.12, 0.03, 0]
        static let smallestScale = 0.989

        static func keyTimes(_ frames: [Double]) -> [NSNumber] {
            frames.map { NSNumber(value: $0 / frames.last!) }
        }
    }

    // MARK: Internal

    override var isFlipped: Bool { true }

    let contentView = BrowserNativeSurface()

    var cornerRadius: CGFloat = 12 { didSet { updateStyle() } }
    var fillColor = BrowserChromeColors.commandBarPanelTint { didSet { updateStyle() } }
    var borderColor = BrowserChromeColors.commandBarPanelBorder { didSet { updateStyle() } }
    var shadowOpacity: CGFloat = 0.38 { didSet { updateStyle() } }
    var shadowRadius: CGFloat = BrowserChromeLayout.commandBarShadowRadius { didSet { updateStyle() } }
    var shadowOffset: CGFloat = 18 { didSet { updateStyle() } }

    // MARK: Private

    private let clip = NSView()
    private let material = NSVisualEffectView()
    /// The site search flash: a glow in the site's color that spreads out
    /// from the card, and a tint over its fill (see `flash(color:)`).
    private let glow = CALayer()
    private let tint = CALayer()
    /// Set by `flash(color:)`; the next layout starts it, once the card has its new size.
    private var pendingFlashColor: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        addSubview(clip)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        clip.addSubview(material)
        clip.addSubview(contentView)
        glow.opacity = 0
        glow.shadowOffset = .zero
        glow.shadowOpacity = 0
        layer?.insertSublayer(glow, at: 0)
        tint.opacity = 0
        contentView.wantsLayer = true
        contentView.layer?.insertSublayer(tint, at: 0)
        updateStyle()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        clip.frame = bounds
        material.frame = clip.bounds
        contentView.frame = clip.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        glow.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil,
        )
        tint.frame = contentView.bounds
        CATransaction.commit()
        if let color = pendingFlashColor {
            pendingFlashColor = nil
            startFlash(color: color)
        }
    }

    override func mouseDown(with _: NSEvent) {}

    /// After Tab picks a site to search, the card dips by about 1% and back in
    /// 0.2 s, its fill takes the site's color and fades back over about 1.1 s,
    /// and a glow of that color spreads out from the card and is gone by 1.05 s.
    func flash(color: NSColor) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pendingFlashColor = color
        needsLayout = true
    }

    private func startFlash(color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.shadowColor = color.cgColor
        glow.opacity = 1
        tint.backgroundColor = color.withAlphaComponent(Flash.tintAlpha).cgColor
        CATransaction.commit()
        let now = CACurrentMediaTime()

        let tintFade = CAKeyframeAnimation(keyPath: "opacity")
        tintFade.values = Flash.tintOpacity
        tintFade.keyTimes = Flash.keyTimes(Flash.tintFrames)
        tintFade.duration = Flash.tintFrames.last! / 60
        tint.add(tintFade, forKey: "siteSearchFlash")

        let glowOpacity = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glowOpacity.values = Flash.glowOpacity
        let glowRadius = CAKeyframeAnimation(keyPath: "shadowRadius")
        glowRadius.values = Flash.glowRadius
        for animation in [glowOpacity, glowRadius] {
            animation.keyTimes = Flash.keyTimes(Flash.glowFrames)
        }
        let glowGroup = CAAnimationGroup()
        glowGroup.animations = [glowOpacity, glowRadius]
        glowGroup.duration = Flash.glowFrames.last! / 60
        glowGroup.beginTime = now + Flash.glowDelay
        glow.add(glowGroup, forKey: "siteSearchFlash")

        guard let layer, bounds.width > 0 else { return }
        // The layer's anchor is its corner, so scale around the center by hand.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = CAKeyframeAnimation(keyPath: "transform")
        scale.values = Flash.scaleDepth.map { depth in
            let factor = 1 - (1 - Flash.smallestScale) * depth
            var transform = CATransform3DMakeTranslation(-center.x, -center.y, 0)
            transform = CATransform3DConcat(transform, CATransform3DMakeScale(factor, factor, 1))
            transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(center.x, center.y, 0))
            return NSValue(caTransform3D: transform)
        }
        scale.keyTimes = Flash.keyTimes(Flash.scaleFrames)
        scale.duration = Flash.scaleFrames.last! / 60
        scale.beginTime = now + Flash.scaleDelay
        layer.add(scale, forKey: "siteSearchFlash")
    }

    private func updateStyle() {
        clip.layer?.cornerRadius = cornerRadius
        contentView.cornerRadius = cornerRadius
        contentView.fillColor = fillColor
        contentView.strokeColor = borderColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowOpacity)
        shadow.shadowBlurRadius = shadowRadius
        shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
        self.shadow = shadow
    }
}
