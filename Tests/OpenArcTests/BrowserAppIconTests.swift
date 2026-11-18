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

@Test func theDockTileDrawsThePickedIconFromTheAppResources() {
    #expect(BrowserAppIcon.resourceName(preferenceValue: "candy") == "openarc-icon-candy")
    #expect(BrowserAppIcon.resourceName(preferenceValue: "monochrome") == "openarc-icon-monochrome")
}

@Test func theDockTileKeepsTheBundleIconForTheStandardChoice() {
    #expect(BrowserAppIcon.resourceName(preferenceValue: "standard") == nil)
    #expect(BrowserAppIcon.resourceName(preferenceValue: nil) == nil, "Nothing picked yet")
    #expect(BrowserAppIcon.resourceName(preferenceValue: "removed") == nil, "A choice a later version dropped")
    #expect(BrowserAppIcon.resourceName(preferenceValue: "") == nil)
}

@Test func theSettingsStoreTheChoiceUnderTheKeyTheDockTileReads() throws {
    let suite = "BrowserAppIconTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("sunset", forKey: BrowserAppIcon.preferenceKey)
    let preferences = BrowserUserPreferencesStore(userDefaults: defaults)
    #expect(preferences.appIcon == .sunset)
}

@Test func theChangeNotificationIsNamedAfterTheApp() {
    let name = BrowserAppIcon.changedNotificationName(bundleIdentifier: "com.example.Browser")
    #expect(name.rawValue == "com.example.Browser.appIconChanged")
}
