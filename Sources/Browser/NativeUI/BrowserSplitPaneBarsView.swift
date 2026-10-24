import AppKit

// MARK: - BrowserSplitPaneBarsView

/// Per-pane top bars while a Split View is shown. The engine leaves the
/// top `BrowserSplitPaneLayout.paneBarHeight` of every pane free and reports the
/// pane frames; this transparent layer above the engine host puts a bar there.
/// Clicks pass through everywhere except on the bars.
final class BrowserSplitPaneBarsView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    weak var model: BrowserChromeModel?
    weak var hostView: NSView?

    /// Tab IDs of the bars on screen, in pane order.
    var paneTabIDs: [String] { model?.splitPaneLayoutTabIDs.filter { bars[$0] != nil } ?? [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func bar(forTabID tabID: String) -> BrowserSplitPaneBarView? { bars[tabID] }

    func refresh() {
        guard let model, let hostView, hostView.window === window || window == nil else {
            removeBars(keeping: [])
            return
        }
        let ids = model.splitPaneLayoutTabIDs
        let frames = model.splitPaneLayoutFrames
        removeBars(keeping: Set(ids))
        for (id, paneFrame) in zip(ids, frames) {
            guard let tab = model.tabs.first(where: { $0.id == id }) else {
                bars.removeValue(forKey: id)?.removeFromSuperview()
                continue
            }
            let bar = bars[id] ?? makeBar()
            bars[id] = bar
            let pane = convert(paneFrame, from: hostView)
            bar.frame = CGRect(
                x: pane.minX,
                y: pane.minY,
                width: pane.width,
                height: min(BrowserSplitPaneLayout.paneBarHeight, pane.height)
            )
            bar.update(tab: tab, focused: model.selectedTabID == id)
        }
    }

    // MARK: Private

    private var bars = [String: BrowserSplitPaneBarView]()

    private func makeBar() -> BrowserSplitPaneBarView {
        let bar = BrowserSplitPaneBarView()
        bar.onAction = { [weak self] action, tabID in self?.perform(action, tabID: tabID) }
        addSubview(bar)
        return bar
    }

    private func removeBars(keeping ids: Set<String>) {
        for id in Set(bars.keys).subtracting(ids) {
            bars.removeValue(forKey: id)?.removeFromSuperview()
        }
    }

    private func perform(_ action: BrowserSplitPaneBarView.Action, tabID: String) {
        guard let model else { return }
        switch action {
        case .focus:
            model.focusSplitPaneForBarAction(tabID: tabID)
        case .back:
            model.focusSplitPaneForBarAction(tabID: tabID)
            model.goBack()
        case .forward:
            model.focusSplitPaneForBarAction(tabID: tabID)
            model.goForward()
        case .reload:
            model.focusSplitPaneForBarAction(tabID: tabID)
            if model.canStopLoading {
                model.stopLoadingCurrentTab()
            } else {
                model.reloadCurrentTab()
            }
        case .copyURL:
            _ = model.copyTabLink(forTabID: tabID)
        case .close:
            if model.selectedTabID == tabID {
                _ = model.closeFocusedSplitPane()
            } else {
                model.closeTab(id: tabID)
            }
        }
    }
}

// MARK: - BrowserSplitPaneBarView

/// One pane's bar: back, forward and, on the focused pane, reload; the page
/// host in the middle copies the URL; Close this Split Pane on the right.
final class BrowserSplitPaneBarView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [backButton, forwardButton, reloadButton, closeButton] {
            addSubview(button)
        }
        addSubview(hostButton)
        hostButton.addSubview(linkIcon)
        hostButton.addSubview(hostLabel)
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.alignment = .center
        linkIcon.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        linkIcon.contentTintColor = BrowserChromeColors.secondaryText
        backButton.onAction = { [weak self] in self?.send(.back) }
        forwardButton.onAction = { [weak self] in self?.send(.forward) }
        reloadButton.onAction = { [weak self] in self?.send(.reload) }
        closeButton.onAction = { [weak self] in self?.send(.close) }
        hostButton.onClick = { [weak self] _ in self?.send(.copyURL) }
        hostButton.setAccessibilityRole(.button)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    enum Action { case focus, back, forward, reload, copyURL, close }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var onAction: (Action, String) -> Void = { _, _ in }
    private(set) var tabID: String?
    private(set) var isFocused = false

    let backButton = BrowserNativeChromeButton(
        symbol: "chevron.left",
        title: BrowserStrings.navigationBack,
        style: .currentURL,
        action: {}
    )
    let forwardButton = BrowserNativeChromeButton(
        symbol: "chevron.right",
        title: BrowserStrings.navigationForward,
        style: .currentURL,
        action: {}
    )
    let reloadButton = BrowserNativeChromeButton(
        symbol: "arrow.clockwise",
        title: BrowserStrings.navigationRefresh,
        style: .currentURL,
        action: {}
    )
    let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.menuCloseSplitPane,
        style: .currentURL,
        action: {}
    )
    let hostButton = BrowserNativePressableView()

    override func mouseDown(with _: NSEvent) {
        send(.focus)
    }

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let y = ((bounds.height - size) / 2).rounded()
        let inset: CGFloat = 4
        backButton.frame = NSRect(x: inset, y: y, width: size, height: size)
        forwardButton.frame = backButton.frame.offsetBy(dx: size, dy: 0)
        reloadButton.frame = forwardButton.frame.offsetBy(dx: size, dy: 0)
        closeButton.frame = NSRect(x: bounds.width - inset - size, y: y, width: size, height: size)
        let leading = (reloadButton.isHidden ? forwardButton.frame.maxX : reloadButton.frame.maxX) + 4
        let trailing = closeButton.frame.minX - 4
        let symmetric = max(leading, bounds.width - trailing)
        let available = max(bounds.width - symmetric * 2, 0)
        let textWidth = ceil(hostLabel.fittingSize.width) + 4
        let iconWidth: CGFloat = 14
        let width = min(textWidth + iconWidth + 4, available)
        hostButton.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: size)
        linkIcon.frame = NSRect(x: 0, y: (size - iconWidth) / 2, width: iconWidth, height: iconWidth)
        hostLabel.frame = NSRect(
            x: iconWidth + 4,
            y: ((size - 16) / 2).rounded(),
            width: max(width - iconWidth - 4, 0),
            height: 16
        )
    }

    /// The bar fills the pane's top with rounded top corners. On the focused
    /// pane it stays inside the accent ring the engine host draws around it.
    override func draw(_: NSRect) {
        let ring = isFocused ? BrowserSplitPaneLayout.focusRingWidth : 0
        let rect = bounds.insetBy(dx: ring, dy: 0).divided(atDistance: ring, from: .minYEdge).remainder
        let radius = max(BrowserSplitPaneLayout.paneCornerRadius - ring, 0)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: 180,
            endAngle: 270
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: 270,
            endAngle: 360
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        BrowserChromeColors.contentBackground.setFill()
        path.fill()
    }

    func update(tab: BrowserChromeModel.Tab, focused: Bool) {
        tabID = tab.id
        if isFocused != focused {
            isFocused = focused
            needsDisplay = true
        }
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        reloadButton.isHidden = !focused
        reloadButton.configureSymbol(
            tab.isLoading ? "xmark" : "arrow.clockwise",
            title: tab.isLoading ? BrowserStrings.navigationStopLoading : BrowserStrings.navigationRefresh
        )
        let host = URL(string: tab.urlString)?.host.map(BrowserURLDisplayFormatter.hostDisplayString(forHost:))
        hostLabel.stringValue = host ?? BrowserURLDisplayFormatter.displayString(for: tab.urlString)
        hostLabel.textColor = focused ? BrowserChromeColors.primaryText : BrowserChromeColors.secondaryText
        hostButton.setAccessibilityLabel(BrowserStrings.tabCopyURLAction)
        hostButton.setAccessibilityIdentifier("browser.split.pane-bar.copy-url.\(tab.id)")
        backButton.setAccessibilityIdentifier("browser.split.pane-bar.back.\(tab.id)")
        forwardButton.setAccessibilityIdentifier("browser.split.pane-bar.forward.\(tab.id)")
        reloadButton.setAccessibilityIdentifier("browser.split.pane-bar.reload.\(tab.id)")
        closeButton.setAccessibilityIdentifier("browser.split.pane-bar.close.\(tab.id)")
        setAccessibilityIdentifier("browser.split.pane-bar.\(tab.id)")
        setAccessibilityLabel(tab.displayTitle)
        needsLayout = true
    }

    // MARK: Private

    private let linkIcon = NSImageView()
    private let hostLabel = BrowserNativeControls.label("", size: 12, weight: .medium)

    private func send(_ action: Action) {
        guard let tabID else { return }
        onAction(action, tabID)
    }
}
