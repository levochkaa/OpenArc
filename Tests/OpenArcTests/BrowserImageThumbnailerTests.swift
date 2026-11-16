// BrowserImageThumbnailerTests.swift

import AppKit
import Foundation
import Testing

@Test
@MainActor func imageThumbnailerDownsamplesEncodedData() throws {
    let imageData = try #require(makeTestImage(width: 128, height: 64).tiffRepresentation)

    let thumbnail = try #require(BrowserImageThumbnailer.image(data: imageData, maximumPixelSize: 32))

    #expect(max(thumbnail.size.width, thumbnail.size.height) <= 32)
    #expect(thumbnail.size.width > thumbnail.size.height)
}

@Test
@MainActor func imageThumbnailerResizesMaterializedImageIntoSquareCanvas() throws {
    let image = makeTestImage(width: 32, height: 16)
    image.isTemplate = true

    let resizedImage = try #require(BrowserImageThumbnailer.resizedImage(image, fitting: 16))

    #expect(resizedImage.size == CGSize(width: 16, height: 16))
    #expect(resizedImage.isTemplate)
}

@Test
@MainActor func imageThumbnailerNormalizesWebArtworkForMacOSDock() throws {
    let sourceImage = makeTestImage(width: 512, height: 512)
    let icon = try #require(BrowserImageThumbnailer.macOSApplicationIcon(from: sourceImage))
    let cgImage = try #require(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let center = bitmap.pixelsWide / 2
    let transparentSample = Int(Double(bitmap.pixelsWide) * 0.05)
    let artworkSample = Int(Double(bitmap.pixelsWide) * 0.12)

    #expect(icon.size == CGSize(
        width: BrowserImageThumbnailer.macOSApplicationIconCanvasSize,
        height: BrowserImageThumbnailer.macOSApplicationIconCanvasSize,
    ))
    #expect(bitmap.colorAt(x: transparentSample, y: center)?.alphaComponent == 0)
    #expect((bitmap.colorAt(x: artworkSample, y: center)?.alphaComponent ?? 0) > 0)
    #expect((bitmap.colorAt(x: artworkSample, y: artworkSample)?.alphaComponent ?? 0) < 0.35)
    #expect((bitmap.colorAt(x: center, y: center)?.alphaComponent ?? 0) > 0)
}

@Test
@MainActor func webAppBundleIconEncoderProducesReadableICNS() throws {
    let fileManager = FileManager.default
    let iconURL = fileManager.temporaryDirectory
        .appendingPathComponent("BrowserWebAppIcon-\(UUID().uuidString).icns", isDirectory: false)
    defer { try? fileManager.removeItem(at: iconURL) }

    let sourceImage = makeTestImage(width: 512, height: 512)
    let icnsData = try #require(BrowserWebAppBundleIconEncoder.icnsData(from: sourceImage))
    try icnsData.write(to: iconURL, options: .atomic)

    #expect(String(decoding: icnsData.prefix(4), as: UTF8.self) == "icns")
    #expect(icnsData.count > 32)
    let decodedIcon = try #require(NSImage(contentsOf: iconURL))
    let decodedCGImage = try #require(decodedIcon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(decodedCGImage.width == 512)
    #expect(decodedCGImage.height == 512)
}

@Test
@MainActor func webAppBundleIconEncoderPreservesNativeManifestIconScale() throws {
    let sourceData = try #require(makeSharpTestImageData())
    let sourceIcon = try #require(NSImage(data: sourceData))
    let sourceCGImage = try #require(sourceIcon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let sourceBitmap = NSBitmapImageRep(cgImage: sourceCGImage)
    let icnsData = try #require(BrowserWebAppBundleIconEncoder.icnsData(fromEncodedImageData: sourceData))
    let decodedIcon = try #require(NSImage(data: icnsData))
    let decodedCGImage = try #require(decodedIcon.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let bitmap = NSBitmapImageRep(cgImage: decodedCGImage)
    let markerY = try #require((0..<sourceBitmap.pixelsHigh).first { y in
        guard let color = sourceBitmap.colorAt(x: 300, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.greenComponent > 0.95 && color.redComponent < 0.05 && color.blueComponent < 0.05
    })
    let stripeColor = try #require(bitmap.colorAt(x: 380, y: 256)?.usingColorSpace(.deviceRGB))
    let neighborColor = try #require(bitmap.colorAt(x: 379, y: 256)?.usingColorSpace(.deviceRGB))
    let markerColor = try #require(bitmap.colorAt(x: 300, y: markerY)?.usingColorSpace(.deviceRGB))

    #expect(stripeColor.redComponent > 0.95)
    #expect(stripeColor.blueComponent < 0.05)
    #expect(neighborColor.redComponent < 0.05)
    #expect(neighborColor.blueComponent > 0.95)
    #expect(markerColor.greenComponent > 0.95)
    #expect(markerColor.redComponent < 0.05)
    #expect(markerColor.blueComponent < 0.05)
}

@MainActor private func makeTestImage(width: CGFloat, height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    return image
}

@MainActor private func makeSharpTestImageData() -> Data? {
    let size = Int(BrowserImageThumbnailer.macOSApplicationIconCanvasSize)
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        return nil
    }

    bitmap.size = CGSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = false
    NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).setFill()
    NSRect(x: 380, y: 0, width: 1, height: size).fill()
    NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1).setFill()
    NSRect(x: 260, y: 400, width: 80, height: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

/// A tab preview draws the page area straight at preview size, keeping its colors.
@Test
@MainActor func viewSnapshotDrawsAtTheSmallSizeDirectly() throws {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).cgColor
    let image = try #require(BrowserImageThumbnailer.viewSnapshot(of: view, maximumPixelWidth: 480))
    let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
    #expect(bitmap.pixelsWide == 480 && bitmap.pixelsHigh == 300)
    #expect(image.size == view.bounds.size)
    let center = try #require(bitmap.colorAt(x: 240, y: 150)?.usingColorSpace(.deviceRGB))
    #expect(center.redComponent > 0.9 && center.greenComponent < 0.1)
}

/// An SVG favicon becomes a bitmap at icon size, its colors kept.
@Test
@MainActor func vectorIconsAreDrawnIntoBitmaps() throws {
    let svg = """
    <svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg">
    <rect x="0" y="0" width="8" height="16" fill="#0000ff"/><rect x="8" y="0" width="8" height="16" fill="#ffff00"/>
    </svg>
    """
    let image = try #require(BrowserImageThumbnailer.image(data: Data(svg.utf8), maximumPixelSize: 64))
    #expect(!(image.representations.first is NSBitmapImageRep), "A finished picture, as decoded icons are")
    let bitmap = try NSBitmapImageRep(cgImage: #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    #expect(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
    let left = try #require(bitmap.colorAt(x: 10, y: 32)?.usingColorSpace(.deviceRGB))
    let right = try #require(bitmap.colorAt(x: 54, y: 32)?.usingColorSpace(.deviceRGB))
    #expect(left.blueComponent > 0.8 && left.redComponent < 0.2)
    #expect(right.redComponent > 0.8 && right.blueComponent < 0.2)
}
