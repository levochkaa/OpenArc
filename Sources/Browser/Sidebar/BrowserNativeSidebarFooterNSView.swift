import AppKit
import Combine

// MARK: - BrowserNativeSidebarFooterNSView

final class BrowserNativeSidebarFooterNSView: NSView, NSPopoverDelegate {
    // MARK: Lifecycle

    init(state: BrowserNativeSidebarState, updateController: BrowserUpdateController) {
        self.state = state
        self.updateController = updateController
        self.downloadsController = BrowserDownloadsViewController(model: state.model.downloadsModel)
        super.init(frame: .zero)
        for view in [toast, scroll, downloadsButton, createButton, downloadDot] {
            addSubview(view)
        }
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = spacesContainer
        scroll.automaticallyAdjustsContentInsets = false
        downloadsButton.setAccessibilityIdentifier("browser.sidebar.downloads")
        downloadsButton.tooltipPlacement = .aboveCapsule
        downloadsButton.onAction = { [weak self] in self?.toggleDownloads() }
        createButton.setAccessibilityIdentifier("browser.sidebar.create-space")
        createButton.tooltipPlacement = .aboveCapsule
        createButton.onAction = { [weak state] in
            state?.dismissRenamingIfNeeded()
            state?.clearSidebarTabSelection()
            state?.model.createNewSpace()
        }
        toast.onInstall = { [weak updateController] in updateController?.installDownloadedUpdateNow() }
        toast.onDismiss = { [weak updateController] in updateController?.dismissToast() }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = downloadsController
        downloadsController.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
        updateController.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshToast() }
            .store(in: &observations)
        state.model
            .downloadsModel
            .objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshDownloadsButton() }
            .store(in: &observations)
        refreshToast()
        refreshDownloadsButton()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    var onSizeChanged: () -> Void = {}

    var isDownloadsPresented: Bool { popover.isShown }

    /// The Space icons, for drops from the sidebar.
    var spaceDock: BrowserSpaceDockNSView { spacesContainer }

    override func layout() {
        super.layout()
        let toastHeight = toast.height(for: max(bounds.width - 4, 0)) * toastProgress
        toast.frame = NSRect(x: 2, y: 0, width: max(bounds.width - 4, 0), height: toastHeight)
        let y = toastHeight + BrowserChromeLayout.sidebarSectionSpacing
        let size = BrowserChromeLayout.chromeButtonSize
        let reserve = size + BrowserChromeLayout.chromeButtonSpacing
        downloadsButton.frame = NSRect(x: 0, y: y, width: size, height: size)
        createButton.frame = NSRect(x: max(bounds.width - size, 0), y: y, width: size, height: size)
        downloadDot.frame = NSRect(x: size - 10, y: y + 5, width: 5, height: 5)
        scroll.frame = NSRect(x: reserve, y: y, width: max(bounds.width - reserve * 2, 0), height: size)
        let contentWidth = CGFloat(spaces.count) * size + CGFloat(max(spaces.count - 1, 0)) * BrowserChromeLayout
            .chromeButtonSpacing
        let width = max(contentWidth, scroll.contentSize.width)
        spacesContainer.frame = NSRect(x: 0, y: 0, width: width, height: size)
        spacesContainer.itemSize = size
        spacesContainer.needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        state.dismissRenamingIfNeeded()
        if !state.isSidebarResizing, !state.isDraggingSidebarItem {
            window?.performDrag(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            popover.performClose(nil)
        }
    }

    func update(snapshot: BrowserSidebarSnapshot, isResizing: Bool) {
        spaces = snapshot.spaces
        self.isResizing = isResizing
        if isResizing {
            popover.performClose(nil)
        }
        let ids = Set(spaces.map(\.id))
        for id in Set(buttons.keys).subtracting(ids) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, space) in spaces.enumerated() {
            let state = state
            let model = state.model
            let button = buttons[space.id] ?? BrowserNativeChromeButton(
                symbol: space.systemImageName,
                title: space.title,
                pressEffect: .compress,
                action: {}
            )
            if buttons[space.id] == nil {
                buttons[space.id] = button
                spacesContainer.addSubview(button)
            }
            button.configureSymbol(space.systemImageName, title: space.title)
            button.tooltipShortcut = BrowserSpaceShortcuts.shortcut(forSpaceIndex: index)
            button.tooltipPlacement = .aboveCapsule
            button.isSelected = snapshot.selectedSpaceID == space.id
            button.isEnabled = !isResizing
            button.setAccessibilityIdentifier("browser.sidebar.select-space.\(space.id)")
            button.onAction = { [weak state] in
                state?.dismissRenamingIfNeeded()
                state?.clearSidebarTabSelection()
                model.selectSpace(id: space.id)
            }
            button.menu = BrowserNativeMenus.space(
                space,
                canDelete: spaces.count > 1,
                canResetTabs: model.canResetSpaceTabs(spaceID: space.id),
                color: model.spaceColorsByID[space.id].flatMap(BrowserSpaceColor.init(rawValue:)),
                onRename: { [weak state] in state?.clearSidebarTabSelection()
                    state?.beginRenamingSpace(id: space.id)
                },
                onChangeIcon: { model.setIcon($0, forSpaceID: space.id) },
                onChangeColor: { model.setColor($0, forSpaceID: space.id) },
                onResetTabs: { model.resetSpaceTabs(spaceID: space.id) },
                onDelete: { [weak state] in state?.dismissRenamingIfNeeded()
                    state?.clearSidebarTabSelection()
                    model.deleteSpace(id: space.id)
                }
            )
        }
        spacesContainer.items = spaces.compactMap { space in buttons[space.id].map { (space.id, $0) } }
        spacesContainer.isReorderingEnabled = !isResizing
        let model = state.model
        spacesContainer.onMove = { id, index in
            model.moveSpace(id: id, toIndex: index)
        }
        let hidden = !state.model.supportsSpaces
        downloadsButton.isHidden = hidden
        createButton.isHidden = hidden
        scroll.isHidden = hidden
        downloadsButton.isEnabled = !isResizing
        createButton.isEnabled = !isResizing
        refreshDownloadsButton()
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        let toastHeight = toast.height(for: max(width - 4, 0)) * toastProgress
        return toastHeight + BrowserChromeLayout.sidebarSectionSpacing + (state.model.supportsSpaces
            ? BrowserChromeLayout.chromeButtonSize
            : 0)
    }

    func popoverDidClose(_: Notification) { refreshDownloadsButton() }

    /// Opens the list from the Downloads button, or from `anchor` while the
    /// sidebar is off screen; closes it if it is open.
    func toggleDownloads(anchor: (rect: CGRect, view: NSView, edge: NSRectEdge)? = nil) {
        guard !isResizing else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            _ = downloadsController.view
            downloadsController.refresh()
            popover.contentSize = downloadsController.preferredContentSize
            let anchor = anchor ?? (downloadsButton.bounds, downloadsButton, .maxY)
            popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.edge)
        }
        refreshDownloadsButton()
    }

    // MARK: Private

    private let state: BrowserNativeSidebarState
    private let updateController: BrowserUpdateController
    private let toast = BrowserNativeUpdateToastView()
    private let toastVisibility = BrowserNativeVisibilityAnimation()
    private let toastAnimation = BrowserNativeAnimation()
    private var toastTarget = false
    private var toastProgress = 0.0
    private let scroll = NSScrollView()
    private let spacesContainer = BrowserSpaceDockNSView()
    private let downloadsButton = BrowserNativeChromeButton(
        symbol: "arrow.down.circle",
        title: BrowserStrings.downloadsTitle,
        pressEffect: .compress,
        action: {}
    )
    private let createButton = BrowserNativeChromeButton(
        symbol: "plus",
        title: BrowserStrings.spaceNewAction,
        pressEffect: .compress,
        action: {}
    )
    private let downloadDot = BrowserNativeDownloadIndicator()
    private let downloadsController: BrowserDownloadsViewController
    private let popover = BrowserNativePopover()
    private var buttons = [String: BrowserNativeChromeButton]()
    private var spaces = [BrowserChromeModel.Space]()
    private var observations = Set<AnyCancellable>()
    private var isResizing = false

    private func refreshToast() {
        let visible = updateController.toast != nil
        if let content = updateController.toast {
            toast.update(content)
        }
        toastVisibility.setVisible(visible, view: toast, curve: .sidebar)
        if toastTarget != visible {
            toastTarget = visible
            let from = toastProgress
            let to = visible ? 1.0 : 0.0
            if window == nil {
                toastProgress = to
            } else {
                toastAnimation.start(.sidebar) { [weak self] progress in
                    guard let self else { return }
                    toastProgress = from + (to - from) * progress
                    needsLayout = true
                    onSizeChanged()
                }
            }
        }
        needsLayout = true
        onSizeChanged()
    }

    private func refreshDownloadsButton() {
        let active = state.model.downloadsModel.hasActiveDownloads
        downloadsButton.configureSymbol(
            active ? "arrow.down.circle.fill" : "arrow.down.circle",
            title: BrowserStrings.downloadsTitle
        )
        downloadsButton.isSelected = popover.isShown || active
        downloadDot.isHidden = !active || !state.model.supportsSpaces
    }
}

// MARK: - BrowserNativeDownloadIndicator

private final class BrowserNativeDownloadIndicator: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func draw(_: NSRect) {
        BrowserChromeColors.primaryText.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
