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

@MainActor private func makeTestImage(width: CGFloat, height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    return image
}
