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

enum BrowserChromePalette {
    // MARK: Internal

    static let solidBackground = adaptive(light: rgb(246, 247, 249), dark: rgb(0, 0, 0))
    static let shellBackground = solidBackground
    static let sidebarBackground = solidBackground
    static let contentBackground = adaptive(light: rgb(255, 255, 255), dark: rgb(20, 20, 22))
    static let rowHover = adaptive(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.08))
    static let rowSelected = adaptive(light: rgba(0, 0, 0, 0.11), dark: rgba(255, 255, 255, 0.14))
    static let currentURLRow = adaptive(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.1))
    static let currentURLRowHover = adaptive(light: rgba(0, 0, 0, 0.08), dark: rgba(255, 255, 255, 0.12))
    static let currentURLButtonHover = adaptive(light: rgba(0, 0, 0, 0.1), dark: rgba(255, 255, 255, 0.16))
    static let currentURLRowResolved = adaptive(light: rgb(233, 234, 236), dark: rgb(25, 25, 25))
    static let currentURLRowHoverResolved = adaptive(light: rgb(226, 228, 231), dark: rgb(31, 31, 31))
    static let currentURLButtonHoverResolved = adaptive(light: rgb(217, 220, 224), dark: rgb(41, 41, 41))
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
    static let bookmarksBarBackground = adaptive(light: rgba(246, 247, 249, 0.94), dark: rgba(0, 0, 0, 0.86))
    static let bookmarksBarBorder = adaptive(light: rgba(0, 0, 0, 0.1), dark: rgba(255, 255, 255, 0.1))
    static let incognitoBannerBackground = Color.black
    static let incognitoBannerBorder = Color.white.opacity(0.12)
    static let incognitoBannerText = Color.white.opacity(0.86)
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

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
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
    static let currentURLRowCornerRadius: CGFloat = 12
    static let sidebarRowHorizontalPadding: CGFloat = 11
    static let sidebarTabTrailingPadding: CGFloat = 7
    static let sidebarRowContentSpacing: CGFloat = 8
    static let sidebarFaviconSize: CGFloat = 14
    static let sidebarPinnedURLIconButtonSize: CGFloat = sidebarRowHeight
    static let sidebarPinnedURLTextHoverOverlap: CGFloat = 4
    static let sidebarPinnedFolderTabIndent: CGFloat = 16
    static let sidebarPinnedFolderIconSize: CGFloat = 18
    static let sidebarPinnedFolderBadgeIconSize: CGFloat = 7.5
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
    static let sidebarCurrentURLExtensionIconSize: CGFloat = 16
    static let siteControlPopoverWidth: CGFloat = 284
    static let siteControlPopoverPadding: CGFloat = 16
    static let siteControlPopoverSpacing: CGFloat = 14
    static let extensionGridSpacing: CGFloat = 10
    static let extensionTileSize: CGFloat = 52
    static let extensionTileCornerRadius: CGFloat = 12
    static let extensionTileIconSize: CGFloat = 24
    static let extensionActionPopupWidth: CGFloat = 380
    static let extensionActionPopupHeight: CGFloat = 520
    static let extensionActionPopupCornerRadius: CGFloat = 12
    static let extensionSidePanelWidth: CGFloat = 360
    static let extensionSidePanelHeaderHeight: CGFloat = 38
    static let extensionSidePanelHeaderHorizontalPadding: CGFloat = 10
    static let extensionSidePanelHeaderIconSize: CGFloat = 16
    static let extensionSidePanelCloseButtonSize: CGFloat = 24
    static let appTabGridSpacing: CGFloat = 5
    static let appTabIconSize: CGFloat = 18
    static let sidebarCloseButtonSize: CGFloat = 22
    static let sidebarCloseButtonLeadingSpacing: CGFloat = 4
    static let sidebarCloseCornerRadius: CGFloat = 7
    static let sidebarCloseSymbolSize: CGFloat = 11
    static let sidebarDividerHeight: CGFloat = 14
    static let sidebarDropIndicatorThickness: CGFloat = 2
    static let sidebarEmptySectionDropZoneHeight: CGFloat = 14
    static let sidebarTabDragCoordinateSpaceName = "BrowserSidebarTabDragCoordinateSpace"
    static let sidebarTabDragMinimumDistance: CGFloat = 4
    static let sidebarTabDropVerticalSnapDistance: CGFloat = sidebarRowHeight * 0.62
    static let sidebarTabDropHorizontalTolerance: CGFloat = 48
    static let sidebarTabDropHysteresisDistance: CGFloat = 3
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
    static let bookmarksBarHeight: CGFloat = chromeButtonSize
    static let bookmarksBarHorizontalPadding: CGFloat = 6
    static let bookmarksBarItemSpacing: CGFloat = 2
    static let bookmarksBarControlSpacing: CGFloat = 4
    static let bookmarksBarLabelSpacing: CGFloat = 6
    static let bookmarksBarItemHeight: CGFloat = chromeButtonSize
    static let bookmarksBarItemMaximumWidth: CGFloat = 220
    static let bookmarksBarItemHorizontalPadding: CGFloat = 8
    static let bookmarksBarItemCornerRadius: CGFloat = 7
    static let bookmarksBarCornerRadius: CGFloat = 0
    static let bookmarksBarControlSize: CGFloat = chromeButtonSize
    static let bookmarksBarIconSize: CGFloat = 13
    static let bookmarksFolderMenuSiteIconSize: CGFloat = 16
    static let bookmarksBarContentGap: CGFloat = 6
    static let siteToolbarHeight: CGFloat = chromeButtonSize
    static let siteToolbarURLButtonMaximumWidth: CGFloat = 420
    static let incognitoBannerHeight: CGFloat = 30
    static let incognitoBannerIconSize: CGFloat = 12
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
    static let tooltipViewportPadding: CGFloat = 8
    static let tooltipMaximumWidth: CGFloat = 360

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
