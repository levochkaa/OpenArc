// BrowserNativeMaterialPanel.swift

import AppKit

/// Shared material, outline and shadow for floating browser controls.
final class BrowserNativeMaterialPanel: NSView {
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
    /// from the card, and a tint over its material (see `flash(color:)`).
    private let glow = CALayer()
    private let tint = CALayer()

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
        if let contentLayer = contentView.layer {
            clip.layer?.insertSublayer(tint, below: contentLayer)
        }
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
        tint.frame = clip.bounds
        CATransaction.commit()
    }

    override func mouseDown(with _: NSEvent) {}

    /// After Tab picks a site to search, the card's material takes the
    /// site's color and fades back in about 0.8 s, while a glow of that color
    /// spreads out from the card, peaks near 0.15 s and is gone by 1 s.
    func flash(color: NSColor) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        needsLayout = true
        layoutSubtreeIfNeeded()
        let cgColor = color.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.shadowColor = cgColor
        glow.opacity = 1
        tint.backgroundColor = cgColor
        CATransaction.commit()

        let glowOpacity = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glowOpacity.values = [0, 0.55, 0.5, 0]
        glowOpacity.keyTimes = [0, 0.15, 0.35, 1]
        let glowRadius = CABasicAnimation(keyPath: "shadowRadius")
        glowRadius.fromValue = 4
        glowRadius.toValue = 36
        glowRadius.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let glowGroup = CAAnimationGroup()
        glowGroup.animations = [glowOpacity, glowRadius]
        glowGroup.duration = 1
        glow.add(glowGroup, forKey: "siteSearchFlash")

        let tintFade = CABasicAnimation(keyPath: "opacity")
        tintFade.fromValue = 0.07
        tintFade.toValue = 0
        tintFade.duration = 0.8
        tintFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tint.add(tintFade, forKey: "siteSearchFlash")
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
