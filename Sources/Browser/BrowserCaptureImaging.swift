// BrowserCaptureImaging.swift

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - BrowserCaptureImaging

/// Picture work for captures: cutting the outlined part out of a picture of
/// the page, and the gray page shown behind a capture.
enum BrowserCaptureImaging {
    /// How bright the gray page behind a capture stays.
    static let backdropBrightness: CGFloat = 0.75

    static func cgImage(png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The pixels of `fraction` (y downward) of a picture of the whole page view.
    static func crop(_ image: CGImage, fraction: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(
            x: fraction.minX * width,
            y: fraction.minY * height,
            width: fraction.width * width,
            height: fraction.height * height,
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    /// The page in gray at three quarters of its brightness, behind a capture.
    static func backdrop(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue,
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        context.setFillColor(gray: 0, alpha: 1 - backdropBrightness)
        context.fill(rect)
        return context.makeImage()
    }

    /// The size a picture of `pixelSize` takes on the page: its pixels as
    /// points, scaled down to fit `bounds`.
    static func fittedSize(pixelSize: CGSize, in bounds: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let scale = min(1, bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }
}
