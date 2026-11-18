// BrowserNativeSidebarNSView.swift

import AppKit
import Combine
import QuartzCore
import UniformTypeIdentifiers

// MARK: - BrowserNativeSidebarNSView

/// AppKit owns sidebar layout, row identity, scrolling, selection, rename editors and drag/drop.
/// Header and footer share native chrome controls with the main toolbar.
final class BrowserNativeSidebarNSView: NSView {
    private static let spaceSelectionDelay: CFTimeInterval = 0.05
    private static let swipeReleaseDelay: CFTimeInterval = 0.05

    private static let leavingPageKey = "browser.page.leaving"

    /// Every sidebar, so a tab dragged out of one can land in another window's.
    private static let sidebars = NSHashTable<BrowserNativeSidebarNSView>.weakObjects()

    // MARK: Internal

    override var isFlipped: Bool { true }

    let state: BrowserNativeSidebarState
    let header: NSView
    var onHoverChanged: (Bool) -> Void = { _ in }
    let footer: NSView
    var headerHeight: CGFloat = BrowserChromeLayout.chromeButtonSize
    var footerHeight: CGFloat = BrowserChromeLayout.chromeButtonSize
    var isCommandBarPresented = false
    var onDragInteractionChange: (Bool) -> Void = { _ in }
    var headerHeightProvider: (() -> CGFloat)?
    var footerHeightProvider: ((CGFloat) -> CGFloat)?
    /// The Space a swipe is moving toward and how far, nil when no swipe is on.
    var onSpacePagerProgress: (String?, CGFloat) -> Void = { _, _ in }
    /// Option held at the drop copies the dragged items instead of moving them.
    var isCopyModifierHeld: () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    /// The footer's Space icons, which accept dragged tabs.
    weak var spaceDock: BrowserSpaceDockNSView?

    /// Folder preview beside a collapsed folder row.
    let folderPreview = BrowserFolderPreviewCoordinator()

    private(set) var linkDropProposal: BrowserSidebarDropProposal?

    let miniPlayers = BrowserMiniPlayerStackNSView()

    // MARK: Private

    private let content = BrowserNativeSidebarBackground()
    private let downloadsTray = BrowserDownloadsTrayView()
    private var isLibraryButtonHovered = false
    private var downloadsTrayWork: DispatchWorkItem?
    private var downloadsTrayTimer: Timer?
    private let appGrid = BrowserNativeSidebarBackground()
    private let emptyAppGuide = BrowserNativeNoninteractiveSurface()
    private let emptyAppGuideLabel = BrowserNativeControls.label(
        BrowserStrings.sidebarDragToAddFavorites,
        size: 12,
        color: BrowserChromeColors.sidebarDimText,
    )
    private var emptyAppEntryFrame: CGRect?
    private var reservedAppHeight: CGFloat = 0
    private var isProjectingAppGrid = false
    private let pagerClip = BrowserNativeSurface()
    private let creationPage = BrowserSpaceCreationView()
    private let pagesContainer = BrowserNativeSurface()
    private let bottomDivider = BrowserNativeSurface()
    private let dragIndicator = BrowserSidebarInsertionIndicator()
    private let dragPreview = BrowserNativeSidebarDragPreview()
    private let dragEvents = BrowserSidebarDragEventSession()
    private var showsCopyCursor = false
    /// Another window's sidebar under a tab dragged from this one.
    private weak var otherWindowDropTarget: BrowserNativeSidebarNSView?

    private let landingAnimation = BrowserNativeAnimation()
    private var dragPreviewTargetSize: CGSize?
    private var dragPreviewIsAppTile = false
    private lazy var handledRevealRequestID = state.model.sidebarRevealRequestID
    private lazy var handledRenameRequestID = state.model.sidebarRenameRequestID
    private lazy var handledSpaceRenameRequestID = state.model.sidebarSpaceRenameRequestID
    private var lastWindowDragPoint = CGPoint.zero
    private var acceptsLinkDrop = false
    private var reportedDragging = false
    private var highlightedDropRow: BrowserNativeSidebarRowNSView?
    /// A folder that takes the drop is marked by a band across the whole
    /// sidebar, behind the rows, not by a pill on its row.
    private let folderDropBand = BrowserNativeNoninteractiveSurface()
    private var folderDropBandID: String?
    /// Past the sidebar the preview is drawn by a panel of its own, which
    /// follows the pointer over the page, other windows and the desktop.
    private var outsidePreviewPanel: NSPanel?
    /// The tab shown before a drag selected the dragged one.
    private var tabSelectedBeforeDrag: String?
    /// The dragged tab's page as it looked when the drag began, shown outside the window.
    private var draggedPageThumbnail: NSImage?
    private var draggedPageThumbnailTabID: String?
    private var splitPreviewRow: BrowserNativeSidebarRowNSView?
    private let scrollObserver = BrowserSpacePagerScrollNSView()
    private var pages = [String: BrowserNativeSidebarPage]()
    private var staleRowHoverCheck: DispatchWorkItem?
    private var appTiles = [String: BrowserNativeSidebarRowNSView]()
    private var hasRenderedAppTiles = false
    private var tracking: NSTrackingArea?
    private var clickMonitor: Any?
    private var isLayingOut = false
    private let frameTransitions = BrowserNativeFrameTransitions()

    private var pagerSlideEnd: CFTimeInterval = 0
    private var leavingPageX = [ObjectIdentifier: CGFloat]()

    private var renderedSnapshot: BrowserSidebarSnapshot { state.renderedSnapshot(for: state.snapshot) }
    private var frameTransitionsAreRunning: Bool { CACurrentMediaTime() < pagerSlideEnd }

    init(state: BrowserNativeSidebarState, header: NSView, footer: NSView) {
        self.state = state
        self.header = header
        self.footer = footer
        super.init(frame: .zero)
        Self.sidebars.add(self)
        (footer as? BrowserSidebarLibraryButtonHosting)?.onLibraryHoverChanged = { [weak self] hovered in
            self?.isLibraryButtonHovered = hovered
            self?.scheduleDownloadsTray()
        }
        downloadsTray.onHoverChanged = { [weak self] in self?.scheduleDownloadsTray() }
        downloadsTray.alphaValue = 0
        setAccessibilityIdentifier("browser.sidebar")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        folderDropBand.strokeWidth = 0
        folderDropBand.isHidden = true
        folderDropBand.setAccessibilityElement(false)
        folderDropBand.setAccessibilityIdentifier("browser.sidebar.folder-drop-band")
        addSubview(folderDropBand)
        addSubview(content)
        content.clipsToBounds = false
        for view in [
            header,
            appGrid,
            emptyAppGuide,
            pagerClip,
            footer,
            bottomDivider,
            miniPlayers,
            dragPreview,
            dragIndicator,
            scrollObserver,
        ] {
            content.addSubview(view)
        }
        emptyAppGuide.cornerRadius = 8
        emptyAppGuide.fillColor = BrowserChromeColors.rowHover
        emptyAppGuide.strokeColor = BrowserChromeColors.sidebarOverlayBorder
        emptyAppGuide.isHidden = true
        emptyAppGuideLabel.alignment = .center
        emptyAppGuide.addSubview(emptyAppGuideLabel)
        frameTransitions.onFrameChange = { [weak self] in self?.needsLayout = true }
        pagerClip.addSubview(pagesContainer)
        pagesContainer.addSubview(creationPage)
        creationPage.isHidden = true
        creationPage.onTitleChange = { [weak state] title in
            state?.model.updateSpaceCreationDraft { $0.title = title }
        }
        creationPage.onChooseIcon = { [weak state] anchor in
            BrowserIconPickerPresenter.shared.show(relativeTo: anchor.bounds, of: anchor, edge: .maxY) { name in
                state?.model.updateSpaceCreationDraft { $0.icon = name }
            }
        }
        creationPage.onChooseTheme = { [weak state] anchor in state?.model.onEditSpaceCreationTheme?(anchor) }
        creationPage.onChooseProfile = { [weak state] id in
            state?.model.updateSpaceCreationDraft { $0.profileDirectory = id }
        }
        creationPage.onCreate = { [weak state] in
            state?.withSidebarAnimation { _ = state?.model.commitCreatingSpace() }
        }
        creationPage.onCancel = { [weak state] in
            state?.withSidebarAnimation { state?.model.cancelCreatingSpace() }
        }
        pagerClip.wantsLayer = true
        pagerClip.layer?.masksToBounds = true
        bottomDivider.strokeWidth = 0
        bottomDivider.fillColor = BrowserChromeColors.sidebarTopChromeDivider
        dragIndicator.isHidden = true
        dragIndicator.setAccessibilityIdentifier("browser.sidebar.drop-indicator")
        dragPreview.setAccessibilityIdentifier("browser.sidebar.drag-preview")
        dragPreview.setAccessibilityElement(false)
        dragPreview.isHidden = true
        registerForDraggedTypes([.URL, .fileURL, .string])
        miniPlayers.onHeightChange = { [weak self] in self?.needsLayout = true }
        miniPlayers.onVolumeChange = { [weak state] tabID, volume in
            state?.model.setMediaVolume(volume, tabID: tabID)
        }
        miniPlayers.onAction = { [weak state] tabID, action in
            guard let model = state?.model else { return }
            switch action {
            case .backToTab: model.selectTab(id: tabID)
            case .previousTrack: model.controlMedia(.previousTrack, tabID: tabID)
            case .nextTrack: model.controlMedia(.nextTrack, tabID: tabID)
            case .playPause:
                let playing = model.tabMediaStates[tabID]?.isPlaying == true
                model.controlMedia(playing ? .pause : .play, tabID: tabID)
            case .toggleMute: model.setTabMuted(!model.isTabMuted(id: tabID), id: tabID)
            case .close: model.dismissMiniPlayer(tabID: tabID)
            }
        }
        content.onEmptyClick = { [weak state] in state?.dismissRenamingIfNeeded() }
        content.permitsWindowDrag = { [weak state] in state?.isDraggingSidebarItem == false }
        appGrid.onEmptyClick = content.onEmptyClick
        appGrid.permitsWindowDrag = content.permitsWindowDrag
        state.onChange = { [weak self] animated in self?.refresh(animated: animated) }
        state.model.onMailPreviewChanged = { [weak self] in
            self?.refresh(animated: false)
            self?.folderPreview.refreshShown()
        }
        folderPreview.isEnabled = { [weak state] in
            guard let state else { return false }
            return !state.isDraggingSidebarItem && !state.isSidebarResizing
        }
        folderPreview.items = { [weak state] id in
            guard let state else { return [] }
            if id.hasPrefix(BrowserChromeModel.recentPagesPreviewPrefix) {
                return state.model.recentPagesPreviewItems(previewID: id)
            }
            return state.model.userPreferencesStore.folderPreviewsEnabled ? state.folderPreviewItems(folderID: id) : []
        }
        folderPreview.name = { [weak state] id in state?.snapshot.pinnedTabFolder(withID: id)?.title }
        folderPreview.onSelect = { [weak state] id in
            guard let model = state?.model else { return }
            if !model.openRecentPagePreviewItem(id: id) {
                model.selectTab(id: id)
            }
        }
        state.drag.onPresentationChange = { [weak self] in self?.updateDragPresentation() }
        state.drag.onLayoutChange = { [weak self] in self?.handleDragLayoutChange() }
        state.drag.onTargetChange = { [weak state] in
            guard state?.model.userPreferencesStore.hapticFeedbackEnabled == true else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        dragEvents.onMove = { [weak self] point in self?.updateDrag(atWindowPoint: point) }
        dragEvents.onRelease = { [weak self] point in self?.finishDragging(atWindowPoint: point) }
        dragEvents.onCancel = { [weak self] in self?.cancelDragging() }
        dragEvents.onTick = { [weak self] elapsed in
            self?.autoscrollDrag(elapsed: elapsed)
            self?.updateCopyCursor()
        }

        scrollObserver.onScrollDelta = { [weak self] delta in
            guard let self else { return }
            state.updateSpacePagerScroll(by: delta, in: state.snapshot, pageWidth: pagerClip.bounds.width)
        }
        scrollObserver.onScrollReleased = { [weak self] in
            guard let self else { return }
            state.finishSpacePagerScroll(in: state.snapshot, pageWidth: pagerClip.bounds.width)
        }
        scrollObserver.onScrollEnded = { [weak state] in state?.resetSpacePagerDrag() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if window == nil {
            folderPreview.dismiss()
            dragEvents.stop()
            landingAnimation.cancel()
            state.clearTabDragState()
            return
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]) { [weak self] event in
            guard let self, event.window === window else { return event }
            state.resignRenamingFirstResponderIfNeeded(for: event, in: self)
            return event
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with _: NSEvent) {
        if !state.isSidebarResizing {
            state.isSidebarHovered = true
            onHoverChanged(true)
        }
    }

    override func mouseExited(with _: NSEvent) {
        if !state.isSidebarResizing {
            state.isSidebarHovered = false
            state.isClearButtonHovered = false
            onHoverChanged(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        state.dismissRenamingIfNeeded()
        if !state.isDraggingSidebarItem {
            window?.performDrag(with: event)
        }
    }

    override func layout() {
        super.layout()
        layoutContent(animated: false)
        synchronizeGeometry()
        layoutFolderDropBand()
    }

    // MARK: Links dropped from pages and other apps

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        beginLinkDrop(from: sender.draggingPasteboard)
        return updateLinkDrop(at: sender.draggingLocation)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateLinkDrop(at: sender.draggingLocation)
    }

    override func draggingExited(_: NSDraggingInfo?) {
        endLinkDrop()
    }

    override func draggingEnded(_: NSDraggingInfo) {
        endLinkDrop()
    }

    override func prepareForDragOperation(_: NSDraggingInfo) -> Bool {
        linkDropProposal != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropLinks(from: sender.draggingPasteboard)
    }

    func refresh(animated: Bool = false) {
        defer {
            revealSelectedRowIfRequested()
            renameSelectedRowIfRequested()
            renameSelectedSpaceIfRequested()
        }
        let snapshot = renderedSnapshot
        miniPlayers.update(items: snapshot.miniPlayers)
        // A list of recent pages or mail isn't a folder: leaving the sidebar for it must not close it.
        if let shown = folderPreview.shownFolderID,
           !shown.hasPrefix(BrowserChromeModel.recentPagesPreviewPrefix),
           snapshot.pinnedTabFolder(withID: shown).map({ $0.isExpanded || $0.spaceID != snapshot.selectedSpaceID })
           ?? true
        {
            folderPreview.dismiss()
        }
        let selectedIndex = state.selectedSpaceIndex(in: snapshot) ?? 0
        let wantedPages = Set(snapshot.spaces
            .enumerated()
            .filter { abs($0.offset - selectedIndex) <= 2 }
            .map(\.element.id))
        for id in Set(pages.keys).subtracting(wantedPages) {
            pages.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, space) in snapshot.spaces.enumerated() where wantedPages.contains(space.id) {
            let page: BrowserNativeSidebarPage
            if let existing = pages[space.id] {
                page = existing
            } else {
                page = BrowserNativeSidebarPage(spaceID: space.id)
                page.onScroll = { [weak self] in
                    self?.synchronizeGeometry()
                    self?.layoutFolderDropBand()
                }
                page.document.onEmptyClick = { [weak state] in state?.dismissRenamingIfNeeded() }
                page.document.permitsWindowDrag = { [weak state] in state?.isDraggingSidebarItem == false }
                pages[space.id] = page
                pagesContainer.addSubview(page)
            }
            page.index = index
            configure(page: page, space: space, snapshot: snapshot)
        }
        let appTabs = state.model.supportsAppTabs ? snapshot.appTabs : []
        for id in Set(appTiles.keys)
            .subtracting(appTabs.map(\.id))
        {
            appTiles.removeValue(forKey: id)?.removeAnimated()
        }
        for tab in appTabs {
            let tile = appTiles[tab.id] ?? BrowserNativeSidebarRowNSView()
            if appTiles[tab.id] == nil {
                appTiles[tab.id] = tile
                appGrid.addSubview(tile)
                if hasRenderedAppTiles {
                    tile.animateInsertion()
                }
            }
            configure(row: tile, tab: tab, section: .app, indent: 0)
        }
        hasRenderedAppTiles = true
        let draft = state.model.spaceCreationDraft
        scrollObserver.isEnabled = !snapshot.spaces.isEmpty && !state.isSidebarResizing
            && state.model.librarySection == nil
            && !state.isDraggingSidebarItem && draft == nil
        let wasCreating = !creationPage.isHidden
        if let draft {
            creationPage.update(draft: draft)
            creationPage.updateProfiles(
                state.model.profileDirectories?.profiles() ?? [],
                selected: draft.profileDirectory ?? state.model.profileDirectories?.windowProfile,
            )
            creationPage.isHidden = false
            state.spacePagerCurve = .spaceSelect
            if !wasCreating {
                DispatchQueue.main.async { [weak creationPage] in creationPage?.focusName() }
            }
        }
        bottomDivider.alphaValue = state.isBottomChromeDividerVisible(in: snapshot) ? 1 : 0
        layoutContent(animated: animated)
        synchronizeGeometry()
        updateDragPresentation()
    }

    func makeDragGeometry() -> BrowserSidebarDragGeometry? {
        state.drag.payload.flatMap { makeDragGeometry(payload: $0) }
    }

    func makeDragGeometry(payload: BrowserSidebarDragPayload) -> BrowserSidebarDragGeometry? {
        guard let id = state.snapshot.selectedSpaceID, let page = pages[id] else { return nil }
        let tree = BrowserSidebarTabTree(snapshot: state.snapshot)
        var rows = [BrowserSidebarDragRowGeometry]()
        for entry in page.entries {
            guard let frame = page.frames[entry.id] else { continue }
            let item: BrowserSidebarItemID
            let depth: Int
            switch entry {
            case .tab(let tab, _, _, _, _, let indent): item = .tab(tab.id)
                depth = indent
            case .folder(let folder): item = .folder(folder.folder.id)
                depth = folder.depth
            default: continue
            }
            guard let container = tree.container(of: item) else { continue }
            var rect = page.document.convert(frame, to: content)
            let indent = CGFloat(depth) * BrowserChromeLayout.sidebarPinnedFolderTabIndent
            rect.origin.x += indent
            rect.size.width = max(rect.width - indent, 0)
            rows.append(.init(item: item, container: container, frame: rect))
        }
        let viewport = page.scroll
            .contentView
            .convert(page.scroll.contentView.bounds, to: content)
            .intersection(content.bounds)
        var geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: payload,
            rows: rows,
            listViewport: viewport,
            spaceHeader: page.header.isHidden
                ? nil
                : (id, page.header.convert(page.header.bounds, to: content)),
            appFrame: state.model.supportsAppTabs && !appGrid.isHidden
                ? appGrid.frame
                : nil,
            rowWidth: content.bounds.width,
            appEntryFrame: emptyAppEntryFrame,
        )
        if let newTab = page.frames["new-tab"] {
            let frame = page.document.convert(newTab, to: content)
            let spacing = BrowserChromeLayout.sidebarListSpacing
            if state.snapshot.visiblePinnedRows(in: id, revealedTabIDsByFolderID: [:]).isEmpty {
                geometry.addEmptySection(
                    .pinned(id),
                    frame: CGRect(x: frame.minX, y: frame.minY - spacing, width: frame.width, height: spacing),
                )
            }
            if state.snapshot.temporaryTabs(in: id).isEmpty {
                geometry.addEmptySection(
                    .temporary(id),
                    frame: CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: spacing),
                )
            }
        }
        return geometry
    }

    @discardableResult func beginDragging(
        item: BrowserSidebarItemID,
        from row: NSView,
        value: BrowserNativeDragValue,
    ) -> Bool {
        guard !state.isSidebarResizing else { return false }
        var source = row.convert(row.bounds, to: content)
        if let row = row as? BrowserNativeSidebarRowNSView {
            source.origin.x += row.contentIndent
            source.size.width -= row.contentIndent
        }
        return beginDragging(item: item, sourceFrame: source, value: value)
    }

    @discardableResult func beginDragging(
        item: BrowserSidebarItemID,
        sourceFrame: CGRect,
        value: BrowserNativeDragValue,
    ) -> Bool {
        folderPreview.dismiss()
        landingAnimation.cancel()
        dragEvents.stop()
        state.clearTabDragState()
        // Only the tab on screen has a drawn page to picture; another one shows
        // as a card with its icon and title, even once the drag selects it.
        let hadPage: Bool =
            if case .tab(let id) = item {
                state.model.selectedTabID == id
            } else {
                false
            }
        activateSingleDraggedTab(item)
        if hadPage {
            captureDraggedPageThumbnail(item)
        } else {
            draggedPageThumbnail = nil
            draggedPageThumbnailTabID = nil
        }
        state.update(snapshot: state.model.sidebarSnapshot, sidebarWidth: state.sidebarWidth, isResizing: false)
        let tree = BrowserSidebarTabTree(snapshot: state.snapshot)
        let ids: Set<String>
        switch item {
        case .tab(let id):
            guard state.snapshot.containsTab(withID: id) else { return false }
            if state.selectedSidebarTabIDs.contains(id) {
                ids = state.selectedSidebarTabIDs
            } else {
                state.clearSidebarTabSelection()
                // A Split View row carries every pane, so the split moves as one group.
                ids = Set(state.snapshot.splitMembers(ofTabID: id) ?? [id])
            }
        case .folder(let id):
            guard let folder = tree.folders[id] else { return false }
            ids = Set(tree.tabIDs(in: .pinned(folder.spaceID, folderID: id)))
            state.clearSidebarTabSelection()
        }
        state.dismissRenamingIfNeeded(in: window)
        state.drag.begin(
            payload: .init(primary: item, tabIDs: ids),
            sourceFrame: sourceFrame,
            start: value.startLocation,
            pointer: value.location,
            grabAnchor: value.grabAnchor,
        )
        frameTransitions.finishAll()
        for page in pages.values {
            page.finishRowAnimations()
        }
        dragPreviewTargetSize = nil
        reservedAppHeight = 0
        isProjectingAppGrid = false
        refresh()
        lastWindowDragPoint = content.convert(value.location, to: nil)
        dragEvents.start(in: window)
        dragPreview.dragCoordinateView = content
        return true
    }

    func updateDrag(atWindowPoint point: CGPoint) {
        guard state.drag.isDragging else { return }
        lastWindowDragPoint = point
        updateOtherWindowDrop(atWindowPoint: point)
        state.drag.updateDockTarget(spaceDock?.spaceID(atWindowPoint: point))
        state.drag.updateEdgeTarget(spaceEdgeDirection(atWindowPoint: point))
        state.drag.updatePointer(content.convert(point, from: nil))
        showPageUnderDrag(atWindowPoint: point)
        state.drag.updatePageDrop(atWindowPoint: point)
        if state.model.appTabs.isEmpty {
            needsLayout = true
        }
    }

    /// The side margins beside the tab list, outside the rows: the left one leads
    /// to the Space before the selected one, the right one to the Space after it.
    func spaceEdgeDirection(atWindowPoint point: CGPoint) -> Int? {
        guard state.snapshot.spaces.count > 1 else { return nil }
        let local = convert(point, from: nil)
        let list = convert(pagerClip.frame, from: content)
        guard local.y >= list.minY, local.y <= list.maxY else { return nil }
        if local.x >= bounds.minX, local.x < content.frame.minX {
            return -1
        }
        if local.x <= bounds.maxX, local.x > content.frame.maxX {
            return 1
        }
        return nil
    }

    func finishDragging(atWindowPoint point: CGPoint) {
        guard state.drag.isDragging else { return }
        if let payload = state.drag.payload, case .tab = payload.primary, let window {
            let screenPoint = window.convertPoint(toScreen: point)
            if let target = otherWindowSidebar(atWindowPoint: point) {
                otherWindowDropTarget = nil
                target.updateTabDrop(at: target.window.map { $0.convertPoint(fromScreen: screenPoint) })
                endDragging(at: state.drag.pointer, cancelled: true)
                completeDragPresentation()
                dragPreview.isHidden = true
                // Dropped in another window's sidebar: the tabs land at its line.
                if target.dropTabs(ids: payload.tabIDs, fromWindowOf: state.model) {
                    target.window?.makeKeyAndOrderFront(nil)
                }
                return
            }
            if !window.frame.contains(screenPoint),
               NSScreen.screens.contains(where: { $0.frame.contains(screenPoint) })
            {
                let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
                let target = NSApp.window(withWindowNumber: number)
                endDragging(at: state.drag.pointer, cancelled: true)
                completeDragPresentation()
                dragPreview.isHidden = true
                if let target {
                    // Dropped on another window of this app: it takes the tabs.
                    _ = state.model.onMoveTabsToWindow?(payload.tabIDs, target)
                } else {
                    // Dropped outside every window: the tabs go to a new window of their own.
                    state.model.moveTabsToNewWindow(ids: payload.tabIDs, at: screenPoint)
                }
                return
            }
        }
        state.drag.updateDockTarget(spaceDock?.spaceID(atWindowPoint: point))
        state.drag.updatePageDrop(atWindowPoint: point)
        endDragging(at: content.convert(point, from: nil), cancelled: false)
    }

    /// The line a tab dragged in from another window's sidebar would take; nil ends it.
    @discardableResult func updateTabDrop(at windowPoint: CGPoint?) -> Bool {
        guard let windowPoint else {
            endLinkDrop()
            return false
        }
        acceptsLinkDrop = true
        return updateLinkDrop(at: windowPoint) != []
    }

    /// Tabs from another window's sidebar land at the line.
    @discardableResult func dropTabs(ids: Set<String>, fromWindowOf source: BrowserChromeModel) -> Bool {
        let destination = linkDropProposal?.destination
        endLinkDrop()
        guard let destination else { return false }
        return state.withSidebarAnimation { state.model.acceptTabs(ids: ids, fromWindowOf: source, at: destination) }
    }

    func cancelDragging() {
        otherWindowDropTarget?.updateTabDrop(at: nil)
        otherWindowDropTarget = nil
        guard state.drag.phase != .idle else { return }
        if state.drag.phase == .settling {
            completeDragPresentation()
            return
        }
        endDragging(at: state.drag.pointer, cancelled: true)
    }

    func restingFrame(for item: BrowserSidebarItemID) -> CGRect? {
        if case .tab(let id) = item, let index = state.snapshot.appTabs.firstIndex(where: { $0.id == id }) {
            let frames = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
                .frames(for: state.snapshot.appTabs.count, availableWidth: content.bounds.width)
            if frames.indices.contains(index) {
                return frames[index].offsetBy(
                    dx: appGrid.frame.minX,
                    dy: appGrid.frame.minY,
                )
            }
        }
        guard let spaceID = state.snapshot.selectedSpaceID, let page = pages[spaceID] else { return nil }
        let key = itemKey(item)
        if let frame = page.frames[key], let row = page.rows[key] {
            var result = page.document.convert(frame, to: content)
            let targetPager = frameTransitions.targetFrame(of: pagerClip)
            let targetPages = frameTransitions.targetFrame(of: pagesContainer)
            result.origin.x += targetPager.minX - pagerClip.frame.minX + targetPages.minX - pagesContainer.frame.minX
            result.origin.y += targetPager.minY - pagerClip.frame.minY
            result.origin.x += row.contentIndent
            result.size.width -= row.contentIndent
            var viewport = page.scroll.contentView.convert(page.scroll.contentView.bounds, to: content)
            viewport.origin.y += targetPager.minY - pagerClip.frame.minY
            viewport.size.height += targetPager.height - pagerClip.frame.height
            return viewport.intersects(result) ? result : nil
        }
        if case .tab(let id) = item, let tab = state.snapshot.tab(withID: id), let folderID = tab.pinnedFolderID {
            return restingFrame(for: .folder(folderID))
        }
        if case .folder(let id) = item, let parent = state.snapshot.pinnedTabFolder(withID: id)?.parentFolderID {
            return restingFrame(for: .folder(parent))
        }
        if state.snapshot.isPinnedSectionCollapsed(in: spaceID) {
            return page.header.convert(page.header.bounds, to: content)
        }
        return nil
    }

    func autoscrollDrag(elapsed: TimeInterval) {
        guard state.drag.isDragging, let id = state.snapshot.selectedSpaceID, let page = pages[id] else { return }
        let point = content.convert(lastWindowDragPoint, from: nil)
        if point != state.drag.pointer {
            state.drag.updatePointer(point)
        }
        let viewport = page.scroll.contentView.convert(page.scroll.contentView.bounds, to: content)
        guard point.x >= viewport.minX, point.x <= viewport.maxX,
              point.y >= viewport.minY - 8, point.y <= viewport.maxY + 8 else { return }
        let edge = min(32.0, viewport.height / 4)
        let speed: CGFloat
        if point.y < viewport.minY + edge {
            speed = -min((viewport.minY + edge - point.y) / edge, 1) * 480
        } else if point.y > viewport.maxY - edge {
            speed = min((point.y - viewport.maxY + edge) / edge, 1) * 480
        } else {
            return
        }
        let clip = page.scroll.contentView
        let y = min(
            max(clip.bounds.minY + speed * elapsed, 0),
            max(page.document.bounds.height - clip.bounds.height, 0),
        )
        guard y != clip.bounds.minY else { return }
        clip.scroll(to: CGPoint(x: 0, y: y))
        page.scroll.reflectScrolledClipView(clip)
        synchronizeGeometry()
    }

    func beginLinkDrop(from pasteboard: NSPasteboard) {
        acceptsLinkDrop = !BrowserSidebarLinkDrop.urls(from: pasteboard).isEmpty
    }

    /// A link dropped on the sidebar opens as a background tab at the
    /// insertion line, pinned in a pinned section or folder.
    @discardableResult func dropLinks(from pasteboard: NSPasteboard) -> Bool {
        let urls = BrowserSidebarLinkDrop.urls(from: pasteboard)
        let destination = linkDropProposal?.destination
        endLinkDrop()
        guard let destination, !urls.isEmpty else { return false }
        return state.withSidebarAnimation { state.model.openURLs(urls, at: destination) }
    }

    /// The insertion a link dropped at a window point would take, as for a
    /// dragged tab; Favorites take no links.
    @discardableResult func updateLinkDrop(at windowPoint: CGPoint) -> NSDragOperation {
        guard acceptsLinkDrop, !state.drag.isDragging, !state.isSidebarResizing, state.model.canCreateTab,
              let geometry = makeDragGeometry(payload: .init(primary: .tab(""), tabIDs: []))
        else {
            endLinkDrop()
            return []
        }
        let proposal = geometry.proposal(at: content.convert(windowPoint, from: nil), previous: linkDropProposal)
        let next = proposal?.destination.container.section == .app ? nil : proposal
        if next != linkDropProposal {
            linkDropProposal = next
            updateDragPresentation()
        }
        return next == nil ? [] : .copy
    }

    /// Starts the slide to a Space before the model does the work of switching to it.
    /// Returns how long the motion waits, a moment after a click or a swipe's release.
    @discardableResult func slidePager(toSpaceID spaceID: String) -> CFTimeInterval {
        guard let index = state.snapshot.spaces.firstIndex(where: { $0.id == spaceID }), window != nil else { return 0 }
        state.pagerTargetSpaceID = spaceID
        var rect = pagesContainer.frame
        rect.origin.x = state.spacePagerOffset(selectedIndex: index, pageWidth: pagerClip.bounds.width)
        let delay = state.hasSpacePagerReleaseVelocity ? Self.swipeReleaseDelay : Self.spaceSelectionDelay
        setFrame(rect, of: pagesContainer, animated: true, delay: delay)
        return delay
    }

    /// A tab dragged from this sidebar over another window's sidebar: that window
    /// comes forward and shows where the tab would land.
    private func updateOtherWindowDrop(atWindowPoint point: CGPoint) {
        let target = otherWindowSidebar(atWindowPoint: point)
        if target !== otherWindowDropTarget {
            otherWindowDropTarget?.updateTabDrop(at: nil)
            otherWindowDropTarget = target
            target?.window?.orderFront(nil)
        }
        guard let target, let other = target.window, let window else { return }
        target.updateTabDrop(at: other.convertPoint(fromScreen: window.convertPoint(toScreen: point)))
    }

    private func otherWindowSidebar(atWindowPoint point: CGPoint) -> BrowserNativeSidebarNSView? {
        guard let window, case .tab? = state.drag.payload?.primary, state.model.windowMode != .incognito else {
            return nil
        }
        let screenPoint = window.convertPoint(toScreen: point)
        guard !window.frame.contains(screenPoint) else { return nil }
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return Self.sidebars.allObjects.first { sidebar in
            guard sidebar !== self, let other = sidebar.window, other.windowNumber == number,
                  !sidebar.isHiddenOrHasHiddenAncestor
            else { return false }
            return other.convertToScreen(sidebar.convert(sidebar.visibleRect, to: nil)).contains(screenPoint)
        }
    }

    /// A single dragged tab activates when the gesture starts; the tab stays
    /// active even if the drop is a no-op. Explicit multi-selections and
    /// folders keep the current tab.
    /// A tab from another Space is never activated, so a drag cannot switch Spaces.
    private func activateSingleDraggedTab(_ item: BrowserSidebarItemID) {
        tabSelectedBeforeDrag = nil
        guard case .tab(let id) = item, !state.selectedSidebarTabIDs.contains(id),
              state.model.selectedTabID != id,
              state.snapshot.splitMembers(ofTabID: id)?.contains(state.model.selectedTabID ?? "") != true,
              let tab = state.model.tabs.first(where: { $0.id == id }),
              tab.placement == .app || tab.spaceID == state.model.selectedSpaceID
        else { return }
        state.clearSidebarTabSelection()
        state.sidebarTabSelectionAnchorID = id
        tabSelectedBeforeDrag = state.model.selectedTabID
        state.model.selectTab(id: id)
    }

    /// Takes a picture of a single dragged tab's page once it is on screen.
    private func captureDraggedPageThumbnail(_ item: BrowserSidebarItemID) {
        draggedPageThumbnail = nil
        draggedPageThumbnailTabID = nil
        guard case .tab(let id) = item, state.model.selectedTabID == id else { return }
        draggedPageThumbnailTabID = id
        let scale = window?.backingScaleFactor ?? 2
        // The page of a tab the drag just selected needs a moment to draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, draggedPageThumbnailTabID == id, state.drag.isDragging else { return }
            state.model.captureSelectedPageThumbnail(
                maximumPixelSize: BrowserDragOutsidePreview.thumbnailWidth * scale,
            ) { [weak self] image in
                guard let self, draggedPageThumbnailTabID == id, let image else { return }
                draggedPageThumbnail = image
            }
        }
    }

    /// A single dragged tab shows its page while the pointer is over the
    /// sidebar. Past the sidebar the page shown before comes back, so the drop
    /// can open the dragged tab in a split with it.
    private func showPageUnderDrag(atWindowPoint point: CGPoint) {
        guard let previous = tabSelectedBeforeDrag, let payload = state.drag.payload,
              payload.tabIDs.count == 1, case .tab(let id) = payload.primary
        else { return }
        let wanted = convert(visibleRect, to: nil).contains(point) ? id : previous
        guard state.model.selectedTabID != wanted, state.model.tabs.contains(where: { $0.id == wanted }) else { return }
        state.model.selectTab(id: wanted)
    }

    /// The list moves under a still pointer when Favorites change. Runs once rows stop moving.
    private func scheduleStaleRowHoverCheck() {
        staleRowHoverCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, let id = state.snapshot.selectedSpaceID else { return }
            pages[id]?.rows.values.forEach { $0.endHoverIfPointerLeft() }
        }
        staleRowHoverCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: check)
    }

    private func layoutContent(animated: Bool) {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let inset = BrowserChromeLayout.sidebarOuterPadding
        content.frame = NSRect(
            x: inset,
            y: inset,
            width: max(bounds.width - inset * 2, 0),
            height: max(bounds.height - inset * 2, 0),
        )
        let width = max(content.bounds.width, 0)
        if let headerHeightProvider {
            headerHeight = headerHeightProvider()
        }
        if let footerHeightProvider {
            footerHeight = footerHeightProvider(width)
        }

        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        let appTabs = renderedSnapshot.appTabs
        let showsApps = state.model.spaceCreationDraft == nil && state.model
            .supportsAppTabs && (!appTabs.isEmpty || (state.drag.isDragging && reservedAppHeight > 0))
        let offersEmptyAppDrop = state.model.supportsAppTabs && state.model.appTabs.isEmpty && state.drag.isDragging
            && state.draggedTabID != nil && state.draggedTabIDs.count == 1
        // The list stays put until the tab is carried up to where the guide appears.
        let showsEmptyAppGuide = offersEmptyAppDrop && state.drag.pointer.y < header.frame.maxY
            + BrowserChromeLayout.sidebarListTopSpacing + BrowserChromeLayout.sidebarEmptySectionDropZoneHeight
        emptyAppGuide.frame = CGRect(
            x: 0,
            y: header.frame.maxY + BrowserChromeLayout.sidebarListTopSpacing,
            width: width,
            height: showsEmptyAppGuide ? BrowserChromeLayout.sidebarEmptySectionDropZoneHeight : 0,
        )
        emptyAppGuideLabel.frame = emptyAppGuide.bounds.insetClamped(
            dx: 8,
            dy: (emptyAppGuide.bounds.height - 16) / 2,
        )
        emptyAppEntryFrame = offersEmptyAppDrop
            ? CGRect(
                x: 0,
                y: header.frame.maxY,
                width: width,
                height: BrowserChromeLayout.sidebarListTopSpacing + BrowserChromeLayout
                    .sidebarEmptySectionDropZoneHeight,
            )
            : nil
        emptyAppGuide.isHidden = !showsEmptyAppGuide || showsApps
        let appLayout = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
        var appHeight = showsApps
            ? max(
                appLayout.height(for: appTabs.count, availableWidth: width),
                BrowserChromeLayout.sidebarEmptySectionDropZoneHeight,
            )
            : 0
        if state.drag.isDragging {
            reservedAppHeight = max(reservedAppHeight, appHeight)
            appHeight = reservedAppHeight
        } else {
            reservedAppHeight = 0
        }
        appGrid.isHidden = !showsApps
        let appFrame = NSRect(
            x: 0,
            y: header.frame.maxY + BrowserChromeLayout.sidebarListTopSpacing,
            width: width,
            height: appHeight,
        )
        setFrame(appFrame, of: appGrid, animated: animated)
        scheduleStaleRowHoverCheck()
        let appFrames = appLayout.frames(for: appTabs.count, availableWidth: width)
        for (index, tab) in appTabs.enumerated() where appFrames.indices.contains(index) {
            if let tile = appTiles[tab.id] {
                setFrame(appFrames[index], of: tile, animated: animated)
            }
        }
        let aboveList = showsApps ? appFrame.maxY : showsEmptyAppGuide ? emptyAppGuide.frame.maxY : header.frame.maxY
        let top = aboveList + BrowserChromeLayout.sidebarListTopSpacing
        footer.frame = NSRect(
            x: 0,
            y: max(content.bounds.height - footerHeight, top),
            width: width,
            height: footerHeight,
        )
        if downloadsTray.superview != nil {
            placeDownloadsTray()
        }
        // Mini players sit above the dock; the list keeps room for their
        // collapsed rows, and a player growing on hover covers its bottom.
        let playersBottom = footer.frame.minY - BrowserChromeLayout.sidebarBottomChromeTopSpacing
        let reservedPlayers = miniPlayers.reservedHeight
        miniPlayers.frame = NSRect(
            x: 0,
            y: playersBottom - miniPlayers.currentHeight,
            width: width,
            height: miniPlayers.currentHeight,
        )
        let listBottom = reservedPlayers > 0 ? playersBottom - reservedPlayers : footer.frame.minY
        bottomDivider.frame = NSRect(
            x: 0,
            y: listBottom - BrowserChromeLayout.sidebarBottomChromeTopSpacing - 1,
            width: width,
            height: 1,
        )
        // Spaces slide across the outer padding, so a swipe is clipped only by
        // the window edge and the browser content. Pages sit one sidebar width
        // apart, keeping neighbors out of the padding at rest.
        let pageStride = width + inset * 2
        setFrame(
            NSRect(x: -inset, y: top, width: pageStride, height: max(bottomDivider.frame.minY - top, 0)),
            of: pagerClip,
            animated: animated,
        )
        scrollObserver.frame = pagerClip.frame
        if state.pagerTargetSpaceID == state.snapshot.selectedSpaceID {
            state.pagerTargetSpaceID = nil
        }
        let selectedIndex = state.pagerTargetSpaceID.flatMap { id in
            state.snapshot.spaces.firstIndex { $0.id == id }
        } ?? state.selectedSpaceIndex(in: state.snapshot) ?? 0
        let isCreatingSpace = state.model.spaceCreationDraft != nil
        // The Space being created is a page after the last one.
        let index = isCreatingSpace ? state.snapshot.spaces.count : selectedIndex
        let x = state.spacePagerOffset(selectedIndex: index, pageWidth: pageStride)
        setFrame(
            NSRect(
                x: x,
                y: 0,
                width: pageStride * CGFloat(state.snapshot.spaces.count + 1),
                height: pagerClip.bounds.height,
            ),
            of: pagesContainer,
            animated: animated,
        )
        creationPage.frame = NSRect(
            x: leavingPageX[ObjectIdentifier(creationPage)] ?? CGFloat(state.snapshot.spaces.count) * pageStride +
                inset,
            y: 0,
            width: width,
            height: pagerClip.bounds.height,
        )
        if !isCreatingSpace, !creationPage.isHidden, !frameTransitionsAreRunning {
            creationPage.isHidden = true
        }
        reportSpacePagerProgress(selectedIndex: selectedIndex, pageStride: pageStride)
        for page in pages.values {
            page.frame = NSRect(
                x: leavingPageX[ObjectIdentifier(page)] ?? CGFloat(page.index) * pageStride + inset,
                y: 0,
                width: width,
                height: pagerClip.bounds.height,
            )
            page.layoutRows(animated: animated, curve: state.rowMoveCurve)
        }
    }

    /// Tells the window how far a swipe has gone toward the neighboring Space,
    /// so the theme follows the finger.
    private func reportSpacePagerProgress(selectedIndex: Int, pageStride: CGFloat) {
        let translation = state.isSpacePagerDragging ? state.spacePagerDragTranslation : 0
        let neighbor = selectedIndex + (translation > 0 ? -1 : 1)
        guard translation != 0, pageStride > 0, state.snapshot.spaces.indices.contains(neighbor) else {
            onSpacePagerProgress(nil, 0)
            return
        }
        onSpacePagerProgress(state.snapshot.spaces[neighbor].id, min(abs(translation) / pageStride, 1))
    }

    /// A view whose frame lies outside the clip stops drawing its text, and a slide's frame is
    /// final before anything has moved. So a leaving page stays inside the clip, shown at its
    /// place in the row by a fixed offset, until the slide ends.
    private func keepLeavingPagesDrawn(endingAt origin: CGPoint) {
        let clip = pagerClip.bounds
        let inside = BrowserChromeLayout.sidebarOuterPadding - origin.x
        for page in Array(pages.values) + [creationPage] {
            let id = ObjectIdentifier(page)
            let natural = pagerX(of: page)
            let width = page.frame.width
            let staysVisible = NSRect(x: natural + origin.x, y: 0, width: width, height: 1).intersects(clip)
            let isVisible = NSRect(x: natural + pagesContainer.frame.minX, y: 0, width: width, height: 1)
                .intersects(clip)
            if staysVisible {
                if leavingPageX.removeValue(forKey: id) != nil {
                    page.layer?.removeAnimation(forKey: Self.leavingPageKey)
                    page.frame.origin.x = natural
                    (page as? BrowserNativeSidebarPage)?.isLeaving = false
                }
            } else if !page.isHidden, isVisible || leavingPageX[id] != nil {
                leavingPageX[id] = inside
                page.frame.origin.x = inside
                (page as? BrowserNativeSidebarPage)?.isLeaving = true
                let offset = CABasicAnimation(keyPath: "position")
                offset.isAdditive = true
                offset.fromValue = NSValue(point: CGPoint(x: natural - inside, y: 0))
                offset.toValue = offset.fromValue
                offset.duration = 60
                page.layer?.add(offset, forKey: Self.leavingPageKey)
            }
        }
    }

    private func endLeavingPages() {
        for page in Array(pages.values) + [creationPage] where leavingPageX[ObjectIdentifier(page)] != nil {
            page.layer?.removeAnimation(forKey: Self.leavingPageKey)
            (page as? BrowserNativeSidebarPage)?.isLeaving = false
        }
        leavingPageX.removeAll()
    }

    /// Where a page sits in the row of pages.
    private func pagerX(of page: NSView) -> CGFloat {
        let index = (page as? BrowserNativeSidebarPage)?.index ?? state.snapshot.spaces.count
        return CGFloat(index) * pagerClip.bounds.width + BrowserChromeLayout.sidebarOuterPadding
    }

    private func setFrame(_ rect: NSRect, of view: NSView, animated: Bool, delay: CFTimeInterval = 0) {
        guard view === pagesContainer else {
            frameTransitions.setFrame(rect, of: view, animated: animated, curve: state.rowMoveCurve)
            return
        }
        // The tab switch that comes with a Space stalls the main thread.
        let curve = state.spacePagerCurve
        var initialVelocity: CGFloat = 0
        var start = delay
        if animated, view.frame.origin != rect.origin {
            let velocity = state.takeSpacePagerReleaseVelocity()
            initialVelocity = velocity / (rect.minX - view.frame.minX)
            if velocity != 0 {
                start = Self.swipeReleaseDelay
            }
            keepLeavingPagesDrawn(endingAt: rect.origin)
            let end = CACurrentMediaTime() + start + curve.duration
            pagerSlideEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + start + curve.duration) { [weak self] in
                guard let self else { return }
                needsLayout = true
                if pagerSlideEnd == end {
                    endLeavingPages()
                }
            }
        }
        frameTransitions.slide(
            view,
            to: rect,
            animated: animated,
            curve: curve,
            initialVelocity: initialVelocity,
            delay: start,
        )
    }

    private func configure(
        page: BrowserNativeSidebarPage,
        space: BrowserChromeModel.Space,
        snapshot: BrowserSidebarSnapshot,
    ) {
        let state = state
        let model = state.model
        // A page keeps its own Space's colors while it slides in.
        let palette = model.spaceThemesByID[space.id]?.palette
        page.spaceThemePalette = palette
        let pageAppearance = palette.flatMap { NSAppearance(named: $0.isLightContent ? .aqua : .darkAqua) }
            ?? window?.effectiveAppearance
        if page.appearance?.name != pageAppearance?.name {
            page.appearance = pageAppearance
        }
        page.document.menuProvider = { [weak self] in self?.spaceMenu(space) ?? NSMenu() }
        page.header.isHidden = !model.supportsSpaces
        page.header.update(
            space: space,
            renaming: state.renamingSpaceID == space.id,
            collapsed: snapshot.isPinnedSectionCollapsed(in: space.id),
            hasPinnedTabs: !snapshot.visiblePinnedRows(in: space.id, revealedTabIDsByFolderID: [:]).isEmpty,
            dropTargeted: state.isSpaceHeaderDropTarget(spaceID: space.id),
            isResizing: state.isSidebarResizing,
            resetID: state.tabRowInteractionResetID,
        )
        page.header.onToggle = { [weak state] in
            state?.dismissRenamingIfNeeded()
            state?.withSidebarAnimation { model.toggleActiveSpacePinnedSectionCollapsed() }
        }
        page.header.onBeginRename = { [weak state] in state?.beginRenamingSpace(id: space.id) }
        page.header.onCommitRename = { [weak state] title in model.setTitle(title, forSpaceID: space.id)
            state?.renamingSpaceID = nil
        }
        page.header.onCancelRename = { [weak state] in state?.renamingSpaceID = nil }
        page.header.menuProvider = page.document.menuProvider
        page.header.onDragChanged = { [weak self] value in
            guard let self else { return }
            state.updateSpacePagerDrag(value, in: state.snapshot, pageWidth: pagerClip.bounds.width)
        }
        page.header.onDragEnded = { [weak self] value in
            guard let self else { return }
            state.finishSpacePagerDrag(value, in: state.snapshot, pageWidth: pagerClip.bounds.width)
        }

        let temporary = snapshot.temporaryTabs(in: space.id)
        let pinnedRows = snapshot.visiblePinnedRows(
            in: space.id,
            revealedTabIDsByFolderID: state.revealedPinnedFolderTabIDsByFolderID,
        )
        var entries = [BrowserNativeSidebarPage.Entry]()
        // A Split View is one row in place of its first member; the other
        // members have no row of their own.
        var renderedSplits = Set<[String]>()
        func showsRow(for tab: BrowserChromeModel.Tab) -> Bool {
            guard let members = snapshot.splitMembers(ofTabID: tab.id) else { return true }
            return renderedSplits.insert(members).inserted
        }
        let collapsed = model.supportsSpaces && snapshot.isPinnedSectionCollapsed(in: space.id)
        if !collapsed {
            for row in pinnedRows {
                switch row {
                case .tab(let tabRow):
                    guard showsRow(for: tabRow.tab) else { continue }
                    entries.append(.tab(
                        tabRow.tab,
                        section: .spacePinned,
                        index: tabRow.sectionIndex,
                        folderID: tabRow.pinnedFolderID,
                        folderChildIndex: tabRow.folderChildIndex,
                        indent: tabRow.depth,
                    ))
                case .folder(let folder): entries.append(.folder(folder))
                }
            }
        }
        if !pinnedRows.isEmpty {
            entries.append(.divider)
        }
        if model.windowMode.isSpaceless {
            entries.append(.incognito)
        }
        entries.append(.newTab)
        entries += temporary.enumerated().filter { showsRow(for: $0.element) }.map { .tab(
            $0.element,
            section: .temporary,
            index: $0.offset,
            folderID: nil,
            folderChildIndex: nil,
            indent: 0,
        ) }
        page.entries = entries
        let ids = Set(entries.map(\.id))
        // Collapsing the Space folds its pinned rows up under the header.
        let foldedIDs: Set<String> = collapsed
            ? Set(pinnedRows.map { row in
                switch row {
                case .tab(let tabRow): "tab:\(tabRow.tab.id)"
                case .folder(let folderRow): "folder:\(folderRow.folder.id)"
                }
            })
            : []
        for id in Set(page.rows.keys).subtracting(ids) {
            guard let row = page.rows.removeValue(forKey: id) else { continue }
            if foldedIDs.contains(id) {
                row.removeAnimated(rising: row.frame.maxY)
            } else {
                row.removeAnimated()
            }
        }
        for entry in entries {
            switch entry {
            case .tab(let tab, let section, _, _, _, let indent):
                let row = page.row(for: entry.id)
                configure(row: row, tab: tab, section: section, indent: indent)
            case .folder(let folderRow):
                let row = page.row(for: entry.id)
                let folder = folderRow.folder
                row.update(
                    folder: folder,
                    showsOpenTabs: folderRow.showsOpenTabs,
                    renaming: state.renamingPinnedTabFolderID == folder.id,
                    indentLevel: folderRow.depth,
                    dropTargeted: state.isPinnedFolderDropTarget(folderID: folder.id),
                    isResizing: state.isSidebarResizing,
                    resetID: state.tabRowInteractionResetID,
                )
                row.dragOpacity = state.drag.hiddenFolderIDs.contains(folder.id) ? 0 : 1
                row.onHoverChanged = { [weak self, weak row] hovered in
                    guard let self, let row else { return }
                    folderPreview.rowHoverChanged(folderID: folder.id, row: row, hovered: hovered && !folder.isExpanded)
                }
                row.onToggle = { [weak self, weak state] in
                    guard let state else { return }
                    self?.folderPreview.dismiss()
                    state.dismissRenamingIfNeeded()
                    state.animateRows(with: folder.isExpanded ? .folderCollapse : .standard)
                    state.withSidebarAnimation {
                        if folder.isExpanded {
                            state.revealedPinnedFolderTabIDsByFolderID[folder.id] = nil
                        }
                        model.togglePinnedTabFolderExpanded(id: folder.id)
                    }
                }
                row.onBeginRename = { [weak state] in state?.beginRenamingPinnedTabFolder(id: folder.id) }
                row.onCommitRename = { [weak state] title in model.setTitle(title, forPinnedTabFolderID: folder.id)
                    state?.renamingPinnedTabFolderID = nil
                }
                row.onCancelRename = { [weak state] in state?.renamingPinnedTabFolderID = nil }
                row.menuProvider = { [weak row, weak state] in BrowserNativeMenus.folder(
                    folder,
                    onRename: { row?.onBeginRename() },
                    onChangeIcon: { model.setIcon($0, forPinnedTabFolderID: folder.id) },
                    onNewNested: { [weak state] in
                        state?.withSidebarAnimation {
                            if let id = model.createNestedFolder(inFolderID: folder.id) {
                                state?.beginRenamingPinnedTabFolder(id: id)
                            }
                        }
                    },
                    onTurnIntoSpace: model.supportsSpaces
                        ? { [weak state] in
                            state?.withSidebarAnimation { _ = model.turnFolderIntoSpace(id: folder.id) }
                        }
                        : nil,
                    onCopyAllLinks: { _ = model.copyAllLinks(inFolderID: folder.id) },
                    onShare: model.onShareFolder.map { share in { share(folder.id) } },
                    onDuplicate: { [weak state] in
                        state?.withSidebarAnimation { _ = model.duplicateFolder(id: folder.id) }
                    },
                    moveTargets: model.spacesForMovingFolder(id: folder.id),
                    onMove: { [weak state] spaceID in
                        state?.withSidebarAnimation { model.moveFolder(id: folder.id, toSpaceID: spaceID) }
                    },
                    onDelete: { [weak state] in
                        state?.withSidebarAnimation { _ = model.deletePinnedTabFolder(id: folder.id) }
                    },
                ) }
                row.dragCoordinateView = content
                row.onBeginDragSession = { [weak self, weak row] value in
                    guard let self, let row else { return false }
                    return beginDragging(item: .folder(folder.id), from: row, value: value)
                }
            case .newTab:
                let row = page.row(for: entry.id)
                row.updateNewTab(
                    isPresented: isCommandBarPresented,
                    isResizing: state.isSidebarResizing,
                    descriptor: model.shortcutStore.descriptor(for: .newTab),
                )
                row.onSelect = { [weak state] in state?.toggleCommandBar() }
                row.onDragChanged = { [weak self] value in
                    guard let self else { return }
                    state.updateSpacePagerDrag(value, in: state.snapshot, pageWidth: pagerClip.bounds.width)
                }
                row.onDragEnded = { [weak self] value in
                    guard let self else { return }
                    state.finishSpacePagerDrag(value, in: state.snapshot, pageWidth: pagerClip.bounds.width)
                }
            case .divider:
                let selectedID = temporary.contains { $0.id == snapshot.selectedTabID } ? snapshot.selectedTabID : nil
                let includesActive = temporary
                    .count == 1 || (selectedID != nil && state.activeTemporaryTabClearConfirmationTabID == selectedID)
                page.divider.update(
                    showsClear: state.isSidebarHovered && !temporary.isEmpty && snapshot.selectedSpaceID == space.id,
                    includesActive: includesActive,
                    descriptor: model.shortcutStore.descriptor(for: .clearTemporaryTabs),
                )
                page.divider.onClear = { [weak state] in state?.clearTemporaryTabs(in: space.id) }
                page.divider.isHidden = false
            case .incognito: break
            }
        }
        page.divider.isHidden = !entries.contains {
            if case .divider = $0 {
                return true
            }
            return false
        }
        page.incognito.isHidden = !model.windowMode.isSpaceless
        page.incognito.stringValue = model.isIncognito
            ? BrowserStrings.incognitoTabsTitle
            : BrowserStrings.blankWindowTabsTitle
        page.scroll.isScrollingEnabled = !state.isSpacePagerDragging
    }

    /// A pressed tab looks selected in this frame, and the row that was selected
    /// stops looking so; the page switch and the full refresh follow.
    private func showSelectionAtOnce(on pressed: BrowserNativeSidebarRowNSView) {
        for page in pages.values {
            for row in page.rows.values where row !== pressed && row.showsSelected {
                row.showSelected(false)
            }
        }
        pressed.showSelected(true)
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    private func configure(
        row: BrowserNativeSidebarRowNSView,
        tab: BrowserChromeModel.Tab,
        section: BrowserSidebarTabSection,
        indent: Int,
    ) {
        if section != .app, let members = state.snapshot.splitMembers(ofTabID: tab.id) {
            configureSplit(row: row, representative: tab, memberIDs: members, section: section, indent: indent)
            return
        }
        let state = state
        let model = state.model
        let isApp = section == .app
        let selected = state.snapshot.selectedTabID == tab.id && (isApp || !isCommandBarPresented)
        row.update(
            tab: tab,
            appTile: isApp,
            selected: selected,
            multiSelected: state.selectedSidebarTabIDs.contains(tab.id),
            renaming: state.renamingTabID == tab.id,
            indentLevel: indent,
            isResizing: state.isSidebarResizing,
            resetID: state.tabRowInteractionResetID,
            closeDescriptor: model.shortcutStore.descriptor(for: .archiveTab),
            muted: state.snapshot.mutedTabIDs.contains(tab.id),
            audible: state.snapshot.audibleTabIDs.contains(tab.id),
            recording: state.snapshot.recordingTabIDs.contains(tab.id),
            peekPage: isApp ? nil : state.snapshot.peekPagesByTabID[tab.id],
            icon: state.snapshot.tabIcons[tab.id],
            developerHost: model.developerModeHost(forTabURLString: tab.urlString),
        )
        let muted = state.snapshot.mutedTabIDs.contains(tab.id)
        row.onToggleMute = { model.setTabMuted(!muted, id: tab.id) }
        let previewID = model.recentPagesPreviewID(forTab: tab)
        row.showsUnreadDot = model.unreadMailCount(forTabID: tab.id) > 0
        row.onHoverChanged = { [weak self, weak row] hovered in
            guard let self, let row, let previewID else { return }
            if hovered {
                state.model.refreshMailPreview(forTabID: tab.id)
            }
            folderPreview.rowHoverChanged(folderID: previewID, row: row, hovered: hovered)
        }
        // The row stays where it was while it is dragged and goes once dropped,
        // so the drop does not slide it across the list beside the preview.
        row.dragOpacity = !state.drag.isDragging && state.draggedTabIDs.contains(tab.id) ? 0 : 1
        row.onSelect = { [weak state] in
            guard let state else { return }
            if state.renamingTabID != tab.id {
                state.dismissRenamingIfNeeded()
            }
            state.handleSidebarTabSelection(tab, in: section)
        }
        row.onShowSelectionAtOnce = { [weak self] row in self?.showSelectionAtOnce(on: row) }
        row.onModifiedSelect = { [weak state] modifiers in
            guard let state else { return }
            state.dismissRenamingIfNeeded()
            state.handleSidebarTabSelection(tab, in: section, modifiers: modifiers)
        }
        row.onBeginRename = { [weak state] in
            if isApp {
                if let title = BrowserNativeMenus.prompt(
                    title: BrowserStrings.tabRenamePromptTitle,
                    defaultValue: tab.userTitleOverride ?? tab.displayTitle,
                ) {
                    model.setUserTitleOverride(title, forTabID: tab.id)
                }
            } else {
                state?.beginRenamingTab(id: tab.id)
            }
        }
        row.onCommitRename = { [weak state] title in model.setUserTitleOverride(title, forTabID: tab.id)
            state?.renamingTabID = nil
        }
        row.onCancelRename = { [weak state] in state?.renamingTabID = nil }
        row.onBackToPinnedURL = { _ = model.resetPinnedTabToPinnedURL(id: tab.id) }
        row.onSeparateFromPinnedTab = { _ = model.separateFromPinnedTab(id: tab.id) }
        row.onClose = { [weak state] in
            guard let state else { return }
            if let renaming = state.renamingTabID, renaming != tab.id {
                state.dismissRenamingIfNeeded()
            }
            if state.renamingTabID == tab.id {
                state.renamingTabID = nil
            }
            state.withSidebarAnimation {
                _ =
                    if isApp {
                        model.closeAppTabProcess(id: tab.id)
                    } else if tab.placement == .spacePinned, tab.pinnedURLString != nil,
                              state.snapshot.selectedTabID == tab.id
                    {
                        model.closePinnedTabProcessOrReset(id: tab.id)
                    } else {
                        model.closeTab(id: tab.id)
                    }
            }
        }
        row.menuProvider = { [weak self, weak row] in
            guard let self, let row else { return NSMenu() }
            return tabMenu(tab, section: section, row: row)
        }
        row.dragCoordinateView = content
        row.onBeginDragSession = { [weak self, weak row] value in
            guard let self, let row else { return false }
            return beginDragging(item: .tab(tab.id), from: row, value: value)
        }
    }

    private func configureSplit(
        row: BrowserNativeSidebarRowNSView,
        representative tab: BrowserChromeModel.Tab,
        memberIDs: [String],
        section: BrowserSidebarTabSection,
        indent: Int,
    ) {
        let state = state
        let model = state.model
        let members = memberIDs.compactMap { state.snapshot.tab(withID: $0) }
        let selectedID = state.snapshot.selectedTabID
        row.update(
            split: members,
            focusedTabID: selectedID,
            selected: selectedID.map(memberIDs.contains) == true && !isCommandBarPresented,
            multiSelected: memberIDs.contains(where: state.selectedSidebarTabIDs.contains),
            indentLevel: indent,
            name: state.snapshot.splitNames[memberIDs],
            icons: state.snapshot.tabIcons,
            recordingTabIDs: state.snapshot.recordingTabIDs,
            isResizing: state.isSidebarResizing,
            resetID: state.tabRowInteractionResetID,
        )
        row.dragOpacity = !state.drag.isDragging && !state.draggedTabIDs.isEmpty
            && memberIDs.allSatisfy(state.draggedTabIDs.contains) ? 0 : 1
        row.onSelectSplitMember = { [weak state] id in
            guard let state, let member = state.snapshot.tab(withID: id) else { return }
            state.dismissRenamingIfNeeded()
            state.handleSidebarTabSelection(member, in: section)
        }
        row.onModifiedSelect = { [weak state] modifiers in
            guard let state else { return }
            state.dismissRenamingIfNeeded()
            state.handleSidebarTabSelection(tab, in: section, modifiers: modifiers)
        }
        row.onCloseSplitMember = { [weak state] id in
            guard let state, let member = state.snapshot.tab(withID: id) else { return }
            state.dismissRenamingIfNeeded()
            state.withSidebarAnimation {
                _ =
                    if member.placement == .spacePinned, member.pinnedURLString != nil,
                    state.snapshot.selectedTabID == id {
                        model.closePinnedTabProcessOrReset(id: id)
                    } else {
                        model.closeTab(id: id)
                    }
            }
        }
        row.menuProvider = { [weak self] in self?.splitMenu(members) ?? NSMenu() }
        row.dragCoordinateView = content
        row.onBeginDragSession = { [weak self, weak row] value in
            guard let self, let row else { return false }
            return beginDragging(item: .tab(tab.id), from: row, value: value)
        }
    }

    /// Split View row menu: whole-split actions, then options per pane.
    private func splitMenu(_ members: [BrowserChromeModel.Tab]) -> NSMenu {
        let state = state
        let model = state.model
        let menu = BrowserNativeMenus.menu()
        guard let first = members.first, let group = model.splitGroup(containingTabID: first.id) else { return menu }
        BrowserNativeMenus.add(BrowserStrings.splitSeparateAllTabsAction, to: menu) { [weak state] in
            state?.withSidebarAnimation { _ = model.separateSplitGroup(id: group.id) }
        }
        BrowserNativeMenus.add(
            BrowserStrings.menuAddSplitView,
            to: menu,
            enabled: members.count < BrowserChromeModel.maximumSplitPaneCount,
        ) {
            if !members.contains(where: { $0.id == model.selectedTabID }) {
                model.selectTab(id: model.splitPaneTabIDs(of: group).first { id in
                    model.tabs.first { $0.id == id }?.syncID == group.focusedTabSyncID
                } ?? first.id)
            }
            model.presentSplitViewCommandBar()
        }
        let vertical = group.orientation == .vertical
        BrowserNativeMenus.add(
            vertical ? BrowserStrings.splitConvertToHorizontalAction : BrowserStrings.splitConvertToVerticalAction,
            to: menu,
        ) {
            _ = model.setSplitOrientation(vertical ? .horizontal : .vertical, groupID: group.id)
        }
        let spaces = model.spacesForMovingTab(id: first.id)
        if !spaces.isEmpty {
            let submenu = BrowserNativeMenus.submenu(BrowserStrings.tabMoveToSpaceAction, in: menu)
            for space in spaces {
                let item = BrowserNativeMenus.add(space.title, to: submenu) { [weak state] in
                    state?.withSidebarAnimation { _ = model.moveSplitToSpace(
                        containingTabID: first.id,
                        spaceID: space.id,
                    ) }
                }
                item.image = NSImage(systemSymbolName: space.systemImageName, accessibilityDescription: nil)
            }
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.splitRenameAction, to: menu) {
            if let title = BrowserNativeMenus.prompt(
                title: BrowserStrings.splitRenameAction,
                defaultValue: group.title ?? "",
            ) {
                model.setSplitTitle(title, groupID: group.id)
            }
        }
        BrowserNativeMenus.addIconMenu(
            BrowserStrings.splitChangeIconAction,
            to: menu,
            selected: group.systemImageName,
            noIconTitle: BrowserStrings.pinnedTabFolderNoIconAction,
        ) { model.setSplitIcon($0, groupID: group.id) }
        BrowserNativeMenus.add(BrowserStrings.splitArchiveAction, to: menu) { [weak state] in
            state?.withSidebarAnimation { model.closeSplit(containingTabID: first.id) }
        }
        menu.addItem(.separator())
        for member in members {
            let item = NSMenuItem(title: member.displayTitle, action: nil, keyEquivalent: "")
            let submenu = BrowserNativeMenus.menu()
            BrowserNativeMenus.add(BrowserStrings.splitSeparateTabAction, to: submenu) { [weak state] in
                state?.withSidebarAnimation { _ = model.separateTabFromSplit(tabID: member.id) }
            }
            BrowserNativeMenus.add(model.shortcutStore.descriptor(for: .copyLink).menuTitle, to: submenu) {
                _ = model.copyTabLink(forTabID: member.id)
            }
            let muted = model.isTabMuted(id: member.id)
            BrowserNativeMenus.add(muted ? BrowserStrings.tabUnmuteAction : BrowserStrings.tabMuteAction, to: submenu) {
                model.setTabMuted(!muted, id: member.id)
            }
            BrowserNativeMenus.add(BrowserStrings.tabCloseAction, to: submenu) { [weak state] in
                state?.withSidebarAnimation { _ = model.closeTab(id: member.id) }
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private func tabMenu(
        _ tab: BrowserChromeModel.Tab,
        section: BrowserSidebarTabSection,
        row: BrowserNativeSidebarRowNSView,
    ) -> NSMenu {
        let model = state.model
        let state = state
        let selected = state.snapshot.selectedTabID == tab.id && (section == .app || !isCommandBarPresented)
        if let easelID = BrowserEaselURL.easelID(from: tab.pinnedURLString ?? tab.urlString) {
            return easelMenu(tab, easelID: easelID, row: row)
        }
        let menu = BrowserNativeMenus.menu()
        let copy = model.shortcutStore.descriptor(for: .copyLink)
        let close = model.shortcutStore.descriptor(for: .archiveTab)
        BrowserNativeMenus
            .add(BrowserStrings.tabCopyLinkAction, to: menu, shortcut: selected ? copy.shortcut : nil) {
                _ = model.copyTabLink(forTabID: tab.id)
            }
        BrowserNativeMenus.share(
            items: tab.pageURL.map { [$0] } ?? [NSString(string: tab.urlString)],
            subject: tab.displayTitle,
            in: menu,
        )
        menu.addItem(.separator())
        BrowserNativeMenus.addIconMenu(
            BrowserStrings.tabChangeIconAction,
            to: menu,
            selected: model.icon(forTabID: tab.id),
            noIconTitle: BrowserStrings.tabSiteIconAction,
        ) { model.setIcon($0, forTabID: tab.id) }
        let folderIDs = state.pinnedTabFolderCreationTabIDs(fromTabID: tab.id, in: section)
        if !folderIDs.isEmpty {
            BrowserNativeMenus
                .add(BrowserStrings.pinnedTabFolderNewAction, to: menu) { [weak state] in
                    state?.createPinnedTabFolder(containingTabIDs: folderIDs)
                }
        }
        BrowserNativeMenus.add(BrowserStrings.tabRenameAction, to: menu, action: row.onBeginRename)
        let muted = model.isTabMuted(id: tab.id)
        // Only a tab that plays sound, or one already silenced, has anything to mute.
        BrowserNativeMenus.add(
            muted ? BrowserStrings.tabMenuUnmuteAction : BrowserStrings.tabMenuMuteAction,
            to: menu,
            enabled: muted || state.snapshot.audibleTabIDs.contains(tab.id),
        ) {
            model.setTabMuted(!muted, id: tab.id)
        }
        if tab.placement.keepsPinnedURL {
            let pinned = BrowserNativeMenus.submenu(BrowserStrings.pinnedTabEditPageAction, in: menu)
            BrowserNativeMenus
                .add(BrowserStrings.pinnedTabReplaceURLWithCurrentAction, to: pinned) {
                    _ = model.replacePinnedURLWithCurrent(forTabID: tab.id)
                }
            BrowserNativeMenus.add(BrowserStrings.pinnedTabEditURLAction, to: pinned) {
                if let url = BrowserNativeMenus.prompt(
                    title: BrowserStrings.pinnedTabEditURLPromptTitle,
                    defaultValue: tab.pinnedURLString ?? tab.urlString,
                ) {
                    _ = model.setPinnedURLString(url, forTabID: tab.id)
                }
            }
        }
        let hasSplitItems = addSplitItems(for: tab, to: menu)
        addArrangeItems(for: tab, to: menu, startsGroup: !hasSplitItems)
        menu.addItem(.separator())
        if tab.placement == .spacePinned {
            BrowserNativeMenus.add(BrowserStrings.tabRemovePinAction, to: menu) { [weak state] in
                state?.withSidebarAnimation { model.togglePinned(forTabID: tab.id) }
            }
            return menu
        }
        BrowserNativeMenus.add(
            section == .app ? BrowserStrings.tabCloseAction : close.menuTitle,
            to: menu,
            shortcut: selected
                ? close.shortcut
                : nil,
            action: row.onClose,
        )
        if section == .app {
            BrowserNativeMenus
                .add(BrowserStrings.appTabRemoveFavoriteAction, to: menu) { [weak state] in
                    state?.withSidebarAnimation { model.removeAppTabFavorite(id: tab.id) }
                }
        } else {
            if section == .temporary {
                let others = model.otherTemporaryTabIDs(id: tab.id)
                BrowserNativeMenus.add(BrowserStrings.tabArchiveOtherTabsAction, to: menu, enabled: !others.isEmpty) {
                    [weak state] in
                    state?.renamingTabID = nil
                    state?.withSidebarAnimation { model.closeOtherTemporaryTabs(id: tab.id) }
                }
            }
            BrowserNativeMenus.add(
                BrowserStrings.tabArchiveTabsBelowAction,
                to: menu,
                enabled: state.snapshot.archivableTabIDs.contains(tab.id),
            ) { [weak state] in
                state?.renamingTabID = nil
                state?.withSidebarAnimation { model.closeTabsBelow(id: tab.id) }
            }
            // Below, then Above.
            if section == .temporary {
                let above = model.temporaryTabIDsAbove(id: tab.id)
                BrowserNativeMenus.add(BrowserStrings.tabArchiveTabsAboveAction, to: menu, enabled: !above.isEmpty) {
                    [weak state] in
                    state?.renamingTabID = nil
                    state?.withSidebarAnimation { model.closeTemporaryTabsAbove(id: tab.id) }
                }
            }
        }
        return menu
    }

    /// An Easel's row: icon, rename, split and move, then remove or delete.
    private func easelMenu(_ tab: BrowserChromeModel.Tab, easelID: String, row: BrowserNativeSidebarRowNSView) -> NSMenu {
        let model = state.model
        let state = state
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.addIconMenu(
            BrowserStrings.tabChangeIconAction,
            to: menu,
            selected: model.icon(forTabID: tab.id),
            noIconTitle: BrowserStrings.tabSiteIconAction,
        ) { model.setIcon($0, forTabID: tab.id) }
        BrowserNativeMenus.add(BrowserStrings.tabRenameAction, to: menu, action: row.onBeginRename)
        let hasSplitItems = addSplitItems(for: tab, to: menu)
        addArrangeItems(for: tab, to: menu, startsGroup: !hasSplitItems)
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.easelRemoveFromSidebar, to: menu) { [weak state] in
            state?.renamingTabID = nil
            state?.withSidebarAnimation { _ = model.closeTab(id: tab.id) }
        }
        BrowserNativeMenus.add(BrowserStrings.easelDeleteMenu, to: menu) { [weak self, weak state] in
            BrowserEaselDialogs.confirmDelete(in: self?.window) {
                state?.renamingTabID = nil
                state?.withSidebarAnimation { model.deleteEasel(id: easelID) }
            }
        }
        return menu
    }

    /// Duplicate and Move to.
    private func addArrangeItems(for tab: BrowserChromeModel.Tab, to menu: NSMenu, startsGroup: Bool) {
        let model = state.model
        let state = state
        let spaces = model.spacesForMovingTab(id: tab.id)
        let canDuplicate = tab.placement == .app || tab.spaceID == state.snapshot.selectedSpaceID
        guard canDuplicate || !spaces.isEmpty else { return }
        if startsGroup {
            menu.addItem(.separator())
        }
        if canDuplicate {
            BrowserNativeMenus.add(BrowserStrings.tabDuplicateAction, to: menu) { [weak state] in
                state?.withSidebarAnimation { _ = model.duplicateTab(id: tab.id) }
            }
        }
        guard !spaces.isEmpty else { return }
        let submenu = BrowserNativeMenus.submenu(BrowserStrings.tabMoveToSpaceAction, in: menu)
        for space in spaces {
            let item = BrowserNativeMenus.add(space.title, to: submenu) { [weak state] in
                state?.withSidebarAnimation { _ = model.moveTabToSpace(id: tab.id, spaceID: space.id) }
            }
            item.image = NSImage(systemSymbolName: space.systemImageName, accessibilityDescription: nil)
        }
    }

    /// Open in Split View joins the row to the selected tab's split; a
    /// split member also offers the split row actions.
    @discardableResult private func addSplitItems(for tab: BrowserChromeModel.Tab, to menu: NSMenu) -> Bool {
        let model = state.model
        let state = state
        let group = model.splitGroup(containingTabID: tab.id)
        let canOpen = model.selectedTabID.map { selected in
            selected != tab.id && model.canAddSplitView && !model.splitPaneTabIDs(forTabID: selected).contains(tab.id)
        } ?? false
        // The shown tab has nothing to join: it asks for a page, as the menu bar does.
        let canAdd = model.selectedTabID == tab.id && model.canAddSplitView
        guard canOpen || canAdd || group != nil else { return false }
        menu.addItem(.separator())
        if canAdd {
            BrowserNativeMenus.add(BrowserStrings.menuAddSplitView, to: menu) {
                model.presentSplitViewCommandBar()
            }
        }
        if canOpen {
            BrowserNativeMenus.add(BrowserStrings.splitOpenInSplitViewAction, to: menu) { [weak state] in
                state?.withSidebarAnimation { _ = model.openInSplitView(tabID: tab.id) }
            }
        }
        guard let group else { return true }
        BrowserNativeMenus.add(BrowserStrings.splitSeparateTabAction, to: menu) { [weak state] in
            state?.withSidebarAnimation { _ = model.separateTabFromSplit(tabID: tab.id) }
        }
        BrowserNativeMenus.add(BrowserStrings.splitSeparateAllTabsAction, to: menu) {
            _ = model.separateSplitGroup(id: group.id)
        }
        let vertical = group.orientation == .vertical
        BrowserNativeMenus.add(
            vertical ? BrowserStrings.splitConvertToHorizontalAction : BrowserStrings.splitConvertToVerticalAction,
            to: menu,
        ) {
            _ = model.setSplitOrientation(vertical ? .horizontal : .vertical, groupID: group.id)
        }
        return true
    }

    private func spaceMenu(_ space: BrowserChromeModel.Space) -> NSMenu {
        let state = state
        let model = state.model
        guard model.supportsSpaces else { return NSMenu() }
        return BrowserNativeMenus.space(
            space,
            canDelete: state.snapshot.spaces.count > 1,
            canResetTabs: model.canResetSpaceTabs(spaceID: space.id),
            onRename: { [weak state] in state?.clearSidebarTabSelection()
                state?.beginRenamingSpace(id: space.id)
            },
            onChangeIcon: { model.setIcon($0, forSpaceID: space.id) },
            onEditTheme: { model.onEditSpaceTheme?(space.id) },
            profiles: model.profileDirectories?.profiles() ?? [],
            selectedProfile: model.profileDirectory(forSpaceID: space.id),
            onSetProfile: { model.requestProfile($0, forSpaceID: space.id) },
            onNewProfile: {
                if let created = model.profileDirectories?.createProfile() {
                    model.setProfile(created, forSpaceID: space.id)
                }
            },
            onManageSpaces: { model.openSpacesInLibrary() },
            canCreateFolder: model.canCreateFolder,
            onNewFolder: { model.createFolderInSelectedSpace() },
            onNewGitHubLiveFolder: { model.createGitHubLiveFolder(inSpaceID: space.id) },
            onShare: model.onShareSpace.map { share in { share(space.id) } },
            exportTargets: state.snapshot.spaces.filter { $0.id != space.id },
            onExport: { targetID in model.exportSpace(id: space.id, intoFolderInSpaceID: targetID) },
            onResetTabs: { model.resetSpaceTabs(spaceID: space.id) },
            onDelete: { [weak state] in state?.dismissRenamingIfNeeded()
                state?.clearSidebarTabSelection()
                model.deleteSpace(id: space.id)
            },
        )
    }

    private func synchronizeGeometry() {
        guard !isLayingOut else { return }
        for page in pages.values {
            let visible = page.scroll.documentVisibleRect
            let threshold = BrowserChromeLayout.sidebarTopChromeDividerScrollThreshold
            let top = visible.minY > threshold
            let bottom = visible.maxY < page.document.bounds.height - threshold
            if state
                .topChromeDividerVisibilityBySpaceID[page.spaceID] !=
                top
            {
                state.topChromeDividerVisibilityBySpaceID[page.spaceID] = top
            }
            if state
                .bottomChromeDividerVisibilityBySpaceID[page.spaceID] !=
                bottom
            {
                state.bottomChromeDividerVisibilityBySpaceID[page.spaceID] = bottom
            }
            page.topDivider.alphaValue = top ? 1 : 0
        }
        if state.drag.isDragging, let geometry = makeDragGeometry() {
            state.drag.updateGeometry(geometry)
        }
    }

    private func endLinkDrop() {
        acceptsLinkDrop = false
        guard linkDropProposal != nil else { return }
        linkDropProposal = nil
        updateDragPresentation()
    }

    private func endDragging(at point: CGPoint, cancelled: Bool) {
        otherWindowDropTarget?.updateTabDrop(at: nil)
        otherWindowDropTarget = nil
        hideOutsidePreview()
        dragEvents.stop()
        guard let payload = state.drag.payload else { return }
        let from = dragPreview.frame
        state.drag.release(at: point, cancel: cancelled, copy: !cancelled && isCopyModifierHeld())
        state.update(
            snapshot: state.model.sidebarSnapshot,
            sidebarWidth: state.sidebarWidth,
            isResizing: state.isSidebarResizing,
        )
        refresh(animated: true)
        dragPreview.update(
            payload: payload,
            snapshot: state.snapshot,
            appTile: state.snapshot.appTabs.contains { .tab($0.id) == payload.primary },
        )
        let landing = state.drag.landingItem ?? payload.primary
        ensureDestinationVisible(landing)
        let target = restingFrame(for: landing)
        let exact = isItemRendered(landing)
        let to = target ?? from
        dragPreview.onBeginDragSession = { [weak self] value in
            guard let self else { return false }
            return beginDragging(item: payload.primary, sourceFrame: dragPreview.frame, value: value)
        }
        landingAnimation.start(.landing) { [weak self] progress in
            guard let self else { return }
            dragPreview.frame = BrowserNativeAnimation.interpolate(from, to, progress)
            dragPreview.alphaValue = target == nil || !exact ? max(1 - progress, 0) : 1
            dragPreview.layoutSubtreeIfNeeded()
        } completion: { [weak self] in self?.completeDragPresentation() }
    }

    private func isItemRendered(_ item: BrowserSidebarItemID) -> Bool {
        if case .tab(let id) = item, state.snapshot.appTabs.contains(where: { $0.id == id }) {
            return true
        }
        return state.snapshot.selectedSpaceID.flatMap { pages[$0]?.frames[itemKey(item)] } != nil
    }

    /// Scrolls the selected row into view once per Reveal Current Tab request,
    /// after the refresh that may have opened its pinned section has laid out.
    private func revealSelectedRowIfRequested() {
        let request = state.model.sidebarRevealRequestID
        guard request != handledRevealRequestID else { return }
        handledRevealRequestID = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let selectedID = state.snapshot.selectedTabID else { return }
            layoutSubtreeIfNeeded()
            // A split's row belongs to whichever member comes first in the sidebar.
            for id in state.snapshot.splitMembers(ofTabID: selectedID) ?? [selectedID] {
                ensureDestinationVisible(.tab(id))
            }
        }
    }

    /// Starts renaming the selected row once per Rename Tab request.
    private func renameSelectedRowIfRequested() {
        if let folderID = state.model.folderToRename {
            state.model.folderToRename = nil
            DispatchQueue.main.async { [weak self] in self?.state.beginRenamingPinnedTabFolder(id: folderID) }
        }
        let request = state.model.sidebarRenameRequestID
        guard request != handledRenameRequestID else { return }
        handledRenameRequestID = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let selectedID = state.snapshot.selectedTabID else { return }
            state.beginRenamingTab(id: selectedID)
        }
    }

    /// Starts renaming the selected Space once per Rename Space request.
    private func renameSelectedSpaceIfRequested() {
        let request = state.model.sidebarSpaceRenameRequestID
        guard request != handledSpaceRenameRequestID else { return }
        handledSpaceRenameRequestID = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let spaceID = state.snapshot.selectedSpaceID else { return }
            state.beginRenamingSpace(id: spaceID)
        }
    }

    private func ensureDestinationVisible(_ item: BrowserSidebarItemID) {
        guard let id = state.snapshot.selectedSpaceID, let page = pages[id],
              let rect = page.frames[itemKey(item)] else { return }
        let clip = page.scroll.contentView
        let height = max(frameTransitions.targetFrame(of: pagerClip).height - page.scroll.frame.minY, 0)
        var y = clip.bounds.minY
        if rect.minY < y {
            y = rect.minY
        }
        if rect.maxY > y + height {
            y = rect.maxY - height
        }
        y = min(max(y, 0), max(page.document.bounds.height - height, 0))
        clip.scroll(to: CGPoint(x: 0, y: y))
        page.scroll.reflectScrolledClipView(clip)
    }

    /// The pointer carries the system's copy badge while Option would copy the drop.
    private func updateCopyCursor() {
        let copies = state.drag.isDragging && isCopyModifierHeld()
            && (state.drag.proposal != nil || state.drag.dockSpaceID != nil)
        guard copies != showsCopyCursor else { return }
        showsCopyCursor = copies
        (copies ? NSCursor.dragCopy : NSCursor.arrow).set()
    }

    private func completeDragPresentation() {
        if showsCopyCursor {
            showsCopyCursor = false
            NSCursor.arrow.set()
        }
        tabSelectedBeforeDrag = nil
        draggedPageThumbnail = nil
        draggedPageThumbnailTabID = nil
        hideOutsidePreview()
        landingAnimation.cancel()
        dragEvents.stop()
        state.clearTabDragState()
        refresh()
    }

    private func itemKey(_ item: BrowserSidebarItemID) -> String {
        switch item { case .tab(let id): "tab:\(id)"
        case .folder(let id): "folder:\(id)" }
    }

    private func handleDragLayoutChange() {
        let projecting = state.drag.projectedPlan != nil
        let leavingGrid = isProjectingAppGrid && !projecting && state.drag.isDragging
        isProjectingAppGrid = projecting
        if leavingGrid {
            // Freeze the actual expanded space immediately. Even a fast exit
            // during the spring must not move the rows away from the pointer.
            frameTransitions.freezeFrame(of: appGrid)
            frameTransitions.freezeFrame(of: pagerClip)
            reservedAppHeight = max(
                pagerClip.frame.minY - header.frame.maxY
                    - BrowserChromeLayout.sidebarListTopSpacing * 2,
                0,
            )
        }
        state.invalidate(animated: !leavingGrid)
    }

    private func updateDragPresentation() {
        if reportedDragging != state.drag.isDragging {
            reportedDragging = state.drag.isDragging
            onDragInteractionChange(reportedDragging)
        }
        highlightedDropRow?.setDropHighlighted(false)
        highlightedDropRow = nil
        splitPreviewRow?.setSplitDropSide(nil)
        splitPreviewRow = nil
        if let target = state.drag.splitTarget {
            splitPreviewRow = pages.values.compactMap { $0.rows["tab:\(target.tabID)"] }.first
            splitPreviewRow?.setSplitDropSide(target.side)
        }
        dragIndicator.update(line: nil, occluding: nil)
        folderDropBandID = nil
        if let feedback = state.drag.proposal?.feedback ?? linkDropProposal?.feedback {
            switch feedback {
            case .line(let line) where state.drag.payload == nil: dragIndicator.update(line: line, occluding: nil)
            case .line: break
            case .folder(let id): folderDropBandID = id
            case .space(let id): highlightedDropRow = pages[id]?.header
            case .app: break
            }
        }
        highlightedDropRow?.setDropHighlighted(true)
        layoutFolderDropBand()
        spaceDock?.dropTargetID = state.drag.dockSpaceID
        guard let payload = state.drag.payload else {
            dragEvents.stop()
            landingAnimation.cancel()
            dragPreview.isHidden = true
            return
        }
        guard state.drag.phase == .dragging else { return }
        dragPreview.onBeginDragSession = nil
        dragPreview.alphaValue = 1
        // The preview keeps the look and size it started with until the drop.
        if dragPreviewTargetSize == nil {
            dragPreviewTargetSize = state.drag.previewSize
            dragPreviewIsAppTile = state.drag.isAppPreview
        }
        let dragPreviewSize = dragPreviewTargetSize ?? state.drag.previewSize
        dragPreview.update(
            payload: payload,
            snapshot: state.snapshot,
            appTile: dragPreviewIsAppTile,
        )
        dragPreview.isHidden = false
        layoutDragPreview(size: dragPreviewSize)
    }

    private func layoutFolderDropBand() {
        guard let id = folderDropBandID,
              let page = pages.values.first(where: { $0.rows["folder:\(id)"] != nil && !$0.isLeaving }),
              let row = page.rows["folder:\(id)"], !row.isHidden
        else {
            folderDropBand.isHidden = true
            return
        }
        let rowFrame = row.convert(row.bounds, to: self)
        let viewport = page.scroll.contentView.convert(page.scroll.contentView.bounds, to: self)
        let band = CGRect(x: 0, y: rowFrame.minY, width: bounds.width, height: rowFrame.height)
            .intersection(CGRect(x: 0, y: viewport.minY, width: bounds.width, height: viewport.height))
        guard !band.isNull, band.height > 0 else {
            folderDropBand.isHidden = true
            return
        }
        folderDropBand.fillColor = page.spaceThemePalette?.dropTargetBand ?? BrowserChromeColors.sidebarDropTargetBand
        folderDropBand.frame = band
        folderDropBand.isHidden = false
    }

    /// The tray shows a moment after the pointer reaches the Library button and
    /// stays while it is over the button or the tray.
    private func scheduleDownloadsTray() {
        downloadsTrayWork?.cancel()
        let shows = isLibraryButtonHovered || downloadsTray.isHovered
        guard shows != (downloadsTray.superview != nil) else { return }
        let work = DispatchWorkItem { [weak self] in self?.setDownloadsTrayShown(shows) }
        downloadsTrayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (shows ? 0.3 : 0.2), execute: work)
    }

    /// The folder's newest items, then the downloads still running, newest last.
    private func downloadsTrayEntries() -> [BrowserDownloadsTrayView.Entry] {
        let downloads = state.model.downloadsModel
        let running = downloads.items.filter { $0.state == .inProgress }.map { item in
            BrowserDownloadsTrayView.Entry(
                url: item.fileURL ?? URL(fileURLWithPath: item.fileName),
                date: item.startedAt,
                progress: downloads.detailText(for: item),
                fraction: item.progressFraction,
                title: item.fileName,
                onCancel: { [weak downloads] in downloads?.cancel(item) },
            )
        }
        let files = BrowserDownloadsTrayView.recentEntries(in: BrowserDownloadLocation.directory(
            customPath: state.model.userPreferencesStore.downloadDirectoryPath,
        ))
        // A canceled download left no file; it shows by when it began, with where it came from.
        let canceled = downloads.items.filter { $0.state == .canceled }.map { item in
            BrowserDownloadsTrayView.Entry(
                url: URL(fileURLWithPath: item.fileName),
                date: item.startedAt,
                progress: BrowserStrings.downloadsTrayCanceled(
                    host: URL(string: item.urlString)?.host.map(BrowserURLDisplayFormatter.hostDisplayString(forHost:)),
                ),
                title: item.fileName,
                isCanceled: true,
            )
        }
        return BrowserDownloadsTrayView.merged(files: files, canceled: canceled, running: running)
    }

    private func setDownloadsTrayShown(_ shown: Bool) {
        let entries = shown && !state.isDraggingSidebarItem ? downloadsTrayEntries() : []
        guard !entries.isEmpty else {
            downloadsTrayTimer?.invalidate()
            downloadsTrayTimer = nil
            guard downloadsTray.superview != nil else { return }
            BrowserNativeTooltipPresenter.shared.isSuppressed = state.isSpacePagerDragging
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                downloadsTray.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.downloadsTray.alphaValue == 0 else { return }
                    self.downloadsTray.removeFromSuperview()
                    self.pagerClip.layer?.mask = nil
                }
            }
            return
        }
        downloadsTray.show(entries)
        // The button's tooltip would cover the newest row.
        BrowserNativeTooltipPresenter.shared.isSuppressed = true
        if downloadsTray.superview == nil {
            content.addSubview(downloadsTray, positioned: .above, relativeTo: miniPlayers)
        }
        placeDownloadsTray()
        // Tracking areas miss fast exits and window changes; the pointer is checked too.
        downloadsTrayTimer?.invalidate()
        downloadsTrayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDownloadsTrayPointer() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            downloadsTray.animator().alphaValue = 1
        }
    }

    private func placeDownloadsTray() {
        let height = downloadsTray.preferredHeight
        downloadsTray.frame = NSRect(x: 0, y: footer.frame.minY - height, width: content.bounds.width, height: height)
        fadeListAbove(trayTop: downloadsTray.frame.minY)
    }

    private func checkDownloadsTrayPointer() {
        guard downloadsTray.superview != nil, let window else { return }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let button = (footer as? BrowserSidebarLibraryButtonHosting & NSView).map {
            content.convert($0.libraryButtonFrame, from: $0)
        } ?? .zero
        guard !downloadsTray.frame.contains(point), !button.contains(point) else {
            // Progress moves, and a finished download turns into its file.
            downloadsTray.refresh(downloadsTrayEntries())
            placeDownloadsTray()
            return
        }
        isLibraryButtonHovered = false
        setDownloadsTrayShown(false)
    }

    /// The list fades out over 40 pt above the tray and is hidden behind it.
    private func fadeListAbove(trayTop: CGFloat) {
        pagerClip.wantsLayer = true
        guard let layer = pagerClip.layer, pagerClip.bounds.height > 0 else { return }
        let top = pagerClip.convert(NSPoint(x: 0, y: trayTop), from: content).y
        let fadeStart = top - 40
        let height = pagerClip.bounds.height
        // Unit positions run from the layer's bottom unless its geometry is flipped.
        func unit(_ y: CGFloat) -> NSNumber {
            let fromTop = pagerClip.isFlipped ? y : height - y
            let fraction = min(max(fromTop / height, 0), 1)
            return NSNumber(value: Double(layer.isGeometryFlipped ? fraction : 1 - fraction))
        }
        let mask = CAGradientLayer()
        mask.frame = layer.bounds
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        // Visible above the fade, gone from the tray's top down, in either unit direction.
        let fade = unit(fadeStart).doubleValue, gone = unit(top).doubleValue
        mask.locations = [0, NSNumber(value: min(fade, gone)), NSNumber(value: max(fade, gone)), 1]
        let shown = NSColor.black.cgColor, hidden = NSColor.clear.cgColor
        mask.colors = fade > gone ? [shown, shown, hidden, hidden] : [hidden, hidden, shown, shown]
        layer.mask = mask
    }

    private func updateOutsidePreview() {
        guard let window, state.drag.phase == .dragging else {
            hideOutsidePreview()
            return
        }
        let pointer = window.convertPoint(toScreen: content.convert(state.drag.pointer, to: nil))
        // Past the sidebar the list clips the preview, over the page as well as outside the window.
        let sidebar = window.convertToScreen(convert(visibleRect, to: nil))
        guard !sidebar.contains(pointer) else {
            hideOutsidePreview()
            return
        }
        let panel = outsidePreviewPanel ?? makeOutsidePreviewPanel()
        guard let container = panel.contentView as? BrowserDragOutsidePreview else { return }
        // Over a page that will split, the tab is the card of the pane it will become.
        var cardTab: BrowserChromeModel.Tab?
        if state.drag.pageSplitTarget != nil, case .tab(let id)? = state.drag.payload?.primary {
            cardTab = state.snapshot.tab(withID: id)
        }
        let outsideWindow = !window.frame.contains(pointer) && otherWindowDropTarget == nil
        if let cardTab {
            container.showCard(for: cardTab)
        } else if outsideWindow, let thumbnail = draggedPageThumbnail {
            // Past the window, the tab is the window it will open in.
            container.showThumbnail(thumbnail)
        } else if outsideWindow, case .tab(let id)? = state.drag.payload?.primary,
                  let tab = state.snapshot.tab(withID: id)
        {
            // Without a picture of its page, a card with its icon and title.
            container.showCard(for: tab, asWindow: true)
        } else if !container.showsRow || !panel.isVisible {
            dragPreview.alphaValue = 1
            let image = NSImage(size: dragPreview.bounds.size)
            if let rep = dragPreview.bitmapImageRepForCachingDisplay(in: dragPreview.bounds) {
                dragPreview.cacheDisplay(in: dragPreview.bounds, to: rep)
                image.addRepresentation(rep)
            }
            container.showRow(image)
        }
        let size = container.preferredSize
        let origin =
            if !container.showsRow {
                CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
            } else {
                // The row keeps the point it was grabbed by under the pointer; screen y grows upward.
                CGPoint(
                    x: pointer.x - size.width * state.drag.anchor.x,
                    y: pointer.y - size.height * (1 - state.drag.anchor.y),
                )
            }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        dragPreview.alphaValue = 0
    }

    private func makeOutsidePreviewPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = BrowserDragOutsidePreview()
        outsidePreviewPanel = panel
        return panel
    }

    private func hideOutsidePreview() {
        guard let panel = outsidePreviewPanel, panel.isVisible else { return }
        panel.orderOut(nil)
        dragPreview.alphaValue = 1
    }

    private func layoutDragPreview(size: CGSize) {
        let drag = state.drag
        dragPreview.frame = CGRect(
            x: drag.pointer.x - size.width * drag.anchor.x,
            y: drag.pointer.y - size.height * drag.anchor.y,
            width: size.width,
            height: size.height,
        )
        dragPreview.layoutSubtreeIfNeeded()
        updateOutsidePreview()
        if case .line(let line) = state.drag.proposal?.feedback {
            dragIndicator.update(line: line, occluding: dragPreview.frame)
        } else {
            dragIndicator.update(line: nil, occluding: nil)
        }
    }
}

// MARK: - BrowserNativeSidebarBackground

private final class BrowserNativeSidebarBackground: NSView {
    override var isFlipped: Bool { true }

    var onEmptyClick: () -> Void = {}
    var permitsWindowDrag: () -> Bool = { true }
    var menuProvider: (() -> NSMenu)?

    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
    override func mouseDown(with event: NSEvent) {
        onEmptyClick()
        if permitsWindowDrag() {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - BrowserNativeSidebarScrollView

private final class BrowserNativeSidebarScrollView: NSScrollView {
    var isScrollingEnabled = true

    override func scrollWheel(with event: NSEvent) {
        if isScrollingEnabled {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - BrowserNativeSidebarPage

private final class BrowserNativeSidebarPage: NSView, BrowserSpaceThemedChrome {
    enum Entry {
        case tab(
            BrowserChromeModel.Tab,
            section: BrowserSidebarTabSection,
            index: Int,
            folderID: String?,
            folderChildIndex: Int?,
            indent: Int,
        )
        case folder(BrowserSidebarPinnedFolderRow)
        case newTab
        case divider
        case incognito

        // MARK: Internal

        var id: String {
            switch self {
            case .tab(let tab, _, _, _, _, _): "tab:\(tab.id)"
            case .folder(let row): "folder:\(row.folder.id)"
            case .newTab: "new-tab"
            case .divider: "divider"
            case .incognito: "incognito"
            }
        }

        var height: CGFloat {
            switch self {
            case .divider: BrowserChromeLayout.sidebarDividerHeight
            case .incognito: 18
            default: BrowserChromeLayout.sidebarRowHeight
            }
        }
    }

    override var isFlipped: Bool { true }

    // MARK: Internal

    var spaceThemePalette: BrowserSpaceTheme.Palette?
    /// On its way out of the row of pages: it still shows, but sits where the new page is.
    var isLeaving = false

    let spaceID: String
    var index = 0
    var entries = [Entry]()
    var rows = [String: BrowserNativeSidebarRowNSView]()
    var frames = [String: NSRect]()
    let header = BrowserNativeSidebarRowNSView()
    let document = BrowserNativeSidebarBackground()
    let scroll = BrowserNativeSidebarScrollView()
    let topDivider = BrowserNativeNoninteractiveSurface()
    let divider = BrowserNativeSidebarClearDivider()
    let incognito = NSTextField(labelWithString: BrowserStrings.incognitoTabsTitle)
    var onScroll: () -> Void = {}

    // MARK: Private

    private let frameTransitions = BrowserNativeFrameTransitions()
    private var hasLaidOutRows = false
    private var laidOutMaxOffset: CGFloat?

    init(spaceID: String) {
        self.spaceID = spaceID
        super.init(frame: .zero)
        addSubview(header)
        addSubview(scroll)
        addSubview(topDivider)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
        )
        document.addSubview(divider)
        document.addSubview(incognito)
        topDivider.strokeWidth = 0
        topDivider.fillColor = BrowserChromeColors.sidebarTopChromeDivider
        topDivider.alphaValue = 0
        incognito.font = .systemFont(ofSize: 11.5, weight: .semibold)
        incognito.textColor = BrowserChromeColors.secondaryText
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isLeaving ? nil : super.hitTest(point)
    }

    func finishRowAnimations() { frameTransitions.finishAll() }

    func row(for id: String) -> BrowserNativeSidebarRowNSView {
        if let existing = rows[id] {
            return existing
        }
        let row = BrowserNativeSidebarRowNSView()
        rows[id] = row
        document.addSubview(row)
        if hasLaidOutRows {
            row.animateInsertion()
        }
        return row
    }

    func layoutRows(animated: Bool, curve: BrowserNativeAnimation.Curve) {
        hasLaidOutRows = true
        let headerHeight = header.isHidden ? 0 : BrowserChromeLayout.sidebarRowHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: BrowserChromeLayout.sidebarRowHeight)
        scroll.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(bounds.height - headerHeight, 0))
        topDivider.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: 1)
        let endInset = BrowserChromeLayout.sidebarListEndInset
        var y: CGFloat = endInset
        frames = [:]
        for entry in entries {
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: entry.height)
            frames[entry.id] = frame
            let view: NSView? =
                switch entry {
                case .divider: divider
                case .incognito: incognito
                default: rows[entry.id]
                }
            if let view {
                let rect: NSRect =
                    if case .incognito = entry {
                        frame.insetClamped(
                            dx: BrowserChromeLayout.sidebarRowHorizontalPadding,
                            dy: 0,
                        )
                    } else {
                        frame
                    }
                frameTransitions.slide(view, to: rect, animated: animated, curve: curve)
            }
            y += entry.height + BrowserChromeLayout.sidebarListSpacing
        }
        let height = max(y - BrowserChromeLayout.sidebarListSpacing + endInset, scroll.contentSize.height)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        // Only a shorter scroll range moves the offset: a scroll stretched past the end,
        // which a layout during the scroll would otherwise snap back, keeps its offset.
        let maxOffset = max(height - scroll.contentSize.height, 0)
        defer { laidOutMaxOffset = maxOffset }
        let origin = scroll.contentView.bounds.origin
        if maxOffset < laidOutMaxOffset ?? .infinity, origin.y > maxOffset {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func scrolled() {
        // Rows scrolled under a still pointer take and drop its hover.
        rows.values.forEach { $0.syncHoverWithPointer() }
        onScroll()
    }
}

// MARK: - BrowserNativeNoninteractiveSurface

private final class BrowserNativeNoninteractiveSurface: BrowserNativeSurface {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

// MARK: - BrowserNativeSidebarClearDivider

private final class BrowserNativeSidebarClearDivider: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onClear: () -> Void = {}

    // MARK: Private

    private let line = BrowserNativeNoninteractiveSurface()
    private let button = BrowserNativePressableView()
    private let title = NSTextField(labelWithString: BrowserStrings.sidebarClearTemporaryTabs)
    private let indicator = NSImageView()
    private var includesActive = false
    private let visibility = BrowserNativeVisibilityAnimation()
    private let clearAnimation = BrowserNativeAnimation()
    private let hoverAnimation = BrowserNativeAnimation()
    private var clearProgress = 0.0
    private var clearTarget = false
    private let indicatorAnimation = BrowserNativeAnimation()
    private var indicatorProgress = 0.0
    /// The arrow drops in from above when it appears and only fades when it goes.
    private var indicatorDrops = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.fillColor = BrowserChromeColors.sidebarDivider
        line.strokeWidth = 0
        addSubview(line)
        addSubview(button)
        button.addSubview(title)
        button.addSubview(indicator)
        title.font = .systemFont(ofSize: BrowserChromeLayout.sidebarClearFontSize, weight: .bold)
        indicator.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: 10,
                weight: .heavy,
            ))
        indicator.imageScaling = .scaleNone
        indicator.isHidden = true
        indicator.alphaValue = 0
        button.onClick = { [weak self] _ in self?.onClear() }
        button.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            let from = title.textColor ?? .clear
            let to = hovered ? BrowserChromeColors.secondaryText : BrowserChromeColors.sidebarClearButtonForeground
            hoverAnimation.start(.easeInOut(0.12)) { [weak self] progress in
                let color = from.blended(withFraction: progress, of: to) ?? to
                self?.title.textColor = color
                self?.indicator.contentTintColor = color
            }
        }
        button.setAccessibilityLabel(BrowserStrings.sidebarClearTemporaryTabs)
        button.setAccessibilityIdentifier("browser.sidebar.clear-temporary")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let textWidth = ceil((title.stringValue as NSString)
            .size(withAttributes: [.font: title.font ?? NSFont.systemFont(ofSize: 11)])
            .width) + 4
        let indicatorWidth = BrowserChromeLayout.sidebarClearArrowWidth * indicatorProgress
        let width = textWidth + indicatorWidth + BrowserChromeLayout.sidebarClearButtonHorizontalPadding * 2
        button.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        title.frame = NSRect(
            x: BrowserChromeLayout.sidebarClearButtonHorizontalPadding + indicatorWidth,
            y: (bounds.height - 16) / 2,
            width: textWidth,
            height: 16,
        )
        // The arrow stands as tall as the title's capitals and centers on them.
        let drop = indicatorDrops ? BrowserChromeLayout.sidebarClearArrowDropDistance * (1 - indicatorProgress) : 0
        // The button widens to the left as the arrow comes; the arrow keeps
        // its final place across the window and only moves down.
        indicator.frame = NSRect(
            x: BrowserChromeLayout.sidebarClearButtonHorizontalPadding - 0.5
                - BrowserChromeLayout.sidebarClearArrowWidth * (1 - indicatorProgress),
            y: (bounds.height - 12) / 2 - 2 - drop,
            width: 11,
            height: 12,
        )
        // The line stops just short of the arrow or title, not of the button's padding.
        let fullEnd = bounds.width - BrowserChromeLayout.sidebarDividerInset
        let clearEnd = button.frame.minX + BrowserChromeLayout.sidebarClearButtonHorizontalPadding
            - BrowserChromeLayout.sidebarClearLineGap
        let lineEnd = fullEnd - (fullEnd - clearEnd) * clearProgress
        line.frame = NSRect(
            x: BrowserChromeLayout.sidebarDividerInset,
            y: (bounds.height - BrowserChromeLayout.sidebarDividerThickness) / 2,
            width: max(lineEnd - BrowserChromeLayout.sidebarDividerInset, 0),
            height: BrowserChromeLayout.sidebarDividerThickness,
        )
    }

    func update(showsClear: Bool, includesActive: Bool, descriptor: BrowserCommandDescriptor) {
        visibility.setVisible(showsClear, view: button, curve: .hover)
        if clearTarget != showsClear {
            clearTarget = showsClear
            let from = clearProgress
            let to = showsClear ? 1.0 : 0.0
            if window == nil {
                clearProgress = to
            } else {
                clearAnimation.start(.sidebar) { [weak self] progress in
                    self?.clearProgress = from + (to - from) * progress
                    self?.needsLayout = true
                }
            }
        }
        button.tooltipTitle = descriptor.helpTitle
        button.tooltipShortcut = descriptor.shortcut
        if self.includesActive != includesActive {
            self.includesActive = includesActive
            let from = indicatorProgress
            let to = includesActive ? 1.0 : 0.0
            indicatorDrops = includesActive
            if window == nil {
                setIndicatorProgress(to)
            } else {
                indicatorAnimation.start(includesActive ? .clearArrowDrop : .sidebar) { [weak self] progress in
                    self?.setIndicatorProgress(from + (to - from) * progress)
                }
            }
        }
        title.textColor = button.isHovered
            ? BrowserChromeColors.secondaryText
            : BrowserChromeColors.sidebarClearButtonForeground
        indicator.contentTintColor = title.textColor
        needsLayout = true
    }

    /// The arrow fades and slides in as the title moves aside for it.
    private func setIndicatorProgress(_ progress: Double) {
        indicatorProgress = progress
        indicator.alphaValue = progress
        indicator.isHidden = progress == 0
        needsLayout = true
    }
}

// MARK: - BrowserNativeSidebarDragPreview

private final class BrowserNativeSidebarDragPreview: BrowserNativePressableView {
    // MARK: Private

    private let row = BrowserNativeSidebarRowNSView()
    private var renderedTab: BrowserChromeModel.Tab?
    private var renderedFolder: BrowserChromeModel.PinnedTabFolder?
    private var renderedSplit: [BrowserChromeModel.Tab]?
    private var renderedAsApp = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = BrowserChromeLayout.sidebarRowCornerRadius
        strokeWidth = 1
        // See-through, so the insertion line and the row under it still show.
        fillColor = BrowserChromeColors.solidBackground.withAlphaComponent(0.7)
        strokeColor = BrowserChromeColors.sidebarDropIndicator.withAlphaComponent(0.28)
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow?.shadowBlurRadius = BrowserChromeLayout.sidebarDragPreviewShadowRadius
        shadow?.shadowOffset = NSSize(width: 0, height: -BrowserChromeLayout.sidebarDragPreviewShadowY)
        addSubview(row)
        row.isInteractionEnabled = false
        permitsTooltip = false
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    // MARK: Internal

    override func hitTest(_ point: NSPoint) -> NSView? {
        onBeginDragSession == nil ? nil : super.hitTest(point)
    }

    override func layout() { super.layout()
        row.frame = bounds
    }

    func update(payload: BrowserSidebarDragPayload, snapshot: BrowserSidebarSnapshot, appTile: Bool) {
        switch payload.primary {
        case .tab(let id):
            if !appTile, let memberIDs = snapshot.splitMembers(ofTabID: id) {
                let members = memberIDs.compactMap { snapshot.tab(withID: $0) }
                guard renderedSplit != members else { return }
                renderedSplit = members
                renderedTab = nil
                renderedFolder = nil
                renderedAsApp = false
                row.update(
                    split: members,
                    focusedTabID: snapshot.selectedTabID,
                    selected: true,
                    icons: snapshot.tabIcons,
                    isResizing: false,
                )
            } else if let tab = snapshot.tab(withID: id) {
                guard renderedTab != tab || renderedAsApp != appTile else { return }
                renderedTab = tab
                renderedSplit = nil
                renderedFolder = nil
                renderedAsApp = appTile
                row.update(
                    tab: tab,
                    appTile: appTile,
                    selected: true,
                    isResizing: false,
                    closeDescriptor: BrowserCommands.archiveTab,
                    icon: snapshot.tabIcons[tab.id],
                )
            }
        case .folder(let id):
            if let folder = snapshot.pinnedTabFolder(withID: id) {
                guard renderedFolder != folder else { return }
                renderedFolder = folder
                renderedTab = nil
                renderedSplit = nil
                row.update(
                    folder: folder,
                    renaming: false,
                    indentLevel: 0,
                    dropTargeted: true,
                    isResizing: false,
                    resetID: 0,
                )
            }
        }
        row.isInteractionEnabled = false
        row.setAccessibilityElement(false)
        row.setAccessibilityIdentifier(nil)
        row.tooltipTitle = nil
        needsLayout = true
    }
}

// MARK: - BrowserDragOutsidePreview

/// What a dragged tab looks like past the sidebar: its row, or over a page
/// that will split, a dark card with its icon and title.
private final class BrowserDragOutsidePreview: NSView {
    // MARK: Internal

    static let cardSize = CGSize(width: 146, height: 249)
    /// A tab without a page picture, outside the window: the window it will open as.
    static let windowCardSize = CGSize(width: 180, height: 180)
    /// The page picture's width inside a 4 pt frame in the window's color.
    static let thumbnailWidth: CGFloat = 216
    static let thumbnailFrameWidth: CGFloat = 4

    override var isFlipped: Bool { true }

    private(set) var showsRow = true

    private(set) var showsThumbnail = false

    private var currentCardSize = BrowserDragOutsidePreview.cardSize
    private var iconCenterFraction: CGFloat = 0.42
    private var titleCenterFraction: CGFloat = 0.58

    // MARK: Private

    private let rowImage = NSImageView()
    private let card = BrowserDragCardSurface()
    private let favicon = BrowserFaviconNSView()
    private let thumbnail = NSImageView()
    private let title = NSTextField(labelWithString: "")

    var preferredSize: CGSize {
        if showsThumbnail, let size = thumbnail.image?.size, size.width > 0 {
            return CGSize(
                width: Self.thumbnailWidth + Self.thumbnailFrameWidth * 2,
                height: (Self.thumbnailWidth * size.height / size.width).rounded() + Self.thumbnailFrameWidth * 2,
            )
        }
        return showsRow ? rowImage.image?.size ?? .zero : currentCardSize
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        rowImage.imageScaling = .scaleNone
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        card.layer?.cornerRadius = 19
        card.layer?.cornerCurve = .continuous
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.cell?.truncatesLastVisibleLine = true
        card.addSubview(favicon)
        card.addSubview(title)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 10
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.borderWidth = Self.thumbnailFrameWidth
        addSubview(rowImage)
        addSubview(card)
        addSubview(thumbnail)
        card.isHidden = true
        thumbnail.isHidden = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        rowImage.frame = bounds
        card.frame = bounds
        thumbnail.frame = bounds
        var frameColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            frameColor = BrowserChromeColors.solidBackground.cgColor
        }
        thumbnail.layer?.borderColor = frameColor
        let icon: CGFloat = 16
        favicon.frame = CGRect(
            x: (bounds.width - icon) / 2,
            y: bounds.height * iconCenterFraction - icon / 2,
            width: icon,
            height: icon,
        )
        let titleHeight = title.sizeThatFits(CGSize(width: bounds.width - 24, height: 40)).height
        title.frame = CGRect(
            x: 12,
            y: bounds.height * titleCenterFraction - titleHeight / 2,
            width: bounds.width - 24,
            height: titleHeight,
        )
    }

    func showRow(_ image: NSImage) {
        rowImage.image = image
        show(row: true, card: false, thumbnail: false)
    }

    func showThumbnail(_ image: NSImage) {
        thumbnail.image = image
        show(row: false, card: false, thumbnail: true)
    }

    /// The card of a split pane, or with `asWindow` the window a tab without a
    /// page picture will open as.
    func showCard(for tab: BrowserChromeModel.Tab, asWindow: Bool = false) {
        currentCardSize = asWindow ? Self.windowCardSize : Self.cardSize
        iconCenterFraction = asWindow ? 0.383 : 0.42
        titleCenterFraction = asWindow ? 0.614 : 0.58
        card.layer?.cornerRadius = asWindow ? 20 : 19
        card.layer?.backgroundColor = NSColor(white: 0.01, alpha: asWindow ? 0.92 : 1).cgColor
        title.font = .systemFont(ofSize: asWindow ? 14 : 13, weight: asWindow ? .bold : .semibold)
        title.stringValue = tab.displayTitle
        favicon.update(url: tab.faviconURLString.flatMap(URL.init(string:)), pageURLString: tab.urlString)
        show(row: false, card: true, thumbnail: false)
    }

    private func show(row: Bool, card showsCard: Bool, thumbnail showsPicture: Bool) {
        showsRow = row
        showsThumbnail = showsPicture
        rowImage.isHidden = !row
        card.isHidden = !showsCard
        thumbnail.isHidden = !showsPicture
        needsLayout = true
    }
}

// MARK: - BrowserDragCardSurface

private final class BrowserDragCardSurface: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserSidebarLinkDrop

/// Links a drag carries for the sidebar: web addresses and files, or a
/// dragged text that is a web address.
enum BrowserSidebarLinkDrop {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let urls = objects.filter { url in
            ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
        }
        if !urls.isEmpty {
            return urls
        }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false
        else { return [] }
        return [url]
    }
}

// MARK: - BrowserSidebarLibraryButtonHosting

/// The footer that holds the Library button, whose hover shows the downloads tray.
@MainActor protocol BrowserSidebarLibraryButtonHosting: AnyObject {
    var onLibraryHoverChanged: (Bool) -> Void { get set }
    /// In the footer's own coordinates.
    var libraryButtonFrame: NSRect { get }
}

// MARK: - BrowserDownloadsTrayView

/// The newest files of the download folder, over the bottom of the sidebar while
/// the Library button is hovered: oldest at the top, the newest by the button.
final class BrowserDownloadsTrayView: NSView {
    struct Entry {
        let url: URL
        let date: Date
        /// A running download's progress, in place of when it arrived.
        var progress: String?
        /// How much of it has arrived, from 0 to 1, when the size is known.
        var fraction: Double?
        var title: String?
        /// Stops a running download.
        var onCancel: (() -> Void)?
        /// A canceled download: no file to show, open or reveal.
        var isCanceled = false
    }

    static let rowHeight: CGFloat = 56
    static let maximumEntries = 4

    override var isFlipped: Bool { true }

    private(set) var isHovered = false
    var onHoverChanged: () -> Void = {}

    private var rows = [BrowserDownloadsTrayRow]()

    private var tracking: NSTrackingArea?

    var preferredHeight: CGFloat { CGFloat(rows.count) * Self.rowHeight }

    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        onHoverChanged()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        onHoverChanged()
    }

    /// Files and canceled downloads by date, then the running downloads, newest last.
    /// A running download's file is already on disk; it shows once, with its progress.
    static func merged(files: [Entry], canceled: [Entry], running: [Entry]) -> [Entry] {
        let runningPaths = Set(running.map(\.url.standardizedFileURL.path))
        let settled = (files.filter { !runningPaths.contains($0.url.standardizedFileURL.path) } + canceled)
            .sorted { $0.date < $1.date }
        return Array((settled + running).suffix(maximumEntries))
    }

    /// The newest visible items of `directory`, newest last; unfinished downloads are left out.
    static func recentEntries(in directory: URL, limit: Int = maximumEntries) -> [Entry] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        )) ?? []
        let entries = urls.compactMap { url -> Entry? in
            guard !["crdownload", "download"].contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let date = values?.addedToDirectoryDate ?? values?.creationDate else { return nil }
            return Entry(url: url, date: date)
        }
        return Array(entries.sorted { $0.date > $1.date }.prefix(limit).reversed())
    }

    /// New progress for the same rows, without rebuilding them under the pointer.
    func refresh(_ entries: [Entry]) {
        guard entries.map(\.url) == rows.map(\.entry.url) else {
            show(entries)
            return
        }
        for (row, entry) in zip(rows, entries) {
            row.update(entry)
        }
    }

    func show(_ entries: [Entry]) {
        for row in rows {
            row.removeFromSuperview()
        }
        rows = entries.map { entry in
            let row = BrowserDownloadsTrayRow(entry: entry)
            addSubview(row)
            return row
        }
        needsLayout = true
    }
}

// MARK: - BrowserDownloadsTrayRow

/// A file's icon, name and when it arrived; a click opens it.
private final class BrowserDownloadsTrayRow: NSView {
    override var isFlipped: Bool { true }

    private(set) var entry: BrowserDownloadsTrayView.Entry

    private let highlight = BrowserNativeSurface()
    private let icon = NSImageView()
    private let ring = BrowserDownloadsTrayProgressRing()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let cancelButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.downloadsCancelAction,
        style: .sidebarClose,
        action: {},
    )
    private var tracking: NSTrackingArea?

    init(entry: BrowserDownloadsTrayView.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        highlight.cornerRadius = 10
        highlight.strokeWidth = 0
        highlight.fillColor = BrowserChromeColors.rowHover
        highlight.isHidden = true
        icon.image = entry.progress == nil
            ? NSWorkspace.shared.icon(forFile: entry.url.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.url.pathExtension) ?? .data)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = entry.title ?? entry.url.lastPathComponent
        title.font = .systemFont(ofSize: 14)
        title.textColor = BrowserChromeColors.primaryText
        title.lineBreakMode = .byTruncatingTail
        detail.stringValue = entry.progress
            ?? RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date())
        cancelButton.isHidden = entry.onCancel == nil
        // A running download is a ring that fills, with an arrow, in place of its file's icon.
        ring.isHidden = entry.progress == nil || entry.isCanceled
        icon.isHidden = entry.progress != nil
        ring.fraction = entry.fraction ?? 0
        cancelButton.onAction = { [entry] in entry.onCancel?() }
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = BrowserChromeColors.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        for view in [highlight, icon, ring, title, detail, cancelButton] as [NSView] {
            addSubview(view)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.stringValue)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 4, dy: 2)
        icon.frame = NSRect(x: 9, y: (bounds.height - 38) / 2, width: 38, height: 38)
        ring.frame = NSRect(x: 14, y: (bounds.height - 28) / 2, width: 28, height: 28)
        let textX: CGFloat = 60
        let size = cancelButton.intrinsicContentSize.width > 0 ? BrowserChromeLayout.sidebarCloseButtonSize : 24
        cancelButton.frame = NSRect(
            x: bounds.width - 12 - size,
            y: (bounds.height - size) / 2,
            width: size,
            height: size,
        )
        let width = max((cancelButton.isHidden ? bounds.width - 10 : cancelButton.frame.minX - 6) - textX, 0)
        title.frame = NSRect(x: textX, y: bounds.height / 2 - 18, width: width, height: 18)
        detail.frame = NSRect(x: textX, y: bounds.height / 2 + 1, width: width, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) { highlight.isHidden = false }
    override func mouseExited(with _: NSEvent) { highlight.isHidden = true }
    override func mouseUp(with _: NSEvent) {
        guard entry.progress == nil else { return }
        NSWorkspace.shared.open(entry.url)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        guard !entry.isCanceled else { return nil }
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(BrowserStrings.libraryRevealInFinder, to: menu) { [entry] in
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        return menu
    }

    func update(_ entry: BrowserDownloadsTrayView.Entry) {
        self.entry = entry
        if let progress = entry.progress {
            detail.stringValue = progress
        }
        ring.fraction = entry.fraction ?? 0
    }
}

// MARK: - BrowserDownloadsTrayProgressRing

/// A running download in the tray: an accent ring that fills with it, around a down arrow.
private final class BrowserDownloadsTrayProgressRing: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        let lineWidth: CGFloat = 2.5
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setStroke()
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        track.stroke()
        if fraction > 0 {
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: rect.width / 2,
                startAngle: 90,
                endAngle: 90 - 360 * CGFloat(min(fraction, 1)),
                clockwise: true,
            )
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
        }
        let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        if let arrow {
            let tinted = NSImage(size: arrow.size, flipped: false) { rect in
                arrow.draw(in: rect)
                NSColor.controlAccentColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(
                x: bounds.midX - arrow.size.width / 2,
                y: bounds.midY - arrow.size.height / 2,
                width: arrow.size.width,
                height: arrow.size.height,
            ))
        }
    }
}
