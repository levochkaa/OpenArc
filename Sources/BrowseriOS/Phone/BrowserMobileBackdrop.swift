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

/// The bar's surface: the page blurred under a light or dark material,
/// following the view's interface style. The dark one is thinner so a
/// colored page keeps more of its color.
final class BrowserMobileBarMaterial: UIVisualEffectView {
    /// Off over the switcher, where the bar shows what is behind it.
    var showsMaterial = true {
        didSet { updateEffect() }
    }

    init() {
        super.init(effect: nil)
        updateEffect()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BrowserMobileBarMaterial, _) in
            view.updateEffect()
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateEffect() {
        guard showsMaterial else {
            effect = nil
            return
        }
        effect = UIBlurEffect(
            style: traitCollection.userInterfaceStyle == .dark ? .systemThinMaterialDark : .systemMaterialLight,
        )
    }
}
