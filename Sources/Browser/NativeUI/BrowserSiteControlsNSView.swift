import AppKit
import Combine
import QuartzCore

// MARK: - BrowserSiteControlsNSView

final class BrowserSiteControlsNSView: NSView {
    // MARK: Lifecycle

    init(model: BrowserChromeModel, mode: Mode) {
        self.model = model
        self.mode = mode
        self.copyButton = BrowserNativeChromeButton(
            symbol: "link",
            title: BrowserStrings.tabCopyURLAction,
            style: mode == .sidebar ? .currentURL : .chrome,
            pressEffect: .compress,
            action: {}
        )
        self.siteButton = BrowserNativeChromeButton(
            symbol: "slider.horizontal.3",
            title: BrowserStrings.siteControlCenterAction,
            style: mode == .sidebar ? .currentURL : .chrome,
            pressEffect: .compress,
            action: {}
        )
        self.extensionPopovers = BrowserNativeExtensionPopoverPresenter(model: model)
        super.init(frame: .zero)
        for view in [urlButton, backButton, forwardButton, reloadButton, copyButton, siteButton] {
            addSubview(view)
        }
        urlButton.isToolbar = mode == .toolbar
        urlButton.setAccessibilityIdentifier(mode == .toolbar ? "browser.site-toolbar.url" : "browser.sidebar.url")
        urlButton.onClick = { [weak model] _ in model?.presentCurrentPageCommandBar() }
        urlButton.onHoverChanged = { [weak self] _ in self?.refreshHover() }
        urlButton.menuProvider = { [weak self] in self?.urlMenu() ?? NSMenu() }
        copyButton.setAccessibilityIdentifier("browser.site.copy-url")
        siteButton.setAccessibilityIdentifier("browser.site.controls")
        backButton.setAccessibilityIdentifier("browser.site.back")
        forwardButton.setAccessibilityIdentifier("browser.site.forward")
        reloadButton.setAccessibilityIdentifier("browser.site.reload")
        backButton.onAction = { [weak model] in model?.goBack() }
        forwardButton.onAction = { [weak model] in model?.goForward() }
        reloadButton.onAction = { [weak self] in self?.reloadOrStop() }
        copyButton.onAction = { [weak self] in self?.copyURL() }
        siteButton.onAction = { [weak self] in self?.showControlCenter() }
        extensionPopovers.onPresentationChanged = { [weak self] in self?.refreshHover() }
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            model.userPreferencesStore.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
            model.currentPageCommandBarModel.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { copyTask?.cancel()
    }

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
            owner: self
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
                x: bounds.width - BrowserChromeLayout.sidebarTabTrailingPadding - size,
                y: (bounds.height - size) / 2,
                width: size,
                height: size
            )
            copyButton.frame = siteButton.frame.offsetBy(dx: -(size + spacing), dy: 0)
            for (index, browserExtension) in pinned.enumerated() {
                extensionButtons[browserExtension.id]?.frame = copyButton.frame.offsetBy(
                    dx: -CGFloat(pinned.count - index) * (size + spacing),
                    dy: 0
                )
            }
        } else {
            let padding = BrowserChromeLayout.bookmarksBarHorizontalPadding
            let size = BrowserChromeLayout.chromeButtonSize
            let spacing = BrowserChromeLayout.chromeButtonSpacing
            let available = max(bounds.width - padding * 2, 0)
            let leftWidth = size * 3 + spacing * 2
            let rightWidth = CGFloat(pinned.count + 1) * size + CGFloat(pinned.count) * spacing
            let clusterWidth = min(
                BrowserChromeLayout.siteToolbarURLButtonMaximumWidth + size + spacing,
                max(available - leftWidth - rightWidth - spacing * 2, 0)
            )
            let remainder = max(available - clusterWidth - spacing * 2, 0)
            let leftArea = max(leftWidth, min(remainder / 2, remainder - rightWidth))
            let y = (bounds.height - size) / 2
            backButton.frame = NSRect(x: padding, y: y, width: size, height: size)
            forwardButton.frame = backButton.frame.offsetBy(dx: size + spacing, dy: 0)
            reloadButton.frame = forwardButton.frame.offsetBy(dx: size + spacing, dy: 0)
            copyButton.frame = NSRect(x: padding + leftArea + spacing, y: y, width: size, height: size)
            urlButton.frame = NSRect(
                x: copyButton.frame.maxX + spacing,
                y: y,
                width: max(clusterWidth - size - spacing, 0),
                height: size
            )
            siteButton.frame = NSRect(x: bounds.width - padding - size, y: y, width: size, height: size)
            for (index, browserExtension) in pinned.enumerated() {
                extensionButtons[browserExtension.id]?.frame = siteButton.frame.offsetBy(
                    dx: -CGFloat(pinned.count - index) * (size + spacing),
                    dy: 0
                )
            }
        }
        publishURLFrame()
    }

    func refresh() {
        let preferences = model.userPreferencesStore
        let tab = model.currentTab
        let display: String =
            if let tab {
                mode == .toolbar && preferences.siteToolbarShowsFullURL
                    ? BrowserURLDisplayFormatter.fullDisplayString(for: tab.urlString)
                    : BrowserURLDisplayFormatter.displayString(for: tab.urlString)
            } else {
                BrowserStrings.newTabTitle
            }
        urlButton.update(title: display)
        urlButton.isInteractionEnabled = tab != nil && !isSidebarResizing
        urlButton.tooltipTitle = mode == .sidebar
            ? tab.map { BrowserURLDisplayFormatter.fullDisplayString(for: $0.urlString) } ?? BrowserStrings.newTabTitle
            : nil
        backButton.isHidden = mode == .sidebar
        forwardButton.isHidden = mode == .sidebar
        reloadButton.isHidden = mode == .sidebar
        backButton.isEnabled = model.canGoBack
        forwardButton.isEnabled = model.canGoForward
        backButton.tooltipShortcut = model.shortcutStore.shortcut(for: .goBack)
        forwardButton.tooltipShortcut = model.shortcutStore.shortcut(for: .goForward)
        reloadButton.configureSymbol(
            model.canStopLoading ? "xmark" : "arrow.clockwise",
            title: model.canStopLoading
                ? BrowserStrings.navigationStopLoading
                : BrowserStrings.navigationRefresh
        )
        reloadButton.tooltipShortcut = model.canStopLoading ? nil : model.shortcutStore.shortcut(for: .reload)
        reloadButton.pressEffect = model.canStopLoading ? .compress : .rotateClockwise
        reloadButton.isEnabled = model.canStopLoading || model.canReload
        copyButton.configureSymbol(didCopy ? "checkmark" : "link", title: BrowserStrings.tabCopyURLAction)
        copyButton.tooltipShortcut = model.shortcutStore.shortcut(for: .copyLink)
        let byID = Dictionary(uniqueKeysWithValues: model.browserExtensions.map { ($0.id, $0) })
        pinned = model.pinnedExtensionIDs.compactMap { id in byID[id].flatMap { $0.isEnabled ? $0 : nil } }
        for id in Set(extensionButtons.keys)
            .subtracting(pinned.map(\.id))
        {
            extensionButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for browserExtension in pinned {
            let button = extensionButtons[browserExtension.id] ?? BrowserNativeExtensionButton(
                tile: false,
                sidebar: mode == .sidebar
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
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
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
            enabled: model.currentTab != nil
        ) { _ = model.copySelectedTabLink() }
        let tab = model.currentTab
        BrowserNativeMenus.share(
            items: tab?.pageURL.map { [$0] } ?? tab.map { [NSString(string: $0.urlString)] } ?? [],
            subject: tab?.displayTitle ?? BrowserStrings.newTabTitle,
            in: menu
        )
        menu.items.last?.isEnabled = tab != nil
        BrowserNativeMenus
            .add(BrowserStrings.siteCaptureFullPageAction, to: menu, enabled: tab != nil) {
                _ = model.captureFullPageSelectedTabToPasteboard()
            }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            preferences.siteURLToolbarEnabled
                ? BrowserStrings.siteShowInSidebarAction
                : BrowserStrings.siteShowAsToolbarAction,
            to: menu
        ) { preferences.siteURLToolbarEnabled.toggle() }
        if preferences.siteURLToolbarEnabled {
            BrowserNativeMenus.add(
                preferences.siteToolbarShowsFullURL
                    ? BrowserStrings.siteHideFullURLAction
                    : BrowserStrings.siteShowFullURLAction,
                to: menu,
                enabled: tab != nil
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
            shortcut: model.shortcutStore.shortcut(for: .toggleBookmarksBar)
        ) {
            preferences.bookmarksBarVisible.toggle()
        }
        return menu
    }

    func closePopovers() { extensionPopovers.close() }

    // MARK: Private

    private let backButton = BrowserNativeChromeButton(
        symbol: "arrow.backward",
        title: BrowserStrings.navigationBack,
        pressEffect: .left,
        action: {}
    )
    private let forwardButton = BrowserNativeChromeButton(
        symbol: "arrow.forward",
        title: BrowserStrings.navigationForward,
        pressEffect: .right,
        action: {}
    )
    private let reloadButton = BrowserNativeChromeButton(
        symbol: "arrow.clockwise",
        title: BrowserStrings.navigationRefresh,
        pressEffect: .rotateClockwise,
        action: {}
    )
    private let extensionPopovers: BrowserNativeExtensionPopoverPresenter
    private var extensionButtons = [String: BrowserNativeExtensionButton]()
    private var pinned = [BrowserExtension]()
    private var observations = Set<AnyCancellable>()
    private var copyTask: Task<Void, Never>?
    private var didCopy = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var lastReportedFrame: CGRect?
    private var frameUpdateScheduled = false

    private var showsSidebarActions: Bool {
        (hovered || extensionPopovers.isPresented) && !isSidebarResizing && model
            .currentTab != nil
    }

    private var sidebarActionWidth: CGFloat {
        let count = CGFloat(pinned.count + 2)
        return count * BrowserChromeLayout.sidebarCurrentURLButtonSize + (count - 1) * BrowserChromeLayout
            .sidebarCurrentURLButtonSpacing
            + BrowserChromeLayout.sidebarTabTrailingPadding + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    private func refreshHover() {
        let sidebar = mode == .sidebar
        let show = !sidebar || showsSidebarActions
        copyButton.isHidden = !show
        siteButton.isHidden = !show
        copyButton.isEnabled = model.currentTab != nil && !isSidebarResizing
        siteButton.isEnabled = model.currentTab != nil && !isSidebarResizing
        for button in extensionButtons.values {
            button.isHidden = !show
            button.isInteractionEnabled = !isSidebarResizing
        }
        urlButton.isSearchPresented = sidebar && model.currentPageCommandBarModel.isPresented
        urlButton.externalHover = sidebar && hovered
        var actionHovered = false
        if let window, show {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            actionHovered = ([copyButton, siteButton] as [NSView] + Array(extensionButtons.values))
                .contains { $0.frame.contains(point) }
        }
        urlButton.permitsTooltip = !actionHovered && !isSidebarResizing
        urlButton.refreshTooltip()
        urlButton.maskedTrailingWidth = sidebar && show ? sidebarActionWidth : 0
        urlButton.interactionChanged()
        needsLayout = true
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
        if model.canStopLoading {
            model.stopLoadingCurrentTab()
        } else {
            model.reloadCurrentTab()
        }
    }

    private func showControlCenter() {
        guard model.currentTab != nil, !isSidebarResizing else { return }
        extensionPopovers.showControlCenter(relativeTo: siteButton, preferredEdge: mode == .toolbar ? .minY : .minX)
    }

    private func openExtension(_ id: String) {
        extensionPopovers.openExtension(id: id, relativeTo: siteButton, preferredEdge: mode == .toolbar ? .minY : .minX)
    }

    private func extensionMenu(_ browserExtension: BrowserExtension) -> NSMenu { extensionPopovers
        .menu(for: browserExtension)
    }
}

// MARK: - BrowserNativeURLButton

final class BrowserNativeURLButton: BrowserNativePressableView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(textContainer)
        textContainer.addSubview(label)
        textContainer.wantsLayer = true
        label.setAccessibilityElement(false)
        cornerRadius = BrowserChromeLayout.currentURLRowCornerRadius
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    var isToolbar = false
    var isSearchPresented = false
    var externalHover = false

    var maskedTrailingWidth: CGFloat = 0 { didSet { needsLayout = true } }

    override func interactionChanged() {
        super.interactionChanged()
        fillColor = isHovered || externalHover || isSearchPresented
            ? BrowserChromeColors.currentURLRowHover
            : BrowserChromeColors.currentURLRow
    }

    override func layout() {
        super.layout()
        textContainer.frame = bounds
        label.frame = NSRect(
            x: BrowserChromeLayout.sidebarRowHorizontalPadding,
            y: (bounds.height - 17) / 2,
            width: max(bounds.width - BrowserChromeLayout.sidebarRowHorizontalPadding * 2, 0),
            height: 17
        )
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

    func update(title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
        label.alignment = isToolbar ? .center : .left
        label.lineBreakMode = isToolbar ? .byTruncatingMiddle : .byTruncatingTail
    }

    // MARK: Private

    private let textContainer = NSView()
    private let label = BrowserNativeControls.label(
        "",
        size: 12.5,
        weight: .medium,
        color: BrowserChromeColors.currentURLText
    )
    private let textMask = CAGradientLayer()
}
