// BrowserBookmarkInteractions.swift

import AppKit

// MARK: - BrowserBookmarkDrop

/// Where a dragged bookmark lands: between two items, or inside a folder.
enum BrowserBookmarkDrop: Equatable {
    case between(folderID: String?, index: Int)
    case into(folderID: String)

    /// `spans` are the items on screen with their edges along the drag axis, and
    /// `baseIndex` is the first one's place in its folder. The middle of a folder
    /// means inside it, and everything else means before or after an item.
    static func location(
        at position: CGFloat,
        spans: [(item: BrowserBookmarkItem, start: CGFloat, end: CGFloat)],
        folderID: String?,
        baseIndex: Int = 0,
    ) -> BrowserBookmarkDrop {
        for (offset, span) in spans.enumerated() where position < span.end {
            let width = span.end - span.start
            if span.item.isFolder, position > span.start + width / 4, position < span.end - width / 4 {
                return .into(folderID: span.item.id)
            }
            let isFirstHalf = position < span.start + width / 2
            return .between(folderID: folderID, index: baseIndex + offset + (isFirstHalf ? 0 : 1))
        }
        return .between(folderID: folderID, index: baseIndex + spans.count)
    }
}

// MARK: - BrowserBookmarkPasteboard

@MainActor enum BrowserBookmarkPasteboard {
    static let idType = NSPasteboard.PasteboardType("com.levochkaa.OpenArc.bookmark-id")
    static let treeType = NSPasteboard.PasteboardType("com.levochkaa.OpenArc.bookmark-tree")

    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    static var dragTypes: [NSPasteboard.PasteboardType] { [idType, .URL, .string] }

    static func dragItem(for item: BrowserBookmarkItem) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id, forType: idType)
        write(item, to: pasteboardItem)
        return pasteboardItem
    }

    static func copy(_ item: BrowserBookmarkItem, to pasteboard: NSPasteboard = .general) {
        let pasteboardItem = NSPasteboardItem()
        write(item, to: pasteboardItem)
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardItem])
    }

    /// A copied bookmark or folder, or any address on the pasteboard.
    static func clipboardItem(from pasteboard: NSPasteboard = .general) -> BrowserBookmarkClipboardItem? {
        if let data = pasteboard.data(forType: treeType),
           let tree = try? JSONDecoder().decode(BrowserBookmarkClipboardItem.self, from: data)
        {
            return tree
        }
        return droppedPage(from: pasteboard).map { .init(title: $0.title, urlString: $0.urlString) }
    }

    static func droppedPage(from pasteboard: NSPasteboard) -> (title: String, urlString: String)? {
        let candidates = [pasteboard.string(forType: .URL), pasteboard.string(forType: .string)]
        guard let urlString = candidates.compactMap(\.self).first(where: isWebAddress) else { return nil }
        return (
            pasteboard.string(forType: urlNameType) ?? "",
            urlString.trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    private static func write(_ item: BrowserBookmarkItem, to pasteboardItem: NSPasteboardItem) {
        if let data = try? JSONEncoder().encode(BrowserBookmarkClipboardItem(item)) {
            pasteboardItem.setData(data, forType: treeType)
        }
        if let urlString = item.urlString {
            pasteboardItem.setString(urlString, forType: .URL)
            pasteboardItem.setString(urlString, forType: .string)
            pasteboardItem.setString(item.displayTitle, forType: urlNameType)
        }
    }

    private static func isWebAddress(_ string: String) -> Bool {
        guard let scheme = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        else { return false }
        return ["http", "https", "file", "openarc"].contains(scheme)
    }
}

// MARK: - BrowserBookmarkEditor

@MainActor enum BrowserBookmarkEditor {
    struct Result {
        let title: String
        let urlString: String?
        let folderID: String?
    }

    /// Asks for a name, an address when `urlString` is set, and a folder. Folders
    /// inside `excludedID` are left out, as a folder can't move into itself.
    static func run(
        title: String,
        name: String,
        urlString: String?,
        folderID: String?,
        tree: [BrowserBookmarkItem],
        excludedID: String? = nil,
    ) -> Result? {
        let nameField = NSTextField(string: name)
        let urlField = NSTextField(string: urlString ?? "")
        let folders = NSPopUpButton(frame: .zero, pullsDown: false)
        let destinations = BrowserBookmarkFolderDestination.destinations(
            in: tree.filter { $0.id != excludedID },
            excluding: excludedID,
        )
        folders.addItem(withTitle: BrowserStrings.bookmarksBarDestination)
        for destination in destinations {
            folders.addItem(withTitle: destination.title)
        }
        if let index = destinations.firstIndex(where: { $0.id == folderID }) {
            folders.selectItem(at: index + 1)
        }
        for field in [nameField, urlField] {
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        var rows: [[NSView]] = [[label(BrowserStrings.bookmarksNameField), nameField]]
        if urlString != nil {
            rows.append([label(BrowserStrings.bookmarksURLField), urlField])
        }
        rows.append([label(BrowserStrings.bookmarksFolderField), folders])
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = grid
        alert.addButton(withTitle: BrowserStrings.bookmarksSave)
        alert.addButton(withTitle: BrowserStrings.bookmarksCancel)
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selected = folders.indexOfSelectedItem
        return Result(
            title: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            urlString: urlString == nil ? nil : normalizedAddress(urlField.stringValue),
            folderID: selected > 0 ? destinations[selected - 1].id : nil,
        )
    }

    /// Typed addresses often lack a scheme.
    nonisolated static func normalizedAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if URL(string: trimmed)?.scheme != nil, !trimmed.contains(" ") { return trimmed }
        let withScheme = "https://\(trimmed)"
        return URL(string: withScheme)?.host == nil ? nil : withScheme
    }
}

// MARK: - BrowserBookmarkInteractions

/// What the bar and its folder panels share: menus, editing, dragging and drops.
@MainActor final class BrowserBookmarkInteractions: NSObject, NSDraggingSource {
    // MARK: Internal

    let model: BrowserChromeModel
    private(set) var panels = [BrowserBookmarkFolderPanel]()
    var cache: BrowserFaviconCache

    private var dragEndHandler: (() -> Void)?
    private var droppedInPanel = false
    private var springTask: Task<Void, Never>?
    private var springFolderID: String?

    // MARK: Private

    private var monitors = [Any]()

    var tree: [BrowserBookmarkItem] { model.bookmarksModel.bookmarkBarItems }

    init(model: BrowserChromeModel, cache: BrowserFaviconCache) {
        self.model = model
        self.cache = cache
        super.init()
    }

    // MARK: Dragging

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        dragEndHandler?()
        dragEndHandler = nil
        cancelSpring()
        if !droppedInPanel {
            dismissPanels()
        }
        droppedInPanel = false
    }

    @discardableResult func beginDrag(of item: BrowserBookmarkItem, from view: BrowserNativePressableView) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        let dragItem = NSDraggingItem(pasteboardWriter: BrowserBookmarkPasteboard.dragItem(for: item))
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(view.bounds, contents: image)
        dragEndHandler = { [weak view] in view?.resetInteraction() }
        let session = view.beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    func dragOperation(for drop: BrowserBookmarkDrop, pasteboard: NSPasteboard) -> NSDragOperation {
        if let id = pasteboard.string(forType: BrowserBookmarkPasteboard.idType) {
            guard let moving = model.bookmarksModel.item(withID: id) else { return [] }
            switch drop {
            case .into(let folderID):
                return moving.contains(id: folderID) ? [] : .move
            case .between(let folderID, _):
                return folderID.map(moving.contains(id:)) == true ? [] : .move
            }
        }
        return BrowserBookmarkPasteboard.droppedPage(from: pasteboard) == nil ? [] : .copy
    }

    @discardableResult func perform(drop: BrowserBookmarkDrop, pasteboard: NSPasteboard, inPanel: Bool) -> Bool {
        droppedInPanel = inPanel
        let target: (folderID: String?, index: Int) =
            switch drop {
            case .between(let folderID, let index):
                (folderID, index)
            case .into(let folderID):
                (folderID, model.bookmarksModel.item(withID: folderID)?.children.count ?? 0)
            }
        if let id = pasteboard.string(forType: BrowserBookmarkPasteboard.idType) {
            return model.moveBookmark(id: id, toFolderID: target.folderID, atIndex: target.index)
        }
        guard let page = BrowserBookmarkPasteboard.droppedPage(from: pasteboard) else { return false }
        return model.insertBookmark(
            title: page.title,
            urlString: page.urlString,
            toFolderID: target.folderID,
            atIndex: target.index,
        )
    }

    /// Holding a drag over a folder opens it, as Chrome does.
    func springLoad(_ item: BrowserBookmarkItem?, opening open: @escaping (BrowserBookmarkItem) -> Void) {
        guard springFolderID != item?.id else { return }
        cancelSpring()
        guard let item else { return }
        springFolderID = item.id
        springTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, self != nil else { return }
            open(item)
        }
    }

    func cancelSpring() {
        springTask?.cancel()
        springTask = nil
        springFolderID = nil
    }

    // MARK: Panels

    /// Opens a folder under a bar item, or beside a row of the panel at `level`.
    func openPanel(
        items: @escaping () -> [BrowserBookmarkItem]?,
        folderID: String?,
        baseIndex: Int,
        anchor: NSView,
        level: Int,
    ) {
        closePanels(from: level)
        guard let window = anchor.window else { return }
        let panel = BrowserBookmarkFolderPanel(
            interactions: self,
            items: items,
            folderID: folderID,
            baseIndex: baseIndex,
            level: level,
        )
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? window.frame
        let size = panel.frame.size
        let origin =
            if level == 0 {
                NSPoint(
                    x: min(frame.minX, visible.maxX - size.width - 8),
                    y: max(frame.minY - size.height - 4, visible.minY + 8),
                )
            } else {
                NSPoint(
                    x: frame.maxX + size.width + 4 > visible.maxX ? frame.minX - size.width - 4 : frame.maxX + 4,
                    y: max(frame.maxY - size.height + 6, visible.minY + 8),
                )
            }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        if panels.isEmpty {
            startDismissMonitors()
        }
        panels.append(panel)
    }

    func closePanels(from level: Int) {
        while panels.count > level, let panel = panels.popLast() {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if panels.isEmpty {
            stopDismissMonitors()
        }
    }

    func dismissPanels() { closePanels(from: 0) }

    func refreshPanels() {
        for panel in panels where !panel.refresh() {
            closePanels(from: panel.stackLevel)
            return
        }
    }

    // MARK: Menus

    func containerMenu(folderID: String?, index: Int? = nil, includesBarActions: Bool = true) -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        addCreationItems(to: menu, folderID: folderID, index: index)
        if includesBarActions {
            addBarItems(to: menu)
        }
        return menu
    }

    func itemMenu(_ item: BrowserBookmarkItem) -> NSMenu {
        let model = model
        let menu = BrowserNativeMenus.menu()
        if item.isFolder {
            let urls = item.flattenedBookmarkURLStrings
            BrowserNativeMenus.add(
                BrowserStrings.bookmarksOpenAllAction(count: urls.count),
                to: menu,
                enabled: !urls.isEmpty,
            ) { [weak self] in
                self?.dismissPanels()
                model.openBookmarks(urls)
            }
        } else if let url = item.urlString {
            for (title, open) in [
                (BrowserStrings.bookmarksOpenInNewTab, { model.openBookmarks([url]) }),
                (BrowserStrings.bookmarksOpenInLittleWindow, { model.openBookmarkInLittleWindow(urlString: url) }),
                (BrowserStrings.bookmarksOpenInSplitView, { model.openBookmarkInSplitView(urlString: url) }),
                (BrowserStrings.bookmarksOpenInIncognito, { model.openBookmarkInIncognito(urlString: url) }),
            ] {
                BrowserNativeMenus.add(title, to: menu) { [weak self] in
                    self?.dismissPanels()
                    open()
                }
            }
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            item.isFolder ? BrowserStrings.bookmarksRenameAction : BrowserStrings.bookmarksEditAction,
            to: menu,
        ) { [weak self] in self?.edit(item) }
        menu.addItem(.separator())
        let place = pasteLocation(after: item)
        BrowserNativeMenus.add(BrowserStrings.bookmarksCut, to: menu) {
            BrowserBookmarkPasteboard.copy(item)
            _ = model.deleteBookmark(id: item.id)
        }
        BrowserNativeMenus.add(BrowserStrings.bookmarksCopy, to: menu) { BrowserBookmarkPasteboard.copy(item) }
        addPasteItem(to: menu, folderID: place.folderID, index: place.index)
        BrowserNativeMenus.add(BrowserStrings.bookmarksDeleteAction, to: menu) { _ = model.deleteBookmark(id: item.id) }
        menu.addItem(.separator())
        addAddItems(to: menu, folderID: place.folderID, index: place.index)
        addBarItems(to: menu)
        return menu
    }

    private func addCreationItems(to menu: NSMenu, folderID: String?, index: Int?) {
        addPasteItem(to: menu, folderID: folderID, index: index)
        menu.addItem(.separator())
        addAddItems(to: menu, folderID: folderID, index: index)
    }

    private func addPasteItem(to menu: NSMenu, folderID: String?, index: Int?) {
        let model = model
        BrowserNativeMenus.add(
            BrowserStrings.bookmarksPaste,
            to: menu,
            enabled: BrowserBookmarkPasteboard.clipboardItem() != nil,
        ) {
            guard let copied = BrowserBookmarkPasteboard.clipboardItem() else { return }
            _ = model.bookmarksModel.insert(copyOf: copied, toFolderID: folderID, atIndex: index)
        }
    }

    private func addAddItems(to menu: NSMenu, folderID: String?, index: Int?) {
        let model = model
        BrowserNativeMenus.add(BrowserStrings.bookmarksAddPageAction, to: menu) { [weak self] in
            guard let self else { return }
            let page = model.pageForNewBookmark
            guard let result = BrowserBookmarkEditor.run(
                title: BrowserStrings.bookmarksAddPageTitle,
                name: page.title,
                urlString: page.urlString,
                folderID: folderID,
                tree: tree,
            ), let urlString = result.urlString else { return }
            _ = model.insertBookmark(
                title: result.title,
                urlString: urlString,
                toFolderID: result.folderID,
                atIndex: result.folderID == folderID ? index : nil,
            )
        }
        BrowserNativeMenus.add(BrowserStrings.bookmarksAddFolderAction, to: menu) { [weak self] in
            guard let self, let result = BrowserBookmarkEditor.run(
                title: BrowserStrings.bookmarksNewFolderPromptTitle,
                name: BrowserStrings.bookmarksUntitledFolder,
                urlString: nil,
                folderID: folderID,
                tree: tree,
            ) else { return }
            _ = model.insertBookmarkFolder(
                title: result.title.isEmpty ? BrowserStrings.bookmarksUntitledFolder : result.title,
                toFolderID: result.folderID,
                atIndex: result.folderID == folderID ? index : nil,
            )
        }
    }

    private func addBarItems(to menu: NSMenu) {
        let model = model
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.bookmarksManageAction, to: menu, action: model.openBookmarksManager)
        BrowserNativeMenus.add(
            BrowserStrings.bookmarksHideBarAction,
            to: menu,
            shortcut: model.shortcutStore.shortcut(for: .toggleBookmarksBar),
        ) { model.userPreferencesStore.bookmarksBarVisible = false }
    }

    /// A folder takes the paste inside; a bookmark gets it right after itself.
    private func pasteLocation(after item: BrowserBookmarkItem) -> (folderID: String?, index: Int?) {
        if item.isFolder {
            return (item.id, nil)
        }
        guard let parent = BrowserBookmarkItem.parentFolderID(of: item.id, in: tree) else { return (nil, nil) }
        let siblings = parent.flatMap { model.bookmarksModel.item(withID: $0)?.children } ?? tree
        return (parent, siblings.firstIndex { $0.id == item.id }.map { $0 + 1 })
    }

    private func edit(_ item: BrowserBookmarkItem) {
        let parent = BrowserBookmarkItem.parentFolderID(of: item.id, in: tree) ?? nil
        guard let result = BrowserBookmarkEditor.run(
            title: item.isFolder ? BrowserStrings.bookmarksRenameFolderTitle : BrowserStrings.bookmarksEditTitle,
            name: item.displayTitle,
            urlString: item.urlString,
            folderID: parent,
            tree: tree,
            excludedID: item.isFolder ? item.id : nil,
        ) else { return }
        if !result.title.isEmpty, result.title != item.displayTitle {
            _ = model.renameBookmark(id: item.id, title: result.title)
        }
        if let urlString = result.urlString, urlString != item.urlString {
            _ = model.updateBookmarkAddress(id: item.id, urlString: urlString)
        }
        if result.folderID != parent {
            _ = model.moveBookmark(id: item.id, toFolderID: result.folderID)
        }
    }

    private func startDismissMonitors() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self, !panels.contains(where: { $0 === event.window }) else { return event }
            dismissPanels()
            return event
        }) {
            monitors.append(local)
        }
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            closePanels(from: panels.count - 1)
            return nil
        }) {
            monitors.append(key)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPanels() }
        }) {
            monitors.append(global)
        }
    }

    private func stopDismissMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
