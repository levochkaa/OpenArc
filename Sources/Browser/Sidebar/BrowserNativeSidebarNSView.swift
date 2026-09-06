import AppKit
import Combine
import QuartzCore

// MARK: - BrowserNativeSidebarNSView

/// AppKit owns sidebar layout, row identity, scrolling, selection, rename editors and drag/drop.
/// Header and footer are injected while the remaining toolbar/popover adapters are migrated.
final class BrowserNativeSidebarNSView: NSView {
    // MARK: Lifecycle

    init(state: BrowserNativeSidebarState, header: NSView, footer: NSView) {
        self.state = state
        self.header = header
        self.footer = footer
        super.init(frame: .zero)
        setAccessibilityIdentifier("browser.sidebar")
        addSubview(content)
        for view in [header, appGrid, pagerClip, footer, bottomDivider, dragIndicator, dragPreview, scrollObserver] {
            content.addSubview(view)
        }
        pagerClip.addSubview(pagesContainer)
        pagerClip.wantsLayer = true
        pagerClip.layer?.masksToBounds = true
        bottomDivider.strokeWidth = 0
        bottomDivider.fillColor = BrowserChromeColors.sidebarTopChromeDivider
        dragIndicator.strokeWidth = 0
        dragIndicator.fillColor = BrowserChromeColors.sidebarDropIndicator
        dragIndicator.cornerRadius = BrowserChromeLayout.sidebarDropIndicatorThickness / 2
        dragIndicator.isHidden = true
        dragPreview.isHidden = true
        content.onEmptyClick = { [weak state] in state?.dismissRenamingIfNeeded() }
        content.permitsWindowDrag = { [weak state] in state?.isDraggingSidebarItem == false }
        appGrid.onEmptyClick = content.onEmptyClick
        appGrid.permitsWindowDrag = content.permitsWindowDrag
        state.onChange = { [weak self] animated in self?.refresh(animated: animated) }
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

    // MARK: Internal

    override var isFlipped: Bool { true }

    let state: BrowserNativeSidebarState
    let header: NSView
    let footer: NSView
    var headerHeight: CGFloat = BrowserChromeLayout.chromeButtonSize
    var footerHeight: CGFloat = BrowserChromeLayout.chromeButtonSize
    var isCommandBarPresented = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if window == nil {
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
            owner: self
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with _: NSEvent) {
        if !state.isSidebarResizing {
            state.isSidebarHovered = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        if !state.isSidebarResizing {
            state.isSidebarHovered = false
            state.isClearButtonHovered = false
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

    func refresh(animated: Bool = false) {
        let snapshot = renderedSnapshot
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
            appTiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        for tab in appTabs {
            let tile = appTiles[tab.id] ?? BrowserNativeSidebarRowNSView()
            if appTiles[tab.id] == nil {
                appTiles[tab.id] = tile
                appGrid.addSubview(tile)
            }
            configure(row: tile, tab: tab, section: .app, indent: 0)
        }
        scrollObserver.isEnabled = snapshot.spaces.count > 1 && !state.isSidebarResizing && !state.isDraggingSidebarItem
        bottomDivider.alphaValue = state.isBottomChromeDividerVisible(in: snapshot) ? 1 : 0
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BrowserChromeLayout.sidebarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layoutContent(animated: true)
            }
        } else {
            layoutContent(animated: false)
        }
        synchronizeGeometry()
        updateDragPreview()
    }

    // MARK: Private

    private let content = BrowserNativeSidebarBackground()
    private let appGrid = BrowserNativeSidebarBackground()
    private let pagerClip = BrowserNativeSurface()
    private let pagesContainer = BrowserNativeSurface()
    private let bottomDivider = BrowserNativeSurface()
    private let dragIndicator = BrowserNativeNoninteractiveSurface()
    private let dragPreview = BrowserNativeSidebarDragPreview()
    private let scrollObserver = BrowserSpacePagerScrollNSView()
    private var pages = [String: BrowserNativeSidebarPage]()
    private var appTiles = [String: BrowserNativeSidebarRowNSView]()
    private var tracking: NSTrackingArea?
    private var clickMonitor: Any?
    private var isLayingOut = false

    private var renderedSnapshot: BrowserSidebarSnapshot { state.renderedSnapshot(for: state.snapshot) }

    private func layoutContent(animated: Bool) {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let inset = BrowserChromeLayout.sidebarOuterPadding
        content.frame = NSRect(
            x: inset,
            y: inset,
            width: max(bounds.width - inset * 2, 0),
            height: max(bounds.height - inset * 2, 0)
        )
        let width = max(content.bounds.width, 0)
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        let appTabs = renderedSnapshot.appTabs
        let showsApps = state.model.supportsAppTabs && (!appTabs.isEmpty || state.draggedTabID != nil)
        let appLayout = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
        let appHeight = showsApps
            ? max(
                appLayout.height(for: appTabs.count, availableWidth: width),
                BrowserChromeLayout.sidebarEmptySectionDropZoneHeight
            )
            : 0
        appGrid.isHidden = !showsApps
        appGrid.frame = NSRect(
            x: 0,
            y: header.frame.maxY + BrowserChromeLayout.sidebarSectionSpacing,
            width: width,
            height: appHeight
        )
        let appFrames = appLayout.frames(for: appTabs.count, availableWidth: width)
        for (index, tab) in appTabs.enumerated() where appFrames.indices.contains(index) {
            if let tile = appTiles[tab.id] {
                setFrame(appFrames[index], of: tile, animated: animated)
            }
        }
        let top = (showsApps ? appGrid.frame.maxY : header.frame.maxY) + BrowserChromeLayout.sidebarListSpacing
        footer.frame = NSRect(
            x: 0,
            y: max(content.bounds.height - footerHeight, top),
            width: width,
            height: footerHeight
        )
        bottomDivider.frame = NSRect(
            x: 0,
            y: footer.frame.minY - BrowserChromeLayout.sidebarBottomChromeTopSpacing - 1,
            width: width,
            height: 1
        )
        pagerClip.frame = NSRect(x: 0, y: top, width: width, height: max(bottomDivider.frame.minY - top, 0))
        scrollObserver.frame = pagerClip.frame
        let index = state.selectedSpaceIndex(in: state.snapshot) ?? 0
        let x = state.spacePagerOffset(selectedIndex: index, pageWidth: width)
        setFrame(
            NSRect(x: x, y: 0, width: width * CGFloat(state.snapshot.spaces.count), height: pagerClip.bounds.height),
            of: pagesContainer,
            animated: animated
        )
        for page in pages.values {
            page.frame = NSRect(x: CGFloat(page.index) * width, y: 0, width: width, height: pagerClip.bounds.height)
            page.layoutRows(animated: animated)
        }
    }

    private func setFrame(_ rect: NSRect, of view: NSView, animated: Bool) {
        if animated {
            view.animator().frame = rect
        } else {
            view.frame = rect
        }
    }

    private func configure(
        page: BrowserNativeSidebarPage,
        space: BrowserChromeModel.Space,
        snapshot: BrowserSidebarSnapshot
    ) {
        let state = state
        let model = state.model
        page.document.menuProvider = { [weak self] in self?.spaceMenu(space) ?? NSMenu() }
        page.header.isHidden = !model.supportsSpaces
        page.header.update(
            space: space,
            renaming: state.renamingSpaceID == space.id,
            collapsed: snapshot.isPinnedSectionCollapsed(in: space.id),
            hasPinnedTabs: !snapshot.spacePinnedTabs(in: space.id).isEmpty,
            dropTargeted: state.isSpaceHeaderDropTarget(spaceID: space.id),
            isResizing: state.isSidebarResizing,
            resetID: state.tabRowInteractionResetID
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

        let pinned = snapshot.spacePinnedTabs(in: space.id)
        let temporary = snapshot.temporaryTabs(in: space.id)
        let pinnedRows = snapshot.visiblePinnedRows(
            in: space.id,
            revealedTabIDsByFolderID: state.revealedPinnedFolderTabIDsByFolderID
        )
        var entries = [BrowserNativeSidebarPage.Entry]()
        let collapsed = model.supportsSpaces && snapshot.isPinnedSectionCollapsed(in: space.id)
        if !collapsed {
            if pinned.isEmpty, state.draggedTabID != nil {
                entries.append(.empty(.spacePinned))
            }
            for row in pinnedRows where !pinned.isEmpty {
                switch row {
                case .tab(let tabRow):
                    entries.append(.tab(
                        tabRow.tab,
                        section: .spacePinned,
                        index: tabRow.sectionIndex,
                        folderID: tabRow.pinnedFolderID,
                        folderChildIndex: tabRow.folderChildIndex,
                        indent: tabRow.depth
                    ))
                case .folder(let folder): entries.append(.folder(folder))
                }
            }
        }
        if !pinned.isEmpty {
            entries.append(.divider)
        }
        if model.isIncognito {
            entries.append(.incognito)
        }
        entries.append(.newTab)
        if temporary.isEmpty, state.draggedTabID != nil {
            entries.append(.empty(.temporary))
        }
        entries += temporary.enumerated().map { .tab(
            $0.element,
            section: .temporary,
            index: $0.offset,
            folderID: nil,
            folderChildIndex: nil,
            indent: 0
        ) }
        page.entries = entries
        let ids = Set(entries.map(\.id))
        for id in Set(page.rows.keys).subtracting(ids) {
            page.rows.removeValue(forKey: id)?.removeFromSuperview()
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
                    resetID: state.tabRowInteractionResetID
                )
                row.alphaValue = state.draggedPinnedFolderID == folder.id ? 0.35 : 1
                row.onToggle = { [weak state] in
                    guard let state else { return }
                    state.dismissRenamingIfNeeded()
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
                row.menuProvider = { [weak row] in BrowserNativeMenus.folder(
                    folder,
                    onRename: { row?.onBeginRename() },
                    onChangeIcon: { model.setIcon($0, forPinnedTabFolderID: folder.id) }
                ) }
                row.dragCoordinateView = content
                row
                    .onDragChanged = { [weak state] value in
                        state?.updatePinnedFolderDrag(for: folder.id, value: value)
                    }
                row.onDragEnded = { [weak state] value in state?.finishPinnedFolderDrag(for: folder.id, value: value) }
            case .newTab:
                let row = page.row(for: entry.id)
                row.updateNewTab(
                    isPresented: isCommandBarPresented,
                    isResizing: state.isSidebarResizing,
                    descriptor: model.shortcutStore.descriptor(for: .newTab)
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
                    descriptor: model.shortcutStore.descriptor(for: .clearTemporaryTabs)
                )
                page.divider.onClear = { [weak state] in state?.clearTemporaryTabs(in: space.id) }
                page.divider.isHidden = false
            case .empty, .incognito: break
            }
        }
        page.divider.isHidden = !entries.contains {
            if case .divider = $0 {
                return true
            }
            return false
        }
        page.incognito.isHidden = !model.isIncognito
        page.scroll.isScrollingEnabled = !state.isSpacePagerDragging
    }

    private func configure(
        row: BrowserNativeSidebarRowNSView,
        tab: BrowserChromeModel.Tab,
        section: BrowserSidebarTabSection,
        indent: Int
    ) {
        let state = state
        let model = state.model
        let isApp = section == .app
        let selected = state.snapshot.selectedTabID == tab.id && (isApp || !isCommandBarPresented)
        row.update(
            tab: tab,
            appTile: isApp,
            selected: selected,
            multiSelected: state.selectedPinnedTabIDs.contains(tab.id),
            renaming: state.renamingTabID == tab.id,
            indentLevel: indent,
            isResizing: state.isSidebarResizing,
            resetID: state.tabRowInteractionResetID,
            closeDescriptor: model.shortcutStore.descriptor(for: .archiveTab)
        )
        row.alphaValue = state.draggedTabIDs.contains(tab.id) ? 0 : 1
        row.onSelect = { [weak state] in
            guard let state, state.suppressedTabSelectionAfterDragID != tab.id else { return }
            if state.renamingTabID != tab.id {
                state.dismissRenamingIfNeeded()
            }
            state.handleSidebarTabSelection(tab, in: section)
        }
        row.onBeginRename = { [weak state] in
            if isApp {
                if let title = BrowserNativeMenus.prompt(
                    title: BrowserStrings.tabRenamePromptTitle,
                    defaultValue: tab.userTitleOverride ?? tab.displayTitle
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
        row.onDragChanged = { [weak state] value in state?.updateTabDrag(for: tab.id, value: value) }
        row.onDragEnded = { [weak state] value in state?.finishTabDrag(for: tab.id, value: value) }
    }

    private func tabMenu(
        _ tab: BrowserChromeModel.Tab,
        section: BrowserSidebarTabSection,
        row: BrowserNativeSidebarRowNSView
    ) -> NSMenu {
        let model = state.model
        let state = state
        let selected = state.snapshot.selectedTabID == tab.id && (section == .app || !isCommandBarPresented)
        let menu = BrowserNativeMenus.menu()
        let copy = model.shortcutStore.descriptor(for: .copyLink)
        let close = model.shortcutStore.descriptor(for: .archiveTab)
        BrowserNativeMenus
            .add(copy.menuTitle, to: menu, shortcut: selected ? copy.shortcut : nil) {
                _ = model.copyTabLink(forTabID: tab.id)
            }
        BrowserNativeMenus.share(
            items: tab.pageURL.map { [$0] } ?? [NSString(string: tab.urlString)],
            subject: tab.displayTitle,
            in: menu
        )
        let folderIDs = state.pinnedTabFolderCreationTabIDs(fromTabID: tab.id, in: section)
        if !folderIDs.isEmpty {
            BrowserNativeMenus
                .add(BrowserStrings.pinnedTabFolderNewAction, to: menu) { [weak state] in
                    state?.createPinnedTabFolder(containingTabIDs: folderIDs)
                }
        }
        BrowserNativeMenus.add(BrowserStrings.tabRenameAction, to: menu, action: row.onBeginRename)
        if tab.placement == .spacePinned {
            BrowserNativeMenus
                .add(BrowserStrings.pinnedTabReplaceURLWithCurrentAction, to: menu) {
                    _ = model.replacePinnedURLWithCurrent(forTabID: tab.id)
                }
            BrowserNativeMenus.add(BrowserStrings.pinnedTabEditURLAction, to: menu) {
                if let url = BrowserNativeMenus.prompt(
                    title: BrowserStrings.pinnedTabEditURLPromptTitle,
                    defaultValue: tab.pinnedURLString ?? tab.urlString
                ) {
                    _ = model.setPinnedURLString(url, forTabID: tab.id)
                }
            }
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            section == .app ? BrowserStrings.tabCloseAction : close.menuTitle,
            to: menu,
            shortcut: selected
                ? close.shortcut
                : nil,
            action: row.onClose
        )
        if section == .app {
            BrowserNativeMenus
                .add(BrowserStrings.appTabRemoveFavoriteAction, to: menu) { [weak state] in
                    state?.withSidebarAnimation { model.removeAppTabFavorite(id: tab.id) }
                }
        } else {
            BrowserNativeMenus.add(
                BrowserStrings.tabArchiveTabsBelowAction,
                to: menu,
                enabled: state.snapshot.archivableTabIDs.contains(tab.id)
            ) { [weak state] in
                state?.renamingTabID = nil
                state?.withSidebarAnimation { model.closeTabsBelow(id: tab.id) }
            }
        }
        return menu
    }

    private func spaceMenu(_ space: BrowserChromeModel.Space) -> NSMenu {
        let state = state
        let model = state.model
        guard model.supportsSpaces else { return NSMenu() }
        return BrowserNativeMenus.space(
            space,
            canDelete: state.snapshot.spaces.count > 1,
            onRename: { [weak state] in state?.clearPinnedTabSelection()
                state?.beginRenamingSpace(id: space.id)
            },
            onChangeIcon: { model.setIcon($0, forSpaceID: space.id) },
            onDelete: { [weak state] in state?.dismissRenamingIfNeeded()
                state?.clearPinnedTabSelection()
                model.deleteSpace(id: space.id)
            }
        )
    }

    private func synchronizeGeometry() {
        guard !isLayingOut else { return }
        let snapshot = renderedSnapshot
        var rows = [String: BrowserSidebarTabRowFrame]()
        var folders = [BrowserSidebarPinnedFolderRowFrame]()
        var headers = [BrowserSidebarSpaceHeaderFrame]()
        var empty = [BrowserSidebarEmptySectionFrame]()
        for page in pages.values {
            if !page.header.isHidden {
                headers.append(.init(
                    spaceID: page.spaceID,
                    frame: page.header.convert(page.header.bounds, to: content)
                ))
            }
            for entry in page.entries {
                guard let frame = page.frames[entry.id] else { continue }
                let converted = page.document.convert(frame, to: content)
                switch entry {
                case .tab(let tab, let section, let index, let folderID, let childIndex, _):
                    rows[tab.id] = .init(
                        tabID: tab.id,
                        section: section,
                        sectionIndex: index,
                        spaceID: page.spaceID,
                        pinnedFolderID: folderID,
                        folderChildIndex: childIndex,
                        frame: converted
                    )
                case .folder(let folder):
                    let childInset = CGFloat(max(folder.depth + 1, 0)) * BrowserChromeLayout
                        .sidebarPinnedFolderTabIndent
                    folders.append(.init(
                        folderID: folder.folder.id,
                        firstSectionIndex: folder.firstSectionIndex,
                        afterSectionIndex: folder.afterSectionIndex,
                        childCount: folder.childCount,
                        spaceID: page.spaceID,
                        frame: converted,
                        childPreviewFrame: CGRect(
                            x: converted.minX + childInset,
                            y: converted.minY,
                            width: max(converted.width - childInset, 0),
                            height: converted.height
                        )
                    ))
                case .empty(let section): empty.append(.init(section: section, spaceID: page.spaceID, frame: converted))
                default: break
                }
            }
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
        state.pinnedFolderRowFrames = folders
        state.spaceHeaderFrames = headers
        state.setTabRowFrames(rows, for: snapshot)
        state.setEmptySectionFrames(empty, for: snapshot)
        let appFrames = Dictionary(uniqueKeysWithValues: snapshot.appTabs.enumerated().compactMap { index, tab -> (
            String,
            BrowserSidebarAppTabFrame
        )? in
            guard let tile = appTiles[tab.id] else { return nil }
            return (tab.id, .init(tabID: tab.id, sectionIndex: index, frame: tile.convert(tile.bounds, to: content)))
        })
        state.setAppTabFrames(appFrames, for: snapshot)
        state.setAppTabsContainerFrame(appGrid.isHidden ? nil : appGrid.frame, for: snapshot)
    }

    private func updateDragPreview() {
        dragIndicator.isHidden = state.dropProposal?.indicatorFrame == nil
        if let frame = state.dropProposal?.indicatorFrame {
            dragIndicator.frame = frame
        }
        if let preview = state.dragPreviewStore.preview, let tab = state.snapshot.tab(withID: preview.tabID) {
            dragPreview.update(tab: tab, size: preview.size)
            dragPreview.frame = NSRect(
                x: preview.center.x - preview.size.width / 2,
                y: preview.center.y - preview.size.height / 2,
                width: preview.size.width,
                height: preview.size.height
            )
            dragPreview.isHidden = false
        } else {
            dragPreview.isHidden = true
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

private final class BrowserNativeSidebarPage: NSView {
    // MARK: Lifecycle

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
            object: scroll.contentView
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

    // MARK: Internal

    enum Entry {
        case tab(
            BrowserChromeModel.Tab,
            section: BrowserSidebarTabSection,
            index: Int,
            folderID: String?,
            folderChildIndex: Int?,
            indent: Int
        )
        case folder(BrowserSidebarPinnedFolderRow)
        case newTab
        case divider
        case incognito
        case empty(BrowserSidebarTabSection)

        // MARK: Internal

        var id: String {
            switch self {
            case .tab(let tab, _, _, _, _, _): "tab:\(tab.id)"
            case .folder(let row): "folder:\(row.folder.id)"
            case .newTab: "new-tab"
            case .divider: "divider"
            case .incognito: "incognito"
            case .empty(let section): "empty:\(section)"
            }
        }

        var height: CGFloat {
            switch self {
            case .divider: BrowserChromeLayout.sidebarDividerHeight
            case .incognito: 18
            case .empty: 0
            default: BrowserChromeLayout.sidebarRowHeight
            }
        }
    }

    override var isFlipped: Bool { true }

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

    func row(for id: String) -> BrowserNativeSidebarRowNSView {
        if let existing = rows[id] {
            return existing
        }
        let row = BrowserNativeSidebarRowNSView()
        rows[id] = row
        document.addSubview(row)
        return row
    }

    func layoutRows(animated: Bool) {
        let headerHeight = header.isHidden
            ? 0
            : BrowserChromeLayout.sidebarRowHeight + BrowserChromeLayout.sidebarListSpacing
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: BrowserChromeLayout.sidebarRowHeight)
        scroll.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(bounds.height - headerHeight, 0))
        topDivider.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: 1)
        var y: CGFloat = 1
        frames = [:]
        for entry in entries {
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: entry.height)
            frames[entry.id] = frame
            let view: NSView? =
                switch entry {
                case .divider: divider
                case .incognito: incognito
                case .empty: nil
                default: rows[entry.id]
                }
            if let view {
                let rect: NSRect =
                    if case .incognito = entry {
                        frame.insetBy(
                            dx: BrowserChromeLayout.sidebarRowHorizontalPadding,
                            dy: 0
                        )
                    } else {
                        frame
                    }
                if animated {
                    view.animator().frame = rect
                } else {
                    view.frame = rect
                }
            }
            y += entry.height + BrowserChromeLayout.sidebarListSpacing
        }
        let height = max(y - BrowserChromeLayout.sidebarListSpacing + 1, scroll.contentSize.height)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        let origin = scroll.contentView.bounds.origin
        if origin.y > max(height - scroll.contentSize.height, 0) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(height - scroll.contentSize.height, 0)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: Private

    @objc private func scrolled() { onScroll() }
}

// MARK: - BrowserNativeNoninteractiveSurface

private final class BrowserNativeNoninteractiveSurface: BrowserNativeSurface {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

// MARK: - BrowserNativeSidebarClearDivider

private final class BrowserNativeSidebarClearDivider: NSView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.fillColor = BrowserChromeColors.sidebarDivider
        line.strokeWidth = 0
        addSubview(line)
        addSubview(button)
        button.addSubview(title)
        button.addSubview(indicator)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        indicator.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: 8,
                weight: .bold
            ))
        indicator.contentTintColor = BrowserChromeColors.secondaryText
        button.onClick = { [weak self] _ in self?.onClear() }
        button.onHoverChanged = { [weak self] hovered in self?.title.textColor = hovered
            ? BrowserChromeColors.secondaryText
            : BrowserChromeColors.sidebarClearButtonForeground
        }
        button.setAccessibilityLabel(BrowserStrings.sidebarClearTemporaryTabs)
        button.setAccessibilityIdentifier("browser.sidebar.clear-temporary")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    var onClear: () -> Void = {}

    override func layout() {
        super.layout()
        let textWidth = ceil(title.intrinsicContentSize.width)
        let indicatorWidth: CGFloat = includesActive ? 11 : 0
        let width = button.isHidden
            ? 0
            : textWidth + indicatorWidth + BrowserChromeLayout.sidebarClearButtonHorizontalPadding * 2
        button.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        title.frame = NSRect(
            x: BrowserChromeLayout.sidebarClearButtonHorizontalPadding + indicatorWidth,
            y: (bounds.height - 16) / 2,
            width: textWidth,
            height: 16
        )
        indicator.frame = NSRect(
            x: BrowserChromeLayout.sidebarClearButtonHorizontalPadding,
            y: (bounds.height - 8) / 2,
            width: 8,
            height: 8
        )
        line.frame = NSRect(x: 0, y: (bounds.height - 1) / 2, width: max(bounds.width - width, 0), height: 1)
    }

    func update(showsClear: Bool, includesActive: Bool, descriptor: BrowserCommandDescriptor) {
        button.isHidden = !showsClear
        button.tooltipTitle = descriptor.helpTitle
        button.tooltipShortcut = descriptor.shortcut
        self.includesActive = includesActive
        indicator.isHidden = !includesActive
        title.textColor = button.isHovered
            ? BrowserChromeColors.secondaryText
            : BrowserChromeColors.sidebarClearButtonForeground
        needsLayout = true
    }

    // MARK: Private

    private let line = BrowserNativeNoninteractiveSurface()
    private let button = BrowserNativePressableView()
    private let title = NSTextField(labelWithString: BrowserStrings.sidebarClearTemporaryTabs)
    private let indicator = NSImageView()
    private var includesActive = false
}

// MARK: - BrowserNativeSidebarDragPreview

private final class BrowserNativeSidebarDragPreview: BrowserNativeSurface {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = BrowserChromeLayout.sidebarRowCornerRadius
        fillColor = BrowserChromeColors.rowSelected
        strokeColor = BrowserChromeColors.sidebarDropIndicator.withAlphaComponent(0.28)
        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow?.shadowBlurRadius = BrowserChromeLayout.sidebarDragPreviewShadowRadius
        shadow?.shadowOffset = NSSize(width: 0, height: -BrowserChromeLayout.sidebarDragPreviewShadowY)
        addSubview(favicon)
        addSubview(title)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let size = isTile ? BrowserChromeLayout.appTabIconSize : BrowserChromeLayout.sidebarFaviconSize
        let x = isTile ? (bounds.width - size) / 2 : BrowserChromeLayout.sidebarRowHorizontalPadding
        favicon.frame = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        title.frame = NSRect(
            x: favicon.frame.maxX + BrowserChromeLayout.sidebarRowContentSpacing,
            y: (bounds.height - 17) / 2,
            width: max(
                bounds.width - favicon.frame.maxX - BrowserChromeLayout.sidebarRowContentSpacing - BrowserChromeLayout
                    .sidebarTabTrailingPadding,
                0
            ),
            height: 17
        )
    }

    func update(tab: BrowserChromeModel.Tab, size: NSSize) {
        title.stringValue = tab.displayTitle
        favicon.update(url: tab.faviconURL, pageURLString: tab.urlString)
        isTile = abs(size.height - BrowserChromeLayout.sidebarRowHeight) > 0.5
        title.isHidden = isTile
        needsLayout = true
    }

    // MARK: Private

    private let favicon = BrowserFaviconNSView()
    private let title = BrowserNativeControls.label("", size: 12.5, weight: .medium)
    private var isTile = false
}
