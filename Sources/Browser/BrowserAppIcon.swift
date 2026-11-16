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

    // MARK: Private

    /// A decoded icon handed to the main thread, which alone uses it from then on.
    private struct DecodedIcon: @unchecked Sendable {
        let image: NSImage
    }

    /// The latest `apply()`, so an earlier pick decoded later is not shown.
    @MainActor private static var applyGeneration = 0

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
        default: imageURL.flatMap(NSImage.init(contentsOf:))
        }
    }

    private var imageURL: URL? {
        Bundle.main.url(forResource: "openarc-icon-\(rawValue)", withExtension: "png")
    }

    /// The Dock draws icons at most 512 pixels wide.
    nonisolated static func dockImage(contentsOf url: URL) -> NSImage? {
        BrowserImageThumbnailer.image(
            contentsOf: url,
            maximumPixelSize: BrowserImageThumbnailer.macOSApplicationIconCanvasSize,
        )
    }

    @MainActor func apply() {
        Self.applyGeneration &+= 1
        guard self != .standard, let url = imageURL else {
            if let image {
                NSApp.applicationIconImage = image
            }
            return
        }
        // Drawing the full picture into the Dock took over a frame at launch,
        // before the window showed; it is decoded at the Dock's size meanwhile.
        let generation = Self.applyGeneration
        Task.detached(priority: .userInitiated) {
            guard let icon = Self.dockImage(contentsOf: url).map(DecodedIcon.init) else { return }
            await MainActor.run {
                guard generation == Self.applyGeneration else { return }
                NSApp.applicationIconImage = icon.image
            }
        }
    }
}
