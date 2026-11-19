// BrowserBookmarksBarNSView.swift

import AppKit
import Combine

// MARK: - BrowserBookmarkFolderDestination

struct BrowserBookmarkFolderDestination: Equatable {
    let id: String
    let title: String

    static func destinations(
        in items: [BrowserBookmarkItem],
        excluding excludedID: String? = nil,
    ) -> [BrowserBookmarkFolderDestination] {
        items.flatMap { item -> [BrowserBookmarkFolderDestination] in
            guard item.isFolder, item.id != excludedID else { return [] }
            return [.init(id: item.id, title: item.displayTitle)]
                + destinations(in: item.children, excluding: excludedID).map {
                    .init(id: $0.id, title: "\(item.displayTitle) / \($0.title)")
                }
        }
    }
}

// MARK: - BrowserBookmarksBarNSView

final class BrowserBookmarksBarNSView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    let star = BrowserNativeChromeButton(
        symbol: "star",
        title: BrowserStrings.bookmarksAddCurrentPage,
        style: .bookmark,
        pressEffect: .compress,
        action: {},
    )
    let chevron = BrowserNativeChromeButton(
        symbol: "chevron.right.2",
        title: BrowserStrings.bookmarksMoreItems,
        style: .bookmark,
        pressEffect: .compress,
        action: {},
    )
    private(set) var buttons = [String: BrowserNativeBookmarkButton]()
    let interactions: BrowserBookmarkInteractions

    // MARK: Private

    private let model: BrowserChromeModel
    private let cache: BrowserFaviconCache
    private let scroll = NSScrollView()
    private let document = BrowserNativeBookmarksDocument()
    private var items = [BrowserBookmarkItem]()
    /// Model changes refresh the view once per run loop pass.
    private lazy var coalescedRefresh = BrowserCoalescedRefresh { [weak self] in self?.refresh() }
    private let dropIndicator = NSView()
    private var firstOverflowIndex: Int?

    /// The items that didn't fit, oldest first.
    var overflowItems: [BrowserBookmarkItem] {
        firstOverflowIndex.map { Array(items[$0...]) } ?? []
    }

    init(model: BrowserChromeModel, cache: BrowserFaviconCache = .shared) {
        self.model = model
        self.cache = cache
        self.interactions = BrowserBookmarkInteractions(model: model, cache: cache)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.bookmarks.bar")
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(scroll)
        addSubview(star)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        document.menuProvider = { [weak self] in self?.barMenu() ?? NSMenu() }
        document.dropDelegate = self
        document.registerForDraggedTypes(BrowserBookmarkPasteboard.dragTypes)
        document.addSubview(dropIndicator)
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = BrowserChromeColors.sidebarDropIndicator.cgColor
        dropIndicator.isHidden = true
        addSubview(chevron)
        chevron.isHidden = true
        chevron.setAccessibilityIdentifier("browser.bookmarks.more")
        chevron.onAction = { [weak self] in self?.openOverflow() }
        star.setAccessibilityIdentifier("browser.bookmarks.toggle-current")
        star.onAction = { [weak model] in _ = model?.toggleSelectedTabBookmark() }
        coalescedRefresh.observe([
            model.objectWillChange.eraseToAnyPublisher(),
            model.bookmarksModel.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
        ])
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { interactions.dismissPanels() }

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.bookmarksBarControlSize
        let padding = BrowserChromeLayout.bookmarksBarHorizontalPadding
        star.frame = NSRect(
            x: max(bounds.width - padding - size, 0),
            y: (bounds.height - size) / 2,
            width: size,
            height: size,
        )
        let spacing = BrowserChromeLayout.bookmarksBarItemSpacing
        let available = max(star.frame.minX - BrowserChromeLayout.bookmarksBarControlSpacing * 2, 0)
        let widths = items.map { buttons[$0.id]?.preferredWidth ?? 0 }
        let total = padding * 2 + widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        let overflows = total > available
        chevron.isHidden = !overflows
        chevron.frame = NSRect(
            x: max(star.frame.minX - BrowserChromeLayout.bookmarksBarControlSpacing - size, 0),
            y: (bounds.height - size) / 2,
            width: size,
            height: size,
        )
        let barWidth = overflows
            ? max(chevron.frame.minX - BrowserChromeLayout.bookmarksBarControlSpacing, 0)
            : available
        scroll.frame = NSRect(x: 0, y: 0, width: barWidth, height: bounds.height)
        var x = padding
        firstOverflowIndex = nil
        for (index, item) in items.enumerated() {
            guard let button = buttons[item.id] else { continue }
            let width = widths[index]
            if firstOverflowIndex == nil, overflows, x + width > barWidth - padding {
                firstOverflowIndex = index
            }
            button.isHidden = firstOverflowIndex != nil
            guard firstOverflowIndex == nil else { continue }
            button.frame = NSRect(
                x: x,
                y: (bounds.height - BrowserChromeLayout.bookmarksBarItemHeight) / 2,
                width: width,
                height: BrowserChromeLayout.bookmarksBarItemHeight,
            )
            x += width + spacing
        }
        document.frame = NSRect(x: 0, y: 0, width: barWidth, height: bounds.height)
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func menu(for _: NSEvent) -> NSMenu? { barMenu() }

    func refresh() {
        items = model.bookmarksModel.bookmarkBarItems
        let ids = Set(items.map(\.id))
        for id in Set(buttons.keys).subtracting(ids) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in items {
            let button = buttons[item.id] ?? BrowserNativeBookmarkButton(cache: cache)
            if buttons[item.id] == nil {
                buttons[item.id] = button
                document.addSubview(button)
            }
            button.update(item)
            button.onClick = { [weak self, weak button] event in
                guard let self else { return }
                if item.isFolder, let button {
                    toggleFolder(item, from: button)
                } else if let url = item.urlString {
                    model.openBookmark(urlString: url, modifiers: event?.modifierFlags ?? [])
                }
            }
            button.onHoverChanged = { [weak self, weak button] hovering in
                // With a folder open, moving along the bar switches folders, as a menu bar does.
                guard let self, hovering, let button, !interactions.panels.isEmpty else { return }
                if item.isFolder {
                    openFolder(item, from: button)
                }
            }
            button.menuProvider = { [weak self] in self?.itemMenu(item) ?? NSMenu() }
            button.onBeginDragSession = { [weak self, weak button] _ in
                guard let self, let button else { return false }
                return interactions.beginDrag(of: item, from: button)
            }
        }
        interactions.refreshPanels()
        let current = model.currentTab
        let enabled = current.map { !$0.urlString.isEmpty } ?? false
        let bookmarked = current.map { model.isBookmarked(urlString: $0.urlString) } ?? false
        star.configureSymbol(
            bookmarked ? "star.fill" : "star",
            title: bookmarked
                ? BrowserStrings.bookmarksRemoveCurrentPage
                : BrowserStrings.bookmarksAddCurrentPage,
        )
        star.tooltipShortcut = model.shortcutStore.shortcut(for: .toggleBookmark)
        star.isSelected = bookmarked
        star.isEnabled = enabled
        star.alphaValue = enabled ? 1 : 0.42
        needsLayout = true
    }

    func barMenu() -> NSMenu {
        interactions.containerMenu(folderID: nil)
    }

    func itemMenu(_ item: BrowserBookmarkItem) -> NSMenu {
        interactions.itemMenu(item)
    }

    fileprivate func openFolder(_ item: BrowserBookmarkItem, from anchor: NSView) {
        let interactions = interactions
        let id = item.id
        if interactions.panels.first?.list.folderID == id { return }
        interactions.openPanel(
            items: { interactions.model.bookmarksModel.item(withID: id)?.children },
            folderID: id,
            baseIndex: 0,
            anchor: anchor,
            level: 0,
        )
    }

    // MARK: Drops

    fileprivate func dropLocation(for sender: NSDraggingInfo) -> BrowserBookmarkDrop {
        let point = document.convert(sender.draggingLocation, from: nil)
        let visible = items.prefix(firstOverflowIndex ?? items.count)
        let spans = visible.compactMap { item -> (item: BrowserBookmarkItem, start: CGFloat, end: CGFloat)? in
            buttons[item.id].map { (item, $0.frame.minX, $0.frame.maxX) }
        }
        return BrowserBookmarkDrop.location(at: point.x, spans: spans, folderID: nil)
    }

    fileprivate func dragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = dropLocation(for: sender)
        let operation = interactions.dragOperation(for: drop, pasteboard: sender.draggingPasteboard)
        guard !operation.isEmpty else {
            dragFinished()
            return []
        }
        switch drop {
        case .between(_, let index):
            interactions.cancelSpring()
            let padding = BrowserChromeLayout.bookmarksBarHorizontalPadding
            let visible = items.prefix(firstOverflowIndex ?? items.count)
            let edge: CGFloat =
                if index < visible.count, let button = buttons[visible[index].id] {
                    button.frame.minX - 1
                } else if let last = visible.last, let button = buttons[last.id] {
                    button.frame.maxX + 1
                } else {
                    padding
                }
            dropIndicator.isHidden = false
            dropIndicator.frame = NSRect(x: edge - 1, y: 5, width: 2, height: bounds.height - 10)
            document.addSubview(dropIndicator, positioned: .above, relativeTo: nil)
        case .into(let id):
            dropIndicator.isHidden = true
            if let item = items.first(where: { $0.id == id }), let button = buttons[id] {
                interactions.springLoad(item) { [weak self, weak button] in
                    if let button { self?.openFolder($0, from: button) }
                }
            }
        }
        return operation
    }

    fileprivate func dragFinished() {
        dropIndicator.isHidden = true
        interactions.cancelSpring()
    }

    fileprivate func performDrop(_ sender: NSDraggingInfo) -> Bool {
        let drop = dropLocation(for: sender)
        dragFinished()
        return interactions.perform(drop: drop, pasteboard: sender.draggingPasteboard, inPanel: false)
    }

    private func toggleFolder(_ item: BrowserBookmarkItem, from anchor: NSView) {
        if interactions.panels.first?.list.folderID == item.id {
            interactions.dismissPanels()
        } else {
            openFolder(item, from: anchor)
        }
    }

    private func openOverflow() {
        guard interactions.panels.isEmpty, let first = firstOverflowIndex else {
            interactions.dismissPanels()
            return
        }
        interactions.openPanel(
            items: { [weak self] in self?.overflowItems },
            folderID: nil,
            baseIndex: first,
            anchor: chevron,
            level: 0,
        )
    }
}

// MARK: - BrowserNativeBookmarkButton

final class BrowserNativeBookmarkButton: BrowserNativePressableView {
    // MARK: Internal

    /// Rows of a folder panel point at the folder they open.
    var showsDisclosure = false {
        didSet {
            disclosure.isHidden = !showsDisclosure
            needsLayout = true
        }
    }

    // MARK: Private

    private let hoverAnimation = BrowserNativeAnimation()
    private var lastHover = false
    private let favicon: BrowserFaviconNSView
    private let folder = NSImageView()
    private let disclosure = NSImageView()
    private let label = BrowserNativeControls.label(
        "",
        size: 12.5,
        weight: .medium,
        color: BrowserChromeColors.primaryText,
    )

    var preferredWidth: CGFloat {
        // A truncating label's intrinsic size is less than its text needs.
        min(
            BrowserChromeLayout.bookmarksBarItemMaximumWidth,
            ceil(label.attributedStringValue.size().width) + 6 + BrowserChromeLayout.bookmarksBarIconSize
                + BrowserChromeLayout.bookmarksBarLabelSpacing + BrowserChromeLayout
                .bookmarksBarItemHorizontalPadding * 2,
        )
    }

    init(cache: BrowserFaviconCache) {
        self.favicon = BrowserFaviconNSView(cache: cache)
        super.init(frame: .zero)
        cornerRadius = BrowserChromeLayout.bookmarksBarItemCornerRadius
        pressedScale = 1
        for view in [favicon, folder, disclosure, label] {
            addSubview(view)
        }
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        disclosure.contentTintColor = BrowserChromeColors.secondaryText
        disclosure.isHidden = true
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: BrowserChromeLayout.bookmarksBarIconSize,
                weight: .semibold,
            ))
        folder.contentTintColor = BrowserChromeColors.secondaryText
        folder.imageScaling = .scaleProportionallyUpOrDown
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func interactionChanged() { super.interactionChanged()
        guard lastHover != isHovered else { return }
        lastHover = isHovered
        let from = fillColor
        let to = isHovered ? BrowserChromeColors.rowHover : .clear
        hoverAnimation.start(.hover) { [weak self] progress in
            self?.fillColor = from.blended(withFraction: min(max(progress, 0), 1), of: to) ?? to
        }
    }

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.bookmarksBarIconSize
        let x = BrowserChromeLayout.bookmarksBarItemHorizontalPadding
        favicon.frame = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        folder.frame = favicon.frame
        disclosure.frame = NSRect(x: bounds.width - x - 10, y: (bounds.height - 12) / 2, width: 10, height: 12)
        let trailing = showsDisclosure ? 14 : CGFloat(0)
        label.frame = NSRect(
            x: x + size + BrowserChromeLayout.bookmarksBarLabelSpacing,
            y: (bounds.height - 17) / 2,
            width: max(bounds.width - x * 2 - size - BrowserChromeLayout.bookmarksBarLabelSpacing - trailing, 0),
            height: 17,
        )
    }

    func update(_ item: BrowserBookmarkItem) {
        label.stringValue = item.displayTitle
        label.lineBreakMode = .byTruncatingTail
        favicon.isHidden = item.isFolder
        folder.isHidden = !item.isFolder
        if !item.isFolder {
            favicon.update(url: item.faviconURL, pageURLString: item.urlString)
        }
        tooltipTitle = item.displayTitle
        tooltipCaption = item.hostDisplayString
        setAccessibilityLabel(item.displayTitle)
        setAccessibilityIdentifier("browser.bookmarks.item.\(item.id)")
        needsLayout = true
    }
}

// MARK: - BrowserNativeBookmarksDocument

private final class BrowserNativeBookmarksDocument: NSView {
    override var isFlipped: Bool { true }

    var menuProvider: (() -> NSMenu)?
    weak var dropDelegate: BrowserBookmarksBarNSView?

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropDelegate?
        .dragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropDelegate?
        .dragUpdated(sender) ?? []
    }

    override func draggingExited(_: NSDraggingInfo?) { dropDelegate?.dragFinished() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropDelegate?.performDrop(sender) ?? false }
}
