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
        updateStyle()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        clip.frame = bounds
        material.frame = clip.bounds
        contentView.frame = clip.bounds
    }

    override func mouseDown(with _: NSEvent) {}

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
