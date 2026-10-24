import AppKit

// MARK: - BrowserFolderPreviewItem

struct BrowserFolderPreviewItem: Equatable {
    let id: String
    let title: String
    let urlString: String
    let faviconURL: URL?
}

// MARK: - BrowserFolderPreviewCoordinator

/// Folder preview: resting the pointer on a collapsed folder lists its
/// tabs beside the sidebar, with a search field; a click or Return opens one.
/// The list does not take the keyboard until its search field is clicked, so
/// hovering never pulls focus from the page.
@MainActor final class BrowserFolderPreviewCoordinator {
    // MARK: Internal

    /// Matches the split drop pause.
    static let showDelay: TimeInterval = 0.5
    static let hideDelay: TimeInterval = 0.25

    var isEnabled: () -> Bool = { true }
    var items: (String) -> [BrowserFolderPreviewItem] = { _ in [] }
    var onSelect: (String) -> Void = { _ in }

    private(set) var panel: BrowserFolderPreviewPanel?
    private(set) var shownFolderID: String?

    /// Beside the row on the page's side, top-aligned with it and kept on screen.
    static func frame(for size: NSSize, beside row: NSView) -> NSRect {
        guard let window = row.window else { return NSRect(origin: .zero, size: size) }
        let rowFrame = window.convertToScreen(row.convert(row.bounds, to: nil))
        let opensRight = rowFrame.midX < window.frame.midX
        var origin = NSPoint(
            x: opensRight ? rowFrame.maxX + 8 : rowFrame.minX - 8 - size.width,
            y: rowFrame.maxY - size.height
        )
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        return NSRect(origin: origin, size: size).integral
    }

    func rowHoverChanged(folderID: String, row: NSView, hovered: Bool) {
        if hovered {
            hideWork?.cancel()
            guard shownFolderID != folderID else { return }
            schedule(&showWork, after: Self.showDelay) { [weak self, weak row] in
                guard let self, let row else { return }
                show(folderID: folderID, beside: row)
            }
        } else {
            showWork?.cancel()
            if shownFolderID == folderID {
                scheduleHide()
            }
        }
    }

    func show(folderID: String, beside row: NSView) {
        guard isEnabled(), let window = row.window else { return }
        let items = items(folderID)
        guard !items.isEmpty else {
            dismiss()
            return
        }
        dismiss()
        let panel = BrowserFolderPreviewPanel(items: items)
        panel.onSelect = { [weak self] id in
            self?.dismiss()
            self?.onSelect(id)
        }
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.onHoverChanged = { [weak self, weak panel] hovered in
            guard let self else { return }
            if hovered {
                hideWork?.cancel()
            } else if panel?.isKeyWindow == false {
                scheduleHide()
            }
        }
        panel.setFrame(Self.frame(for: panel.preferredSize, beside: row), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        shownFolderID = folderID
    }

    func dismiss() {
        showWork?.cancel()
        hideWork?.cancel()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        shownFolderID = nil
    }

    // MARK: Private

    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    private func scheduleHide() {
        schedule(&hideWork, after: Self.hideDelay) { [weak self] in
            guard let self, panel?.isPointerInside != true, panel?.isKeyWindow != true else { return }
            dismiss()
        }
    }

    private func schedule(_ work: inout DispatchWorkItem?, after delay: TimeInterval, _ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

// MARK: - BrowserFolderPreviewPanel

/// The preview's floating list. It becomes key only when its search field is
/// clicked.
final class BrowserFolderPreviewPanel: NSPanel, NSSearchFieldDelegate {
    // MARK: Lifecycle

    init(items: [BrowserFolderPreviewItem]) {
        self.items = items
        self.visibleItems = items
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size(forRowCount: items.count)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        let surface = BrowserFolderPreviewSurface()
        surface.fillColor = BrowserChromeColors.tooltipBackground
        surface.strokeColor = BrowserChromeColors.tooltipBorder
        surface.cornerRadius = Self.cornerRadius
        surface.onHoverChanged = { [weak self] hovered in
            self?.isPointerInside = hovered
            self?.onHoverChanged(hovered)
        }
        contentView = surface
        searchField.placeholderString = BrowserStrings.folderPreviewSearchPlaceholder
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.setAccessibilityIdentifier("browser.folder-preview.search")
        surface.addSubview(searchField)
        surface.addSubview(list)
        setAccessibilityIdentifier("browser.folder-preview")
        reloadRows()
    }

    // MARK: Internal

    static let width: CGFloat = 280
    static let rowHeight: CGFloat = 28
    static let maximumVisibleRows = 8
    static let searchHeight: CGFloat = 36
    static let padding: CGFloat = 6
    static let cornerRadius: CGFloat = 10

    override var canBecomeKey: Bool { true }

    let searchField = NSSearchField()
    private(set) var visibleItems: [BrowserFolderPreviewItem]
    private(set) var selectedIndex = 0
    private(set) var isPointerInside = false
    var onSelect: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }

    var preferredSize: NSSize { Self.size(forRowCount: items.count) }

    override func resignKey() {
        super.resignKey()
        if !isPointerInside {
            onCancel()
        }
    }

    static func size(forRowCount count: Int) -> NSSize {
        NSSize(
            width: width,
            height: searchHeight + CGFloat(min(max(count, 1), maximumVisibleRows)) * rowHeight + padding * 2
        )
    }

    func controlTextDidChange(_: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visibleItems = query.isEmpty
            ? items
            : items.filter {
                $0.title.lowercased().contains(query) || $0.urlString.lowercased().contains(query)
            }
        selectedIndex = 0
        reloadRows()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(selectedIndex + 1)
        case #selector(NSResponder.moveUp(_:)):
            select(selectedIndex - 1)
        case #selector(NSResponder.insertNewline(_:)):
            if visibleItems.indices.contains(selectedIndex) {
                onSelect(visibleItems[selectedIndex].id)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
        default:
            return false
        }
        return true
    }

    // MARK: Private

    private let items: [BrowserFolderPreviewItem]
    private let list = BrowserFolderPreviewList()

    private func select(_ index: Int) {
        guard visibleItems.indices.contains(index) else { return }
        selectedIndex = index
        list.highlightedIndex = index
        list.scrollRowToVisible(index)
    }

    private func reloadRows() {
        guard let content = contentView else { return }
        let bounds = content.bounds
        searchField.frame = NSRect(
            x: Self.padding + 2,
            y: Self.padding + 4,
            width: bounds.width - Self.padding * 2 - 4,
            height: Self.searchHeight - 10
        )
        list.frame = NSRect(
            x: Self.padding,
            y: Self.padding + Self.searchHeight,
            width: bounds.width - Self.padding * 2,
            height: max(bounds.height - Self.searchHeight - Self.padding * 2, 0)
        )
        list.update(items: visibleItems, rowHeight: Self.rowHeight) { [weak self] id in self?.onSelect(id) }
        list.highlightedIndex = visibleItems.isEmpty ? nil : selectedIndex
    }
}

// MARK: - BrowserFolderPreviewSurface

/// Reports the pointer entering and leaving the preview.
private final class BrowserFolderPreviewSurface: BrowserNativeSurface {
    var onHoverChanged: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) { onHoverChanged(true) }
    override func mouseExited(with _: NSEvent) { onHoverChanged(false) }
}

// MARK: - BrowserFolderPreviewList

/// The tabs of the preview: favicon and title rows that scroll past eight.
private final class BrowserFolderPreviewList: NSScrollView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = stack
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    var highlightedIndex: Int? {
        didSet {
            for (index, row) in rows.enumerated() {
                row.isHighlighted = index == highlightedIndex
            }
        }
    }

    func update(items: [BrowserFolderPreviewItem], rowHeight: CGFloat, onSelect: @escaping (String) -> Void) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = BrowserFolderPreviewRow(item: item)
            row.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: contentSize.width, height: rowHeight)
            row.autoresizingMask = [.width]
            row.onSelect = { onSelect(item.id) }
            stack.addSubview(row)
            return row
        }
        stack.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: CGFloat(items.count) * rowHeight)
        self.rowHeight = rowHeight
    }

    func scrollRowToVisible(_ index: Int) {
        stack.scrollToVisible(NSRect(x: 0, y: CGFloat(index) * rowHeight, width: 1, height: rowHeight))
    }

    // MARK: Private

    private let stack = BrowserFolderPreviewFlippedView()
    private var rows = [BrowserFolderPreviewRow]()
    private var rowHeight: CGFloat = 28
}

// MARK: - BrowserFolderPreviewFlippedView

private final class BrowserFolderPreviewFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserFolderPreviewRow

final class BrowserFolderPreviewRow: NSView {
    // MARK: Lifecycle

    init(item: BrowserFolderPreviewItem) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        favicon.update(url: item.faviconURL, pageURLString: item.urlString)
        title.stringValue = item.title
        title.lineBreakMode = .byTruncatingTail
        addSubview(favicon)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("browser.folder-preview.row")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    var onSelect: () -> Void = {}

    var isHighlighted = false { didSet { refreshBackground() } }

    override func layout() {
        super.layout()
        favicon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        title.frame = NSRect(x: 32, y: (bounds.height - 16) / 2, width: max(bounds.width - 40, 0), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onSelect()
        }
    }

    override func mouseDown(with _: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }

    // MARK: Private

    private let favicon = BrowserFaviconNSView()
    private let title = BrowserNativeControls.label("", size: 12.5, color: BrowserChromeColors.primaryText)
    private var isHovered = false

    private func refreshBackground() {
        let color = isHighlighted ? BrowserChromeColors.rowSelected : isHovered ? BrowserChromeColors.rowHover : .clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
