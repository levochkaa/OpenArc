// BrowserImageThumbnailer.swift

import AppKit
import ImageIO

enum BrowserImageThumbnailer {
    // MARK: Internal

    static let chromeIconMaximumPixelSize: CGFloat = 64
    static let macOSApplicationIconCanvasSize: CGFloat = 512

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

        // An SVG or PDF icon is drawn once into a bitmap, as decoded icons are: image
        // views can leave parts of a vector icon undrawn.
        if !image.representations.contains(where: { $0 is NSBitmapImageRep }) {
            return rasterizedImage(image, maximumPixelSize: maximumPixelSize)
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

    static func macOSApplicationIcon(from image: NSImage) -> NSImage? {
        guard
            image.size.width > 0,
            image.size.height > 0,
            let sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let bitmap = macOSApplicationIconBitmap(from: sourceImage)
        else {
            return nil
        }

        let icon = NSImage(size: bitmap.size)
        icon.addRepresentation(bitmap)
        return icon
    }

    static func macOSApplicationIconPNGData(from image: NSImage) -> Data? {
        guard
            let sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let bitmap = macOSApplicationIconBitmap(from: sourceImage)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func macOSApplicationIconPNGData(fromEncodedImageData data: Data) -> Data? {
        guard
            let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions()),
            let sourceImage = applicationIconSourceImage(from: imageSource),
            let bitmap = macOSApplicationIconBitmap(from: sourceImage)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
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
            height: floor(image.size.height * scale),
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
            height: drawSize.height,
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
            height: floor(image.size.height * scale),
        )
        return renderedImage(image, canvasSize: targetSize, drawRect: CGRect(origin: .zero, size: targetSize))
    }

    /// A view drawn straight into a bitmap at most `maximumPixelWidth` wide. Drawing
    /// at the small size skips the full-resolution capture a resize would start from.
    @MainActor static func viewSnapshot(of view: NSView, maximumPixelWidth: CGFloat) -> NSImage? {
        let bounds = view.bounds
        guard maximumPixelWidth > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = floor(min(maximumPixelWidth, bounds.width * backingScale))
        let pixelHeight = floor(bounds.height * pixelWidth / bounds.width)
        guard pixelWidth >= 1, pixelHeight >= 1, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelWidth),
            pixelsHigh: Int(pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ) else { return nil }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func rasterizedImage(_ image: NSImage, maximumPixelSize: CGFloat) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = maximumPixelSize / max(image.size.width, image.size.height)
        let width = max(Int((image.size.width * scale).rounded()), 1)
        let height = max(Int((image.size.height * scale).rounded()), 1)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let rasterized = NSImage(size: NSSize(width: width, height: height))
        rasterized.addRepresentation(bitmap)
        rasterized.isTemplate = image.isTemplate
        return rasterized
    }

    // MARK: Private

    private static func macOSApplicationIconBitmap(from sourceImage: CGImage) -> NSBitmapImageRep? {
        let canvasSize = macOSApplicationIconCanvasSize
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize),
                pixelsHigh: Int(canvasSize),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0,
            ),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }

        bitmap.size = CGSize(width: canvasSize, height: canvasSize)
        let canvasRect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        let maskRect = canvasRect.insetBy(dx: 50, dy: 50)
        let maskPath = NSBezierPath(roundedRect: maskRect, xRadius: 92, yRadius: 92)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.shouldAntialias = true
        graphicsContext.imageInterpolation = NSImageInterpolation.high
        NSColor.clear.setFill()
        canvasRect.fill(using: .copy)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(77 / 255)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor.black.setFill()
        maskPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        maskPath.addClip()
        NSColor.white.setFill()
        canvasRect.fill()
        graphicsContext.cgContext.interpolationQuality = sourceImage.width == Int(canvasSize)
            && sourceImage.height == Int(canvasSize)
            ? .none
            : .high
        graphicsContext.cgContext.draw(sourceImage, in: canvasRect)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap
    }

    private static func applicationIconSourceImage(from imageSource: CGImageSource) -> CGImage? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }

        let maximumSourceDimension = max(pixelWidth.intValue, pixelHeight.intValue)
        if maximumSourceDimension <= Int(macOSApplicationIconCanvasSize) {
            return CGImageSourceCreateImageAtIndex(
                imageSource,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary,
            )
        }

        return thumbnailCGImage(from: imageSource, maximumPixelSize: macOSApplicationIconCanvasSize)
    }

    private static func imageSourceOptions() -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
    }

    private static func thumbnailImage(from imageSource: CGImageSource, maximumPixelSize: CGFloat) -> NSImage? {
        guard let cgImage = thumbnailCGImage(from: imageSource, maximumPixelSize: maximumPixelSize) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)),
        )
    }

    private static func thumbnailCGImage(from imageSource: CGImageSource, maximumPixelSize: CGFloat) -> CGImage? {
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(maximumPixelSize))),
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions)
    }

    private static func renderedImage(_ image: NSImage, canvasSize: CGSize, drawRect: CGRect) -> NSImage {
        let resizedImage = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: drawRect,
                from: CGRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1,
            )
            return true
        }
        resizedImage.isTemplate = image.isTemplate
        return resizedImage
    }
}
