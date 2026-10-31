// BrowserIconPicker.swift

import AppKit

// MARK: - BrowserIconPickerViewController

/// Chooses an icon for a Space, folder or tab: an Emoji tab with search and
/// categories, and an Icon tab of symbols.
final class BrowserIconPickerViewController: NSViewController, NSSearchFieldDelegate {
    // MARK: Private

    private static let size = NSSize(width: 272, height: 272)

    // MARK: Internal

    var onPick: (String) -> Void = { _ in }

    private let tabs = BrowserIconPickerTabs(titles: [BrowserStrings.iconPickerEmoji, BrowserStrings.iconPickerIcon])
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let grid = BrowserIconPickerGrid()
    private let categoryBar = BrowserIconPickerRootView()
    private var sectionOffsets = [CGFloat]()

    override func loadView() {
        let root = BrowserIconPickerRootView(frame: NSRect(origin: .zero, size: Self.size))
        view = root
        preferredContentSize = Self.size
        tabs.frame = NSRect(x: 83, y: 14, width: 106, height: 24)
        tabs.onChange = { [weak self] _ in self?.showSelectedTab() }
        root.addSubview(tabs)
        search.frame = NSRect(x: 8, y: 46, width: Self.size.width - 16, height: 26)
        search.placeholderString = BrowserStrings.iconPickerSearch
        search.delegate = self
        search.focusRingType = .default
        search.setAccessibilityIdentifier("browser.icon-picker.search")
        root.addSubview(search)
        scroll.frame = NSRect(x: 0, y: 76, width: Self.size.width, height: Self.size.height - 76 - 36)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = grid
        grid.onPick = { [weak self] in self?.onPick($0) }
        root.addSubview(scroll)
        categoryBar.frame = NSRect(x: 8, y: Self.size.height - 36, width: Self.size.width - 16, height: 36)
        root.addSubview(categoryBar)
        for (index, category) in BrowserSpaceIconCatalog.emojiCategories.enumerated() {
            let button = BrowserIconPickerCategoryButton(symbol: category.symbol)
            button.frame = NSRect(x: CGFloat(index) * (categoryBar.frame.width / 8), y: 4, width: 31, height: 28)
            button.onAction = { [weak self] in self?.scrollToCategory(index) }
            categoryBar.addSubview(button)
        }
        showSelectedTab()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tabs.selectedIndex == 0 { view.window?.makeFirstResponder(search) }
    }

    func controlTextDidChange(_: Notification) { reloadEmoji() }

    private func showSelectedTab() {
        let isEmoji = tabs.selectedIndex == 0
        search.isHidden = !isEmoji
        categoryBar.isHidden = !isEmoji
        scroll.frame = isEmoji
            ? NSRect(x: 0, y: 76, width: Self.size.width, height: Self.size.height - 76 - 36)
            : NSRect(x: 0, y: 44, width: Self.size.width, height: Self.size.height - 44)
        if isEmoji {
            reloadEmoji()
        } else {
            grid.setItems(BrowserSpaceIconCatalog.systemImageNames, width: scroll.contentSize.width)
            sectionOffsets = []
        }
        scroll.documentView?.scroll(.zero)
    }

    private func reloadEmoji() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let categories = BrowserSpaceIconCatalog.emojiCategories
        var names = [String]()
        var offsets = [CGFloat]()
        for category in categories {
            offsets.append(BrowserIconPickerGrid.rowOrigin(forItem: names.count))
            names += category.emoji
                .filter { query.isEmpty || BrowserSpaceIconCatalog.searchName(ofEmoji: $0).contains(query) }
                .map(BrowserIconImage.name(emoji:))
        }
        sectionOffsets = offsets
        grid.setItems(names, width: scroll.contentSize.width)
    }

    private func scrollToCategory(_ index: Int) {
        guard sectionOffsets.indices.contains(index) else { return }
        scroll.documentView?.scroll(NSPoint(x: 0, y: sectionOffsets[index]))
    }
}

// MARK: - BrowserIconPickerRootView

private final class BrowserIconPickerRootView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserIconPickerTabs

/// The Emoji and Icon switch.
private final class BrowserIconPickerTabs: NSView {
    override var isFlipped: Bool { true }

    // MARK: Internal

    var onChange: (Int) -> Void = { _ in }
    private(set) var selectedIndex = 0

    // MARK: Private

    private let titles: [String]

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: NSRect) {
        NSColor.white.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let width = bounds.width / CGFloat(max(titles.count, 1))
        for (index, title) in titles.enumerated() {
            let cell = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            if index == selectedIndex {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white.withAlphaComponent(index == selectedIndex ? 1 : 0.85),
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(
                at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2),
                withAttributes: attributes,
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let index = min(max(Int(x / (bounds.width / CGFloat(max(titles.count, 1)))), 0), titles.count - 1)
        guard index != selectedIndex else { return }
        selectedIndex = index
        needsDisplay = true
        onChange(index)
    }
}

// MARK: - BrowserIconPickerGrid

/// Eight icons a row; the one under the pointer lights up.
final class BrowserIconPickerGrid: NSView {
    // MARK: Private

    private static let columns = 8
    private static let rowHeight: CGFloat = 31
    private static let columnWidth: CGFloat = 31
    private static let leading: CGFloat = 12.5

    override var isFlipped: Bool { true }

    // MARK: Internal

    var onPick: (String) -> Void = { _ in }

    private var items = [String]()
    private var images = [Int: NSImage]()
    private var tracking: NSTrackingArea?
    private var hovered: Int?

    override func draw(_ dirtyRect: NSRect) {
        for index in visibleItemRange(in: dirtyRect) {
            let cell = cellRect(index)
            if index == hovered {
                NSColor.white.withAlphaComponent(0.11).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 4, yRadius: 4).fill()
            }
            guard let image = image(index) else { continue }
            let size = image.size
            let rect = NSRect(
                x: cell.midX - size.width / 2,
                y: cell.midY - size.height / 2,
                width: size.width,
                height: size.height,
            )
            if image.isTemplate {
                NSGraphicsContext.saveGraphicsState()
                NSColor.white.set()
                let tinted = NSImage(size: size, flipped: false) { bounds in
                    image.draw(in: bounds)
                    NSColor.white.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil,
                )
                NSGraphicsContext.restoreGraphicsState()
            } else {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { setHovered(itemIndex(at: event)) }
    override func mouseExited(with _: NSEvent) { setHovered(nil) }

    override func mouseUp(with event: NSEvent) {
        if let index = itemIndex(at: event) { onPick(items[index]) }
    }

    static func rowOrigin(forItem index: Int) -> CGFloat {
        CGFloat(index / columns) * rowHeight
    }

    func setItems(_ names: [String], width: CGFloat) {
        items = names
        images.removeAll()
        hovered = nil
        let rows = (names.count + Self.columns - 1) / Self.columns
        frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows) * Self.rowHeight + 8)
        needsDisplay = true
    }

    private func cellRect(_ index: Int) -> NSRect {
        NSRect(
            x: Self.leading + CGFloat(index % Self.columns) * Self.columnWidth,
            y: 4 + CGFloat(index / Self.columns) * Self.rowHeight,
            width: 30,
            height: 30,
        )
    }

    private func visibleItemRange(in rect: NSRect) -> Range<Int> {
        let first = max(Int((rect.minY - 4) / Self.rowHeight), 0) * Self.columns
        let last = min((Int((rect.maxY - 4) / Self.rowHeight) + 1) * Self.columns, items.count)
        return first < last ? first..<last : 0..<0
    }

    private func image(_ index: Int) -> NSImage? {
        if let image = images[index] { return image }
        let name = items[index]
        let isEmoji = BrowserIconImage.emoji(from: name) != nil
        let image = BrowserIconImage.image(named: name, pointSize: isEmoji ? 22 : 14)
        images[index] = image
        return image
    }

    private func itemIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int((point.x - Self.leading) / Self.columnWidth)
        let row = Int((point.y - 4) / Self.rowHeight)
        let index = row * Self.columns + column
        guard point.x >= Self.leading, point.y >= 4, column < Self.columns, items.indices.contains(index) else {
            return nil
        }
        return index
    }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }
}

// MARK: - BrowserIconPickerCategoryButton

private final class BrowserIconPickerCategoryButton: NSView {
    var onAction: () -> Void = {}

    init(symbol: String) {
        super.init(frame: .zero)
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        image.autoresizingMask = [.width, .height]
        image.frame = NSRect(x: 0, y: 0, width: 31, height: 28)
        addSubview(image)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseUp(with _: NSEvent) { onAction() }
}

// MARK: - BrowserIconPickerPresenter

/// Shows the picker in a transient popover beside an anchor.
@MainActor final class BrowserIconPickerPresenter {
    static let shared = BrowserIconPickerPresenter()

    private var popover: BrowserNativePopover?

    /// Opens where the pointer is, which is where the menu that asked for it was.
    func showAtPointer(onPick: @escaping (String) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let rect = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        show(relativeTo: rect, of: view, edge: view.isFlipped ? .maxY : .minY, onPick: onPick)
    }

    func show(relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge, onPick: @escaping (String) -> Void) {
        popover?.performClose(nil)
        let picker = BrowserIconPickerViewController()
        let next = BrowserNativePopover()
        picker.onPick = { [weak next] name in
            onPick(name)
            next?.performClose(nil)
        }
        next.behavior = .transient
        next.contentViewController = picker
        next.appearance = NSAppearance(named: .darkAqua)
        popover = next
        next.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}
