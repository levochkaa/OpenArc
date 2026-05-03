import AppKit
import Foundation
import Testing

@Test
@MainActor func faviconCacheReturnsStoredImageSynchronously() throws {
    let cache = BrowserFaviconCache(dataLoader: { _ in nil })
    let url = try #require(URL(string: "https://example.com/favicon.ico"))
    let image = NSImage(size: NSSize(width: 16, height: 16))

    #expect(cache.image(for: url) == nil)

    cache.store(image, for: url)

    let cachedImage = try #require(cache.image(for: url))
    #expect(cachedImage === image)
}

@Test
@MainActor func faviconCacheLoadsImageDataOnDemand() async throws {
    let url = try #require(URL(string: "https://example.com/favicon.ico"))
    let imageData = try #require(makeTestFaviconImage().tiffRepresentation)
    let cache = BrowserFaviconCache(dataLoader: { requestedURL in
        requestedURL == url ? imageData : nil
    })

    await cache.loadImageIfNeeded(from: url)

    #expect(cache.image(for: url) != nil)
}

private func makeTestFaviconImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 16, height: 16).fill()
    image.unlockFocus()
    return image
}
