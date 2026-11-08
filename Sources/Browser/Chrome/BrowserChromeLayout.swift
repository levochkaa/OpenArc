// BrowserChromeLayout.swift

import AppKit

// MARK: - BrowserChromeLayout

enum BrowserChromeLayout {
    static let sidebarSpaceTitleXWithoutIcon: CGFloat = 5
    static let spaceCreationRowCornerRadius: CGFloat = 8
    /// Where the theme editor attaches beside the sidebar: the Space title's height.
    static let spaceThemeEditorAnchorY: CGFloat = 99
    static let sidebarAnimationDuration = 0.18
    static let sidebarResizeHoverDelayNanoseconds: UInt64 = 500_000_000
    static let sidebarHoverRevealDelayNanoseconds: UInt64 = 70_000_000
    static let leadingContentCornerRadius: CGFloat = BrowserWindowGeometry.browserContentCornerRadius
    static let sidebarOuterPadding: CGFloat = 8
    static let sidebarSectionSpacing: CGFloat = 10
    static let sidebarListSpacing: CGFloat = 5
    /// From the header to the Space title.
    static let sidebarListTopSpacing: CGFloat = 8
    /// From the Space title to the first row.
    static let sidebarListEndInset: CGFloat = 5
    static let sidebarRowHeight: CGFloat = 36
    static let sidebarRowCornerRadius: CGFloat = 12
    static let currentURLRowCornerRadius: CGFloat = 12
    static let sidebarRowHorizontalPadding: CGFloat = 10
    static let sidebarTabTrailingPadding: CGFloat = 8
    static let sidebarRowContentSpacing: CGFloat = 8
    static let sidebarFaviconSize: CGFloat = 16
    /// Icons center in this leading column and titles start after it.
    static let sidebarRowLeadingColumnWidth: CGFloat = sidebarRowHeight
    /// Labels draw their text 2 pt inside their frame.
    static let sidebarRowTitleX: CGFloat = sidebarRowLeadingColumnWidth - 2
    static let sidebarRowFontSize: CGFloat = 14
    static let sidebarSpaceFontSize: CGFloat = 13
    static let sidebarSpaceSymbolSize: CGFloat = 14
    static let sidebarPinnedURLIconButtonSize: CGFloat = sidebarRowHeight
    static let sidebarPinnedURLTextHoverOverlap: CGFloat = 4
    static let sidebarPinnedFolderTabIndent: CGFloat = 16
    static let sidebarPinnedFolderIconSize: CGFloat = 21
    static let sidebarPinnedFolderBadgeIconSize: CGFloat = 7.5
    static let sidebarButtonPressedScale: CGFloat = 0.985
    static let sidebarRenameActivationGraceInterval: TimeInterval = 0.25
    static let sidebarCloseButtonPressedScale: CGFloat = 0.92
    static let sidebarNewTabSymbolSize: CGFloat = 15.5
    static let sidebarCurrentURLOverlayWidth: CGFloat = 76
    static let sidebarCurrentURLOverlaySolidWidth: CGFloat = 66
    static let sidebarCurrentURLOverlayFadeWidth: CGFloat = 16
    /// The address fades out this far from the row's end while the actions are away.
    static let sidebarCurrentURLRestingTrailingWidth: CGFloat = 3
    static let sidebarCurrentURLButtonSpacing: CGFloat = 0
    static let sidebarCurrentURLButtonTrailingPadding: CGFloat = 5
    static let sidebarCurrentURLTextLeading: CGFloat = 11
    /// With no tab the address row shows a magnifier and the search placeholder.
    static let sidebarAddressPlaceholderIconCenterX: CGFloat = 18
    static let sidebarAddressPlaceholderIconPointSize: CGFloat = 12.5
    static let sidebarAddressPlaceholderTextLeading: CGFloat = 32
    static let sidebarCurrentURLButtonSize: CGFloat = 28
    static let sidebarCurrentURLButtonCornerRadius: CGFloat = 9
    static let sidebarCurrentURLButtonSymbolSize: CGFloat = 14
    static let sidebarCurrentURLExtensionIconSize: CGFloat = 16
    static let siteControlPopoverWidth: CGFloat = 236
    static let siteControlPopoverPadding: CGFloat = 10
    static let siteControlPopoverSpacing: CGFloat = 10
    /// Page actions, extension tiles and the footer's chip share this height.
    static let siteControlItemHeight: CGFloat = 32
    static let siteControlSettingRowHeight: CGFloat = 43
    static let extensionGridSpacing: CGFloat = 8
    static let extensionTileSize: CGFloat = 48
    static let extensionTileCornerRadius: CGFloat = 8
    static let extensionTileIconSize: CGFloat = 16
    /// The size until the page reports its own.
    static let extensionActionPopupWidth: CGFloat = 320
    static let extensionActionPopupHeight: CGFloat = 200
    static let extensionActionPopupCornerRadius: CGFloat = 12
    static let extensionSidePanelWidth: CGFloat = 360
    static let extensionSidePanelHeaderHeight: CGFloat = 38
    static let extensionSidePanelHeaderHorizontalPadding: CGFloat = 10
    static let extensionSidePanelHeaderIconSize: CGFloat = 16
    static let extensionSidePanelCloseButtonSize: CGFloat = 24
    static let appTabGridSpacing: CGFloat = 8
    static let appTabIconSize: CGFloat = 18
    static let sidebarCloseButtonSize: CGFloat = 24
    /// Mini player: a 32 pt row of 24 pt controls, 66 pt with the
    /// title row it shows on hover.
    static let sidebarMiniPlayerHeight: CGFloat = 32
    static let sidebarMiniPlayerExpandedHeight: CGFloat = 66
    static let sidebarMiniPlayerButtonSize: CGFloat = 24
    static let sidebarMiniPlayerInset: CGFloat = 10
    static let sidebarMiniPlayerSpacing: CGFloat = 6
    /// Ends past the title's trailing edge, which it then cuts short.
    static let sidebarCloseButtonTrailingPadding: CGFloat = 6
    static let sidebarCloseButtonLeadingSpacing: CGFloat = 4
    static let sidebarCloseCornerRadius: CGFloat = 6
    static let sidebarCloseSymbolSize: CGFloat = 11
    static let sidebarDividerHeight: CGFloat = 12
    static let sidebarClearFontSize: CGFloat = 10
    static let sidebarDividerInset: CGFloat = 10
    static let sidebarDividerThickness: CGFloat = 0.5
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
    /// Space between the divider's end and Clear's arrow or title.
    static let sidebarClearLineGap: CGFloat = 6
    static let sidebarClearButtonVerticalPadding: CGFloat = 2
    static let sidebarTopChromeDividerHeight: CGFloat = 1
    static let sidebarTopChromeDividerScrollThreshold: CGFloat = 0.5
    static let sidebarBottomChromeTopSpacing: CGFloat = sidebarSectionSpacing / 2
    static let sidebarResizeHitWidth: CGFloat = sidebarOuterPadding
    static let sidebarHoverRevealWidth: CGFloat = browserContentEdgeInset
    static let sidebarHoverOverlayEdgeInset: CGFloat = 5
    static let detachedSidebarWindowBorderInset: CGFloat = 1
    static let sidebarOverlayBorderWidth: CGFloat = 1
    static let sidebarOverlayCornerRadius: CGFloat = 12
    /// The sidebar edge snaps to the default width within 14 pt.
    static let sidebarSnapThreshold: CGFloat = 14
    /// Dragging the sidebar edge below this width hides the sidebar (82 pt).
    static let sidebarCollapseDragWidth: CGFloat = 82
    static let browserContentEdgeInset: CGFloat = BrowserWindowGeometry.browserContentEdgeInset
    static let contentShadowRadius: CGFloat = 3
    static let contentShadowOpacity: Float = 0.25
    static let contentShadowOffset: CGFloat = 1
    /// Header and dock buttons, 34 pt apart.
    static let sidebarChromeButtonSize: CGFloat = 32
    static let sidebarChromeButtonSpacing: CGFloat = 2
    static let sidebarChromeButtonCornerRadius: CGFloat = 6
    static let sidebarChromeSymbolSize: CGFloat = 15.5
    /// A Space's dock item is wider than the buttons, so the icons stay 34 pt apart.
    static let sidebarDockItemWidth: CGFloat = 34
    /// Lifts the header buttons so their center lines up with the window controls.
    static let sidebarHeaderButtonY: CGFloat = -0.5
    /// The reload button reaches past the URL field's trailing edge.
    static let sidebarHeaderTrailingOverhang: CGFloat = 2
    static let sidebarWindowControlsLeading: CGFloat = 5
    static let sidebarWindowControlsToggleGap: CGFloat = -2
    static let sidebarDockTopInset: CGFloat = 9
    static let sidebarDockBottomInset: CGFloat = 1
    static let chromeButtonSize: CGFloat = 28
    static let chromeButtonSymbolSize: CGFloat = 13.5
    static let chromeButtonCornerRadius: CGFloat = 9
    static let chromeButtonSpacing: CGFloat = 6
    static let windowControlsTrailingGap: CGFloat = 5
    static let commandBarWidth: CGFloat = 763
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
    static let commandBarCornerRadius: CGFloat = 14
    static let commandBarShadowRadius: CGFloat = 40
    static let commandBarTopInsetMinimum: CGFloat = 92
    static let commandBarTopInsetMaximum: CGFloat = 184
    static let commandBarTopInsetFraction: CGFloat = 0.22
    static let commandBarOuterPadding: CGFloat = 4
    static let commandBarFieldHeight: CGFloat = 60
    static let commandBarTextFieldVerticalOffset: CGFloat = 4
    static let commandBarFieldCornerRadius: CGFloat = 14
    static let commandBarRowHorizontalPadding: CGFloat = 13
    static let commandBarRowContentSpacing: CGFloat = 12
    static let commandBarRowVerticalPadding: CGFloat = 12
    static let commandBarFieldLeading: CGFloat = 22
    static let commandBarSymbolSize: CGFloat = 14
    static let commandBarSymbolWidth: CGFloat = 18
    static let commandBarSuggestionRowHeight: CGFloat = 46
    static let commandBarSuggestionSpacing: CGFloat = 4
    static let commandBarSuggestionVerticalInset: CGFloat = commandBarOuterPadding * 2
    /// Scroll inset around the suggestion table. Table row rects include half the row spacing above and below,
    /// so this inset plus that half equals the visible vertical inset.
    static let commandBarSuggestionScrollInset: CGFloat = commandBarSuggestionVerticalInset
        - commandBarSuggestionSpacing / 2
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
    /// Find in page: a 300 x 32 pt bar 10 pt inside the page's top trailing corner.
    static let findBarWidth: CGFloat = 300
    static let findBarHeight: CGFloat = 32
    static let findBarTopInset: CGFloat = 10
    static let findBarTrailingInset: CGFloat = 10
    static let findBarCornerRadius: CGFloat = 5
    static let findBarSymbolSize: CGFloat = 13
    static let findBarSymbolLeading: CGFloat = 10
    static let findBarTextLeading: CGFloat = 32
    static let findBarButtonSize: CGFloat = 22
    static let findBarButtonSymbolSize: CGFloat = 12
    /// Centers of the trailing controls, from the bar's trailing edge.
    static let findBarCloseCenterInset: CGFloat = 15.75
    static let findBarDividerInset: CGFloat = 30.5
    static let findBarNextCenterInset: CGFloat = 48.25
    static let findBarPreviousCenterInset: CGFloat = 74.25
    /// The match count ends this far before the previous button's glyph.
    static let findBarCountGap: CGFloat = 14.5
    static let findBarNotFoundGap: CGFloat = 6
    static let findBarDividerHeight: CGFloat = 18
    static let tooltipCornerRadius: CGFloat = 14
    static let tooltipTopLeadingCornerRadius: CGFloat = 3
    /// The panel's room for the shadows around the bubble.
    static let tooltipPanelMargin: CGFloat = 32.5
    static let tooltipTitleFontSize: CGFloat = 12
    static let tooltipCaptionFontSize: CGFloat = 11
    static let tooltipKeyFontSize: CGFloat = 11
    static let tooltipOuterShadowRadius: CGFloat = 10
    static let tooltipOuterShadowOpacity: Float = 0.15
    static let tooltipOuterShadowOffset: CGFloat = 2.5
    static let tooltipInnerShadowRadius: CGFloat = 2.5
    static let tooltipInnerShadowOpacity: Float = 0.18
    static let tooltipVerticalGap: CGFloat = 3.5
    static let tooltipHorizontalPadding: CGFloat = 10
    /// Around one line of text, and around a title with a caption.
    static let tooltipVerticalPadding: CGFloat = 6.5
    static let tooltipCaptionVerticalPadding: CGFloat = 7
    static let tooltipContentSpacing: CGFloat = 6
    static let tooltipKeySpacing: CGFloat = 3
    static let tooltipKeyHeight: CGFloat = 19
    static let tooltipKeyCornerRadius: CGFloat = 4
    static let tooltipKeyFaceCornerRadius: CGFloat = 3
    static let tooltipKeyFaceInset: CGFloat = 1
    static let tooltipKeyFaceHeight: CGFloat = 15.5
    static let tooltipKeyHorizontalPadding: CGFloat = 4
    static let tooltipBorderWidth: CGFloat = 1
    static let tooltipAnchorXFraction: CGFloat = 0.8
    /// A sidebar row's tooltip starts near the row's middle.
    static let sidebarRowTooltipAnchorXFraction: CGFloat = 0.49
    static let tooltipAnchorYFraction: CGFloat = 0.8125
    static let tooltipViewportPadding: CGFloat = 8
    static let tooltipMaximumWidth: CGFloat = 360
}
