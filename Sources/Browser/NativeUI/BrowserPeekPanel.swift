import AppKit

// MARK: - BrowserPeekPanel

/// Peek: a Shift-clicked link opens in a floating card over the window.
/// The card has the page's host, Open as Tab and Close; Escape, Close or a
/// click on the window behind closes it. Standalone, it is a
/// small window of its own for links from other apps, whose host is an address
/// field (`⌘L`). `⌘O` opens either as a tab. The engine puts its page in
/// `hostView`.
@objc final class BrowserPeekPanel: NSPanel, NSTextFieldDelegate, NSMenuDelegate {
    // MARK: Lifecycle

    private init(contentRect: NSRect, standalone: Bool) {
        self.isStandalone = standalone
        super.init(
            contentRect: contentRect,
            styleMask: standalone
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        if standalone {
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            isFloatingPanel = false
            hidesOnDeactivate = false
            minSize = NSSize(width: 480, height: 360)
            closeButton.isHidden = true
        } else {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            animationBehavior = .utilityWindow
        }
        isMovableByWindowBackground = false
        let card = NSVisualEffectView()
        card.material = .windowBackground
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = standalone ? 0 : Self.cornerRadius
        card.layer?.masksToBounds = true
        card.autoresizingMask = [.width, .height]
        card.frame = NSRect(origin: .zero, size: contentRect.size)
        contentView = card
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

    // MARK: Internal

    static let barHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 12
    /// The card covers this share of the window and leaves the page
    /// visible around it.
    static let windowFraction: CGFloat = 0.84

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
        action: {}
    )
    let openButton = BrowserNativeChromeButton(
        symbol: "arrow.up.left.and.arrow.down.right",
        title: BrowserStrings.peekOpenInTabAction,
        style: .currentURL,
        action: {}
    )
    /// Peek can also open beside the page; the small window has no page beside it.
    let splitButton = BrowserNativeChromeButton(
        symbol: "rectangle.split.2x1",
        title: BrowserStrings.peekOpenInSplitViewAction,
        style: .currentURL,
        action: {}
    )
    let hostLabel = BrowserPeekAddressField(string: "")

    /// The engine keeps a loading page from taking the keys meanwhile.
    @objc var isEditingAddress: Bool { hostLabel.currentEditor() != nil }

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
    static func frame(over window: NSWindow) -> NSRect {
        let parent = window.frame
        let width = (parent.width * windowFraction).rounded()
        let height = (parent.height * windowFraction).rounded()
        return NSRect(x: parent.midX - width / 2, y: parent.midY - height / 2, width: width, height: height).integral
    }

    /// The small window, centered on the main screen.
    @objc(presentStandalone) static func presentStandalone() -> BrowserPeekPanel {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(820, screen.width - 80), height: min(640, screen.height - 80))
        let frame = NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        .integral
        let panel = BrowserPeekPanel(contentRect: frame, standalone: true)
        panel.makeKeyAndOrderFront(nil)
        // The window would focus the address field; the page takes the keys.
        panel.focusPage()
        NSApp.activate(ignoringOtherApps: true)
        return panel
    }

    @objc(presentOverWindow:) static func present(over window: NSWindow) -> BrowserPeekPanel {
        let frame = frame(over: window)
        let panel = BrowserPeekPanel(contentRect: frame, standalone: false)
        window.addChildWindow(panel, ordered: .above)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.watchParent(window)
        return panel
    }

    /// Typed text becomes a URL or a search with the chosen search engine.
    static func resolvedURLString(for input: String) -> String? {
        let resolver = BrowserNavigationResolver(searchEngineProvider: { BrowserUserPreferencesStore().searchEngine })
        return resolver.resolve(input).map { resolution in
            BrowserInternalURLNormalizer.canonicalURLString(for: resolution.resolvedURLString)
                ?? resolution.resolvedURLString
        }
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

    /// `⌘L` edits the small window's address, `⌘O` opens the page as a tab and `⇧⌘O`
    /// shows Open In. The app asks before its own shortcuts.
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
            item.image = NSImage(systemSymbolName: space.systemImageName, accessibilityDescription: nil)
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
            height: height
        )
    }

    @objc func dismiss() {
        stopWatchingParent()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    // MARK: Private

    private var parentMonitor: Any?
    private var currentURLString = ""

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
        guard let card = contentView else { return }
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
            height: 16
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
    // MARK: Lifecycle

    init(id: String, title: String, systemImageName: String) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
    }

    // MARK: Internal

    @objc let id: String
    @objc let title: String
    @objc let systemImageName: String
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
    /// Peek for Shift-clicked links, on unless turned off in Settings.
    @objc static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: BrowserUserPreferencesStore.peekEnabledKey) as? Bool ?? true
    }

    /// Option-Command-click into the small window, off unless turned on.
    @objc static var opensOptionCommandClicksInLittleWindow: Bool {
        UserDefaults.standard.bool(forKey: BrowserUserPreferencesStore.littleWindowOptionCommandClickKey)
    }
}
