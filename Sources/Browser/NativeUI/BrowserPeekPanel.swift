import AppKit

// MARK: - BrowserPeekPanel

/// Peek: a Shift-clicked link opens in a floating card over the window.
/// The card has the page's host, Open as Tab and Close; Escape, Close or a
/// click on the window behind closes it. The engine puts its page in
/// `hostView`.
@objc final class BrowserPeekPanel: NSPanel {
    // MARK: Lifecycle

    private init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        let card = NSVisualEffectView()
        card.material = .windowBackground
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.masksToBounds = true
        card.autoresizingMask = [.width, .height]
        card.frame = NSRect(origin: .zero, size: contentRect.size)
        contentView = card
        for view in [closeButton, hostLabel, openButton, hostView] {
            card.addSubview(view)
        }
        hostLabel.alignment = .center
        hostLabel.lineBreakMode = .byTruncatingMiddle
        closeButton.onAction = { [weak self] in self?.onClose?() }
        openButton.onAction = { [weak self] in self?.onOpenInTab?() }
        closeButton.setAccessibilityIdentifier("browser.peek.close")
        openButton.setAccessibilityIdentifier("browser.peek.open-in-tab")
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

    @objc let hostView = NSView()
    @objc var onClose: (() -> Void)?
    @objc var onOpenInTab: (() -> Void)?

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
    let hostLabel = BrowserNativeControls.label("", size: 12, weight: .medium, color: BrowserChromeColors.secondaryText)

    override var canBecomeKey: Bool { true }

    /// The card's frame for a parent window, centered over its content.
    static func frame(over window: NSWindow) -> NSRect {
        let parent = window.frame
        let width = (parent.width * windowFraction).rounded()
        let height = (parent.height * windowFraction).rounded()
        return NSRect(x: parent.midX - width / 2, y: parent.midY - height / 2, width: width, height: height).integral
    }

    @objc(presentOverWindow:) static func present(over window: NSWindow) -> BrowserPeekPanel {
        let frame = frame(over: window)
        let panel = BrowserPeekPanel(contentRect: frame)
        window.addChildWindow(panel, ordered: .above)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.watchParent(window)
        return panel
    }

    @objc(updateWithURLString:) func update(urlString: String) {
        let host = URL(string: urlString)?.host.map(BrowserURLDisplayFormatter.hostDisplayString(forHost:))
        hostLabel.stringValue = host ?? BrowserURLDisplayFormatter.displayString(for: urlString)
        hostView.setAccessibilityLabel(hostLabel.stringValue)
    }

    @objc func dismiss() {
        stopWatchingParent()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_: Any?) {
        onClose?()
    }

    /// Close Window and Command-W reach the card without a title bar button.
    override func performClose(_: Any?) {
        onClose?()
    }

    // MARK: Private

    private var parentMonitor: Any?

    private func layoutCard() {
        guard let card = contentView else { return }
        let bounds = card.bounds
        let size = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let y = bounds.height - Self.barHeight + ((Self.barHeight - size) / 2).rounded()
        closeButton.frame = NSRect(x: 6, y: y, width: size, height: size)
        openButton.frame = NSRect(x: bounds.width - 6 - size, y: y, width: size, height: size)
        hostLabel.frame = NSRect(
            x: closeButton.frame.maxX + 8,
            y: bounds.height - Self.barHeight + (Self.barHeight - 16) / 2,
            width: max(openButton.frame.minX - closeButton.frame.maxX - 16, 0),
            height: 16
        )
        hostView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - Self.barHeight, 0))
        hostView.autoresizingMask = [.width, .height]
    }

    /// A click on the window behind closes the card.
    private func watchParent(_ window: NSWindow) {
        parentMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === window else { return event }
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

// MARK: - BrowserPeekSettings

/// Read by the engine when a link asks for a new window.
@objc final class BrowserPeekSettings: NSObject {
    /// Peek for Shift-clicked links, on unless turned off in Settings.
    @objc static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: BrowserUserPreferencesStore.peekEnabledKey) as? Bool ?? true
    }
}

