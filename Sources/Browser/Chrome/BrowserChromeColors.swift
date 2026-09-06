import AppKit

// MARK: - BrowserChromeColors

enum BrowserChromeColors {
    // MARK: Internal

    static let solidBackground = adaptive(light: rgb(246, 247, 249), dark: rgb(0, 0, 0))
    static let contentBackground = adaptive(light: rgb(255, 255, 255), dark: rgb(20, 20, 22))
    static let rowHover = adaptive(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.08))
    static let rowSelected = adaptive(light: rgba(0, 0, 0, 0.11), dark: rgba(255, 255, 255, 0.14))
    static let currentURLRow = adaptive(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.1))
    static let currentURLRowHover = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgba(255, 255, 255, 0.12))
    static let currentURLButtonHover = adaptive(light: rgba(0, 0, 0, 0.1), dark: rgba(255, 255, 255, 0.16))
    static let rowCloseHover = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgba(255, 255, 255, 0.12))
    static let rowCloseForeground = adaptive(light: rgba(0, 0, 0, 0.68), dark: rgba(255, 255, 255, 0.82))
    static let sidebarDivider = adaptive(light: rgba(0, 0, 0, 0.12), dark: rgba(255, 255, 255, 0.12))
    static let sidebarOverlayBorder = adaptive(light: rgba(0, 0, 0, 0.18), dark: rgba(255, 255, 255, 0.28))
    static let sidebarTopChromeDivider = adaptive(light: rgba(0, 0, 0, 0.14), dark: rgba(255, 255, 255, 0.2))
    static let sidebarClearButtonForeground = adaptive(light: rgba(0, 0, 0, 0.34), dark: rgba(255, 255, 255, 0.3))
    static let sidebarDropIndicator = adaptive(light: rgba(0, 0, 0, 0.84), dark: rgba(255, 255, 255, 0.96))
    static let primaryText = adaptive(light: rgba(0, 0, 0, 0.86), dark: rgba(255, 255, 255, 0.92))
    static let secondaryText = adaptive(light: rgba(0, 0, 0, 0.5), dark: rgba(255, 255, 255, 0.58))
    static let currentURLText = adaptive(light: rgba(0, 0, 0, 0.54), dark: rgba(255, 255, 255, 0.5))
    static let buttonBackground = adaptive(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.1))
    static let buttonHoverBackground = adaptive(light: rgba(0, 0, 0, 0.1), dark: rgba(255, 255, 255, 0.16))
    static let buttonBorder = adaptive(light: rgba(0, 0, 0, 0.12), dark: rgba(255, 255, 255, 0.12))
    static let buttonHoverBorder = adaptive(light: rgba(0, 0, 0, 0.18), dark: rgba(255, 255, 255, 0.2))
    static let buttonDisabledForeground = adaptive(light: rgba(0, 0, 0, 0.26), dark: rgba(255, 255, 255, 0.32))
    static let chromeButtonHoverBackground = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgba(255, 255, 255, 0.14))
    static let chromeButtonPressedBackground = adaptive(light: rgba(0, 0, 0, 0.12), dark: rgba(255, 255, 255, 0.2))
    static let chromeButtonHoverForeground = adaptive(light: rgba(0, 0, 0, 0.92), dark: rgba(255, 255, 255, 0.98))
    static let chromeButtonPressedForeground = adaptive(light: rgb(0, 0, 0), dark: rgb(255, 255, 255))
    static let chromeButtonHighlightGlow = adaptive(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.1))
    static let resizeHandle = adaptive(light: rgba(0, 0, 0, 0.14), dark: rgba(255, 255, 255, 0.16))
    static let resizeHandleHover = adaptive(light: rgba(0, 0, 0, 0.24), dark: rgba(255, 255, 255, 0.28))
    static let commandBarBackdropTint = adaptive(light: rgba(255, 255, 255, 0.38), dark: rgba(0, 0, 0, 0.34))
    static let commandBarPanelTint = adaptive(light: rgba(255, 255, 255, 0.88), dark: rgba(0, 0, 0, 0.38))
    static let commandBarPanelBorder = adaptive(light: rgba(0, 0, 0, 0.14), dark: rgba(255, 255, 255, 0.12))
    static let commandBarFieldTint = adaptive(light: rgba(0, 0, 0, 0.05), dark: rgba(255, 255, 255, 0.06))
    static let commandBarFieldBorder = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgba(255, 255, 255, 0.08))
    static let commandBarPlaceholder = adaptive(light: rgba(0, 0, 0, 0.36), dark: rgba(255, 255, 255, 0.36))
    static let commandBarCompletion = adaptive(light: rgba(0, 0, 0, 0.48), dark: rgba(255, 255, 255, 0.5))
    static let commandBarSuggestionSelected = adaptive(light: rgba(0, 0, 0, 0.07), dark: rgba(255, 255, 255, 0.1))
    static let incognitoBannerBackground = NSColor.black
    static let incognitoBannerBorder = NSColor.white.withAlphaComponent(0.12)
    static let incognitoBannerText = NSColor.white.withAlphaComponent(0.86)
    static let findBarPanelTint = adaptive(light: rgba(255, 255, 255, 0.9), dark: rgba(0, 0, 0, 0.5))
    static let findBarPanelBorder = adaptive(light: rgba(0, 0, 0, 0.14), dark: rgba(255, 255, 255, 0.14))
    static let findBarFieldTint = adaptive(light: rgba(0, 0, 0, 0.05), dark: rgba(255, 255, 255, 0.08))
    static let findBarPlaceholder = adaptive(light: rgba(0, 0, 0, 0.38), dark: rgba(255, 255, 255, 0.4))
    static let tooltipBackground = adaptive(light: rgba(255, 255, 255, 0.98), dark: rgba(0, 0, 0, 0.96))
    static let tooltipBorder = adaptive(light: rgba(0, 0, 0, 0.18), dark: rgba(255, 255, 255, 0.22))
    static let tooltipText = adaptive(light: rgba(0, 0, 0, 0.88), dark: rgba(255, 255, 255, 0.96))
    static let tooltipCaption = adaptive(light: rgba(0, 0, 0, 0.56), dark: rgba(255, 255, 255, 0.56))
    static let tooltipShadow = adaptive(light: rgba(0, 0, 0, 0.16), dark: rgba(0, 0, 0, 0.3))
    static let tooltipKeyBackground = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgb(255, 255, 255))
    static let tooltipKeyText = adaptive(light: rgba(0, 0, 0, 0.88), dark: rgba(0, 0, 0, 0.92))
    static let tooltipKeyShadow = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgba(0, 0, 0, 0.12))

    // MARK: Private

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        rgba(red, green, blue, 1)
    }

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }
}
