// BrowserAppIcon.swift

import AppKit

/// The Dock icon the user picked in Settings. `script/app_icon/make_icons.py`
/// draws every icon; the bundle's own is the Original. The Dock tile plug-in
/// compiles this file too, so it uses no other app code but the thumbnailer.
enum BrowserAppIcon: String, CaseIterable {
    case standard
    case candy
    case neon
    case hologram
    case sunset
    case sticker
    case monochrome

    // MARK: Internal

    /// The defaults key in the app's domain that holds the choice.
    static let preferenceKey = "browser.settings.appIcon"

    /// The PNG in the app's Resources that draws this icon.
    var resourceName: String { "openarc-icon-\(rawValue)" }

    /// The Dock tile plug-in shows the choice again when the app posts this
    /// distributed notification, so the tile is right once the app quits.
    static func changedNotificationName(bundleIdentifier: String) -> Notification.Name {
        Notification.Name("\(bundleIdentifier).appIconChanged")
    }

    /// The PNG for a stored choice. The standard choice, a missing value and
    /// an unknown one keep the bundle's own icon and return nil.
    static func resourceName(preferenceValue: String?) -> String? {
        guard let icon = preferenceValue.flatMap(Self.init(rawValue:)), icon != .standard else {
            return nil
        }
        return icon.resourceName
    }

    /// The Dock draws icons at most 512 pixels wide.
    nonisolated static func dockImage(contentsOf url: URL) -> NSImage? {
        BrowserImageThumbnailer.image(
            contentsOf: url,
            maximumPixelSize: BrowserImageThumbnailer.macOSApplicationIconCanvasSize,
        )
    }
}
