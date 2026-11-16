// BrowserSiteControlsNSView.swift

import AppKit
import Combine
import QuartzCore

// MARK: - BrowserSiteControlsNSView

final class BrowserSiteControlsNSView: NSView {
    // MARK: Internal

    enum Mode { case sidebar, toolbar }

    override var isFlipped: Bool { true }
    override var isHidden: Bool {
        didSet {
            if isHidden {
                closePopovers()
                resetCopyFeedback()
                publishURLFrame()
            }
        }
    }

    let model: BrowserChromeModel
    let mode: Mode
    let urlButton = BrowserNativeURLButton()
    let copyButton: BrowserNativeChromeButton
    let splitButton: BrowserNativeChromeButton
    let siteButton: BrowserNativeChromeButton
    var onURLFrameChange: (CGRect?) -> Void = { _ in }

    var isSidebarResizing = false {
        didSet {
            if isSidebarResizing {
                hovered = false
                closePopovers()
                urlButton.resetInteraction()
            }
            refreshHover()
        }
    }

    /// The actions show while the pointer is anywhere in the sidebar.
    var isSidebarHovered = false {
        didSet {
            if oldValue != isSidebarHovered { refreshHover() }
        }
    }

    // MARK: Private

    private let backButton = BrowserNativeChromeButton(
        symbol: "arrow.backward",
        title: BrowserStrings.navigationBack,
        pressEffect: .left,
        action: {},
    )
    private let forwardButton = BrowserNativeChromeButton(
        symbol: "arrow.forward",
        title: BrowserStrings.navigationForward,
        pressEffect: .right,
        action: {},
    )
    private lazy var reloadSymbol = BrowserReloadSymbolState { [weak self] in self?.refresh() }
    private let reloadButton = BrowserNativeChromeButton(
        symbol: "arrow.clockwise",
        title: BrowserStrings.navigationRefresh,
        pressEffect: .rotateClockwise,
        action: {},
    )
    private let extensionPopovers: BrowserNativeExtensionPopoverPresenter
    private var extensionButtons = [String: BrowserNativeExtensionButton]()
    private var extensionVisibilities = [String: BrowserNativeVisibilityAnimation]()
    private var pinned = [BrowserExtension]()
    /// Model changes refresh the view once per run loop pass.
    private lazy var coalescedRefresh = BrowserCoalescedRefresh { [weak self] in self?.refresh() }
    private var copyTask: Task<Void, Never>?
    private let copyVisibility = BrowserNativeVisibilityAnimation()
    private let siteVisibility = BrowserNativeVisibilityAnimation()
    private let splitVisibility = BrowserNativeVisibilityAnimation()
    private let actionAnimation = BrowserNativeAnimation()
    private var actionWidthTarget: CGFloat?
    private var didCopy = false
    private var commandButtons = [BrowserCommandID: BrowserNativeChromeButton]()
    private var toolbarOverlay: BrowserToolbarEditOverlay?
    private var customizePanel: BrowserToolbarCustomizePanel?

    private var hovered = false
    private var tracking: NSTrackingArea?
    private var lastReportedFrame: CGRect?
    private var frameUpdateScheduled = false

    private var showsSidebarActions: Bool {
        (hovered || isSidebarHovered || extensionPopovers.isPresented) && !isSidebarResizing && model
            .currentTab != nil
    }

    private var sidebarActionWidth: CGFloat {
        let count = CGFloat(pinned.count + 2)
        return count * BrowserChromeLayout.sidebarCurrentURLButtonSize + (count - 1) * BrowserChromeLayout
            .sidebarCurrentURLButtonSpacing
            + BrowserChromeLayout.sidebarCurrentURLButtonTrailingPadding
    }

    private var toolbarItems: [BrowserToolbarItem] { model.userPreferencesStore.toolbarConfiguration.items }

    init(model: BrowserChromeModel, mode: Mode) {
        self.model = model
        self.mode = mode
        self.copyButton = BrowserNativeChromeButton(
            symbol: "link",
            title: BrowserStrings.tabCopyURLAction,
            style: mode == .sidebar ? .currentURL : .chrome,
            pressEffect: .compress,
            action: {},
        )
        self.siteButton = BrowserNativeChromeButton(
            symbol: BrowserNativeBarGlyph.siteControls,
            title: BrowserStrings.siteControlCenterAction,
            style: mode == .sidebar ? .currentURL : .chrome,
            pressEffect: .compress,
            action: {},
        )
        self.splitButton = BrowserNativeChromeButton(
            symbol: "rectangle.split.2x1",
            title: BrowserStrings.splitViewButtonTitle,
            style: mode == .sidebar ? .currentURL : .chrome,
            pressEffect: .compress,
            action: {},
        )
        self.extensionPopovers = BrowserNativeExtensionPopoverPresenter(model: model)
        super.init(frame: .zero)
        splitButton.menuProvider = { [weak self] in self?.splitMenu() }
        for view in [urlButton, backButton, forwardButton, reloadButton, copyButton, splitButton, siteButton] {
            addSubview(view)
        }
        urlButton.isToolbar = mode == .toolbar
        urlButton.setAccessibilityIdentifier(mode == .toolbar ? "browser.site-toolbar.url" : "browser.sidebar.url")
        urlButton.onClick = { [weak model] _ in model?.presentCurrentPageCommandBar() }
        urlButton.onHoverChanged = { [weak self] _ in self?.refreshHover() }
        urlButton.menuProvider = { [weak self] in self?.urlMenu() ?? NSMenu() }
        copyButton.setAccessibilityIdentifier("browser.site.copy-url")
        siteButton.setAccessibilityIdentifier("browser.site.controls")
        splitButton.setAccessibilityIdentifier("browser.site.split-view")
        backButton.setAccessibilityIdentifier("browser.site.back")
        forwardButton.setAccessibilityIdentifier("browser.site.forward")
        reloadButton.setAccessibilityIdentifier("browser.site.reload")
        backButton.onAction = { [weak model] in model?.goBack() }
        forwardButton.onAction = { [weak model] in model?.goForward() }
        backButton.onSecondaryClick = { [weak self] in
            if let self { model.showNavigationList(goingBack: true, below: backButton) }
        }
        forwardButton.onSecondaryClick = { [weak self] in
            if let self { model.showNavigationList(goingBack: false, below: forwardButton) }
        }
        reloadButton.onAction = { [weak self] in self?.reloadOrStop() }
        copyButton.onAction = { [weak self] in self?.copyURL() }
        siteButton.onAction = { [weak self] in self?.showControlCenter() }
        splitButton.onAction = { [weak self] in self?.splitButtonPressed() }
        extensionPopovers.onPresentationChanged = { [weak self] in self?.refreshHover() }
        coalescedRefresh.observe([
            model.objectWillChange.eraseToAnyPublisher(),
            model.userPreferencesStore.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
            model.currentPageCommandBarModel.objectWillChange.eraseToAnyPublisher(),
        ])
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { copyTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshCustomization()
        if window == nil {
            closePopovers()
            resetCopyFeedback()
            hovered = false
        }
        publishURLFrame()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin)
        publishURLFrame()
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize)
        publishURLFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with _: NSEvent) {
        if !isSidebarResizing {
            hovered = true
            refreshHover()
        }
    }

    override func mouseMoved(with _: NSEvent) { refreshHover() }
    override func mouseExited(with _: NSEvent) { hovered = false
        refreshHover()
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .toolbar {
            window?.performDrag(with: event)
        }
    }

    override func menu(for _: NSEvent) -> NSMenu? { urlMenu() }

    override func layout() {
        super.layout()
        if mode == .sidebar {
            urlButton.frame = bounds
            let size = BrowserChromeLayout.sidebarCurrentURLButtonSize
            let spacing = BrowserChromeLayout.sidebarCurrentURLButtonSpacing
            siteButton.frame = NSRect(
                x: bounds.width - BrowserChromeLayout.sidebarCurrentURLButtonTrailingPadding - size,
                y: (bounds.height - size) / 2,
                width: size,
                height: size,
            )
            copyButton.frame = siteButton.frame.offsetBy(dx: -(size + spacing), dy: 0)
            for (index, browserExtension) in pinned.enumerated() {
                extensionButtons[browserExtension.id]?.frame = copyButton.frame.offsetBy(
                    dx: -CGFloat(pinned.count - index) * (size + spacing),
                    dy: 0,
                )
            }
        } else {
            layoutToolbarItems()
        }
        publishURLFrame()
    }

    func refresh() {
        let preferences = model.userPreferencesStore
        // A page another window took leaves the address empty, as a blank window has it.
        let tab = model.showsMovedPage ? nil : model.currentTab
        let display: String =
            if let tab {
                mode == .toolbar && preferences.siteToolbarShowsFullURL
                    ? BrowserURLDisplayFormatter.fullDisplayString(for: tab.urlString)
                    : BrowserURLDisplayFormatter.displayString(for: tab.urlString)
            } else {
                mode == .sidebar ? BrowserStrings.commandBarPlaceholder : BrowserStrings.newTabTitle
            }
        urlButton.update(title: display, isPlaceholder: tab == nil && mode == .sidebar)
        urlButton.isInteractionEnabled = tab != nil && !isSidebarResizing
        urlButton.tooltipTitle = mode == .sidebar
            ? tab.map { BrowserURLDisplayFormatter.fullDisplayString(for: $0.urlString) } ?? BrowserStrings.newTabTitle
            : nil
        if mode == .sidebar {
            backButton.isHidden = true
            forwardButton.isHidden = true
            reloadButton.isHidden = true
        }
        backButton.isEnabled = model.canGoBack
        forwardButton.isEnabled = model.canGoForward
        backButton.tooltipShortcut = model.shortcutStore.shortcut(for: .goBack)
        forwardButton.tooltipShortcut = model.shortcutStore.shortcut(for: .goForward)
        reloadSymbol.update(isLoading: model.canStopLoading)
        let showsStop = reloadSymbol.showsStop
        reloadButton.configureSymbol(
            showsStop ? "xmark" : "arrow.clockwise",
            title: showsStop
                ? BrowserStrings.navigationStopLoading
                : BrowserStrings.navigationRefresh,
        )
        reloadButton.tooltipShortcut = showsStop ? nil : model.shortcutStore.shortcut(for: .reload)
        reloadButton.pressEffect = showsStop ? .compress : .rotateClockwise
        reloadButton.isEnabled = model.canStopLoading || model.canReload
        copyButton.configureSymbol(didCopy ? "checkmark" : "link", title: BrowserStrings.tabCopyURLAction)
        copyButton.tooltipShortcut = model.shortcutStore.shortcut(for: .copyLink)
        let inSplit = model.selectedSplitGroup != nil
        splitButton.isSelected = inSplit
        splitButton.tooltipShortcut = inSplit ? nil : model.shortcutStore.shortcut(for: .addSplitView)
        let byID = Dictionary(uniqueKeysWithValues: model.browserExtensions.map { ($0.id, $0) })
        pinned = model.pinnedExtensionIDs.compactMap { id in byID[id].flatMap { $0.isEnabled ? $0 : nil } }
        for id in Set(extensionButtons.keys)
            .subtracting(pinned.map(\.id))
        {
            extensionButtons.removeValue(forKey: id)?.removeFromSuperview()
            extensionVisibilities.removeValue(forKey: id)
        }
        for browserExtension in pinned {
            let button = extensionButtons[browserExtension.id] ?? BrowserNativeExtensionButton(
                tile: false,
                sidebar: mode == .sidebar,
            )
            if extensionButtons[browserExtension.id] == nil {
                extensionButtons[browserExtension.id] = button
                addSubview(button)
            }
            button.update(browserExtension)
            button.onClick = { [weak self] _ in self?.openExtension(browserExtension.id) }
            button.menuProvider = { [weak self] in self?.extensionMenu(browserExtension) ?? NSMenu() }
        }
        extensionPopovers.refresh()
        refreshToolbarItems()
        refreshHover()
        needsLayout = true
    }

    func publishURLFrame() {
        guard !frameUpdateScheduled else { return }
        frameUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            frameUpdateScheduled = false
            let frame = window != nil && !isHiddenOrHasHiddenAncestor
                ? urlButton.convert(urlButton.bounds, to: nil)
                : nil
            guard frame != lastReportedFrame else { return }
            lastReportedFrame = frame
            onURLFrameChange(frame)
        }
    }

    func copyURL() {
        guard model.copySelectedTabLink() else { return }
        didCopy = true
        copyButton.configureSymbol("checkmark", title: BrowserStrings.tabCopyURLAction)
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                return
            }
            guard let self else { return }
            didCopy = false
            copyButton.configureSymbol("link", title: BrowserStrings.tabCopyURLAction)
        }
    }

    func urlMenu() -> NSMenu {
        let model = model
        let preferences = model.userPreferencesStore
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(
            BrowserStrings.tabCopyURLAction,
            to: menu,
            shortcut: model.shortcutStore.shortcut(for: .copyLink),
            enabled: model.currentTab != nil,
        ) { _ = model.copySelectedTabLink() }
        let tab = model.currentTab
        BrowserNativeMenus.share(
            items: tab?.pageURL.map { [$0] } ?? tab.map { [NSString(string: $0.urlString)] } ?? [],
            subject: tab?.displayTitle ?? BrowserStrings.newTabTitle,
            in: menu,
        )
        menu.items.last?.isEnabled = tab != nil
        BrowserNativeMenus.add(
            model.shortcutStore.descriptor(for: .captureArea).menuTitle,
            to: menu,
            enabled: tab != nil,
        ) {
            model.beginAreaCapture()
        }
        BrowserNativeMenus
            .add(BrowserStrings.siteCaptureFullPageAction, to: menu, enabled: tab != nil) {
                _ = model.captureFullPageSelectedTabToPasteboard()
            }
        BrowserNativeMenus.add(
            model.shortcutStore.descriptor(for: .capturePortrait).menuTitle,
            to: menu,
            enabled: tab != nil && model.canCaptureArea,
        ) {
            _ = model.beginPortraitCapture()
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            preferences.siteURLToolbarEnabled
                ? BrowserStrings.siteShowInSidebarAction
                : BrowserStrings.siteShowAsToolbarAction,
            to: menu,
        ) { preferences.siteURLToolbarEnabled.toggle() }
        if preferences.siteURLToolbarEnabled {
            BrowserNativeMenus.add(
                preferences.siteToolbarShowsFullURL
                    ? BrowserStrings.siteHideFullURLAction
                    : BrowserStrings.siteShowFullURLAction,
                to: menu,
                enabled: tab != nil,
            ) {
                preferences.siteToolbarShowsFullURL.toggle()
            }
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            preferences.bookmarksBarVisible
                ? BrowserStrings.bookmarksHideBarAction
                : BrowserStrings.settingsShowBookmarksBar,
            to: menu,
            shortcut: model.shortcutStore.shortcut(for: .toggleBookmarksBar),
        ) {
            preferences.bookmarksBarVisible.toggle()
        }
        if mode == .toolbar {
            BrowserNativeMenus.add(BrowserStrings.menuCustomizeToolbar, to: menu) { [weak model] in
                model?.beginToolbarCustomization()
            }
        }
        return menu
    }

    /// Split View Menu for the focused pane; outside a split it only
    /// offers Add Split View.
    func splitMenu() -> NSMenu {
        let model = model
        let shortcuts = model.shortcutStore
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(
            BrowserStrings.menuAddSplitView,
            to: menu,
            shortcut: shortcuts.shortcut(for: .addSplitView),
            enabled: model.canAddSplitView,
        ) { model.presentSplitViewCommandBar() }
        guard let group = model.selectedSplitGroup else { return menu }
        let vertical = group.orientation == .vertical
        BrowserNativeMenus.add(
            vertical ? BrowserStrings.splitMovePaneUp : BrowserStrings.splitMovePaneLeft,
            to: menu,
            enabled: model.canMoveSelectedSplitPane(by: -1),
        ) { _ = model.moveSelectedSplitPane(by: -1) }
        BrowserNativeMenus.add(
            vertical ? BrowserStrings.splitMovePaneDown : BrowserStrings.splitMovePaneRight,
            to: menu,
            enabled: model.canMoveSelectedSplitPane(by: 1),
        ) { _ = model.moveSelectedSplitPane(by: 1) }
        BrowserNativeMenus.add(
            vertical ? BrowserStrings.splitAddBottom : BrowserStrings.splitAddRight,
            to: menu,
            enabled: model.canAddSplitView,
        ) { model.presentSplitViewCommandBar(insertion: .after) }
        BrowserNativeMenus.add(
            vertical ? BrowserStrings.splitAddTop : BrowserStrings.splitAddLeft,
            to: menu,
            enabled: model.canAddSplitView,
        ) { model.presentSplitViewCommandBar(insertion: .before) }
        BrowserNativeMenus.add(
            model.isSelectedSplitPaneExpanded
                ? BrowserStrings.menuShowAllSplitPanes
                : BrowserStrings.menuExpandCurrentSplit,
            to: menu,
            shortcut: shortcuts.shortcut(for: .expandCurrentSplit),
        ) { _ = model.toggleExpandedSplitPane() }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            BrowserStrings.splitSeparateTabAction,
            to: menu,
            shortcut: shortcuts.shortcut(for: .separateTabFromSplit),
        ) { _ = model.separateSelectedTabFromSplit() }
        BrowserNativeMenus.add(
            model.splitOrientationToggleTitle,
            to: menu,
            shortcut: shortcuts.shortcut(for: .toggleSplitOrientation),
        ) { _ = model.toggleSelectedSplitOrientation() }
        BrowserNativeMenus.add(
            BrowserStrings.splitSeparateAllTabsAction,
            to: menu,
            shortcut: shortcuts.shortcut(for: .separateSplitView),
        ) { _ = model.separateSelectedSplitGroup() }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            BrowserStrings.menuCloseSplitPane,
            to: menu,
            shortcut: shortcuts.shortcut(for: .closeSplitPane),
        ) { _ = model.closeFocusedSplitPane() }
        return menu
    }

    /// From the menu bar: anchored to the site button, whichever extensions are pinned.
    func openExtensionFromMenu(id: String) {
        extensionPopovers.openExtension(
            id: id,
            relativeTo: extensionButtons[id] ??
                (isHiddenOrHasHiddenAncestor ? window?.contentView ?? self : siteButton),
            preferredEdge: mode == .toolbar ? .minY : .maxX,
        )
    }

    func closePopovers() { extensionPopovers.close() }

    /// Opens the site control center with its extensions, from the site
    /// button or from `anchor` while these controls are off screen.
    func showControlCenter(anchor: NSView? = nil, preferredEdge: NSRectEdge? = nil) {
        guard model.currentTab != nil, !isSidebarResizing else { return }
        // From the keyboard the button may still be hidden, and a popover needs a shown view.
        if anchor == nil {
            siteButton.isHidden = false
        }
        // It hangs below the button, in the sidebar as in the toolbar.
        extensionPopovers.showControlCenter(
            relativeTo: anchor ?? siteButton,
            preferredEdge: preferredEdge ?? .minY,
        )
    }

    /// Follows the toolbar, which may still be sliding into place.
    private func positionCustomizePanel() {
        guard let customizePanel, let window else { return }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        customizePanel.setFrameTopLeftPoint(NSPoint(
            x: frame.midX - customizePanel.frame.width / 2,
            y: frame.minY - 8,
        ))
    }

    /// The item's own view, for those that have one.
    private func view(for item: BrowserToolbarItem) -> NSView? {
        switch item {
        case .back: backButton
        case .forward: forwardButton
        case .reload: reloadButton
        case .copyLink: copyButton
        case .address: urlButton
        case .splitView: splitButton
        case .siteControls: siteButton
        case .command(let id): commandButtons[id]
        case .flexibleSpace, .pinnedExtensions: nil
        }
    }

    private func layoutToolbarItems() {
        let padding = BrowserChromeLayout.bookmarksBarHorizontalPadding
        let size = BrowserChromeLayout.chromeButtonSize
        let spacing = BrowserChromeLayout.chromeButtonSpacing
        let customizing = model.isCustomizingToolbar
        let items = toolbarItems.filter { customizing || $0 != .pinnedExtensions || !pinned.isEmpty }
        let extensionsWidth = max(
            CGFloat(pinned.count) * size + CGFloat(max(pinned.count - 1, 0)) * spacing,
            customizing
                ? size
                : 0,
        )
        let hasFlexible = items.contains(.flexibleSpace)
        let fixedWidth = items.reduce(CGFloat(0)) { total, item in
            switch item {
            case .address, .flexibleSpace: total
            case .pinnedExtensions: total + extensionsWidth
            default: total + size
            }
        }
        let gaps = spacing * CGFloat(max(items.count - 1, 0))
        let free = max(bounds.width - padding * 2 - fixedWidth - gaps, 0)
        // The address stops at its maximum only if a flexible space takes the rest.
        let addressWidth = hasFlexible ? min(free, BrowserChromeLayout.siteToolbarURLButtonMaximumWidth) : free
        let widths: [CGFloat?] = items.map { item in
            switch item {
            case .flexibleSpace: nil
            case .address: addressWidth
            case .pinnedExtensions: extensionsWidth
            default: size
            }
        }
        let spans = BrowserToolbarConfiguration.spans(
            for: widths,
            spacing: spacing,
            padding: padding,
            length: bounds.width,
            flexibleMinimum: customizing ? 28 : 0,
        )
        let y = (bounds.height - size) / 2
        for (item, span) in zip(items, spans) {
            let frame = NSRect(x: span.start, y: y, width: span.width, height: size)
            view(for: item)?.frame = frame
            if item == .pinnedExtensions {
                for (index, browserExtension) in pinned.enumerated() {
                    extensionButtons[browserExtension.id]?.frame = NSRect(
                        x: span.start + CGFloat(index) * (size + spacing),
                        y: y,
                        width: size,
                        height: size,
                    )
                }
            }
        }
        toolbarOverlay?.frame = bounds
        positionCustomizePanel()
        toolbarOverlay?.entries = zip(items, spans).map { item, span in
            (item, NSRect(x: span.start, y: y, width: span.width, height: size))
        }
    }

    private func refreshToolbarItems() {
        guard mode == .toolbar else { return }
        let items = toolbarItems
        backButton.isHidden = !items.contains(.back)
        forwardButton.isHidden = !items.contains(.forward)
        reloadButton.isHidden = !items.contains(.reload)
        urlButton.isHidden = !items.contains(.address)
        let commands = items.compactMap { item -> BrowserCommandID? in
            if case .command(let id) = item { return id }
            return nil
        }
        for id in Set(commandButtons.keys).subtracting(commands) {
            commandButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in commands {
            let descriptor = model.shortcutStore.descriptor(for: id)
            let button = commandButtons[id] ?? BrowserNativeChromeButton(
                symbol: id.commandBarSystemImageName,
                title: descriptor.menuTitle,
                style: .chrome,
                pressEffect: .compress,
                action: { [weak model] in model?.performToolbarCommand(id) },
            )
            if commandButtons[id] == nil {
                commandButtons[id] = button
                addSubview(button)
                button.setAccessibilityIdentifier("browser.toolbar.command.\(id.rawValue)")
            }
            if id == .toggleBookmark {
                let bookmarked = model.currentTab.map { model.isBookmarked(urlString: $0.urlString) } ?? false
                button.configureSymbol(bookmarked ? "star.fill" : "star", title: descriptor.menuTitle)
                button.isSelected = bookmarked
            }
            button.tooltipShortcut = model.shortcutStore.shortcut(for: id)
            button.isEnabled = model.isCommandBarActionAvailable(id)
        }
        refreshCustomization()
    }

    private func refreshCustomization() {
        guard model.isCustomizingToolbar, window != nil else {
            toolbarOverlay?.removeFromSuperview()
            toolbarOverlay = nil
            if let customizePanel {
                customizePanel.parent?.removeChildWindow(customizePanel)
                customizePanel.orderOut(nil)
                self.customizePanel = nil
            }
            return
        }
        let preferences = model.userPreferencesStore
        if toolbarOverlay == nil {
            let overlay = BrowserToolbarEditOverlay(frame: bounds)
            overlay.onMove = { from, to in preferences.toolbarConfiguration.move(from: from, to: to) }
            overlay.onInsert = { item, index in preferences.toolbarConfiguration.insert(item, at: index) }
            overlay.onRemove = { index in preferences.toolbarConfiguration.remove(at: index) }
            addSubview(overlay, positioned: .above, relativeTo: nil)
            toolbarOverlay = overlay
        } else if let toolbarOverlay, subviews.last !== toolbarOverlay {
            addSubview(toolbarOverlay, positioned: .above, relativeTo: nil)
        }
        if customizePanel == nil, let window {
            let panel = BrowserToolbarCustomizePanel(
                shortcutStore: model.shortcutStore,
                onReset: { preferences.toolbarConfiguration = .standard },
                onDone: { [weak model] in model?.endToolbarCustomization() },
                onRemove: { index in preferences.toolbarConfiguration.remove(at: index) },
            )
            panel.update(available: preferences.toolbarConfiguration.availableItems)
            window.addChildWindow(panel, ordered: .above)
            customizePanel = panel
            positionCustomizePanel()
        } else {
            customizePanel?.update(available: preferences.toolbarConfiguration.availableItems)
        }
    }

    private func refreshHover() {
        let sidebar = mode == .sidebar
        let show = !sidebar || showsSidebarActions
        let items = toolbarItems
        copyVisibility.setVisible(sidebar ? show : items.contains(.copyLink), view: copyButton, curve: .appearance)
        siteVisibility.setVisible(sidebar ? show : items.contains(.siteControls), view: siteButton, curve: .appearance)
        // The sidebar's address row has no Split View button; the toolbar does.
        splitVisibility.setVisible(!sidebar && items.contains(.splitView), view: splitButton, curve: .appearance)
        copyButton.isEnabled = model.currentTab != nil && !isSidebarResizing
        siteButton.isEnabled = model.currentTab != nil && !isSidebarResizing
        splitButton.isEnabled = (model.selectedSplitGroup != nil || model.canAddSplitView) && !isSidebarResizing
        for (id, button) in extensionButtons {
            let visibility = extensionVisibilities[id] ?? BrowserNativeVisibilityAnimation()
            extensionVisibilities[id] = visibility
            visibility.setVisible(sidebar ? show : items.contains(.pinnedExtensions), view: button, curve: .appearance)
            button.isInteractionEnabled = !isSidebarResizing
        }
        urlButton.isSearchPresented = sidebar && model.currentPageCommandBarModel.isPresented
        urlButton.externalHover = sidebar && hovered
        var actionHovered = false
        if let window, show {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            actionHovered = ([copyButton, splitButton, siteButton] as [NSView] + Array(extensionButtons.values))
                .contains { $0.frame.contains(point) }
        }
        urlButton.permitsTooltip = !actionHovered && !isSidebarResizing && !urlButton.isSearchPresented
        urlButton.refreshTooltip()
        updateAddressFade(sidebar: sidebar, showsActions: show)
        urlButton.interactionChanged()
        needsLayout = true
    }

    /// The address makes room for the actions at once, and takes it back only
    /// when they have faded out. The fade itself never moves on screen.
    private func updateAddressFade(sidebar: Bool, showsActions: Bool) {
        let resting = sidebar ? BrowserChromeLayout.sidebarCurrentURLRestingTrailingWidth : 0
        let target = sidebar && showsActions ? sidebarActionWidth : resting
        guard actionWidthTarget != target else { return }
        let isFirst = actionWidthTarget == nil
        actionWidthTarget = target
        actionAnimation.cancel()
        guard target == resting, !isFirst, window != nil, !isSidebarResizing else {
            urlButton.maskedTrailingWidth = target
            return
        }
        actionAnimation.start(.appearance, updates: { _ in }, completion: { [weak self] in
            self?.urlButton.maskedTrailingWidth = target
        })
    }

    private func resetCopyFeedback() {
        copyTask?.cancel()
        copyTask = nil
        didCopy = false
        copyButton.configureSymbol("link", title: BrowserStrings.tabCopyURLAction)
        hovered = false
        urlButton.resetInteraction()
    }

    private func reloadOrStop() {
        if reloadSymbol.showsStop {
            model.stopLoadingCurrentTab()
        } else {
            model.reloadCurrentTab()
        }
    }

    /// Outside a split the button adds one; inside, it opens the Split View Menu.
    private func splitButtonPressed() {
        guard !isSidebarResizing else { return }
        guard model.selectedSplitGroup != nil else {
            model.presentSplitViewCommandBar()
            return
        }
        splitMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: splitButton.bounds.maxY + 4), in: splitButton)
    }

    /// A pinned extension's popup points at its own button.
    private func openExtension(_ id: String) {
        extensionPopovers.openExtension(
            id: id,
            relativeTo: extensionButtons[id] ?? siteButton,
            preferredEdge: mode == .toolbar
                ? .minY
                : model.userPreferencesStore.sidebarPosition == .right ? .minX : .maxX,
        )
    }

    private func extensionMenu(_ browserExtension: BrowserExtension) -> NSMenu { extensionPopovers
        .menu(for: browserExtension)
    }
}

// MARK: - BrowserNativeURLButton

final class BrowserNativeURLButton: BrowserNativePressableView {
    // MARK: Internal

    var isToolbar = false
    var isSearchPresented = false
    var externalHover = false

    var maskedTrailingWidth: CGFloat = 0 { didSet { needsLayout = true } }

    // MARK: Private

    private let textContainer = NSView()
    private let label = BrowserNativeControls.label(
        "",
        size: 13,
        weight: .regular,
        color: BrowserChromeColors.currentURLText,
    )
    private let textMask = CAGradientLayer()
    private let placeholderIcon = NSImageView()
    private var isPlaceholder = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(textContainer)
        textContainer.addSubview(label)
        placeholderIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: BrowserChromeLayout.sidebarAddressPlaceholderIconPointSize,
                weight: .regular,
            ))
        placeholderIcon.imageScaling = .scaleNone
        placeholderIcon.contentTintColor = BrowserChromeColors.sidebarDimText
        placeholderIcon.isHidden = true
        textContainer.addSubview(placeholderIcon)
        textContainer.wantsLayer = true
        label.setAccessibilityElement(false)
        cornerRadius = BrowserChromeLayout.currentURLRowCornerRadius
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func interactionChanged() {
        super.interactionChanged()
        fillColor = isHovered || externalHover || isSearchPresented
            ? BrowserChromeColors.currentURLRowHover
            : BrowserChromeColors.currentURLRow
    }

    override func layout() {
        super.layout()
        textContainer.frame = bounds
        // The sidebar's address runs to the fade; the toolbar's is centered and truncated.
        let leading = isPlaceholder
            ? BrowserChromeLayout.sidebarAddressPlaceholderTextLeading
            : BrowserChromeLayout.sidebarCurrentURLTextLeading
        let iconSize = placeholderIcon.image?.size ?? .zero
        placeholderIcon.frame = NSRect(
            x: BrowserChromeLayout.sidebarAddressPlaceholderIconCenterX - iconSize.width / 2,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height,
        )
        label.frame = NSRect(
            x: leading,
            y: (bounds.height - 17) / 2,
            width: max(bounds.width - leading - (isToolbar ? leading : 0), 0),
            height: 17,
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if maskedTrailingWidth > 0, bounds.width > 0 {
            let fade = BrowserChromeLayout.sidebarCurrentURLOverlayFadeWidth
            let end = max(bounds.width - maskedTrailingWidth, 0) / bounds.width
            let start = max(bounds.width - maskedTrailingWidth - fade, 0) / bounds.width
            textMask.frame = textContainer.bounds
            textMask.startPoint = CGPoint(x: 0, y: 0.5)
            textMask.endPoint = CGPoint(x: 1, y: 0.5)
            textMask.colors = [
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
            ]
            textMask.locations = [0, NSNumber(value: Double(start)), NSNumber(value: Double(end)), 1]
            textContainer.layer?.mask = textMask
        } else {
            textContainer.layer?.mask = nil
        }
    }

    /// A placeholder shows the search prompt after a magnifier in a fainter color.
    func update(title: String, isPlaceholder: Bool = false) {
        if self.isPlaceholder != isPlaceholder {
            self.isPlaceholder = isPlaceholder
            placeholderIcon.isHidden = !isPlaceholder
            label.textColor = isPlaceholder
                ? BrowserChromeColors.commandBarPlaceholder
                : BrowserChromeColors
                    .currentURLText
            needsLayout = true
        }
        label.stringValue = title
        setAccessibilityLabel(title)
        label.alignment = isToolbar ? .center : .left
        label.lineBreakMode = isToolbar ? .byTruncatingMiddle : .byClipping
    }
}
