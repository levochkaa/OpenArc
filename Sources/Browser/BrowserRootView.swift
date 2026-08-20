import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserRootView

struct BrowserRootView: View {
    // MARK: Lifecycle

    init(model: BrowserChromeModel, updateController: BrowserUpdateController) {
        self.model = model
        _commandBarModel = ObservedObject(wrappedValue: model.commandBarModel)
        _currentPageCommandBarModel = ObservedObject(wrappedValue: model.currentPageCommandBarModel)
        _shortcutStore = ObservedObject(wrappedValue: model.shortcutStore)
        _preferences = ObservedObject(wrappedValue: model.userPreferencesStore)
        _bookmarksModel = ObservedObject(wrappedValue: model.bookmarksModel)
        _updateController = ObservedObject(wrappedValue: updateController)
        _showsSidebarWindowControls = State(initialValue: model.isSidebarVisible)
    }

    // MARK: Internal

    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BrowserChromeBackgroundView(mode: chromeBackgroundMode)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                BrowserScreenFrameReader { screenFrame in
                    rootViewScreenFrame = screenFrame
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
                .zIndex(-1)

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
                .animation(
                    .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                    value: model.isSidebarVisible
                )
                .animation(
                    .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                    value: model.extensionSidePanel
                )
                .animation(
                    .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                    value: showsBookmarksBar
                )

                if showsSiteToolbar {
                    BrowserSiteToolbar(
                        tab: sidebarSnapshot.selectedTab,
                        extensions: model.browserExtensions,
                        pinnedExtensionIDs: model.pinnedExtensionIDs,
                        canGoBack: sidebarSnapshot.canGoBack,
                        canGoForward: sidebarSnapshot.canGoForward,
                        canStopLoading: sidebarSnapshot.canStopLoading,
                        canReload: sidebarSnapshot.canReload,
                        goBackShortcut: shortcutStore.shortcut(for: .goBack),
                        goForwardShortcut: shortcutStore.shortcut(for: .goForward),
                        reloadShortcut: shortcutStore.shortcut(for: .reload),
                        copyLinkShortcut: shortcutStore.shortcut(for: .copyLink),
                        toggleBookmarksBarShortcut: shortcutStore.shortcut(for: .toggleBookmarksBar),
                        showsFullURL: preferences.siteToolbarShowsFullURL,
                        isBookmarksBarVisible: preferences.bookmarksBarVisible,
                        onURLButtonFrameChange: { currentURLRowWindowFrame = $0 },
                        onOpenSearch: model.presentCurrentPageCommandBar,
                        onGoBack: model.goBack,
                        onGoForward: model.goForward,
                        onStopLoading: model.stopLoadingCurrentTab,
                        onReload: model.reloadCurrentTab,
                        onCopyURL: model.copySelectedTabLink,
                        onCaptureFullPage: model.captureFullPageSelectedTabToPasteboard,
                        onToggleToolbar: {
                            preferences.siteURLToolbarEnabled.toggle()
                        },
                        onToggleShowsFullURL: {
                            preferences.siteToolbarShowsFullURL.toggle()
                        },
                        onToggleBookmarksBar: toggleBookmarksBarVisibility,
                        onRefreshExtensions: model.refreshBrowserExtensions,
                        onOpenExtensionsManager: model.openExtensionsManager,
                        onOpenExtensionStore: model.openExtensionStore,
                        onOpenExtensionStorePage: model.openExtensionStore,
                        onOpenExtensionDetails: model.openExtensionDetails,
                        onRemoveExtension: { extensionID in
                            model.removeExtension(id: extensionID)
                        },
                        onToggleExtensionPinned: { extensionID in
                            model.toggleExtensionPinned(id: extensionID)
                        },
                        onOpenExtension: model.openExtension
                    )
                    .frame(
                        width: bookmarksBarWidth(in: proxy.size),
                        height: BrowserChromeLayout.siteToolbarHeight,
                        alignment: .leading
                    )
                    .offset(x: browserContentMinX, y: siteToolbarMinY)
                    .zIndex(5)
                }

                if showsBookmarksBar {
                    BrowserBookmarksBar(
                        items: bookmarksModel.bookmarkBarItems,
                        selectedTab: sidebarSnapshot.selectedTab,
                        isSelectedTabBookmarked: isSelectedTabBookmarked,
                        toggleBookmarkShortcut: shortcutStore.shortcut(for: .toggleBookmark),
                        toggleBookmarksBarShortcut: shortcutStore.shortcut(for: .toggleBookmarksBar),
                        onOpenBookmark: model.openBookmark,
                        onOpenBookmarks: model.openBookmarks,
                        onToggleSelectedTabBookmark: {
                            _ = model.toggleSelectedTabBookmark()
                        },
                        onRenameBookmark: model.renameBookmark,
                        onEditBookmarkAddress: model.updateBookmarkAddress,
                        onMoveBookmark: model.moveBookmark,
                        onCreateFolder: model.createBookmarkFolder,
                        onCreateFolderAndMoveBookmark: model.createBookmarkFolderAndMoveBookmark,
                        onDeleteBookmark: model.deleteBookmark,
                        onManageBookmarks: model.openBookmarksManager,
                        onHideBookmarksBar: hideBookmarksBar
                    )
                    .frame(
                        width: bookmarksBarWidth(in: proxy.size),
                        height: BrowserChromeLayout.bookmarksBarHeight,
                        alignment: .leading
                    )
                    .offset(x: browserContentMinX, y: bookmarksBarMinY)
                    .zIndex(5)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: model.isSidebarVisible
                    )
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: model.extensionSidePanel
                    )
                }

                if let extensionSidePanel = model.extensionSidePanel,
                   let extensionSidePanelHostView = model.extensionSidePanelHostView
                {
                    BrowserExtensionSidePanelView(
                        sidePanel: extensionSidePanel,
                        hostView: extensionSidePanelHostView,
                        isContextReady: model.isContextReady,
                        usesWindowContentInsets: usesWindowContentInsets,
                        onClose: model.closeExtensionSidePanel
                    )
                    .frame(
                        width: model.extensionSidePanelWidth,
                        height: browserContentHeight(in: proxy.size),
                        alignment: .leading
                    )
                    .offset(x: extensionSidePanelMinX(in: proxy.size), y: browserContentMinY)
                    .zIndex(7)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: model.extensionSidePanel
                    )

                    BrowserExtensionSidePanelResizeHandle(model: model)
                        .frame(
                            width: extensionSidePanelResizeHandleWidth,
                            height: browserContentHeight(in: proxy.size)
                        )
                        .offset(
                            x: extensionSidePanelMinX(in: proxy.size) - extensionSidePanelResizeHandleWidth,
                            y: browserContentMinY
                        )
                        .zIndex(8)
                }

                if usesInlineSidebarChrome {
                    BrowserSidebarChromeView(
                        model: model,
                        updateController: updateController,
                        snapshot: sidebarSnapshot,
                        showsWindowControlsInSidebar: showsWindowControlsInSidebarChrome,
                        isCommandBarPresented: commandBarModel.isPresented,
                        isCurrentPageCommandBarPresented: currentPageCommandBarModel.isPresented,
                        showsCurrentURLRow: !preferences.siteURLToolbarEnabled,
                        sidebarWidth: model.sidebarWidth,
                        isOverlayPresentation: isSidebarOverlayPresentation,
                        showsOverlayBorder: isSidebarOverlayPresentation,
                        toggleSidebarTooltipTitle: toggleSidebarTooltipTitle,
                        ownedBackgroundMode: isSidebarOverlayPresentation ? chromeBackgroundMode : nil,
                        onToggleSidebar: toggleSidebarFromChrome,
                        onURLRowFrameChange: { currentURLRowWindowFrame = $0 }
                    )
                    .frame(
                        width: model.sidebarWidth,
                        height: sidebarHeight(in: proxy.size),
                        alignment: .leading
                    )
                    .clipped()
                    .animation(nil, value: model.sidebarWidth)
                    .offset(x: sidebarOffset, y: sidebarOffsetY)
                    .allowsHitTesting(isSidebarPresented)
                    .zIndex(6)
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: model.isSidebarVisible
                    )
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
                .animation(
                    .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                    value: model.isSidebarVisible
                )

                if !preferences.bookmarksBarVisible {
                    BrowserBookmarksBarChromeBackgroundContextMenuRegions(
                        windowSize: proxy.size,
                        blockedLeadingWidth: contentEdgeDragBlockedLeadingWidth,
                        leadingInset: browserContentLeadingInset,
                        topInset: browserContentTopInset,
                        trailingInset: browserContentTrailingInset,
                        bottomInset: browserContentBottomInset,
                        toggleBookmarksBarShortcut: shortcutStore.shortcut(for: .toggleBookmarksBar),
                        onToggleBookmarksBar: toggleBookmarksBarVisibility
                    )
                    .zIndex(4)
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: model.isSidebarVisible
                    )
                }

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
                            updateController: updateController,
                            snapshot: sidebarSnapshot,
                            showsWindowControlsInSidebar: showsWindowControlsInSidebarChrome,
                            isCommandBarPresented: commandBarModel.isPresented,
                            isCurrentPageCommandBarPresented: currentPageCommandBarModel.isPresented,
                            showsCurrentURLRow: !preferences.siteURLToolbarEnabled,
                            isOverlayPresentation: isSidebarOverlayPresentation,
                            showsOverlayBorder: isSidebarOverlayPresentation,
                            roundsWindowLeadingCorners: usesWindowContentInsets,
                            toggleSidebarTooltipTitle: toggleSidebarTooltipTitle,
                            chromeBackgroundMode: chromeBackgroundMode,
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
                    .animation(
                        .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                        value: model.isSidebarVisible
                    )
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
                            sidebarWidth: model.sidebarWidth,
                            matchesAnchorWidth: showsSiteToolbar
                        ),
                        faviconCandidate: currentPageCommandBarFaviconCandidate
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(10)
                }

                BrowserTabSwitcherEventObserver(
                    isEnabled: model.selectedTabID != nil,
                    onTab: { reverse in
                        model.advanceTabSwitcher(reverse: reverse)
                    },
                    onCommit: {
                        model.commitTabSwitcher()
                    },
                    onCancel: {
                        model.cancelTabSwitcher()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
                .zIndex(18)

                if let tabSwitcherState = model.tabSwitcherState, tabSwitcherState.isVisible {
                    BrowserTabSwitcherOverlay(state: tabSwitcherState)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .animation(.easeOut(duration: 0.12), value: tabSwitcherState.isVisible)
                        .zIndex(19)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(
                .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                value: showsBookmarksBar
            )
        }
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
                let tooltipViewport = tooltipOverlayViewport(in: proxy.size)
                let tooltipEntries = values.map { entry in
                    BrowserResolvedTooltipEntry(
                        id: entry.id,
                        sourceFrame: proxy[entry.bounds].offsetBy(
                            dx: tooltipViewport.sourceFrameOffset.x,
                            dy: tooltipViewport.sourceFrameOffset.y
                        ),
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
                            matchesAnchorWidth: showsSiteToolbar,
                            faviconCandidate: currentPageCommandBarFaviconCandidate
                        )
                        .environmentObject(tooltipCoordinator)
                        .environmentObject(faviconCache)
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                }

                BrowserDetachedOverlayWindowRepresentable(
                    isVisible: !tooltipEntries.isEmpty,
                    isInteractive: false,
                    contentFrameLeadingInset: 0,
                    framePolicy: tooltipOverlayFramePolicy,
                    content: BrowserTooltipOverlay(entries: tooltipEntries)
                        .frame(
                            width: tooltipViewport.size.width,
                            height: tooltipViewport.size.height,
                            alignment: .topLeading
                        )
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
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

    // MARK: Private

    @ObservedObject private var commandBarModel: BrowserCommandBarModel
    @ObservedObject private var currentPageCommandBarModel: BrowserCommandBarModel
    @ObservedObject private var shortcutStore: BrowserShortcutStore
    @ObservedObject private var preferences: BrowserUserPreferencesStore
    @ObservedObject private var bookmarksModel: BrowserBookmarksModel
    @ObservedObject private var updateController: BrowserUpdateController
    @ObservedObject private var faviconCache = BrowserFaviconCache.shared
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
    @State private var rootViewScreenFrame: CGRect?
    @StateObject private var tooltipCoordinator = BrowserTooltipCoordinator()

    private var sidebarLayoutWidth: CGFloat {
        model.isSidebarVisible ? model.sidebarWidth : 0
    }

    private var extensionSidePanelLayoutWidth: CGFloat {
        isExtensionSidePanelPresented ? model.extensionSidePanelWidth + extensionSidePanelContentGap : 0
    }

    private var extensionSidePanelResizeHandleWidth: CGFloat {
        BrowserChromeLayout.sidebarResizeHitWidth
    }

    private var extensionSidePanelContentGap: CGFloat {
        isExtensionSidePanelPresented ? BrowserChromeLayout.sidebarOuterPadding : 0
    }

    private var showsBookmarksBar: Bool {
        model.isContextReady && preferences.bookmarksBarVisible
    }

    private var showsSiteToolbar: Bool {
        model.isContextReady && preferences.siteURLToolbarEnabled
    }

    private var siteToolbarReservedHeight: CGFloat {
        showsSiteToolbar
            ? BrowserChromeLayout.siteToolbarHeight + BrowserChromeLayout.bookmarksBarContentGap
            : 0
    }

    private var bookmarksBarReservedHeight: CGFloat {
        showsBookmarksBar
            ? BrowserChromeLayout.bookmarksBarHeight + BrowserChromeLayout.bookmarksBarContentGap
            : 0
    }

    private var siteToolbarMinY: CGFloat {
        browserChromeTopInset
    }

    private var bookmarksBarMinY: CGFloat {
        browserChromeTopInset + siteToolbarReservedHeight
    }

    private var isSelectedTabBookmarked: Bool {
        guard let selectedTab = sidebarSnapshot.selectedTab else {
            return false
        }

        return model.isBookmarked(urlString: selectedTab.urlString)
    }

    private var isExtensionSidePanelPresented: Bool {
        model.extensionSidePanel != nil && model.extensionSidePanelHostView != nil
    }

    private var chromeBackgroundMode: BrowserChromeBackgroundMode {
        preferences.blurredChromeBackgroundEnabled ? .blurred : .black
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

    private var tooltipOverlayFramePolicy: BrowserDetachedOverlayFramePolicy {
        guard rootViewScreenFrame != nil else {
            return .windowBounds
        }

        return isWindowFullscreen ? .windowBounds : .screenVisibleBounds
    }

    private var toggleSidebarTooltipTitle: String {
        model.isSidebarVisible ? BrowserStrings.sidebarHide : BrowserStrings.sidebarShow
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

    private var browserChromeTopInset: CGFloat {
        showsSiteToolbar || showsBookmarksBar
            ? max(browserContentTopInset, BrowserChromeLayout.sidebarOuterPadding)
            : browserContentTopInset
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
        browserChromeTopInset
            + siteToolbarReservedHeight
            + bookmarksBarReservedHeight
    }

    private var usesDetachedBrowserOverlays: Bool {
        false
    }

    private var sidebarSnapshot: BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            spaces: model.spaces,
            selectedSpaceID: model.selectedSpaceID,
            activeSpace: model.activeSpace,
            isActiveSpacePinnedSectionCollapsed: model.isActiveSpacePinnedSectionCollapsed,
            allTabs: model.tabs,
            pinnedTabFolders: model.pinnedTabFolders,
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

    private func browserContentWidth(in windowSize: CGSize) -> CGFloat {
        max(windowSize.width - browserContentMinX - browserContentTrailingInset - extensionSidePanelLayoutWidth, 0)
    }

    private func bookmarksBarWidth(in windowSize: CGSize) -> CGFloat {
        max(windowSize.width - browserContentMinX - browserContentTrailingInset, 0)
    }

    private func browserContentHeight(in windowSize: CGSize) -> CGFloat {
        max(windowSize.height - browserContentMinY - browserContentBottomInset, 0)
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

    private func extensionSidePanelMinX(in windowSize: CGSize) -> CGFloat {
        max(windowSize.width - browserContentTrailingInset - model.extensionSidePanelWidth, 0)
    }

    private func tooltipOverlayViewport(in windowSize: CGSize) -> BrowserTooltipOverlayViewport {
        BrowserTooltipOverlayViewportResolver.viewport(
            windowSize: windowSize,
            windowScreenFrame: rootViewScreenFrame,
            screenVisibleFrame: tooltipScreenVisibleFrame(),
            isWindowFullscreen: isWindowFullscreen
        )
    }

    private func tooltipScreenVisibleFrame() -> CGRect? {
        guard let rootViewScreenFrame else {
            return nil
        }

        return NSScreen.browserBestMatchingScreen(for: rootViewScreenFrame)?.visibleFrame
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

    private func toggleBookmarksBarVisibility() {
        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            preferences.bookmarksBarVisible.toggle()
        }
    }

    private func hideBookmarksBar() {
        guard preferences.bookmarksBarVisible else {
            return
        }

        toggleBookmarksBarVisibility()
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
}

// MARK: - BrowserBookmarksBarVisibilityMenuContent

struct BrowserBookmarksBarVisibilityMenuContent: View {
    let isBookmarksBarVisible: Bool
    let toggleBookmarksBarShortcut: BrowserKeyboardShortcut
    let onToggleBookmarksBar: () -> Void

    var body: some View {
        Button(
            isBookmarksBarVisible ? BrowserStrings.bookmarksHideBarAction : BrowserStrings.settingsShowBookmarksBar,
            action: onToggleBookmarksBar
        )
        .browserKeyboardShortcut(toggleBookmarksBarShortcut)
    }
}

// MARK: - BrowserBookmarksBarChromeBackgroundContextMenuRegions

private struct BrowserBookmarksBarChromeBackgroundContextMenuRegions: View {
    // MARK: Internal

    let windowSize: CGSize
    let blockedLeadingWidth: CGFloat
    let leadingInset: CGFloat
    let topInset: CGFloat
    let trailingInset: CGFloat
    let bottomInset: CGFloat
    let toggleBookmarksBarShortcut: BrowserKeyboardShortcut
    let onToggleBookmarksBar: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if topInset > 0 {
                dragRegion(
                    width: max(windowSize.width - blockedLeadingWidth, 0),
                    height: topInset
                )
                .offset(x: blockedLeadingWidth)
            }

            if bottomInset > 0 {
                dragRegion(
                    width: max(windowSize.width - blockedLeadingWidth, 0),
                    height: bottomInset
                )
                .offset(x: blockedLeadingWidth, y: max(windowSize.height - bottomInset, 0))
            }

            if trailingInset > 0 {
                dragRegion(width: trailingInset, height: windowSize.height)
                    .offset(x: max(windowSize.width - trailingInset, 0))
            }

            if leadingInset > 0 {
                dragRegion(width: leadingInset, height: windowSize.height)
                    .offset(x: blockedLeadingWidth)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }

    // MARK: Private

    private func dragRegion(width: CGFloat, height: CGFloat) -> some View {
        BrowserWindowDragRegion()
            .frame(width: width, height: height)
            .contextMenu {
                BrowserBookmarksBarVisibilityMenuContent(
                    isBookmarksBarVisible: false,
                    toggleBookmarksBarShortcut: toggleBookmarksBarShortcut,
                    onToggleBookmarksBar: onToggleBookmarksBar
                )
            }
    }
}

private extension NSScreen {
    static func browserBestMatchingScreen(for frame: CGRect) -> NSScreen? {
        screens.max { lhs, rhs in
            lhs.frame.intersectionArea(with: frame) < rhs.frame.intersectionArea(with: frame)
        } ?? main
    }
}

private extension CGRect {
    func intersectionArea(with frame: CGRect) -> CGFloat {
        let intersection = intersection(frame)
        guard !intersection.isNull else {
            return 0
        }

        return max(intersection.width, 0) * max(intersection.height, 0)
    }
}
