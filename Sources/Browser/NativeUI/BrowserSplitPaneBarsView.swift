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

    /// The window controls move into the top-leading pane's bar while the
    /// sidebar, which normally holds them, is hidden.
    var showsWindowControls = false {
        didSet {
            if oldValue != showsWindowControls {
                refresh()
            }
        }
    }

    /// Tab IDs of the bars on screen, in pane order.
    var paneTabIDs: [String] { model?.splitPaneLayoutTabIDs.filter { bars[$0] != nil } ?? [] }

    /// The pane a grip drag would land on, while it differs from the dragged one.
    private(set) var paneDropTargetTabID: String? {
        didSet {
            if oldValue != paneDropTargetTabID {
                needsDisplay = true
            }
        }
    }

    /// The half of a page or pane that a tab dragged from the sidebar would take.
    private(set) var pageDropPreview: CGRect? {
        didSet {
            if oldValue != pageDropPreview {
                needsDisplay = true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// The landing pane is outlined while a pane is dragged by its grip, and
    /// the new pane's place while a sidebar tab is dragged over the page.
    override func draw(_: NSRect) {
        guard let target = pageDropPreview ?? paneDropTargetTabID.flatMap({ paneRects[$0] }) else { return }
        let radius = BrowserSplitPaneLayout.paneCornerRadius
        let ring = BrowserSplitPaneLayout.focusRingWidth
        let path = NSBezierPath(
            roundedRect: target.insetBy(dx: ring / 2, dy: ring / 2),
            xRadius: radius,
            yRadius: radius
        )
        BrowserSplitPaneLayout.focusRingColor.withAlphaComponent(0.12).setFill()
        path.fill()
        path.lineWidth = ring
        BrowserSplitPaneLayout.focusRingColor.setStroke()
        path.stroke()
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
        paneRects = Dictionary(
            zip(ids, frames).map { ($0, convert($1, from: hostView)) },
            uniquingKeysWith: { first, _ in first }
        )
        let topLeadingID = paneRects.min { first, second in
            (first.value.minY, first.value.minX) < (second.value.minY, second.value.minX)
        }?.key
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
            bar.update(tab: tab, focused: model.selectedTabID == id, canReorder: ids.count > 1)
            bar.showsWindowControls = showsWindowControls && id == topLeadingID
        }
    }

    /// The page part of a shown pane, below its bar, or nil outside a split.
    func pageFrame(forTabID tabID: String) -> CGRect? {
        paneRects[tabID].map { BrowserSplitPaneLayout.webContentFrame(forPaneFrame: $0, flipped: isFlipped) }
    }

    /// The pane that a pane dragged by its grip lands on at `point`, in this
    /// view's coordinates, or nil over the dragged pane itself.
    func paneDropTarget(for tabID: String, at point: NSPoint) -> String? {
        guard let model, let group = model.splitGroup(containingTabID: tabID) else { return nil }
        let ids = model.splitPaneLayoutTabIDs.filter { paneRects[$0] != nil }
        guard let index = BrowserSplitPaneLayout.paneIndex(
            at: point,
            in: ids.compactMap { paneRects[$0] },
            orientation: group.orientation
        ), ids[index] != tabID else { return nil }
        return ids[index]
    }

    /// Page drop zones while a sidebar tab is dragged over the page: each
    /// visible pane, or the single page, splits at the edge under the pointer.
    /// A split only grows along its own axis. The middle of a shown split's
    /// pane replaces that pane; the middle of a single page is no drop zone.
    /// A nil point clears the preview.
    func pageSplitDrop(
        atWindowPoint point: CGPoint?,
        draggedTabID: String
    ) -> BrowserSidebarDragState.PageSplitDropTarget? {
        guard let point, let model, let hostView, !isHidden, window != nil else {
            pageDropPreview = nil
            return nil
        }
        let local = convert(point, from: nil)
        let group = model.selectedSplitGroup
        var panes = model.splitPaneLayoutTabIDs.compactMap { id in paneRects[id].map { (id: id, frame: $0) } }
        if panes.isEmpty, let selectedTabID = model.selectedTabID {
            panes = [(selectedTabID, convert(hostView.bounds, from: hostView))]
        }
        guard let pane = panes.first(where: { $0.frame.contains(local) }) else {
            pageDropPreview = nil
            return nil
        }
        guard let edge = BrowserSplitPaneLayout.pageDropEdge(at: local, in: pane.frame) else {
            guard group != nil, model.canReplaceSplitPane(anchorTabID: pane.id, with: draggedTabID) else {
                pageDropPreview = nil
                return nil
            }
            pageDropPreview = pane.frame
            return .init(anchorTabID: pane.id, replacesAnchor: true)
        }
        guard group.map({ $0.orientation == edge.orientation }) ?? true,
              model.canOpenInSplitView(tabID: draggedTabID, anchorTabID: pane.id)
        else {
            pageDropPreview = nil
            return nil
        }
        pageDropPreview = BrowserSplitPaneLayout.pageDropPreview(for: edge, in: pane.frame)
        return .init(anchorTabID: pane.id, insertion: edge.isBefore ? .before : .after, orientation: edge.orientation)
    }

    /// Ends a grip drag: the pane takes the landing pane's position.
    func finishPaneDrag(for tabID: String, at point: NSPoint) {
        paneDropTargetTabID = nil
        guard let model, let target = paneDropTarget(for: tabID, at: point),
              let index = model.splitPaneTabIDs(forTabID: tabID).firstIndex(of: target)
        else { return }
        model.moveSplitPane(tabID: tabID, to: index)
    }

    // MARK: Private

    private var bars = [String: BrowserSplitPaneBarView]()
    private var paneRects = [String: CGRect]()

    private func makeBar() -> BrowserSplitPaneBarView {
        let bar = BrowserSplitPaneBarView()
        bar.onAction = { [weak self] action, tabID in self?.perform(action, tabID: tabID) }
        bar.onGripDrag = { [weak self] tabID, location in
            guard let self else { return }
            paneDropTargetTabID = paneDropTarget(for: tabID, at: convert(location, from: nil))
        }
        bar.onGripDragEnd = { [weak self] tabID, location in
            guard let self else { return }
            finishPaneDrag(for: tabID, at: convert(location, from: nil))
        }
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
        addSubview(grip)
        windowControls.managesSystemButtons = false
        windowControls.showsInSidebar = false
        windowControls.isHidden = true
        addSubview(windowControls)
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
        grip.onDrag = { [weak self] location in
            guard let self, let tabID else { return }
            onGripDrag(tabID, location)
        }
        grip.onDragEnd = { [weak self] location in
            guard let self, let tabID else { return }
            onGripDragEnd(tabID, location)
        }
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
    /// Pointer locations in window coordinates while the grip is dragged.
    var onGripDrag: (String, NSPoint) -> Void = { _, _ in }
    var onGripDragEnd: (String, NSPoint) -> Void = { _, _ in }
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
    let grip = BrowserSplitPaneGripView()
    let windowControls = BrowserWindowControlsHostView()

    var showsWindowControls = false {
        didSet {
            guard oldValue != showsWindowControls else { return }
            windowControls.showsInSidebar = showsWindowControls
            windowControls.isHidden = !showsWindowControls
            needsLayout = true
        }
    }

    override func mouseDown(with _: NSEvent) {
        send(.focus)
    }

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.sidebarCurrentURLButtonSize
        let y = ((bounds.height - size) / 2).rounded()
        var inset: CGFloat = 4
        if showsWindowControls {
            // The controls sit where they would in the sidebar header.
            let controlsWidth = windowControls.intrinsicContentSize.width
            let controlsX = BrowserChromeLayout.sidebarOuterPadding
            windowControls.frame = NSRect(x: controlsX, y: y, width: controlsWidth, height: size)
            inset = controlsX + controlsWidth + BrowserChromeLayout.windowControlsTrailingGap
        }
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
        let gripHit = BrowserSplitPaneLayout.paneGripHitSize
        grip.frame = NSRect(
            x: ((bounds.width - gripHit.width) / 2).rounded(),
            y: 0,
            width: gripHit.width,
            height: gripHit.height
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

    func update(tab: BrowserChromeModel.Tab, focused: Bool, canReorder: Bool = true) {
        tabID = tab.id
        // The drag grip shows on the focused pane only.
        grip.isHidden = !focused || !canReorder
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
        grip.setAccessibilityIdentifier("browser.split.pane-bar.grip.\(tab.id)")
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

// MARK: - BrowserSplitPaneGripView

/// Pane drag handle at the top center of the focused pane. Dragging it
/// moves the pane to the position under the pointer on release.
final class BrowserSplitPaneGripView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel(BrowserStrings.splitPaneGripAccessibilityLabel)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var onDrag: (NSPoint) -> Void = { _ in }
    var onDragEnd: (NSPoint) -> Void = { _ in }
    private(set) var isDragging = false

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        let size = BrowserSplitPaneLayout.paneGripSize
        let rect = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        let color = isDragging ? BrowserChromeColors.primaryText : BrowserChromeColors.secondaryText
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDown(with _: NSEvent) {
        isDragging = true
        NSCursor.closedHand.push()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        needsDisplay = true
        onDragEnd(event.locationInWindow)
    }
}
