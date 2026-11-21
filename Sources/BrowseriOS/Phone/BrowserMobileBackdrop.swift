// BrowserMobileBackdrop.swift

import UIKit

// MARK: - BrowserMobileBackdrop

/// Whether the page under the phone's bar is dark, so the bar's material and
/// controls turn dark with it.
enum BrowserMobileBackdrop {
    /// Relative luminance under which a page counts as dark: where white and
    /// black text have the same contrast on it.
    static let darkBelow: CGFloat = 0.179

    static let buttonFill = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.1)
    }

    static let buttonBorder = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.12)
    }

    /// Glyphs on the bar and the page menu.
    static let glyph = UIColor {
        $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0.21, alpha: 1)
    }

    /// Average relative luminance of an image's pixels, nil for an empty one.
    static func luminance(of image: CGImage) -> CGFloat? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += luminance(
                red: CGFloat(pixels[index]) / 255, green: CGFloat(pixels[index + 1]) / 255,
                blue: CGFloat(pixels[index + 2]) / 255,
            )
        }
        return total / CGFloat(side * side)
    }

    /// Relative luminance of an opaque color; nil for one that cannot be read
    /// or is mostly transparent.
    static func luminance(of color: UIColor) -> CGFloat? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.5 else { return nil }
        return luminance(
            red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1),
        )
    }

    static func isDark(luminance: CGFloat) -> Bool {
        luminance < darkBelow
    }

    private static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// MARK: - BrowserMobileBarMaterial

/// The bar's surface: the page blurred under a thin light or dark material,
/// following the view's interface style, with a wash over it that lets more
/// of the page through than the system material and darkens toward the
/// bottom edge of the screen.
final class BrowserMobileBarMaterial: UIVisualEffectView {
    /// The wash over the material: its opacity and its top and bottom
    /// whites, the bottom one reached at the view's bottom edge.
    struct Wash: Equatable {
        static let light = Wash(alpha: 0.47, top: 0.92, bottom: 0.675)
        static let dark = Wash(alpha: 0.15, top: 0.116, bottom: 0.018)

        var alpha: CGFloat
        var top: CGFloat
        var bottom: CGFloat

        static func forStyle(_ style: UIUserInterfaceStyle) -> Wash {
            style == .dark ? dark : light
        }
    }

    /// The wash: one tone down to `span` above the bottom edge, then a
    /// linear ramp to the bottom tone.
    private final class WashView: UIView {
        override static var layerClass: AnyClass { CAGradientLayer.self }

        override var frame: CGRect {
            didSet { if frame.height != oldValue.height { updateGradient() } }
        }

        var wash = Wash.light {
            didSet { if wash != oldValue { updateGradient() } }
        }

        var span: CGFloat = 0 {
            didSet { if span != oldValue { updateGradient() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            updateGradient()
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        private func updateGradient() {
            guard let gradient = layer as? CAGradientLayer else { return }
            let top = UIColor(white: wash.top, alpha: wash.alpha).cgColor
            let bottom = UIColor(white: wash.bottom, alpha: wash.alpha).cgColor
            let start = bounds.height > span ? 1 - span / bounds.height : 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = [top, top, bottom]
            gradient.locations = [0, NSNumber(value: Double(start)), 1]
            CATransaction.commit()
        }
    }

    /// Height over which the wash darkens, up from the bottom edge: the
    /// expanded bar's height, so a taller panel keeps the top tone above it.
    static let washSpan: CGFloat = 76
    /// Opacity of the top hairline: black on the light material, white on
    /// the dark one.
    static let hairlineAlpha: CGFloat = 0.1

    /// The dark panel's glass that this material turns into as the panel
    /// rises out of the bar.
    static let panelGlass = UIBlurEffect(style: .systemUltraThinMaterialDark)

    /// Off over the switcher, where the bar shows what is behind it.
    var showsMaterial = true {
        didSet { updateEffect() }
    }

    /// Off while a panel grown out of the bar stands in for it, so the two
    /// materials do not stack.
    var isCovered = false {
        didSet {
            if isCovered != oldValue { updateEffect() }
        }
    }

    /// A hairline along the top edge, as the bar has and panels do not.
    var showsTopHairline = false {
        didSet { updateEffect() }
    }

    /// How far the material has turned into the panel glass, from 0 (the
    /// bar's material) to 1.
    private(set) var glassShare: CGFloat = 0

    private let wash = WashView()
    private let hairline = UIView()
    private let shade = UIView()
    /// Holds the blur partway between the bar's and the glass's while a
    /// finger moves the panel; one effect view keeps the page blurred all the
    /// way, where fading two would let it show through.
    private var glassAnimator: UIViewPropertyAnimator?

    /// The panel glass's shade over the blur.
    var shadeColor: UIColor? {
        get { shade.backgroundColor }
        set { shade.backgroundColor = newValue }
    }

    /// The bar's own effect, or none where the bar shows what is behind it.
    private var restingEffect: UIVisualEffect? {
        guard showsMaterial, !isCovered else { return nil }
        let dark = traitCollection.userInterfaceStyle == .dark
        return UIBlurEffect(style: dark ? .systemThinMaterialDark : .systemThinMaterialLight)
    }

    init() {
        super.init(effect: nil)
        wash.isUserInteractionEnabled = false
        hairline.isUserInteractionEnabled = false
        shade.isUserInteractionEnabled = false
        shade.alpha = 0
        contentView.insertSubview(wash, at: 0)
        contentView.insertSubview(shade, aboveSubview: wash)
        contentView.insertSubview(hairline, aboveSubview: shade)
        updateEffect()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (view: BrowserMobileBarMaterial, _) in
            view.updateEffect()
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        wash.frame = contentView.bounds
        wash.span = Self.washSpan
        shade.frame = contentView.bounds
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        hairline.frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: 1 / scale)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // A paused animator must not outlive its run.
        if newWindow == nil { endGlassAnimator() }
    }

    /// Turns the material toward the panel glass. Inside an animation block
    /// the change animates; `interactive` holds it partway, as a finger
    /// moving the panel does.
    func setGlassShare(_ share: CGFloat, interactive: Bool = false) {
        glassShare = share
        wash.alpha = 1 - share
        shade.alpha = share
        if interactive {
            if glassAnimator == nil {
                UIView.performWithoutAnimation { effect = restingEffect }
                let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                    self?.effect = Self.panelGlass
                }
                animator.pausesOnCompletion = true
                glassAnimator = animator
            }
            glassAnimator?.fractionComplete = share
        } else {
            endGlassAnimator()
            effect = share > 0 ? Self.panelGlass : restingEffect
        }
    }

    private func endGlassAnimator() {
        guard let animator = glassAnimator else { return }
        glassAnimator = nil
        animator.stopAnimation(true)
    }

    private func updateEffect() {
        let shows = showsMaterial && !isCovered
        wash.isHidden = !shows
        hairline.isHidden = !shows || !showsTopHairline
        let dark = traitCollection.userInterfaceStyle == .dark
        wash.wash = Wash.forStyle(traitCollection.userInterfaceStyle)
        hairline.backgroundColor = UIColor(white: dark ? 1 : 0, alpha: Self.hairlineAlpha)
        if glassAnimator != nil {
            // Starts the held blur again from the new resting effect.
            endGlassAnimator()
            setGlassShare(glassShare, interactive: true)
        } else {
            effect = glassShare > 0 ? Self.panelGlass : restingEffect
        }
    }
}
