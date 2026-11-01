// BrowserAppIcon.swift

import AppKit
import CoreImage

/// The Dock icon the user picked in Settings.
enum BrowserAppIcon: String, CaseIterable {
    case standard
    case ring
    case monogram
    case neon
    case candy
    case forest

    // MARK: Internal

    var title: String {
        switch self {
        case .standard: BrowserStrings.appIconStandard
        case .ring: BrowserStrings.appIconRing
        case .monogram: BrowserStrings.appIconMonogram
        case .neon: BrowserStrings.appIconNeon
        case .candy: BrowserStrings.appIconCandy
        case .forest: BrowserStrings.appIconForest
        }
    }

    /// The bundle's icon for `standard`, or one of the shipped images, with its hue turned.
    var image: NSImage? {
        switch self {
        case .standard: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        case .ring: Self.shipped("openarc-icon-ring")
        case .monogram: Self.shipped("openarc-icon-monogram")
        case .neon: Self.turned("openarc-icon-ring", radians: 2.2)
        case .candy: Self.turned("openarc-icon-ring", radians: -1)
        case .forest: Self.turned("openarc-icon-monogram", radians: 1.6)
        }
    }

    // MARK: Private

    private static func shipped(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    private static func turned(_ name: String, radians: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let input = CIImage(contentsOf: url),
              let filter = CIFilter(name: "CIHueAdjust")
        else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radians, forKey: kCIInputAngleKey)
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    @MainActor func apply() {
        if let image {
            NSApp.applicationIconImage = image
        }
    }
}
