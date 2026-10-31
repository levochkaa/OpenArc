// BrowserSidebarChromeView.swift

import AppKit

final class BrowserSidebarChromeView: NSView, BrowserSpaceThemedChrome {
    override var isFlipped: Bool { true }

    // MARK: Internal

    private(set) var spaceThemePalette: BrowserSpaceTheme.Palette?

    let sidebar: BrowserNativeSidebarNSView
    let header: BrowserNativeSidebarHeaderNSView
    let footer: BrowserNativeSidebarFooterNSView
    var showsWindowControls = false
    var isOverlayPresentation = false
    var onToggleSidebar: () -> Void = {}
    var onDragInteractionChange: () -> Void = {}
    var onURLFrameChange: (CGRect?) -> Void = { _ in }

    var sidebarPosition = BrowserSidebarPosition.left {
        didSet {
            guard oldValue != sidebarPosition else { return }
            resize.direction = sidebarPosition == .left ? 1 : -1
            needsLayout = true
        }
    }

    // MARK: Private

    private let model: BrowserChromeModel
    private let background = BrowserChromeBackgroundNSView()
    private let resize = BrowserNativeResizeHandle()
    private var isResizing = false
    private var resizeStartWidth: CGFloat = 0

    init(model: BrowserChromeModel, updateController: BrowserUpdateController) {
        self.model = model
        let state = BrowserNativeSidebarState(
            model: model,
            snapshot: model.sidebarSnapshot,
            sidebarWidth: model.sidebarWidth,
        )
        self.header = BrowserNativeSidebarHeaderNSView(model: model)
        self.footer = BrowserNativeSidebarFooterNSView(state: state, updateController: updateController)
        self.sidebar = BrowserNativeSidebarNSView(state: state, header: header, footer: footer)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(background)
        addSubview(sidebar)
        addSubview(resize)
        sidebar.headerHeightProvider = { [weak header] in header?.preferredHeight ?? 0 }
        sidebar.footerHeightProvider = { [weak footer] width in footer?.height(for: width) ?? 0 }
        footer.onSizeChanged = { [weak sidebar] in sidebar?.refresh(animated: true) }
        sidebar.spaceDock = footer.spaceDock
        sidebar.onDragInteractionChange = { [weak self] _ in self?.onDragInteractionChange() }
        resize.setAccessibilityIdentifier("browser.sidebar.resize")
        resize.defaultWidth = BrowserChromeModel.defaultSidebarWidth
        resize.getWidth = { [weak model] in model?.sidebarWidth ?? BrowserChromeModel.defaultSidebarWidth }
        resize.setWidth = { [weak model] in model?.setSidebarWidth($0) }
        resize.collapseWidth = BrowserChromeLayout.sidebarCollapseDragWidth
        resize.onCollapse = { [weak model] in
            if model?.isSidebarVisible == true {
                model?.toggleSidebar()
            }
        }
        resize.onResizePhaseChange = { [weak self] active in
            guard let self else { return }
            if active {
                self.resizeStartWidth = model.sidebarWidth
            } else if resizeStartWidth != model.sidebarWidth {
                model.persistSidebarWidthPreferenceIfAllowed()
            }
            self.isResizing = active
            refresh()
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        sidebar.frame = bounds
        resize.frame = NSRect(
            x: sidebarPosition == .left ? max(bounds.width - BrowserChromeLayout.sidebarResizeHitWidth, 0) : 0,
            y: 0,
            width: BrowserChromeLayout.sidebarResizeHitWidth,
            height: bounds.height,
        )
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func refresh() {
        let snapshot = model.sidebarSnapshot
        let previous = sidebar.state.snapshot
        header.onToggleSidebar = onToggleSidebar
        header.urlControls.onURLFrameChange = onURLFrameChange
        header.configure(
            showsWindowControls: showsWindowControls,
            showsURL:!model.userPreferencesStore.siteURLToolbarEnabled,
            isResizing: isResizing,
            toggleTitle: model.isSidebarVisible
                ? BrowserStrings.sidebarHide
                : BrowserStrings.sidebarShow,
        )
        sidebar.headerHeight = header.preferredHeight
        footer.update(snapshot: snapshot, isResizing: isResizing)
        sidebar.footerHeight = footer.height(for: max(
            model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2,
            0,
        ))
        sidebar.state.update(snapshot: snapshot, sidebarWidth: model.sidebarWidth, isResizing: isResizing)
        sidebar.isCommandBarPresented = model.commandBarModel.isPresented
        sidebar.refresh(animated: previous.selectedSpaceID != snapshot.selectedSpaceID
            || previous.allTabs.map(\.id) != snapshot.allTabs.map(\.id) || previous.pinnedTabFolders != snapshot
            .pinnedTabFolders)
        background.isHidden = !isOverlayPresentation
        background.mode = model.userPreferencesStore.blurredChromeBackgroundEnabled ? .blurred : .black
        // The floating sidebar carries the Space's theme like the window behind it.
        background.setTheme(model.selectedSpaceTheme, animated: false)
        applySpaceTheme()
        layer?.cornerRadius = isOverlayPresentation ? BrowserChromeLayout.sidebarOverlayCornerRadius : 0
        layer?.borderWidth = isOverlayPresentation ? BrowserChromeLayout.sidebarOverlayBorderWidth : 0
        layer?.borderColor = BrowserChromeColors.sidebarOverlayBorder.cgColor
        resize.hapticsEnabled = model.userPreferencesStore.hapticFeedbackEnabled
        needsLayout = true
    }

    /// Text and fills follow the theme: dark on bright colors, light on dark ones.
    private func applySpaceTheme() {
        spaceThemePalette = model.selectedSpaceTheme?.palette
        let name: NSAppearance.Name? = spaceThemePalette.map { $0.isLightContent ? .aqua : .darkAqua }
        if appearance?.name != name {
            appearance = name.flatMap(NSAppearance.init(named:))
        }
    }
}
