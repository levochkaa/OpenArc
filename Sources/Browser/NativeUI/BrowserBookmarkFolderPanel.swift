// BrowserBookmarkFolderPanel.swift

import AppKit

// MARK: - BrowserBookmarkFolderPanelLayout

private enum BrowserBookmarkFolderPanelLayout {
    static let width: CGFloat = 280
    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 6
    static let maximumHeight: CGFloat = 520
    static let cornerRadius: CGFloat = 10
}

// MARK: - BrowserBookmarkFolderPanel

/// A bookmark folder's contents. Unlike a menu, it takes right clicks, reordering
/// and drops, and it stays open while a drag passes over it.
@MainActor final class BrowserBookmarkFolderPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    // MARK: Internal

    let stackLevel: Int
    let list: BrowserBookmarkFolderListView

    private let scroll = NSScrollView()
    private let items: () -> [BrowserBookmarkItem]?

    init(
        interactions: BrowserBookmarkInteractions,
        items: @escaping () -> [BrowserBookmarkItem]?,
        folderID: String?,
        baseIndex: Int,
        level: Int,
    ) {
        self.stackLevel = level
        self.items = items
        self.list = BrowserBookmarkFolderListView(
            interactions: interactions,
            folderID: folderID,
            baseIndex: baseIndex,
            level: level,
        )
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BrowserBookmarkFolderPanelLayout.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
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
        card.layer?.cornerRadius = BrowserBookmarkFolderPanelLayout.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        contentView = card
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.autoresizingMask = [.width, .height]
        card.addSubview(scroll)
        _ = refresh()
    }

    /// False when the folder is gone.
    @discardableResult func refresh() -> Bool {
        guard let current = items() else { return false }
        list.update(current)
        let width = BrowserBookmarkFolderPanelLayout.width
        let height = min(list.contentHeight, BrowserBookmarkFolderPanelLayout.maximumHeight)
        let top = frame.maxY
        setContentSize(NSSize(width: width, height: height))
        if parent != nil {
            setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
        }
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
        list.frame = NSRect(x: 0, y: 0, width: width, height: list.contentHeight)
        return true
    }
}

// MARK: - BrowserBookmarkFolderListView

final class BrowserBookmarkFolderListView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    private(set) var rows = [String: BrowserNativeBookmarkButton]()
    private(set) var items = [BrowserBookmarkItem]()

    let folderID: String?

    private let interactions: BrowserBookmarkInteractions
    private let baseIndex: Int
    private let level: Int
    private let indicator = NSView()
    private let emptyLabel = BrowserNativeControls.label(
        BrowserStrings.bookmarksEmptyFolder,
        size: 12.5,
        weight: .medium,
        color: BrowserChromeColors.secondaryText,
    )
    private var hoverTask: Task<Void, Never>?

    var contentHeight: CGFloat {
        BrowserBookmarkFolderPanelLayout.padding * 2
            + CGFloat(max(items.count, 1)) * BrowserBookmarkFolderPanelLayout.rowHeight
    }

    init(interactions: BrowserBookmarkInteractions, folderID: String?, baseIndex: Int, level: Int) {
        self.interactions = interactions
        self.folderID = folderID
        self.baseIndex = baseIndex
        self.level = level
        super.init(frame: .zero)
        addSubview(emptyLabel)
        addSubview(indicator)
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = BrowserChromeColors.sidebarDropIndicator.cgColor
        indicator.isHidden = true
        registerForDraggedTypes(BrowserBookmarkPasteboard.dragTypes)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func menu(for _: NSEvent) -> NSMenu? {
        interactions.containerMenu(folderID: folderID)
    }

    // MARK: Drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }

    override func draggingExited(_: NSDraggingInfo?) {
        indicator.isHidden = true
        interactions.cancelSpring()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        interactions.cancelSpring()
        return interactions.perform(
            drop: drop(for: sender),
            pasteboard: sender.draggingPasteboard,
            inPanel: true,
        )
    }

    func update(_ newItems: [BrowserBookmarkItem]) {
        items = newItems
        for id in Set(rows.keys).subtracting(items.map(\.id)) {
            rows.removeValue(forKey: id)?.removeFromSuperview()
        }
        emptyLabel.isHidden = !items.isEmpty
        let layout = BrowserBookmarkFolderPanelLayout.self
        emptyLabel.frame = NSRect(x: layout.padding + 12, y: layout.padding + 5, width: layout.width - 40, height: 17)
        for (offset, item) in items.enumerated() {
            let row = rows[item.id] ?? BrowserNativeBookmarkButton(cache: interactions.cache)
            if rows[item.id] == nil {
                rows[item.id] = row
                addSubview(row)
            }
            row.showsDisclosure = item.isFolder
            row.update(item)
            row.frame = NSRect(
                x: layout.padding,
                y: layout.padding + CGFloat(offset) * layout.rowHeight,
                width: layout.width - layout.padding * 2,
                height: layout.rowHeight,
            )
            configure(row, for: item)
        }
    }

    // MARK: Private

    private func configure(_ row: BrowserNativeBookmarkButton, for item: BrowserBookmarkItem) {
        let interactions = interactions
        let level = level
        row.onClick = { [weak self, weak row] _ in
            if item.isFolder {
                if let row { self?.openFolder(item, from: row) }
            } else if let url = item.urlString {
                interactions.dismissPanels()
                interactions.model.openBookmark(urlString: url)
            }
        }
        row.onHoverChanged = { [weak self, weak row] hovering in
            guard let self else { return }
            hoverTask?.cancel()
            guard hovering, let row else { return }
            hoverTask = Task { [weak self, weak row] in
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, let self, let row else { return }
                if item.isFolder {
                    openFolder(item, from: row)
                } else {
                    interactions.closePanels(from: level + 1)
                }
            }
        }
        row.menuProvider = { interactions.itemMenu(item) }
        row.onBeginDragSession = { [weak row] _ in
            guard let row else { return false }
            return interactions.beginDrag(of: item, from: row)
        }
    }

    private func openFolder(_ item: BrowserBookmarkItem, from row: NSView) {
        let interactions = interactions
        let id = item.id
        if interactions.panels.count > level + 1,
           interactions.panels[level + 1].list.folderID == id
        {
            return
        }
        interactions.openPanel(
            items: { interactions.model.bookmarksModel.item(withID: id)?.children },
            folderID: id,
            baseIndex: 0,
            anchor: row,
            level: level + 1,
        )
    }

    private func drop(for sender: NSDraggingInfo) -> BrowserBookmarkDrop {
        let point = convert(sender.draggingLocation, from: nil)
        let spans = items.compactMap { item -> (item: BrowserBookmarkItem, start: CGFloat, end: CGFloat)? in
            rows[item.id].map { (item, $0.frame.minY, $0.frame.maxY) }
        }
        return BrowserBookmarkDrop.location(at: point.y, spans: spans, folderID: folderID, baseIndex: baseIndex)
    }

    private func dragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = drop(for: sender)
        let operation = interactions.dragOperation(for: drop, pasteboard: sender.draggingPasteboard)
        guard !operation.isEmpty else {
            indicator.isHidden = true
            interactions.cancelSpring()
            return []
        }
        let layout = BrowserBookmarkFolderPanelLayout.self
        switch drop {
        case .between(_, let index):
            interactions.cancelSpring()
            indicator.isHidden = false
            indicator.frame = NSRect(
                x: layout.padding + 4,
                y: layout.padding + CGFloat(index - baseIndex) * layout.rowHeight - 1,
                width: bounds.width - layout.padding * 2 - 8,
                height: 2,
            )
        case .into(let id):
            indicator.isHidden = true
            if let item = items.first(where: { $0.id == id }), let row = rows[id] {
                interactions.springLoad(item) { [weak self, weak row] in
                    if let row { self?.openFolder($0, from: row) }
                }
            }
        }
        return operation
    }
}
