import AppKit
import QuartzCore
import SwiftUI

private enum BrowserChromePalette {
    static let shellBackground = Color.black
    static let sidebarBackground = Color.black
    static let contentBackground = Color.white
    static let rowHover = Color.white.opacity(0.08)
    static let rowSelected = Color.white.opacity(0.14)
    static let rowCloseHover = Color.white.opacity(0.12)
    static let rowCloseForeground = Color.white.opacity(0.82)
    static let sidebarDivider = Color.white.opacity(0.12)
    static let sidebarClearButtonForeground = Color.white.opacity(0.3)
    static let sidebarDropIndicator = Color.white.opacity(0.96)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
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
    static let sidebarDragPreviewShadowRadius: CGFloat = 14
    static let sidebarDragPreviewShadowY: CGFloat = 8
    static let sidebarClearButtonHorizontalPadding: CGFloat = 8
    static let sidebarClearButtonVerticalPadding: CGFloat = 2
    static let sidebarResizeHitWidth: CGFloat = sidebarOuterPadding
    static let sidebarSnapThreshold: CGFloat = 10
    static let browserContentEdgeInset: CGFloat = BrowserWindowGeometry.browserContentEdgeInset
    static let chromeButtonSize: CGFloat = 28
    static let chromeButtonSymbolSize: CGFloat = 13.5
    static let chromeButtonCornerRadius: CGFloat = 9
    static let chromeButtonSpacing: CGFloat = 6
    static let windowControlsTrailingGap: CGFloat = 5
    static let commandBarWidth: CGFloat = 720
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
        sectionIndex: Int
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
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarEmptySectionFrame(section: BrowserSidebarTabSection) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarEmptySectionFramePreferenceKey.self,
                    value: [
                        BrowserSidebarEmptySectionFrame(
                            section: section,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserWindowDragGesture() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture(), including: .gesture)
            .allowsWindowActivationEvents(true)
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
    @State private var showsSidebarWindowControls: Bool
    @State private var isWindowFullscreen = false
    @StateObject private var tooltipCoordinator = BrowserTooltipCoordinator()

    init(model: BrowserChromeModel) {
        self.model = model
        _commandBarModel = ObservedObject(wrappedValue: model.commandBarModel)
        _showsSidebarWindowControls = State(initialValue: model.isSidebarVisible)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BrowserContentView(
                    hostView: model.hostView,
                    isContextReady: model.isContextReady,
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

                BrowserSidebarChromeView(
                    model: model,
                    snapshot: sidebarSnapshot,
                    showsWindowControlsInSidebar: showsSidebarWindowControls,
                    isCommandBarPresented: commandBarModel.isPresented
                )
                .frame(width: model.sidebarWidth, height: proxy.size.height, alignment: .leading)
                .offset(x: sidebarOffset)
                .allowsHitTesting(model.isSidebarVisible)
                .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)

                BrowserContentEdgeDragRegions(
                    windowSize: proxy.size,
                    blockedLeadingWidth: sidebarLayoutWidth,
                    leadingInset: browserContentLeadingInset,
                    topInset: browserContentTopInset,
                    trailingInset: browserContentTrailingInset,
                    bottomInset: browserContentBottomInset
                )
                .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)

                if commandBarModel.isPresented, sidebarLayoutWidth > 0 {
                    BrowserPassthroughInteractionObserver(
                        eventMask: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
                    ) {
                        DispatchQueue.main.async {
                            model.dismissCommandBar()
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
                        blockedLeadingInset: browserContentMinX
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(10)
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(BrowserChromePalette.shellBackground)
        .background {
            BrowserWindowFullscreenReader { isFullscreen in
                isWindowFullscreen = isFullscreen
            }
            .allowsHitTesting(false)
        }
        .clipped()
        .environmentObject(tooltipCoordinator)
        .overlayPreferenceValue(BrowserTooltipPreferenceKey.self) { values in
            GeometryReader { proxy in
                let tooltipEntries = values.map { entry in
                    BrowserResolvedTooltipEntry(
                        id: entry.id,
                        sourceFrame: proxy[entry.bounds],
                        title: entry.title,
                        caption: entry.caption,
                        shortcut: entry.shortcut
                    )
                }

                if usesDetachedBrowserOverlays {
                    BrowserDetachedOverlayWindowRepresentable(
                        isVisible: model.isFindBarPresented || commandBarModel.isPresented,
                        isInteractive: true,
                        contentFrameLeadingInset: browserContentMinX,
                        content: BrowserDetachedControlsOverlayContent(
                            model: model,
                            commandBarModel: commandBarModel,
                            blockedLeadingInset: 0
                        )
                        .environmentObject(tooltipCoordinator)
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
                showsSidebarWindowControls = true
            }
        }
        .onAnimationCompleted(for: sidebarVisibilityAnimationValue) { completedValue in
            showsSidebarWindowControls = model.isSidebarVisible || completedValue > 0
        }
    }

    private var sidebarLayoutWidth: CGFloat {
        model.isSidebarVisible ? model.sidebarWidth : 0
    }

    private var sidebarOffset: CGFloat {
        model.isSidebarVisible ? 0 : -model.sidebarWidth
    }

    private var sidebarVisibilityAnimationValue: CGFloat {
        model.isSidebarVisible ? 1 : 0
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

    private var usesDetachedBrowserOverlays: Bool {
        model.selectedTabUsesWindowedBrowser
    }

    private var sidebarSnapshot: BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            pinnedTabs: model.pinnedTabs,
            temporaryTabs: model.temporaryTabs,
            selectedTabID: model.selectedTabID,
            archivableTabIDs: Set(model.tabs.dropLast().map(\.id)),
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
    @State private var isSidebarResizing = false

    var body: some View {
        BrowserSidebarContainerView(
            model: model,
            snapshot: snapshot,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar,
            isCommandBarPresented: isCommandBarPresented,
            isSidebarResizing: isSidebarResizing
        )
        .overlay(alignment: .trailing) {
            BrowserSidebarResizeHandle(model: model, isSidebarResizing: $isSidebarResizing)
                .frame(width: BrowserChromeLayout.sidebarResizeHitWidth)
        }
    }
}

private struct BrowserSidebarContainerView: View {
    let model: BrowserChromeModel
    let snapshot: BrowserSidebarSnapshot
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isSidebarResizing: Bool

    var body: some View {
        BrowserSidebarView(
            model: model,
            snapshot: snapshot,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar,
            isCommandBarPresented: isCommandBarPresented,
            isSidebarResizing: isSidebarResizing
        )
        .equatable()
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

    func updateLocation(_ location: CGPoint) {
        guard var preview else {
            return
        }

        guard preview.location != location else {
            return
        }

        preview.location = location
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
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isSidebarResizing: Bool
    @State private var isNewTabButtonHovered = false
    @State private var isClearButtonHovered = false
    @State private var isSidebarHovered = false
    @State private var newTabButtonWindowFrame: CGRect?
    @State private var renamingTabID: String?
    @State private var draggedTabID: String?
    @State private var dropTarget: BrowserSidebarTabDropTarget?
    @StateObject private var dragPreviewStore = BrowserSidebarTabDragPreviewStore()
    @State private var suppressedTabSelectionAfterDragID: String?
    @State private var tabRowInteractionResetID = 0
    @State private var rawTabRowFrames: [String: BrowserSidebarTabRowFrame] = [:]
    @State private var tabRowFrames: [String: BrowserSidebarTabRowFrame] = [:]
    @State private var tabDropRowFrameList: [BrowserSidebarTabRowFrame] = []
    @State private var rawEmptySectionFrames: [BrowserSidebarEmptySectionFrame] = []
    @State private var emptySectionFrames: [BrowserSidebarEmptySectionFrame] = []

    var body: some View {
        let pinnedTabs = snapshot.pinnedTabs
        let temporaryTabs = snapshot.temporaryTabs

        VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            BrowserSidebarHeaderView(
                canGoBack: snapshot.canGoBack,
                canGoForward: snapshot.canGoForward,
                canStopLoading: snapshot.canStopLoading,
                canReload: snapshot.canReload,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar,
                onToggleSidebar: model.toggleSidebar,
                onGoBack: model.goBack,
                onGoForward: model.goForward,
                onStopLoading: model.stopLoadingCurrentTab,
                onReload: model.reloadCurrentTab
            )
            .zIndex(1)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: BrowserChromeLayout.sidebarListSpacing) {
                    if pinnedTabs.isEmpty {
                        emptySectionDropZone(for: .pinned)
                    }

                    ForEach(Array(pinnedTabs.enumerated()), id: \.element.id) { index, tab in
                        sidebarRow(for: tab, in: .pinned, sectionIndex: index)
                    }

                    BrowserSidebarTemporaryTabsDivider(
                        showsClearButton: isSidebarHovered && !temporaryTabs.isEmpty,
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
                            model.clearTemporaryTabs()
                        }
                    )

                    newTabButton

                    if temporaryTabs.isEmpty {
                        emptySectionDropZone(for: .temporary)
                    }

                    ForEach(Array(temporaryTabs.enumerated()), id: \.element.id) { index, tab in
                        sidebarRow(for: tab, in: .temporary, sectionIndex: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .coordinateSpace(name: BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
            .frame(maxWidth: .infinity)
            .browserWindowDragGesture()
            .onPreferenceChange(BrowserSidebarTabRowFramePreferenceKey.self) { frames in
                setTabRowFrames(frames, for: snapshot)
            }
            .onPreferenceChange(BrowserSidebarEmptySectionFramePreferenceKey.self) { frames in
                setEmptySectionFrames(frames, for: snapshot)
            }
            .background {
                BrowserWindowDragRegion()
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissRenamingIfNeeded()
                    })
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    tabDropIndicatorOverlay
                    tabDragPreviewOverlay
                }
            }
        }
        .padding(.top, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.leading, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.bottom, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .browserWindowDragGesture()
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
            setTabRowFrames(rawTabRowFrames, for: snapshot)
            setEmptySectionFrames(rawEmptySectionFrames, for: snapshot)

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

                BrowserWindowDragRegion()
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissRenamingIfNeeded()
                    })
            }
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
            title: BrowserCommands.newTab.helpTitle,
            shortcut: BrowserCommands.newTab.shortcut,
            isPresented: isNewTabButtonHovered && !isCommandBarPresented && !isSidebarResizing
        )
    }

    private var tabDragPreviewOverlay: some View {
        BrowserSidebarTabDragPreviewOverlay(
            store: dragPreviewStore,
            snapshot: snapshot
        )
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

    private func sidebarRow(
        for tab: BrowserChromeModel.Tab,
        in section: BrowserSidebarTabSection,
        sectionIndex: Int
    ) -> some View {
        BrowserSidebarRow(
            tab: tab,
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
                model.closeTab(id: tab.id)
            },
            onArchiveTabsBelow: {
                renamingTabID = nil
                model.closeTabsBelow(id: tab.id)
            }
        )
        .browserSidebarTabRowFrame(tabID: tab.id, section: section, sectionIndex: sectionIndex)
        .simultaneousGesture(tabDragGesture(for: tab.id))
    }

    private func emptySectionDropZone(for section: BrowserSidebarTabSection) -> some View {
        BrowserSidebarEmptySectionDropZone(
            showsDropIndicator: dropTarget == BrowserSidebarTabDropTarget(section: section, sectionIndex: 0)
        )
        .browserSidebarEmptySectionFrame(section: section)
    }

    private func dismissRenamingIfNeeded(in window: NSWindow? = NSApp.keyWindow) {
        guard let activeRenamingTabID = renamingTabID else {
            return
        }

        window?.makeFirstResponder(nil)

        DispatchQueue.main.async {
            guard renamingTabID == activeRenamingTabID else {
                return
            }

            renamingTabID = nil
        }
    }

    private func resignRenamingFirstResponderIfNeeded(for event: NSEvent, in observerView: NSView) {
        guard renamingTabID != nil,
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
        if let renamingTabID, renamingTabID != tabID {
            dismissRenamingIfNeeded()
        }

        DispatchQueue.main.async {
            renamingTabID = tabID
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
        updateDragPreviewLocation(value.location)
        setDropTarget(resolvedTabDropTarget(at: value.location))
    }

    private func finishTabDrag(for tabID: String, value: DragGesture.Value) {
        guard draggedTabID == tabID else {
            clearTabDragState()
            return
        }

        suppressSelectionAfterDrag(for: tabID)
        updateDragPreviewLocation(value.location)

        let target = resolvedTabDropTarget(at: value.location)
        setDropTarget(target)

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

    private func updateDragPreviewLocation(_ location: CGPoint) {
        withoutSidebarDragAnimation {
            dragPreviewStore.updateLocation(location)
        }
    }

    private func dragPreviewSourceFrame(for tabID: String, startLocation: CGPoint) -> CGRect {
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

    private func resolvedTabDropTarget(at location: CGPoint) -> BrowserSidebarTabDropTarget? {
        BrowserSidebarTabDragTargetResolver(
            verticalSnapDistance: BrowserChromeLayout.sidebarTabDropVerticalSnapDistance,
            horizontalTolerance: BrowserChromeLayout.sidebarTabDropHorizontalTolerance
        )
        .target(
            for: location,
            rowFrames: tabDropRowFrameList,
            emptySectionFrames: emptySectionFrames,
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
        let pinnedTabIDs = snapshot.pinnedTabs.map(\.id)
        let temporaryTabIDs = snapshot.temporaryTabs.map(\.id)
        let synchronizedFrames = BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
            rawTabRowFrames,
            pinnedTabIDs: pinnedTabIDs,
            temporaryTabIDs: temporaryTabIDs
        )

        tabRowFrames = synchronizedFrames
        tabDropRowFrameList = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
            rawTabRowFrames,
            fallbackRowFrames: tabDropRowFrameList,
            emptySectionFrames: rawEmptySectionFrames,
            pinnedTabIDs: pinnedTabIDs,
            temporaryTabIDs: temporaryTabIDs,
            rowHeight: BrowserChromeLayout.sidebarRowHeight,
            rowSpacing: BrowserChromeLayout.sidebarListSpacing
        )
    }

    private func setEmptySectionFrames(
        _ frames: [BrowserSidebarEmptySectionFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawEmptySectionFrames = frames
        emptySectionFrames = BrowserSidebarTabFrameSynchronizer.synchronizedEmptySectionFrames(
            frames,
            pinnedTabIDs: snapshot.pinnedTabs.map(\.id),
            temporaryTabIDs: snapshot.temporaryTabs.map(\.id)
        )
        updateSynchronizedTabFrames(for: snapshot)
    }

    private func setDropTarget(_ target: BrowserSidebarTabDropTarget?) {
        guard dropTarget != target else {
            return
        }

        withoutSidebarDragAnimation {
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
            toPinnedState: target.section.isPinned,
            atSectionIndex: target.sectionIndex
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
                toPinnedState: target.section.isPinned,
                atSectionIndex: target.sectionIndex
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
            && lhs.showsWindowControlsInSidebar == rhs.showsWindowControlsInSidebar
            && lhs.isCommandBarPresented == rhs.isCommandBarPresented
            && lhs.isSidebarResizing == rhs.isSidebarResizing
    }
}

private struct BrowserSidebarEmptySectionDropZone: View {
    let showsDropIndicator: Bool

    var body: some View {
        Color.clear
            .frame(height: BrowserChromeLayout.sidebarEmptySectionDropZoneHeight)
            .overlay(alignment: .center) {
                if showsDropIndicator {
                    BrowserSidebarDropIndicator()
                }
            }
            .contentShape(Rectangle())
    }
}

private struct BrowserSidebarTemporaryTabsDivider: View {
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
                    title: BrowserCommands.clearTemporaryTabs.helpTitle,
                    shortcut: BrowserCommands.clearTemporaryTabs.shortcut,
                    isPresented: isClearButtonHovered
                )
            }
        }
        .frame(height: BrowserChromeLayout.sidebarDividerHeight)
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: showsClearButton)
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

private struct BrowserWindowFullscreenReader: NSViewRepresentable {
    let onFullscreenChange: (Bool) -> Void

    func makeNSView(context _: Context) -> BrowserWindowFullscreenReaderNSView {
        let view = BrowserWindowFullscreenReaderNSView()
        view.onFullscreenChange = onFullscreenChange
        return view
    }

    func updateNSView(_ nsView: BrowserWindowFullscreenReaderNSView, context _: Context) {
        nsView.onFullscreenChange = onFullscreenChange
        nsView.sendFullscreenChangeIfNeeded()
    }
}

private final class BrowserWindowFullscreenReaderNSView: NSView {
    var onFullscreenChange: (Bool) -> Void = { _ in }

    private weak var observedWindow: NSWindow?
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastIsFullscreen: Bool?

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
        sendFullscreenChangeIfNeeded()
    }

    func sendFullscreenChangeIfNeeded() {
        let isFullscreen = window?.styleMask.contains(.fullScreen) ?? false
        sendFullscreenChangeIfNeeded(isFullscreen)
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
            self?.sendFullscreenChangeIfNeeded(true)
        }
        addNotificationObserver(for: NSWindow.didEnterFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenChangeIfNeeded(true)
        }
        addNotificationObserver(for: NSWindow.didExitFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenChangeIfNeeded(false)
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

    private func sendFullscreenChangeIfNeeded(_ isFullscreen: Bool) {
        guard lastIsFullscreen != isFullscreen else {
            return
        }

        lastIsFullscreen = isFullscreen
        onFullscreenChange(isFullscreen)
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

private struct BrowserCommandBarOverlay: View {
    @ObservedObject var model: BrowserCommandBarModel
    let blockedLeadingInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if model.isPresented {
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
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        inputField

                        if !model.suggestions.isEmpty {
                            Rectangle()
                                .fill(BrowserChromePalette.commandBarPanelBorder)
                                .frame(height: 1)
                                .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)

                            BrowserCommandSuggestionList(model: model)
                                .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
                        }
                    }
                    .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
                    .padding(.top, BrowserChromeLayout.commandBarOuterPadding)
                    .padding(.bottom, model.suggestions.isEmpty ? BrowserChromeLayout.commandBarOuterPadding : 0)
                    .frame(width: BrowserChromeLayout.commandBarWidth, alignment: .top)
                    .background(panelBackground)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.commandBarCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay(panelBorder)
                    .shadow(color: Color.black.opacity(0.38), radius: BrowserChromeLayout.commandBarShadowRadius, y: 18)
                    .padding(.top, commandBarTopInset(for: proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(model.isPresented)
    }

    private var inputField: some View {
        HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
            Image(systemName: leadingSymbolName)
                .font(.system(size: BrowserChromeLayout.commandBarSymbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(BrowserStrings.commandBarPlaceholder)
                        .font(.system(size: 22, weight: .medium))
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
                    onMoveUp: { model.moveSelection(by: -1) },
                    onMoveDown: { model.moveSelection(by: 1) },
                    onAcceptCompletion: { _ = model.acceptSelectedSuggestion() },
                    onSubmit: { model.submitSelection() },
                    onDismiss: { model.dismiss() }
                )
            }
        }
        .padding(
            .horizontal,
            BrowserChromeLayout.commandBarRowHorizontalPadding + BrowserChromeLayout.commandBarOuterPadding
        )
        .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
        .frame(minHeight: BrowserChromeLayout.commandBarFieldHeight)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.commandBarCornerRadius, style: .continuous)
            .fill(BrowserChromePalette.commandBarPanelTint)
            .background(
                BrowserVisualEffectView(material: .hudWindow)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.commandBarCornerRadius,
                            style: .continuous
                        )
                    )
            )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.commandBarCornerRadius, style: .continuous)
            .stroke(BrowserChromePalette.commandBarPanelBorder, lineWidth: 1)
    }

    private var leadingSymbolName: String {
        model.selectedSuggestion?.systemImageName ?? "magnifyingglass"
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: BrowserChromeLayout.commandBarSuggestionSpacing) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { _, suggestion in
                        BrowserCommandSuggestionRow(
                            suggestion: suggestion,
                            isSelected: model.selectedSuggestionID == suggestion.id,
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
    let suggestion: BrowserCommandSuggestion
    let isSelected: Bool
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
                Image(systemName: suggestion.systemImageName)
                    .font(.system(size: BrowserChromeLayout.commandBarSymbolSize, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.primaryText)
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
}

private struct BrowserCommandQueryTextField: NSViewRepresentable {
    @Binding var text: String
    let previewDisplayText: String?
    let inlineCompletionSuffix: String?
    let isFocused: Bool
    let focusRequestID: Int
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
            focusRequestID: focusRequestID
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

    private var pendingFocus = false
    private var lastFocusRequestID = -1
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
        font = .systemFont(ofSize: 22, weight: .medium)
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
        focusRequestID: Int
    ) {
        committedText = text
        self.previewDisplayText = previewDisplayText
        self.inlineCompletionSuffix = inlineCompletionSuffix
        pendingFocus = shouldFocus
        syncDisplayedText()
        let shouldForceFocus = focusRequestID != lastFocusRequestID
        lastFocusRequestID = focusRequestID
        syncFocus(shouldFocus, force: shouldForceFocus)
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
        let targetSelectionRange = previewSelectionRange

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
                    tooltipTitle: BrowserCommands.toggleSidebar.helpTitle,
                    tooltipShortcut: BrowserCommands.toggleSidebar.shortcut,
                    pressEffect: .compress,
                    action: onToggleSidebar
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                BrowserChromeControlButton(
                    systemImageName: "arrow.backward",
                    tooltipTitle: BrowserCommands.goBack.helpTitle,
                    tooltipShortcut: BrowserCommands.goBack.shortcut,
                    isEnabled: canGoBack,
                    pressEffect: .moveLeft,
                    action: onGoBack
                )

                BrowserChromeControlButton(
                    systemImageName: "arrow.forward",
                    tooltipTitle: BrowserCommands.goForward.helpTitle,
                    tooltipShortcut: BrowserCommands.goForward.shortcut,
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
                        tooltipTitle: BrowserCommands.reload.helpTitle,
                        tooltipShortcut: BrowserCommands.reload.shortcut,
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
    let pinnedTabs: [BrowserChromeModel.Tab]
    let temporaryTabs: [BrowserChromeModel.Tab]
    let selectedTabID: String?
    let archivableTabIDs: Set<String>
    let canGoBack: Bool
    let canGoForward: Bool
    let canStopLoading: Bool
    let canReload: Bool

    func containsTab(withID tabID: String) -> Bool {
        pinnedTabs.contains { $0.id == tabID } || temporaryTabs.contains { $0.id == tabID }
    }

    func tab(withID tabID: String) -> BrowserChromeModel.Tab? {
        pinnedTabs.first { $0.id == tabID } ?? temporaryTabs.first { $0.id == tabID }
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

private struct BrowserWindowDragRegion: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

private struct BrowserChromeControlButton: View {
    let systemImageName: String
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    var isEnabled = true
    var pressEffect: BrowserChromeControlPressEffect = .none
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: BrowserChromeLayout.chromeButtonSymbolSize, weight: .semibold))
        }
        .buttonStyle(
            BrowserChromeControlButtonStyle(
                isEnabled: isEnabled,
                isHovered: isHovered,
                pressEffect: pressEffect
            )
        )
        .disabled(!isEnabled)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        .onHover { hovering in
            isHovered = hovering
        }
        .browserTooltip(
            title: tooltipTitle,
            shortcut: tooltipShortcut,
            isPresented: isHovered
        )
    }
}

private struct BrowserShortcutTooltipModifier: ViewModifier {
    @EnvironmentObject private var tooltipCoordinator: BrowserTooltipCoordinator

    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
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
                        shortcut: shortcut
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
        isPresented: Bool
    ) -> some View {
        modifier(
            BrowserShortcutTooltipModifier(
                title: title,
                caption: caption,
                shortcut: shortcut,
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
}

private struct BrowserTooltipOverlay: View {
    let entries: [BrowserResolvedTooltipEntry]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.id) { entry in
                    BrowserShortcutTooltip(
                        title: entry.title,
                        caption: entry.caption,
                        shortcut: entry.shortcut
                    )
                    .fixedSize()
                    .offset(
                        x: entry.sourceFrame.minX
                            + entry.sourceFrame.width * BrowserChromeLayout.tooltipAnchorXFraction,
                        y: entry.sourceFrame.minY
                            + entry.sourceFrame.height * BrowserChromeLayout.tooltipAnchorYFraction
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: entries.map(\.id))
    }
}

private struct BrowserShortcutTooltip: View {
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?

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
        tooltipShape
            .fill(BrowserChromePalette.tooltipBackground)
            .overlay(
                tooltipShape.stroke(
                    BrowserChromePalette.tooltipBorder,
                    lineWidth: BrowserChromeLayout.tooltipBorderWidth
                )
            )
    }

    private var tooltipShape: UnevenRoundedRectangle {
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

private struct BrowserChromeControlButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isHovered: Bool
    let pressEffect: BrowserChromeControlPressEffect

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        let buttonShape = RoundedRectangle(
            cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
            style: .continuous
        )

        return ZStack {
            buttonShape
                .fill(backgroundColor(isPressed: isPressed))

            configuration.label
                .foregroundStyle(foregroundColor(isPressed: isPressed))
                .offset(
                    x: horizontalOffset(isPressed: isPressed),
                    y: verticalOffset(isPressed: isPressed)
                )
                .rotationEffect(.degrees(rotationAngle(isPressed: isPressed)))
                .scaleEffect(scale(isPressed: isPressed))
        }
        .frame(
            width: BrowserChromeLayout.chromeButtonSize,
            height: BrowserChromeLayout.chromeButtonSize
        )
        .shadow(
            color: shadowColor(isPressed: isPressed),
            radius: shadowRadius(isPressed: isPressed)
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return .clear
        }

        if isPressed {
            return BrowserChromePalette.chromeButtonPressedBackground
        }

        if isHovered {
            return BrowserChromePalette.chromeButtonHoverBackground
        }

        return .clear
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonDisabledForeground
        }

        if isPressed {
            return BrowserChromePalette.chromeButtonPressedForeground
        }

        return BrowserChromePalette.secondaryText
    }

    private func horizontalOffset(isPressed: Bool) -> CGFloat {
        guard isPressed else {
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

    private func verticalOffset(isPressed: Bool) -> CGFloat {
        guard isPressed else {
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

    private func rotationAngle(isPressed: Bool) -> Double {
        guard isPressed else {
            return 0
        }

        switch pressEffect {
        case .rotateClockwise:
            return 90
        case .none, .compress, .moveLeft, .moveRight, .moveUp, .moveDown:
            return 0
        }
    }

    private func scale(isPressed: Bool) -> CGFloat {
        guard isPressed else {
            return 1
        }

        switch pressEffect {
        case .compress:
            return 0.9
        case .none, .moveLeft, .moveRight, .moveUp, .moveDown, .rotateClockwise:
            return 1
        }
    }

    private func shadowColor(isPressed: Bool) -> Color {
        guard isEnabled, isHovered || isPressed else {
            return .clear
        }

        return BrowserChromePalette.chromeButtonHighlightGlow
    }

    private func shadowRadius(isPressed: Bool) -> CGFloat {
        guard isEnabled, isHovered || isPressed else {
            return 0
        }

        return isPressed ? 10 : 8
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

private struct BrowserSidebarTabDragPreviewOverlay: View {
    @ObservedObject var store: BrowserSidebarTabDragPreviewStore
    let snapshot: BrowserSidebarSnapshot

    var body: some View {
        if let preview = store.preview, let tab = snapshot.tab(withID: preview.tabID) {
            BrowserSidebarTabDragPreview(tab: tab)
                .equatable()
                .frame(width: preview.size.width, height: preview.size.height)
                .position(preview.center)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .allowsHitTesting(false)
        }
    }
}

private struct BrowserSidebarTabDragPreview: View {
    let tab: BrowserChromeModel.Tab

    var body: some View {
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
}

extension BrowserSidebarTabDragPreview: Equatable {
    static func == (lhs: BrowserSidebarTabDragPreview, rhs: BrowserSidebarTabDragPreview) -> Bool {
        lhs.tab == rhs.tab
    }
}

private struct BrowserSidebarRow: View {
    let tab: BrowserChromeModel.Tab
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

    @ViewBuilder
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
            title: BrowserStrings.tabArchiveTooltip,
            shortcut: nil,
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
            Button(BrowserCommands.copyLink.menuTitle, action: onCopyLink)
                .browserKeyboardShortcut(BrowserCommands.copyLink.shortcut)
        } else {
            Button(BrowserCommands.copyLink.menuTitle, action: onCopyLink)
        }
    }

    @ViewBuilder
    private var archiveTabMenuItem: some View {
        if isSelected {
            Button(BrowserCommands.archiveTab.menuTitle, role: .destructive, action: onClose)
                .browserKeyboardShortcut(BrowserCommands.archiveTab.shortcut)
        } else {
            Button(BrowserCommands.archiveTab.menuTitle, role: .destructive, action: onClose)
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

        return deprecatedSharingServices(for: items).filter { service in
            guard let readingListMenuTitle else {
                return true
            }

            return service.menuItemTitle != readingListMenuTitle
        }
    }

    /// AppKit's newer picker API exposes a ready-made "Share…" item, not a submenu.
    @available(macOS, deprecated: 13.0)
    private static func deprecatedSharingServices(for items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
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
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 14, height: 14)
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
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool

    var body: some View {
        BrowserViewportHostRepresentable(
            hostView: hostView,
            cornerRadius: contentCornerRadius,
            maskedCorners: maskedContentCorners
        )
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
                blockedLeadingInset: blockedLeadingInset
            )
            .zIndex(10)
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
        panel.level = .floating
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
