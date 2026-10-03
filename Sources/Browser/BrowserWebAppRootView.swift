import AppKit
import Combine
import QuartzCore

// MARK: - BrowserWebAppViewActions

struct BrowserWebAppViewActions {
    let showAppInfo: () -> Void
    let openInBrowser: () -> Void
    let uninstall: () -> Void
}

// MARK: - BrowserWebAppRootView

final class BrowserWebAppRootView: NSView {
    // MARK: Lifecycle

    init(
        model: BrowserChromeModel,
        configuration: BrowserWebAppConfiguration,
        preferences: BrowserWebAppPreferences,
        actions: BrowserWebAppViewActions
    ) {
        self.model = model
        self.preferences = preferences
        self.content = BrowserContentNSView(hostView: model.hostView)
        self.toolbar = BrowserWebAppToolbarNSView(
            model: model,
            preferences: preferences,
            configuration: configuration,
            actions: actions
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.webapp.window")
        for view in [background, content, toolbar, margins, find, fullscreen] {
            addSubview(view)
        }
        find.bind(to: model)
        content.bindTabCreation(to: model)
        fullscreen.onFullscreenStateChange = { [weak self] state in self?.isFullscreen = state.isFullscreen
            self?.refresh()
        }
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            preferences.objectWillChange.eraseToAnyPublisher(),
            model.userPreferencesStore.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    // MARK: Internal

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let geometry = windowLayout
        background.frame = bounds
        let contentFrame = NSRect(
            x: geometry.contentHorizontalInset,
            y: geometry.contentMinY,
            width: max(bounds.width - geometry.contentHorizontalInset * 2, 0),
            height: max(
                bounds.height - geometry.contentMinY - geometry.contentBottomInset,
                0
            )
        )
        let toolbarFrame = NSRect(
            x: geometry.toolbarHorizontalInset,
            y: geometry.toolbarTopInset,
            width: max(bounds.width - geometry.toolbarHorizontalInset * 2, 0),
            height: BrowserWebAppLayout.toolbarHeight
        )
        frameTransitions.setFrame(contentFrame, of: content, animated: animateNextLayout, curve: .sidebar)
        frameTransitions.setFrame(toolbarFrame, of: toolbar, animated: animateNextLayout, curve: .sidebar)
        frameTransitions.setFrame(contentFrame, of: find, animated: animateNextLayout, curve: .sidebar)
        animateNextLayout = false
        margins.frame = bounds
        margins.configure(
            blockedLeadingWidth: 0,
            leading: geometry.edgeDragInset,
            top: geometry.edgeDragInset,
            trailing: geometry.edgeDragInset,
            bottom: geometry.edgeDragInset
        )
    }

    // MARK: Private

    private let model: BrowserChromeModel
    private let preferences: BrowserWebAppPreferences
    private let background = BrowserChromeBackgroundNSView()
    private let content: BrowserContentNSView
    private let toolbar: BrowserWebAppToolbarNSView
    private let margins = BrowserNativeWindowMargins()
    private let find = BrowserFindBarNSView()
    private let fullscreen = BrowserWindowFullscreenReaderNSView()
    private var isFullscreen = false
    private var previousShowsToolbar: Bool?
    private var animateNextLayout = false
    private let frameTransitions = BrowserNativeFrameTransitions()
    private let toolbarVisibility = BrowserNativeVisibilityAnimation()
    private var observations = Set<AnyCancellable>()

    private var showsToolbar: Bool { !isFullscreen || preferences.alwaysShowsToolbarInFullscreen }
    private var windowLayout: BrowserWebAppWindowLayout { .init(isFullscreen: isFullscreen, showsToolbar: showsToolbar)
    }

    private func refresh() {
        background.mode = model.userPreferencesStore.blurredChromeBackgroundEnabled ? .blurred : .black
        content.update(
            hostView: model.hostView,
            isContextReady: model.isContextReady,
            hasSelectedTab: model.selectedTabID != nil,
            isSidebarVisible: false,
            usesWindowContentInsets: windowLayout.usesWindowContentInsets,
            selectedTabCreationState: model.selectedTabCreationState
        )
        if let previousShowsToolbar, previousShowsToolbar != showsToolbar {
            animateNextLayout = true
        }
        previousShowsToolbar = showsToolbar
        toolbarVisibility.setVisible(showsToolbar, view: toolbar, curve: .sidebar)
        toolbar.windowControlsWidth = windowLayout.windowControlsWidth
        toolbar.refresh()
        find.refresh(from: model, blockedLeadingInset: 0)
        needsLayout = true
    }
}
