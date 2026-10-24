import AppKit

// MARK: - BrowserPeekPanel

/// Peek: a Shift-clicked link opens in a floating card over the window.
/// The card has the page's host, Open as Tab and Close; Escape, Close or a
/// click on the window behind closes it. Standalone, it is a
/// small window of its own for links from other apps. The engine puts its page
/// in `hostView`.
@objc final class BrowserPeekPanel: NSPanel {
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

    override var canBecomeKey: Bool { true }

    /// A small window rather than a Peek card.
    @objc let isStandalone: Bool
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

    // MARK: Private

    private var parentMonitor: Any?

    /// The bar keeps its place on resize; the small window leaves room for the
    /// traffic lights instead of a Close button.
    private func layoutCard() {
        guard let card = contentView else { return }
        let bounds = card.bounds
        let size = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let y = bounds.height - Self.barHeight + ((Self.barHeight - size) / 2).rounded()
        closeButton.frame = NSRect(x: 6, y: y, width: size, height: size)
        openButton.frame = NSRect(x: bounds.width - 6 - size, y: y, width: size, height: size)
        let labelX = isStandalone ? 78 : closeButton.frame.maxX + 8
        hostLabel.frame = NSRect(
            x: labelX,
            y: bounds.height - Self.barHeight + (Self.barHeight - 16) / 2,
            width: max(openButton.frame.minX - 8 - labelX, 0),
            height: 16
        )
        hostView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - Self.barHeight, 0))
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        openButton.autoresizingMask = [.minXMargin, .minYMargin]
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

// MARK: - BrowserPeekSettings

/// Read by the engine when a link asks for a new window.
@objc final class BrowserPeekSettings: NSObject {
    /// Peek for Shift-clicked links, on unless turned off in Settings.
    @objc static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: BrowserUserPreferencesStore.peekEnabledKey) as? Bool ?? true
    }
}
