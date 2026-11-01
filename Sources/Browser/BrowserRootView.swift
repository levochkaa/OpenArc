// BrowserRootView.swift

import AppKit
import Combine
import QuartzCore

final class BrowserRootView: NSView {
    private static let captureHintSeenKey = "browser.capture.hintSeen"

    // MARK: Internal

    override var isFlipped: Bool { true }

    // MARK: Private

    private let model: BrowserChromeModel
    private let updateController: BrowserUpdateController
    private let background = BrowserChromeBackgroundNSView()
    private let content: BrowserContentNSView
    private let sidebar: BrowserSidebarChromeView
    private var sidebarLibraryEnd = 0
    private let libraryScrollObserver = BrowserSpacePagerScrollNSView()
    /// While a swipe pulls the Library: 0 is the sidebar in place, 1 the Library.
    private var librarySwipeProgress: CGFloat?
    private var librarySwipeTranslation: CGFloat = 0
    private var librarySwipeStart: CFTimeInterval = 0
    private let toolbar: BrowserSiteControlsNSView
    private lazy var developerToolbar = BrowserDeveloperToolbarView(model: model)
    private let captureToast = BrowserCaptureToastView()
    private let passwordPrompt = BrowserPasswordPromptView()
    private var portraitCapture: BrowserPortraitCaptureView?
    private var portraitCaptureMonitor: Any?
    private var captureDragMonitor: Any?
    private var captureDragStart: NSEvent?
    private var isCaptureDragging = false
    private let bookmarks: BrowserBookmarksBarNSView
    private let margins = BrowserNativeWindowMargins()
    private let revealEdge = BrowserNativeSidebarRevealEdge()
    private let find = BrowserFindBarNSView()
    private let pageLoadingIndicator = BrowserPageLoadingIndicatorView()
    private let linkStatus = BrowserLinkStatusView()
    private let command: BrowserCommandBarNSView
    private let currentPageCommand: BrowserCommandBarNSView
    private let sidebarDismiss = BrowserSidebarHoverOverlayDismissNSView()
    private let sidebarInteraction = BrowserPassthroughInteractionNSView()
    private let tabEvents = BrowserTabSwitcherEventNSView()
    private let tabSwitcher = BrowserTabSwitcherNSView()
    private let fullscreenReader = BrowserWindowFullscreenReaderNSView()
    private let pageTopDrag = BrowserPageTopWindowDrag()
    private let sessionRecovery = BrowserSessionPersistenceStatusView()
    /// Positions popovers whose own button is off screen.
    private let popoverAnchor = NSView()
    private lazy var library = BrowserLibraryNSView(model: model)
    private var wasLibraryPresented = false
    private var spaceThemePopover: BrowserNativePopover?
    private let extensionResize = BrowserNativeResizeHandle()
    private var extensionPanel: BrowserExtensionSidePanelNSView?
    private let toolbarVisibility = BrowserNativeVisibilityAnimation()
    private let bookmarksVisibility = BrowserNativeVisibilityAnimation()
    private let extensionVisibility = BrowserNativeVisibilityAnimation()
    private var observations = Set<AnyCancellable>()
    private var revealTask: Task<Void, Never>?
    private var previousLayoutState: [Bool]?
    private let presentationMotion = BrowserNativeFrameTransitions()
    private var animateNextLayout = false
    private var nextLayoutCurve = BrowserNativeAnimation.Curve.sidebar
    private var nextLayoutDelay: CFTimeInterval = 0
    private let frameAnimation = BrowserNativeAnimation()
    private var isAnimatingFrames = false
    private var lastFrameTargets = [ObjectIdentifier: CGRect]()
    private var showsSidebarWindowControls: Bool
    private var isWindowFullscreen = false
    private var isWindowFullscreenTransitioning = false
    private var isSidebarHoverOverlayPresented = false
    private var isSidebarHoverOverlayChromeVisible = false
    /// A floating sidebar being pinned keeps its background until the page has made room.
    private var isSidebarOverlayPinning = false
    private var preservesSidebarHoverOverlayDuringFullscreenTransition = false
    private var isSidebarHoverOverlayPointerSyncSuspended = false
    private var isSidebarRevealEdgeHovered = false
    private var currentURLRowWindowFrame: CGRect?

    private var libraryFollowsSwipe: Bool { librarySwipeProgress != nil }

    private var preferences: BrowserUserPreferencesStore { model.userPreferencesStore }
    private var shortcutStore: BrowserShortcutStore { model.shortcutStore }
    private var commandBarModel: BrowserCommandBarModel { model.commandBarModel }
    private var currentPageCommandBarModel: BrowserCommandBarModel { model.currentPageCommandBarModel }
    private var windowGeometry: BrowserWindowChromeLayout {
        .init(
            windowSize: bounds.size,
            sidebarWidth: reservedSidebarWidth(swipeProgress: librarySwipeProgress),
            isSidebarVisible: model.isSidebarVisible || model.librarySection != nil || libraryFollowsSwipe,
            isHoverSidebarPresented: isSidebarHoverOverlayPresented,
            isOverlayChromeVisible: isSidebarHoverOverlayChromeVisible,
            isFullscreen: isWindowFullscreen,
            showsSiteToolbar: showsSiteToolbar,
            showsBookmarksBar: showsBookmarksBar,
            extensionSidePanelWidth: isExtensionSidePanelPresented ? model.extensionSidePanelWidth : nil,
            sidebarPosition: preferences.sidebarPosition,
            developerToolbarHeight: showsDeveloperToolbar ? BrowserDeveloperToolbarView.height : 0,
        )
    }

    private var sidebarLayoutWidth: CGFloat { windowGeometry.sidebarReservedWidth }

    /// Drag strip at the top of the page, while nothing sits above it:
    /// no toolbar, bookmarks bar or split pane bars, and not in full screen.
    private var pageTopDragRegion: NSRect? {
        guard preferences.windowDraggingFromPageTopEnabled, !isWindowFullscreen, !showsSiteToolbar,
              !showsBookmarksBar, let selected = model.selectedTabID,
              model.splitPaneTabIDs(forTabID: selected).count <= 1
        else { return nil }
        let strip = NSRect(x: 0, y: 0, width: content.bounds.width, height: BrowserPageTopWindowDrag.regionHeight)
        return content.convert(strip, to: nil)
    }

    private var showsBookmarksBar: Bool { model.isContextReady && preferences.bookmarksBarVisible }
    private var showsSiteToolbar: Bool { model.isContextReady && preferences.siteURLToolbarEnabled }
    private var showsDeveloperToolbar: Bool { model.isContextReady && model.isDeveloperModeOn }
    private var isExtensionSidePanelPresented: Bool {
        model.extensionSidePanel != nil && model.extensionSidePanelHostView != nil
    }

    private var chromeBackgroundMode: BrowserChromeBackgroundMode {
        if preferences.blurredChromeBackgroundEnabled {
            .blurred
        } else {
            .black
        }
    }

    private var isEditingSpaceTheme: Bool { spaceThemePopover?.isShown == true }
    private var isSidebarPresented: Bool { model.isSidebarVisible || isSidebarHoverOverlayPresented }
    private var isSidebarHoverOverlayActive: Bool { !model.isSidebarVisible && isSidebarHoverOverlayPresented }
    private var isSidebarOverlayPresentation: Bool {
        isSidebarOverlayPinning || !model.isSidebarVisible && isSidebarHoverOverlayChromeVisible
    }

    private var showsWindowControlsInSidebarChrome: Bool {
        showsSidebarWindowControls || isSidebarHoverOverlayChromeVisible
    }

    private var allowsSidebarHoverOverlayPointerSyncDismissal: Bool {
        !isWindowFullscreenTransitioning && !isSidebarHoverOverlayPointerSyncSuspended
    }

    private var contentEdgeDragBlockedLeadingWidth: CGFloat { windowGeometry.leadingReservedWidth }
    private var currentPageCommandBarFaviconCandidate: BrowserCommandBarFaviconCandidate? {
        model.currentTab.map(BrowserCommandBarFaviconCandidate.init(tab:))
    }

    private var usesWindowContentInsets: Bool { !isWindowFullscreen }
    private var browserContentLeadingInset: CGFloat { windowGeometry.leadingInset }
    private var browserContentTopInset: CGFloat { windowGeometry.edgeInset }
    private var browserContentTrailingInset: CGFloat { windowGeometry.trailingInset }
    private var browserContentBottomInset: CGFloat { windowGeometry.edgeInset }
    private var browserContentMinX: CGFloat { windowGeometry.contentMinX }

    init(model: BrowserChromeModel, updateController: BrowserUpdateController) {
        self.model = model
        self.updateController = updateController
        self.showsSidebarWindowControls = model.isSidebarVisible
        self.content = BrowserContentNSView(hostView: model.hostView)
        self.sidebar = BrowserSidebarChromeView(model: model, updateController: updateController)
        self.toolbar = BrowserSiteControlsNSView(model: model, mode: .toolbar)
        self.bookmarks = BrowserBookmarksBarNSView(model: model)
        self.command = BrowserCommandBarNSView(model: model.commandBarModel)
        self.currentPageCommand = BrowserCommandBarNSView(model: model.currentPageCommandBarModel)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.window.chrome")
        for view in [
            background,
            content,
            margins,
            toolbar,
            bookmarks,
            library,
            sidebar,
            extensionResize,
            revealEdge,
            find,
            pageLoadingIndicator,
            sidebarDismiss,
            sidebarInteraction,
            command,
            currentPageCommand,
            tabEvents,
            tabSwitcher,
            fullscreenReader,
            sessionRecovery,
            popoverAnchor,
        ] {
            addSubview(view)
        }
        library.isHidden = true
        addSubview(linkStatus)
        addSubview(developerToolbar, positioned: .below, relativeTo: content)
        addSubview(captureToast)
        addSubview(passwordPrompt)
        passwordPrompt.isHidden = true
        passwordPrompt.onSave = { [weak self] in self?.model.answerPasswordPrompt(save: true) }
        passwordPrompt.onNotNow = { [weak self] in self?.model.answerPasswordPrompt(save: false) }
        passwordPrompt.onNever = { [weak self] in self?.model.neverSavePasswordsFromPromptSite() }
        passwordPrompt.onFill = { [weak self] in self?.model.fillPassword($0) }
        NotificationCenter.default.addObserver(
            forName: BrowserCaptureToastView.didCopyNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let png = notification.object as? Data else { return }
            MainActor.assumeIsolated {
                guard let self, self.window?.isMainWindow == true else { return }
                self.playCaptureSound()
                self.showCaptureToast { $0.showCopied(png: png) }
            }
        }
        installCaptureDragMonitor()
        addSubview(libraryScrollObserver)
        bindLibrarySwipes()
        find.bind(to: model)
        content.bindTabCreation(to: model)
        let beginCapture = model.onBeginAreaCapture
        model.onBeginAreaCapture = { [weak self] in
            let began = beginCapture?() ?? false
            if began, let self, !isCaptureDragging, !UserDefaults.standard.bool(forKey: Self.captureHintSeenKey) {
                UserDefaults.standard.set(true, forKey: Self.captureHintSeenKey)
                showCaptureToast { $0.showHint(keysText: "⇧⌘") }
            }
            return began
        }
        pageTopDrag.pageView = { [weak content] in content?.viewport }
        pageTopDrag.region = { [weak self] in self?.pageTopDragRegion }
        sessionRecovery.onRetry = { [weak model] in model?.retrySessionPersistence() }
        sessionRecovery.onSaveCopy = { [weak self] in
            guard let self, let window else { return }
            BrowserSessionRecoveryExporter.present(model: model, window: window)
        }
        sidebar.onToggleSidebar = { [weak model] in model?.toggleSidebar() }
        model.onToggleDownloads = { [weak self] in self?.toggleDownloads() }
        model.onRevealSidebar = { [weak self] in self?.revealSidebarFromKeyboard() }
        model.onSpaceWillSelect = { [weak self] in self?.beginSpaceTransition(to: $0) }
        model.onTabRowsChanged = { [weak self] in
            self?.refresh()
            self?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        model.onOpenExtensions = { [weak self] in self?.openExtensions() }
        model.onOpenExtensionRequest = { [weak self] id in
            guard let self else { return }
            (showsSiteToolbar ? toolbar : sidebar.header.urlControls).openExtensionFromMenu(id: id)
        }
        model.onPortraitCapture = { [weak self] in self?.presentPortraitCapture(png: $0) }
        model.onEditSpaceTheme = { [weak self] in self?.presentSpaceThemeEditor(spaceID: $0) }
        model.onShareURL = { [weak self] url in
            guard let self else { return }
            popoverAnchor.frame = CGRect(x: bounds.midX, y: 40, width: 1, height: 1)
            NSSharingServicePicker(items: [url]).show(
                relativeTo: popoverAnchor.bounds,
                of: popoverAnchor,
                preferredEdge: .minY,
            )
        }
        model.onEditSpaceCreationTheme = { [weak self] _ in self?.presentSpaceCreationThemeEditor() }
        sidebar.sidebar.state.drag.pageSplitDropResolver = { [weak content] point, tabID in
            content?.splitPaneBars.pageSplitDrop(atWindowPoint: point, draggedTabID: tabID)
        }
        sidebar.sidebar.onSpacePagerProgress = { [weak self] spaceID, progress in
            guard let self else { return }
            background.setSwipeTransition(
                toward: spaceID.flatMap { self.model.spaceThemesByID[$0] },
                progress: progress,
            )
        }
        sidebar.onDragInteractionChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        sidebar.onURLFrameChange = { [weak self] frame in self?.updateURLFrame(frame) }
        toolbar.onURLFrameChange = { [weak self] frame in self?.updateURLFrame(frame) }
        revealEdge.onHoverChange = { [weak self] in self?.handleSidebarRevealEdgeHoverChange($0) }
        fullscreenReader.onFullscreenStateChange = { [weak self] in self?.handleWindowFullscreenStateChange($0) }
        margins.menuProvider = { [weak self, weak model] in
            guard let self,!preferences.bookmarksBarVisible else { return nil }
            let menu = BrowserNativeMenus.menu()
            BrowserNativeMenus.add(
                BrowserStrings.settingsShowBookmarksBar,
                to: menu,
                shortcut: shortcutStore.shortcut(for: .toggleBookmarksBar),
            ) { [weak model] in model?
                .userPreferencesStore
                .bookmarksBarVisible
                .toggle()
            }
            return menu
        }
        sidebarInteraction.eventMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        sidebarInteraction.onInteraction = { [weak self] _, _ in
            guard let self, commandBarModel.isPresented else { return }
            let requestID = commandBarModel.focusRequestID
            DispatchQueue.main.async { [weak self] in
                guard let self, commandBarModel.focusRequestID == requestID,
                      sidebarLayoutWidth > 0, commandBarModel.isPresented,
                      !currentPageCommandBarModel.isPresented else { return }
                commandBarModel.dismiss()
            }
        }
        tabEvents.onTab = { [weak model] reverse in model?.advanceTabSwitcher(reverse: reverse) ?? false }
        tabEvents.onCommit = { [weak model] in model?.commitTabSwitcher() ?? false }
        tabEvents.onCancel = { [weak model] in model?.cancelTabSwitcher() ?? false }
        extensionResize
            .getWidth = { [weak model] in
                model?.extensionSidePanelWidth ?? BrowserChromeModel.defaultExtensionSidePanelWidth
            }
        extensionResize.setWidth = { [weak model] in model?.setExtensionSidePanelWidth($0) }
        extensionResize.defaultWidth = BrowserChromeModel.defaultExtensionSidePanelWidth
        extensionResize.direction = -1
        extensionResize.setAccessibilityIdentifier("browser.extensions.resize")
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            commandBarModel.objectWillChange.eraseToAnyPublisher(),
            currentPageCommandBarModel.objectWillChange.eraseToAnyPublisher(),
            preferences.objectWillChange.eraseToAnyPublisher(),
            shortcutStore.objectWillChange.eraseToAnyPublisher(),
            model.bookmarksModel.objectWillChange.eraseToAnyPublisher(),
            updateController.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }
    isolated deinit { revealTask?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pageTopDrag.stop()
        } else {
            pageTopDrag.start(in: window)
        }
    }

    override func layout() {
        super.layout()
        let animate = animateNextLayout && window != nil && !isWindowFullscreenTransitioning
        let curve = nextLayoutCurve
        let delay = nextLayoutDelay
        nextLayoutDelay = 0
        animateNextLayout = false
        nextLayoutCurve = .sidebar
        background.frame = bounds
        margins.frame = bounds
        margins.configure(
            blockedLeadingWidth: contentEdgeDragBlockedLeadingWidth,
            blockedTrailingWidth: windowGeometry.trailingReservedWidth,
            leading: browserContentLeadingInset,
            top: browserContentTopInset,
            trailing: browserContentTrailingInset,
            bottom: browserContentBottomInset,
        )
        for overlay in [command, currentPageCommand, tabEvents, tabSwitcher, sidebarDismiss] {
            overlay.frame = bounds
        }
        layoutCaptureToast()
        layoutPasswordPrompt()
        let onRight = preferences.sidebarPosition == .right
        libraryScrollObserver.frame = CGRect(
            x: onRight ? bounds.width - BrowserLibraryLayout.width : 0,
            y: 0,
            width: BrowserLibraryLayout.width,
            height: bounds.height,
        )
        sidebarInteraction.frame = NSRect(
            x: onRight ? bounds.width - sidebarLayoutWidth : 0,
            y: 0,
            width: sidebarLayoutWidth,
            height: bounds.height,
        )
        let revealWidth = BrowserChromeLayout.sidebarHoverRevealWidth
        revealEdge.frame = NSRect(
            x: onRight ? bounds.width - revealWidth : 0,
            y: 0,
            width: revealWidth,
            height: bounds.height,
        )
        sidebarDismiss.update(
            isPresented: isSidebarHoverOverlayActive,
            sidebarFrame: sidebarFrame(in: bounds.size),
            allowsPointerSyncDismissal: allowsSidebarHoverOverlayPointerSyncDismissal,
            onPointerMovement: { [weak self] in self?.handleSidebarHoverOverlayPointerMovement() },
            onDismiss: { [weak self] in self?.dismissSidebarHoverOverlay() },
        )
        let geometry = windowGeometry
        let recoveryWidth = min(max(bounds.width - 32, 0), 640)
        let recoveryHeight = sessionRecovery.height(for: recoveryWidth)
        sessionRecovery.frame = NSRect(
            x: (bounds.width - recoveryWidth) / 2,
            y: max(bounds.height - recoveryHeight - 16, 0),
            width: recoveryWidth,
            height: recoveryHeight,
        )
        let libraryWidth = model.librarySection == .spaces ? bounds.width : BrowserLibraryLayout.width
        let libraryShown = model.librarySection != nil
        developerToolbar.isHidden = !showsDeveloperToolbar
        var targets: [(NSView, CGRect)] = [
            (content, pageFrameDuringLibrarySwipe(geometry.contentFrame)), (find, geometry.contentFrame),
            // It reaches behind the page so the page's rounded corners show the bar.
            (
                developerToolbar,
                geometry.developerToolbarFrame.union(
                    geometry.developerToolbarFrame.offsetBy(dx: 0, dy: BrowserChromeLayout.leadingContentCornerRadius),
                ),
            ),
            // The Library takes the sidebar's place: the sidebar keeps its size while it fades.
            (sidebar, libraryShown || libraryFollowsSwipe ? sidebar.frame : geometry.sidebarFrame),
            (
                pageLoadingIndicator,
                CGRect(
                    x: geometry.contentFrame.midX - BrowserPageLoadingIndicatorView.size.width / 2,
                    y: 3,
                    width: BrowserPageLoadingIndicatorView.size.width,
                    height: BrowserPageLoadingIndicatorView.size.height,
                ),
            ),
            (
                library,
                libraryFrame(width: libraryWidth, progress: librarySwipeProgress ?? (libraryShown ? 1 : 0)),
            ),
            (
                toolbar,
                showsSiteToolbar
                    ? geometry.toolbarFrame
                    : geometry.toolbarFrame.offsetBy(dx: 0, dy: -geometry.toolbarFrame.height),
            ),
            (
                bookmarks,
                showsBookmarksBar
                    ? geometry.bookmarksFrame
                    : geometry.bookmarksFrame.offsetBy(dx: 0, dy: -geometry.bookmarksFrame.height),
            ),
            (extensionResize, geometry.extensionResizeFrame),
        ]
        if let extensionPanel {
            let frame = isExtensionSidePanelPresented
                ? geometry.extensionFrame
                : CGRect(
                    x: bounds.width,
                    y: extensionPanel.frame.minY,
                    width: extensionPanel.frame.width,
                    height: extensionPanel.frame.height,
                )
            targets.append((extensionPanel, frame))
        }
        let targetFrames = Dictionary(uniqueKeysWithValues: targets.map { (ObjectIdentifier($0.0), $0.1) })
        // Model notifications unrelated to geometry must not interrupt an in-flight transition.
        if isAnimatingFrames, targetFrames == lastFrameTargets {
            return
        }
        lastFrameTargets = targetFrames
        frameAnimation.cancel()
        presentationMotion.endSlideOuts(atTarget: !animate)
        isAnimatingFrames = animate
        // Keep hit regions and anchored panels on the same geometry as the page.
        let updateHitRegions = { [weak self] (page: CGRect) in
            guard let self else { return }
            if preferences.sidebarPosition == .right {
                let minX = min(max(page.maxX, extensionPanel?.frame.maxX ?? 0), bounds.width)
                sidebarInteraction.frame = NSRect(x: minX, y: 0, width: bounds.width - minX, height: bounds.height)
            } else {
                sidebarInteraction.frame.size.width = max(page.minX, 0)
            }
        }
        guard animate else {
            for (view, frame) in targets {
                view.frame = frame
            }
            for (view, _) in targets {
                view.layoutSubtreeIfNeeded()
            }
            updateHitRegions(geometry.contentFrame)
            finishPresentationAnimation()
            return
        }
        // Everything moves on the render server: resizing the page takes longer than a
        // frame, so stepping frames on the main thread would stutter. The page resizes
        // once, and until then stays large enough to leave no gap while it moves.
        let page = geometry.contentFrame
        let pageWhileMoving = CGRect(
            origin: page.origin,
            size: CGSize(width: max(content.frame.width, page.width), height: max(content.frame.height, page.height)),
        )
        for (view, frame) in targets {
            if !frame.intersects(bounds), view.frame.intersects(bounds) {
                presentationMotion.slideOut(view, to: frame, curve: curve, delay: delay)
            } else {
                presentationMotion.slide(
                    view,
                    to: view === content ? pageWhileMoving : frame,
                    animated: true,
                    curve: curve,
                    delay: delay,
                )
            }
        }
        for (view, _) in targets {
            view.layoutSubtreeIfNeeded()
        }
        updateHitRegions(page)
        frameAnimation.start(.easeOut(curve.duration + delay), updates: { _ in }) { [weak self] in
            guard let self else { return }
            presentationMotion.endSlideOuts(atTarget: true)
            content.frame = page
            content.layoutSubtreeIfNeeded()
            finishPresentationAnimation()
        }
    }

    private func sidebarFrame(in _: CGSize) -> CGRect { windowGeometry.sidebarFrame }

    private func reservedSidebarWidth(swipeProgress: CGFloat?) -> CGFloat {
        guard let swipeProgress else {
            return model.librarySection == nil ? model.sidebarWidth : BrowserLibraryLayout.width
        }
        let start = model.isSidebarVisible ? model.sidebarWidth : 0
        return start + (BrowserLibraryLayout.width - start) * swipeProgress
    }

    private func libraryFrame(width: CGFloat, progress: CGFloat) -> CGRect {
        let away = width * (1 - progress)
        return CGRect(
            x: preferences.sidebarPosition == .right ? bounds.width - width + away : -away,
            y: 0,
            width: width,
            height: bounds.height,
        )
    }

    /// Resizing the page takes longer than a frame, so during a swipe it only moves.
    /// It keeps the size it has with the sidebar, and the layout resizes it at the end.
    private func pageFrameDuringLibrarySwipe(_ page: CGRect) -> CGRect {
        guard let librarySwipeProgress else { return page }
        let moved = reservedSidebarWidth(swipeProgress: librarySwipeProgress) - reservedSidebarWidth(swipeProgress: 0)
        return CGRect(origin: page.origin, size: CGSize(width: page.width + moved, height: page.height))
    }

    /// Off screen after its slide, and out of reach of the keyboard and accessibility.
    private func hideLibraryAfterSlide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + BrowserNativeAnimation.Curve.library.duration) { [weak self] in
            guard let self, model.librarySection == nil, !libraryFollowsSwipe else { return }
            library.isHidden = true
        }
    }

    private func bindLibrarySwipes() {
        let state = sidebar.sidebar.state
        state.onLibrarySwipe = { [weak self] progress in self?.followLibrarySwipe(progress: progress) }
        state.onLibrarySwipeEnded = { [weak self] opens in self?.finishLibrarySwipe(opens: opens) }
        libraryScrollObserver.onScrollDelta = { [weak self] delta in
            guard let self else { return }
            if !libraryFollowsSwipe {
                librarySwipeStart = CACurrentMediaTime()
                librarySwipeTranslation = 0
            }
            librarySwipeTranslation = min(librarySwipeTranslation + delta * 0.5, 0)
            followLibrarySwipe(progress: 1 - min(-librarySwipeTranslation / BrowserLibraryLayout.width, 1))
        }
        libraryScrollObserver.onScrollReleased = { [weak self] in
            guard let self, libraryFollowsSwipe else { return }
            let isQuick = CACurrentMediaTime() - librarySwipeStart < 0.5
            let closes = librarySwipeTranslation < 0
                && (isQuick || -librarySwipeTranslation >= BrowserLibraryLayout.width / 2)
            finishLibrarySwipe(opens: !closes)
        }
        libraryScrollObserver.onScrollEnded = { [weak self] in
            guard let self, libraryFollowsSwipe else { return }
            finishLibrarySwipe(opens: model.librarySection != nil)
        }
    }

    /// `progress` 1 is the Library in place. The page's edge follows the swipe from the
    /// start, and the sidebar fades and shrinks away over the first half.
    private func followLibrarySwipe(progress: CGFloat) {
        librarySwipeProgress = progress
        library.isHidden = false
        sidebar.isHidden = false
        sidebar.alphaValue = max(1 - progress * 2, 0)
        setSidebarLayerTransform(sidebarSwipeTransform(progress: progress))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func sidebarSwipeTransform(progress: CGFloat) -> CATransform3D {
        let anchor = CGPoint(
            x: preferences.sidebarPosition == .right ? sidebar.bounds.width - 354 : 354,
            y: sidebar.bounds.height / 2,
        )
        let scale = 1 - 0.1 * min(progress, 0.5)
        var transform = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -anchor.x, -anchor.y, 0)
    }

    private func setSidebarLayerTransform(_ transform: CATransform3D) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sidebar.layer?.transform = transform
        CATransaction.commit()
    }

    private func finishLibrarySwipe(opens: Bool) {
        librarySwipeProgress = nil
        if opens != (model.librarySection != nil) {
            model.toggleLibrary()
            return
        }
        // The swipe changed nothing: everything goes back where it was.
        let opacity = sidebar.alphaValue
        let transform = sidebar.layer?.transform ?? CATransform3DIdentity
        sidebar.alphaValue = 1
        setSidebarLayerTransform(CATransform3DIdentity)
        sidebar.isHidden = opens
        if !opens {
            let fade = BrowserNativeAnimation.Curve.library.layerAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 1
            sidebar.layer?.add(fade, forKey: "browser.sidebar.library.fade")
            let scale = BrowserNativeAnimation.Curve.library.layerAnimation(keyPath: "transform")
            scale.fromValue = transform
            scale.toValue = CATransform3DIdentity
            sidebar.layer?.add(scale, forKey: "browser.sidebar.library.scale")
        }
        animateNextLayout = true
        nextLayoutCurve = opens ? .libraryOpen : .library
        needsLayout = true
        if !opens {
            hideLibraryAfterSlide()
        }
    }

    /// Uses the sound macOS plays for its own screenshots.
    private func playCaptureSound() {
        guard preferences.soundEffectsEnabled else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    /// Only over the tab that asked; the question waits while another one shows.
    private func refreshPasswordPrompt() {
        model.dropStalePasswordPrompt()
        guard let prompt = model.passwordPrompt, model.isTabVisibleForPasswordPrompt(prompt.tabID) else {
            passwordPrompt.isHidden = true
            return
        }
        passwordPrompt.update(prompt)
        passwordPrompt.isHidden = false
        addSubview(passwordPrompt, positioned: .above, relativeTo: nil)
        layoutPasswordPrompt()
    }

    private func layoutPasswordPrompt() {
        let page = windowGeometry.contentFrame
        passwordPrompt.frame = CGRect(
            x: page.maxX - BrowserPasswordPromptView.width - 12,
            y: page.minY + 12,
            width: BrowserPasswordPromptView.width,
            height: passwordPrompt.preferredHeight,
        )
    }

    private func presentPortraitCapture(png: Data) {
        portraitCapture?.removeFromSuperview()
        let card = BrowserPortraitCaptureView(pagePNG: png)
        card.onFinish = { [weak self] in self?.dismissPortraitCapture() }
        let page = windowGeometry.contentFrame
        let size = BrowserPortraitCaptureView.size
        if let anchor = model.portraitCaptureAnchor, anchor.window === window {
            let frame = convert(anchor.bounds, from: anchor)
            card.frame.origin = CGPoint(
                x: min(frame.midX - size.width / 2, bounds.width - size.width - 8),
                y: frame.maxY + 8,
            )
        } else {
            card.frame.origin = CGPoint(x: page.midX - size.width / 2, y: page.midY - size.height / 2)
        }
        model.portraitCaptureAnchor = nil
        addSubview(card, positioned: .above, relativeTo: nil)
        portraitCapture = card
        portraitCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .keyDown,
        ]) { [weak self, weak card] event in
            guard let self, let card else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                dismissPortraitCapture()
                return nil
            }
            if event.window === window, !card.frame.contains(convert(event.locationInWindow, from: nil)) {
                dismissPortraitCapture()
            }
            return event
        }
    }

    private func dismissPortraitCapture() {
        portraitCapture?.removeFromSuperview()
        portraitCapture = nil
        if let portraitCaptureMonitor {
            NSEvent.removeMonitor(portraitCaptureMonitor)
            self.portraitCaptureMonitor = nil
        }
    }

    private func showCaptureToast(_ configure: (BrowserCaptureToastView) -> Void) {
        captureToast.fill = model.selectedSpaceTheme?.palette?.tintedLight.nsColor ?? NSColor(white: 0.93, alpha: 1)
        configure(captureToast)
        addSubview(captureToast, positioned: .above, relativeTo: nil)
        layoutCaptureToast()
    }

    private func layoutCaptureToast() {
        let width = captureToast.preferredWidth
        captureToast.frame = CGRect(
            x: bounds.width - width - 8,
            y: 8,
            width: width,
            height: BrowserCaptureToastView.height,
        )
    }

    /// Holding Shift-Command and dragging on the page captures that part. A click
    /// with those keys stays the page's own.
    private func installCaptureDragMonitor() {
        captureDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
        ]) {
            [weak self] event in
            guard let self, event.window === window else { return event }
            return handleCaptureDrag(event)
        }
    }

    private func handleCaptureDrag(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            isCaptureDragging = false
            let keys = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard keys == [.command, .shift], model.canCaptureArea,
                  content.frame.contains(convert(event.locationInWindow, from: nil))
            else {
                captureDragStart = nil
                return event
            }
            captureDragStart = event
            return nil
        case .leftMouseDragged:
            guard let start = captureDragStart else { return event }
            if !isCaptureDragging {
                let distance = hypot(
                    event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y,
                )
                guard distance >= 4, model.beginAreaCapture(), let overlay = content.areaCapture else { return nil }
                isCaptureDragging = true
                overlay.mouseDown(with: start)
            }
            content.areaCapture?.mouseDragged(with: event)
            return nil
        case .leftMouseUp:
            guard let start = captureDragStart else { return event }
            captureDragStart = nil
            if isCaptureDragging {
                isCaptureDragging = false
                content.areaCapture?.mouseUp(with: event)
                return nil
            }
            // Only a click: it was the page's after all.
            window?.sendEvent(start)
            return event
        default:
            return event
        }
    }

    /// The sidebar shrinks a little and fades as the Library arrives, and comes back the same way.
    private func transitionSidebar(forLibraryPresented presented: Bool) {
        sidebarLibraryEnd += 1
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = sidebar.layer
        else {
            sidebar.isHidden = presented
            return
        }
        let center = CGPoint(
            x: preferences.sidebarPosition == .right
                ? sidebar.bounds.width - BrowserLibraryLayout.width / 2
                : BrowserLibraryLayout.width / 2,
            y: sidebar.bounds.height / 2,
        )
        var small = CATransform3DMakeTranslation(center.x, center.y, 0)
        small = CATransform3DScale(small, 0.95, 0.95, 1)
        small = CATransform3DTranslate(small, -center.x, -center.y, 0)
        // A swipe may have started the fade and the shrink already.
        let swipeOpacity = sidebar.alphaValue
        sidebar.alphaValue = 1
        let swipeTransform = CATransform3DIsIdentity(layer.transform) ? nil : layer.transform
        setSidebarLayerTransform(CATransform3DIdentity)
        let curve: BrowserNativeAnimation.Curve = presented ? .sidebarToLibrary : .sidebarFromLibrary
        let scale = curve.layerAnimation(keyPath: "transform")
        scale.fromValue = swipeTransform ?? (presented
            ? layer.presentation()?.transform ?? CATransform3DIdentity
            : small)
        scale.toValue = presented ? small : CATransform3DIdentity
        let fade = curve.layerAnimation(keyPath: "opacity")
        fade.fromValue = swipeOpacity < 1 ? Float(swipeOpacity) : layer.presentation()?.opacity ?? (presented ? 1 : 0)
        fade.toValue = presented ? 0 : 1
        if presented {
            for animation in [scale, fade] {
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
            layer.add(scale, forKey: "browser.sidebar.library.scale")
            layer.add(fade, forKey: "browser.sidebar.library.fade")
        } else {
            if sidebar.isHidden, swipeOpacity == 1 {
                fade.fromValue = 0
            }
            sidebar.isHidden = false
            layer.removeAnimation(forKey: "browser.sidebar.library.scale")
            layer.removeAnimation(forKey: "browser.sidebar.library.fade")
            // A group starts when the transaction commits, together with the Library's slide.
            let delay: CFTimeInterval = 0.05
            let group = CAAnimationGroup()
            for animation in [scale, fade] {
                animation.beginTime = delay
                animation.fillMode = .backwards
            }
            group.animations = [scale, fade]
            group.duration = curve.duration + delay
            layer.add(group, forKey: "browser.sidebar.library.return")
        }
        guard presented else { return }
        let end = sidebarLibraryEnd
        DispatchQueue.main.asyncAfter(deadline: .now() + curve.duration) { [weak self] in
            guard let self, sidebarLibraryEnd == end else { return }
            sidebar.isHidden = true
            layer.removeAnimation(forKey: "browser.sidebar.library.scale")
            layer.removeAnimation(forKey: "browser.sidebar.library.fade")
        }
    }

    /// Committed at once, so the slide and the fade run while the tab switches.
    private func beginSpaceTransition(to spaceID: String) {
        let delay = sidebar.sidebar.slidePager(toSpaceID: spaceID)
        background.setTheme(model.spaceThemesByID[spaceID], animated: !isEditingSpaceTheme, delay: delay + 0.02)
        CATransaction.flush()
    }

    private func updateURLFrame(_ frame: CGRect?) {
        guard frame != currentURLRowWindowFrame else { return }
        currentURLRowWindowFrame = frame
        configureCommandBars()
    }

    private func configureCommandBars() {
        let blockedTrailingInset = windowGeometry.trailingReservedWidth
        command.configure(
            blockedLeadingInset: browserContentMinX,
            blockedTrailingInset: blockedTrailingInset,
            style: .standard,
            faviconCandidate: nil,
        )
        // A click on the sidebar dismisses this bar, as one on the page does.
        currentPageCommand.configure(
            blockedLeadingInset: 0,
            blockedTrailingInset: preferences.sidebarPosition == .right ? 0 : blockedTrailingInset,
            style: .compact(
                anchorFrame: currentURLRowWindowFrame,
                sidebarWidth: model.sidebarWidth,
                matchesAnchorWidth: showsSiteToolbar,
            ),
            faviconCandidate: currentPageCommandBarFaviconCandidate,
        )
    }

    private func refresh() {
        sessionRecovery.update(model.sessionPersistenceFailure)
        let state = [
            model.isSidebarVisible,
            isSidebarHoverOverlayPresented,
            showsBookmarksBar,
            showsSiteToolbar,
            showsDeveloperToolbar,
            isExtensionSidePanelPresented,
            preferences.sidebarPosition == .right,
        ]
        if let previousLayoutState, previousLayoutState != state {
            animateNextLayout = true
            // Only the floating sidebar slides with its own spring; everything else
            // moves the page and keeps the shared ease.
            let changed = zip(previousLayoutState, state).enumerated().filter { $0.element.0 != $0.element.1 }
            nextLayoutCurve = changed.map(\.offset) == [1] ? .floatingSidebar : .sidebar
            if changed.map(\.offset) == [0] {
                nextLayoutDelay = model.isSidebarVisible ? 0.075 : 0.015
            }
            // The toolbar and bookmarks bar appear and leave at once.
            if Set(changed.map(\.offset)).isSubset(of: [2, 3]) {
                animateNextLayout = false
            }
            if model.isSidebarVisible,!previousLayoutState[0] {
                isSidebarOverlayPinning = isSidebarHoverOverlayChromeVisible
                finishSidebarHoverOverlayPromotionIfNeeded()
            }
        }
        previousLayoutState = state
        background.mode = chromeBackgroundMode
        background.setTheme(model.selectedSpaceTheme, animated: !isEditingSpaceTheme)
        pageLoadingIndicator.setColor(
            model.selectedSpaceTheme?.palette?.title.nsColor
                ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black),
        )
        pageLoadingIndicator.setLoading(model.canStopLoading)
        if window?.isMainWindow == true || BrowserPageScripts.pageStartScript == nil {
            BrowserPageScripts.pageStartScript = preferences.sharesThemeWithWebsites
                ? model.selectedSpaceTheme?.pageScript
                : nil
        }
        let libraryPresented = model.librarySection != nil
        if libraryPresented != wasLibraryPresented {
            wasLibraryPresented = libraryPresented
            if libraryPresented {
                library.isHidden = false
            } else {
                hideLibraryAfterSlide()
            }
            transitionSidebar(forLibraryPresented: libraryPresented)
            animateNextLayout = true
            nextLayoutCurve = libraryPresented ? .libraryOpen : .library
        }
        library.refresh()
        let page = windowGeometry.contentFrame
        let inset = BrowserLinkStatusView.inset
        let statusWidth = linkStatus.update(status: model.linkStatus, maximumWidth: max(page.width * 0.6, 1))
        linkStatus.frame = CGRect(
            x: page.minX + inset,
            y: page.maxY - BrowserLinkStatusView.height - inset,
            width: statusWidth,
            height: BrowserLinkStatusView.height,
        )
        libraryScrollObserver.isEnabled = libraryPresented && model.librarySection != .spaces
        let contentAppearance = model.selectedSpaceTheme?.palette.map {
            NSAppearance(named: $0.isLightContent ? .aqua : .darkAqua)
        } ?? nil
        if toolbar.appearance?.name != contentAppearance?.name {
            toolbar.appearance = contentAppearance
            bookmarks.appearance = contentAppearance
        }
        content.update(
            hostView: model.hostView,
            isContextReady: model.isContextReady,
            hasSelectedTab: model.selectedTabID != nil,
            isSidebarVisible: model.isSidebarVisible,
            usesWindowContentInsets: usesWindowContentInsets,
            sidebarPosition: preferences.sidebarPosition,
            selectedTabCreationState: model.selectedTabCreationState,
        )
        sidebar.sidebarPosition = preferences.sidebarPosition
        sidebar.showsWindowControls = showsWindowControlsInSidebarChrome
        sidebar.isOverlayPresentation = isSidebarOverlayPresentation
        sidebar.refresh()
        toolbarVisibility.setVisible(showsSiteToolbar, view: toolbar, curve: .sidebar)
        developerToolbar.refresh()
        refreshPasswordPrompt()
        let selectionColor = model.selectedSpaceTheme?.palette?.accentFill
        command.themeSelectionColor = selectionColor
        currentPageCommand.themeSelectionColor = selectionColor
        toolbar.refresh()
        bookmarksVisibility.setVisible(showsBookmarksBar, view: bookmarks, curve: .sidebar)
        bookmarks.refresh()
        if let panel = model.extensionSidePanel, let host = model.extensionSidePanelHostView {
            let view = extensionPanel ?? BrowserExtensionSidePanelNSView(hostView: host)
            if extensionPanel == nil {
                extensionPanel = view
                addSubview(view, positioned: .above, relativeTo: sidebar)
                view.frame = windowGeometry.extensionFrame.offsetBy(dx: windowGeometry.extensionFrame.width, dy: 0)
                extensionVisibility.setVisible(false, view: view, curve: .sidebar)
            }
            extensionVisibility.setVisible(true, view: view, curve: .sidebar)
            view.onClose = { [weak model] in model?.closeExtensionSidePanel() }
            view.update(
                sidePanel: panel,
                hostView: host,
                isContextReady: model.isContextReady,
                usesWindowContentInsets: usesWindowContentInsets,
            )
        } else if let extensionPanel {
            extensionVisibility.setVisible(false, view: extensionPanel, curve: .sidebar)
        }
        extensionResize.isHidden = !isExtensionSidePanelPresented
        extensionResize.hapticsEnabled = preferences.hapticFeedbackEnabled
        revealEdge.isHidden = model.isSidebarVisible || isSidebarPresented
        tabEvents.isEnabled = model.selectedTabID != nil
        // The switcher appears and leaves at once, like the command bar.
        tabSwitcher.isHidden = model.tabSwitcherState?.isVisible != true
        tabSwitcher.alphaValue = 1
        if let state = model.tabSwitcherState {
            tabSwitcher.update(state: state)
        }
        find.refresh(from: model, blockedLeadingInset: 0)
        configureCommandBars()
        needsLayout = true
    }

    private func finishPresentationAnimation() {
        isAnimatingFrames = false
        isSidebarOverlayPinning = false
        if !isExtensionSidePanelPresented {
            extensionPanel?.removeFromSuperview()
            extensionPanel = nil
        }
        if !isSidebarPresented {
            isSidebarHoverOverlayChromeVisible = false
        }
        showsSidebarWindowControls = model.isSidebarVisible || isSidebarPresented
        sidebar.showsWindowControls = showsWindowControlsInSidebarChrome
        sidebar.isOverlayPresentation = isSidebarOverlayPresentation
        sidebar.refresh()
    }

    private func handleSidebarRevealEdgeHoverChange(_ hovering: Bool) {
        guard !model.isSidebarVisible, isSidebarRevealEdgeHovered != hovering else { return }
        isSidebarRevealEdgeHovered = hovering
        revealTask?.cancel()
        guard hovering,!isSidebarPresented else { return }
        revealTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarHoverRevealDelayNanoseconds)
            } catch {
                return
            }
            guard let self, isSidebarRevealEdgeHovered,!isSidebarPresented else { return }
            presentSidebarHoverOverlay()
        }
    }

    private func handleWindowFullscreenStateChange(_ state: BrowserWindowFullscreenState) {
        isWindowFullscreen = state.isFullscreen
        isWindowFullscreenTransitioning = state.isTransitioning
        if state.isTransitioning {
            preserveSidebarHoverOverlayDuringFullscreenTransitionIfNeeded()
        } else {
            restoreSidebarHoverOverlayAfterFullscreenTransitionIfNeeded()
        }
        refresh()
    }

    /// Open Extensions opens the control center of the visible URL controls.
    /// With the sidebar hidden and no toolbar it points at the page's top
    /// corner on the sidebar side.
    /// Opens the theme editor beside the sidebar, at the Space's title. The Space
    /// is selected first, so edits show on the window at once.
    private func presentSpaceThemeEditor(spaceID: String) {
        model.selectSpace(id: spaceID)
        showSpaceThemeEditor(theme: model.spaceThemesByID[spaceID]) { [weak self] theme, commit in
            self?.model.setTheme(theme, forSpaceID: spaceID, persist: commit)
        }
    }

    /// The Space being created has no ID yet; its draft holds the theme.
    private func presentSpaceCreationThemeEditor() {
        showSpaceThemeEditor(theme: model.spaceCreationDraft?.theme) { [weak self] theme, _ in
            self?.model.updateSpaceCreationDraft { $0.theme = theme.colors.isEmpty ? nil : theme }
        }
    }

    private func showSpaceThemeEditor(
        theme: BrowserSpaceTheme?,
        onChange: @escaping (BrowserSpaceTheme, Bool) -> Void,
    ) {
        spaceThemePopover?.performClose(nil)
        let editor = BrowserSpaceThemeEditorViewController(theme: theme)
        editor.onChange = onChange
        let popover = BrowserNativePopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = editor
        popover.contentSize = BrowserSpaceThemeEditorLayout.size
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.setValue(true, forKey: "shouldHideAnchor")
        spaceThemePopover = popover
        let onLeft = preferences.sidebarPosition == .left
        let x = onLeft ? sidebarLayoutWidth : bounds.width - sidebarLayoutWidth
        popoverAnchor.frame = CGRect(x: x, y: BrowserChromeLayout.spaceThemeEditorAnchorY, width: 1, height: 1)
        popover.show(relativeTo: popoverAnchor.bounds, of: popoverAnchor, preferredEdge: onLeft ? .maxX : .minX)
    }

    private func openExtensions() {
        if showsSiteToolbar {
            toolbar.showControlCenter()
            return
        }
        let controls = sidebar.header.urlControls
        guard !model.isSidebarVisible, !isSidebarHoverOverlayActive else {
            controls.showControlCenter()
            return
        }
        let page = windowGeometry.contentFrame
        let inset = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let x = preferences.sidebarPosition == .right ? page.maxX - inset : page.minX + inset
        popoverAnchor.frame = CGRect(x: x, y: page.minY + inset, width: 1, height: 1)
        controls.showControlCenter(anchor: popoverAnchor, preferredEdge: .maxY)
    }

    /// View Downloads opens the sidebar footer's list. With the sidebar hidden or
    /// without the footer button, the list points at the page's bottom corner on
    /// the sidebar side instead.
    /// Downloads live in the Library; without Spaces, in an incognito window, they
    /// stay in a popover over the page.
    private func toggleDownloads() {
        guard model.supportsSpaces else {
            showDownloadsPopover()
            return
        }
        if model.librarySection == .downloads {
            model.closeLibrary()
        } else {
            model.openLibrary(section: .downloads)
        }
    }

    private func showDownloadsPopover() {
        let footer = sidebar.footer
        // Without Spaces, as in an incognito window, the footer has no Downloads button.
        let showsButton = (model.isSidebarVisible || isSidebarHoverOverlayActive) && model.supportsSpaces
        guard !showsButton, !footer.isDownloadsPresented else {
            footer.toggleDownloads()
            return
        }
        let page = windowGeometry.contentFrame
        let inset = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let x = preferences.sidebarPosition == .right ? page.maxX - inset : page.minX + inset
        footer.toggleDownloads(anchor: (CGRect(x: x, y: page.maxY - inset, width: 1, height: 1), self, .minY))
    }

    private func finishSidebarHoverOverlayPromotionIfNeeded() {
        isSidebarHoverOverlayPresented = false
        isSidebarHoverOverlayChromeVisible = false
        preservesSidebarHoverOverlayDuringFullscreenTransition = false
        isSidebarHoverOverlayPointerSyncSuspended = false
        isSidebarRevealEdgeHovered = false
        revealTask?.cancel()
        showsSidebarWindowControls = true
    }

    private func presentSidebarHoverOverlay() {
        guard !model.isSidebarVisible,!isSidebarHoverOverlayPresented else { return }
        isSidebarRevealEdgeHovered = false
        isSidebarHoverOverlayPointerSyncSuspended = false
        isSidebarHoverOverlayChromeVisible = true
        // Prepare the owned background before moving the sidebar into the window.
        sidebar.isOverlayPresentation = true
        sidebar.showsWindowControls = true
        sidebar.refresh()
        frameAnimation.cancel()
        isAnimatingFrames = false
        sidebar.frame = windowGeometry.sidebarFrame
        sidebar.layoutSubtreeIfNeeded()
        isSidebarHoverOverlayPresented = true
        refresh()
    }

    /// Reveal Current Tab shows a hidden sidebar as the hover overlay. It stays
    /// until the pointer moves, then follows the pointer like a hover reveal.
    private func revealSidebarFromKeyboard() {
        guard !model.isSidebarVisible, !isSidebarHoverOverlayPresented else { return }
        presentSidebarHoverOverlay()
        isSidebarHoverOverlayPointerSyncSuspended = true
        refresh()
    }

    private func dismissSidebarHoverOverlay() {
        guard isSidebarHoverOverlayPresented, !sidebar.sidebar.state.isDraggingSidebarItem else { return }
        guard !isWindowFullscreenTransitioning else { preserveSidebarHoverOverlayDuringFullscreenTransitionIfNeeded()
            return
        }
        guard !isSidebarHoverOverlayPointerSyncSuspended else { return }
        isSidebarRevealEdgeHovered = false
        revealTask?.cancel()
        isSidebarHoverOverlayPointerSyncSuspended = false
        isSidebarHoverOverlayPresented = false
        refresh()
    }

    private func preserveSidebarHoverOverlayDuringFullscreenTransitionIfNeeded() {
        guard isSidebarHoverOverlayActive || isSidebarOverlayPresentation else { return }
        preservesSidebarHoverOverlayDuringFullscreenTransition = true
        isSidebarHoverOverlayPointerSyncSuspended = true
        isSidebarRevealEdgeHovered = false
        revealTask?.cancel()
        isSidebarHoverOverlayChromeVisible = true
        isSidebarHoverOverlayPresented = true
    }

    private func restoreSidebarHoverOverlayAfterFullscreenTransitionIfNeeded() {
        guard preservesSidebarHoverOverlayDuringFullscreenTransition else { return }
        preservesSidebarHoverOverlayDuringFullscreenTransition = false
        guard !model.isSidebarVisible else {
            isSidebarHoverOverlayPointerSyncSuspended = false
            isSidebarHoverOverlayPresented = false
            isSidebarHoverOverlayChromeVisible = false
            return
        }
        isSidebarRevealEdgeHovered = false
        revealTask?.cancel()
        isSidebarHoverOverlayChromeVisible = true
        isSidebarHoverOverlayPresented = true
    }

    private func handleSidebarHoverOverlayPointerMovement() {
        guard !isWindowFullscreenTransitioning, isSidebarHoverOverlayPointerSyncSuspended else { return }
        isSidebarHoverOverlayPointerSyncSuspended = false
        refresh()
    }
}
