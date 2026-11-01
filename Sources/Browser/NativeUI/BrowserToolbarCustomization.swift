// BrowserToolbarCustomization.swift

import AppKit

// MARK: - BrowserToolbarPasteboard

@MainActor enum BrowserToolbarPasteboard {
    static let itemType = NSPasteboard.PasteboardType("com.levochkaa.OpenArc.toolbar-item")
    static let sourceIndexType = NSPasteboard.PasteboardType("com.levochkaa.OpenArc.toolbar-source-index")

    static func dragItem(_ item: BrowserToolbarItem, sourceIndex: Int?) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.rawValue, forType: itemType)
        if let sourceIndex {
            pasteboardItem.setString(String(sourceIndex), forType: sourceIndexType)
        }
        return pasteboardItem
    }

    static func item(from pasteboard: NSPasteboard) -> BrowserToolbarItem? {
        pasteboard.string(forType: itemType).flatMap(BrowserToolbarItem.init(rawValue:))
    }

    static func sourceIndex(from pasteboard: NSPasteboard) -> Int? {
        pasteboard.string(forType: sourceIndexType).flatMap(Int.init)
    }
}

// MARK: - BrowserToolbarItem + Display

extension BrowserToolbarItem {
    var symbolName: String {
        switch self {
        case .back: "arrow.backward"
        case .forward: "arrow.forward"
        case .reload: "arrow.clockwise"
        case .copyLink: "link"
        case .address: "textformat.abc"
        case .flexibleSpace: "arrow.left.and.right"
        case .pinnedExtensions: "puzzlepiece.extension"
        case .splitView: "rectangle.split.2x1"
        case .siteControls: "slider.horizontal.3"
        case .command(let id): id.commandBarSystemImageName
        }
    }

    @MainActor func title(in store: BrowserShortcutStore) -> String {
        switch self {
        case .back: BrowserStrings.navigationBack
        case .forward: BrowserStrings.navigationForward
        case .reload: BrowserStrings.navigationRefresh
        case .copyLink: BrowserStrings.tabCopyURLAction
        case .address: BrowserStrings.toolbarAddressItem
        case .flexibleSpace: BrowserStrings.toolbarFlexibleSpaceItem
        case .pinnedExtensions: BrowserStrings.toolbarPinnedExtensionsItem
        case .splitView: BrowserStrings.splitViewButtonTitle
        case .siteControls: BrowserStrings.siteControlCenterAction
        case .command(let id): store.descriptor(for: id).menuTitle
        }
    }
}

// MARK: - BrowserToolbarEditOverlay

/// Sits over the toolbar while customizing: items stop acting like buttons and
/// can be dragged along the bar, or off it to remove them.
final class BrowserToolbarEditOverlay: NSView, NSDraggingSource {
    // MARK: Internal

    override var isFlipped: Bool { true }

    /// The items with their frames in this view's coordinates.
    var entries = [(item: BrowserToolbarItem, frame: CGRect)]() {
        didSet { needsDisplay = true }
    }

    var onMove: (Int, Int) -> Void = { _, _ in }
    var onInsert: (BrowserToolbarItem, Int) -> Void = { _, _ in }
    var onRemove: (Int) -> Void = { _ in }

    private var downIndex: Int?
    private var downPoint = NSPoint.zero
    private var dropIndex: Int?
    private var draggedIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([BrowserToolbarPasteboard.itemType])
        setAccessibilityElement(true)
        setAccessibilityIdentifier("browser.toolbar.customize-overlay")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        for (index, entry) in entries.enumerated() {
            let path = NSBezierPath(roundedRect: entry.frame.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            BrowserChromeColors.primaryText.withAlphaComponent(index == draggedIndex ? 0.5 : 0.28).setStroke()
            path.lineWidth = 1
            if entry.item == .flexibleSpace {
                path.setLineDash([3, 3], count: 2, phase: 0)
            }
            path.stroke()
        }
        if let dropIndex {
            BrowserChromeColors.sidebarDropIndicator.setFill()
            let x = Self.dropEdge(index: dropIndex, frames: entries.map(\.frame), width: bounds.width)
            NSBezierPath(rect: NSRect(x: x - 1, y: 3, width: 2, height: bounds.height - 6)).fill()
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        downIndex = entries.firstIndex { $0.frame.contains(downPoint) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = downIndex, entries.indices.contains(index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return }
        downIndex = nil
        draggedIndex = index
        let frame = entries[index].frame
        let dragItem = NSDraggingItem(
            pasteboardWriter: BrowserToolbarPasteboard.dragItem(entries[index].item, sourceIndex: index),
        )
        dragItem.setDraggingFrame(frame, contents: Self.image(of: self, in: frame))
        beginDraggingSession(with: [dragItem], event: event, source: self)
        needsDisplay = true
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }
    override func draggingExited(_: NSDraggingInfo?) {
        dropIndex = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let index = Self.dropIndex(at: convert(sender.draggingLocation, from: nil).x, frames: entries.map(\.frame))
        dropIndex = nil
        needsDisplay = true
        let pasteboard = sender.draggingPasteboard
        if let source = BrowserToolbarPasteboard.sourceIndex(from: pasteboard) {
            onMove(source, index)
            return true
        }
        guard let item = BrowserToolbarPasteboard.item(from: pasteboard) else { return false }
        onInsert(item, index)
        return true
    }

    /// The gap nearest to `x`.
    nonisolated static func dropIndex(at x: CGFloat, frames: [CGRect]) -> Int {
        frames.firstIndex { x < $0.midX } ?? frames.count
    }

    nonisolated static func dropEdge(index: Int, frames: [CGRect], width _: CGFloat) -> CGFloat {
        if frames.indices.contains(index) { return frames[index].minX - 1 }
        return (frames.last?.maxX ?? 0) + 1
    }

    static func image(of view: NSView, in frame: CGRect) -> NSImage {
        let image = NSImage(size: frame.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: frame) {
            view.cacheDisplay(in: frame, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation { .move }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation: NSDragOperation) {
        // Dragged off the bar: the item goes back to the palette.
        if operation.isEmpty, let draggedIndex {
            onRemove(draggedIndex)
        }
        draggedIndex = nil
        needsDisplay = true
    }

    // MARK: Private

    private func dragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropIndex = Self.dropIndex(at: convert(sender.draggingLocation, from: nil).x, frames: entries.map(\.frame))
        needsDisplay = true
        return .move
    }
}

// MARK: - BrowserToolbarCustomizePanel

/// The palette under the toolbar: everything that can go on it, Restore Defaults and Done.
@MainActor final class BrowserToolbarCustomizePanel: NSPanel {
    // MARK: Internal

    private enum Layout {
        static let width: CGFloat = 640
        static let tileWidth: CGFloat = 96
        static let tileHeight: CGFloat = 62
        static let padding: CGFloat = 16
        static let footerHeight: CGFloat = 52
        static let headerHeight: CGFloat = 40
        static let cornerRadius: CGFloat = 12
    }

    fileprivate static var tileSize: CGSize { CGSize(width: Layout.tileWidth, height: Layout.tileHeight) }
    fileprivate static var padding: CGFloat { Layout.padding }
    fileprivate static var headerHeight: CGFloat { Layout.headerHeight }
    fileprivate static var footerHeight: CGFloat { Layout.footerHeight }

    override var canBecomeKey: Bool { true }

    private let shortcutStore: BrowserShortcutStore
    private let content: BrowserToolbarPaletteView

    init(
        shortcutStore: BrowserShortcutStore,
        onReset: @escaping () -> Void,
        onDone: @escaping () -> Void,
        onRemove: @escaping (Int) -> Void,
    ) {
        self.shortcutStore = shortcutStore
        self.content = BrowserToolbarPaletteView(shortcutStore: shortcutStore, onRemove: onRemove)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = BrowserChromeColors.commandBarPanelTint.cgColor
        card.layer?.cornerRadius = Layout.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        contentView = card
        card.addSubview(content)

        let title = NSTextField(labelWithString: BrowserStrings.toolbarCustomizeHint)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = BrowserChromeColors.secondaryText
        title.frame = NSRect(x: Layout.padding, y: 12, width: Layout.width - Layout.padding * 2, height: 18)
        content.addSubview(title)
        content.header = title

        let reset = NSButton(title: BrowserStrings.toolbarRestoreDefaults, target: nil, action: nil)
        let done = NSButton(title: BrowserStrings.toolbarCustomizeDone, target: nil, action: nil)
        done.keyEquivalent = "\r"
        reset.bezelStyle = .rounded
        done.bezelStyle = .rounded
        reset.setAccessibilityIdentifier("browser.toolbar.customize-reset")
        done.setAccessibilityIdentifier("browser.toolbar.customize-done")
        reset.target = content
        reset.action = #selector(BrowserToolbarPaletteView.resetPressed)
        done.target = content
        done.action = #selector(BrowserToolbarPaletteView.donePressed)
        content.onReset = onReset
        content.onDone = onDone
        content.footerButtons = [reset, done]
        content.addSubview(reset)
        content.addSubview(done)
    }

    func update(available: [BrowserToolbarItem]) {
        let top = frame.maxY
        let height = content.update(available: available, width: Layout.width)
        setContentSize(NSSize(width: Layout.width, height: height))
        if parent != nil {
            setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
        }
        content.frame = NSRect(x: 0, y: 0, width: Layout.width, height: height)
    }
}

// MARK: - BrowserToolbarPaletteView

final class BrowserToolbarPaletteView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    weak var header: NSView?
    var footerButtons = [NSButton]()
    var onReset: () -> Void = {}
    var onDone: () -> Void = {}

    private let shortcutStore: BrowserShortcutStore
    private let onRemove: (Int) -> Void
    private var tiles = [BrowserToolbarPaletteTile]()

    init(shortcutStore: BrowserShortcutStore, onRemove: @escaping (Int) -> Void) {
        self.shortcutStore = shortcutStore
        self.onRemove = onRemove
        super.init(frame: .zero)
        registerForDraggedTypes([BrowserToolbarPasteboard.itemType])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Dropping a toolbar item here takes it off the bar.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = BrowserToolbarPasteboard.sourceIndex(from: sender.draggingPasteboard) else { return false }
        onRemove(source)
        return true
    }

    @objc func resetPressed() { onReset() }
    @objc func donePressed() { onDone() }

    /// Returns the height everything needs.
    func update(available: [BrowserToolbarItem], width: CGFloat) -> CGFloat {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = available.map { BrowserToolbarPaletteTile(item: $0, title: $0.title(in: shortcutStore)) }
        let padding = BrowserToolbarCustomizePanel.padding
        let size = BrowserToolbarCustomizePanel.tileSize
        let columns = max(Int((width - padding * 2) / size.width), 1)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(
                x: padding + CGFloat(index % columns) * size.width,
                y: BrowserToolbarCustomizePanel.headerHeight + CGFloat(index / columns) * size.height,
                width: size.width,
                height: size.height,
            )
            addSubview(tile)
        }
        let rows = (tiles.count + columns - 1) / columns
        let height = BrowserToolbarCustomizePanel.headerHeight + CGFloat(rows) * size.height
            + BrowserToolbarCustomizePanel.footerHeight
        var x = width - padding
        for button in footerButtons.reversed() {
            button.sizeToFit()
            x -= button.frame.width
            button.frame.origin = NSPoint(x: x, y: height - BrowserToolbarCustomizePanel.footerHeight + 14)
            x -= 8
        }
        return height
    }

    // MARK: Private

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        BrowserToolbarPasteboard.sourceIndex(from: sender.draggingPasteboard) == nil ? [] : .move
    }
}

// MARK: - BrowserToolbarPaletteTile

final class BrowserToolbarPaletteTile: NSView, NSDraggingSource {
    // MARK: Internal

    override var isFlipped: Bool { true }

    let item: BrowserToolbarItem

    private var downPoint = NSPoint.zero

    init(item: BrowserToolbarItem, title: String) {
        self.item = item
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("browser.toolbar.palette.\(item.rawValue)")
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        icon.contentTintColor = BrowserChromeColors.primaryText
        icon.frame = NSRect(x: 0, y: 8, width: 96, height: 22)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .regular)
        label.textColor = BrowserChromeColors.secondaryText
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 4, y: 36, width: 88, height: 16)
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// The icon and label must not take the click that starts a drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 3 else { return }
        let dragItem = NSDraggingItem(pasteboardWriter: BrowserToolbarPasteboard.dragItem(item, sourceIndex: nil))
        dragItem.setDraggingFrame(bounds, contents: BrowserToolbarEditOverlay.image(of: self, in: bounds))
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation { .move }
}
