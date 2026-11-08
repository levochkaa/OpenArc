// BrowserNativeSidebarHeaderNSView.swift

import AppKit
import Combine

final class BrowserNativeSidebarHeaderNSView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    let urlControls: BrowserSiteControlsNSView
    var onToggleSidebar: () -> Void = {}

    // MARK: Private

    private let model: BrowserChromeModel
    private let windowControls = BrowserWindowControlsHostView()
    private let toggle = BrowserNativeChromeButton(
        symbol: "sidebar.left",
        title: BrowserStrings.sidebarHide,
        style: .sidebarNavigation,
        pressEffect: .compress,
        action: {},
    )
    private let back = BrowserNativeChromeButton(
        symbol: "arrow.backward",
        title: BrowserStrings.navigationBack,
        style: .sidebarNavigation,
        pressEffect: .left,
        action: {},
    )
    private lazy var reloadMenu = BrowserNativeChromeButton(
        symbol: "chevron.down",
        title: BrowserStrings.developerReloadOptions,
        style: .miniPlayer,
        pressEffect: .compress,
        action: { [weak self] in self?.showReloadMenu() },
    )
    private let forward = BrowserNativeChromeButton(
        symbol: "arrow.forward",
        title: BrowserStrings.navigationForward,
        style: .sidebarNavigation,
        pressEffect: .right,
        action: {},
    )
    private lazy var reloadSymbol = BrowserReloadSymbolState { [weak self] in self?.refresh() }
    private let reload = BrowserNativeChromeButton(
        symbol: "arrow.clockwise",
        title: BrowserStrings.navigationRefresh,
        style: .sidebarNavigation,
        pressEffect: .rotateClockwise,
        action: {},
    )
    private let profile = BrowserNativeSurface()
    private let profileIcon = NSImageView()
    private let profileName = BrowserNativeControls.label(
        "",
        size: 12,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
    )
    private var observations = Set<AnyCancellable>()
    private var showsURL = true
    private var showsNavigation = true

    var preferredHeight: CGFloat {
        let profileHeight: CGFloat = model.showsProfileIndicator ? 28 + BrowserChromeLayout.sidebarSectionSpacing : 0
        let urlHeight: CGFloat = showsURL
            ? BrowserChromeLayout.sidebarRowHeight + BrowserChromeLayout.sidebarSectionSpacing
            : 0
        return BrowserChromeLayout.chromeButtonSize + profileHeight + urlHeight
    }

    private var isMirrored: Bool { model.userPreferencesStore.sidebarPosition == .right }

    init(model: BrowserChromeModel) {
        self.model = model
        self.urlControls = BrowserSiteControlsNSView(model: model, mode: .sidebar)
        super.init(frame: .zero)
        for view in [windowControls, toggle, back, forward, reload, reloadMenu, profile, urlControls] {
            addSubview(view)
        }
        profile.addSubview(profileIcon)
        profile.addSubview(profileName)
        profile.cornerRadius = 7
        profile.strokeWidth = 0
        profile.fillColor = BrowserChromeColors.currentURLRow
        profileIcon.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: 13,
                weight: .semibold,
            ))
        profileIcon.contentTintColor = BrowserChromeColors.secondaryText
        toggle.onAction = { [weak self] in self?.onToggleSidebar() }
        toggle.setAccessibilityIdentifier("browser.sidebar.toggle")
        back.onAction = { [weak model] in model?.goBack() }
        forward.onAction = { [weak model] in model?.goForward() }
        back.onSecondaryClick = { [weak model, weak back] in
            if let back { model?.showNavigationList(goingBack: true, below: back) }
        }
        forward.onSecondaryClick = { [weak model, weak forward] in
            if let forward { model?.showNavigationList(goingBack: false, below: forward) }
        }
        reload
            .onAction = { [weak self, weak model] in
                if self?.reloadSymbol.showsStop == true {
                    model?.stopLoadingCurrentTab()
                } else {
                    model?.reloadRespectingDeveloperMode()
                }
            }
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.sidebarChromeButtonSize
        let spacing = BrowserChromeLayout.sidebarChromeButtonSpacing
        let buttonY = BrowserChromeLayout.sidebarHeaderButtonY
        let controlsWidth = windowControls.intrinsicContentSize.width
        let menuWidth: CGFloat = model.isDeveloperModeOn ? 14 : 0
        // A sidebar on the right mirrors the row: window controls and the
        // toggle at the right edge, navigation at the left with Reload outermost.
        if isMirrored {
            windowControls.frame = NSRect(
                x: bounds.width - BrowserChromeLayout.sidebarWindowControlsLeading - controlsWidth,
                y: 0,
                width: controlsWidth,
                height: size,
            )
            toggle.frame = NSRect(
                x: controlsWidth > 0
                    ? windowControls.frame.minX - BrowserChromeLayout.sidebarWindowControlsToggleGap - size
                    : bounds.width - size,
                y: buttonY,
                width: size,
                height: size,
            )
            reload.frame = NSRect(
                x: -BrowserChromeLayout.sidebarHeaderTrailingOverhang,
                y: buttonY,
                width: size,
                height: size,
            )
            reloadMenu.frame = NSRect(x: reload.frame.maxX - 4, y: buttonY, width: menuWidth + 4, height: size)
            back.frame = reload.frame.offsetBy(dx: size + spacing + menuWidth, dy: 0)
            forward.frame = back.frame.offsetBy(dx: size + spacing, dy: 0)
        } else {
            windowControls.frame = NSRect(
                x: BrowserChromeLayout.sidebarWindowControlsLeading,
                y: 0,
                width: controlsWidth,
                height: size,
            )
            toggle.frame = NSRect(
                x: controlsWidth > 0
                    ? windowControls.frame.maxX + BrowserChromeLayout.sidebarWindowControlsToggleGap
                    : 0,
                y: buttonY,
                width: size,
                height: size,
            )
            reload.frame = NSRect(
                x: bounds.width + BrowserChromeLayout.sidebarHeaderTrailingOverhang - size - menuWidth,
                y: buttonY,
                width: size,
                height: size,
            )
            reloadMenu.frame = NSRect(x: reload.frame.maxX - 4, y: buttonY, width: menuWidth + 4, height: size)
            forward.frame = reload.frame.offsetBy(dx: -(size + spacing), dy: 0)
            back.frame = forward.frame.offsetBy(dx: -(size + spacing), dy: 0)
        }
        var y = BrowserChromeLayout.chromeButtonSize
        if !profile.isHidden {
            y += BrowserChromeLayout.sidebarSectionSpacing
            profile.frame = NSRect(x: 0, y: y, width: bounds.width, height: 28)
            profileIcon.frame = NSRect(x: 10, y: 7.5, width: 13, height: 13)
            profileName.frame = NSRect(x: 31, y: 6, width: max(bounds.width - 41, 0), height: 16)
            y += 28
        }
        if showsURL {
            y += BrowserChromeLayout.sidebarSectionSpacing
            urlControls.frame = NSRect(x: 0, y: y, width: bounds.width, height: BrowserChromeLayout.sidebarRowHeight)
            urlControls.publishURLFrame()
        }
    }

    override func mouseDown(with event: NSEvent) { window?.dragOrActOnBarClick(with: event) }

    func configure(
        showsWindowControls: Bool,
        showsURL: Bool,
        showsNavigation: Bool? = nil,
        isResizing: Bool,
        toggleTitle: String,
    ) {
        windowControls.showsInSidebar = showsWindowControls
        self.showsURL = showsURL
        self.showsNavigation = showsNavigation ?? showsURL
        toggle.configureSymbol(isMirrored ? "sidebar.right" : "sidebar.left", title: toggleTitle)
        urlControls.isHidden = !showsURL
        urlControls.isSidebarResizing = isResizing
        refresh()
    }

    /// Developer Mode's Reload can skip the cache or clear cookies; the choice stays.
    private func showReloadMenu() {
        let menu = BrowserNativeMenus.menu()
        let shortcuts = model.shortcutStore
        let preferences = model.userPreferencesStore
        func add(_ title: String, _ behavior: BrowserDeveloperReloadBehavior, shortcut: BrowserKeyboardShortcut?) {
            let item = BrowserNativeMenus.add(title, to: menu, shortcut: shortcut) { [weak model] in
                preferences.developerReloadBehavior = behavior
                model?.reloadRespectingDeveloperMode()
            }
            item.state = preferences.developerReloadBehavior == behavior ? .on : .off
        }
        add(BrowserStrings.developerReload, .reload, shortcut: shortcuts.shortcut(for: .reload))
        add(BrowserStrings.developerReloadIgnoreCache, .ignoreCache, shortcut: shortcuts.shortcut(for: .forceReload))
        menu.addItem(.separator())
        add(shortcuts.descriptor(for: .clearCookiesAndRefresh).menuTitle, .clearCookies, shortcut: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: reloadMenu.frame.minX, y: reloadMenu.frame.maxY + 4), in: self)
    }

    private func refresh() {
        let shortcuts = model.shortcutStore
        toggle.tooltipShortcut = shortcuts.shortcut(for: .toggleSidebar)
        back.tooltipShortcut = shortcuts.shortcut(for: .goBack)
        back.tooltipTitle = shortcuts.descriptor(for: .goBack).helpTitle
        forward.tooltipShortcut = shortcuts.shortcut(for: .goForward)
        forward.tooltipTitle = shortcuts.descriptor(for: .goForward).helpTitle
        back.isEnabled = model.canGoBack
        forward.isEnabled = model.canGoForward
        reloadSymbol.update(isLoading: model.canStopLoading)
        let showsStop = reloadSymbol.showsStop
        reload.configureSymbol(
            showsStop ? "xmark" : "arrow.clockwise",
            title: showsStop
                ? BrowserStrings.navigationStopLoading
                : shortcuts.descriptor(for: .reload).helpTitle,
        )
        reload.tooltipShortcut = showsStop ? nil : shortcuts.shortcut(for: .reload)
        reload.isEnabled = model.canStopLoading || model.canReload
        reload.pressEffect = showsStop ? .compress : .rotateClockwise
        for button in [back, forward, reload] {
            button.isHidden = !showsNavigation
        }
        reloadMenu.isHidden = !showsNavigation || !model.isDeveloperModeOn
        profile.isHidden = !model.showsProfileIndicator
        profileName.stringValue = model.profileDisplayName
        needsLayout = true
    }
}
