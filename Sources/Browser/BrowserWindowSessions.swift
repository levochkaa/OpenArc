import AppKit

// MARK: - BrowserWindowContentContainerView

final class BrowserWindowContentContainerView: NSView {
    // MARK: Lifecycle

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
    // MARK: Lifecycle

    init(window: NSWindow, chromeModel: BrowserChromeModel) {
        self.window = window
        self.chromeModel = chromeModel
    }

    // MARK: Internal

    let window: NSWindow
    let chromeModel: BrowserChromeModel
}

// MARK: - BrowserWebAppWindowSession

final class BrowserWebAppWindowSession {
    // MARK: Lifecycle

    init(
        window: NSWindow,
        chromeModel: BrowserChromeModel,
        configuration: BrowserWebAppConfiguration,
        preferences: BrowserWebAppPreferences
    ) {
        self.window = window
        self.chromeModel = chromeModel
        self.configuration = configuration
        self.preferences = preferences
    }

    // MARK: Internal

    let window: NSWindow
    let chromeModel: BrowserChromeModel
    let configuration: BrowserWebAppConfiguration
    let preferences: BrowserWebAppPreferences
}

// MARK: - BrowserProfileWindowSession

final class BrowserProfileWindowSession {
    // MARK: Lifecycle

    init(
        window: NSWindow,
        chromeModel: BrowserChromeModel,
        accountStore: BrowserAccountStore,
        profile: BrowserProfile
    ) {
        self.window = window
        self.chromeModel = chromeModel
        self.accountStore = accountStore
        self.profile = profile
    }

    // MARK: Internal

    let window: NSWindow
    let chromeModel: BrowserChromeModel
    let accountStore: BrowserAccountStore
    let profile: BrowserProfile
}
