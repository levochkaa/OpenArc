import AppKit

// MARK: - BrowserWindowControlsHostView

final class BrowserWindowControlsHostView: NSView {
    // MARK: Lifecycle

    isolated deinit {
        if managesSystemButtons {
            updateSystemButtons(hidden: false, for: observedWindow)
        }
        stopObservingWindow()
    }

    // MARK: Internal

    override var intrinsicContentSize: NSSize {
        let shouldReserveSidebarWidth =
            showsInSidebar &&
            (showsSidebarControlsDuringFullscreenExit || !usesSystemFullscreenControls)

        return NSSize(
            width: shouldReserveSidebarWidth ? BrowserWindowControlsLayout.totalWidth : 0,
            height: BrowserWindowControlsLayout.controlsHeight
        )
    }

    /// The sidebar header's host hides the system buttons it replaces. Other
    /// hosts in the same window, such as a split pane bar, leave them alone,
    /// so removing one never brings the system buttons back.
    var managesSystemButtons = true

    var showsInSidebar = true {
        didSet {
            guard showsInSidebar != oldValue else {
                return
            }

            invalidateIntrinsicContentSize()
            updateWindowButtons()
        }
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()
        ensureCustomButtons()
        invalidateIntrinsicContentSize()
        updateWindowButtons()
    }

    override func layout() {
        super.layout()
        layoutCustomButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setGroupHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setGroupHovered(false)
    }

    // MARK: Private

    private enum DisplayMode {
        case hidden
        case sidebar
        case system
    }

    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private weak var observedWindow: NSWindow?
    private var customButtons = [NSWindow.ButtonType: BrowserTrafficLightButton]()
    private var hoverTrackingArea: NSTrackingArea?
    private var isGroupHovered = false
    private var suppressCustomButtonsUntilNextUpdate = false
    private var hideSystemButtonsForFullscreenTransition = false
    private var showsSidebarControlsDuringFullscreenExit = false

    private var displayMode: DisplayMode {
        guard window != nil else {
            return .hidden
        }

        if showsSidebarControlsDuringFullscreenExit {
            return showsInSidebar ? .sidebar : .hidden
        }

        if usesSystemFullscreenControls {
            return .system
        }

        return showsInSidebar ? .sidebar : .hidden
    }

    private var hasSystemWindowButtons: Bool {
        guard let window else {
            return false
        }

        return buttonTypes.allSatisfy { window.standardWindowButton($0) != nil }
    }

    private var usesSystemFullscreenControls: Bool {
        guard let window else {
            return false
        }

        return hasSystemWindowButtons && window.styleMask.contains(.fullScreen)
    }

    private var shouldHideSystemButtons: Bool {
        if hideSystemButtonsForFullscreenTransition {
            return true
        }

        switch displayMode {
        case .system:
            return false
        case .hidden, .sidebar:
            return true
        }
    }

    @objc private func handleWindowStateChange(_ notification: Notification) {
        let shouldUseSystemFullscreenControls = hasSystemWindowButtons

        switch notification.name {
        case NSWindow.willEnterFullScreenNotification:
            showsSidebarControlsDuringFullscreenExit = false
            hideSystemButtonsForFullscreenTransition = shouldUseSystemFullscreenControls
            suppressCustomButtonsUntilNextUpdate = shouldUseSystemFullscreenControls
            setGroupHovered(false)
        case NSWindow.didEnterFullScreenNotification:
            showsSidebarControlsDuringFullscreenExit = false
            hideSystemButtonsForFullscreenTransition = false
            suppressCustomButtonsUntilNextUpdate = shouldUseSystemFullscreenControls
            setGroupHovered(false)
        case NSWindow.willExitFullScreenNotification:
            showsSidebarControlsDuringFullscreenExit = true
            hideSystemButtonsForFullscreenTransition = shouldUseSystemFullscreenControls
            suppressCustomButtonsUntilNextUpdate = false
            setGroupHovered(false)
        case NSWindow.didExitFullScreenNotification:
            showsSidebarControlsDuringFullscreenExit = false
            hideSystemButtonsForFullscreenTransition = false
            suppressCustomButtonsUntilNextUpdate = false
            setGroupHovered(false)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                invalidateIntrinsicContentSize()
                updateWindowButtons()
            }
        case NSApplication.didResignActiveNotification,
             NSWindow.didResignKeyNotification,
             NSWindow.didResignMainNotification:
            setGroupHovered(false)
        case NSApplication.didBecomeActiveNotification,
             NSWindow.didBecomeKeyNotification,
             NSWindow.didBecomeMainNotification:
            updateGroupHoverFromCurrentMouseLocation()
        default:
            break
        }

        invalidateIntrinsicContentSize()
        updateWindowButtons()
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else {
            return
        }

        if managesSystemButtons {
            updateSystemButtons(hidden: false, for: observedWindow)
        }
        stopObservingWindow()

        guard let window else {
            return
        }

        observedWindow = window
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.willExitFullScreenNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didResignMainNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func stopObservingWindow() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }

    private func ensureCustomButtons() {
        guard customButtons.isEmpty else {
            return
        }

        for buttonType in buttonTypes {
            let button = BrowserTrafficLightButton(buttonType: buttonType)
            button.target = self
            button.action = action(for: buttonType)
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            button.setAccessibilityIdentifier("browser.window.control.\(buttonType.rawValue)")
            if buttonType == .closeButton {
                button.setAccessibilityLabel(BrowserStrings.webAppCloseWindowAction)
            }
            addSubview(button)
            customButtons[buttonType] = button
        }

        layoutCustomButtons()
    }

    private func updateWindowButtons() {
        ensureCustomButtons()
        syncCustomButtonState()
        if managesSystemButtons {
            updateSystemButtons(hidden: shouldHideSystemButtons, for: window)
        }

        switch displayMode {
        case .hidden:
            setCustomButtonsHidden(true)
        case .sidebar:
            setCustomButtonsHidden(suppressCustomButtonsUntilNextUpdate)
            layoutCustomButtons()
        case .system:
            setCustomButtonsHidden(true)
        }
    }

    private func syncCustomButtonState() {
        guard let window else {
            return
        }

        let isWindowFocused = NSApp.isActive && (window.isKeyWindow || window.isMainWindow)

        for buttonType in buttonTypes {
            guard let customButton = customButtons[buttonType] else {
                continue
            }

            let systemButton = window.standardWindowButton(buttonType)
            let isEnabled = systemButton?.isEnabled ?? fallbackEnabledState(for: buttonType, in: window)

            customButton.isEnabled = isEnabled
            customButton.toolTip = systemButton?.toolTip
            customButton.isWindowFocused = isWindowFocused
            customButton.showsHoverState = isGroupHovered
        }
    }

    private func layoutCustomButtons() {
        let originY = floor((bounds.height - BrowserWindowControlsLayout.buttonSize) / 2)

        for (index, buttonType) in buttonTypes.enumerated() {
            guard let button = customButtons[buttonType] else {
                continue
            }

            let originX = CGFloat(index) * (
                BrowserWindowControlsLayout.buttonSize + BrowserWindowControlsLayout.buttonSpacing
            )
            button.frame = NSRect(
                x: originX,
                y: originY,
                width: BrowserWindowControlsLayout.buttonSize,
                height: BrowserWindowControlsLayout.buttonSize
            )
        }
    }

    private func updateSystemButtons(hidden: Bool, for window: NSWindow?) {
        guard let window else {
            return
        }

        for buttonType in buttonTypes {
            window.standardWindowButton(buttonType)?.isHidden = hidden
        }
    }

    private func fallbackEnabledState(for buttonType: NSWindow.ButtonType, in window: NSWindow) -> Bool {
        switch buttonType {
        case .closeButton:
            true
        case .miniaturizeButton:
            window.styleMask.contains(.miniaturizable) && !window.styleMask.contains(.fullScreen)
        case .zoomButton:
            window.collectionBehavior.contains(.fullScreenPrimary) || window.styleMask.contains(.resizable)
        default:
            true
        }
    }

    private func setCustomButtonsHidden(_ hidden: Bool) {
        for value in customButtons.values {
            value.isHidden = hidden
        }

        if hidden {
            setGroupHovered(false)
        }
    }

    private func setGroupHovered(_ hovered: Bool) {
        guard hovered != isGroupHovered else {
            return
        }

        isGroupHovered = hovered
        for value in customButtons.values {
            value.showsHoverState = hovered
        }
    }

    private func updateGroupHoverFromCurrentMouseLocation() {
        guard let window else {
            setGroupHovered(false)
            return
        }

        let locationInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setGroupHovered(bounds.contains(locationInView))
    }

    private func action(for buttonType: NSWindow.ButtonType) -> Selector {
        switch buttonType {
        case .closeButton:
            #selector(closeWindow(_:))
        case .miniaturizeButton:
            #selector(miniaturizeWindow(_:))
        case .zoomButton:
            #selector(toggleFullScreen(_:))
        default:
            #selector(toggleFullScreen(_:))
        }
    }

    @objc private func closeWindow(_: Any?) {
        guard let window else {
            return
        }

        if window.delegate?.windowShouldClose?(window) == false {
            return
        }

        window.close()
    }

    @objc private func miniaturizeWindow(_ sender: Any?) {
        window?.performMiniaturize(sender)
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }
}

// MARK: - BrowserTrafficLightButton

private final class BrowserTrafficLightButton: NSButton {
    // MARK: Lifecycle

    init(buttonType: NSWindow.ButtonType) {
        self.buttonType = buttonType
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = nil
        focusRingType = .none
        setButtonType(.momentaryPushIn)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else {
                return
            }

            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: BrowserWindowControlsLayout.buttonSize, height: BrowserWindowControlsLayout.buttonSize)
    }

    var isWindowFocused = true {
        didSet {
            guard isWindowFocused != oldValue else {
                return
            }

            needsDisplay = true
        }
    }

    var showsHoverState = false {
        didSet {
            guard showsHoverState != oldValue else {
                return
            }

            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        guard let image = Self.image(named: currentAssetName) else {
            return
        }

        image.draw(in: bounds)
    }

    // MARK: Private

    private enum VisualState {
        case disabled
        case unfocused
        case normal
        case hover
        case pressed
    }

    private enum AssetName: String {
        case closeNormal = "TrafficLightCloseNormal"
        case closeHover = "TrafficLightCloseHover"
        case closePressed = "TrafficLightClosePressed"
        case minimizeNormal = "TrafficLightMinimizeNormal"
        case minimizeHover = "TrafficLightMinimizeHover"
        case minimizePressed = "TrafficLightMinimizePressed"
        case fullscreenNormal = "TrafficLightFullscreenNormal"
        case fullscreenHover = "TrafficLightFullscreenHover"
        case fullscreenPressed = "TrafficLightFullscreenPressed"
    }

    private static var imageCache = [AssetName: NSImage]()

    private let buttonType: NSWindow.ButtonType

    private var visualState: VisualState {
        if !isEnabled {
            return .disabled
        }

        if !isWindowFocused {
            return .unfocused
        }

        if cell?.isHighlighted == true {
            return .pressed
        }

        if showsHoverState {
            return .hover
        }

        return .normal
    }

    private var currentAssetName: AssetName {
        switch visualState {
        case .disabled:
            normalAssetName
        case .normal, .unfocused:
            normalAssetName
        case .hover:
            switch buttonType {
            case .closeButton:
                .closeHover
            case .miniaturizeButton:
                .minimizeHover
            case .zoomButton:
                .fullscreenHover
            default:
                .fullscreenHover
            }
        case .pressed:
            switch buttonType {
            case .closeButton:
                .closePressed
            case .miniaturizeButton:
                .minimizePressed
            case .zoomButton:
                .fullscreenPressed
            default:
                .fullscreenPressed
            }
        }
    }

    private var normalAssetName: AssetName {
        switch buttonType {
        case .closeButton:
            .closeNormal
        case .miniaturizeButton:
            .minimizeNormal
        case .zoomButton:
            .fullscreenNormal
        default:
            .fullscreenNormal
        }
    }

    private static func image(named assetName: AssetName) -> NSImage? {
        if let image = imageCache[assetName] {
            return image
        }

        guard let image = NSImage(named: NSImage.Name(assetName.rawValue)) else {
            assertionFailure("Missing traffic light asset: \(assetName.rawValue)")
            return nil
        }

        let resizedImage = BrowserImageThumbnailer.resizedImage(
            image,
            fitting: BrowserWindowControlsLayout.buttonSize
        ) ?? image
        resizedImage.isTemplate = false
        imageCache[assetName] = resizedImage
        return resizedImage
    }
}
