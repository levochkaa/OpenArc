// BrowserWindowSessions.swift

import AppKit

// MARK: - BrowserWindowContentContainerView

final class BrowserWindowContentContainerView: NSView {
    // MARK: Internal

    static let defaultCornerRadius: CGFloat = BrowserWindowGeometry.windowCornerRadius

    var cornerRadius: CGFloat = defaultCornerRadius {
        didSet {
            guard cornerRadius != oldValue else {
                return
            }

            updateCornerRadius()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateCornerRadius()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Private

    private func updateCornerRadius() {
        layer?.cornerRadius = cornerRadius
    }
}

// MARK: - BrowserMainWindow

final class BrowserMainWindow: NSWindow {
    // MARK: Internal

    override var undoManager: UndoManager? {
        browserUndoManager ?? super.undoManager
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override var styleMask: NSWindow.StyleMask {
        didSet {
            updateWindowShape()
        }
    }

    override var contentView: NSView? {
        didSet {
            updateWindowShape()
        }
    }

    var browserUndoManager: UndoManager?

    /// A borderless window would otherwise disable File > Close Window.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(performClose(_:)) ? true : super.validateUserInterfaceItem(item)
    }

    /// A borderless window has no close button, so AppKit's own version only beeps.
    override func performClose(_: Any?) {
        guard delegate?.windowShouldClose?(self) ?? true else { return }
        close()
    }

    func configureBrowserChrome() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior.insert(.fullScreenPrimary)
        updateWindowShape()
    }

    // MARK: Private

    private func updateWindowShape() {
        guard let containerView = contentView as? BrowserWindowContentContainerView else {
            return
        }

        containerView.cornerRadius = styleMask.contains(.fullScreen)
            ? 0
            : BrowserWindowContentContainerView.defaultCornerRadius
    }
}

// MARK: - BrowserIncognitoWindowSession

final class BrowserIncognitoWindowSession {
    // MARK: Internal

    let window: NSWindow
    let chromeModel: BrowserChromeModel

    init(window: NSWindow, chromeModel: BrowserChromeModel) {
        self.window = window
        self.chromeModel = chromeModel
    }
}

// MARK: - BrowserWebAppWindowSession

final class BrowserWebAppWindowSession {
    // MARK: Internal

    let window: NSWindow
    let chromeModel: BrowserChromeModel
    let configuration: BrowserWebAppConfiguration
    let preferences: BrowserWebAppPreferences

    init(
        window: NSWindow,
        chromeModel: BrowserChromeModel,
        configuration: BrowserWebAppConfiguration,
        preferences: BrowserWebAppPreferences,
    ) {
        self.window = window
        self.chromeModel = chromeModel
        self.configuration = configuration
        self.preferences = preferences
    }
}

// MARK: - BrowserProfileWindowSession

final class BrowserProfileWindowSession {
    // MARK: Internal

    let window: NSWindow
    let chromeModel: BrowserChromeModel
    let accountStore: BrowserAccountStore
    let shareStore: BrowserShareStore
    let profile: BrowserProfile

    init(
        window: NSWindow,
        chromeModel: BrowserChromeModel,
        accountStore: BrowserAccountStore,
        shareStore: BrowserShareStore,
        profile: BrowserProfile,
    ) {
        self.window = window
        self.chromeModel = chromeModel
        self.accountStore = accountStore
        self.shareStore = shareStore
        self.profile = profile
    }
}
