// BrowserPeekPanel.swift

import AppKit

// MARK: - BrowserPeekPanel

/// Peek: a Shift-clicked link opens in a floating card over the window.
/// The card has the page's host, Open as Tab and Close; Escape, Close or a
/// click on the window behind closes it. Standalone, it is a
/// small window of its own for links from other apps, whose host is an address
/// field (`⌘L`). `⌘O` opens either as a tab. The engine puts its page in
/// `hostView`.
@objc final class BrowserPeekPanel: NSPanel, NSTextFieldDelegate, NSMenuDelegate {
    // MARK: Internal

    static let barHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 12
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

    override var canBecomeKey: Bool { true }

    /// A small window rather than a Peek card.
    @objc let isStandalone: Bool
    @objc let hostView = NSView()
    @objc var onClose: (() -> Void)?
    @objc var onOpenInTab: (() -> Void)?
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

    /// The engine keeps a loading page from taking the keys meanwhile.
    @objc var isEditingAddress: Bool { hostLabel.currentEditor() != nil }

    /// The card on screen, without the clear part of the panel.
    var cardScreenFrame: NSRect {
        isStandalone ? frame : convertToScreen(cardHost.convert(cardHost.bounds, to: nil))
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
        for view in [closeButton, hostLabel, splitButton, openButton, hostView, permissionPrompt] {
            card.addSubview(view)
        }
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
        hostLabel.onFocus = { [weak self] in self?.beginEditingAddress() }
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

    @objc(presentStandalone) static func presentStandalone() -> BrowserPeekPanel {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(820, screen.width - 80), height: min(640, screen.height - 80))
        let frame = NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
        .integral
        let panel = BrowserPeekPanel(contentRect: frame, standalone: true)
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
        makeFirstResponder(hostLabel)
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
        openInMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: openButton.bounds.height + 4), in: openButton)
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
        focusPage()
        update(urlString: currentURLString)
    }

    /// The engine focuses its page; until the page attaches, the window keeps the keys.
    private func focusPage() {
        makeFirstResponder(nil)
        onFocusPage?()
    }

    /// The bar keeps its place on resize; the small window leaves room for the
    /// traffic lights instead of a Close button.
    private func layoutCard() {
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
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        openButton.autoresizingMask = [.minXMargin, .minYMargin]
        splitButton.autoresizingMask = [.minXMargin, .minYMargin]
        hostLabel.autoresizingMask = [.width, .minYMargin]
        hostView.autoresizingMask = [.width, .height]
    }

    /// A click on the window behind closes the card.
    private func watchParent(_ window: NSWindow) {
        parentMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .rightMouseDown,
        ]) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
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

    init(id: String, title: String, systemImageName: String) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
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
