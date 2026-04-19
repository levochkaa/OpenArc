import AppKit
import SwiftUI

enum BrowserWindowControlsLayout {
    static let buttonSize: CGFloat = 14
    static let controlsHeight: CGFloat = buttonSize
    static let buttonSpacing: CGFloat = 7
    static let controlsWidth: CGFloat = buttonSize * 3 + buttonSpacing * 2
    static let trailingSpacing: CGFloat = 6
    static let totalWidth: CGFloat = controlsWidth + trailingSpacing
}

struct BrowserWindowControlsView: NSViewRepresentable {
    var showsInSidebar: Bool

    func makeNSView(context _: Context) -> BrowserWindowControlsHostView {
        let view = BrowserWindowControlsHostView()
        view.showsInSidebar = showsInSidebar
        return view
    }

    func updateNSView(_ nsView: BrowserWindowControlsHostView, context _: Context) {
        nsView.showsInSidebar = showsInSidebar
    }
}

final class BrowserWindowControlsHostView: NSView {
    private enum DisplayMode {
        case hidden
        case sidebar
        case system
    }

    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private weak var observedWindow: NSWindow?
    private var customButtons: [NSWindow.ButtonType: NSButton] = [:]

    var showsInSidebar = true {
        didSet {
            guard showsInSidebar != oldValue else {
                return
            }

            invalidateIntrinsicContentSize()
            updateWindowButtons()
        }
    }

    override var intrinsicContentSize: NSSize {
        let shouldReserveSidebarWidth =
            showsInSidebar &&
            !(window?.styleMask.contains(.fullScreen) ?? false)

        return NSSize(
            width: shouldReserveSidebarWidth ? BrowserWindowControlsLayout.totalWidth : 0,
            height: BrowserWindowControlsLayout.controlsHeight
        )
    }

    deinit {
        updateSystemButtons(hidden: false, for: observedWindow)
        stopObservingWindow()
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

    @objc
    private func handleWindowStateChange(_: Notification) {
        invalidateIntrinsicContentSize()
        updateWindowButtons()
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else {
            return
        }

        updateSystemButtons(hidden: false, for: observedWindow)
        stopObservingWindow()

        guard let window else {
            return
        }

        observedWindow = window
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowStateChange(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    private func stopObservingWindow() {
        guard let observedWindow else {
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didEnterFullScreenNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didExitFullScreenNotification,
            object: observedWindow
        )
        self.observedWindow = nil
    }

    private var displayMode: DisplayMode {
        guard let window else {
            return .hidden
        }

        if window.styleMask.contains(.fullScreen) {
            return .system
        }

        return showsInSidebar ? .sidebar : .hidden
    }

    private func ensureCustomButtons() {
        guard customButtons.isEmpty, let window else {
            return
        }

        var styleMask = window.styleMask
        styleMask.remove(.fullScreen)

        for buttonType in buttonTypes {
            guard let button = NSWindow.standardWindowButton(buttonType, for: styleMask) else {
                continue
            }

            button.target = self
            button.action = action(for: buttonType)
            button.translatesAutoresizingMaskIntoConstraints = true
            button.autoresizingMask = []
            addSubview(button)
            customButtons[buttonType] = button
        }

        layoutCustomButtons()
    }

    private func updateWindowButtons() {
        ensureCustomButtons()
        syncCustomButtonState()

        switch displayMode {
        case .hidden:
            updateSystemButtons(hidden: true, for: window)
            setCustomButtonsHidden(true)
        case .sidebar:
            updateSystemButtons(hidden: true, for: window)
            setCustomButtonsHidden(false)
            layoutCustomButtons()
        case .system:
            updateSystemButtons(hidden: false, for: window)
            setCustomButtonsHidden(true)
        }
    }

    private func syncCustomButtonState() {
        guard let window else {
            return
        }

        for buttonType in buttonTypes {
            guard
                let customButton = customButtons[buttonType],
                let systemButton = window.standardWindowButton(buttonType)
            else {
                continue
            }

            customButton.isEnabled = systemButton.isEnabled
            customButton.toolTip = systemButton.toolTip
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

    private func setCustomButtonsHidden(_ hidden: Bool) {
        customButtons.values.forEach {
            $0.isHidden = hidden
        }
    }

    private func action(for buttonType: NSWindow.ButtonType) -> Selector {
        switch buttonType {
        case .closeButton:
            return #selector(closeWindow(_:))
        case .miniaturizeButton:
            return #selector(miniaturizeWindow(_:))
        case .zoomButton:
            return #selector(toggleFullScreen(_:))
        default:
            return #selector(toggleFullScreen(_:))
        }
    }

    @objc
    private func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc
    private func miniaturizeWindow(_ sender: Any?) {
        window?.performMiniaturize(sender)
    }

    @objc
    private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }
}
