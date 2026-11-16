// BrowserAppIconTests.swift

import AppKit
import Testing

@Test func aPickedIconIsDecodedAtTheDocksSize() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
    ))
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)

    let icon = try #require(BrowserAppIcon.dockImage(contentsOf: url))
    let pixels = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
    #expect(pixels == 512, "Decoded once at the Dock's largest size, not at 1024")
}
