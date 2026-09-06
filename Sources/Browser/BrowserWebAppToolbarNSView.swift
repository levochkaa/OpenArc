import AppKit
import Combine

final class BrowserWebAppToolbarNSView: NSView {
    // MARK: Lifecycle

    init(
        model: BrowserChromeModel,
        preferences: BrowserWebAppPreferences,
        configuration: BrowserWebAppConfiguration,
        actions: BrowserWebAppViewActions
    ) {
        self.model = model
        self.preferences = preferences
        self.configuration = configuration
        self.actions = actions
        self.extensionsPresenter = BrowserNativeExtensionPopoverPresenter(model: model)
        super.init(frame: .zero)
        for subview in [windowControls, back, reload, extensions, more, heading] {
            addSubview(subview)
        }
        heading.setAccessibilityIdentifier("browser.webapp.title")
        back.setAccessibilityIdentifier("browser.webapp.back")
        reload.setAccessibilityIdentifier("browser.webapp.reload")
        extensions.setAccessibilityIdentifier("browser.webapp.extensions")
        more.setAccessibilityIdentifier("browser.webapp.more")
        back.onAction = { [weak model] in model?.goBack() }
        reload.onAction = { [weak model] in
            if model?.canStopLoading == true {
                model?.stopLoadingCurrentTab()
            } else {
                model?.reloadCurrentTab()
            }
        }
        extensions.onAction = { [weak self] in
            guard let self else { return }
            extensionsPresenter.showControlCenter(relativeTo: extensions, preferredEdge: .minY)
        }
        extensionsPresenter.onPresentationChanged = { [weak self] in
            guard let self else { return }
            extensions.isSelected = extensionsPresenter.isPresented
        }
        more.onAction = { [weak self] in
            guard let self else { return }
            moreMenu().popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY), in: self)
        }
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            preferences.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    var actions: BrowserWebAppViewActions

    var windowControlsWidth: CGFloat = 0 { didSet { windowControls.showsInSidebar = windowControlsWidth > 0
        needsLayout = true
    } }

    override func layout() {
        super.layout()
        let padding = BrowserChromeLayout.bookmarksBarHorizontalPadding
        let spacing = BrowserChromeLayout.chromeButtonSpacing
        let size = BrowserChromeLayout.chromeButtonSize
        let y = (bounds.height - size) / 2
        windowControls.isHidden = windowControlsWidth <= 0
        windowControls.frame = NSRect(x: padding, y: y, width: windowControlsWidth, height: size)
        back.frame = NSRect(
            x: padding + (windowControlsWidth > 0 ? windowControlsWidth + spacing : 0),
            y: y,
            width: size,
            height: size
        )
        reload.frame = back.frame.offsetBy(dx: size + spacing, dy: 0)
        more.frame = NSRect(x: bounds.width - padding - size, y: y, width: size, height: size)
        extensions.frame = more.frame.offsetBy(dx: -(size + spacing), dy: 0)
        let sideReserve = max(reload.frame.maxX, bounds.width - extensions.frame.minX) + BrowserWebAppLayout
            .minimumTitlePadding
        let titleWidth = min(
            ceil(heading.intrinsicContentSize.width),
            BrowserWebAppLayout.titleMaximumWidth,
            max(bounds.width - sideReserve * 2, 0)
        )
        heading.frame = NSRect(
            x: (bounds.width - titleWidth) / 2,
            y: (bounds.height - 17) / 2,
            width: titleWidth,
            height: 17
        )
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow()
        if window == nil {
            closePopovers()
        }
    }

    func refresh() {
        back.isEnabled = model.canGoBack
        back.tooltipShortcut = model.shortcutStore.shortcut(for: .goBack)
        reload.configureSymbol(
            model.canStopLoading ? "xmark" : "arrow.clockwise",
            title: model.canStopLoading
                ? BrowserStrings.navigationStopLoading
                : BrowserStrings.navigationRefresh
        )
        reload.isEnabled = model.canStopLoading || model.canReload
        reload.tooltipShortcut = model.canStopLoading ? nil : model.shortcutStore.shortcut(for: .reload)
        reload.pressEffect = model.canStopLoading ? .compress : .rotateClockwise
        extensions.isEnabled = model.isContextReady
        heading.stringValue =
            if let tab = model.currentTab {
                preferences.alwaysShowsFullURLs
                    ? BrowserURLDisplayFormatter.fullDisplayString(for: tab.urlString)
                    : tab.displayTitle
            } else {
                configuration.name
            }
        heading.lineBreakMode = preferences.alwaysShowsFullURLs ? .byTruncatingMiddle : .byTruncatingTail
        needsLayout = true
    }

    func closePopovers() { extensionsPresenter.close() }

    // MARK: Private

    private let model: BrowserChromeModel
    private let preferences: BrowserWebAppPreferences
    private let configuration: BrowserWebAppConfiguration
    private let extensionsPresenter: BrowserNativeExtensionPopoverPresenter
    private let windowControls = BrowserWindowControlsHostView()
    private let back = BrowserNativeChromeButton(
        symbol: "arrow.backward",
        title: BrowserStrings.navigationBack,
        pressEffect: .left,
        action: {}
    )
    private let reload = BrowserNativeChromeButton(
        symbol: "arrow.clockwise",
        title: BrowserStrings.navigationRefresh,
        pressEffect: .rotateClockwise,
        action: {}
    )
    private let extensions = BrowserNativeChromeButton(
        symbol: "puzzlepiece.extension",
        title: BrowserStrings.extensionsSectionTitle,
        pressEffect: .compress,
        action: {}
    )
    private let more = BrowserNativeChromeButton(
        symbol: "ellipsis",
        title: BrowserStrings.webAppMoreAction,
        pressEffect: .compress,
        action: {}
    )
    private let heading = BrowserNativeControls.label(
        "",
        size: 12.5,
        weight: .medium,
        color: BrowserChromeColors.primaryText
    )
    private var observations = Set<AnyCancellable>()

    private func moreMenu() -> NSMenu {
        let model = model
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(BrowserStrings.webAppInfoAction, to: menu, action: actions.showAppInfo)
        BrowserNativeMenus
            .add(BrowserStrings.webAppCopyURLAction, to: menu, enabled: model.canCopySelectedTabLink) {
                _ = model.copySelectedTabLink()
            }
        BrowserNativeMenus.add(
            BrowserStrings.webAppOpenInBrowserAction,
            to: menu,
            enabled: model.currentTab != nil,
            action: actions.openInBrowser
        )
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            BrowserStrings.webAppUninstallAction(configuration.name),
            to: menu,
            action: actions.uninstall
        )
        menu.addItem(.separator())
        let zoom = BrowserNativeMenus.submenu(BrowserStrings.webAppZoomMenu(model.zoomPercent), in: menu)
        BrowserNativeMenus.add(
            BrowserStrings.webAppZoomOutAction,
            to: zoom,
            enabled: model.zoomPercent != BrowserChromeModel.zoomPercentages.first,
            action: model.zoomOut
        )
        BrowserNativeMenus.add(
            BrowserStrings.webAppZoomResetAction,
            to: zoom,
            enabled: model.zoomPercent != 100,
            action: model.resetZoom
        )
        BrowserNativeMenus.add(
            BrowserStrings.webAppZoomInAction,
            to: zoom,
            enabled: model.zoomPercent != BrowserChromeModel.zoomPercentages.last,
            action: model.zoomIn
        )
        BrowserNativeMenus.add(
            BrowserStrings.menuPrint,
            to: menu,
            enabled: model.canPrintPage,
            action: model.printCurrentPage
        )
        BrowserNativeMenus
            .add(BrowserStrings.menuFind, to: menu, enabled: model.canPresentFindInPage) {
                _ = model.presentFindInPage()
            }
        let edit = BrowserNativeMenus.submenu(BrowserStrings.webAppEditMenu, in: menu)
        for (title, selector) in [
            (BrowserStrings.menuCut, #selector(NSText.cut(_:))),
            (BrowserStrings.menuCopy, #selector(NSText.copy(_:))),
            (BrowserStrings.menuPaste, #selector(NSText.paste(_:))),
            (BrowserStrings.menuSelectAll, #selector(NSText.selectAll(_:))),
        ] {
            BrowserNativeMenus.add(title, to: edit) { NSApp.sendAction(selector, to: nil, from: nil) }
        }
        BrowserNativeMenus.add(
            BrowserStrings.webAppCastAction,
            to: menu,
            enabled: model.canCastPage,
            action: model.castCurrentPage
        )
        return menu
    }
}
