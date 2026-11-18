// BrowserMobileBackdrop.swift

import UIKit

/// Whether the page under the phone's bar is dark, so the bar's glass and
/// controls turn dark with it.
enum BrowserMobileBackdrop {
    /// Relative luminance under which the glass turns dark; between the two
    /// limits it keeps its current look.
    static let darkBelow: CGFloat = 0.16
    static let lightAbove: CGFloat = 0.24

    static let buttonFill = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.1)
    }

    static let buttonBorder = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.12)
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
        func linear(_ value: UInt8) -> CGFloat {
            let c = CGFloat(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var total: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1])
                + 0.0722 * linear(pixels[index + 2])
        }
        return total / CGFloat(side * side)
    }

    /// The bar's look for a backdrop of `luminance`, keeping `current` in the
    /// band between the limits so a mixed page does not flicker.
    static func isDark(luminance: CGFloat, current: Bool) -> Bool {
        if luminance < darkBelow { return true }
        if luminance > lightAbove { return false }
        return current
    }

    @MainActor static func glass() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        effect.tintColor = UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 0.62) : UIColor(white: 1, alpha: 0.42)
        }
        return effect
    }
}
