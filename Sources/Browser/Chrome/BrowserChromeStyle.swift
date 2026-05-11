import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserChromeBackgroundMode

enum BrowserChromeBackgroundMode: Equatable {
    case blurred
    case black
}

// MARK: - BrowserChromeBackgroundView

struct BrowserChromeBackgroundView: View {
    let mode: BrowserChromeBackgroundMode

    var body: some View {
        switch mode {
        case .blurred:
            BrowserVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        case .black:
            BrowserChromePalette.solidBackground
        }
    }
}

// MARK: - BrowserChromePalette

enum BrowserChromePalette {
    static let solidBackground = Color.black
    static let shellBackground = solidBackground
    static let sidebarBackground = solidBackground
    static let contentBackground = Color.white
    static let rowHover = Color.white.opacity(0.08)
    static let rowSelected = Color.white.opacity(0.14)
    static let currentURLRow = Color.white.opacity(0.1)
    static let currentURLRowHover = Color.white.opacity(0.12)
    static let currentURLButtonHover = Color.white.opacity(0.16)
    static let currentURLRowResolved = Color(nsColor: NSColor(
        srgbRed: 25 / 255,
        green: 25 / 255,
        blue: 25 / 255,
        alpha: 1
    ))
    static let currentURLRowHoverResolved = Color(nsColor: NSColor(
        srgbRed: 31 / 255,
        green: 31 / 255,
        blue: 31 / 255,
        alpha: 1
    ))
    static let currentURLButtonHoverResolved = Color(nsColor: NSColor(
        srgbRed: 41 / 255,
        green: 41 / 255,
        blue: 41 / 255,
        alpha: 1
    ))
    static let rowCloseHover = Color.white.opacity(0.12)
    static let rowCloseForeground = Color.white.opacity(0.82)
    static let sidebarDivider = Color.white.opacity(0.12)
    static let sidebarOverlayBorder = Color.white.opacity(0.28)
    static let sidebarTopChromeDivider = Color.white.opacity(0.2)
    static let sidebarClearButtonForeground = Color.white.opacity(0.3)
    static let sidebarDropIndicator = Color.white.opacity(0.96)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
    static let currentURLText = Color.white.opacity(0.5)
    static let buttonBackground = Color.white.opacity(0.1)
    static let buttonHoverBackground = Color.white.opacity(0.16)
    static let buttonBorder = Color.white.opacity(0.12)
    static let buttonHoverBorder = Color.white.opacity(0.2)
    static let buttonDisabledForeground = Color.white.opacity(0.32)
    static let chromeButtonHoverBackground = Color.white.opacity(0.14)
    static let chromeButtonPressedBackground = Color.white.opacity(0.2)
    static let chromeButtonHoverForeground = Color.white.opacity(0.98)
    static let chromeButtonPressedForeground = Color.white
    static let chromeButtonHighlightGlow = Color.white.opacity(0.1)
    static let resizeHandle = Color.white.opacity(0.16)
    static let resizeHandleHover = Color.white.opacity(0.28)
    static let commandBarBackdropTint = Color.black.opacity(0.34)
    static let commandBarPanelTint = Color.black.opacity(0.38)
    static let commandBarPanelBorder = Color.white.opacity(0.12)
    static let commandBarFieldTint = Color.white.opacity(0.06)
    static let commandBarFieldBorder = Color.white.opacity(0.08)
    static let commandBarPlaceholder = Color.white.opacity(0.36)
    static let commandBarCompletion = Color.white.opacity(0.5)
    static let commandBarSuggestionSelected = Color.white.opacity(0.1)
    static let findBarPanelTint = Color.black.opacity(0.5)
    static let findBarPanelBorder = Color.white.opacity(0.14)
    static let findBarFieldTint = Color.white.opacity(0.08)
    static let findBarPlaceholder = Color.white.opacity(0.4)
    static let tooltipBackground = Color.black.opacity(0.96)
    static let tooltipBorder = Color.white.opacity(0.22)
    static let tooltipText = Color.white.opacity(0.96)
    static let tooltipCaption = Color.white.opacity(0.56)
    static let tooltipShadow = Color.black.opacity(0.3)
    static let tooltipKeyBackground = Color.white
    static let tooltipKeyText = Color.black.opacity(0.92)
    static let tooltipKeyShadow = Color.black.opacity(0.12)
}

// MARK: - BrowserChromeLayout

enum BrowserChromeLayout {
    static let sidebarAnimationDuration = 0.18
    static let sidebarResizeHoverDelayNanoseconds: UInt64 = 500_000_000
    static let sidebarHoverRevealDelayNanoseconds: UInt64 = 500_000_000
    static let leadingContentCornerRadius: CGFloat = BrowserWindowGeometry.browserContentCornerRadius
    static let sidebarOuterPadding: CGFloat = 8
    static let sidebarSectionSpacing: CGFloat = 10
    static let sidebarListSpacing: CGFloat = 5
    static let sidebarRowHeight: CGFloat = 36
    static let sidebarRowCornerRadius: CGFloat = 10
    static let sidebarRowHorizontalPadding: CGFloat = 11
    static let sidebarTabTrailingPadding: CGFloat = 7
    static let sidebarRowContentSpacing: CGFloat = 8
    static let sidebarFaviconSize: CGFloat = 14
    static let sidebarButtonPressedScale: CGFloat = 0.985
    static let sidebarRenameActivationGraceInterval: TimeInterval = 0.25
    static let sidebarCloseButtonPressedScale: CGFloat = 0.92
    static let sidebarNewTabSymbolSize: CGFloat = 14
    static let sidebarCurrentURLOverlayWidth: CGFloat = 76
    static let sidebarCurrentURLOverlaySolidWidth: CGFloat = 66
    static let sidebarCurrentURLOverlayFadeWidth: CGFloat = 10
    static let sidebarCurrentURLButtonSpacing: CGFloat = 2
    static let sidebarCurrentURLButtonSize: CGFloat = 26
    static let sidebarCurrentURLButtonCornerRadius: CGFloat = 8
    static let sidebarCurrentURLButtonSymbolSize: CGFloat = 12.5
    static let siteControlPopoverWidth: CGFloat = 284
    static let siteControlPopoverPadding: CGFloat = 16
    static let siteControlPopoverSpacing: CGFloat = 14
    static let extensionGridSpacing: CGFloat = 10
    static let extensionTileSize: CGFloat = 52
    static let extensionTileCornerRadius: CGFloat = 12
    static let extensionTileIconSize: CGFloat = 24
    static let appTabGridSpacing: CGFloat = 5
    static let appTabIconSize: CGFloat = 18
    static let sidebarCloseButtonSize: CGFloat = 22
    static let sidebarCloseButtonLeadingSpacing: CGFloat = 4
    static let sidebarCloseCornerRadius: CGFloat = 7
    static let sidebarCloseSymbolSize: CGFloat = 11
    static let sidebarDividerHeight: CGFloat = 24
    static let sidebarDropIndicatorThickness: CGFloat = 2
    static let sidebarEmptySectionDropZoneHeight: CGFloat = 14
    static let sidebarTabDragCoordinateSpaceName = "BrowserSidebarTabDragCoordinateSpace"
    static let sidebarTabDragMinimumDistance: CGFloat = 4
    static let sidebarTabDropVerticalSnapDistance: CGFloat = sidebarRowHeight * 0.62
    static let sidebarTabDropHorizontalTolerance: CGFloat = 48
    static let sidebarDragPreviewShadowRadius: CGFloat = 14
    static let sidebarDragPreviewShadowY: CGFloat = 8
    static let sidebarClearButtonHorizontalPadding: CGFloat = 8
    static let sidebarClearButtonVerticalPadding: CGFloat = 2
    static let sidebarTopChromeDividerHeight: CGFloat = 1
    static let sidebarTopChromeDividerScrollThreshold: CGFloat = 0.5
    static let sidebarBottomChromeTopSpacing: CGFloat = sidebarSectionSpacing / 2
    static let sidebarResizeHitWidth: CGFloat = sidebarOuterPadding
    static let sidebarHoverRevealWidth: CGFloat = browserContentEdgeInset
    static let sidebarHoverOverlayEdgeInset: CGFloat = browserContentEdgeInset
    static let detachedSidebarWindowBorderInset: CGFloat = 1
    static let sidebarOverlayBorderWidth: CGFloat = 1
    static let sidebarOverlayCornerRadius: CGFloat = leadingContentCornerRadius
    static let sidebarSnapThreshold: CGFloat = 10
    static let browserContentEdgeInset: CGFloat = BrowserWindowGeometry.browserContentEdgeInset
    static let chromeButtonSize: CGFloat = 28
    static let chromeButtonSymbolSize: CGFloat = 13.5
    static let chromeButtonCornerRadius: CGFloat = 9
    static let chromeButtonSpacing: CGFloat = 6
    static let windowControlsTrailingGap: CGFloat = 5
    static let commandBarWidth: CGFloat = 720
    static let compactCommandBarMinimumSidebarMultiplier: CGFloat = 2
    static let compactCommandBarMaximumWindowFraction: CGFloat = 0.5
    static let compactCommandBarHorizontalViewportPadding: CGFloat = 12
    static let compactCommandBarTextWidthBuffer: CGFloat = 104
    static let compactCommandBarFieldHeight: CGFloat = 42
    static let compactCommandBarCornerRadius: CGFloat = 14
    static let compactCommandBarFontSize: CGFloat = 15
    static let compactCommandBarSymbolSize: CGFloat = 13
    static let compactCommandBarTopGap: CGFloat = 0
    static let compactCommandBarTextFieldVerticalOffset: CGFloat = 4
    static let commandBarCornerRadius: CGFloat = 20
    static let commandBarShadowRadius: CGFloat = 40
    static let commandBarTopInsetMinimum: CGFloat = 92
    static let commandBarTopInsetMaximum: CGFloat = 184
    static let commandBarTopInsetFraction: CGFloat = 0.22
    static let commandBarOuterPadding: CGFloat = 4
    static let commandBarFieldHeight: CGFloat = 52
    static let commandBarFieldCornerRadius: CGFloat = 14
    static let commandBarRowHorizontalPadding: CGFloat = 14
    static let commandBarRowContentSpacing: CGFloat = 12
    static let commandBarRowVerticalPadding: CGFloat = 12
    static let commandBarSymbolSize: CGFloat = 14
    static let commandBarSymbolWidth: CGFloat = 18
    static let commandBarSuggestionRowHeight: CGFloat = 42
    static let commandBarSuggestionSpacing: CGFloat = 4
    static let commandBarSuggestionVerticalInset: CGFloat = commandBarOuterPadding * 2
    static let commandBarSuggestionViewportAllowance: CGFloat = commandBarOuterPadding
    static let findBarWidth: CGFloat = 360
    static let findBarHeight: CGFloat = 42
    static let findBarFieldWidth: CGFloat = 202
    static let findBarTopInset: CGFloat = 12
    static let findBarTrailingInset: CGFloat = 12
    static let findBarHorizontalPadding: CGFloat = 10
    static let findBarCornerRadius: CGFloat = 12
    static let findBarFieldCornerRadius: CGFloat = 8
    static let findBarSymbolSize: CGFloat = 13
    static let findBarContentSpacing: CGFloat = 6
    static let tooltipCornerRadius: CGFloat = 12
    static let tooltipVerticalGap: CGFloat = 8
    static let tooltipHorizontalPadding: CGFloat = 12
    static let tooltipVerticalPadding: CGFloat = 10
    static let tooltipContentSpacing: CGFloat = 10
    static let tooltipKeySpacing: CGFloat = 6
    static let tooltipKeyHeight: CGFloat = 22
    static let tooltipKeyHorizontalPadding: CGFloat = 7
    static let tooltipBorderWidth: CGFloat = 0.5
    static let tooltipAnchorXFraction: CGFloat = 0.75
    static let tooltipAnchorYFraction: CGFloat = 0.75

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
