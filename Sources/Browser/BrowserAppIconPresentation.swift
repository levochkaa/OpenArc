// BrowserAppIconPresentation.swift

import AppKit

extension BrowserAppIcon {
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
        Bundle.main.url(forResource: resourceName, withExtension: "png")
    }

    @MainActor func apply() {
        Self.applyGeneration &+= 1
        Self.postChange()
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

    /// Tells the Dock tile plug-in to read the stored choice again.
    private static func postChange() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        DistributedNotificationCenter.default().postNotificationName(
            changedNotificationName(bundleIdentifier: bundleIdentifier),
            object: nil,
            userInfo: nil,
            deliverImmediately: true,
        )
    }
}
