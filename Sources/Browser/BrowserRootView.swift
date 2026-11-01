// BrowserRootView.swift

import AppKit
import Combine
import QuartzCore

final class BrowserRootView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    // MARK: Private

    private let model: BrowserChromeModel
    private let updateController: BrowserUpdateController
    private let background = BrowserChromeBackgroundNSView()
    private let content: BrowserContentNSView
    private let sidebar: BrowserSidebarChromeView
    private let toolbar: BrowserSiteControlsNSView
    private let bookmarks: BrowserBookmarksBarNSView
    private let margins = BrowserNativeWindowMargins()
    private let revealEdge = BrowserNativeSidebarRevealEdge()
    private let find = BrowserFindBarNSView()
    private let pageLoadingIndicator = BrowserPageLoadingIndicatorView()
    private let command: BrowserCommandBarNSView
    private let currentPageCommand: BrowserCommandBarNSView
    private let sidebarDismiss = BrowserSidebarHoverOverlayDismissNSView()
    private let sidebarInteraction = BrowserPassthroughInteractionNSView()
    private let tabEvents = BrowserTabSwitcherEventNSView()
    private let tabSwitcher = BrowserTabSwitcherNSView()
    private let tabSwitcherVisibility = BrowserNativeVisibilityAnimation()
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
    private var animateNextLayout = false
    private var nextLayoutCurve = BrowserNativeAnimation.Curve.sidebar
    private let frameAnimation = BrowserNativeAnimation()
    private var isAnimatingFrames = false
    private var lastFrameTargets = [ObjectIdentifier: CGRect]()
    private var showsSidebarWindowControls: Bool
    private var isWindowFullscreen = false
    private var isWindowFullscreenTransitioning = false
    private var isSidebarHoverOverlayPresented = false
    private var isSidebarHoverOverlayChromeVisible = false
    private var preservesSidebarHoverOverlayDuringFullscreenTransition = false
    private var isSidebarHoverOverlayPointerSyncSuspended = false
    private var isSidebarRevealEdgeHovered = false
    private var currentURLRowWindowFrame: CGRect?

    private var preferences: BrowserUserPreferencesStore { model.userPreferencesStore }
    private var shortcutStore: BrowserShortcutStore { model.shortcutStore }
    private var commandBarModel: BrowserCommandBarModel { model.commandBarModel }
    private var currentPageCommandBarModel: BrowserCommandBarModel { model.currentPageCommandBarModel }
    private var sidebarSnapshot: BrowserSidebarSnapshot { model.sidebarSnapshot }
    private var windowGeometry: BrowserWindowChromeLayout {
        .init(
            windowSize: bounds.size,
            sidebarWidth: model.librarySection == nil ? model.sidebarWidth : BrowserLibraryLayout.width,
            isSidebarVisible: model.isSidebarVisible || model.librarySection != nil,
            isHoverSidebarPresented: isSidebarHoverOverlayPresented,
            isOverlayChromeVisible: isSidebarHoverOverlayChromeVisible,
            isFullscreen: isWindowFullscreen,
            showsSiteToolbar: showsSiteToolbar,
            showsBookmarksBar: showsBookmarksBar,
            extensionSidePanelWidth: isExtensionSidePanelPresented ? model.extensionSidePanelWidth : nil,
            sidebarPosition: preferences.sidebarPosition,
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
    private var isSidebarOverlayPresentation: Bool { !model.isSidebarVisible && isSidebarHoverOverlayChromeVisible }
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
        find.bind(to: model)
        content.bindTabCreation(to: model)
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
        model.onOpenExtensions = { [weak self] in self?.openExtensions() }
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
        let onRight = preferences.sidebarPosition == .right
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
        var targets: [(NSView, CGRect)] = [
            (content, geometry.contentFrame), (find, geometry.contentFrame), (sidebar, geometry.sidebarFrame),
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
                CGRect(
                    x: libraryShown ? 0 : -libraryWidth,
                    y: 0,
                    width: libraryWidth,
                    height: bounds.height,
                ),
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
        isAnimatingFrames = animate
        let starts = targets.map(\.0.frame)
        let updates: @MainActor (Double) -> Void = { [weak self] progress in
            guard let self else { return }
            for (index, target) in targets.enumerated() {
                target.0.frame = BrowserNativeAnimation.interpolate(starts[index], target.1, progress)
            }
            for (view, _) in targets {
                view.layoutSubtreeIfNeeded()
            }
            // Keep hit regions and anchored panels on the same geometry as the page.
            if preferences.sidebarPosition == .right {
                let minX = min(max(content.frame.maxX, extensionPanel?.frame.maxX ?? 0), bounds.width)
                sidebarInteraction.frame = NSRect(x: minX, y: 0, width: bounds.width - minX, height: bounds.height)
            } else {
                sidebarInteraction.frame.size.width = max(content.frame.minX, 0)
            }
        }
        if animate {
            frameAnimation.start(curve, updates: updates) { [weak self] in
                self?.finishPresentationAnimation()
            }
        } else {
            updates(1)
            finishPresentationAnimation()
        }
    }

    private func sidebarFrame(in _: CGSize) -> CGRect { windowGeometry.sidebarFrame }

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
        currentPageCommand.configure(
            blockedLeadingInset: browserContentMinX,
            blockedTrailingInset: blockedTrailingInset,
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
            isExtensionSidePanelPresented,
            preferences.sidebarPosition == .right,
        ]
        if let previousLayoutState, previousLayoutState != state {
            animateNextLayout = true
            // Only the floating sidebar slides with its own spring; everything else
            // moves the page and keeps the shared ease.
            let changed = zip(previousLayoutState, state).enumerated().filter { $0.element.0 != $0.element.1 }
            nextLayoutCurve = changed.map(\.offset) == [1] ? .floatingSidebar : .sidebar
            if model.isSidebarVisible,!previousLayoutState[0] {
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
        if window?.isMainWindow == true || BrowserContentBlockerEngine.pageStartScript == nil {
            BrowserContentBlockerEngine.pageStartScript = preferences.sharesThemeWithWebsites
                ? model.selectedSpaceTheme?.pageScript
                : nil
        }
        let libraryPresented = model.librarySection != nil
        if libraryPresented != wasLibraryPresented {
            wasLibraryPresented = libraryPresented
            if libraryPresented {
                library.isHidden = false
            } else {
                // Off screen after its slide, and out of reach of the keyboard and accessibility.
                let duration = BrowserNativeAnimation.Curve.library.duration
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self, model.librarySection == nil else { return }
                    library.isHidden = true
                }
            }
            sidebar.isHidden = libraryPresented
            animateNextLayout = true
            nextLayoutCurve = .library
        }
        library.refresh()
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
        tabSwitcherVisibility.setVisible(
            model.tabSwitcherState?.isVisible == true,
            view: tabSwitcher,
            curve: .easeOut(0.12),
        )
        if let state = model.tabSwitcherState {
            tabSwitcher.update(state: state)
        }
        find.refresh(from: model, blockedLeadingInset: 0)
        configureCommandBars()
        needsLayout = true
    }

    private func finishPresentationAnimation() {
        isAnimatingFrames = false
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
