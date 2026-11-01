// BrowserNativeSidebarNSView.swift

import AppKit
import Combine
import QuartzCore

// MARK: - BrowserNativeSidebarNSView

/// AppKit owns sidebar layout, row identity, scrolling, selection, rename editors and drag/drop.
/// Header and footer share native chrome controls with the main toolbar.
final class BrowserNativeSidebarNSView: NSView {
    private static let spaceSelectionDelay: CFTimeInterval = 0.05
    private static let swipeReleaseDelay: CFTimeInterval = 0.05

    private static let leavingPageKey = "browser.page.leaving"

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
    /// The footer's Space icons, which accept dragged tabs.
    weak var spaceDock: BrowserSpaceDockNSView?

    /// Folder preview beside a collapsed folder row.
    let folderPreview = BrowserFolderPreviewCoordinator()

    private(set) var linkDropProposal: BrowserSidebarDropProposal?

    let miniPlayers = BrowserMiniPlayerStackNSView()

    // MARK: Private

    private let content = BrowserNativeSidebarBackground()
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
    private var splitPreviewRow: BrowserNativeSidebarRowNSView?
    private let scrollObserver = BrowserSpacePagerScrollNSView()
    private var pages = [String: BrowserNativeSidebarPage]()
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
        setAccessibilityIdentifier("browser.sidebar")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
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
        dragEvents.onTick = { [weak self] elapsed in self?.autoscrollDrag(elapsed: elapsed) }

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
        if let shown = folderPreview.shownFolderID,
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
                page.onScroll = { [weak self] in self?.synchronizeGeometry() }
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
        activateSingleDraggedTab(item)
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
        state.drag.updateDockTarget(spaceDock?.spaceID(atWindowPoint: point))
        state.drag.updatePointer(content.convert(point, from: nil))
        state.drag.updatePageDrop(atWindowPoint: point)
        if state.model.appTabs.isEmpty {
            needsLayout = true
        }
    }

    func finishDragging(atWindowPoint point: CGPoint) {
        guard state.drag.isDragging else { return }
        state.drag.updateDockTarget(spaceDock?.spaceID(atWindowPoint: point))
        state.drag.updatePageDrop(atWindowPoint: point)
        endDragging(at: content.convert(point, from: nil), cancelled: false)
    }

    func cancelDragging() {
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

    /// A single dragged tab activates when the gesture starts; the tab stays
    /// active even if the drop is a no-op. Explicit multi-selections and
    /// folders keep the current tab.
    /// A tab from another Space is never activated, so a drag cannot switch Spaces.
    private func activateSingleDraggedTab(_ item: BrowserSidebarItemID) {
        guard case .tab(let id) = item, !state.selectedSidebarTabIDs.contains(id),
              state.model.selectedTabID != id,
              state.snapshot.splitMembers(ofTabID: id)?.contains(state.model.selectedTabID ?? "") != true,
              let tab = state.model.tabs.first(where: { $0.id == id }),
              tab.placement == .app || tab.spaceID == state.model.selectedSpaceID
        else { return }
        state.clearSidebarTabSelection()
        state.sidebarTabSelectionAnchorID = id
        state.model.selectTab(id: id)
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
        emptyAppGuideLabel.frame = emptyAppGuide.bounds.insetBy(
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
        for id in Set(page.rows.keys).subtracting(ids) {
            page.rows.removeValue(forKey: id)?.removeAnimated()
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
            icon: state.snapshot.tabIcons[tab.id],
            developerHost: model.developerModeHost(forTabURLString: tab.urlString),
        )
        let muted = state.snapshot.mutedTabIDs.contains(tab.id)
        row.onToggleMute = { model.setTabMuted(!muted, id: tab.id) }
        let previewID = model.recentPagesPreviewID(forTab: tab)
        row.onHoverChanged = { [weak self, weak row] hovered in
            guard let self, let row, let previewID else { return }
            folderPreview.rowHoverChanged(folderID: previewID, row: row, hovered: hovered)
        }
        row.dragOpacity = state.draggedTabIDs.contains(tab.id) ? 0 : 1
        row.onSelect = { [weak state] in
            guard let state else { return }
            if state.renamingTabID != tab.id {
                state.dismissRenamingIfNeeded()
            }
            state.handleSidebarTabSelection(tab, in: section)
        }
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
            isResizing: state.isSidebarResizing,
            resetID: state.tabRowInteractionResetID,
        )
        row.dragOpacity = !state.draggedTabIDs.isEmpty && memberIDs.allSatisfy(state.draggedTabIDs.contains) ? 0 : 1
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
        BrowserNativeMenus.add(muted ? BrowserStrings.tabUnmuteAction : BrowserStrings.tabMuteAction, to: menu) {
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
                let above = model.temporaryTabIDsAbove(id: tab.id)
                BrowserNativeMenus.add(BrowserStrings.tabArchiveTabsAboveAction, to: menu, enabled: !above.isEmpty) {
                    [weak state] in
                    state?.renamingTabID = nil
                    state?.withSidebarAnimation { model.closeTemporaryTabsAbove(id: tab.id) }
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
            onSetProfile: { model.setProfile($0, forSpaceID: space.id) },
            onNewProfile: {
                if let created = model.profileDirectories?.createProfile() {
                    model.setProfile(created, forSpaceID: space.id)
                }
            },
            onManageSpaces: { model.openSpacesInLibrary() },
            canCreateFolder: model.canCreateFolder,
            onNewFolder: { model.createFolderInSelectedSpace() },
            onNewGitHubLiveFolder: { model.createGitHubLiveFolder(inSpaceID: space.id) },
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
        dragEvents.stop()
        guard let payload = state.drag.payload else { return }
        let from = dragPreview.frame
        state.drag.release(at: point, cancel: cancelled)
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
        ensureDestinationVisible(payload.primary)
        let target = restingFrame(for: payload.primary)
        let exact = isItemRendered(payload.primary)
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

    private func completeDragPresentation() {
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
        if let feedback = state.drag.proposal?.feedback ?? linkDropProposal?.feedback {
            switch feedback {
            case .line(let line) where state.drag.payload == nil: dragIndicator.update(line: line, occluding: nil)
            case .line: break
            case .folder(let id): highlightedDropRow = pages.values.compactMap { $0.rows["folder:\(id)"] }.first
            case .space(let id): highlightedDropRow = pages[id]?.header
            case .app: break
            }
        }
        highlightedDropRow?.setDropHighlighted(true)
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

    private func layoutDragPreview(size: CGSize) {
        let drag = state.drag
        dragPreview.frame = CGRect(
            x: drag.pointer.x - size.width * drag.anchor.x,
            y: drag.pointer.y - size.height * drag.anchor.y,
            width: size.width,
            height: size.height,
        )
        dragPreview.layoutSubtreeIfNeeded()
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
                        frame.insetBy(
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
        let origin = scroll.contentView.bounds.origin
        if origin.y > max(height - scroll.contentSize.height, 0) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(height - scroll.contentSize.height, 0)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func scrolled() { onScroll() }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.fillColor = BrowserChromeColors.sidebarDivider
        line.strokeWidth = 0
        addSubview(line)
        addSubview(button)
        button.addSubview(title)
        button.addSubview(indicator)
        title.font = .systemFont(ofSize: BrowserChromeLayout.sidebarClearFontSize, weight: .bold)
        indicator.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: 8,
                weight: .bold,
            ))
        indicator.contentTintColor = BrowserChromeColors.secondaryText
        button.onClick = { [weak self] _ in self?.onClear() }
        button.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            let from = title.textColor ?? .clear
            let to = hovered ? BrowserChromeColors.secondaryText : BrowserChromeColors.sidebarClearButtonForeground
            hoverAnimation.start(.easeInOut(0.12)) { [weak self] progress in
                self?.title.textColor = from.blended(withFraction: progress, of: to) ?? to
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
        let indicatorWidth: CGFloat = includesActive ? 11 : 0
        let width = textWidth + indicatorWidth + BrowserChromeLayout.sidebarClearButtonHorizontalPadding * 2
        button.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        title.frame = NSRect(
            x: BrowserChromeLayout.sidebarClearButtonHorizontalPadding + indicatorWidth,
            y: (bounds.height - 16) / 2,
            width: textWidth,
            height: 16,
        )
        indicator.frame = NSRect(
            x: BrowserChromeLayout.sidebarClearButtonHorizontalPadding,
            y: (bounds.height - 8) / 2,
            width: 8,
            height: 8,
        )
        line.frame = NSRect(
            x: BrowserChromeLayout.sidebarDividerInset,
            y: (bounds.height - BrowserChromeLayout.sidebarDividerThickness) / 2,
            width: max(bounds.width - BrowserChromeLayout.sidebarDividerInset * 2 - width * clearProgress, 0),
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
        self.includesActive = includesActive
        indicator.isHidden = !includesActive
        title.textColor = button.isHovered
            ? BrowserChromeColors.secondaryText
            : BrowserChromeColors.sidebarClearButtonForeground
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
        fillColor = BrowserChromeColors.solidBackground
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
