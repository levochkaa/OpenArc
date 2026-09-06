import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserChromeBackgroundMode

enum BrowserChromeBackgroundMode: Hashable {
    case blurred
    case black
}

// MARK: - BrowserChromeBackgroundView

struct BrowserChromeBackgroundView: View {
    // MARK: Internal

    let mode: BrowserChromeBackgroundMode

    var body: some View {
        content
            .id(BrowserChromeBackgroundIdentity(mode: mode, colorScheme: colorScheme))
    }

    // MARK: Private

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var content: some View {
        switch mode {
        case .blurred:
            BrowserVisualEffectView(material: colorScheme == .dark ? .hudWindow : .sidebar, blendingMode: .behindWindow)
        case .black:
            BrowserChromePalette.solidBackground
        }
    }
}

// MARK: - BrowserChromeBackgroundIdentity

private struct BrowserChromeBackgroundIdentity: Hashable {
    let mode: BrowserChromeBackgroundMode
    let colorScheme: ColorScheme
}

// MARK: - BrowserChromePalette

/// Temporary SwiftUI adapter; AppKit owns the shared design tokens.
enum BrowserChromePalette {
    static let solidBackground = Color(nsColor: BrowserChromeColors.solidBackground)
    static let contentBackground = Color(nsColor: BrowserChromeColors.contentBackground)
    static let rowHover = Color(nsColor: BrowserChromeColors.rowHover)
    static let rowSelected = Color(nsColor: BrowserChromeColors.rowSelected)
    static let currentURLRow = Color(nsColor: BrowserChromeColors.currentURLRow)
    static let currentURLRowHover = Color(nsColor: BrowserChromeColors.currentURLRowHover)
    static let currentURLButtonHover = Color(nsColor: BrowserChromeColors.currentURLButtonHover)
    static let rowCloseHover = Color(nsColor: BrowserChromeColors.rowCloseHover)
    static let rowCloseForeground = Color(nsColor: BrowserChromeColors.rowCloseForeground)
    static let sidebarDivider = Color(nsColor: BrowserChromeColors.sidebarDivider)
    static let sidebarOverlayBorder = Color(nsColor: BrowserChromeColors.sidebarOverlayBorder)
    static let sidebarTopChromeDivider = Color(nsColor: BrowserChromeColors.sidebarTopChromeDivider)
    static let sidebarClearButtonForeground = Color(nsColor: BrowserChromeColors.sidebarClearButtonForeground)
    static let sidebarDropIndicator = Color(nsColor: BrowserChromeColors.sidebarDropIndicator)
    static let primaryText = Color(nsColor: BrowserChromeColors.primaryText)
    static let secondaryText = Color(nsColor: BrowserChromeColors.secondaryText)
    static let currentURLText = Color(nsColor: BrowserChromeColors.currentURLText)
    static let buttonBackground = Color(nsColor: BrowserChromeColors.buttonBackground)
    static let buttonHoverBackground = Color(nsColor: BrowserChromeColors.buttonHoverBackground)
    static let buttonBorder = Color(nsColor: BrowserChromeColors.buttonBorder)
    static let buttonHoverBorder = Color(nsColor: BrowserChromeColors.buttonHoverBorder)
    static let buttonDisabledForeground = Color(nsColor: BrowserChromeColors.buttonDisabledForeground)
    static let chromeButtonHoverBackground = Color(nsColor: BrowserChromeColors.chromeButtonHoverBackground)
    static let chromeButtonPressedBackground = Color(nsColor: BrowserChromeColors.chromeButtonPressedBackground)
    static let chromeButtonHoverForeground = Color(nsColor: BrowserChromeColors.chromeButtonHoverForeground)
    static let chromeButtonPressedForeground = Color(nsColor: BrowserChromeColors.chromeButtonPressedForeground)
    static let chromeButtonHighlightGlow = Color(nsColor: BrowserChromeColors.chromeButtonHighlightGlow)
    static let resizeHandle = Color(nsColor: BrowserChromeColors.resizeHandle)
    static let resizeHandleHover = Color(nsColor: BrowserChromeColors.resizeHandleHover)
    static let commandBarBackdropTint = Color(nsColor: BrowserChromeColors.commandBarBackdropTint)
    static let commandBarPanelTint = Color(nsColor: BrowserChromeColors.commandBarPanelTint)
    static let commandBarPanelBorder = Color(nsColor: BrowserChromeColors.commandBarPanelBorder)
    static let commandBarFieldTint = Color(nsColor: BrowserChromeColors.commandBarFieldTint)
    static let commandBarFieldBorder = Color(nsColor: BrowserChromeColors.commandBarFieldBorder)
    static let commandBarPlaceholder = Color(nsColor: BrowserChromeColors.commandBarPlaceholder)
    static let commandBarCompletion = Color(nsColor: BrowserChromeColors.commandBarCompletion)
    static let commandBarSuggestionSelected = Color(nsColor: BrowserChromeColors.commandBarSuggestionSelected)
    static let incognitoBannerBackground = Color(nsColor: BrowserChromeColors.incognitoBannerBackground)
    static let incognitoBannerBorder = Color(nsColor: BrowserChromeColors.incognitoBannerBorder)
    static let incognitoBannerText = Color(nsColor: BrowserChromeColors.incognitoBannerText)
    static let findBarPanelTint = Color(nsColor: BrowserChromeColors.findBarPanelTint)
    static let findBarPanelBorder = Color(nsColor: BrowserChromeColors.findBarPanelBorder)
    static let findBarFieldTint = Color(nsColor: BrowserChromeColors.findBarFieldTint)
    static let findBarPlaceholder = Color(nsColor: BrowserChromeColors.findBarPlaceholder)
    static let tooltipBackground = Color(nsColor: BrowserChromeColors.tooltipBackground)
    static let tooltipBorder = Color(nsColor: BrowserChromeColors.tooltipBorder)
    static let tooltipText = Color(nsColor: BrowserChromeColors.tooltipText)
    static let tooltipCaption = Color(nsColor: BrowserChromeColors.tooltipCaption)
    static let tooltipShadow = Color(nsColor: BrowserChromeColors.tooltipShadow)
    static let tooltipKeyBackground = Color(nsColor: BrowserChromeColors.tooltipKeyBackground)
    static let tooltipKeyText = Color(nsColor: BrowserChromeColors.tooltipKeyText)
    static let tooltipKeyShadow = Color(nsColor: BrowserChromeColors.tooltipKeyShadow)
}

// MARK: - SwiftUI transition adapters

extension BrowserChromeLayout {
    static var sidebarTabDropListAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.82)
    }

    static var sidebarTabDragPreviewAnimation: Animation {
        .spring(response: 0.2, dampingFraction: 0.86)
    }

    static var sidebarTabVisibilityTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    static var currentURLCopyIconAnimation: Animation {
        .spring(response: 0.22, dampingFraction: 0.68)
    }
}
