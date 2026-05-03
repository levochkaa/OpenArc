import AppKit
import QuartzCore
import SwiftUI

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
