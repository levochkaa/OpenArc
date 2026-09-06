import AppKit
import Combine
import QuartzCore

final class BrowserRootView: NSView {
    // MARK: Lifecycle

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
            sidebar,
            extensionResize,
            revealEdge,
            find,
            sidebarDismiss,
            sidebarInteraction,
            command,
            currentPageCommand,
            tabEvents,
            tabSwitcher,
            fullscreenReader,
        ] {
            addSubview(view)
        }
        find.bind(to: model)
        sidebar.onToggleSidebar = { [weak model] in model?.toggleSidebar() }
        sidebar.onURLFrameChange = { [weak self] frame in self?.updateURLFrame(frame) }
        toolbar.onURLFrameChange = { [weak self] frame in self?.updateURLFrame(frame) }
        revealEdge.onHoverChange = { [weak self] in self?.handleSidebarRevealEdgeHoverChange($0) }
        fullscreenReader.onFullscreenStateChange = { [weak self] in self?.handleWindowFullscreenStateChange($0) }
        margins.menuProvider = { [weak self] in
            guard let self,!preferences.bookmarksBarVisible else { return nil }
            let menu = BrowserNativeMenus.menu()
            BrowserNativeMenus.add(
                BrowserStrings.settingsShowBookmarksBar,
                to: menu,
                shortcut: shortcutStore.shortcut(for: .toggleBookmarksBar)
            ) { [weak model] in model?
                .userPreferencesStore
                .bookmarksBarVisible
                .toggle()
            }
            return menu
        }
        sidebarInteraction.eventMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        sidebarInteraction.onInteraction = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, sidebarLayoutWidth > 0, commandBarModel.isPresented,
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

    // MARK: Internal

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let animate = animateNextLayout && window != nil && !isWindowFullscreenTransitioning
        animateNextLayout = false
        background.frame = bounds
        margins.frame = bounds
        margins.configure(
            blockedLeadingWidth: contentEdgeDragBlockedLeadingWidth,
            leading: browserContentLeadingInset,
            top: browserContentTopInset,
            trailing: browserContentTrailingInset,
            bottom: browserContentBottomInset
        )
        for overlay in [find, command, currentPageCommand, tabEvents, tabSwitcher, sidebarDismiss] {
            overlay.frame = bounds
        }
        sidebarInteraction.frame = NSRect(x: 0, y: 0, width: sidebarLayoutWidth, height: bounds.height)
        revealEdge.frame = NSRect(x: 0, y: 0, width: BrowserChromeLayout.sidebarHoverRevealWidth, height: bounds.height)
        sidebarDismiss.update(
            isPresented: isSidebarHoverOverlayActive,
            sidebarFrame: sidebarFrame(in: bounds.size),
            allowsPointerSyncDismissal: allowsSidebarHoverOverlayPointerSyncDismissal,
            onPointerMovement: { [weak self] in self?.handleSidebarHoverOverlayPointerMovement() },
            onDismiss: { [weak self] in self?.dismissSidebarHoverOverlay() }
        )
        let geometry = windowGeometry
        var targets: [(NSView, CGRect)] = [
            (content, geometry.contentFrame), (sidebar, geometry.sidebarFrame),
            (toolbar, geometry.toolbarFrame), (bookmarks, geometry.bookmarksFrame),
            (extensionResize, geometry.extensionResizeFrame),
        ]
        if let extensionPanel {
            targets.append((extensionPanel, geometry.extensionFrame))
        }
        let targetFrames = Dictionary(uniqueKeysWithValues: targets.map { (ObjectIdentifier($0.0), $0.1) })
        // Model notifications unrelated to geometry must not interrupt an in-flight transition.
        if isAnimatingFrames, targetFrames == lastFrameTargets {
            return
        }
        lastFrameTargets = targetFrames
        animationGeneration += 1
        let generation = animationGeneration
        isAnimatingFrames = animate
        func frames(_ animated: Bool) {
            for (view, rect) in targets {
                if animated {
                    view.animator().frame = rect
                } else {
                    view.frame = rect
                }
            }
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BrowserChromeLayout.sidebarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                frames(true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == animationGeneration else { return }
                    finishPresentationAnimation()
                }
            }
        } else {
            frames(false)
            finishPresentationAnimation()
        }
    }

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
    private let command: BrowserCommandBarNSView
    private let currentPageCommand: BrowserCommandBarNSView
    private let sidebarDismiss = BrowserSidebarHoverOverlayDismissNSView()
    private let sidebarInteraction = BrowserPassthroughInteractionNSView()
    private let tabEvents = BrowserTabSwitcherEventNSView()
    private let tabSwitcher = BrowserTabSwitcherNSView()
    private let fullscreenReader = BrowserWindowFullscreenReaderNSView()
    private let extensionResize = BrowserNativeResizeHandle()
    private var extensionPanel: BrowserExtensionSidePanelNSView?
    private var observations = Set<AnyCancellable>()
    private var revealTask: Task<Void, Never>?
    private var previousLayoutState: [Bool]?
    private var animateNextLayout = false
    private var animationGeneration = 0
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
            sidebarWidth: model.sidebarWidth,
            isSidebarVisible: model.isSidebarVisible,
            isHoverSidebarPresented: isSidebarHoverOverlayPresented,
            isOverlayChromeVisible: isSidebarHoverOverlayChromeVisible,
            isFullscreen: isWindowFullscreen,
            showsSiteToolbar: showsSiteToolbar,
            showsBookmarksBar: showsBookmarksBar,
            extensionSidePanelWidth: isExtensionSidePanelPresented ? model.extensionSidePanelWidth : nil
        )
    }

    private var sidebarLayoutWidth: CGFloat { windowGeometry.sidebarReservedWidth }
    private var showsBookmarksBar: Bool { model.isContextReady && preferences.bookmarksBarVisible }
    private var showsSiteToolbar: Bool { model.isContextReady && preferences.siteURLToolbarEnabled }
    private var isExtensionSidePanelPresented: Bool {
        model.extensionSidePanel != nil && model.extensionSidePanelHostView != nil
    }

    private var chromeBackgroundMode: BrowserChromeBackgroundMode { preferences.blurredChromeBackgroundEnabled
        ? .blurred
        : .black
    }

    private var isSidebarPresented: Bool { model.isSidebarVisible || isSidebarHoverOverlayPresented }
    private var isSidebarHoverOverlayActive: Bool { !model.isSidebarVisible && isSidebarHoverOverlayPresented }
    private var isSidebarOverlayPresentation: Bool { !model.isSidebarVisible && isSidebarHoverOverlayChromeVisible }
    private var showsWindowControlsInSidebarChrome: Bool {
        showsSidebarWindowControls || isSidebarHoverOverlayChromeVisible
    }

    private var allowsSidebarHoverOverlayPointerSyncDismissal: Bool {
        !isWindowFullscreenTransitioning && !isSidebarHoverOverlayPointerSyncSuspended
    }

    private var contentEdgeDragBlockedLeadingWidth: CGFloat { sidebarLayoutWidth }
    private var currentPageCommandBarFaviconCandidate: BrowserCommandBarFaviconCandidate? {
        model.currentTab.map(BrowserCommandBarFaviconCandidate.init(tab:))
    }

    private var usesWindowContentInsets: Bool { !isWindowFullscreen }
    private var browserContentLeadingInset: CGFloat { windowGeometry.leadingInset }
    private var browserContentTopInset: CGFloat { windowGeometry.edgeInset }
    private var browserContentTrailingInset: CGFloat { windowGeometry.edgeInset }
    private var browserContentBottomInset: CGFloat { windowGeometry.edgeInset }
    private var browserContentMinX: CGFloat { windowGeometry.contentMinX }

    private func sidebarFrame(in _: CGSize) -> CGRect { windowGeometry.sidebarFrame }

    private func updateURLFrame(_ frame: CGRect?) {
        guard frame != currentURLRowWindowFrame else { return }
        currentURLRowWindowFrame = frame
        configureCommandBars()
    }

    private func configureCommandBars() {
        command.configure(blockedLeadingInset: browserContentMinX, style: .standard, faviconCandidate: nil)
        currentPageCommand.configure(
            blockedLeadingInset: browserContentMinX,
            style: .compact(
                anchorFrame: currentURLRowWindowFrame,
                sidebarWidth: model.sidebarWidth,
                matchesAnchorWidth: showsSiteToolbar
            ),
            faviconCandidate: currentPageCommandBarFaviconCandidate
        )
    }

    private func refresh() {
        let state = [
            model.isSidebarVisible,
            isSidebarHoverOverlayPresented,
            showsBookmarksBar,
            showsSiteToolbar,
            isExtensionSidePanelPresented,
        ]
        if let previousLayoutState, previousLayoutState != state {
            animateNextLayout = true
            if model.isSidebarVisible,!previousLayoutState[0] {
                finishSidebarHoverOverlayPromotionIfNeeded()
            }
        }
        previousLayoutState = [
            model.isSidebarVisible,
            isSidebarHoverOverlayPresented,
            showsBookmarksBar,
            showsSiteToolbar,
            isExtensionSidePanelPresented,
        ]
        background.mode = chromeBackgroundMode
        content.update(
            hostView: model.hostView,
            isContextReady: model.isContextReady,
            hasSelectedTab: model.selectedTabID != nil,
            isSidebarVisible: model.isSidebarVisible,
            usesWindowContentInsets: usesWindowContentInsets
        )
        sidebar.showsWindowControls = showsWindowControlsInSidebarChrome
        sidebar.isOverlayPresentation = isSidebarOverlayPresentation
        sidebar.refresh()
        toolbar.isHidden = !showsSiteToolbar
        toolbar.refresh()
        bookmarks.isHidden = !showsBookmarksBar
        bookmarks.refresh()
        if let panel = model.extensionSidePanel, let host = model.extensionSidePanelHostView {
            let view = extensionPanel ?? BrowserExtensionSidePanelNSView(hostView: host)
            if extensionPanel == nil {
                extensionPanel = view
                addSubview(view, positioned: .above, relativeTo: sidebar)
            }
            view.onClose = { [weak model] in model?.closeExtensionSidePanel() }
            view.update(
                sidePanel: panel,
                hostView: host,
                isContextReady: model.isContextReady,
                usesWindowContentInsets: usesWindowContentInsets
            )
        } else {
            extensionPanel?.removeFromSuperview()
            extensionPanel = nil
        }
        extensionResize.isHidden = !isExtensionSidePanelPresented
        extensionResize.hapticsEnabled = preferences.hapticFeedbackEnabled
        revealEdge.isHidden = model.isSidebarVisible || isSidebarPresented
        tabEvents.isEnabled = model.selectedTabID != nil
        tabSwitcher.isHidden = model.tabSwitcherState?.isVisible != true
        if let state = model.tabSwitcherState {
            tabSwitcher.update(state: state)
        }
        find.refresh(from: model, blockedLeadingInset: browserContentMinX)
        configureCommandBars()
        needsLayout = true
    }

    private func finishPresentationAnimation() {
        isAnimatingFrames = false
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
            do { try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarHoverRevealDelayNanoseconds) } catch {
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
        DispatchQueue.main.async { [weak self] in
            guard let self,!model.isSidebarVisible, isSidebarHoverOverlayChromeVisible,
                  !isSidebarHoverOverlayPresented else { return }
            isSidebarHoverOverlayPresented = true
            refresh()
        }
    }

    private func dismissSidebarHoverOverlay() {
        guard isSidebarHoverOverlayPresented else { return }
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
