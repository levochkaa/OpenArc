// BrowserSpaceColor.swift

import AppKit

// MARK: - BrowserSpaceColor

/// Space theme: a light tint over the neutral window background. A Space
/// without one stays neutral.
enum BrowserSpaceColor: String, CaseIterable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case gray

    // MARK: Internal

    var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .gray: .systemGray
        }
    }

    var title: String {
        switch self {
        case .blue: BrowserStrings.spaceColorBlue
        case .purple: BrowserStrings.spaceColorPurple
        case .pink: BrowserStrings.spaceColorPink
        case .red: BrowserStrings.spaceColorRed
        case .orange: BrowserStrings.spaceColorOrange
        case .yellow: BrowserStrings.spaceColorYellow
        case .green: BrowserStrings.spaceColorGreen
        case .teal: BrowserStrings.spaceColorTeal
        case .gray: BrowserStrings.spaceColorGray
        }
    }

    /// How strongly the tint covers the window background; dark windows need more.
    static func tintAlpha(dark: Bool) -> CGFloat { dark ? 0.2 : 0.14 }
}
