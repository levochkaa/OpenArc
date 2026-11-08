// BrowserAppIcon.swift

import AppKit

/// The Dock icon the user picked in Settings. `script/app_icon/make_icons.py`
/// draws every icon; the bundle's own is the Original.
enum BrowserAppIcon: String, CaseIterable {
    case standard
    case candy
    case neon
    case hologram
    case sunset
    case sticker
    case monochrome

    // MARK: Internal

    static var choices: [Self] { allCases }

    var title: String {
        switch self {
        case .standard: BrowserStrings.appIconStandard
        case .candy: BrowserStrings.appIconCandy
        case .neon: BrowserStrings.appIconNeon
        case .hologram: BrowserStrings.appIconHologram
        case .sunset: BrowserStrings.appIconSunset
        case .sticker: BrowserStrings.appIconSticker
        case .monochrome: BrowserStrings.appIconMonochrome
        }
    }

    var image: NSImage? {
        switch self {
        case .standard: NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        default: Bundle.main
            .url(forResource: "openarc-icon-\(rawValue)", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
        }
    }

    @MainActor func apply() {
        if let image {
            NSApp.applicationIconImage = image
        }
    }
}
