import AppKit
import QuartzCore
import SwiftUI

private enum BrowserChromePalette {
    static let shellBackground = Color.black
    static let sidebarBackground = Color.black
    static let contentBackground = Color.white
    static let rowHover = Color.white.opacity(0.08)
    static let rowSelected = Color.white.opacity(0.14)
    static let currentURLRow = Color.white.opacity(0.1)
    static let currentURLRowHover = Color.white.opacity(0.12)
    static let currentURLButtonHover = Color.white.opacity(0.16)
    static let currentURLRowResolved = Color(nsColor: NSColor(srgbRed: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1))
    static let currentURLRowHoverResolved = Color(nsColor: NSColor(srgbRed: 31 / 255, green: 31 / 255, blue: 31 / 255, alpha: 1))
    static let currentURLButtonHoverResolved = Color(nsColor: NSColor(srgbRed: 41 / 255, green: 41 / 255, blue: 41 / 255, alpha: 1))
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

private enum BrowserChromeLayout {
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
    static let sidebarButtonPressedScale: CGFloat = 0.985
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
    static var currentURLCopyIconAnimation: Animation {
        .spring(response: 0.22, dampingFraction: 0.68)
    }
}

private struct AnimationCompletionObserverModifier<Value: VectorArithmetic>: AnimatableModifier {
    var targetValue: Value
    var completion: (Value) -> Void

    var animatableData: Value {
        didSet {
            notifyCompletionIfFinished()
        }
    }

    init(observedValue: Value, completion: @escaping (Value) -> Void) {
        targetValue = observedValue
        animatableData = observedValue
        self.completion = completion
    }

    func body(content: Content) -> some View {
        content
    }

    private func notifyCompletionIfFinished() {
        guard animatableData == targetValue else {
            return
        }

        DispatchQueue.main.async {
            completion(targetValue)
        }
    }
}

private extension View {
    func onAnimationCompleted<Value: VectorArithmetic>(
        for value: Value,
        perform completion: @escaping (Value) -> Void
    ) -> some View {
        modifier(AnimationCompletionObserverModifier(observedValue: value, completion: completion))
    }

    func browserSidebarTabRowFrame(
        tabID: String,
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String?
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarTabRowFramePreferenceKey.self,
                    value: [
                        tabID: BrowserSidebarTabRowFrame(
                            tabID: tabID,
                            section: section,
                            sectionIndex: sectionIndex,
                            spaceID: spaceID,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarAppTabFrame(
        tabID: String,
        sectionIndex: Int
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarAppTabFramePreferenceKey.self,
                    value: [
                        tabID: BrowserSidebarAppTabFrame(
                            tabID: tabID,
                            sectionIndex: sectionIndex,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarAppTabsContainerFrame() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarAppTabsContainerFramePreferenceKey.self,
                    value: proxy.frame(
                        in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                    )
                )
            }
        }
    }

    func browserSidebarEmptySectionFrame(section: BrowserSidebarTabSection, spaceID: String?) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarEmptySectionFramePreferenceKey.self,
                    value: [
                        BrowserSidebarEmptySectionFrame(
                            section: section,
                            spaceID: spaceID,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    @ViewBuilder
    func browserWindowDragGesture(isEnabled: Bool = true) -> some View {
        if isEnabled {
            contentShape(Rectangle())
                .gesture(WindowDragGesture(), including: .gesture)
                .allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

private struct BrowserSidebarAppTabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: BrowserSidebarAppTabFrame] = [:]

    static func reduce(
        value: inout [String: BrowserSidebarAppTabFrame],
        nextValue: () -> [String: BrowserSidebarAppTabFrame]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

private struct BrowserSidebarAppTabsContainerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct BrowserSidebarTabRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: BrowserSidebarTabRowFrame] = [:]

    static func reduce(
        value: inout [String: BrowserSidebarTabRowFrame],
        nextValue: () -> [String: BrowserSidebarTabRowFrame]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

private struct BrowserSidebarEmptySectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [BrowserSidebarEmptySectionFrame] = []

    static func reduce(
        value: inout [BrowserSidebarEmptySectionFrame],
        nextValue: () -> [BrowserSidebarEmptySectionFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

struct BrowserRootView: View {
    @ObservedObject var model: BrowserChromeModel
    @ObservedObject private var commandBarModel: BrowserCommandBarModel
    @ObservedObject private var currentPageCommandBarModel: BrowserCommandBarModel
    @ObservedObject private var shortcutStore: BrowserShortcutStore
    @State private var showsSidebarWindowControls: Bool
    @State private var isWindowFullscreen = false
    @State private var isWindowFullscreenTransitioning = false
    @State private var isSidebarHoverOverlayPresented = false
    @State private var isSidebarHoverOverlayChromeVisible = false
    @State private var preservesSidebarHoverOverlayDuringFullscreenTransition = false
    @State private var isSidebarHoverOverlayPointerSyncSuspended = false
    @State private var isSidebarRevealEdgeHovered = false
    @State private var sidebarRevealHoverTaskID = 0
    @State private var currentURLRowWindowFrame: CGRect?
    @StateObject private var tooltipCoordinator = BrowserTooltipCoordinator()
    @ObservedObject private var faviconCache = BrowserFaviconCache.shared

    init(model: BrowserChromeModel) {
        self.model = model
        _commandBarModel = ObservedObject(wrappedValue: model.commandBarModel)
        _currentPageCommandBarModel = ObservedObject(wrappedValue: model.currentPageCommandBarModel)
        _shortcutStore = ObservedObject(wrappedValue: model.shortcutStore)
        _showsSidebarWindowControls = State(initialValue: model.isSidebarVisible)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BrowserContentView(
                    hostView: model.hostView,
                    isContextReady: model.isContextReady,
                    hasSelectedTab: model.selectedTabID != nil,
                    isSidebarVisible: model.isSidebarVisible,
                    usesWindowContentInsets: usesWindowContentInsets
                )
                .equatable()
                .frame(
                    width: browserContentWidth(in: proxy.size),
                    height: browserContentHeight(in: proxy.size),
                    alignment: .leading
                )
                .offset(x: browserContentMinX, y: browserContentMinY)
                .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)

                if usesInlineSidebarChrome {
                    BrowserSidebarChromeView(
                        model: model,
                        snapshot: sidebarSnapshot,
                        showsWindowControlsInSidebar: showsWindowControlsInSidebarChrome,
                        isCommandBarPresented: commandBarModel.isPresented,
                        isCurrentPageCommandBarPresented: currentPageCommandBarModel.isPresented,
                        isOverlayPresentation: isSidebarOverlayPresentation,
                        showsOverlayBorder: isSidebarHoverOverlayPresented,
                        onToggleSidebar: toggleSidebarFromChrome,
                        onURLRowFrameChange: { currentURLRowWindowFrame = $0 }
                    )
                    .frame(
                        width: model.sidebarWidth,
                        height: sidebarHeight(in: proxy.size),
                        alignment: .leading
                    )
                    .offset(x: sidebarOffset, y: sidebarOffsetY)
                    .allowsHitTesting(isSidebarPresented)
                    .zIndex(6)
                    .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: isSidebarHoverOverlayPresented
                    )
                }

                BrowserContentEdgeDragRegions(
                    windowSize: proxy.size,
                    blockedLeadingWidth: contentEdgeDragBlockedLeadingWidth,
                    leadingInset: browserContentLeadingInset,
                    topInset: browserContentTopInset,
                    trailingInset: browserContentTrailingInset,
                    bottomInset: browserContentBottomInset
                )
                .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)

                if !model.isSidebarVisible, !usesDetachedBrowserOverlays {
                    BrowserSidebarHoverRevealEdge(onHoverChange: handleSidebarRevealEdgeHoverChange)
                        .frame(width: BrowserChromeLayout.sidebarHoverRevealWidth, height: proxy.size.height)
                        .allowsHitTesting(!isSidebarPresented)
                        .zIndex(7)
                }

                if usesDetachedBrowserOverlays {
                    BrowserDetachedOverlayWindowRepresentable(
                        isVisible: isDetachedSidebarHoverRevealEdgeVisible,
                        isInteractive: true,
                        contentFrameLeadingInset: 0,
                        content: BrowserSidebarHoverRevealEdge(onHoverChange: handleSidebarRevealEdgeHoverChange)
                    )
                    .frame(width: BrowserChromeLayout.sidebarHoverRevealWidth, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .zIndex(11)

                    BrowserDetachedOverlayWindowRepresentable(
                        isVisible: true,
                        isInteractive: isDetachedSidebarChromeInteractive,
                        contentFrameLeadingInset: 0,
                        content: BrowserDetachedSidebarHoverOverlayContent(
                            model: model,
                            snapshot: sidebarSnapshot,
                            showsWindowControlsInSidebar: showsWindowControlsInSidebarChrome,
                            isCommandBarPresented: commandBarModel.isPresented,
                            isCurrentPageCommandBarPresented: currentPageCommandBarModel.isPresented,
                            isOverlayPresentation: isSidebarOverlayPresentation,
                            showsOverlayBorder: isSidebarHoverOverlayPresented,
                            roundsWindowLeadingCorners: usesWindowContentInsets,
                            sidebarWidth: model.sidebarWidth,
                            sidebarHeight: sidebarHeight(in: proxy.size),
                            containerWidth: detachedSidebarChromeWidth,
                            containerHeight: proxy.size.height,
                            isPresented: isDetachedSidebarChromePresented,
                            onToggleSidebar: toggleSidebarFromChrome,
                            onURLRowFrameChange: { _ in }
                        )
                        .environmentObject(tooltipCoordinator)
                        .environmentObject(faviconCache)
                    )
                    .frame(
                        width: detachedSidebarChromeWidth,
                        height: proxy.size.height,
                        alignment: .leading
                    )
                    .allowsHitTesting(false)
                    .zIndex(12)
                    .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: isSidebarHoverOverlayPresented
                    )
                }

                BrowserSidebarHoverOverlayDismissReader(
                    isPresented: isSidebarHoverOverlayActive,
                    sidebarFrame: sidebarFrame(in: proxy.size),
                    allowsPointerSyncDismissal: allowsSidebarHoverOverlayPointerSyncDismissal,
                    onPointerMovement: handleSidebarHoverOverlayPointerMovement,
                    onDismiss: dismissSidebarHoverOverlay
                )
                .frame(width: proxy.size.width, height: proxy.size.height)

                BrowserSpaceSwipeObserver(
                    canSwitchSpaces: model.spaces.count > 1,
                    onSwipeLeft: model.selectNextSpace,
                    onSwipeRight: model.selectPreviousSpace
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)

                if commandBarModel.isPresented, !currentPageCommandBarModel.isPresented, sidebarLayoutWidth > 0 {
                    BrowserPassthroughInteractionObserver(
                        eventMask: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
                    ) {
                        DispatchQueue.main.async {
                            guard commandBarModel.isPresented, !currentPageCommandBarModel.isPresented else {
                                return
                            }

                            commandBarModel.dismiss()
                        }
                    }
                    .frame(width: sidebarLayoutWidth, height: proxy.size.height)
                    .zIndex(9)
                }

                if !usesDetachedBrowserOverlays {
                    BrowserFindBarOverlay(
                        model: model,
                        blockedLeadingInset: browserContentMinX
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(8)

                    BrowserCommandBarOverlay(
                        model: commandBarModel,
                        blockedLeadingInset: browserContentMinX,
                        style: .standard,
                        faviconCandidate: nil
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(10)

                    BrowserCommandBarOverlay(
                        model: currentPageCommandBarModel,
                        blockedLeadingInset: browserContentMinX,
                        style: .compact(
                            anchorFrame: currentURLRowWindowFrame,
                            sidebarWidth: model.sidebarWidth
                        ),
                        faviconCandidate: currentPageCommandBarFaviconCandidate
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(10)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(BrowserChromePalette.shellBackground)
        .background {
            BrowserWindowFullscreenReader { fullscreenState in
                handleWindowFullscreenStateChange(fullscreenState)
            }
            .allowsHitTesting(false)
        }
        .clipped()
        .environmentObject(tooltipCoordinator)
        .environmentObject(faviconCache)
        .overlayPreferenceValue(BrowserTooltipPreferenceKey.self) { values in
            GeometryReader { proxy in
                let tooltipEntries = values.map { entry in
                    BrowserResolvedTooltipEntry(
                        id: entry.id,
                        sourceFrame: proxy[entry.bounds],
                        title: entry.title,
                        caption: entry.caption,
                        shortcut: entry.shortcut,
                        placement: entry.placement
                    )
                }

                if usesDetachedBrowserOverlays {
                    BrowserDetachedOverlayWindowRepresentable(
                        isVisible: model.isFindBarPresented
                            || commandBarModel.isPresented,
                        isInteractive: true,
                        contentFrameLeadingInset: browserContentMinX,
                        content: BrowserDetachedControlsOverlayContent(
                            model: model,
                            commandBarModel: commandBarModel,
                            blockedLeadingInset: 0
                        )
                        .environmentObject(tooltipCoordinator)
                        .environmentObject(faviconCache)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                    BrowserDetachedOverlayWindowRepresentable(
                        isVisible: currentPageCommandBarModel.isPresented,
                        isInteractive: true,
                        contentFrameLeadingInset: 0,
                        content: BrowserDetachedCurrentPageCommandBarOverlayContent(
                            currentPageCommandBarModel: currentPageCommandBarModel,
                            blockedLeadingInset: browserContentMinX,
                            anchorFrame: currentURLRowWindowFrame,
                            sidebarWidth: model.sidebarWidth,
                            faviconCandidate: currentPageCommandBarFaviconCandidate
                        )
                        .environmentObject(tooltipCoordinator)
                        .environmentObject(faviconCache)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                    BrowserDetachedOverlayWindowRepresentable(
                        isVisible: !tooltipEntries.isEmpty,
                        isInteractive: false,
                        contentFrameLeadingInset: 0,
                        content: BrowserTooltipOverlay(entries: tooltipEntries)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                } else {
                    BrowserTooltipOverlay(entries: tooltipEntries)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: model.isSidebarVisible) { _, isSidebarVisible in
            if isSidebarVisible {
                finishSidebarHoverOverlayPromotionIfNeeded()
            }
        }
        .onAnimationCompleted(for: sidebarVisibilityAnimationValue) { completedValue in
            if completedValue == 0 {
                isSidebarHoverOverlayChromeVisible = false
            }
            showsSidebarWindowControls = model.isSidebarVisible || completedValue > 0
        }
        .task(id: sidebarRevealHoverTaskID) {
            await presentSidebarHoverOverlayAfterDelayIfNeeded()
        }
    }

    private var sidebarLayoutWidth: CGFloat {
        model.isSidebarVisible ? model.sidebarWidth : 0
    }

    private var isSidebarPresented: Bool {
        model.isSidebarVisible || isSidebarHoverOverlayPresented
    }

    private var isSidebarHoverOverlayActive: Bool {
        !model.isSidebarVisible && isSidebarHoverOverlayPresented
    }

    private var usesInlineSidebarChrome: Bool {
        !usesDetachedBrowserOverlays
    }

    private var isDetachedSidebarHoverRevealEdgeVisible: Bool {
        usesDetachedBrowserOverlays && !model.isSidebarVisible && !isSidebarPresented
    }

    private var isDetachedSidebarChromeInteractive: Bool {
        model.isSidebarVisible || isSidebarHoverOverlayPresented
    }

    private var isDetachedSidebarChromePresented: Bool {
        model.isSidebarVisible || isSidebarHoverOverlayPresented
    }

    private var isSidebarOverlayPresentation: Bool {
        !model.isSidebarVisible && isSidebarHoverOverlayChromeVisible
    }

    private var detachedSidebarChromeWidth: CGFloat {
        if isSidebarOverlayPresentation {
            return model.sidebarWidth + BrowserChromeLayout.sidebarHoverOverlayEdgeInset * 2
        }

        return model.sidebarWidth
    }

    private var showsWindowControlsInSidebarChrome: Bool {
        showsSidebarWindowControls || isSidebarHoverOverlayChromeVisible
    }

    private var allowsSidebarHoverOverlayPointerSyncDismissal: Bool {
        !isWindowFullscreenTransitioning && !isSidebarHoverOverlayPointerSyncSuspended
    }

    private var contentEdgeDragBlockedLeadingWidth: CGFloat {
        sidebarLayoutWidth
    }

    private var sidebarOffset: CGFloat {
        if model.isSidebarVisible {
            return 0
        }

        if isSidebarHoverOverlayPresented {
            return BrowserChromeLayout.sidebarHoverOverlayEdgeInset
        }

        if isSidebarOverlayPresentation {
            return -model.sidebarWidth + BrowserChromeLayout.sidebarHoverOverlayEdgeInset
        }

        return -model.sidebarWidth
    }

    private var sidebarOffsetY: CGFloat {
        isSidebarOverlayPresentation ? BrowserChromeLayout.sidebarHoverOverlayEdgeInset : 0
    }

    private var sidebarVisibilityAnimationValue: CGFloat {
        isSidebarPresented ? 1 : 0
    }

    private var currentPageCommandBarFaviconCandidate: BrowserCommandBarFaviconCandidate? {
        guard let selectedTab = sidebarSnapshot.selectedTab else {
            return nil
        }

        return BrowserCommandBarFaviconCandidate(tab: selectedTab)
    }

    private var usesWindowContentInsets: Bool {
        !isWindowFullscreen
    }

    private var browserContentEdgeInset: CGFloat {
        usesWindowContentInsets ? BrowserChromeLayout.browserContentEdgeInset : 0
    }

    private var browserContentLeadingInset: CGFloat {
        model.isSidebarVisible ? 0 : browserContentEdgeInset
    }

    private var browserContentTopInset: CGFloat {
        browserContentEdgeInset
    }

    private var browserContentTrailingInset: CGFloat {
        browserContentEdgeInset
    }

    private var browserContentBottomInset: CGFloat {
        browserContentEdgeInset
    }

    private var browserContentMinX: CGFloat {
        sidebarLayoutWidth + browserContentLeadingInset
    }

    private var browserContentMinY: CGFloat {
        browserContentTopInset
    }

    private func browserContentWidth(in windowSize: CGSize) -> CGFloat {
        max(windowSize.width - browserContentMinX - browserContentTrailingInset, 0)
    }

    private func browserContentHeight(in windowSize: CGSize) -> CGFloat {
        max(windowSize.height - browserContentTopInset - browserContentBottomInset, 0)
    }

    private func sidebarHeight(in windowSize: CGSize) -> CGFloat {
        guard isSidebarOverlayPresentation else {
            return windowSize.height
        }

        return max(windowSize.height - BrowserChromeLayout.sidebarHoverOverlayEdgeInset * 2, 0)
    }

    private func sidebarFrame(in windowSize: CGSize) -> CGRect {
        CGRect(
            x: sidebarOffset,
            y: sidebarOffsetY,
            width: model.sidebarWidth,
            height: sidebarHeight(in: windowSize)
        )
    }

    private var usesDetachedBrowserOverlays: Bool {
        false
    }

    private func handleSidebarRevealEdgeHoverChange(_ hovering: Bool) {
        guard !model.isSidebarVisible, isSidebarRevealEdgeHovered != hovering else {
            return
        }

        isSidebarRevealEdgeHovered = hovering
        sidebarRevealHoverTaskID += 1
    }

    private func handleWindowFullscreenStateChange(_ fullscreenState: BrowserWindowFullscreenState) {
        isWindowFullscreen = fullscreenState.isFullscreen
        isWindowFullscreenTransitioning = fullscreenState.isTransitioning

        if fullscreenState.isTransitioning {
            preserveSidebarHoverOverlayDuringFullscreenTransitionIfNeeded()
            return
        }

        restoreSidebarHoverOverlayAfterFullscreenTransitionIfNeeded()
    }

    private func toggleSidebarFromChrome() {
        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            model.toggleSidebar()
        }
    }

    private func finishSidebarHoverOverlayPromotionIfNeeded() {
        let updates = {
            isSidebarHoverOverlayPresented = false
            isSidebarHoverOverlayChromeVisible = false
            preservesSidebarHoverOverlayDuringFullscreenTransition = false
            isSidebarHoverOverlayPointerSyncSuspended = false
            isSidebarRevealEdgeHovered = false
            sidebarRevealHoverTaskID += 1
            showsSidebarWindowControls = true
        }

        guard isSidebarHoverOverlayPresented || isSidebarHoverOverlayChromeVisible else {
            updates()
            return
        }

        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), updates)
    }

    private func presentSidebarHoverOverlayAfterDelayIfNeeded() async {
        guard isSidebarRevealEdgeHovered, !isSidebarPresented else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarHoverRevealDelayNanoseconds)
        } catch {
            return
        }

        guard isSidebarRevealEdgeHovered, !isSidebarPresented else {
            return
        }

        presentSidebarHoverOverlay()
    }

    private func presentSidebarHoverOverlay() {
        guard !model.isSidebarVisible, !isSidebarHoverOverlayPresented else {
            return
        }

        withoutSidebarPresentationAnimation {
            isSidebarRevealEdgeHovered = false
            sidebarRevealHoverTaskID += 1
            isSidebarHoverOverlayPointerSyncSuspended = false
            isSidebarHoverOverlayChromeVisible = true
        }

        DispatchQueue.main.async {
            guard !model.isSidebarVisible,
                  isSidebarHoverOverlayChromeVisible,
                  !isSidebarHoverOverlayPresented
            else {
                return
            }

            withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
                isSidebarHoverOverlayPresented = true
            }
        }
    }

    private func withoutSidebarPresentationAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func dismissSidebarHoverOverlay() {
        guard isSidebarHoverOverlayPresented else {
            return
        }

        guard !isWindowFullscreenTransitioning else {
            preserveSidebarHoverOverlayDuringFullscreenTransitionIfNeeded()
            return
        }

        guard !isSidebarHoverOverlayPointerSyncSuspended else {
            return
        }

        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            isSidebarRevealEdgeHovered = false
            sidebarRevealHoverTaskID += 1
            isSidebarHoverOverlayPointerSyncSuspended = false
            isSidebarHoverOverlayPresented = false
        }
    }

    private func preserveSidebarHoverOverlayDuringFullscreenTransitionIfNeeded() {
        guard isSidebarHoverOverlayActive || isSidebarOverlayPresentation else {
            return
        }

        preservesSidebarHoverOverlayDuringFullscreenTransition = true
        isSidebarHoverOverlayPointerSyncSuspended = true
        isSidebarRevealEdgeHovered = false
        sidebarRevealHoverTaskID += 1
        isSidebarHoverOverlayChromeVisible = true
        isSidebarHoverOverlayPresented = true
    }

    private func restoreSidebarHoverOverlayAfterFullscreenTransitionIfNeeded() {
        guard preservesSidebarHoverOverlayDuringFullscreenTransition else {
            return
        }

        preservesSidebarHoverOverlayDuringFullscreenTransition = false

        guard !model.isSidebarVisible else {
            isSidebarHoverOverlayPointerSyncSuspended = false
            isSidebarHoverOverlayPresented = false
            isSidebarHoverOverlayChromeVisible = false
            return
        }

        isSidebarRevealEdgeHovered = false
        sidebarRevealHoverTaskID += 1
        isSidebarHoverOverlayChromeVisible = true
        isSidebarHoverOverlayPresented = true
    }

    private func handleSidebarHoverOverlayPointerMovement() {
        guard !isWindowFullscreenTransitioning, isSidebarHoverOverlayPointerSyncSuspended else {
            return
        }

        isSidebarHoverOverlayPointerSyncSuspended = false
    }

    private var sidebarSnapshot: BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            spaces: model.spaces,
            selectedSpaceID: model.selectedSpaceID,
            activeSpace: model.activeSpace,
            isActiveSpacePinnedSectionCollapsed: model.isActiveSpacePinnedSectionCollapsed,
            allTabs: model.tabs,
            appTabs: model.appTabs,
            spacePinnedTabs: model.spacePinnedTabs,
            temporaryTabs: model.temporaryTabs,
            selectedTabID: model.selectedTabID,
            archivableTabIDs: Set((model.spacePinnedTabs + model.temporaryTabs).dropLast().map(\.id)),
            canGoBack: model.canGoBack,
            canGoForward: model.canGoForward,
            canStopLoading: model.canStopLoading,
            canReload: model.canReload
        )
    }
}

private struct BrowserSidebarChromeView: View {
    @ObservedObject var model: BrowserChromeModel
    let snapshot: BrowserSidebarSnapshot
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let isOverlayPresentation: Bool
    let showsOverlayBorder: Bool
    var roundsWindowLeadingCorners = false
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void
    @State private var isSidebarResizing = false

    var body: some View {
        sidebarContent
            .clipShape(sidebarShape)
            .overlay {
                sidebarShape
                    .strokeBorder(
                        BrowserChromePalette.sidebarOverlayBorder,
                        lineWidth: BrowserChromeLayout.sidebarOverlayBorderWidth
                    )
                    .opacity(showsOverlayBorder ? 1 : 0)
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: showsOverlayBorder
                    )
            }
    }

    private var sidebarContent: some View {
        BrowserSidebarContainerView(
            model: model,
            snapshot: snapshot,
            extensions: model.browserExtensions,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar,
            isCommandBarPresented: isCommandBarPresented,
            isCurrentPageCommandBarPresented: isCurrentPageCommandBarPresented,
            isSidebarResizing: isSidebarResizing,
            onToggleSidebar: onToggleSidebar,
            onURLRowFrameChange: onURLRowFrameChange
        )
        .overlay(alignment: .trailing) {
            BrowserSidebarResizeHandle(model: model, isSidebarResizing: $isSidebarResizing)
                .frame(width: BrowserChromeLayout.sidebarResizeHitWidth)
        }
    }

    private var sidebarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: sidebarCornerRadii,
            style: .continuous
        )
    }

    private var sidebarCornerRadii: RectangleCornerRadii {
        if usesOverlayShape {
            let cornerRadius = BrowserChromeLayout.sidebarOverlayCornerRadius
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        }

        if roundsWindowLeadingCorners {
            let cornerRadius = BrowserWindowGeometry.windowCornerRadius
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        }

        return RectangleCornerRadii()
    }

    private var usesOverlayShape: Bool {
        isOverlayPresentation || showsOverlayBorder
    }
}

private struct BrowserSidebarContainerView: View {
    let model: BrowserChromeModel
    let snapshot: BrowserSidebarSnapshot
    let extensions: [BrowserExtension]
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let isSidebarResizing: Bool
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    var body: some View {
        BrowserSidebarView(
            model: model,
            snapshot: snapshot,
            extensions: extensions,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar,
            isCommandBarPresented: isCommandBarPresented,
            isCurrentPageCommandBarPresented: isCurrentPageCommandBarPresented,
            isSidebarResizing: isSidebarResizing,
            onToggleSidebar: onToggleSidebar,
            onURLRowFrameChange: onURLRowFrameChange
        )
        .background(BrowserChromePalette.sidebarBackground)
    }
}

private struct BrowserSidebarResizeHandle: View {
    @ObservedObject var model: BrowserChromeModel
    @Binding var isSidebarResizing: Bool

    @State private var isHoveringResizeArea = false
    @State private var isResizeHovered = false
    @State private var isResizing = false
    @State private var isSnappedToDefaultWidth = false
    @State private var dragStartWidth: CGFloat?
    @State private var pushedResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay {
                Rectangle()
                    .fill(isResizeHovered ? BrowserChromePalette.resizeHandleHover : BrowserChromePalette.resizeHandle)
                    .frame(width: 2)
                    .opacity(shouldShowResizeHandle ? 1 : 0)
            }
            .padding(.vertical, BrowserChromeLayout.sidebarOuterPadding)
            .contentShape(Rectangle())
            .onHover(perform: handleResizeHover)
            .task(id: resizeHoverActivationTaskID) {
                await activateResizeHoverIfNeeded()
            }
            .gesture(resizeGesture)
            .onDisappear {
                popResizeCursorIfNeeded()
                isHoveringResizeArea = false
                isResizeHovered = false
                isResizing = false
                isSidebarResizing = false
                isSnappedToDefaultWidth = false
                dragStartWidth = nil
            }
    }

    private var shouldShowResizeHandle: Bool {
        isResizeHovered || isResizing
    }

    private var resizeHoverActivationTaskID: Int {
        (isHoveringResizeArea ? 1 : 0) | (isResizing ? 2 : 0)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                beginResizeIfNeeded()
                updateSidebarWidth(with: value.translation.width)
            }
            .onEnded { _ in
                finishResize()
            }
    }

    private func handleResizeHover(_ hovering: Bool) {
        isHoveringResizeArea = hovering

        if !hovering {
            isResizeHovered = false
            if !isResizing {
                popResizeCursorIfNeeded()
            }
        }
    }

    private func beginResizeIfNeeded() {
        if dragStartWidth == nil {
            dragStartWidth = model.sidebarWidth
        }

        isResizing = true
        isSidebarResizing = true

        pushResizeCursorIfNeeded()
    }

    private func updateSidebarWidth(with translation: CGFloat) {
        let baseWidth = dragStartWidth ?? model.sidebarWidth
        let proposedWidth = baseWidth + translation
        let shouldSnapToDefault =
            abs(proposedWidth - BrowserChromeModel.defaultSidebarWidth) <= BrowserChromeLayout.sidebarSnapThreshold

        if shouldSnapToDefault {
            model.setSidebarWidth(BrowserChromeModel.defaultSidebarWidth)

            if !isSnappedToDefaultWidth {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else {
            model.setSidebarWidth(proposedWidth)
        }

        isSnappedToDefaultWidth = shouldSnapToDefault
    }

    private func finishResize() {
        let shouldPersistSidebarWidth = if let dragStartWidth {
            dragStartWidth != model.sidebarWidth
        } else {
            false
        }

        dragStartWidth = nil
        isResizing = false
        isSidebarResizing = false
        isSnappedToDefaultWidth = false

        if shouldPersistSidebarWidth {
            model.persistSidebarWidthPreferenceIfAllowed()
        }

        guard isHoveringResizeArea else {
            isResizeHovered = false
            popResizeCursorIfNeeded()
            return
        }

        if !isResizeHovered {
            popResizeCursorIfNeeded()
        }
    }

    private func activateResizeHoverIfNeeded() async {
        guard isHoveringResizeArea, !isResizing else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarResizeHoverDelayNanoseconds)
        } catch {
            return
        }

        guard isHoveringResizeArea, !isResizing else {
            return
        }

        isResizeHovered = true
        pushResizeCursorIfNeeded()
    }

    private func pushResizeCursorIfNeeded() {
        guard !pushedResizeCursor else {
            return
        }

        NSCursor.resizeLeftRight.push()
        pushedResizeCursor = true
    }

    private func popResizeCursorIfNeeded() {
        guard pushedResizeCursor else {
            return
        }

        NSCursor.pop()
        pushedResizeCursor = false
    }
}

private final class BrowserSidebarTabDragPreviewStore: ObservableObject {
    @Published var preview: BrowserSidebarTabDragPreviewState?

    func begin(_ preview: BrowserSidebarTabDragPreviewState) {
        guard self.preview != preview else {
            return
        }

        self.preview = preview
    }

    func update(location: CGPoint, size: CGSize) {
        guard var preview else {
            return
        }

        guard preview.location != location || preview.size != size else {
            return
        }

        preview.update(location: location, size: size)
        self.preview = preview
    }

    func clear() {
        guard preview != nil else {
            return
        }

        preview = nil
    }
}

private struct BrowserSidebarView: View {
    let model: BrowserChromeModel
    let snapshot: BrowserSidebarSnapshot
    let extensions: [BrowserExtension]
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let isSidebarResizing: Bool
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void
    @State private var isNewTabButtonHovered = false
    @State private var isClearButtonHovered = false
    @State private var isSidebarHovered = false
    @State private var newTabButtonWindowFrame: CGRect?
    @State private var renamingSpaceID: String?
    @State private var renamingTabID: String?
    @State private var draggedTabID: String?
    @State private var dropTarget: BrowserSidebarTabDropTarget?
    @StateObject private var dragPreviewStore = BrowserSidebarTabDragPreviewStore()
    @State private var suppressedTabSelectionAfterDragID: String?
    @State private var tabRowInteractionResetID = 0
    @State private var rawTabRowFrames: [String: BrowserSidebarTabRowFrame] = [:]
    @State private var tabRowFrames: [String: BrowserSidebarTabRowFrame] = [:]
    @State private var tabDropRowFrameList: [BrowserSidebarTabRowFrame] = []
    @State private var rawAppTabFrames: [String: BrowserSidebarAppTabFrame] = [:]
    @State private var appTabFrames: [String: BrowserSidebarAppTabFrame] = [:]
    @State private var appTabDropFrameList: [BrowserSidebarAppTabFrame] = []
    @State private var appTabsContainerFrame: CGRect?
    @State private var rawEmptySectionFrames: [BrowserSidebarEmptySectionFrame] = []
    @State private var emptySectionFrames: [BrowserSidebarEmptySectionFrame] = []
    @State private var showsTopChromeDivider = false
    @State private var showsBottomChromeDivider = false
    @State private var visibleSpaceID: String?

    var body: some View {
        let visibleSnapshot = displayedSnapshot
        let renderedSidebarSnapshot = renderedSnapshot(for: visibleSnapshot)
        let appTabs = renderedSidebarSnapshot.appTabs
        let sidebarContentWidth = max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)

        VStack(spacing: 0) {
            VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
                topChrome

                if !appTabs.isEmpty || draggedTabID != nil {
                    appTabsGrid(
                        appTabs,
                        sidebarContentWidth: sidebarContentWidth
                    )
                }

                if let activeSpace = renderedSidebarSnapshot.activeSpace {
                    spaceHeaderRow(for: activeSpace)
                        .background(BrowserChromePalette.sidebarBackground)
                        .zIndex(2)
                }
            }
            .overlay(alignment: .bottom) {
                BrowserSidebarTopChromeDivider(isVisible: showsTopChromeDivider)
                    .offset(y: BrowserChromeLayout.sidebarSectionSpacing)
            }
            .zIndex(1)
            .padding(.bottom, BrowserChromeLayout.sidebarSectionSpacing)

            spacePages(
                for: renderedSidebarSnapshot,
                sidebarContentWidth: sidebarContentWidth
            )

            bottomChrome
        }
        .onPreferenceChange(BrowserSidebarAppTabFramePreferenceKey.self) { frames in
            setAppTabFrames(frames, for: renderedSidebarSnapshot)
        }
        .onPreferenceChange(BrowserSidebarAppTabsContainerFramePreferenceKey.self) { frame in
            setAppTabsContainerFrame(frame, for: renderedSidebarSnapshot)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                tabDropIndicatorOverlay
                tabDragPreviewOverlay
                tabDragEventMonitor
            }
        }
        .coordinateSpace(name: BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
        .padding(.top, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.leading, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.bottom, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .browserWindowDragGesture(isEnabled: draggedTabID == nil)
        .overlay {
            BrowserPassthroughInteractionObserver { event, observerView in
                resignRenamingFirstResponderIfNeeded(for: event, in: observerView)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
                isSidebarHovered = hovering
            }
            if !hovering {
                isClearButtonHovered = false
            }
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            guard isSidebarResizing else {
                return
            }

            clearTabDragState()
            isNewTabButtonHovered = false
            isClearButtonHovered = false
            isSidebarHovered = false
        }
        .onChange(of: snapshot) { _, snapshot in
            let displayedSidebarSnapshot = displayedSnapshot(for: snapshot)
            let renderedSidebarSnapshot = renderedSnapshot(for: displayedSidebarSnapshot)
            setTabRowFrames(rawTabRowFrames, for: renderedSidebarSnapshot)
            setEmptySectionFrames(rawEmptySectionFrames, for: renderedSidebarSnapshot)
            setAppTabFrames(rawAppTabFrames, for: renderedSidebarSnapshot)
            setAppTabsContainerFrame(appTabsContainerFrame, for: renderedSidebarSnapshot)

            guard let draggedTabID, !snapshot.containsTab(withID: draggedTabID) else {
                return
            }

            clearTabDragState()
        }
        .onChange(of: isCommandBarPresented) { _, isCommandBarPresented in
            if !isCommandBarPresented {
                syncNewTabHoverStateWithPointer()
            }
        }
        .onDisappear {
            clearTabDragState()
        }
        .background {
            ZStack {
                BrowserChromePalette.sidebarBackground

                BrowserWindowDragRegion(isEnabled: draggedTabID == nil)
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissRenamingIfNeeded()
                    })
            }
        }
    }

    private var topChrome: some View {
        VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            BrowserSidebarHeaderView(
                canGoBack: snapshot.canGoBack,
                canGoForward: snapshot.canGoForward,
                canStopLoading: snapshot.canStopLoading,
                canReload: snapshot.canReload,
                shortcutStore: model.shortcutStore,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar,
                onToggleSidebar: onToggleSidebar,
                onGoBack: model.goBack,
                onGoForward: model.goForward,
                onStopLoading: model.stopLoadingCurrentTab,
                onReload: model.reloadCurrentTab
            )

            BrowserSidebarCurrentURLRow(
                tab: snapshot.selectedTab,
                extensions: extensions,
                copyLinkShortcut: model.shortcutStore.shortcut(for: .copyLink),
                isSearchPresented: isCurrentPageCommandBarPresented,
                isSidebarResizing: isSidebarResizing,
                onFrameChange: onURLRowFrameChange,
                onOpenSearch: model.presentCurrentPageCommandBar,
                onCopyURL: {
                    model.copySelectedTabLink()
                },
                onRefreshExtensions: model.refreshBrowserExtensions,
                onOpenExtensionsManager: model.openExtensionsManager,
                onOpenExtensionStore: model.openExtensionStore,
                onOpenExtensionDetails: model.openExtensionDetails
            )
        }
    }

    private func spacePages(
        for renderedSidebarSnapshot: BrowserSidebarSnapshot,
        sidebarContentWidth: CGFloat
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(renderedSidebarSnapshot.spaces) { space in
                    spacePage(
                        for: space,
                        in: renderedSidebarSnapshot,
                        sidebarContentWidth: sidebarContentWidth
                    )
                    .frame(width: sidebarContentWidth)
                    .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleSpaceID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .browserWindowDragGesture(isEnabled: draggedTabID == nil)
        .onAppear {
            syncVisibleSpaceID(with: renderedSidebarSnapshot.selectedSpaceID, animated: false)
        }
        .onChange(of: renderedSidebarSnapshot.selectedSpaceID) { _, selectedSpaceID in
            syncVisibleSpaceID(with: selectedSpaceID, animated: true)
        }
        .onChange(of: visibleSpaceID) { _, visibleSpaceID in
            guard
                let visibleSpaceID,
                visibleSpaceID != renderedSidebarSnapshot.selectedSpaceID
            else {
                return
            }

            dismissRenamingIfNeeded()
            model.selectSpace(id: visibleSpaceID)
        }
        .onPreferenceChange(BrowserSidebarTabRowFramePreferenceKey.self) { frames in
            setTabRowFrames(frames, for: renderedSidebarSnapshot)
        }
        .onPreferenceChange(BrowserSidebarEmptySectionFramePreferenceKey.self) { frames in
            setEmptySectionFrames(frames, for: renderedSidebarSnapshot)
        }
        .background {
            BrowserWindowDragRegion(isEnabled: draggedTabID == nil)
                .simultaneousGesture(TapGesture().onEnded {
                    dismissRenamingIfNeeded()
                })
        }
    }

    private func spacePage(
        for space: BrowserChromeModel.Space,
        in renderedSidebarSnapshot: BrowserSidebarSnapshot,
        sidebarContentWidth _: CGFloat
    ) -> some View {
        let spacePinnedTabs = renderedSidebarSnapshot.spacePinnedTabs(in: space.id)
        let temporaryTabs = renderedSidebarSnapshot.temporaryTabs(in: space.id)
        let isPinnedSectionCollapsed = renderedSidebarSnapshot.isPinnedSectionCollapsed(in: space.id)

        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BrowserChromeLayout.sidebarListSpacing) {
                if !isPinnedSectionCollapsed {
                    if spacePinnedTabs.isEmpty {
                        if draggedTabID != nil {
                            emptySectionDropZone(for: .spacePinned, spaceID: space.id, height: 0)
                        }
                    } else {
                        ForEach(Array(spacePinnedTabs.enumerated()), id: \.element.id) { index, tab in
                            sidebarRow(for: tab, in: .spacePinned, sectionIndex: index, spaceID: space.id)
                        }
                    }
                }

                if !spacePinnedTabs.isEmpty {
                    BrowserSidebarTemporaryTabsDivider(
                        clearTemporaryTabsDescriptor: model.shortcutStore.descriptor(for: .clearTemporaryTabs),
                        showsClearButton: isSidebarHovered
                            && !temporaryTabs.isEmpty
                            && renderedSidebarSnapshot.selectedSpaceID == space.id,
                        isClearButtonHovered: isClearButtonHovered,
                        onHoverClearButton: { hovering in
                            guard !isSidebarResizing else {
                                return
                            }

                            isClearButtonHovered = hovering
                        },
                        onClear: {
                            clearTabDragState()
                            dismissRenamingIfNeeded()
                            withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                                model.clearTemporaryTabs()
                            }
                        }
                    )
                }

                newTabButton

                if temporaryTabs.isEmpty, draggedTabID != nil {
                    emptySectionDropZone(for: .temporary, spaceID: space.id, height: 0)
                }

                ForEach(Array(temporaryTabs.enumerated()), id: \.element.id) { index, tab in
                    sidebarRow(for: tab, in: .temporary, sectionIndex: index, spaceID: space.id)
                }
            }
            .animation(
                BrowserChromeLayout.sidebarTabDropListAnimation,
                value: isPinnedSectionCollapsed
            )
            .animation(
                BrowserChromeLayout.sidebarTabDropListAnimation,
                value: spacePinnedTabs.map(\.id)
            )
            .animation(
                BrowserChromeLayout.sidebarTabDropListAnimation,
                value: temporaryTabs.map(\.id)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > BrowserChromeLayout.sidebarTopChromeDividerScrollThreshold
        } action: { _, shouldShow in
            guard renderedSidebarSnapshot.selectedSpaceID == space.id else {
                return
            }

            updateTopChromeDividerVisibility(shouldShow)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY < geometry.contentSize.height - BrowserChromeLayout.sidebarTopChromeDividerScrollThreshold
        } action: { _, shouldShow in
            guard renderedSidebarSnapshot.selectedSpaceID == space.id else {
                return
            }

            updateBottomChromeDividerVisibility(shouldShow)
        }
    }

    private func syncVisibleSpaceID(with selectedSpaceID: String?, animated: Bool) {
        guard visibleSpaceID != selectedSpaceID else {
            return
        }

        let update = {
            visibleSpaceID = selectedSpaceID
        }

        if animated {
            withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation, update)
        } else {
            update()
        }
    }

    private var displayedSnapshot: BrowserSidebarSnapshot {
        displayedSnapshot(for: snapshot)
    }

    private func displayedSnapshot(for snapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
        guard
            let draggedTabID,
            let dropTarget,
            let reorderedTabs = model.reorderedTabs(
                movingTabID: draggedTabID,
                toPlacement: dropTarget.section.placement,
                requestedSectionIndex: dropTarget.sectionIndex,
                targetSpaceID: dropTarget.spaceID
            )
        else {
            return snapshot
        }

        return snapshot.replacingTabs(reorderedTabs)
    }

    private func renderedSnapshot(for visibleSnapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
        guard
            let draggedTabID,
            let draggedTab = snapshot.tab(withID: draggedTabID)
        else {
            return visibleSnapshot
        }

        return BrowserSidebarSnapshot(
            spaces: visibleSnapshot.spaces,
            selectedSpaceID: visibleSnapshot.selectedSpaceID,
            activeSpace: visibleSnapshot.activeSpace,
            isActiveSpacePinnedSectionCollapsed: visibleSnapshot.isActiveSpacePinnedSectionCollapsed,
            allTabs: renderedAllTabs(in: visibleSnapshot, draggedTab: draggedTab),
            appTabs: renderedAppTabs(visibleSnapshot.appTabs, draggedTab: draggedTab),
            spacePinnedTabs: renderedRowTabs(
                visibleSnapshot.spacePinnedTabs,
                in: .spacePinned,
                draggedTab: draggedTab
            ),
            temporaryTabs: renderedRowTabs(
                visibleSnapshot.temporaryTabs,
                in: .temporary,
                draggedTab: draggedTab
            ),
            selectedTabID: visibleSnapshot.selectedTabID,
            archivableTabIDs: visibleSnapshot.archivableTabIDs,
            canGoBack: visibleSnapshot.canGoBack,
            canGoForward: visibleSnapshot.canGoForward,
            canStopLoading: visibleSnapshot.canStopLoading,
            canReload: visibleSnapshot.canReload
        )
    }

    private func renderedAllTabs(
        in visibleSnapshot: BrowserSidebarSnapshot,
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        guard
            let dropTarget,
            dropTarget.section.placement != .app,
            let targetSpaceID = dropTarget.spaceID,
            draggedTab.placement != dropTarget.section.placement || draggedTab.spaceID != targetSpaceID,
            visibleSnapshot.allTabs.contains(where: { $0.id == draggedTab.id })
        else {
            return visibleSnapshot.allTabs
        }

        var renderedTabs = visibleSnapshot.allTabs.filter { $0.id != draggedTab.id }
        var renderedTab = draggedTab
        renderedTab.spaceID = targetSpaceID
        renderedTab.placement = dropTarget.section.placement

        let targetTabs = renderedTabs.filter {
            $0.spaceID == targetSpaceID && $0.placement == dropTarget.section.placement
        }
        let insertionReferenceIndex = targetTabs.dropFirst(
            min(max(dropTarget.sectionIndex, 0), targetTabs.count)
        ).first.flatMap { referenceTab in
            renderedTabs.firstIndex { $0.id == referenceTab.id }
        }

        renderedTabs.insert(renderedTab, at: insertionReferenceIndex ?? renderedTabs.count)
        return renderedTabs
    }

    private func renderedAppTabs(
        _ visibleTabs: [BrowserChromeModel.Tab],
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        guard draggedTab.placement == .app, !visibleTabs.contains(where: { $0.id == draggedTab.id }) else {
            return visibleTabs
        }

        var renderedTabs = visibleTabs
        let sourceIndex = snapshot.appTabs.firstIndex(where: { $0.id == draggedTab.id }) ?? renderedTabs.count
        renderedTabs.insert(draggedTab, at: min(sourceIndex, renderedTabs.count))
        return renderedTabs
    }

    private func renderedRowTabs(
        _ visibleTabs: [BrowserChromeModel.Tab],
        in section: BrowserSidebarTabSection,
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        var renderedTabs = visibleTabs

        if section == .spacePinned, draggedTab.placement != section.placement {
            renderedTabs.removeAll { $0.id == draggedTab.id }
        }

        guard draggedTab.placement == section.placement, !renderedTabs.contains(where: { $0.id == draggedTab.id }) else {
            return renderedTabs
        }

        let sourceTabs = tabs(in: section, from: snapshot)
        let sourceIndex = sourceTabs.firstIndex(where: { $0.id == draggedTab.id }) ?? renderedTabs.count
        renderedTabs.insert(draggedTab, at: min(sourceIndex, renderedTabs.count))
        return renderedTabs
    }

    private func tabs(
        in section: BrowserSidebarTabSection,
        from snapshot: BrowserSidebarSnapshot
    ) -> [BrowserChromeModel.Tab] {
        switch section {
        case .app:
            snapshot.appTabs
        case .spacePinned:
            snapshot.spacePinnedTabs
        case .temporary:
            snapshot.temporaryTabs
        }
    }

    private func toggleCommandBar() {
        dismissRenamingIfNeeded()
        model.toggleCommandBar()
    }

    private func syncNewTabHoverStateWithPointer() {
        guard
            let newTabButtonWindowFrame,
            let window = NSApp.keyWindow
        else {
            isNewTabButtonHovered = false
            return
        }

        isNewTabButtonHovered = newTabButtonWindowFrame.contains(window.mouseLocationOutsideOfEventStream)
    }

    private var newTabButtonBackgroundColor: Color {
        guard !isSidebarResizing else {
            return .clear
        }

        if isCommandBarPresented {
            return BrowserChromePalette.rowSelected
        }

        if isNewTabButtonHovered {
            return BrowserChromePalette.rowHover
        }

        return .clear
    }

    private var newTabButton: some View {
        Button(action: toggleCommandBar) {
            HStack(spacing: BrowserChromeLayout.sidebarRowContentSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: BrowserChromeLayout.sidebarNewTabSymbolSize, weight: .semibold))
                Text(BrowserStrings.sidebarNewTab)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
            .frame(height: BrowserChromeLayout.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
                    .fill(newTabButtonBackgroundColor)
            )
            .background {
                BrowserWindowFrameReader { frame in
                    newTabButtonWindowFrame = frame
                }
            }
        }
        .buttonStyle(BrowserSidebarPressButtonStyle())
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isNewTabButtonHovered = hovering
        }
        .browserTooltip(
            title: model.shortcutStore.descriptor(for: .newTab).helpTitle,
            shortcut: model.shortcutStore.shortcut(for: .newTab),
            isPresented: isNewTabButtonHovered && !isCommandBarPresented && !isSidebarResizing
        )
    }

    private var spacesBar: some View {
        BrowserSidebarSpacesBar(
            spaces: snapshot.spaces,
            selectedSpaceID: snapshot.selectedSpaceID,
            isSidebarResizing: isSidebarResizing,
            onSelectSpace: { spaceID in
                dismissRenamingIfNeeded()
                model.selectSpace(id: spaceID)
            },
            onCreateSpace: {
                dismissRenamingIfNeeded()
                model.createNewSpace()
            }
        )
    }

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            BrowserSidebarTopChromeDivider(isVisible: showsBottomChromeDivider)
            Color.clear
                .frame(height: BrowserChromeLayout.sidebarBottomChromeTopSpacing)
            spacesBar
        }
        .background(BrowserChromePalette.sidebarBackground)
        .zIndex(1)
    }

    private func spaceHeaderRow(for space: BrowserChromeModel.Space) -> some View {
        BrowserSidebarSpaceHeaderRow(
            space: space,
            isRenaming: renamingSpaceID == space.id,
            isCollapsed: snapshot.isActiveSpacePinnedSectionCollapsed,
            isSidebarResizing: isSidebarResizing,
            interactionResetID: tabRowInteractionResetID,
            onToggleCollapsed: {
                dismissRenamingIfNeeded()
                withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                    model.toggleActiveSpacePinnedSectionCollapsed()
                }
            },
            onBeginRename: {
                beginRenamingSpace(id: space.id)
            },
            onCommitRename: { title in
                model.setTitle(title, forSpaceID: space.id)
                renamingSpaceID = nil
            },
            onCancelRename: {
                renamingSpaceID = nil
            },
            onChangeIcon: { systemImageName in
                model.setIcon(systemImageName, forSpaceID: space.id)
            }
        )
    }

    private var tabDragPreviewOverlay: some View {
        BrowserSidebarTabDragPreviewOverlay(
            store: dragPreviewStore,
            snapshot: snapshot
        )
    }

    @ViewBuilder
    private var tabDragEventMonitor: some View {
        if let draggedTabID {
            BrowserSidebarTabDragEventMonitor(
                tabID: draggedTabID,
                onDragged: updateActiveTabDrag(for:location:),
                onEnded: finishActiveTabDrag(for:location:)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var tabDropIndicatorOverlay: some View {
        if let dropIndicatorFrame {
            BrowserSidebarDropIndicator()
                .frame(width: dropIndicatorFrame.width, height: dropIndicatorFrame.height)
                .position(x: dropIndicatorFrame.midX, y: dropIndicatorFrame.midY)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .allowsHitTesting(false)
        }
    }

    private var dropIndicatorFrame: CGRect? {
        BrowserSidebarTabDropIndicatorFrameResolver().frame(
            for: dropTarget,
            rowFrames: tabDropRowFrameList,
            emptySectionFrames: emptySectionFrames,
            horizontalInset: 6,
            thickness: BrowserChromeLayout.sidebarDropIndicatorThickness
        )
    }

    private func appTabsGrid(
        _ appTabs: [BrowserChromeModel.Tab],
        sidebarContentWidth: CGFloat
    ) -> some View {
        BrowserSidebarAppTabsGrid(
            tabs: appTabs,
            draggedTabID: draggedTabID,
            isSidebarResizing: isSidebarResizing,
            sidebarContentWidth: sidebarContentWidth,
            onSelect: { tabID in
                guard suppressedTabSelectionAfterDragID != tabID else {
                    return
                }

                if renamingTabID != tabID {
                    dismissRenamingIfNeeded()
                }
                model.selectTab(id: tabID)
            },
            onDragChanged: updateTabDrag(for:value:),
            onDragEnded: finishTabDrag(for:value:)
        )
    }

    private func sidebarRow(
        for tab: BrowserChromeModel.Tab,
        in section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String
    ) -> some View {
        BrowserSidebarRow(
            tab: tab,
            copyLinkDescriptor: model.shortcutStore.descriptor(for: .copyLink),
            archiveTabDescriptor: model.shortcutStore.descriptor(for: .archiveTab),
            isSelected: snapshot.selectedTabID == tab.id && !isCommandBarPresented,
            isRenaming: renamingTabID == tab.id,
            canArchiveTabsBelow: snapshot.archivableTabIDs.contains(tab.id),
            isSidebarResizing: isSidebarResizing,
            interactionResetID: tabRowInteractionResetID,
            onSelect: {
                guard suppressedTabSelectionAfterDragID != tab.id else {
                    return
                }

                if renamingTabID != tab.id {
                    dismissRenamingIfNeeded()
                }
                model.selectTab(id: tab.id)
            },
            onCopyLink: {
                _ = model.copyTabLink(forTabID: tab.id)
            },
            onBeginRename: {
                beginRenamingTab(id: tab.id)
            },
            onCommitRename: { titleOverride in
                model.setUserTitleOverride(titleOverride, forTabID: tab.id)
                renamingTabID = nil
            },
            onCancelRename: {
                renamingTabID = nil
            },
            onClose: {
                if let renamingTabID, renamingTabID != tab.id {
                    dismissRenamingIfNeeded()
                }
                if renamingTabID == tab.id {
                    renamingTabID = nil
                }
                withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                    model.closeTab(id: tab.id)
                }
            },
            onArchiveTabsBelow: {
                renamingTabID = nil
                withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                    model.closeTabsBelow(id: tab.id)
                }
            }
        )
        .browserSidebarTabRowFrame(tabID: tab.id, section: section, sectionIndex: sectionIndex, spaceID: spaceID)
        .transition(BrowserChromeLayout.sidebarTabVisibilityTransition)
        .opacity(draggedTabID == tab.id ? 0 : 1)
        .allowsHitTesting(draggedTabID != tab.id)
        .simultaneousGesture(tabDragGesture(for: tab.id))
    }

    private func emptySectionDropZone(
        for section: BrowserSidebarTabSection,
        spaceID: String,
        height: CGFloat = BrowserChromeLayout.sidebarEmptySectionDropZoneHeight
    ) -> some View {
        BrowserSidebarEmptySectionDropZone(
            height: height,
            showsDropIndicator: dropTarget == BrowserSidebarTabDropTarget(
                section: section,
                sectionIndex: 0,
                spaceID: spaceID
            )
        )
        .browserSidebarEmptySectionFrame(section: section, spaceID: spaceID)
    }

    private func dismissRenamingIfNeeded(in window: NSWindow? = NSApp.keyWindow) {
        guard renamingTabID != nil || renamingSpaceID != nil else {
            return
        }

        let activeRenamingTabID = renamingTabID
        let activeRenamingSpaceID = renamingSpaceID
        window?.makeFirstResponder(nil)

        DispatchQueue.main.async {
            guard renamingTabID == activeRenamingTabID, renamingSpaceID == activeRenamingSpaceID else {
                return
            }

            renamingTabID = nil
            renamingSpaceID = nil
        }
    }

    private func resignRenamingFirstResponderIfNeeded(for event: NSEvent, in observerView: NSView) {
        guard renamingTabID != nil || renamingSpaceID != nil,
              let window = observerView.window,
              !isEventInsideSidebarRenameTextField(event, in: window)
        else {
            return
        }

        dismissRenamingIfNeeded(in: window)
    }

    private func isEventInsideSidebarRenameTextField(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else {
            return false
        }

        return contentView.containsWindowPoint(
            event.locationInWindow,
            inDescendantOfType: BrowserSidebarRenameNSTextField.self
        )
    }

    private func beginRenamingTab(id tabID: String) {
        if renamingSpaceID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingTabID, renamingTabID != tabID {
            dismissRenamingIfNeeded()
        }

        DispatchQueue.main.async {
            renamingTabID = tabID
        }
    }

    private func beginRenamingSpace(id spaceID: String) {
        if renamingTabID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingSpaceID, renamingSpaceID != spaceID {
            dismissRenamingIfNeeded()
        }

        DispatchQueue.main.async {
            renamingSpaceID = spaceID
        }
    }

    private func tabDragGesture(for tabID: String) -> some Gesture {
        DragGesture(
            minimumDistance: BrowserChromeLayout.sidebarTabDragMinimumDistance,
            coordinateSpace: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
        )
        .onChanged { value in
            updateTabDrag(for: tabID, value: value)
        }
        .onEnded { value in
            finishTabDrag(for: tabID, value: value)
        }
    }

    private func updateTabDrag(for tabID: String, value: DragGesture.Value) {
        guard suppressedTabSelectionAfterDragID != tabID else {
            clearTabDragState()
            return
        }

        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        beginTabDragIfNeeded(for: tabID, startLocation: value.startLocation, location: value.location)
        let target = resolvedTabDropTarget(at: value.location)
        setDropTarget(target)
        updateDragPreviewLocation(value.location, target: target)
    }

    private func updateActiveTabDrag(for tabID: String, location: CGPoint) {
        guard draggedTabID == tabID else {
            return
        }

        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        let target = resolvedTabDropTarget(at: location)
        setDropTarget(target)
        updateDragPreviewLocation(location, target: target)
    }

    private func finishTabDrag(for tabID: String, value: DragGesture.Value) {
        guard draggedTabID == tabID else {
            clearTabDragState()
            return
        }

        suppressSelectionAfterDrag(for: tabID)

        let target = resolvedTabDropTarget(at: value.location)
        setDropTarget(target)
        updateDragPreviewLocation(value.location, target: target)

        if let target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    private func finishActiveTabDrag(for tabID: String, location: CGPoint) {
        guard draggedTabID == tabID else {
            return
        }

        suppressSelectionAfterDrag(for: tabID)

        let target = resolvedTabDropTarget(at: location)
        setDropTarget(target)
        updateDragPreviewLocation(location, target: target)

        if let target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    private func beginTabDragIfNeeded(for tabID: String, startLocation: CGPoint, location: CGPoint) {
        guard draggedTabID != tabID else {
            return
        }

        dismissRenamingIfNeeded()
        draggedTabID = tabID
        withoutSidebarDragAnimation {
            dragPreviewStore.begin(
                BrowserSidebarTabDragPreviewState(
                    tabID: tabID,
                    sourceFrame: dragPreviewSourceFrame(for: tabID, startLocation: startLocation),
                    location: location
                )
            )
        }
        suppressedTabSelectionAfterDragID = nil
        setDropTarget(nil)
    }

    private func updateDragPreviewLocation(_ location: CGPoint, target: BrowserSidebarTabDropTarget?) {
        dragPreviewStore.update(location: location, size: dragPreviewSize(for: target))
    }

    private func dragPreviewSourceFrame(for tabID: String, startLocation: CGPoint) -> CGRect {
        if let frame = appTabFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        if let frame = tabRowFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        let fallbackWidth = max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)
        return CGRect(
            x: 0,
            y: startLocation.y - BrowserChromeLayout.sidebarRowHeight / 2,
            width: fallbackWidth,
            height: BrowserChromeLayout.sidebarRowHeight
        )
    }

    private func dragPreviewSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        guard target?.section == .app else {
            return dragPreviewRowSize(for: target)
        }

        return dragPreviewAppTileSize(for: target)
    }

    private func dragPreviewRowSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        if
            let target,
            target.section != .app,
            let frame = dragPreviewRowFrame(for: target)
        {
            return CGSize(width: frame.width, height: BrowserChromeLayout.sidebarRowHeight)
        }

        if let draggedTabID, let frame = tabRowFrames[draggedTabID]?.frame, !frame.isEmpty {
            return frame.size
        }

        return CGSize(
            width: max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0),
            height: BrowserChromeLayout.sidebarRowHeight
        )
    }

    private func dragPreviewRowFrame(for target: BrowserSidebarTabDropTarget) -> CGRect? {
        let sectionFrames = tabDropRowFrameList.filter {
            $0.section == target.section && $0.spaceID == target.spaceID
        }
        if let targetFrame = sectionFrames.first(where: { $0.sectionIndex == target.sectionIndex })?.frame {
            return targetFrame
        }

        if let previousFrame = sectionFrames.first(where: { $0.sectionIndex == target.sectionIndex - 1 })?.frame {
            return previousFrame
        }

        if let sectionFrame = sectionFrames.first?.frame {
            return sectionFrame
        }

        return emptySectionFrames.first {
            $0.section == target.section && $0.spaceID == target.spaceID
        }?.frame
    }

    private func dragPreviewAppTileSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        if
            let draggedTabID,
            let frame = appTabDropFrameList.first(where: { $0.tabID == draggedTabID })?.frame
        {
            return frame.size
        }

        let sectionIndex = min(max(target?.sectionIndex ?? 0, 0), max(appTabDropFrameList.count - 1, 0))
        if appTabDropFrameList.indices.contains(sectionIndex) {
            return appTabDropFrameList[sectionIndex].frame.size
        }

        let proposedFrameCount = proposedAppTabCountForDrag()
        return BrowserSidebarAppTabGridLayout(
            spacing: BrowserChromeLayout.appTabGridSpacing
        )
        .frames(
            for: proposedFrameCount,
            availableWidth: max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)
        )
        .dropFirst(min(max(target?.sectionIndex ?? 0, 0), max(proposedFrameCount - 1, 0)))
        .first?
        .size ?? CGSize(width: BrowserChromeLayout.sidebarRowHeight, height: BrowserChromeLayout.sidebarRowHeight)
    }

    private func proposedAppTabCountForDrag() -> Int {
        guard
            let draggedTabID,
            let draggedTab = snapshot.tab(withID: draggedTabID)
        else {
            return max(snapshot.appTabs.count, 1)
        }

        let proposedCount = snapshot.appTabs.count + (draggedTab.placement == .app ? 0 : 1)
        return min(max(proposedCount, 1), BrowserSidebarAppTabGridLayout.capacity)
    }

    private func resolvedTabDropTarget(at location: CGPoint) -> BrowserSidebarTabDropTarget? {
        BrowserSidebarTabDragTargetResolver(
            verticalSnapDistance: BrowserChromeLayout.sidebarTabDropVerticalSnapDistance,
            horizontalTolerance: BrowserChromeLayout.sidebarTabDropHorizontalTolerance
        )
        .target(
            for: location,
            rowFrames: tabDropRowFrameList,
            emptySectionFrames: emptySectionFrames,
            appTabFrames: appTabDropFrameList,
            appTabContainerFrame: appTabsContainerFrame,
            canMoveToTarget: canMoveDraggedTab(to:)
        )
    }

    private func setTabRowFrames(
        _ frames: [String: BrowserSidebarTabRowFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawTabRowFrames = frames
        updateSynchronizedTabFrames(for: snapshot)
    }

    private func updateSynchronizedTabFrames(for snapshot: BrowserSidebarSnapshot) {
        var synchronizedFrames: [String: BrowserSidebarTabRowFrame] = [:]
        var synchronizedDropFrames: [BrowserSidebarTabRowFrame] = []

        for space in snapshot.spaces {
            let spacePinnedTabIDs = snapshot.isPinnedSectionCollapsed(in: space.id) ? [] : snapshot.spacePinnedTabs(in: space.id).map(\.id)
            let temporaryTabIDs = snapshot.temporaryTabs(in: space.id).map(\.id)

            synchronizedFrames.merge(
                BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
                    rawTabRowFrames,
                    spacePinnedTabIDs: spacePinnedTabIDs,
                    temporaryTabIDs: temporaryTabIDs,
                    spaceID: space.id
                )
            ) { _, newValue in newValue }

            synchronizedDropFrames.append(
                contentsOf: BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
                    rawTabRowFrames,
                    fallbackRowFrames: tabDropRowFrameList,
                    emptySectionFrames: rawEmptySectionFrames,
                    spacePinnedTabIDs: spacePinnedTabIDs,
                    temporaryTabIDs: temporaryTabIDs,
                    rowHeight: BrowserChromeLayout.sidebarRowHeight,
                    rowSpacing: BrowserChromeLayout.sidebarListSpacing,
                    spaceID: space.id
                )
            )
        }

        tabRowFrames = synchronizedFrames
        tabDropRowFrameList = synchronizedDropFrames
    }

    private func setAppTabFrames(
        _ frames: [String: BrowserSidebarAppTabFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawAppTabFrames = frames
        updateSynchronizedAppTabFrames(for: snapshot)
    }

    private func setAppTabsContainerFrame(
        _ frame: CGRect?,
        for snapshot: BrowserSidebarSnapshot
    ) {
        appTabsContainerFrame = frame
        updateSynchronizedAppTabFrames(for: snapshot)
    }

    private func updateSynchronizedAppTabFrames(for snapshot: BrowserSidebarSnapshot) {
        let appTabIDs = snapshot.appTabs.map(\.id)
        appTabFrames = BrowserSidebarAppTabFrameSynchronizer.synchronizedFrames(
            rawAppTabFrames,
            appTabIDs: appTabIDs
        )
        appTabDropFrameList = BrowserSidebarAppTabFrameSynchronizer.dropFrameList(
            containerFrame: appTabsContainerFrame,
            appTabIDs: appTabIDs,
            spacing: BrowserChromeLayout.appTabGridSpacing
        )
    }

    private func setEmptySectionFrames(
        _ frames: [BrowserSidebarEmptySectionFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawEmptySectionFrames = frames
        emptySectionFrames = snapshot.spaces.flatMap { space in
            BrowserSidebarTabFrameSynchronizer.synchronizedEmptySectionFrames(
                frames,
                spacePinnedTabIDs: snapshot.isPinnedSectionCollapsed(in: space.id) ? [] : snapshot.spacePinnedTabs(in: space.id).map(\.id),
                temporaryTabIDs: snapshot.temporaryTabs(in: space.id).map(\.id),
                spaceID: space.id
            )
        }
        updateSynchronizedTabFrames(for: snapshot)
    }

    private func updateTopChromeDividerVisibility(_ shouldShow: Bool) {
        guard showsTopChromeDivider != shouldShow else {
            return
        }

        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            showsTopChromeDivider = shouldShow
        }
    }

    private func updateBottomChromeDividerVisibility(_ shouldShow: Bool) {
        guard showsBottomChromeDivider != shouldShow else {
            return
        }

        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            showsBottomChromeDivider = shouldShow
        }
    }

    private func setDropTarget(_ target: BrowserSidebarTabDropTarget?) {
        guard dropTarget != target else {
            return
        }

        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            dropTarget = target
        }

        if target != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func suppressSelectionAfterDrag(for tabID: String) {
        suppressedTabSelectionAfterDragID = tabID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard suppressedTabSelectionAfterDragID == tabID else {
                return
            }

            suppressedTabSelectionAfterDragID = nil
        }
    }

    private func canMoveDraggedTab(to target: BrowserSidebarTabDropTarget) -> Bool {
        guard let draggedTabID else {
            return false
        }

        return model.canMoveTab(
            withID: draggedTabID,
            toPlacement: target.section.placement,
            atSectionIndex: target.sectionIndex,
            targetSpaceID: target.spaceID
        )
    }

    private func moveDraggedTab(to target: BrowserSidebarTabDropTarget) {
        guard let draggedTabID else {
            return
        }

        dismissRenamingIfNeeded()
        clearTabDragState()

        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            model.moveTab(
                withID: draggedTabID,
                toPlacement: target.section.placement,
                atSectionIndex: target.sectionIndex,
                targetSpaceID: target.spaceID
            )
        }
    }

    private func clearTabDragState() {
        let hadTabDragState = draggedTabID != nil || dropTarget != nil || dragPreviewStore.preview != nil
        draggedTabID = nil
        dropTarget = nil
        dragPreviewStore.clear()

        if hadTabDragState {
            tabRowInteractionResetID += 1
        }
    }

    private func withoutSidebarDragAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }
}

extension BrowserSidebarView: Equatable {
    static func == (lhs: BrowserSidebarView, rhs: BrowserSidebarView) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.extensions == rhs.extensions
            && lhs.showsWindowControlsInSidebar == rhs.showsWindowControlsInSidebar
            && lhs.isCommandBarPresented == rhs.isCommandBarPresented
            && lhs.isCurrentPageCommandBarPresented == rhs.isCurrentPageCommandBarPresented
            && lhs.isSidebarResizing == rhs.isSidebarResizing
    }
}

private struct BrowserSidebarEmptySectionDropZone: View {
    let height: CGFloat
    let showsDropIndicator: Bool

    var body: some View {
        Color.clear
            .frame(height: height)
            .overlay(alignment: .center) {
                if showsDropIndicator, height > 0 {
                    BrowserSidebarDropIndicator()
                }
            }
            .contentShape(Rectangle())
    }
}

private struct BrowserSidebarAppTabsGrid: View {
    let tabs: [BrowserChromeModel.Tab]
    let draggedTabID: String?
    let isSidebarResizing: Bool
    let sidebarContentWidth: CGFloat
    let onSelect: (String) -> Void
    let onDragChanged: (String, DragGesture.Value) -> Void
    let onDragEnded: (String, DragGesture.Value) -> Void

    private let layout = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)

    var body: some View {
        let frames = layout.frames(for: tabs.count, availableWidth: sidebarContentWidth)

        ZStack(alignment: .topLeading) {
            if tabs.isEmpty {
                Color.clear
                    .frame(height: BrowserChromeLayout.sidebarEmptySectionDropZoneHeight)
            }

            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if frames.indices.contains(index) {
                    let frame = frames[index]
                    appTabTile(tab, sectionIndex: index)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: gridHeight, alignment: .top)
        .animation(BrowserChromeLayout.sidebarTabDropListAnimation, value: tabs.map(\.id))
        .browserSidebarAppTabsContainerFrame()
    }

    private var gridHeight: CGFloat {
        max(
            layout.height(for: tabs.count, availableWidth: sidebarContentWidth),
            BrowserChromeLayout.sidebarEmptySectionDropZoneHeight
        )
    }

    private func appTabTile(_ tab: BrowserChromeModel.Tab, sectionIndex: Int) -> some View {
        BrowserSidebarAppTabTile(
            tab: tab,
            isSidebarResizing: isSidebarResizing,
            onSelect: {
                onSelect(tab.id)
            }
        )
        .browserSidebarAppTabFrame(tabID: tab.id, sectionIndex: sectionIndex)
        .transition(BrowserChromeLayout.sidebarTabVisibilityTransition)
        .opacity(draggedTabID == tab.id ? 0 : 1)
        .allowsHitTesting(draggedTabID != tab.id)
        .simultaneousGesture(
            DragGesture(
                minimumDistance: BrowserChromeLayout.sidebarTabDragMinimumDistance,
                coordinateSpace: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
            )
            .onChanged { value in
                onDragChanged(tab.id, value)
            }
            .onEnded { value in
                onDragEnded(tab.id, value)
            }
        )
    }
}

private struct BrowserSidebarAppTabTile: View {
    let tab: BrowserChromeModel.Tab
    let isSidebarResizing: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
                    .fill(backgroundColor)

                BrowserFaviconView(url: tab.faviconURL, size: BrowserChromeLayout.appTabIconSize)
            }
            .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous))
        }
        .buttonStyle(
            BrowserSidebarPressTrackingButtonStyle { isPressed in
                self.isPressed = isPressed
            }
        )
        .scaleEffect(isPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isHovered = hovering
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            guard isSidebarResizing else {
                return
            }

            isHovered = false
            isPressed = false
        }
        .browserTooltip(
            title: tab.displayTitle,
            shortcut: nil,
            isPresented: isHovered && !isSidebarResizing
        )
    }

    private var backgroundColor: Color {
        isHovered ? BrowserChromePalette.currentURLRowHover : BrowserChromePalette.currentURLRow
    }
}

private struct BrowserSidebarTopChromeDivider: View {
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(BrowserChromePalette.sidebarTopChromeDivider)
            .frame(height: BrowserChromeLayout.sidebarTopChromeDividerHeight)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct BrowserSidebarTemporaryTabsDivider: View {
    let clearTemporaryTabsDescriptor: BrowserCommandDescriptor
    let showsClearButton: Bool
    let isClearButtonHovered: Bool
    let onHoverClearButton: (Bool) -> Void
    let onClear: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Rectangle()
                .fill(BrowserChromePalette.sidebarDivider)
                .frame(height: 1)

            if showsClearButton {
                Button(action: onClear) {
                    Text(BrowserStrings.sidebarClearTemporaryTabs)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            isClearButtonHovered
                                ? BrowserChromePalette.secondaryText
                                : BrowserChromePalette.sidebarClearButtonForeground
                        )
                        .padding(.horizontal, BrowserChromeLayout.sidebarClearButtonHorizontalPadding)
                        .padding(.vertical, BrowserChromeLayout.sidebarClearButtonVerticalPadding)
                        .background(BrowserChromePalette.sidebarBackground)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.12), value: isClearButtonHovered)
                .transition(.opacity)
                .onHover(perform: onHoverClearButton)
                .browserTooltip(
                    title: clearTemporaryTabsDescriptor.helpTitle,
                    shortcut: clearTemporaryTabsDescriptor.shortcut,
                    isPresented: isClearButtonHovered
                )
            }
        }
        .frame(height: BrowserChromeLayout.sidebarDividerHeight)
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: showsClearButton)
    }
}

private struct BrowserSpaceSwipeObserver: NSViewRepresentable {
    let canSwitchSpaces: Bool
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeNSView(context _: Context) -> BrowserSpaceSwipeNSView {
        let view = BrowserSpaceSwipeNSView()
        view.canSwitchSpaces = canSwitchSpaces
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        return view
    }

    func updateNSView(_ nsView: BrowserSpaceSwipeNSView, context _: Context) {
        nsView.canSwitchSpaces = canSwitchSpaces
        nsView.onSwipeLeft = onSwipeLeft
        nsView.onSwipeRight = onSwipeRight
    }
}

private final class BrowserSpaceSwipeNSView: NSView {
    var canSwitchSpaces = false
    var onSwipeLeft: () -> Void = {}
    var onSwipeRight: () -> Void = {}

    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeLocalMonitor()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeLocalMonitor()
        } else {
            installLocalMonitorIfNeeded()
        }
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard
                let self,
                canSwitchSpaces,
                let window,
                event.window === window
            else {
                return event
            }

            if event.deltaX < 0 {
                onSwipeLeft()
            } else if event.deltaX > 0 {
                onSwipeRight()
            } else {
                return event
            }

            return nil
        }
    }

    private func removeLocalMonitor() {
        guard let localMonitor else {
            return
        }

        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }
}

private struct BrowserPassthroughInteractionObserver: NSViewRepresentable {
    let eventMask: NSEvent.EventTypeMask
    let onInteraction: (NSEvent, NSView) -> Void

    init(
        eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown],
        onInteraction: @escaping () -> Void
    ) {
        self.eventMask = eventMask
        self.onInteraction = { _, _ in
            onInteraction()
        }
    }

    init(
        eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown],
        onInteraction: @escaping (NSEvent, NSView) -> Void
    ) {
        self.eventMask = eventMask
        self.onInteraction = onInteraction
    }

    func makeNSView(context _: Context) -> BrowserPassthroughInteractionNSView {
        let view = BrowserPassthroughInteractionNSView()
        view.eventMask = eventMask
        view.onInteraction = onInteraction
        return view
    }

    func updateNSView(_ nsView: BrowserPassthroughInteractionNSView, context _: Context) {
        nsView.eventMask = eventMask
        nsView.onInteraction = onInteraction
    }
}

private final class BrowserPassthroughInteractionNSView: NSView {
    var eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
        didSet {
            guard eventMask != oldValue else {
                return
            }

            reinstallLocalMonitorIfNeeded()
        }
    }

    var onInteraction: (NSEvent, NSView) -> Void = { _, _ in }

    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeLocalMonitor()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeLocalMonitor()
        } else {
            installLocalMonitorIfNeeded()
        }
    }

    private func reinstallLocalMonitorIfNeeded() {
        guard window != nil else {
            return
        }

        removeLocalMonitor()
        installLocalMonitorIfNeeded()
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self else {
                return event
            }

            guard let window, event.window === window else {
                return event
            }

            let frameInWindow = convert(bounds, to: nil)
            if frameInWindow.contains(event.locationInWindow) {
                onInteraction(event, self)
            }

            return event
        }
    }

    private func removeLocalMonitor() {
        guard let localMonitor else {
            return
        }

        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }
}

private struct BrowserWindowFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context _: Context) -> BrowserWindowFrameReaderNSView {
        let view = BrowserWindowFrameReaderNSView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: BrowserWindowFrameReaderNSView, context _: Context) {
        nsView.onFrameChange = onFrameChange
        nsView.scheduleFrameUpdate()
    }
}

private final class BrowserWindowFrameReaderNSView: NSView {
    var onFrameChange: (CGRect?) -> Void = { _ in }

    private var lastFrameInWindow: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFrameUpdate()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleFrameUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleFrameUpdate()
    }

    override func layout() {
        super.layout()
        scheduleFrameUpdate()
    }

    func scheduleFrameUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.sendFrameUpdateIfNeeded()
        }
    }

    private func sendFrameUpdateIfNeeded() {
        let frameInWindow = window.map { _ in convert(bounds, to: nil) }
        guard frameInWindow != lastFrameInWindow else {
            return
        }

        lastFrameInWindow = frameInWindow
        onFrameChange(frameInWindow)
    }
}

private struct BrowserWindowFullscreenState: Equatable {
    let isFullscreen: Bool
    let isTransitioning: Bool
}

private struct BrowserWindowFullscreenReader: NSViewRepresentable {
    let onFullscreenStateChange: (BrowserWindowFullscreenState) -> Void

    func makeNSView(context _: Context) -> BrowserWindowFullscreenReaderNSView {
        let view = BrowserWindowFullscreenReaderNSView()
        view.onFullscreenStateChange = onFullscreenStateChange
        return view
    }

    func updateNSView(_ nsView: BrowserWindowFullscreenReaderNSView, context _: Context) {
        nsView.onFullscreenStateChange = onFullscreenStateChange
        nsView.sendFullscreenStateIfNeeded()
    }
}

private final class BrowserWindowFullscreenReaderNSView: NSView {
    var onFullscreenStateChange: (BrowserWindowFullscreenState) -> Void = { _ in }

    private weak var observedWindow: NSWindow?
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastFullscreenState: BrowserWindowFullscreenState?

    deinit {
        removeNotificationObservers()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservedWindow()
        sendFullscreenStateIfNeeded()
    }

    func sendFullscreenStateIfNeeded() {
        sendFullscreenStateIfNeeded(
            BrowserWindowFullscreenState(
                isFullscreen: window?.styleMask.contains(.fullScreen) ?? false,
                isTransitioning: false
            )
        )
    }

    private func updateObservedWindow() {
        guard observedWindow !== window else {
            return
        }

        removeNotificationObservers()
        observedWindow = window

        guard let window else {
            return
        }

        addNotificationObserver(for: NSWindow.willEnterFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: true, isTransitioning: true)
            )
        }
        addNotificationObserver(for: NSWindow.didEnterFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: true, isTransitioning: false)
            )
        }
        addNotificationObserver(for: NSWindow.willExitFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: false, isTransitioning: true)
            )
        }
        addNotificationObserver(for: NSWindow.didExitFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: false, isTransitioning: false)
            )
        }
    }

    private func addNotificationObserver(
        for name: NSNotification.Name,
        window: NSWindow,
        handler: @escaping () -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: window,
            queue: .main
        ) { _ in
            handler()
        }
        notificationObservers.append(observer)
    }

    private func removeNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
    }

    private func sendFullscreenStateIfNeeded(_ fullscreenState: BrowserWindowFullscreenState) {
        guard lastFullscreenState != fullscreenState else {
            return
        }

        lastFullscreenState = fullscreenState
        onFullscreenStateChange(fullscreenState)
    }
}

private extension NSView {
    func containsWindowPoint<T: NSView>(_ windowPoint: NSPoint, inDescendantOfType descendantType: T.Type) -> Bool {
        if self is T, bounds.contains(convert(windowPoint, from: nil)) {
            return true
        }

        return subviews.contains {
            $0.containsWindowPoint(windowPoint, inDescendantOfType: descendantType)
        }
    }
}

private struct BrowserFindBarOverlay: View {
    @ObservedObject var model: BrowserChromeModel
    let blockedLeadingInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: blockedLeadingInset)
                    .allowsHitTesting(false)

                ZStack(alignment: .topTrailing) {
                    if model.isFindBarPresented {
                        BrowserFindBarPanel(model: model)
                            .padding(.top, BrowserChromeLayout.findBarTopInset)
                            .padding(.trailing, BrowserChromeLayout.findBarTrailingInset)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(
                    width: max(proxy.size.width - blockedLeadingInset, 0),
                    height: proxy.size.height,
                    alignment: .topTrailing
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(model.isFindBarPresented)
        .animation(.easeOut(duration: 0.12), value: model.isFindBarPresented)
    }
}

private struct BrowserFindBarPanel: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        HStack(spacing: BrowserChromeLayout.findBarContentSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: BrowserChromeLayout.findBarSymbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.secondaryText)
                .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

            ZStack(alignment: .leading) {
                if model.findQuery.isEmpty {
                    Text(BrowserStrings.findBarPlaceholder)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.findBarPlaceholder)
                        .allowsHitTesting(false)
                }

                BrowserFindQueryTextField(
                    text: $model.findQuery,
                    isFocused: model.isFindBarPresented,
                    focusRequestID: model.findBarFocusRequest,
                    onSubmit: model.findNextInPage,
                    onCancel: model.dismissFindBar
                )
            }
            .padding(.horizontal, 8)
            .frame(width: BrowserChromeLayout.findBarFieldWidth)
            .frame(height: BrowserChromeLayout.chromeButtonSize)
            .background(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.findBarFieldCornerRadius, style: .continuous)
                    .fill(BrowserChromePalette.findBarFieldTint)
            )

            BrowserChromeControlButton(
                systemImageName: "chevron.up",
                tooltipTitle: BrowserStrings.findBarPreviousMatch,
                tooltipShortcut: nil,
                isEnabled: canStepThroughMatches,
                pressEffect: .moveUp,
                action: model.findPreviousInPage
            )

            BrowserChromeControlButton(
                systemImageName: "chevron.down",
                tooltipTitle: BrowserStrings.findBarNextMatch,
                tooltipShortcut: nil,
                isEnabled: canStepThroughMatches,
                pressEffect: .moveDown,
                action: model.findNextInPage
            )

            BrowserChromeControlButton(
                systemImageName: "xmark",
                tooltipTitle: BrowserStrings.findBarClose,
                tooltipShortcut: nil,
                pressEffect: .compress,
                action: model.dismissFindBar
            )
        }
        .padding(.horizontal, BrowserChromeLayout.findBarHorizontalPadding)
        .frame(width: BrowserChromeLayout.findBarWidth, height: BrowserChromeLayout.findBarHeight)
        .background(panelBackground)
        .overlay(panelBorder)
        .shadow(color: Color.black.opacity(0.24), radius: 18, y: 8)
    }

    private var canStepThroughMatches: Bool {
        model.canStepThroughFindMatches
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.findBarCornerRadius, style: .continuous)
            .fill(BrowserChromePalette.findBarPanelTint)
            .background(
                BrowserVisualEffectView(material: .hudWindow)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.findBarCornerRadius,
                            style: .continuous
                        )
                    )
            )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.findBarCornerRadius, style: .continuous)
            .stroke(BrowserChromePalette.findBarPanelBorder, lineWidth: 1)
    }
}

private struct BrowserFindQueryTextField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let focusRequestID: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> BrowserFindNSTextField {
        let textField = BrowserFindNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: BrowserFindNSTextField, context: Context) {
        context.coordinator.update(text: $text, onSubmit: onSubmit, onCancel: onCancel)
        nsView.sync(text: text, shouldFocus: isFocused, focusRequestID: focusRequestID)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onSubmit: () -> Void
        private var onCancel: () -> Void

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? BrowserFindNSTextField else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            case #selector(NSResponder.selectAll(_:)):
                textView.selectAll(nil)
                return true
            default:
                return false
            }
        }
    }
}

private final class BrowserFindNSTextField: NSTextField {
    private var pendingFocus = false
    private var pendingSelectAll = false
    private var lastFocusRequestID = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: 13, weight: .medium)
        textColor = .white.withAlphaComponent(0.92)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        selectAllTextIfNeeded()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    func sync(text: String, shouldFocus: Bool, focusRequestID: Int) {
        if stringValue != text {
            stringValue = text
        }

        if focusRequestID != lastFocusRequestID {
            lastFocusRequestID = focusRequestID
            pendingSelectAll = shouldFocus
        }

        if shouldFocus, !pendingFocus {
            pendingSelectAll = true
        }

        pendingFocus = shouldFocus
        syncFocus(shouldFocus)
    }

    private func syncFocus(_ shouldFocus: Bool) {
        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard !isEditing else {
                applyEditorAppearance()
                selectAllTextIfNeeded()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, pendingFocus else {
                    return
                }

                _ = self.window?.makeFirstResponder(self)
                applyEditorAppearance()
                selectAllTextIfNeeded()
            }
            return
        }

        pendingSelectAll = false

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private func selectAllTextIfNeeded() {
        guard pendingSelectAll else {
            return
        }

        if let editor = currentEditor() as? NSTextView {
            editor.selectAll(nil)
            pendingSelectAll = false
            return
        }

        if window?.firstResponder === self {
            selectText(nil)
            pendingSelectAll = false
        }
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = .white
        editor.textColor = .white.withAlphaComponent(0.92)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13, weight: .medium)
        editor.textContainerInset = NSSize(width: 0, height: 1)
    }
}

private enum BrowserCommandBarOverlayStyle {
    case standard
    case compact(anchorFrame: CGRect?, sidebarWidth: CGFloat)

    var fontSize: CGFloat {
        switch self {
        case .standard:
            22
        case .compact:
            BrowserChromeLayout.compactCommandBarFontSize
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarSymbolSize
        case .compact:
            BrowserChromeLayout.compactCommandBarSymbolSize
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarCornerRadius
        case .compact:
            BrowserChromeLayout.compactCommandBarCornerRadius
        }
    }

    var fieldHeight: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarFieldHeight
        case .compact:
            BrowserChromeLayout.compactCommandBarFieldHeight
        }
    }

    var textFieldVerticalOffset: CGFloat {
        switch self {
        case .standard:
            0
        case .compact:
            BrowserChromeLayout.compactCommandBarTextFieldVerticalOffset
        }
    }

    var selectsTextOnFocus: Bool {
        switch self {
        case .standard:
            false
        case .compact:
            true
        }
    }
}

private enum BrowserCommandBarTextWidthMeasurer {
    static func width(for text: String, fontSize: CGFloat) -> CGFloat {
        let measuredText = text.isEmpty ? BrowserStrings.commandBarPlaceholder : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]

        return ceil((measuredText as NSString).size(withAttributes: attributes).width)
    }
}

private struct BrowserCommandBarFaviconCandidate: Equatable {
    let pageURLString: String
    let faviconURL: URL?

    init(tab: BrowserChromeModel.Tab) {
        pageURLString = tab.urlString
        faviconURL = tab.faviconURL
    }

    func faviconURL(for suggestion: BrowserCommandSuggestion?) -> URL? {
        guard
            let suggestion,
            suggestion.kind == .url,
            Self.matchesPageURL(suggestion.resolvedURLString, pageURLString)
        else {
            return nil
        }

        return faviconURL
    }

    private static func matchesPageURL(_ lhs: String, _ rhs: String) -> Bool {
        normalizedPageURLString(lhs) == normalizedPageURLString(rhs)
    }

    private static func normalizedPageURLString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }

        return components.url?.absoluteString ?? urlString
    }
}

private struct BrowserCommandBarOverlay: View {
    @EnvironmentObject private var faviconCache: BrowserFaviconCache
    @ObservedObject var model: BrowserCommandBarModel
    let blockedLeadingInset: CGFloat
    let style: BrowserCommandBarOverlayStyle
    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if model.isPresented {
                    dismissLayer(in: proxy.size)

                    panel
                        .frame(width: panelWidth(in: proxy.size), alignment: .top)
                        .background(panelBackground)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: style.cornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay(panelBorder)
                        .shadow(color: Color.black.opacity(0.38), radius: BrowserChromeLayout.commandBarShadowRadius, y: 18)
                        .offset(panelOffset(in: proxy.size))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(model.isPresented)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            inputField

            if !model.suggestions.isEmpty {
                Rectangle()
                    .fill(BrowserChromePalette.commandBarPanelBorder)
                    .frame(height: 1)
                    .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)

                BrowserCommandSuggestionList(
                    model: model,
                    faviconCandidate: faviconCandidate
                )
                .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
            }
        }
        .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
        .padding(.top, BrowserChromeLayout.commandBarOuterPadding)
        .padding(.bottom, model.suggestions.isEmpty ? BrowserChromeLayout.commandBarOuterPadding : 0)
    }

    private var inputField: some View {
        HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
            leadingIcon
                .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(BrowserStrings.commandBarPlaceholder)
                        .font(.system(size: style.fontSize, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.commandBarPlaceholder)
                        .allowsHitTesting(false)
                }

                BrowserCommandQueryTextField(
                    text: Binding(
                        get: { model.query },
                        set: { model.query = $0 }
                    ),
                    previewDisplayText: model.previewDisplayText,
                    inlineCompletionSuffix: model.inlineCompletionSuffix,
                    isFocused: model.isPresented,
                    focusRequestID: model.focusRequestID,
                    fontSize: style.fontSize,
                    selectAllOnFocus: style.selectsTextOnFocus,
                    onMoveUp: { model.moveSelection(by: -1) },
                    onMoveDown: { model.moveSelection(by: 1) },
                    onAcceptCompletion: { _ = model.acceptSelectedSuggestion() },
                    onSubmit: { model.submitSelection() },
                    onDismiss: { model.dismiss() }
                )
                .offset(y: style.textFieldVerticalOffset)
            }
        }
        .padding(
            .horizontal,
            BrowserChromeLayout.commandBarRowHorizontalPadding + BrowserChromeLayout.commandBarOuterPadding
        )
        .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
        .frame(minHeight: style.fieldHeight)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .fill(BrowserChromePalette.commandBarPanelTint)
            .background(
                BrowserVisualEffectView(material: .hudWindow)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: style.cornerRadius,
                            style: .continuous
                        )
                    )
            )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .stroke(BrowserChromePalette.commandBarPanelBorder, lineWidth: 1)
    }

    private var leadingSymbolName: String {
        model.selectedSuggestion?.systemImageName ?? "magnifyingglass"
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let cachedLeadingFavicon {
            Image(nsImage: cachedLeadingFavicon)
                .resizable()
                .scaledToFit()
                .frame(width: style.symbolSize, height: style.symbolSize)
        } else {
            Image(systemName: leadingSymbolName)
                .font(.system(size: style.symbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
        }
    }

    private var cachedLeadingFavicon: NSImage? {
        faviconCache.image(for: faviconCandidate?.faviconURL(for: model.selectedSuggestion))
    }

    private func dismissLayer(in availableSize: CGSize) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: blockedLeadingInset)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.dismiss()
                }
        }
        .frame(width: availableSize.width, height: availableSize.height, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private func panelWidth(in availableSize: CGSize) -> CGFloat {
        switch style {
        case .standard:
            return BrowserChromeLayout.commandBarWidth
        case let .compact(anchorFrame, sidebarWidth):
            let originX = compactPanelOriginX(anchorFrame: anchorFrame)
            let viewportMaximum = max(
                availableSize.width - originX - BrowserChromeLayout.compactCommandBarHorizontalViewportPadding,
                0
            )
            let maximumWidth = min(
                max(availableSize.width * BrowserChromeLayout.compactCommandBarMaximumWindowFraction, 0),
                viewportMaximum
            )
            let minimumWidth = min(
                max(
                    sidebarWidth,
                    BrowserChromeModel.minSidebarWidth
                        * BrowserChromeLayout.compactCommandBarMinimumSidebarMultiplier
                ),
                maximumWidth
            )
            let measuredWidth = BrowserCommandBarTextWidthMeasurer.width(
                for: model.previewDisplayText ?? model.query,
                fontSize: style.fontSize
            ) + BrowserChromeLayout.compactCommandBarTextWidthBuffer

            return max(min(max(measuredWidth, minimumWidth), maximumWidth), 0)
        }
    }

    private func panelOffset(in availableSize: CGSize) -> CGSize {
        switch style {
        case .standard:
            CGSize(
                width: max((availableSize.width - BrowserChromeLayout.commandBarWidth) / 2, 0),
                height: commandBarTopInset(for: availableSize.height)
            )
        case let .compact(anchorFrame, _):
            CGSize(
                width: compactPanelOriginX(anchorFrame: anchorFrame),
                height: compactPanelOriginY(anchorFrame: anchorFrame, availableHeight: availableSize.height)
            )
        }
    }

    private func compactPanelOriginX(anchorFrame: CGRect?) -> CGFloat {
        max(anchorFrame?.minX ?? BrowserChromeLayout.sidebarOuterPadding, BrowserChromeLayout.sidebarOuterPadding)
    }

    private func compactPanelOriginY(anchorFrame: CGRect?, availableHeight: CGFloat) -> CGFloat {
        if let anchorFrame {
            return max(
                availableHeight - anchorFrame.maxY + BrowserChromeLayout.compactCommandBarTopGap,
                BrowserChromeLayout.sidebarOuterPadding
            )
        }

        let fallbackY = BrowserChromeLayout.sidebarOuterPadding
            + BrowserChromeLayout.chromeButtonSize
            + BrowserChromeLayout.sidebarSectionSpacing

        return fallbackY + BrowserChromeLayout.compactCommandBarTopGap
    }

    private func commandBarTopInset(for availableHeight: CGFloat) -> CGFloat {
        min(
            max(
                availableHeight * BrowserChromeLayout.commandBarTopInsetFraction,
                BrowserChromeLayout.commandBarTopInsetMinimum
            ),
            BrowserChromeLayout.commandBarTopInsetMaximum
        )
    }
}

private struct BrowserCommandSuggestionList: View {
    @ObservedObject var model: BrowserCommandBarModel
    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: BrowserChromeLayout.commandBarSuggestionSpacing) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { _, suggestion in
                        BrowserCommandSuggestionRow(
                            suggestion: suggestion,
                            isSelected: model.selectedSuggestionID == suggestion.id,
                            faviconCandidate: faviconCandidate,
                            onPress: { model.submitSuggestion(id: suggestion.id) }
                        )
                        .id(suggestion.id)
                    }
                }
                .padding(.vertical, BrowserChromeLayout.commandBarSuggestionVerticalInset)
            }
            .frame(height: visibleHeight)
            .onChange(of: model.selectedSuggestionID) { _, selectedSuggestionID in
                guard let selectedSuggestionID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedSuggestionID, anchor: .center)
                }
            }
        }
    }

    private var visibleSuggestionCount: Int {
        min(model.suggestions.count, BrowserCommandBarModel.maximumVisibleSuggestions)
    }

    private var visibleHeight: CGFloat {
        guard visibleSuggestionCount > 0 else {
            return 0
        }

        return CGFloat(visibleSuggestionCount) * BrowserChromeLayout.commandBarSuggestionRowHeight
            + CGFloat(max(visibleSuggestionCount - 1, 0)) * BrowserChromeLayout.commandBarSuggestionSpacing
            + BrowserChromeLayout.commandBarSuggestionVerticalInset * 2
            + visibleViewportAllowance
    }

    private var visibleViewportAllowance: CGFloat {
        model.suggestions.count > visibleSuggestionCount
            ? BrowserChromeLayout.commandBarSuggestionViewportAllowance
            : 0
    }
}

private struct BrowserCommandSuggestionRow: View {
    @EnvironmentObject private var faviconCache: BrowserFaviconCache

    let suggestion: BrowserCommandSuggestion
    let isSelected: Bool
    let faviconCandidate: BrowserCommandBarFaviconCandidate?
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
                leadingIcon
                    .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

                Text(suggestion.displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrowserChromeLayout.commandBarRowHorizontalPadding)
            .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: BrowserChromeLayout.commandBarSuggestionRowHeight)
            .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((isSelected || isHovered) ? BrowserChromePalette.commandBarSuggestionSelected : Color.clear)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let cachedFavicon {
            Image(nsImage: cachedFavicon)
                .resizable()
                .scaledToFit()
                .frame(
                    width: BrowserChromeLayout.commandBarSymbolSize,
                    height: BrowserChromeLayout.commandBarSymbolSize
                )
        } else {
            Image(systemName: suggestion.systemImageName)
                .font(.system(size: BrowserChromeLayout.commandBarSymbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
        }
    }

    private var cachedFavicon: NSImage? {
        faviconCache.image(for: faviconCandidate?.faviconURL(for: suggestion))
    }
}

private struct BrowserCommandQueryTextField: NSViewRepresentable {
    @Binding var text: String
    let previewDisplayText: String?
    let inlineCompletionSuffix: String?
    let isFocused: Bool
    let focusRequestID: Int
    let fontSize: CGFloat
    let selectAllOnFocus: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onAcceptCompletion: () -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onAcceptCompletion: onAcceptCompletion,
            onSubmit: onSubmit,
            onDismiss: onDismiss
        )
    }

    func makeNSView(context: Context) -> BrowserCommandNSTextField {
        let textField = BrowserCommandNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.fontSize = fontSize
        textField.selectAllOnFocus = selectAllOnFocus
        return textField
    }

    func updateNSView(_ nsView: BrowserCommandNSTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onAcceptCompletion: onAcceptCompletion,
            onSubmit: onSubmit,
            onDismiss: onDismiss
        )

        nsView.syncCommandPresentation(
            text: text,
            previewDisplayText: previewDisplayText,
            inlineCompletionSuffix: inlineCompletionSuffix,
            shouldFocus: isFocused,
            focusRequestID: focusRequestID,
            fontSize: fontSize,
            selectAllOnFocus: selectAllOnFocus
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onMoveUp: () -> Void
        private var onMoveDown: () -> Void
        private var onAcceptCompletion: () -> Void
        private var onSubmit: () -> Void
        private var onDismiss: () -> Void

        init(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onAcceptCompletion: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onAcceptCompletion = onAcceptCompletion
            self.onSubmit = onSubmit
            self.onDismiss = onDismiss
        }

        func update(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onAcceptCompletion: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onAcceptCompletion = onAcceptCompletion
            self.onSubmit = onSubmit
            self.onDismiss = onDismiss
        }

        func controlTextDidChange(_ notification: Notification) {
            guard
                let textField = notification.object as? BrowserCommandNSTextField,
                !textField.isApplyingPresentation
            else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
            textField.clearFocusSelectionRequest()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMoveDown()
                return true
            case #selector(NSResponder.moveRight(_:)):
                guard
                    let textField = control as? BrowserCommandNSTextField,
                    textField.hasSuggestionPreview
                else {
                    return false
                }

                onAcceptCompletion()
                return true
            case #selector(NSResponder.selectAll(_:)):
                textView.selectAll(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onDismiss()
                return true
            default:
                return false
            }
        }
    }
}

private final class BrowserCommandNSTextField: NSTextField {
    fileprivate private(set) var isApplyingPresentation = false
    var selectAllOnFocus = false
    var fontSize: CGFloat = 22 {
        didSet {
            guard fontSize != oldValue else {
                return
            }

            applyFont()
            applyEditorAppearance()
        }
    }

    private var pendingFocus = false
    private var lastFocusRequestID = -1
    private var focusSelectionRequestID: Int?
    private var committedText = ""
    private var previewDisplayText: String?
    private var inlineCompletionSuffix: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        applyFont()
        textColor = NSColor.white.withAlphaComponent(0.92)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    var hasSuggestionPreview: Bool {
        guard previewDisplayText != nil else {
            return false
        }

        if let editor = currentEditor() as? NSTextView {
            return editor.string == desiredDisplayText
        }

        return stringValue == desiredDisplayText
    }

    func syncCommandPresentation(
        text: String,
        previewDisplayText: String?,
        inlineCompletionSuffix: String?,
        shouldFocus: Bool,
        focusRequestID: Int,
        fontSize: CGFloat,
        selectAllOnFocus: Bool
    ) {
        self.fontSize = fontSize
        self.selectAllOnFocus = selectAllOnFocus
        committedText = text
        self.previewDisplayText = previewDisplayText
        self.inlineCompletionSuffix = inlineCompletionSuffix
        pendingFocus = shouldFocus
        let shouldForceFocus = focusRequestID != lastFocusRequestID
        if shouldFocus, shouldForceFocus, selectAllOnFocus {
            focusSelectionRequestID = focusRequestID
        }
        lastFocusRequestID = focusRequestID
        syncDisplayedText()
        syncFocus(shouldFocus, force: shouldForceFocus)
    }

    func clearFocusSelectionRequest() {
        focusSelectionRequestID = nil
    }

    private func syncFocus(_ shouldFocus: Bool, force: Bool = false) {
        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard force || !isEditing else {
                syncDisplayedText()
                applyEditorAppearance()
                return
            }

            requestFocusOnNextRunLoop()
            return
        }

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private func requestFocusOnNextRunLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.focusIfPossible()

            DispatchQueue.main.async { [weak self] in
                self?.focusIfPossible()
            }
        }
    }

    private func focusIfPossible() {
        guard window != nil else {
            return
        }

        window?.makeKey()
        _ = window?.makeFirstResponder(self)
        syncDisplayedText()
        applyEditorAppearance()
    }

    private var desiredDisplayText: String {
        previewDisplayText ?? committedText
    }

    private var previewSelectionRange: NSRange? {
        guard let previewDisplayText, previewDisplayText != committedText else {
            return nil
        }

        if let inlineCompletionSuffix, !inlineCompletionSuffix.isEmpty {
            return NSRange(
                location: (committedText as NSString).length,
                length: (inlineCompletionSuffix as NSString).length
            )
        }

        return nil
    }

    private func syncDisplayedText() {
        let targetDisplayText = desiredDisplayText
        let targetSelectionRange = fullTextSelectionRange(for: targetDisplayText) ?? previewSelectionRange

        if let editor = currentEditor() as? NSTextView {
            let needsStringUpdate = editor.string != targetDisplayText || stringValue != targetDisplayText
            let needsPreviewSelection = targetSelectionRange != nil && editor.selectedRange() != targetSelectionRange
            let needsSelectionCollapse =
                targetSelectionRange == nil &&
                editor.string == targetDisplayText &&
                editor.selectedRange().length > 0

            guard needsStringUpdate || needsPreviewSelection || needsSelectionCollapse else {
                applyEditorAppearance()
                return
            }

            isApplyingPresentation = true
            stringValue = targetDisplayText
            editor.string = targetDisplayText

            if let targetSelectionRange {
                editor.setSelectedRange(targetSelectionRange)
            } else if needsStringUpdate || needsSelectionCollapse {
                editor.setSelectedRange(
                    NSRange(location: (targetDisplayText as NSString).length, length: 0)
                )
            }

            isApplyingPresentation = false
            applyEditorAppearance()
            return
        }

        guard stringValue != targetDisplayText else {
            return
        }

        isApplyingPresentation = true
        stringValue = targetDisplayText
        isApplyingPresentation = false
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = .white
        editor.textColor = .white.withAlphaComponent(0.92)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize, weight: .medium)
    }

    private func applyFont() {
        font = .systemFont(ofSize: fontSize, weight: .medium)
    }

    private func fullTextSelectionRange(for text: String) -> NSRange? {
        guard focusSelectionRequestID == lastFocusRequestID else {
            return nil
        }

        return NSRange(location: 0, length: (text as NSString).length)
    }
}

private struct BrowserSidebarTitleTextField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onBlur: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel, onBlur: onBlur)
    }

    func makeNSView(context: Context) -> BrowserSidebarRenameNSTextField {
        let textField = BrowserSidebarRenameNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: BrowserSidebarRenameNSTextField, context: Context) {
        context.coordinator.update(text: $text, onSubmit: onSubmit, onCancel: onCancel, onBlur: onBlur)

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        nsView.syncFocus(isFocused)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onSubmit: () -> Void
        private var onCancel: () -> Void
        private var onBlur: () -> Void
        private var suppressesNextBlur = false

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onBlur: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onBlur = onBlur
        }

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onBlur: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onBlur = onBlur
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func controlTextDidEndEditing(_: Notification) {
            if suppressesNextBlur {
                suppressesNextBlur = false
                return
            }

            onBlur()
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                suppressesNextBlur = true
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressesNextBlur = true
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class BrowserSidebarRenameNSTextField: NSTextField {
    private var pendingFocus = false
    private var pendingSelectAll = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: 12.5, weight: .medium)
        textColor = .white.withAlphaComponent(0.92)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 17)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        selectAllTextIfNeeded()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    func syncFocus(_ shouldFocus: Bool) {
        if shouldFocus, !pendingFocus {
            pendingSelectAll = true
        }

        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard !isEditing else {
                applyEditorAppearance()
                selectAllTextIfNeeded()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, pendingFocus else {
                    return
                }

                _ = self.window?.makeFirstResponder(self)
                applyEditorAppearance()
                selectAllTextIfNeeded()
            }
            return
        }

        pendingSelectAll = false

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private func selectAllTextIfNeeded() {
        guard pendingSelectAll else {
            return
        }

        if let editor = currentEditor() as? NSTextView {
            editor.selectAll(nil)
            pendingSelectAll = false
            return
        }

        if window?.firstResponder === self {
            selectText(nil)
            pendingSelectAll = false
        }
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = .white
        editor.textColor = .white.withAlphaComponent(0.92)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12.5, weight: .medium)
        editor.textContainerInset = NSSize(width: 0, height: 0.5)
    }
}

private struct BrowserVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}

private struct BrowserSidebarHeaderView: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let canStopLoading: Bool
    let canReload: Bool
    let shortcutStore: BrowserShortcutStore
    let showsWindowControlsInSidebar: Bool
    let onToggleSidebar: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onStopLoading: () -> Void
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: BrowserChromeLayout.windowControlsTrailingGap) {
                BrowserWindowControlsView(showsInSidebar: showsWindowControlsInSidebar)
                    .frame(height: BrowserChromeLayout.chromeButtonSize)
                    .fixedSize(horizontal: true, vertical: false)

                BrowserChromeControlButton(
                    systemImageName: "sidebar.left",
                    tooltipTitle: shortcutStore.descriptor(for: .toggleSidebar).helpTitle,
                    tooltipShortcut: shortcutStore.shortcut(for: .toggleSidebar),
                    pressEffect: .compress,
                    action: onToggleSidebar
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                BrowserChromeControlButton(
                    systemImageName: "arrow.backward",
                    tooltipTitle: shortcutStore.descriptor(for: .goBack).helpTitle,
                    tooltipShortcut: shortcutStore.shortcut(for: .goBack),
                    isEnabled: canGoBack,
                    pressEffect: .moveLeft,
                    action: onGoBack
                )

                BrowserChromeControlButton(
                    systemImageName: "arrow.forward",
                    tooltipTitle: shortcutStore.descriptor(for: .goForward).helpTitle,
                    tooltipShortcut: shortcutStore.shortcut(for: .goForward),
                    isEnabled: canGoForward,
                    pressEffect: .moveRight,
                    action: onGoForward
                )

                if canStopLoading {
                    BrowserChromeControlButton(
                        systemImageName: "xmark",
                        tooltipTitle: BrowserStrings.navigationStopLoading,
                        tooltipShortcut: nil,
                        isEnabled: canStopLoading,
                        pressEffect: .compress,
                        action: onStopLoading
                    )
                } else {
                    BrowserChromeControlButton(
                        systemImageName: "arrow.clockwise",
                        tooltipTitle: shortcutStore.descriptor(for: .reload).helpTitle,
                        tooltipShortcut: shortcutStore.shortcut(for: .reload),
                        isEnabled: canReload,
                        pressEffect: .rotateClockwise,
                        action: onReload
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: BrowserChromeLayout.chromeButtonSize)
    }
}

private struct BrowserSidebarSnapshot: Equatable {
    let spaces: [BrowserChromeModel.Space]
    let selectedSpaceID: String?
    let activeSpace: BrowserChromeModel.Space?
    let isActiveSpacePinnedSectionCollapsed: Bool
    let allTabs: [BrowserChromeModel.Tab]
    let appTabs: [BrowserChromeModel.Tab]
    let spacePinnedTabs: [BrowserChromeModel.Tab]
    let temporaryTabs: [BrowserChromeModel.Tab]
    let selectedTabID: String?
    let archivableTabIDs: Set<String>
    let canGoBack: Bool
    let canGoForward: Bool
    let canStopLoading: Bool
    let canReload: Bool

    var selectedTab: BrowserChromeModel.Tab? {
        guard let selectedTabID else {
            return nil
        }

        return tab(withID: selectedTabID)
    }

    func containsTab(withID tabID: String) -> Bool {
        allTabs.contains { $0.id == tabID }
    }

    func tab(withID tabID: String) -> BrowserChromeModel.Tab? {
        allTabs.first { $0.id == tabID }
    }

    func isPinnedSectionCollapsed(in spaceID: String) -> Bool {
        spaces.first { $0.id == spaceID }?.isPinnedSectionCollapsed ?? false
    }

    func spacePinnedTabs(in spaceID: String) -> [BrowserChromeModel.Tab] {
        allTabs.filter { $0.spaceID == spaceID && $0.placement == .spacePinned }
    }

    func temporaryTabs(in spaceID: String) -> [BrowserChromeModel.Tab] {
        allTabs.filter { $0.spaceID == spaceID && $0.placement == .temporary }
    }

    func replacingTabs(_ tabs: [BrowserChromeModel.Tab]) -> BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            spaces: spaces,
            selectedSpaceID: selectedSpaceID,
            activeSpace: activeSpace,
            isActiveSpacePinnedSectionCollapsed: isActiveSpacePinnedSectionCollapsed,
            allTabs: tabs,
            appTabs: tabs.filter { $0.placement == .app },
            spacePinnedTabs: tabs.filter { $0.spaceID == selectedSpaceID && $0.placement == .spacePinned },
            temporaryTabs: tabs.filter { $0.spaceID == selectedSpaceID && $0.placement == .temporary },
            selectedTabID: selectedTabID,
            archivableTabIDs: archivableTabIDs,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canStopLoading: canStopLoading,
            canReload: canReload
        )
    }
}

private struct BrowserSiteControlCenterPopover: View {
    let extensions: [BrowserExtension]
    let onManageExtensions: () -> Void
    let onAddExtension: () -> Void
    let onSelectExtension: (String) -> Void

    private var gridItems: [BrowserExtensionControlCenterItem] {
        BrowserExtensionControlCenterModel.gridItems(for: extensions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserChromeLayout.siteControlPopoverSpacing) {
            HStack(spacing: 10) {
                Text(BrowserStrings.extensionsSectionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Button(BrowserStrings.extensionsManageAction, action: onManageExtensions)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(BrowserChromeLayout.extensionTileSize), spacing: BrowserChromeLayout.extensionGridSpacing),
                    count: BrowserExtensionControlCenterModel.maximumVisibleTiles
                ),
                alignment: .leading,
                spacing: BrowserChromeLayout.extensionGridSpacing
            ) {
                ForEach(gridItems) { item in
                    BrowserExtensionControlCenterTile(
                        item: item,
                        onAddExtension: onAddExtension,
                        onSelectExtension: onSelectExtension
                    )
                }
            }
        }
        .padding(BrowserChromeLayout.siteControlPopoverPadding)
        .frame(width: BrowserChromeLayout.siteControlPopoverWidth, alignment: .topLeading)
    }
}

private struct BrowserExtensionControlCenterTile: View {
    let item: BrowserExtensionControlCenterItem
    let onAddExtension: () -> Void
    let onSelectExtension: (String) -> Void

    var body: some View {
        Button(action: performAction) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: BrowserChromeLayout.extensionTileCornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .controlBackgroundColor))

                tileIcon
                    .opacity(iconOpacity)
            }
            .frame(
                width: BrowserChromeLayout.extensionTileSize,
                height: BrowserChromeLayout.extensionTileSize
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var tileIcon: some View {
        switch item.kind {
        case let .installed(browserExtension):
            if let iconImage = browserExtension.iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: BrowserChromeLayout.extensionTileIconSize,
                        height: BrowserChromeLayout.extensionTileIconSize
                    )
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: BrowserChromeLayout.extensionTileIconSize, weight: .medium))
                    .foregroundStyle(.primary)
            }
        case .add:
            Image(systemName: "plus")
                .font(.system(size: BrowserChromeLayout.extensionTileIconSize, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var iconOpacity: Double {
        switch item.kind {
        case let .installed(browserExtension):
            browserExtension.isEnabled ? 1 : 0.38
        case .add:
            1
        }
    }

    private var accessibilityLabel: String {
        switch item.kind {
        case let .installed(browserExtension):
            browserExtension.name
        case .add:
            BrowserStrings.extensionsAddAction
        }
    }

    private func performAction() {
        switch item.kind {
        case let .installed(browserExtension):
            onSelectExtension(browserExtension.id)
        case .add:
            onAddExtension()
        }
    }
}

private struct BrowserSidebarCurrentURLRow: View {
    let tab: BrowserChromeModel.Tab?
    let extensions: [BrowserExtension]
    let copyLinkShortcut: BrowserKeyboardShortcut
    let isSearchPresented: Bool
    let isSidebarResizing: Bool
    let onFrameChange: (CGRect?) -> Void
    let onOpenSearch: () -> Void
    let onCopyURL: () -> Bool
    let onRefreshExtensions: () -> Void
    let onOpenExtensionsManager: () -> Void
    let onOpenExtensionStore: () -> Void
    let onOpenExtensionDetails: (String) -> Void

    @State private var isRowHovered = false
    @State private var isCopyHovered = false
    @State private var isSiteControlHovered = false
    @State private var didCopyURL = false
    @State private var isSiteControlCenterPresented = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpenSearch) {
                Text(displayURL)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.currentURLText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
                    .frame(height: BrowserChromeLayout.sidebarRowHeight)
                    .background(rowBackgroundShape)
                    .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
            }
            .buttonStyle(BrowserSidebarPressButtonStyle())
            .disabled(tab == nil)
            .browserTooltip(
                title: fullURLString,
                shortcut: nil,
                isPresented: isRowHovered && !isActionButtonHovered && !isSidebarResizing
            )

            actionButtonOverlay
                .opacity(showsActionButtons ? 1 : 0)
                .allowsHitTesting(showsActionButtons)
        }
        .frame(maxWidth: .infinity)
        .background {
            BrowserWindowFrameReader(onFrameChange: onFrameChange)
        }
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isRowHovered = hovering
            if !hovering {
                isCopyHovered = false
                isSiteControlHovered = false
            }
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            guard isSidebarResizing else {
                return
            }

            resetTransientInteractionState()
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            onFrameChange(nil)
            resetTransientInteractionState()
        }
    }

    private var actionButtonOverlay: some View {
        HStack(spacing: BrowserChromeLayout.sidebarCurrentURLButtonSpacing) {
            currentURLActionButton(
                systemImageName: didCopyURL ? "checkmark" : "link",
                tooltipTitle: BrowserStrings.tabCopyURLAction,
                tooltipShortcut: copyLinkShortcut,
                isHovered: isCopyHovered,
                onHover: { isCopyHovered = $0 },
                action: copyURL
            )

            currentURLActionButton(
                systemImageName: "slider.horizontal.3",
                tooltipTitle: BrowserStrings.siteControlCenterAction,
                tooltipShortcut: nil,
                isHovered: isSiteControlHovered,
                onHover: { isSiteControlHovered = $0 },
                action: { isSiteControlCenterPresented = true }
            )
            .popover(isPresented: $isSiteControlCenterPresented, arrowEdge: .trailing) {
                BrowserSiteControlCenterPopover(
                    extensions: extensions,
                    onManageExtensions: {
                        isSiteControlCenterPresented = false
                        onOpenExtensionsManager()
                    },
                    onAddExtension: {
                        isSiteControlCenterPresented = false
                        onOpenExtensionStore()
                    },
                    onSelectExtension: { extensionID in
                        isSiteControlCenterPresented = false
                        onOpenExtensionDetails(extensionID)
                    }
                )
                .onAppear(perform: onRefreshExtensions)
            }
        }
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .padding(.leading, BrowserChromeLayout.sidebarCloseButtonLeadingSpacing)
        .frame(
            width: BrowserChromeLayout.sidebarCurrentURLOverlayWidth,
            height: BrowserChromeLayout.sidebarRowHeight,
            alignment: .trailing
        )
        .background(actionButtonOverlayBackground)
    }

    private func currentURLActionButton(
        systemImageName: String,
        tooltipTitle: String,
        tooltipShortcut: BrowserKeyboardShortcut?,
        isHovered: Bool,
        onHover: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                    style: .continuous
                )
                .fill(isHovered ? BrowserChromePalette.currentURLButtonHoverResolved : Color.clear)

                ForEach([systemImageName], id: \.self) { imageName in
                    Image(systemName: imageName)
                        .font(.system(size: BrowserChromeLayout.sidebarCurrentURLButtonSymbolSize, weight: .bold))
                        .foregroundStyle(BrowserChromePalette.currentURLText)
                        .transition(.scale(scale: 0.58).combined(with: .opacity))
                }
            }
            .frame(
                width: BrowserChromeLayout.sidebarCurrentURLButtonSize,
                height: BrowserChromeLayout.sidebarCurrentURLButtonSize
            )
        }
        .animation(BrowserChromeLayout.currentURLCopyIconAnimation, value: systemImageName)
        .buttonStyle(BrowserSidebarCloseButtonStyle())
        .contentShape(
            RoundedRectangle(
                cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                style: .continuous
            )
        )
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            onHover(hovering)
        }
        .browserTooltip(
            title: tooltipTitle,
            shortcut: tooltipShortcut,
            isPresented: isHovered && !isSidebarResizing
        )
    }

    private var actionButtonOverlayBackground: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.clear,
                    rowBackgroundResolvedColor,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: BrowserChromeLayout.sidebarCurrentURLOverlayFadeWidth)

            rowBackgroundResolvedColor
                .frame(width: BrowserChromeLayout.sidebarCurrentURLOverlaySolidWidth)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
        )
    }

    private var rowBackgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
            .fill(rowBackgroundColor)
    }

    private var rowBackgroundColor: Color {
        isRowHovered || isSearchPresented
            ? BrowserChromePalette.currentURLRowHover
            : BrowserChromePalette.currentURLRow
    }

    private var rowBackgroundResolvedColor: Color {
        isRowHovered || isSearchPresented
            ? BrowserChromePalette.currentURLRowHoverResolved
            : BrowserChromePalette.currentURLRowResolved
    }

    private var showsActionButtons: Bool {
        isRowHovered && !isSidebarResizing && tab != nil
    }

    private var isActionButtonHovered: Bool {
        isCopyHovered || isSiteControlHovered
    }

    private var displayURL: String {
        guard let tab else {
            return BrowserStrings.newTabTitle
        }

        return BrowserURLDisplayFormatter.displayString(for: tab.urlString)
    }

    private var fullURLString: String {
        tab?.urlString ?? BrowserStrings.newTabTitle
    }

    private func copyURL() {
        guard onCopyURL() else {
            return
        }

        withAnimation(BrowserChromeLayout.currentURLCopyIconAnimation) {
            didCopyURL = true
        }
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }

            withAnimation(BrowserChromeLayout.currentURLCopyIconAnimation) {
                didCopyURL = false
            }
        }
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isCopyHovered = false
        isSiteControlHovered = false
        isSiteControlCenterPresented = false
    }
}

private struct BrowserContentEdgeDragRegions: View {
    let windowSize: CGSize
    let blockedLeadingWidth: CGFloat
    let leadingInset: CGFloat
    let topInset: CGFloat
    let trailingInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if topInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: max(windowSize.width - blockedLeadingWidth, 0), height: topInset)
                    .offset(x: blockedLeadingWidth)
            }

            if bottomInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: max(windowSize.width - blockedLeadingWidth, 0), height: bottomInset)
                    .offset(x: blockedLeadingWidth, y: max(windowSize.height - bottomInset, 0))
            }

            if trailingInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: trailingInset, height: windowSize.height)
                    .offset(x: max(windowSize.width - trailingInset, 0))
            }

            if leadingInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: leadingInset, height: windowSize.height)
                    .offset(x: blockedLeadingWidth)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }
}

private struct BrowserSidebarHoverRevealEdge: View {
    let onHoverChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover(perform: onHoverChange)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

private struct BrowserSidebarHoverOverlayDismissReader: NSViewRepresentable {
    let isPresented: Bool
    let sidebarFrame: CGRect
    let allowsPointerSyncDismissal: Bool
    let onPointerMovement: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context _: Context) -> BrowserSidebarHoverOverlayDismissNSView {
        let view = BrowserSidebarHoverOverlayDismissNSView()
        view.update(
            isPresented: isPresented,
            sidebarFrame: sidebarFrame,
            allowsPointerSyncDismissal: allowsPointerSyncDismissal,
            onPointerMovement: onPointerMovement,
            onDismiss: onDismiss
        )
        return view
    }

    func updateNSView(_ nsView: BrowserSidebarHoverOverlayDismissNSView, context _: Context) {
        nsView.update(
            isPresented: isPresented,
            sidebarFrame: sidebarFrame,
            allowsPointerSyncDismissal: allowsPointerSyncDismissal,
            onPointerMovement: onPointerMovement,
            onDismiss: onDismiss
        )
    }
}

private final class BrowserSidebarHoverOverlayDismissNSView: NSView {
    private var isPresented = false
    private var sidebarFrame: CGRect = .zero
    private var allowsPointerSyncDismissal = true
    private var onPointerMovement: () -> Void = {}
    private var onDismiss: () -> Void = {}
    private var trackingArea: NSTrackingArea?
    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeHoverTrackingArea()
        removeLocalMonitor()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        syncLocalMonitor()
        schedulePointerSync()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        schedulePointerSync()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeHoverTrackingArea()

        guard isPresented else {
            return
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMovement()
        dismissIfNeeded(for: event.locationInWindow)
    }

    override func mouseExited(with _: NSEvent) {
        guard isPresented else {
            return
        }

        onPointerMovement()
        dismissIfPointerIsPastSidebarTrailingEdge()
    }

    func update(
        isPresented: Bool,
        sidebarFrame: CGRect,
        allowsPointerSyncDismissal: Bool,
        onPointerMovement: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let shouldRefreshTracking = self.isPresented != isPresented
        let shouldSyncPointer = shouldRefreshTracking
            || self.sidebarFrame != sidebarFrame
            || self.allowsPointerSyncDismissal != allowsPointerSyncDismissal

        self.isPresented = isPresented
        self.sidebarFrame = sidebarFrame
        self.allowsPointerSyncDismissal = allowsPointerSyncDismissal
        self.onPointerMovement = onPointerMovement
        self.onDismiss = onDismiss

        if shouldRefreshTracking {
            updateTrackingAreas()
            syncLocalMonitor()
        }

        if shouldSyncPointer {
            schedulePointerSync()
        }
    }

    private func schedulePointerSync() {
        guard allowsPointerSyncDismissal else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.dismissIfPointerOutsideSidebar()
        }
    }

    private func dismissIfPointerOutsideSidebar() {
        guard isPresented, !bounds.isEmpty, let window else {
            return
        }

        dismissIfNeeded(for: window.mouseLocationOutsideOfEventStream)
    }

    private func dismissIfNeeded(for locationInWindow: NSPoint) {
        guard isPresented, !bounds.isEmpty, locationInWindow.x > sidebarFrameInWindow.maxX else {
            return
        }

        onDismiss()
    }

    private func syncLocalMonitor() {
        guard isPresented, window != nil else {
            removeLocalMonitor()
            return
        }

        installLocalMonitorIfNeeded()
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            handleMonitoredEvent(event)
            return event
        }
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
        guard isPresented,
              let sourceWindow = event.window,
              let targetWindow = window
        else {
            return
        }

        let locationInTargetWindow: NSPoint
        if sourceWindow === targetWindow {
            locationInTargetWindow = event.locationInWindow
        } else {
            let screenRect = sourceWindow.convertToScreen(
                NSRect(origin: event.locationInWindow, size: .zero)
            )
            locationInTargetWindow = targetWindow.convertFromScreen(screenRect).origin
        }

        onPointerMovement()
        dismissIfNeeded(for: locationInTargetWindow)
    }

    private func dismissIfPointerIsPastSidebarTrailingEdge() {
        guard isPresented, let window else {
            return
        }

        dismissIfNeeded(for: window.mouseLocationOutsideOfEventStream)
    }

    private var sidebarFrameInWindow: CGRect {
        convert(sidebarFrame, to: nil)
    }

    private func removeHoverTrackingArea() {
        guard let trackingArea else {
            return
        }

        removeTrackingArea(trackingArea)
        self.trackingArea = nil
    }

    private func removeLocalMonitor() {
        guard let localMonitor else {
            return
        }

        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }
}

private struct BrowserWindowDragRegion: View {
    var isEnabled = true

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .allowsHitTesting(isEnabled)
    }
}

private struct BrowserChromeControlButton: View {
    let systemImageName: String
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    var tooltipPlacement: BrowserTooltipPlacement = .belowLeading
    var isEnabled = true
    var isSelected = false
    var pressEffect: BrowserChromeControlPressEffect = .none
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                buttonShape
                    .fill(backgroundColor)

                Image(systemName: systemImageName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: BrowserChromeLayout.chromeButtonSymbolSize, weight: .semibold))
                    .foregroundColor(foregroundColor)
                    .offset(x: horizontalOffset, y: verticalOffset)
                    .rotationEffect(.degrees(rotationAngle))
                    .scaleEffect(scale)
            }
            .frame(
                width: BrowserChromeLayout.chromeButtonSize,
                height: BrowserChromeLayout.chromeButtonSize
            )
            .shadow(color: shadowColor, radius: shadowRadius)
        }
        .buttonStyle(BrowserChromeControlPressTrackingButtonStyle { isPressed in
            self.isPressed = isEnabled && isPressed
        })
        .disabled(!isEnabled)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        .onHover { hovering in
            isHovered = hovering
        }
        .browserTooltip(
            title: tooltipTitle,
            shortcut: tooltipShortcut,
            placement: tooltipPlacement,
            isPresented: isHovered
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
            style: .continuous
        )
    }

    private var effectiveIsPressed: Bool {
        isEnabled && isPressed
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return .clear
        }

        if effectiveIsPressed {
            return BrowserChromePalette.chromeButtonPressedBackground
        }

        if isHovered {
            return BrowserChromePalette.chromeButtonHoverBackground
        }

        return .clear
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonDisabledForeground
        }

        if effectiveIsPressed {
            return BrowserChromePalette.chromeButtonPressedForeground
        }

        if isHovered {
            return BrowserChromePalette.chromeButtonHoverForeground
        }

        if isSelected {
            return BrowserChromePalette.primaryText
        }

        return BrowserChromePalette.secondaryText
    }

    private var horizontalOffset: CGFloat {
        guard effectiveIsPressed else {
            return 0
        }

        switch pressEffect {
        case .moveLeft:
            return -2
        case .moveRight:
            return 2
        case .none, .compress, .moveUp, .moveDown, .rotateClockwise:
            return 0
        }
    }

    private var verticalOffset: CGFloat {
        guard effectiveIsPressed else {
            return 0
        }

        switch pressEffect {
        case .moveUp:
            return -2
        case .moveDown:
            return 2
        case .none, .compress, .moveLeft, .moveRight, .rotateClockwise:
            return 0
        }
    }

    private var rotationAngle: Double {
        guard effectiveIsPressed else {
            return 0
        }

        switch pressEffect {
        case .rotateClockwise:
            return 90
        case .none, .compress, .moveLeft, .moveRight, .moveUp, .moveDown:
            return 0
        }
    }

    private var scale: CGFloat {
        guard effectiveIsPressed else {
            return 1
        }

        switch pressEffect {
        case .compress:
            return 0.9
        case .none, .moveLeft, .moveRight, .moveUp, .moveDown, .rotateClockwise:
            return 1
        }
    }

    private var shadowColor: Color {
        guard isEnabled, isHovered || effectiveIsPressed else {
            return .clear
        }

        return BrowserChromePalette.chromeButtonHighlightGlow
    }

    private var shadowRadius: CGFloat {
        guard isEnabled, isHovered || effectiveIsPressed else {
            return 0
        }

        return effectiveIsPressed ? 10 : 8
    }
}

private enum BrowserTooltipPlacement {
    case belowLeading
    case aboveCapsule
}

private struct BrowserShortcutTooltipModifier: ViewModifier {
    @EnvironmentObject private var tooltipCoordinator: BrowserTooltipCoordinator

    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
    let isPresented: Bool

    @State private var tooltipID = UUID()

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: BrowserTooltipPreferenceKey.self, value: .bounds) { bounds in
                guard tooltipCoordinator.activeTooltipID == tooltipID else {
                    return []
                }

                return [
                    BrowserTooltipPreferenceEntry(
                        id: tooltipID,
                        bounds: bounds,
                        title: title,
                        caption: caption,
                        shortcut: shortcut,
                        placement: placement
                    ),
                ]
            }
            .onAppear {
                if isPresented {
                    tooltipCoordinator.setHovering(true, for: tooltipID)
                }
            }
            .onChange(of: isPresented) { _, isPresented in
                tooltipCoordinator.setHovering(isPresented, for: tooltipID)
            }
            .onDisappear {
                tooltipCoordinator.setHovering(false, for: tooltipID)
            }
    }
}

private extension View {
    func browserTooltip(
        title: String,
        caption: String? = nil,
        shortcut: BrowserKeyboardShortcut?,
        placement: BrowserTooltipPlacement = .belowLeading,
        isPresented: Bool
    ) -> some View {
        modifier(
            BrowserShortcutTooltipModifier(
                title: title,
                caption: caption,
                shortcut: shortcut,
                placement: placement,
                isPresented: isPresented
            )
        )
    }
}

private struct BrowserTooltipPreferenceEntry {
    let id: UUID
    let bounds: Anchor<CGRect>
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
}

private struct BrowserTooltipPreferenceKey: PreferenceKey {
    static var defaultValue: [BrowserTooltipPreferenceEntry] = []

    static func reduce(value: inout [BrowserTooltipPreferenceEntry], nextValue: () -> [BrowserTooltipPreferenceEntry]) {
        value.append(contentsOf: nextValue())
    }
}

private struct BrowserResolvedTooltipEntry {
    let id: UUID
    let sourceFrame: CGRect
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
}

private struct BrowserTooltipOverlay: View {
    let entries: [BrowserResolvedTooltipEntry]

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.id) { entry in
                    BrowserShortcutTooltip(
                        title: entry.title,
                        caption: entry.caption,
                        shortcut: entry.shortcut,
                        placement: entry.placement
                    )
                    .fixedSize()
                    .modifier(BrowserTooltipPlacementModifier(entry: entry))
                    .transition(transition(for: entry.placement))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: entries.map(\.id))
    }

    private func transition(for placement: BrowserTooltipPlacement) -> AnyTransition {
        switch placement {
        case .belowLeading:
            .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
        case .aboveCapsule:
            .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
        }
    }
}

private struct BrowserTooltipPlacementModifier: ViewModifier {
    let entry: BrowserResolvedTooltipEntry

    func body(content: Content) -> some View {
        switch entry.placement {
        case .belowLeading:
            content.offset(
                x: entry.sourceFrame.minX
                    + entry.sourceFrame.width * BrowserChromeLayout.tooltipAnchorXFraction,
                y: entry.sourceFrame.minY
                    + entry.sourceFrame.height * BrowserChromeLayout.tooltipAnchorYFraction
            )
        case .aboveCapsule:
            content.position(
                x: entry.sourceFrame.midX,
                y: entry.sourceFrame.minY - BrowserChromeLayout.tooltipVerticalGap - BrowserChromeLayout.tooltipKeyHeight
            )
        }
    }
}

private struct BrowserShortcutTooltip: View {
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement

    var body: some View {
        HStack(spacing: BrowserChromeLayout.tooltipContentSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.tooltipText)
                    .fixedSize()

                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.tooltipCaption)
                        .fixedSize()
                }
            }

            if let shortcut {
                BrowserShortcutKeyCapsView(shortcut: shortcut)
            }
        }
        .padding(.horizontal, BrowserChromeLayout.tooltipHorizontalPadding)
        .padding(.vertical, BrowserChromeLayout.tooltipVerticalPadding)
        .background(tooltipBackground)
        .fixedSize()
        .shadow(
            color: BrowserChromePalette.tooltipShadow,
            radius: 18,
            x: 0,
            y: 10
        )
    }

    private var tooltipBackground: some View {
        Group {
            switch placement {
            case .belowLeading:
                tooltipCornerShape
                    .fill(BrowserChromePalette.tooltipBackground)
                    .overlay(
                        tooltipCornerShape.stroke(
                            BrowserChromePalette.tooltipBorder,
                            lineWidth: BrowserChromeLayout.tooltipBorderWidth
                        )
                    )
            case .aboveCapsule:
                Capsule(style: .continuous)
                    .fill(BrowserChromePalette.tooltipBackground)
                    .overlay(
                        Capsule(style: .continuous).stroke(
                            BrowserChromePalette.tooltipBorder,
                            lineWidth: BrowserChromeLayout.tooltipBorderWidth
                        )
                    )
            }
        }
    }

    private var tooltipCornerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: BrowserChromeLayout.tooltipCornerRadius,
                bottomTrailing: BrowserChromeLayout.tooltipCornerRadius,
                topTrailing: BrowserChromeLayout.tooltipCornerRadius
            ),
            style: .continuous
        )
    }
}

private struct BrowserShortcutKeyCapsView: View {
    let shortcut: BrowserKeyboardShortcut

    var body: some View {
        HStack(spacing: BrowserChromeLayout.tooltipKeySpacing) {
            ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { _, keyCap in
                Text(keyCap)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.tooltipKeyText)
                    .padding(.horizontal, BrowserChromeLayout.tooltipKeyHorizontalPadding)
                    .frame(minWidth: BrowserChromeLayout.tooltipKeyHeight)
                    .frame(height: BrowserChromeLayout.tooltipKeyHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(BrowserChromePalette.tooltipKeyBackground)
                    )
                    .shadow(
                        color: BrowserChromePalette.tooltipKeyShadow,
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            }
        }
    }
}

private extension View {
    func browserKeyboardShortcut(_ shortcut: BrowserKeyboardShortcut) -> some View {
        keyboardShortcut(shortcut.swiftUIKeyEquivalent, modifiers: shortcut.swiftUIModifiers)
    }
}

private extension BrowserKeyboardShortcut {
    var swiftUIKeyEquivalent: KeyEquivalent {
        guard let keyEquivalent = keyEquivalent.first else {
            return KeyEquivalent(Character(" "))
        }

        return KeyEquivalent(keyEquivalent)
    }

    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []

        if modifiers.contains(.control) {
            result.insert(.control)
        }

        if modifiers.contains(.option) {
            result.insert(.option)
        }

        if modifiers.contains(.shift) {
            result.insert(.shift)
        }

        if modifiers.contains(.command) {
            result.insert(.command)
        }

        return result
    }
}

private enum BrowserChromeControlPressEffect {
    case none
    case compress
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case rotateClockwise
}

private struct BrowserChromeControlPressTrackingButtonStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isPressed)
            }
    }
}

private struct BrowserSidebarPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct BrowserSidebarPressTrackingButtonStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isPressed)
            }
    }
}

private struct BrowserSidebarCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? BrowserChromeLayout.sidebarCloseButtonPressedScale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct BrowserSidebarTabDragEventMonitor: NSViewRepresentable {
    let tabID: String
    let onDragged: (String, CGPoint) -> Void
    let onEnded: (String, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BrowserSidebarTabDragEventMonitorView {
        let view = BrowserSidebarTabDragEventMonitorView()
        context.coordinator.update(
            view: view,
            tabID: tabID,
            onDragged: onDragged,
            onEnded: onEnded
        )
        return view
    }

    func updateNSView(_ nsView: BrowserSidebarTabDragEventMonitorView, context: Context) {
        context.coordinator.update(
            view: nsView,
            tabID: tabID,
            onDragged: onDragged,
            onEnded: onEnded
        )
    }

    static func dismantleNSView(_: BrowserSidebarTabDragEventMonitorView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private weak var view: BrowserSidebarTabDragEventMonitorView?
        private var localMonitor: Any?
        private var tabID: String?
        private var onDragged: ((String, CGPoint) -> Void)?
        private var onEnded: ((String, CGPoint) -> Void)?

        func update(
            view: BrowserSidebarTabDragEventMonitorView,
            tabID: String,
            onDragged: @escaping (String, CGPoint) -> Void,
            onEnded: @escaping (String, CGPoint) -> Void
        ) {
            self.view = view
            self.tabID = tabID
            self.onDragged = onDragged
            self.onEnded = onEnded
            installMonitorIfNeeded()
        }

        func removeMonitor() {
            guard let localMonitor else {
                return
            }

            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        private func installMonitorIfNeeded() {
            guard localMonitor == nil else {
                return
            }

            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard
                let view,
                event.window === view.window,
                let tabID
            else {
                return
            }

            let location = view.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDragged:
                onDragged?(tabID, location)
            case .leftMouseUp:
                onEnded?(tabID, location)
                removeMonitor()
            default:
                break
            }
        }
    }
}

private final class BrowserSidebarTabDragEventMonitorView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

private enum BrowserSpaceIconCatalog {
    static let systemImageNames = [
        "square.grid.2x2",
        "briefcase",
        "house",
        "person",
        "book",
        "star",
        "hammer",
        "paintbrush",
        "terminal",
        "globe",
        "bolt",
        "heart",
    ]
}

private struct BrowserSidebarSpaceHeaderRow: View {
    let space: BrowserChromeModel.Space
    let isRenaming: Bool
    let isCollapsed: Bool
    let isSidebarResizing: Bool
    let interactionResetID: Int
    let onToggleCollapsed: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onChangeIcon: (String) -> Void

    @State private var isRowHovered = false
    @State private var isMenuHovered = false
    @State private var isRowPressed = false
    @State private var draftTitle = ""

    var body: some View {
        rowInteractionSurface
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                isRowHovered = hovering
                if !hovering {
                    isMenuHovered = false
                }
            }
            .onAppear {
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
            }
            .onChange(of: isRenaming) { _, isRenaming in
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
                if isRenaming {
                    isMenuHovered = false
                    isRowPressed = false
                }
            }
            .onChange(of: isSidebarResizing) { _, isSidebarResizing in
                guard isSidebarResizing else {
                    return
                }

                resetTransientInteractionState()
            }
            .onChange(of: interactionResetID) { _, _ in
                resetTransientInteractionState()
            }
            .onDisappear {
                resetTransientInteractionState()
            }
            .contextMenu {
                menuItems
            }
    }

    private var rowInteractionSurface: some View {
        ZStack(alignment: .trailing) {
            rowSurface

            rowSelectionButton
                .allowsHitTesting(!isRenaming)

            menuButtonOverlay
                .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        }
        .scaleEffect(isRowPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isRowPressed)
    }

    private var rowSelectionButton: some View {
        Button(action: onToggleCollapsed) {
            Color.clear
                .frame(
                    maxWidth: .infinity,
                    minHeight: BrowserChromeLayout.sidebarRowHeight,
                    maxHeight: BrowserChromeLayout.sidebarRowHeight
                )
                .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        }
        .buttonStyle(
            BrowserSidebarPressTrackingButtonStyle { isPressed in
                isRowPressed = isPressed
            }
        )
    }

    private var rowSurface: some View {
        HStack(spacing: 0) {
            Image(systemName: leadingSystemImageName)
                .font(.system(size: BrowserChromeLayout.sidebarNewTabSymbolSize, weight: .semibold))
                .foregroundStyle(leadingSymbolColor)
                .rotationEffect(leadingSymbolRotation)
                .animation(.easeInOut(duration: 0.14), value: isCollapsed)
                .frame(width: BrowserChromeLayout.sidebarRowContentSpacing + 10)

            Spacer(minLength: 0)
                .frame(width: BrowserChromeLayout.sidebarRowContentSpacing)

            if isRenaming {
                BrowserSidebarTitleTextField(
                    text: $draftTitle,
                    isFocused: isRenaming,
                    onSubmit: commitRename,
                    onCancel: cancelRename,
                    onBlur: commitRename
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: 1)
            } else {
                Text(space.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.trailing, showsMenuButton ? menuButtonReservedWidth : 0)
        .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: BrowserChromeLayout.sidebarRowHeight,
            maxHeight: BrowserChromeLayout.sidebarRowHeight,
            alignment: .leading
        )
        .background(backgroundShape)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
    }

    private var menuButtonOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
                .fill(isMenuHovered ? BrowserChromePalette.rowCloseHover : .clear)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: BrowserChromeLayout.sidebarCloseSymbolSize, weight: .bold))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .frame(
                        width: BrowserChromeLayout.sidebarCloseButtonSize,
                        height: BrowserChromeLayout.sidebarCloseButtonSize
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(BrowserSidebarCloseButtonStyle())
        }
        .frame(
            width: BrowserChromeLayout.sidebarCloseButtonSize,
            height: BrowserChromeLayout.sidebarCloseButtonSize
        )
        .contentShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isMenuHovered = hovering
        }
        .opacity(showsMenuButton ? 1 : 0)
        .allowsHitTesting(showsMenuButton)
        .frame(
            width: menuButtonReservedWidth,
            height: BrowserChromeLayout.sidebarCloseButtonSize,
            alignment: .trailing
        )
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(BrowserStrings.spaceRenameAction, action: beginRename)
        Menu(BrowserStrings.spaceChangeIconAction) {
            ForEach(BrowserSpaceIconCatalog.systemImageNames, id: \.self) { systemImageName in
                Button {
                    onChangeIcon(systemImageName)
                } label: {
                    Label(
                        systemImageName,
                        systemImage: space.systemImageName == systemImageName ? "checkmark" : systemImageName
                    )
                }
            }
        }
    }

    private var leadingSystemImageName: String {
        isShowingDisclosure ? "chevron.right" : space.systemImageName
    }

    private var leadingSymbolColor: Color {
        isShowingDisclosure ? BrowserChromePalette.secondaryText : BrowserChromePalette.primaryText
    }

    private var leadingSymbolRotation: Angle {
        isShowingDisclosure && !isCollapsed ? .degrees(90) : .zero
    }

    private var isShowingDisclosure: Bool {
        isRowHovered && !isRenaming
    }

    private var menuButtonReservedWidth: CGFloat {
        BrowserChromeLayout.sidebarCloseButtonSize + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    private var showsMenuButton: Bool {
        isRowHovered && !isRenaming
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
            .fill(isRowHovered ? BrowserChromePalette.rowHover : Color.clear)
    }

    private func beginRename() {
        draftTitle = space.title
        onBeginRename()
    }

    private func commitRename() {
        onCommitRename(draftTitle)
    }

    private func cancelRename() {
        draftTitle = space.title
        onCancelRename()
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isMenuHovered = false
        isRowPressed = false
    }

    private func syncDraftTitleIfNeeded(isRenaming: Bool) {
        guard isRenaming else {
            return
        }

        draftTitle = space.title
    }
}

private struct BrowserSidebarSpacesBar: View {
    let spaces: [BrowserChromeModel.Space]
    let selectedSpaceID: String?
    let isSidebarResizing: Bool
    let onSelectSpace: (String) -> Void
    let onCreateSpace: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: sideReserveWidth)

                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                                BrowserSidebarSpaceBarButton(
                                    space: space,
                                    shortcut: BrowserSpaceShortcuts.shortcut(forSpaceIndex: index),
                                    isSelected: selectedSpaceID == space.id,
                                    onSelect: {
                                        onSelectSpace(space.id)
                                    }
                                )
                            }
                        }
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: BrowserChromeLayout.chromeButtonSize,
                            alignment: .center
                        )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(height: BrowserChromeLayout.chromeButtonSize)

                Color.clear
                    .frame(width: sideReserveWidth)
            }

            BrowserSidebarCreateSpaceButton(
                onCreate: onCreateSpace
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: BrowserChromeLayout.chromeButtonSize)
        .allowsHitTesting(!isSidebarResizing)
    }

    private var sideReserveWidth: CGFloat {
        BrowserChromeLayout.chromeButtonSize + BrowserChromeLayout.chromeButtonSpacing
    }
}

private struct BrowserSidebarSpaceBarButton: View {
    let space: BrowserChromeModel.Space
    let shortcut: BrowserKeyboardShortcut?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        BrowserChromeControlButton(
            systemImageName: space.systemImageName,
            tooltipTitle: space.title,
            tooltipShortcut: shortcut,
            tooltipPlacement: .aboveCapsule,
            isSelected: isSelected,
            pressEffect: .compress,
            action: onSelect
        )
    }
}

private struct BrowserSidebarCreateSpaceButton: View {
    let onCreate: () -> Void

    var body: some View {
        BrowserChromeControlButton(
            systemImageName: "plus",
            tooltipTitle: BrowserStrings.spaceNewAction,
            tooltipShortcut: nil,
            tooltipPlacement: .aboveCapsule,
            pressEffect: .compress,
            action: onCreate
        )
    }
}

private struct BrowserSidebarTabDragPreviewOverlay: View {
    @ObservedObject var store: BrowserSidebarTabDragPreviewStore
    let snapshot: BrowserSidebarSnapshot

    var body: some View {
        if let preview = store.preview, let tab = snapshot.tab(withID: preview.tabID) {
            BrowserSidebarTabDragPreview(
                tab: tab,
                style: dragPreviewStyle(for: preview.size)
            )
            .equatable()
            .frame(width: preview.size.width, height: preview.size.height)
            .position(preview.center)
            .animation(BrowserChromeLayout.sidebarTabDragPreviewAnimation, value: preview.size)
            .allowsHitTesting(false)
        }
    }

    private func dragPreviewStyle(for size: CGSize) -> BrowserSidebarTabDragPreview.Style {
        abs(size.height - BrowserChromeLayout.sidebarRowHeight) > 0.5 ? .appTile : .row
    }
}

private struct BrowserSidebarTabDragPreview: View {
    enum Style {
        case row
        case appTile
    }

    let tab: BrowserChromeModel.Tab
    let style: Style

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
                    .fill(BrowserChromePalette.rowSelected)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
                    .stroke(BrowserChromePalette.sidebarDropIndicator.opacity(0.28), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(0.32),
                radius: BrowserChromeLayout.sidebarDragPreviewShadowRadius,
                y: BrowserChromeLayout.sidebarDragPreviewShadowY
            )
            .compositingGroup()
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .row:
            HStack(spacing: 0) {
                BrowserFaviconView(url: tab.faviconURL)
                Spacer(minLength: 0)
                    .frame(width: BrowserChromeLayout.sidebarRowContentSpacing)

                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
            .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: BrowserChromeLayout.sidebarRowHeight,
                maxHeight: BrowserChromeLayout.sidebarRowHeight,
                alignment: .leading
            )
        case .appTile:
            BrowserFaviconView(url: tab.faviconURL, size: BrowserChromeLayout.appTabIconSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

extension BrowserSidebarTabDragPreview: Equatable {}

private struct BrowserSidebarRow: View {
    let tab: BrowserChromeModel.Tab
    let copyLinkDescriptor: BrowserCommandDescriptor
    let archiveTabDescriptor: BrowserCommandDescriptor
    let isSelected: Bool
    let isRenaming: Bool
    let canArchiveTabsBelow: Bool
    let isSidebarResizing: Bool
    let interactionResetID: Int
    let onSelect: () -> Void
    let onCopyLink: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onClose: () -> Void
    let onArchiveTabsBelow: () -> Void

    @State private var isRowHovered = false
    @State private var isCloseHovered = false
    @State private var isRowPressed = false
    @State private var draftTitle = ""

    var body: some View {
        rowInteractionSurface
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                if isRenaming {
                    isRowHovered = hovering
                    if !hovering {
                        isCloseHovered = false
                    }
                    return
                }

                isRowHovered = hovering
                if !hovering {
                    isCloseHovered = false
                }
            }
            .onAppear {
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
            }
            .onChange(of: isRenaming) { _, isRenaming in
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
                if isRenaming {
                    isCloseHovered = false
                    isRowPressed = false
                }
            }
            .onChange(of: isSidebarResizing) { _, isSidebarResizing in
                guard isSidebarResizing else {
                    return
                }

                resetTransientInteractionState()
            }
            .onChange(of: interactionResetID) { _, _ in
                resetTransientInteractionState()
            }
            .onDisappear {
                resetTransientInteractionState()
            }
            .contextMenu {
                copyLinkMenuItem
                shareMenuItem
                Button(BrowserStrings.tabRenameAction, action: beginRename)
                Divider()
                archiveTabMenuItem
                Button(
                    BrowserStrings.tabArchiveTabsBelowAction,
                    role: .destructive,
                    action: onArchiveTabsBelow
                )
                .disabled(!canArchiveTabsBelow)
            }
    }

    private var rowInteractionSurface: some View {
        ZStack(alignment: .trailing) {
            rowSurface

            rowSelectionButton
                .allowsHitTesting(!isRenaming)

            closeButtonOverlay
                .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        }
        .scaleEffect(isRowPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isRowPressed)
    }

    private var rowSelectionButton: some View {
        Button(action: onSelect) {
            Color.clear
                .frame(
                    maxWidth: .infinity,
                    minHeight: BrowserChromeLayout.sidebarRowHeight,
                    maxHeight: BrowserChromeLayout.sidebarRowHeight
                )
                .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        }
        .buttonStyle(
            BrowserSidebarPressTrackingButtonStyle { isPressed in
                isRowPressed = isPressed
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    beginRename()
                }
        )
    }

    private var rowSurface: some View {
        let spacing = BrowserChromeLayout.sidebarRowContentSpacing

        return HStack(spacing: 0) {
            BrowserFaviconView(url: tab.faviconURL)
            Spacer(minLength: 0)
                .frame(width: spacing)

            if isRenaming {
                BrowserSidebarTitleTextField(
                    text: $draftTitle,
                    isFocused: isRenaming,
                    onSubmit: commitRename,
                    onCancel: cancelRename,
                    onBlur: commitRename
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: 1)
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.trailing, showsCloseButton ? closeButtonReservedWidth : 0)
        .contentShape(Rectangle())
        .browserTooltip(
            title: tab.displayTitle,
            caption: BrowserStrings.tabRenameTooltipCaption,
            shortcut: nil,
            isPresented: isRowHovered && !isCloseHovered && !isRenaming && !isSidebarResizing
        )
        .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: BrowserChromeLayout.sidebarRowHeight,
            maxHeight: BrowserChromeLayout.sidebarRowHeight,
            alignment: .leading
        )
        .background(backgroundShape)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
    }

    private var closeButtonBackgroundColor: Color {
        isCloseHovered ? BrowserChromePalette.rowCloseHover : .clear
    }

    private var closeButtonReservedWidth: CGFloat {
        BrowserChromeLayout.sidebarCloseButtonSize + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    private var showsCloseButton: Bool {
        isRowHovered && !isRenaming
    }

    private var closeButtonOverlay: some View {
        ZStack(alignment: .trailing) {
            Button(action: onClose) {
                ZStack {
                    RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
                        .fill(closeButtonBackgroundColor)

                    Image(systemName: "xmark")
                        .font(.system(size: BrowserChromeLayout.sidebarCloseSymbolSize, weight: .bold))
                        .foregroundStyle(BrowserChromePalette.rowCloseForeground)
                }
                .frame(
                    width: BrowserChromeLayout.sidebarCloseButtonSize,
                    height: BrowserChromeLayout.sidebarCloseButtonSize
                )
            }
            .buttonStyle(BrowserSidebarCloseButtonStyle())
            .contentShape(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
            )
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                isCloseHovered = hovering
            }
            .opacity(showsCloseButton ? 1 : 0)
            .allowsHitTesting(showsCloseButton)
        }
        .frame(
            width: closeButtonReservedWidth,
            height: BrowserChromeLayout.sidebarCloseButtonSize,
            alignment: .trailing
        )
        .browserTooltip(
            title: archiveTabDescriptor.helpTitle,
            shortcut: isSelected ? archiveTabDescriptor.shortcut : nil,
            isPresented: showsCloseButton && isCloseHovered && !isSidebarResizing
        )
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
            .fill(
                isSelected
                    ? BrowserChromePalette.rowSelected
                    : (isRowHovered ? BrowserChromePalette.rowHover : Color.clear)
            )
    }

    private func beginRename() {
        draftTitle = tab.userTitleOverride ?? tab.displayTitle
        onBeginRename()
    }

    private func commitRename() {
        onCommitRename(draftTitle)
    }

    private func cancelRename() {
        draftTitle = tab.userTitleOverride ?? tab.displayTitle
        onCancelRename()
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isCloseHovered = false
        isRowPressed = false
    }

    private func syncDraftTitleIfNeeded(isRenaming: Bool) {
        guard isRenaming else {
            return
        }

        draftTitle = tab.userTitleOverride ?? tab.displayTitle
    }

    @ViewBuilder
    private var copyLinkMenuItem: some View {
        if isSelected {
            Button(copyLinkDescriptor.menuTitle, action: onCopyLink)
                .browserKeyboardShortcut(copyLinkDescriptor.shortcut)
        } else {
            Button(copyLinkDescriptor.menuTitle, action: onCopyLink)
        }
    }

    @ViewBuilder
    private var archiveTabMenuItem: some View {
        if isSelected {
            Button(archiveTabDescriptor.menuTitle, role: .destructive, action: onClose)
                .browserKeyboardShortcut(archiveTabDescriptor.shortcut)
        } else {
            Button(archiveTabDescriptor.menuTitle, role: .destructive, action: onClose)
        }
    }

    @ViewBuilder
    private var shareMenuItem: some View {
        let sharingServices = BrowserShareMenuServiceProvider.sharingServices(for: sharingItems)

        if !sharingServices.isEmpty {
            Menu(BrowserStrings.tabShareAction) {
                ForEach(Array(sharingServices.enumerated()), id: \.offset) { _, service in
                    Button {
                        service.subject = tab.displayTitle
                        service.perform(withItems: sharingItems)
                    } label: {
                        Label {
                            Text(service.menuItemTitle)
                        } icon: {
                            Image(nsImage: service.image)
                        }
                    }
                }
            }
        }
    }

    private var sharingItems: [Any] {
        if let pageURL = tab.pageURL {
            return [pageURL]
        }

        return [NSString(string: tab.urlString)]
    }
}

private enum BrowserShareMenuServiceProvider {
    static func sharingServices(for items: [Any]) -> [NSSharingService] {
        let readingListMenuTitle = NSSharingService(named: .addToSafariReadingList)?.menuItemTitle

        return legacySharingServices(for: items).filter { service in
            guard let readingListMenuTitle else {
                return true
            }

            return service.menuItemTitle != readingListMenuTitle
        }
    }

    private static func legacySharingServices(for items: [Any]) -> [NSSharingService] {
        let selector = NSSelectorFromString("sharingServicesForItems:")

        guard NSSharingService.responds(to: selector),
              let result = NSSharingService.perform(selector, with: items as NSArray)?.takeUnretainedValue()
        else {
            return []
        }

        return result as? [NSSharingService] ?? []
    }
}

private struct BrowserSidebarDropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarDropIndicatorThickness / 2, style: .continuous)
            .fill(BrowserChromePalette.sidebarDropIndicator)
            .frame(height: BrowserChromeLayout.sidebarDropIndicatorThickness)
    }
}

private struct BrowserFaviconView: View {
    @EnvironmentObject private var faviconCache: BrowserFaviconCache

    let url: URL?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = faviconCache.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            await faviconCache.loadImageIfNeeded(from: url)
        }
    }

    private var placeholder: some View {
        Image(systemName: "globe")
            .resizable()
            .scaledToFit()
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .padding(1)
    }
}

private struct BrowserContentView: View {
    let hostView: NSView
    let isContextReady: Bool
    let hasSelectedTab: Bool
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool

    var body: some View {
        BrowserViewportHostRepresentable(
            hostView: hostView,
            cornerRadius: contentCornerRadius,
            maskedCorners: maskedContentCorners
        )
        .opacity(hasSelectedTab ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserChromePalette.shellBackground)
        .overlay {
            if !isContextReady {
                ZStack {
                    Rectangle()
                        .fill(BrowserChromePalette.contentBackground)

                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                        Text(BrowserStrings.loadingLaunchingBrowser)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.black.opacity(0.58))
                    }
                }
                .clipShape(contentShape)
            }
        }
    }

    private var contentCornerRadius: CGFloat {
        shouldRoundLeadingCorners || shouldRoundTrailingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0
    }

    private var shouldRoundLeadingCorners: Bool {
        isSidebarVisible || usesWindowContentInsets
    }

    private var shouldRoundTrailingCorners: Bool {
        usesWindowContentInsets
    }

    private var maskedContentCorners: CACornerMask {
        var corners: CACornerMask = []

        if shouldRoundLeadingCorners {
            corners.insert(.layerMinXMinYCorner)
            corners.insert(.layerMinXMaxYCorner)
        }

        if shouldRoundTrailingCorners {
            corners.insert(.layerMaxXMinYCorner)
            corners.insert(.layerMaxXMaxYCorner)
        }

        return corners
    }

    private var contentShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: shouldRoundLeadingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0,
                bottomLeading: shouldRoundLeadingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0,
                bottomTrailing: shouldRoundTrailingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0,
                topTrailing: shouldRoundTrailingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0
            ),
            style: .continuous
        )
    }
}

private struct BrowserDetachedControlsOverlayContent: View {
    @ObservedObject var model: BrowserChromeModel
    @ObservedObject var commandBarModel: BrowserCommandBarModel
    let blockedLeadingInset: CGFloat

    var body: some View {
        ZStack {
            BrowserFindBarOverlay(
                model: model,
                blockedLeadingInset: blockedLeadingInset
            )
            .zIndex(8)

            BrowserCommandBarOverlay(
                model: commandBarModel,
                blockedLeadingInset: blockedLeadingInset,
                style: .standard,
                faviconCandidate: nil
            )
            .zIndex(10)
        }
    }
}

private struct BrowserDetachedCurrentPageCommandBarOverlayContent: View {
    @ObservedObject var currentPageCommandBarModel: BrowserCommandBarModel
    let blockedLeadingInset: CGFloat
    let anchorFrame: CGRect?
    let sidebarWidth: CGFloat
    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    var body: some View {
        BrowserCommandBarOverlay(
            model: currentPageCommandBarModel,
            blockedLeadingInset: blockedLeadingInset,
            style: .compact(anchorFrame: anchorFrame, sidebarWidth: sidebarWidth),
            faviconCandidate: faviconCandidate
        )
        .zIndex(10)
    }
}

private struct BrowserDetachedSidebarHoverOverlayContent: View {
    @ObservedObject var model: BrowserChromeModel
    @EnvironmentObject private var tooltipCoordinator: BrowserTooltipCoordinator
    @EnvironmentObject private var faviconCache: BrowserFaviconCache

    let snapshot: BrowserSidebarSnapshot
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let isOverlayPresentation: Bool
    let showsOverlayBorder: Bool
    let roundsWindowLeadingCorners: Bool
    let sidebarWidth: CGFloat
    let sidebarHeight: CGFloat
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let isPresented: Bool
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    var body: some View {
        BrowserSidebarChromePresentationHost(
            content: BrowserSidebarChromeView(
                model: model,
                snapshot: snapshot,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar,
                isCommandBarPresented: isCommandBarPresented,
                isCurrentPageCommandBarPresented: isCurrentPageCommandBarPresented,
                isOverlayPresentation: isOverlayPresentation,
                showsOverlayBorder: showsOverlayBorder,
                roundsWindowLeadingCorners: roundsWindowLeadingCorners,
                onToggleSidebar: onToggleSidebar,
                onURLRowFrameChange: onURLRowFrameChange
            )
            .frame(width: sidebarWidth, height: sidebarHeight, alignment: .leading)
            .environmentObject(tooltipCoordinator)
            .environmentObject(faviconCache),
            contentSize: sidebarContentSize,
            contentOffset: sidebarContentOffset,
            cornerRadius: sidebarClipCornerRadius,
            maskedCorners: sidebarClipMaskedCorners,
            animationDuration: BrowserChromeLayout.sidebarAnimationDuration,
            animatesOffsetChanges: true
        )
        .frame(width: containerWidth, height: containerHeight, alignment: .topLeading)
    }

    private var sidebarXOffset: CGFloat {
        if isPresented {
            return isOverlayPresentation ? BrowserChromeLayout.sidebarHoverOverlayEdgeInset : 0
        }

        return -sidebarWidth
    }

    private var sidebarYOffset: CGFloat {
        isOverlayPresentation ? BrowserChromeLayout.sidebarHoverOverlayEdgeInset : 0
    }

    private var sidebarContentSize: CGSize {
        CGSize(
            width: max(sidebarWidth - dockedWindowBorderInset, 0),
            height: max(sidebarHeight - dockedWindowBorderInset * 2, 0)
        )
    }

    private var sidebarContentOffset: CGPoint {
        CGPoint(
            x: sidebarXOffset + dockedWindowBorderInset,
            y: sidebarYOffset + dockedWindowBorderInset
        )
    }

    private var dockedWindowBorderInset: CGFloat {
        guard !isOverlayPresentation, !showsOverlayBorder, roundsWindowLeadingCorners else {
            return 0
        }

        return BrowserChromeLayout.detachedSidebarWindowBorderInset
    }

    private var sidebarClipCornerRadius: CGFloat {
        if isOverlayPresentation || showsOverlayBorder {
            return BrowserChromeLayout.sidebarOverlayCornerRadius
        }

        return roundsWindowLeadingCorners ? BrowserWindowGeometry.windowCornerRadius : 0
    }

    private var sidebarClipMaskedCorners: CACornerMask {
        if isOverlayPresentation || showsOverlayBorder {
            return [
                .layerMinXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMinYCorner,
                .layerMaxXMaxYCorner,
            ]
        }

        guard roundsWindowLeadingCorners else {
            return []
        }

        return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }
}

private struct BrowserSidebarChromePresentationHost<Content: View>: NSViewRepresentable {
    let content: Content
    let contentSize: CGSize
    let contentOffset: CGPoint
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask
    let animationDuration: TimeInterval
    let animatesOffsetChanges: Bool

    func makeNSView(context _: Context) -> BrowserSidebarChromePresentationNSView<Content> {
        BrowserSidebarChromePresentationNSView(
            rootView: content,
            contentSize: contentSize,
            contentOffset: contentOffset,
            cornerRadius: cornerRadius,
            maskedCorners: maskedCorners,
            animationDuration: animationDuration,
            animatesOffsetChanges: animatesOffsetChanges
        )
    }

    func updateNSView(_ nsView: BrowserSidebarChromePresentationNSView<Content>, context _: Context) {
        nsView.update(
            rootView: content,
            contentSize: contentSize,
            contentOffset: contentOffset,
            cornerRadius: cornerRadius,
            maskedCorners: maskedCorners,
            animationDuration: animationDuration,
            animatesOffsetChanges: animatesOffsetChanges
        )
    }
}

private final class BrowserSidebarChromePresentationNSView<Content: View>: NSView {
    private var hostingView: NSHostingView<Content>
    private var contentSize: CGSize
    private var contentOffset: CGPoint
    private var cornerRadius: CGFloat
    private var maskedCorners: CACornerMask
    private var animationDuration: TimeInterval
    private var animatesOffsetChanges: Bool
    private var didApplyInitialFrame = false

    override var isFlipped: Bool {
        true
    }

    init(
        rootView: Content,
        contentSize: CGSize,
        contentOffset: CGPoint,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask,
        animationDuration: TimeInterval,
        animatesOffsetChanges: Bool
    ) {
        hostingView = NSHostingView(rootView: rootView)
        self.contentSize = contentSize
        self.contentOffset = contentOffset
        self.cornerRadius = cornerRadius
        self.maskedCorners = maskedCorners
        self.animationDuration = animationDuration
        self.animatesOffsetChanges = animatesOffsetChanges
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        hostingView.safeAreaRegions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)

        updateClipping()
        applyHostingFrame(animated: false)
        didApplyInitialFrame = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: Content,
        contentSize: CGSize,
        contentOffset: CGPoint,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask,
        animationDuration: TimeInterval,
        animatesOffsetChanges: Bool
    ) {
        let shouldAnimateOffset = didApplyInitialFrame
            && animatesOffsetChanges
            && self.contentOffset != contentOffset
            && self.contentSize == contentSize
            && animationDuration > 0

        hostingView.rootView = rootView
        self.contentSize = contentSize
        self.contentOffset = contentOffset
        self.cornerRadius = cornerRadius
        self.maskedCorners = maskedCorners
        self.animationDuration = animationDuration
        self.animatesOffsetChanges = animatesOffsetChanges

        updateClipping()
        applyHostingFrame(animated: shouldAnimateOffset)
        didApplyInitialFrame = true
    }

    private func updateClipping() {
        guard let layer, let hostingLayer = hostingView.layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = true
        hostingLayer.cornerRadius = max(cornerRadius, 0)
        hostingLayer.maskedCorners = maskedCorners
        hostingLayer.cornerCurve = .continuous
        hostingLayer.masksToBounds = true
        CATransaction.commit()
    }

    private func applyHostingFrame(animated: Bool) {
        let targetFrame = CGRect(origin: contentOffset, size: contentSize)
        guard !NSEqualRects(hostingView.frame, targetFrame) else {
            return
        }

        guard animated else {
            hostingView.frame = targetFrame
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            hostingView.animator().frame = targetFrame
        }
    }
}

private struct BrowserDetachedOverlayWindowRepresentable<Content: View>: NSViewRepresentable {
    let isVisible: Bool
    let isInteractive: Bool
    let contentFrameLeadingInset: CGFloat
    let content: Content

    func makeNSView(context _: Context) -> BrowserDetachedOverlayHostView<Content> {
        BrowserDetachedOverlayHostView(
            rootView: content,
            isVisible: isVisible,
            isInteractive: isInteractive,
            contentFrameLeadingInset: contentFrameLeadingInset
        )
    }

    func updateNSView(_ nsView: BrowserDetachedOverlayHostView<Content>, context _: Context) {
        nsView.update(
            rootView: content,
            isVisible: isVisible,
            isInteractive: isInteractive,
            contentFrameLeadingInset: contentFrameLeadingInset
        )
    }
}

private final class BrowserDetachedOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func performDrag(with event: NSEvent) {
        guard let parent else {
            super.performDrag(with: event)
            return
        }

        let screenRect = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero))
        let parentLocation = parent.convertFromScreen(screenRect).origin
        guard let parentEvent = NSEvent.mouseEvent(
            with: event.type,
            location: parentLocation,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: parent.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) else {
            parent.performDrag(with: event)
            return
        }

        parent.performDrag(with: parentEvent)
    }
}

private final class BrowserDetachedOverlayHostView<Content: View>: NSView {
    private var overlayPanel: BrowserDetachedOverlayPanel?
    private var hostingView: NSHostingView<Content>
    private var isVisible: Bool
    private var isInteractive: Bool
    private var contentFrameLeadingInset: CGFloat

    init(rootView: Content, isVisible: Bool, isInteractive: Bool, contentFrameLeadingInset: CGFloat) {
        hostingView = NSHostingView(rootView: rootView)
        self.isVisible = isVisible
        self.isInteractive = isInteractive
        self.contentFrameLeadingInset = contentFrameLeadingInset
        super.init(frame: .zero)
    }

    deinit {
        detachPanel()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPanel()
    }

    override func layout() {
        super.layout()
        syncPanelFrame()
    }

    func update(rootView: Content, isVisible: Bool, isInteractive: Bool, contentFrameLeadingInset: CGFloat) {
        hostingView.rootView = rootView
        self.isVisible = isVisible
        self.isInteractive = isInteractive
        self.contentFrameLeadingInset = contentFrameLeadingInset
        syncPanel()
    }

    private func syncPanel() {
        guard let window else {
            detachPanel()
            return
        }

        let panel = overlayPanel ?? makePanel()
        overlayPanel = panel
        panel.ignoresMouseEvents = !isInteractive
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.level = window.level

        guard isVisible else {
            panel.orderOut(nil)
            return
        }

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        } else {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }

        syncPanelFrame()
        panel.orderFront(nil)
    }

    private func makePanel() -> BrowserDetachedOverlayPanel {
        let panel = BrowserDetachedOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.safeAreaRegions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func syncPanelFrame() {
        guard let panel = overlayPanel, let window else {
            return
        }

        var windowFrame = convert(bounds, to: nil)
        if contentFrameLeadingInset > 0 {
            let inset = min(contentFrameLeadingInset, windowFrame.width)
            windowFrame.origin.x += inset
            windowFrame.size.width -= inset
        }

        let screenFrame = window.convertToScreen(windowFrame)
        guard !screenFrame.isEmpty else {
            panel.orderOut(nil)
            return
        }

        panel.setFrame(screenFrame, display: true)
    }

    private func detachPanel() {
        guard let overlayPanel else {
            return
        }

        overlayPanel.parent?.removeChildWindow(overlayPanel)
        overlayPanel.orderOut(nil)
    }
}

extension BrowserContentView: Equatable {
    static func == (lhs: BrowserContentView, rhs: BrowserContentView) -> Bool {
        ObjectIdentifier(lhs.hostView) == ObjectIdentifier(rhs.hostView)
            && lhs.isContextReady == rhs.isContextReady
            && lhs.hasSelectedTab == rhs.hasSelectedTab
            && lhs.isSidebarVisible == rhs.isSidebarVisible
            && lhs.usesWindowContentInsets == rhs.usesWindowContentInsets
    }
}

private struct BrowserViewportHostRepresentable: NSViewRepresentable {
    let hostView: NSView
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask

    func makeNSView(context _: Context) -> BrowserViewportClipView {
        let clipView = BrowserViewportClipView(hostView: hostView)
        clipView.updateClipping(cornerRadius: cornerRadius, maskedCorners: maskedCorners)
        return clipView
    }

    func updateNSView(_ nsView: BrowserViewportClipView, context _: Context) {
        nsView.update(hostView: hostView)
        nsView.updateClipping(cornerRadius: cornerRadius, maskedCorners: maskedCorners)
    }
}

private final class BrowserViewportClipView: NSView {
    private var hostedView: NSView

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(hostView: NSView) {
        hostedView = hostView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        attachHostedViewIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }

    func update(hostView: NSView) {
        guard hostedView !== hostView else {
            attachHostedViewIfNeeded()
            return
        }

        hostedView = hostView
        attachHostedViewIfNeeded()
        needsLayout = true
    }

    func updateClipping(cornerRadius: CGFloat, maskedCorners: CACornerMask) {
        guard let layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = max(cornerRadius, 0)
        layer.maskedCorners = maskedCorners
        CATransaction.commit()
    }

    private func attachHostedViewIfNeeded() {
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }

        hostedView.autoresizingMask = [.width, .height]
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }
}
