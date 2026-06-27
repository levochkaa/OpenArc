import AppKit
import ImageIO

enum BrowserImageThumbnailer {
    // MARK: Internal

    static let chromeIconMaximumPixelSize: CGFloat = 64

    static func image(data: Data, maximumPixelSize: CGFloat) -> NSImage? {
        guard maximumPixelSize > 0 else {
            return nil
        }

        if let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions()),
           let thumbnail = thumbnailImage(from: imageSource, maximumPixelSize: maximumPixelSize)
        {
            return thumbnail
        }

        guard let image = NSImage(data: data) else {
            return nil
        }

        return resizedImage(image, maximumPixelDimension: maximumPixelSize)
    }

    static func image(contentsOf url: URL, maximumPixelSize: CGFloat) -> NSImage? {
        guard maximumPixelSize > 0 else {
            return nil
        }

        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions()),
           let thumbnail = thumbnailImage(from: imageSource, maximumPixelSize: maximumPixelSize)
        {
            return thumbnail
        }

        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        return resizedImage(image, maximumPixelDimension: maximumPixelSize)
    }

    static func resizedImage(_ image: NSImage, maximumPixelWidth: CGFloat) -> NSImage? {
        guard maximumPixelWidth > 0, image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let scale = min(maximumPixelWidth / image.size.width, 1)
        guard scale < 1 else {
            return image
        }

        let targetSize = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )
        return renderedImage(image, canvasSize: targetSize, drawRect: CGRect(origin: .zero, size: targetSize))
    }

    static func resizedImage(_ image: NSImage, fitting dimension: CGFloat) -> NSImage? {
        resizedImage(image, fitting: CGSize(width: dimension, height: dimension))
    }

    static func resizedImage(_ image: NSImage, fitting targetSize: CGSize) -> NSImage? {
        guard targetSize.width > 0, targetSize.height > 0, image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let scale = min(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        return renderedImage(image, canvasSize: targetSize, drawRect: drawRect)
    }

    static func resizedImage(_ image: NSImage, maximumPixelDimension: CGFloat) -> NSImage? {
        guard maximumPixelDimension > 0, image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let scale = min(maximumPixelDimension / max(image.size.width, image.size.height), 1)
        guard scale < 1 else {
            return image
        }

        let targetSize = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )
        return renderedImage(image, canvasSize: targetSize, drawRect: CGRect(origin: .zero, size: targetSize))
    }

    // MARK: Private

    private static func imageSourceOptions() -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
    }

    private static func thumbnailImage(from imageSource: CGImageSource, maximumPixelSize: CGFloat) -> NSImage? {
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(maximumPixelSize))),
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
    }

    private static func renderedImage(_ image: NSImage, canvasSize: CGSize, drawRect: CGRect) -> NSImage {
        let resizedImage = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: drawRect,
                from: CGRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1
            )
            return true
        }
        resizedImage.isTemplate = image.isTemplate
        return resizedImage
    }
}
