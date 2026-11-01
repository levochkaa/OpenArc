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

    init(model: BrowserChromeModel) {
        self.model = model
        self.urlControls = BrowserSiteControlsNSView(model: model, mode: .sidebar)
        super.init(frame: .zero)
        for view in [windowControls, toggle, back, forward, reload, profile, urlControls] {
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
                    model?.reloadCurrentTab()
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
        windowControls.frame = NSRect(
            x: BrowserChromeLayout.sidebarWindowControlsLeading,
            y: 0,
            width: controlsWidth,
            height: size,
        )
        toggle.frame = NSRect(
            x: controlsWidth > 0 ? windowControls.frame.maxX + BrowserChromeLayout.sidebarWindowControlsToggleGap : 0,
            y: buttonY,
            width: size,
            height: size,
        )
        reload.frame = NSRect(
            x: bounds.width + BrowserChromeLayout.sidebarHeaderTrailingOverhang - size,
            y: buttonY,
            width: size,
            height: size,
        )
        forward.frame = reload.frame.offsetBy(dx: -(size + spacing), dy: 0)
        back.frame = forward.frame.offsetBy(dx: -(size + spacing), dy: 0)
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

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

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
        toggle.configureSymbol("sidebar.left", title: toggleTitle)
        urlControls.isHidden = !showsURL
        urlControls.isSidebarResizing = isResizing
        refresh()
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
        profile.isHidden = !model.showsProfileIndicator
        profileName.stringValue = model.profileDisplayName
        needsLayout = true
    }
}
