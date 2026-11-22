// BrowserMobileAppIcon.swift

import UIKit

/// The Home Screen icons to choose from, the same set the Mac's Settings
/// offers. `script/app_icon/make_icons.py` draws each one's app icon set and
/// its picture for the picker.
enum BrowserMobileAppIcon: String, CaseIterable {
    case original
    case candy
    case neon
    case hologram
    case sunset
    case sticker
    case monochrome

    // MARK: Internal

    /// The one the Home Screen shows now.
    @MainActor static var current: BrowserMobileAppIcon {
        icon(alternateIconName: UIApplication.shared.alternateIconName)
    }

    /// The app icon set's name, nil for the bundle's own icon.
    var alternateIconName: String? {
        self == .original ? nil : "AppIcon-\(rawValue.capitalized)"
    }

    var title: String {
        switch self {
        case .original: String(localized: "Original", table: "Mobile")
        case .candy: String(localized: "Candy", table: "Mobile")
        case .neon: String(localized: "Neon", table: "Mobile")
        case .hologram: String(localized: "Hologram", table: "Mobile")
        case .sunset: String(localized: "Sunset", table: "Mobile")
        case .sticker: String(localized: "Sticker", table: "Mobile")
        case .monochrome: String(localized: "Monochrome", table: "Mobile")
        }
    }

    /// The icon's picture, a full square that the picker rounds.
    var preview: UIImage? {
        UIImage(named: "AppIconPreview-\(rawValue.capitalized)")
    }

    /// The icon for an alternate icon name; an unknown one is the Original.
    static func icon(alternateIconName: String?) -> BrowserMobileAppIcon {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .original
    }

    /// Puts the icon on the Home Screen; iOS confirms the change with its own alert.
    /// Returns whether the Home Screen shows it now.
    @MainActor @discardableResult static func choose(_ icon: BrowserMobileAppIcon) async -> Bool {
        let application = UIApplication.shared
        guard icon != current else { return true }
        guard application.supportsAlternateIcons else { return false }
        do {
            try await application.setAlternateIconName(icon.alternateIconName)
            return true
        } catch {
            return false
        }
    }
}
