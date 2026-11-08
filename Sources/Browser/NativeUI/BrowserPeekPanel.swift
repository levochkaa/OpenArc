// BrowserPeekPanel.swift

import AppKit
import Combine

// MARK: - BrowserPeekPanel

/// Peek: a Shift-clicked link opens in a floating card over the window.
/// The card has the page's host, Open as Tab and Close; Escape, Close or a
/// click on the window behind closes it. Standalone, it is a
/// small window of its own for links from other apps, whose host is an address
/// field (`⌘L`). `⌘O` opens either as a tab. The engine puts its page in
/// `hostView`.
@objc final class BrowserPeekPanel: NSPanel, NSTextFieldDelegate, NSMenuDelegate {
    /// Back, Forward, Reload and Reload Ignoring Cache for the card's page.
    enum NavigationCommand: Int {
        case back
        case forward
        case reload
        case forceReload
    }

    // MARK: Internal

    static let barHeight: CGFloat = 36
    /// The small window's bar: an address pill and the Open in button.
    static let standaloneBarHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 12
    /// A small window's share of the screen's visible area: 1185 x 832 pt on a
    /// 1728 x 1084 pt one.
    static let standaloneScreenFraction = CGSize(width: 1185.0 / 1728.0, height: 832.0 / 1084.0)
    static let linkStatusHeight: CGFloat = 24
    static let linkStatusInset: CGFloat = 10.5
    /// The card covers this share of the window and leaves the page
    /// visible around it.
    static let windowFraction: CGFloat = 0.84
    /// The card's width against the page behind it.
    static let pageWidthFraction: CGFloat = 0.804

    // MARK: Private

    private static let stripHeight: CGFloat = 133.5
    private static let cardOpens = (stiffness: CGFloat(657.7), damping: CGFloat(44.37))
    private static let cardCloses = (stiffness: CGFloat(779.82), damping: CGFloat(49.99))
    /// How far the page behind steps back, about its center.
    private static let pageScale: CGFloat = 0.9881
    private static let pageOpacity: Float = 0.3

    private static let closeDelay: TimeInterval = 0.035

    private static let searchAddressAction = Selector(("searchSmallWindowAddress:"))

    override var canBecomeKey: Bool { true }

    /// A small window rather than a Peek card.
    @objc let isStandalone: Bool
    @objc let hostView = NSView()
    @objc var onClose: (() -> Void)?
    @objc var onOpenInTab: (() -> Void)?
    /// Opens the page's Developer Tools, or closes them when they are open.
    @objc var onToggleDeveloperTools: (() -> Void)?
    /// Finds text in the page: the text, forward, and whether to select a match.
    @objc var onFind: ((String, Bool, Bool) -> Void)?
    /// Gets a `NavigationCommand` raw value.
    @objc var onNavigationCommand: ((Int) -> Void)?
    /// Whether the page has somewhere to go back or forward to, from the engine.
    @objc var canGoBack = false
    @objc var canGoForward = false

    /// Sets the page's zoom level, Chromium's log base 1.2 of the scale.
    @objc var onSetZoomLevel: ((Double) -> Void)?
    @objc var onStopFinding: (() -> Void)?
    /// Find in the card's page, over its top trailing corner as in a tab.
    let findBar = BrowserFindBarNSView()
    /// A typed address or search, resolved to the URL the page should load.
    @objc var onNavigate: ((String) -> Void)?
    /// The card's page joins the page behind it in a Split View.
    @objc var onOpenInSplitView: (() -> Void)?
    /// Gives the keyboard to the page through the engine.
    @objc var onFocusPage: (() -> Void)?
    /// The window's Spaces for Open In, in sidebar order.
    @objc var spacesProvider: (() -> [BrowserPeekSpace])?
    /// Open In: the page becomes a tab of the chosen Space.
    @objc var onOpenInSpace: ((String) -> Void)?
    /// Open as Tab's right-click menu and `⇧⌘O`.
    let openInMenu = NSMenu()
    /// The page's permission request over the top of the page, as in a tab.
    let permissionPrompt = BrowserSitePermissionPromptView()
    /// Allow (true), Block (false) or Close (nil) in the prompt.
    var onSitePermissionAnswer: ((Int, Bool?) -> Void)?

    let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.peekCloseAction,
        style: .currentURL,
        action: {},
    )
    let openButton = BrowserNativeChromeButton(
        symbol: "arrow.up.left.and.arrow.down.right",
        title: BrowserStrings.peekOpenInTabAction,
        style: .currentURL,
        action: {},
    )
    /// Peek can also open beside the page; the small window has no page beside it.
    let splitButton = BrowserNativeChromeButton(
        symbol: "rectangle.split.2x1",
        title: BrowserStrings.peekOpenInSplitViewAction,
        style: .currentURL,
        action: {},
    )
    let hostLabel = BrowserPeekAddressField(string: "")
    /// The small window's address background, with a magnifier and Copy Link.
    let addressPill = BrowserNativeSurface()
    let copyLinkButton = BrowserNativeChromeButton(
        symbol: "link",
        title: BrowserStrings.tabCopyURLAction,
        style: .currentURL,
        action: {},
    )
    /// "Open in <Space> ⌘O" and a chevron for the other Spaces.
    let openInButton = BrowserPeekOpenInButton()
    /// "Copied Current URL" with Share, after Copy Link.
    let copiedToast = BrowserCaptureToastView()
    /// The address of the link under the pointer, at the page's bottom left.
    let linkStatus = BrowserLinkStatusView()

    /// The bar New Tab shows over the small window's page, if any.
    private(set) var searchBar: BrowserCommandBarNSView?

    /// The page's zoom in percent, one of the browser's steps.
    private(set) var zoomPercent = 100

    private let addressSymbol = NSImageView()

    private var parentMonitor: Any?
    private var currentURLString = ""
    private var card = NSVisualEffectView()
    /// Holds the card, and moves and scales it as one.
    private let cardHost = NSView()
    private let cardMask = CALayer()
    private let cardShadow = CALayer()
    private var openingTransform = CATransform3DIdentity
    /// The page behind the card, which dims and steps back.
    private weak var pageBehind: NSView?
    private var isClosingAnimated = false
    private var findQuery = ""
    private var isFindPresented = false
    private var findMatchCount: Int?
    private var findActiveOrdinal: Int?
    private var findFocusRequest = 0
    private var searchObservation: AnyCancellable?
    private var isHandingAddressToSearch = false

    /// The engine keeps a loading page from taking the keys meanwhile.
    @objc var isEditingAddress: Bool { hostLabel.currentEditor() != nil }

    /// The card on screen, without the clear part of the panel.
    var cardScreenFrame: NSRect {
        isStandalone ? frame : convertToScreen(cardHost.convert(cardHost.bounds, to: nil))
    }

    // MARK: Find

    /// Find works once the page can search.
    @objc var canFind: Bool { onFind != nil }

    @objc var canStepThroughFindMatches: Bool {
        isFindPresented && !findQuery.isEmpty && findMatchCount != 0
    }

    /// The page has an address to copy.
    @objc var canCopyLink: Bool { !currentURLString.isEmpty && currentURLString != "about:blank" }

    /// The page's address, for the search to open with.
    var addressForEditing: String {
        currentURLString == "about:blank" ? "" : currentURLString
    }

    var canZoom: Bool { onSetZoomLevel != nil }

    /// The app answers with a search over the page; without it the field edits inline.
    private var canSearchAddress: Bool {
        isStandalone && NSApp.target(forAction: Self.searchAddressAction, to: nil, from: self) != nil
    }

    private init(contentRect: NSRect, standalone: Bool) {
        self.isStandalone = standalone
        super.init(
            contentRect: contentRect,
            styleMask: standalone
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        isReleasedWhenClosed = false
        if standalone {
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            isFloatingPanel = false
            hidesOnDeactivate = false
            minSize = NSSize(width: 480, height: 360)
            closeButton.isHidden = true
            animationBehavior = .none
        } else {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            animationBehavior = .none
        }
        isMovableByWindowBackground = false
        let card = NSVisualEffectView()
        card.material = .windowBackground
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = standalone ? 0 : Self.cornerRadius
        card.layer?.masksToBounds = true
        card.autoresizingMask = [.width, .height]
        self.card = card
        if standalone {
            card.frame = NSRect(origin: .zero, size: contentRect.size)
            contentView = card
        } else {
            let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
            contentView = content
            cardHost.frame = content.bounds
            cardHost.autoresizingMask = [.width, .height]
            cardHost.wantsLayer = true
            content.addSubview(cardHost)
            card.frame = cardHost.bounds
            cardHost.addSubview(card)
        }
        for view in [closeButton, hostLabel, splitButton, openButton, hostView, linkStatus, findBar, permissionPrompt] {
            card.addSubview(view)
        }
        if standalone {
            addressPill.fillColor = NSColor.labelColor.withAlphaComponent(0.08)
            addressPill.strokeWidth = 0
            addressPill.cornerRadius = 8
            card.addSubview(addressPill, positioned: .below, relativeTo: hostLabel)
            addressSymbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            addressSymbol.contentTintColor = BrowserChromeColors.secondaryText
            addressSymbol.setAccessibilityElement(false)
            addressPill.addSubview(addressSymbol)
            addressPill.addSubview(copyLinkButton)
            copyLinkButton.onAction = { [weak self] in self?.copyLink() }
            copyLinkButton.setAccessibilityIdentifier("browser.peek.copy-link")
            copyLinkButton.tooltipShortcut = BrowserShortcutStore().shortcut(for: .copyLink)
            card.addSubview(openInButton)
            openInButton.onOpen = { [weak self] in self?.onOpenInTab?() }
            openInButton.onShowMenu = { [weak self] in self?.showOpenInMenu() }
            openInButton.setAccessibilityIdentifier("browser.peek.open-in")
            openButton.isHidden = true
        }
        findBar.queryField.focusPermission = { [weak self] in self?.isFindPresented == true }
        findBar.onQueryChanged = { [weak self] in self?.findQueryDidChange($0) }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onDismiss = { [weak self] in self?.dismissFind() }
        permissionPrompt.isHidden = true
        permissionPrompt.autoresizingMask = [.maxXMargin, .minYMargin]
        permissionPrompt.onAnswer = { [weak self] id, allowed in self?.onSitePermissionAnswer?(id, allowed) }
        permissionPrompt.onDismiss = { [weak self] id in self?.onSitePermissionAnswer?(id, nil) }
        hostLabel.alignment = .center
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hostLabel.textColor = BrowserChromeColors.secondaryText
        hostLabel.isBordered = false
        hostLabel.drawsBackground = false
        hostLabel.focusRingType = .none
        hostLabel.cell?.usesSingleLineMode = true
        hostLabel.cell?.isScrollable = true
        hostLabel.isEditable = standalone
        hostLabel.isSelectable = standalone
        hostLabel.placeholderString = standalone ? BrowserStrings.peekAddressPlaceholder : nil
        hostLabel.delegate = self
        hostLabel.onFocus = { [weak self] in
            guard let self else { return }
            // Only a click hands the address over; the window taking the keyboard
            // focuses the field too.
            guard canSearchAddress, NSApp.currentEvent?.type == .leftMouseDown else {
                beginEditingAddress()
                return
            }
            // The address opens in the search over the page, selected.
            DispatchQueue.main.async {
                // The search takes the keyboard, not the page.
                self.isHandingAddressToSearch = true
                self.makeFirstResponder(nil)
                self.isHandingAddressToSearch = false
                self.update(urlString: self.currentURLString)
                self.searchAddress()
            }
        }
        hostLabel.setAccessibilityIdentifier("browser.peek.address")
        closeButton.onAction = { [weak self] in self?.onClose?() }
        openButton.onAction = { [weak self] in self?.onOpenInTab?() }
        splitButton.onAction = { [weak self] in self?.onOpenInSplitView?() }
        splitButton.isHidden = standalone
        splitButton.setAccessibilityIdentifier("browser.peek.open-in-split")
        closeButton.setAccessibilityIdentifier("browser.peek.close")
        openButton.setAccessibilityIdentifier("browser.peek.open-in-tab")
        openInMenu.delegate = self
        openInMenu.autoenablesItems = false
        openButton.menu = openInMenu
        hostView.setAccessibilityIdentifier("browser.peek.page")
        setAccessibilityIdentifier("browser.peek")
        layoutCard()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        centerWindowButtons()
    }

    override func becomeKey() {
        super.becomeKey()
        centerWindowButtons()
        // The window's Space may have changed while this one was in the back.
        refreshOpenInTitle()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !isStandalone {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_: Any?) {
        if !isStandalone {
            onClose?()
        }
    }

    /// Close Window and Command-W reach the card without a title bar button.
    override func performClose(_: Any?) {
        onClose?()
    }

    /// The card's frame for a parent window, centered over its content.
    static func frame(over window: NSWindow, page: NSView? = nil) -> NSRect {
        if let page, page.window === window {
            let area = window.convertToScreen(page.convert(page.bounds, to: nil))
            let width = (area.width * pageWidthFraction).rounded()
            let height = area.height - 4
            return NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
        }
        let parent = window.frame
        let width = (parent.width * windowFraction).rounded()
        let height = (parent.height * windowFraction).rounded()
        return NSRect(x: parent.midX - width / 2, y: parent.midY - height / 2, width: width, height: height).integral
    }

    /// A small window sits in the top right corner of the screen, where its address bar appeared.
    static func standaloneFrame(in screen: NSRect) -> NSRect {
        let margin = BrowserLittleWindowLauncher.screenMargin
        let size = NSSize(
            width: min(max((screen.width * standaloneScreenFraction.width).rounded(), 820), screen.width - 80),
            height: min(max((screen.height * standaloneScreenFraction.height).rounded(), 640), screen.height - 80),
        )
        return NSRect(
            x: screen.maxX - margin - size.width,
            y: screen.maxY - margin - size.height,
            width: size.width,
            height: size.height,
        )
        .integral
    }

    @objc(presentStandalone) static func presentStandalone() -> BrowserPeekPanel {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let panel = BrowserPeekPanel(contentRect: standaloneFrame(in: screen), standalone: true)
        // An empty page paints white before it has anything to show.
        panel.hostView.wantsLayer = true
        panel.hostView.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in panel?.hostView.alphaValue = 1 }
        panel.makeKeyAndOrderFront(nil)
        // The window would focus the address field; the page takes the keys.
        panel.focusPage()
        NSApp.activate(ignoringOtherApps: true)
        return panel
    }

    /// The panel covers the parent window and its clear part lets clicks through, so
    /// the card can grow beyond its final size without resizing the page in it.
    @objc(presentOverWindow:page:) static func present(over window: NSWindow, page: NSView?) -> BrowserPeekPanel {
        let cardFrame = frame(over: window, page: page)
        let panel = BrowserPeekPanel(contentRect: window.frame, standalone: false)
        window.addChildWindow(panel, ordered: .above)
        panel.setFrame(window.frame, display: false)
        panel.pageBehind = page
        panel.placeCard(screenFrame: cardFrame)
        panel.makeKeyAndOrderFront(nil)
        panel.watchParent(window)
        panel.animateOpening(from: NSEvent.mouseLocation)
        return panel
    }

    static func present(over window: NSWindow) -> BrowserPeekPanel {
        present(over: window, page: nil)
    }

    /// Typed text becomes a URL or a search with the chosen search engine.
    static func resolvedURLString(for input: String) -> String? {
        let resolver = BrowserNavigationResolver(searchEngineProvider: { BrowserUserPreferencesStore().searchEngine })
        return resolver.resolve(input).map { resolution in
            BrowserInternalURLNormalizer.canonicalURLString(for: resolution.resolvedURLString)
                ?? resolution.resolvedURLString
        }
    }

    func navigate(_ command: NavigationCommand) {
        onNavigationCommand?(command.rawValue)
    }

    /// The small window, centered on the main screen.
    /// The page has started to arrive, so its first paint is near.
    @objc func revealPage() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.hostView.alphaValue = 1 }
    }

    @objc(updateWithURLString:) func update(urlString: String) {
        currentURLString = urlString
        let host = URL(string: urlString)?.host.map(BrowserURLDisplayFormatter.hostDisplayString(forHost:))
        let display = urlString == "about:blank" ? "" : host ?? BrowserURLDisplayFormatter.displayString(for: urlString)
        hostView.setAccessibilityLabel(display)
        if hostLabel.currentEditor() == nil {
            hostLabel.stringValue = display
        }
    }

    /// The small window's address field takes the keyboard with the address selected.
    @objc func focusAddressField() {
        guard isStandalone else { return }
        if canSearchAddress {
            searchAddress()
        } else {
            makeFirstResponder(hostLabel)
        }
    }

    /// `⌘L` edits the small window's address, `⌘O` opens the page as a tab and
    /// `⇧⌘O` shows Open In. The app asks before its own shortcuts.
    @objc func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard event.type == .keyDown, modifiers == .command || modifiers == [.command, .shift] else { return false }
        switch (event.keyCode, modifiers == .command) {
        case (37, true) where isStandalone:
            focusAddressField()
            return true
        case (31, true):
            onOpenInTab?()
            return true
        case (31, false):
            showOpenInMenu()
            return true
        default:
            return false
        }
    }

    func showOpenInMenu() {
        let anchor: NSView = isStandalone ? openInButton : openButton
        // Below the anchor, whichever way its coordinates run.
        let below = anchor.isFlipped ? anchor.bounds.height + 4 : -4
        openInMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }

    /// Names the Space a page opens in from the small window.
    @objc func refreshOpenInTitle() {
        guard isStandalone else { return }
        let spaces = spacesProvider?() ?? []
        openInButton.spaceTitle = (spaces.first(where: \.isSelected) ?? spaces.first)?.title
        layoutCard()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openInMenu else { return }
        menu.removeAllItems()
        let header = NSMenuItem(title: BrowserStrings.peekOpenInMenuTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for space in spacesProvider?() ?? [] {
            let item = BrowserNativeMenuItem(space.title) { [weak self] in self?.onOpenInSpace?(space.id) }
            item.image = BrowserIconImage.image(named: space.systemImageName, pointSize: 13)
            menu.addItem(item)
        }
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let input = hostLabel.stringValue
            endEditingAddress()
            if let urlString = Self.resolvedURLString(for: input) {
                update(urlString: urlString)
                onNavigate?(urlString)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditingAddress()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_: Notification) {
        update(urlString: currentURLString)
    }

    /// A prompt from the page's sign-in or checkout, over its top right corner.
    func hostPrompt(_ prompt: NSView, height: CGFloat) {
        guard let parent = hostView.superview else { return }
        let page = hostView.frame
        let width = min(BrowserPasswordPromptView.width, max(page.width - 24, 0))
        parent.addSubview(prompt, positioned: .above, relativeTo: nil)
        prompt.frame = NSRect(x: page.maxX - 12 - width, y: page.maxY - 12 - height, width: width, height: height)
        prompt.autoresizingMask = [.minXMargin, .minYMargin]
    }

    /// Shows the page's oldest waiting request, or hides the prompt for nil.
    func showSitePermissionRequest(_ request: BrowserSitePermissionRequest?) {
        guard let request else {
            permissionPrompt.isHidden = true
            return
        }
        permissionPrompt.update(request: request)
        permissionPrompt.isHidden = false
        let page = hostView.frame
        let height = permissionPrompt.fittingHeight
        permissionPrompt.frame = NSRect(
            x: page.minX + 12,
            y: page.maxY - 12 - height,
            width: min(BrowserSitePermissionPromptView.width, max(page.width - 24, 0)),
            height: height,
        )
    }

    /// Puts the card away while another tab is shown, keeping its page.
    @objc func hideForOtherTab() {
        stopWatchingParent()
        restorePageBehind()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// Brings the card back over its tab, without the opening motion.
    @objc(showAgainOverWindow:page:) func showAgain(over window: NSWindow, page: NSView?) {
        window.addChildWindow(self, ordered: .above)
        setFrame(window.frame, display: false)
        pageBehind = page
        placeCard(screenFrame: Self.frame(over: window, page: page))
        setPageBehind(dimmed: true, animated: false)
        makeKeyAndOrderFront(nil)
        watchParent(window)
    }

    @objc func dismiss() {
        stopWatchingParent()
        restorePageBehind()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// Closes the card back into its strip, then runs `completion` with the page out
    /// of view. A small window and Reduce Motion close at once.
    @objc func dismiss(completion: @escaping @MainActor @Sendable () -> Void) {
        guard !isStandalone, isVisible, !isClosingAnimated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            dismiss()
            completion()
            return
        }
        isClosingAnimated = true
        stopWatchingParent()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay) { [weak self] in
            guard let self else {
                completion()
                return
            }
            let duration = animateClosing()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.dismiss()
                completion()
            }
        }
    }

    /// Command-F: shows the find bar with its last query selected.
    @objc func presentFind() {
        guard canFind else { return }
        isFindPresented = true
        findFocusRequest += 1
        if !findQuery.isEmpty {
            onFind?(findQuery, true, false)
        }
        refreshFind()
    }

    @objc func findNext() {
        guard canStepThroughFindMatches else { return }
        onFind?(findQuery, true, true)
    }

    @objc func findPrevious() {
        guard canStepThroughFindMatches else { return }
        onFind?(findQuery, false, true)
    }

    @objc func updateFindResult(count: Int, activeOrdinal: Int, finalUpdate: Bool) {
        guard isFindPresented, !findQuery.isEmpty else { return }
        if finalUpdate || count > 0 {
            findMatchCount = max(count, 0)
        }
        if activeOrdinal > 0 {
            findActiveOrdinal = activeOrdinal
        }
        refreshFind()
    }

    /// New Tab: a command bar over the page, closed by Escape, × or a result.
    func presentSearch(model: BrowserCommandBarModel, initialQuery: String = "") {
        dismissSearch()
        let bar = BrowserCommandBarNSView(model: model)
        bar.configure(blockedLeadingInset: 0, style: .standard, faviconCandidate: nil)
        bar.showsCloseButton = true
        bar.selectsTextOnFocus = !initialQuery.isEmpty
        // As wide as the small window bar, centered on the whole window.
        bar.panelWidthLimit = BrowserLittleWindowLauncher.barWidth
        bar.frame = card.bounds
        bar.autoresizingMask = [.width, .height]
        card.addSubview(bar, positioned: .above, relativeTo: nil)
        searchBar = bar
        searchObservation = model.$isPresented
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.dismissSearch() }
            }
        model.present(initialQuery: initialQuery, pageTitle: initialQuery.isEmpty ? nil : title)
    }

    /// Zoom In, Zoom Out (`step` 1 and -1) and Actual Size (0) for the card's
    /// page, with the same note as in a browser window at the window's top right.
    func zoom(step: Int) {
        guard let onSetZoomLevel else { return }
        let steps = BrowserChromeModel.zoomPercentages
        let next: Int? =
            switch step {
            case 0: 100
            case 1...: steps.first { $0 > zoomPercent }
            default: steps.last { $0 < zoomPercent }
            }
        guard let next else { return }
        zoomPercent = next
        onSetZoomLevel(log(Double(next) / 100) / log(1.2))
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        copiedToast.isDark = dark
        copiedToast.fill = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        copiedToast.showZoom(percent: next)
        layoutCopiedToast()
    }

    /// Copy Link and Copy URL: the page's address, with the same note as in a
    /// browser window at the card's top right.
    @discardableResult @objc func copyLink() -> Bool {
        guard canCopyLink else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentURLString, forType: .string)
        if let url = URL(string: currentURLString) {
            // In the small window's colors, like its bar.
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            copiedToast.isDark = dark
            copiedToast.fill = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            copiedToast.showCopiedURL(url)
            layoutCopiedToast()
        }
        return true
    }

    /// The page's status text, usually the address of the link under the pointer;
    /// nil or empty hides it.
    @objc(updateLinkStatus:) func updateLinkStatus(_ status: String?) {
        let status = status?.isEmpty == false ? status : nil
        let page = hostView.frame
        let inset = Self.linkStatusInset
        let width = linkStatus.update(status: status, maximumWidth: max(page.width * 0.6, 1))
        guard status != nil else { return }
        linkStatus.frame = NSRect(
            x: page.minX + inset,
            y: page.minY + inset,
            width: width,
            height: Self.linkStatusHeight,
        )
        linkStatus.cornerRadius = Self.linkStatusHeight / 2
        linkStatus.autoresizingMask = [.maxXMargin, .maxYMargin]
    }

    private func searchAddress() {
        NSApp.sendAction(Self.searchAddressAction, to: nil, from: self)
    }

    private func dismissSearch() {
        searchObservation = nil
        guard let bar = searchBar else { return }
        searchBar = nil
        bar.removeFromSuperview()
        focusPage()
    }

    private func layoutCopiedToast() {
        let bounds = card.bounds
        let inset = copiedToast.pageCornerInset ?? CGSize(width: 9, height: 8)
        copiedToast.frame = NSRect(
            x: bounds.width - copiedToast.preferredWidth - inset.width,
            y: bounds.height - inset.height - copiedToast.preferredHeight,
            width: copiedToast.preferredWidth,
            height: copiedToast.preferredHeight,
        )
        copiedToast.autoresizingMask = [.minXMargin, .minYMargin]
        card.addSubview(copiedToast, positioned: .above, relativeTo: nil)
    }

    private func placeCard(screenFrame: NSRect) {
        guard let content = contentView else { return }
        let local = content.convert(convertFromScreen(screenFrame), from: nil)
        cardHost.autoresizingMask = []
        cardHost.frame = local
        card.frame = cardHost.bounds
        layoutCard()
        cardMask.backgroundColor = NSColor.black.cgColor
        cardMask.cornerRadius = Self.cornerRadius
        cardMask.anchorPoint = .zero
        cardMask.frame = cardHost.bounds
        cardHost.layer?.mask = cardMask
        cardHost.layer?.masksToBounds = false
        cardShadow.frame = local
        cardShadow.shadowColor = NSColor.black.cgColor
        cardShadow.shadowOpacity = 0.3
        cardShadow.shadowRadius = 24
        cardShadow.shadowOffset = CGSize(width: 0, height: -8)
        cardShadow.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: local.size),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil,
        )
        content.wantsLayer = true
        if cardShadow.superlayer == nil, let hostLayer = cardHost.layer {
            content.layer?.insertSublayer(cardShadow, below: hostLayer)
        }
    }

    /// The strip the card grows from: the card's top, wide as the page, around the pointer.
    private func stripTransform(pointer: NSPoint) -> CATransform3D {
        guard let page = pageBehind, let pageWindow = page.window else { return CATransform3DIdentity }
        let area = pageWindow.convertToScreen(page.convert(page.bounds, to: nil))
        let size = cardHost.bounds.size
        let scale = size.width > 0 ? max(area.width / size.width, 1) : 1
        let onScreen = cardScreenFrame
        let halfStrip = Self.stripHeight * scale / 2
        let target = min(max(pointer.y, area.minY + halfStrip), area.maxY - halfStrip - 4)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // The strip's middle, in the card, before any transform.
        let stripMiddle = size.height - Self.stripHeight / 2
        let dy = (target - onScreen.minY) - (center.y + scale * (stripMiddle - center.y))
        var transform = CATransform3DMakeTranslation(0, dy, 0)
        transform = CATransform3DTranslate(transform, center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    private func pageTransform(_ page: NSView) -> CATransform3D {
        let center = CGPoint(x: page.bounds.midX, y: page.bounds.midY)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, Self.pageScale, Self.pageScale, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    private func spring(
        _ keyPath: String,
        from: Any?,
        to: Any?,
        _ parameters: (stiffness: CGFloat, damping: CGFloat),
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = parameters.stiffness
        animation.damping = parameters.damping
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    private func animateOpening(from pointer: NSPoint) {
        guard let hostLayer = cardHost.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            setPageBehind(dimmed: true, animated: false)
            return
        }
        let size = cardHost.bounds.size
        let start = stripTransform(pointer: pointer)
        openingTransform = start
        let strip = CGRect(x: 0, y: size.height - Self.stripHeight, width: size.width, height: Self.stripHeight)
        let identity = NSValue(caTransform3D: CATransform3DIdentity)
        hostLayer.add(
            spring("transform", from: NSValue(caTransform3D: start), to: identity, Self.cardOpens),
            forKey: "open",
        )
        cardMask.add(
            spring(
                "bounds",
                from: NSValue(rect: CGRect(origin: .zero, size: strip.size)),
                to: NSValue(rect: CGRect(origin: .zero, size: size)),
                Self.cardOpens,
            ),
            forKey: "open.bounds",
        )
        cardMask.add(
            spring("position", from: NSValue(point: strip.origin), to: NSValue(point: .zero), Self.cardOpens),
            forKey: "open.position",
        )
        cardMask.add(spring("cornerRadius", from: 0, to: Self.cornerRadius, Self.cardOpens), forKey: "open.corner")
        cardShadow.add(spring("shadowOpacity", from: 0, to: 0.3, Self.cardOpens), forKey: "open.shadow")
        setPageBehind(dimmed: true, animated: true)
    }

    /// Returns how long the closing runs.
    private func animateClosing() -> TimeInterval {
        guard let hostLayer = cardHost.layer else { return 0 }
        let size = cardHost.bounds.size
        let end = openingTransform
        let strip = CGRect(x: 0, y: size.height - Self.stripHeight, width: size.width, height: Self.stripHeight)
        let move = spring(
            "transform",
            from: NSValue(caTransform3D: CATransform3DIdentity),
            to: NSValue(caTransform3D: end),
            Self.cardCloses,
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.transform = end
        hostLayer.opacity = 0
        cardShadow.shadowOpacity = 0
        cardMask.bounds = CGRect(origin: .zero, size: strip.size)
        cardMask.position = strip.origin
        cardMask.cornerRadius = 0
        hostLayer.add(move, forKey: "close")
        hostLayer.add(spring("opacity", from: 1, to: 0, Self.cardCloses), forKey: "close.opacity")
        cardMask.add(
            spring(
                "bounds",
                from: NSValue(rect: CGRect(origin: .zero, size: size)),
                to: NSValue(rect: CGRect(origin: .zero, size: strip.size)),
                Self.cardCloses,
            ),
            forKey: "close.bounds",
        )
        cardMask.add(
            spring("position", from: NSValue(point: .zero), to: NSValue(point: strip.origin), Self.cardCloses),
            forKey: "close.position",
        )
        cardMask.add(spring("cornerRadius", from: Self.cornerRadius, to: 0, Self.cardCloses), forKey: "close.corner")
        cardShadow.add(spring("shadowOpacity", from: 0.3, to: 0, Self.cardCloses), forKey: "close.shadow")
        CATransaction.commit()
        setPageBehind(dimmed: false, animated: true)
        return move.settlingDuration
    }

    private func setPageBehind(dimmed: Bool, animated: Bool) {
        guard let page = pageBehind, let layer = page.layer else { return }
        let transform = dimmed ? pageTransform(page) : CATransform3DIdentity
        let opacity: Float = dimmed ? Self.pageOpacity : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            // The page moves on the spring the card does not use.
            let parameters = dimmed ? Self.cardCloses : Self.cardOpens
            let fromTransform = layer.presentation()?.transform ?? layer.transform
            let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
            layer.add(
                spring(
                    "transform",
                    from: NSValue(caTransform3D: fromTransform),
                    to: NSValue(caTransform3D: transform),
                    parameters,
                ),
                forKey: "peek.page",
            )
            layer.add(spring("opacity", from: fromOpacity, to: opacity, parameters), forKey: "peek.page.opacity")
        }
        layer.transform = transform
        layer.opacity = opacity
        CATransaction.commit()
    }

    private func restorePageBehind() {
        guard let layer = pageBehind?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !isClosingAnimated {
            layer.removeAnimation(forKey: "peek.page")
            layer.removeAnimation(forKey: "peek.page.opacity")
        }
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
        pageBehind = nil
    }

    private func beginEditingAddress() {
        guard isStandalone else { return }
        let address = currentURLString == "about:blank" ? "" : currentURLString
        if let editor = hostLabel.currentEditor() {
            editor.string = address
            editor.selectAll(nil)
        } else {
            hostLabel.stringValue = address
        }
    }

    private func endEditingAddress() {
        guard !isHandingAddressToSearch else { return }
        focusPage()
        update(urlString: currentURLString)
    }

    private func findQueryDidChange(_ query: String) {
        findQuery = query
        findMatchCount = nil
        findActiveOrdinal = nil
        if query.isEmpty {
            onStopFinding?()
        } else {
            // A new query selects its first match.
            onFind?(query, true, true)
        }
        refreshFind()
    }

    private func dismissFind() {
        guard isFindPresented else { return }
        isFindPresented = false
        findMatchCount = nil
        findActiveOrdinal = nil
        onStopFinding?()
        refreshFind()
        focusPage()
    }

    private func refreshFind() {
        findBar.update(
            query: findQuery,
            isPresented: isFindPresented,
            canStep: canStepThroughFindMatches,
            result: BrowserFindBarNSView.result(query: findQuery, count: findMatchCount, active: findActiveOrdinal),
            focusRequestID: findFocusRequest,
            blockedLeadingInset: 0,
        )
    }

    /// The engine focuses its page; until the page attaches, the window keeps the keys.
    private func focusPage() {
        makeFirstResponder(nil)
        onFocusPage?()
    }

    /// The bar keeps its place on resize; the small window leaves room for the
    /// traffic lights instead of a Close button.
    private func layoutCard() {
        if isStandalone {
            layoutStandaloneBar()
            return
        }
        let bounds = card.bounds
        let size = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let y = bounds.height - Self.barHeight + ((Self.barHeight - size) / 2).rounded()
        closeButton.frame = NSRect(x: 6, y: y, width: size, height: size)
        openButton.frame = NSRect(x: bounds.width - 6 - size, y: y, width: size, height: size)
        splitButton.frame = NSRect(x: openButton.frame.minX - 2 - size, y: y, width: size, height: size)
        let labelX = isStandalone ? 78 : closeButton.frame.maxX + 8
        let trailing = isStandalone ? openButton.frame.minX : splitButton.frame.minX
        hostLabel.frame = NSRect(
            x: labelX,
            y: bounds.height - Self.barHeight + (Self.barHeight - 16) / 2,
            width: max(trailing - 8 - labelX, 0),
            height: 16,
        )
        hostView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - Self.barHeight, 0))
        findBar.frame = hostView.frame
        findBar.autoresizingMask = [.width, .height]
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        openButton.autoresizingMask = [.minXMargin, .minYMargin]
        splitButton.autoresizingMask = [.minXMargin, .minYMargin]
        hostLabel.autoresizingMask = [.width, .minYMargin]
        hostView.autoresizingMask = [.width, .height]
    }

    /// Traffic lights, the address pill, then Open in at the trailing edge.
    private func layoutStandaloneBar() {
        let bounds = card.bounds
        let bar = Self.standaloneBarHeight
        let top = bounds.height - bar
        let buttonWidth = openInButton.preferredWidth
        openInButton.frame = NSRect(x: bounds.width - 8 - buttonWidth, y: top + 10, width: buttonWidth, height: 29)
        openInButton.autoresizingMask = [.minXMargin, .minYMargin]
        let pillX: CGFloat = 83
        addressPill.frame = NSRect(
            x: pillX,
            y: top + 9,
            width: max(openInButton.frame.minX - 9 - pillX, 0),
            height: 31,
        )
        addressPill.autoresizingMask = [.width, .minYMargin]
        addressSymbol.frame = NSRect(x: 9, y: 7.5, width: 16, height: 16)
        let linkSize = BrowserChromeLayout.sidebarCurrentURLButtonSize
        copyLinkButton.frame = NSRect(
            x: addressPill.bounds.width - 4 - linkSize,
            y: (31 - linkSize) / 2,
            width: linkSize,
            height: linkSize,
        )
        copyLinkButton.autoresizingMask = [.minXMargin]
        hostLabel.frame = NSRect(
            x: pillX + 34,
            y: top + 9 + 7.5,
            width: max(addressPill.frame.width - 68, 0),
            height: 16,
        )
        hostLabel.autoresizingMask = [.width, .minYMargin]
        hostView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(top, 0))
        hostView.autoresizingMask = [.width, .height]
        for view in [closeButton, splitButton, openButton] {
            view.frame = .zero
        }
        centerWindowButtons()
    }

    /// The traffic lights sit in the middle of the taller bar, level with the
    /// address. AppKit lays them out again on resize, so this follows it.
    private func centerWindowButtons() {
        guard isStandalone, let close = standardWindowButton(.closeButton), let titlebar = close.superview,
              let container = titlebar.superview
        else { return }
        let bar = Self.standaloneBarHeight
        let containerFrame = NSRect(
            x: container.frame.minX,
            y: frame.height - bar,
            width: container.frame.width,
            height: bar,
        )
        if container.frame != containerFrame {
            container.frame = containerFrame
        }
        if titlebar.frame.height != bar {
            titlebar.frame = NSRect(x: 0, y: 0, width: containerFrame.width, height: bar)
        }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            let y = ((bar - button.frame.height) / 2).rounded(.down)
            if button.frame.minY != y {
                button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y))
            }
        }
    }

    /// A click on the page behind closes the card. The sidebar stays usable: a
    /// click there may show another tab, which puts the card away with its tab.
    private func watchParent(_ window: NSWindow) {
        parentMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .rightMouseDown,
        ]) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if let page = pageBehind, page.window === window,
               !page.convert(page.bounds, to: nil).contains(event.locationInWindow)
            {
                return event
            }
            onClose?()
            return event
        }
    }

    private func stopWatchingParent() {
        if let parentMonitor {
            NSEvent.removeMonitor(parentMonitor)
        }
        parentMonitor = nil
    }
}

// MARK: - BrowserPeekSpace

/// A Space offered by Open In.
@objc final class BrowserPeekSpace: NSObject, Sendable {
    // MARK: Internal

    @objc let id: String
    @objc let title: String
    @objc let systemImageName: String
    /// The Space the window shows, where Open as Tab puts the page.
    @objc let isSelected: Bool

    init(id: String, title: String, systemImageName: String, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
        self.isSelected = isSelected
    }
}

// MARK: - BrowserPeekAddressField

/// The small window's address: the host until it is clicked, then the full address.
final class BrowserPeekAddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, isEditable {
            onFocus?()
        }
        return became
    }
}

// MARK: - BrowserPeekSettings

/// Read by the engine when a link asks for a new window.
@objc final class BrowserPeekSettings: NSObject {
    /// Seconds an unused small window stays open; 0 keeps it.
    @objc static var smallWindowLifetime: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: BrowserUserPreferencesStore.smallWindowLifetimeKey)
        return (stored as? Double) ?? BrowserSmallWindowLifetime.twelveHours.rawValue
    }

    /// Peek for Shift-clicked links, on unless turned off in Settings.
    @objc static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: BrowserUserPreferencesStore.peekEnabledKey) as? Bool ?? true
    }

    /// Option-Command-click into the small window, off unless turned on.
    @objc static var opensOptionCommandClicksInLittleWindow: Bool {
        UserDefaults.standard.bool(forKey: BrowserUserPreferencesStore.littleWindowOptionCommandClickKey)
    }
}

// MARK: - BrowserPeekOpenInButton

/// The small window's "Open in <Space> ⌘O", with a chevron that lists the
/// other Spaces.
final class BrowserPeekOpenInButton: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Internal

    var onOpen: () -> Void = {}
    var onShowMenu: () -> Void = {}

    var spaceTitle: String? {
        didSet { updateTitle() }
    }

    // MARK: Private

    private let surface = BrowserNativeSurface()
    private let title = NSTextField(labelWithString: "")
    private let badge = BrowserNativeSurface()
    private let badgeLabel = NSTextField(labelWithString: "⌘O")
    private let divider = BrowserNativeSurface()
    private let chevron = NSImageView()

    /// Fits the title, the key badge and the chevron.
    var preferredWidth: CGFloat {
        // The label's cell draws its text a few points inside its frame.
        ceil(title.attributedStringValue.size().width) + 6 + 12 + 8 + badgeWidth + 8 + 1 + 28
    }

    private var badgeWidth: CGFloat { ceil(badgeLabel.attributedStringValue.size().width) + 10 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.fillColor = NSColor.black.withAlphaComponent(0.35)
        surface.strokeWidth = 0
        surface.cornerRadius = 8
        addSubview(surface)
        title.lineBreakMode = .byTruncatingTail
        badge.fillColor = NSColor.labelColor.withAlphaComponent(0.1)
        badge.strokeWidth = 0
        badge.cornerRadius = 5
        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = BrowserChromeColors.secondaryText
        badge.addSubview(badgeLabel)
        divider.fillColor = NSColor.labelColor.withAlphaComponent(0.12)
        divider.strokeWidth = 0
        chevron.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: BrowserStrings.peekOpenInMenuTitle,
        )?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = BrowserChromeColors.secondaryText
        for view in [title, badge, divider, chevron] as [NSView] {
            surface.addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateTitle()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let height = bounds.height
        let chevronWidth: CGFloat = 28
        chevron.frame = NSRect(x: bounds.width - chevronWidth, y: (height - 14) / 2, width: chevronWidth, height: 14)
        divider.frame = NSRect(x: chevron.frame.minX - 1, y: 6, width: 1, height: max(height - 12, 0))
        badge.frame = NSRect(
            x: divider.frame.minX - 8 - badgeWidth,
            y: (height - 20) / 2,
            width: badgeWidth,
            height: 20,
        )
        badgeLabel.frame = NSRect(x: 5, y: 2, width: badgeWidth - 10, height: 16)
        title.frame = NSRect(x: 12, y: (height - 17) / 2, width: max(badge.frame.minX - 8 - 12, 0), height: 17)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if point.x >= divider.frame.minX {
            onShowMenu()
        } else {
            onOpen()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen()
        return true
    }

    private func updateTitle() {
        let text = NSMutableAttributedString(
            string: BrowserStrings.peekOpenInPrefix,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: BrowserChromeColors.secondaryText,
            ],
        )
        text.append(NSAttributedString(
            string: spaceTitle ?? BrowserStrings.peekOpenInTabAction,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: BrowserChromeColors.primaryText,
            ],
        ))
        title.attributedStringValue = spaceTitle == nil
            ? NSAttributedString(
                string: BrowserStrings.peekOpenInTabAction,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: BrowserChromeColors.primaryText,
                ],
            )
            : text
        setAccessibilityLabel(title.stringValue)
        needsLayout = true
        superview?.needsLayout = true
    }
}
