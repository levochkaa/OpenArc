import AppKit
import Combine

// MARK: - BrowserBookmarkFolderDestination

struct BrowserBookmarkFolderDestination: Equatable {
    let id: String
    let title: String

    static func destinations(in items: [BrowserBookmarkItem]) -> [BrowserBookmarkFolderDestination] {
        items.flatMap { item -> [BrowserBookmarkFolderDestination] in
            guard item.isFolder else { return [] }
            return [.init(id: item.id, title: item.displayTitle)] + destinations(in: item.children).map {
                .init(id: $0.id, title: "\(item.displayTitle) / \($0.title)")
            }
        }
    }
}

// MARK: - BrowserBookmarksBarNSView

final class BrowserBookmarksBarNSView: NSView {
    // MARK: Lifecycle

    init(model: BrowserChromeModel, cache: BrowserFaviconCache = .shared) {
        self.model = model
        self.cache = cache
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
        star.setAccessibilityIdentifier("browser.bookmarks.toggle-current")
        star.onAction = { [weak model] in _ = model?.toggleSelectedTabBookmark() }
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            model.bookmarksModel.objectWillChange.eraseToAnyPublisher(),
            model.shortcutStore.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { menuIconTask?.cancel() }

    // MARK: Internal

    override var isFlipped: Bool { true }

    let star = BrowserNativeChromeButton(
        symbol: "star",
        title: BrowserStrings.bookmarksAddCurrentPage,
        style: .bookmark,
        pressEffect: .compress,
        action: {}
    )
    private(set) var buttons = [String: BrowserNativeBookmarkButton]()

    override func layout() {
        super.layout()
        let size = BrowserChromeLayout.bookmarksBarControlSize
        let padding = BrowserChromeLayout.bookmarksBarHorizontalPadding
        star.frame = NSRect(
            x: max(bounds.width - padding - size, 0),
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        scroll.frame = NSRect(
            x: 0,
            y: 0,
            width: max(star.frame.minX - BrowserChromeLayout.bookmarksBarControlSpacing * 2, 0),
            height: bounds.height
        )
        var x = padding
        for item in items {
            guard let button = buttons[item.id] else { continue }
            let width = button.preferredWidth
            button.frame = NSRect(
                x: x,
                y: (bounds.height - BrowserChromeLayout.bookmarksBarItemHeight) / 2,
                width: width,
                height: BrowserChromeLayout.bookmarksBarItemHeight
            )
            x += width + BrowserChromeLayout.bookmarksBarItemSpacing
        }
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: max(x - BrowserChromeLayout.bookmarksBarItemSpacing + padding, scroll.contentSize.width),
            height: bounds.height
        )
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
            button.onClick = { [weak self, weak button] _ in
                guard let self else { return }
                if item.isFolder, let button {
                    folderMenu(item).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
                } else if let url = item.urlString {
                    model.openBookmark(urlString: url)
                }
            }
            button.menuProvider = { [weak self] in self?.itemMenu(item) ?? NSMenu() }
        }
        let current = model.currentTab
        let enabled = current.map { !$0.urlString.isEmpty } ?? false
        let bookmarked = current.map { model.isBookmarked(urlString: $0.urlString) } ?? false
        star.configureSymbol(
            bookmarked ? "star.fill" : "star",
            title: bookmarked
                ? BrowserStrings.bookmarksRemoveCurrentPage
                : BrowserStrings.bookmarksAddCurrentPage
        )
        star.tooltipShortcut = model.shortcutStore.shortcut(for: .toggleBookmark)
        star.isSelected = bookmarked
        star.isEnabled = enabled
        star.alphaValue = enabled ? 1 : 0.42
        needsLayout = true
    }

    func barMenu() -> NSMenu {
        let model = model
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(BrowserStrings.bookmarksNewFolderAction, to: menu) {
            if let title = BrowserNativeMenus.prompt(
                title: BrowserStrings.bookmarksNewFolderPromptTitle,
                defaultValue: BrowserStrings.bookmarksUntitledFolder
            ) {
                _ = model.createBookmarkFolder(title: title)
            }
        }
        BrowserNativeMenus.add(BrowserStrings.bookmarksManageAction, to: menu, action: model.openBookmarksManager)
        menu.addItem(.separator())
        BrowserNativeMenus.add(
            BrowserStrings.bookmarksHideBarAction,
            to: menu,
            shortcut: model.shortcutStore.shortcut(for: .toggleBookmarksBar)
        ) { model.userPreferencesStore.bookmarksBarVisible = false }
        return menu
    }

    func itemMenu(_ item: BrowserBookmarkItem) -> NSMenu {
        let model = model
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(BrowserStrings.bookmarksRenameAction, to: menu) {
            if let title = BrowserNativeMenus.prompt(
                title: BrowserStrings.bookmarksRenamePromptTitle,
                defaultValue: item.displayTitle
            ) {
                _ = model.renameBookmark(id: item.id, title: title)
            }
        }
        if item.isFolder {
            BrowserNativeMenus
                .add(
                    BrowserStrings.bookmarksOpenAllAction(count: item.flattenedBookmarkURLStrings.count),
                    to: menu,
                    enabled:!item.flattenedBookmarkURLStrings.isEmpty
                ) {
                    model.openBookmarks(item.flattenedBookmarkURLStrings)
                }
        } else {
            BrowserNativeMenus.add(BrowserStrings.bookmarksEditAddressAction, to: menu) {
                guard let url = item.urlString,
                      let updated = BrowserNativeMenus.prompt(
                          title: BrowserStrings.bookmarksEditAddressPromptTitle,
                          defaultValue: url
                      ) else { return }
                _ = model.updateBookmarkAddress(id: item.id, urlString: updated)
            }
            let move = BrowserNativeMenus.submenu(BrowserStrings.bookmarksMoveToAction, in: menu)
            if !items.contains(where: { $0.id == item.id }) {
                BrowserNativeMenus.add(BrowserStrings.bookmarksBarDestination, to: move) { _ = model.moveBookmark(
                    id: item.id,
                    toFolderID: nil
                ) }
            }
            for destination in BrowserBookmarkFolderDestination.destinations(in: items)
                where destination.id != item.id
            {
                BrowserNativeMenus.add(destination.title, to: move) { _ = model.moveBookmark(
                    id: item.id,
                    toFolderID: destination.id
                ) }
            }
            move.addItem(.separator())
            BrowserNativeMenus.add(BrowserStrings.bookmarksNewFolderAction, to: move) {
                if let title = BrowserNativeMenus.prompt(
                    title: BrowserStrings.bookmarksNewFolderPromptTitle,
                    defaultValue: BrowserStrings.bookmarksUntitledFolder
                ) {
                    _ = model.createBookmarkFolderAndMoveBookmark(title: title, bookmarkID: item.id)
                }
            }
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.bookmarksDeleteAction, to: menu) { _ = model.deleteBookmark(id: item.id) }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.bookmarksManageAction, to: menu, action: model.openBookmarksManager)
        return menu
    }

    func folderMenu(_ folder: BrowserBookmarkItem) -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        var icons = [(BrowserBookmarkItem, NSMenuItem)]()
        func append(_ item: BrowserBookmarkItem, to menu: NSMenu) {
            if item.isFolder {
                let submenu = BrowserNativeMenus.submenu(item.displayTitle, in: menu)
                menu.items.last?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                for child in item.children {
                    append(child, to: submenu)
                }
            } else {
                let menuItem = BrowserNativeMenus.add(item.displayTitle, to: menu) { [weak model] in
                    if let url = item.urlString {
                        model?.openBookmark(urlString: url)
                    }
                }
                menuItem.image = menuIcon(for: item)
                icons.append((item, menuItem))
            }
        }
        for item in folder.children {
            append(item, to: menu)
        }
        menuIconTask?.cancel()
        menuIconTask = Task { [weak self, cache] in
            for (item, menuItem) in icons {
                await cache.loadImageIfNeeded(from: item.faviconURL)
                guard !Task.isCancelled else { return }
                menuItem.image = self?.menuIcon(for: item)
            }
        }
        return menu
    }

    // MARK: Private

    private let model: BrowserChromeModel
    private let cache: BrowserFaviconCache
    private let scroll = NSScrollView()
    private let document = BrowserNativeBookmarksDocument()
    private var items = [BrowserBookmarkItem]()
    private var observations = Set<AnyCancellable>()
    private var menuIconTask: Task<Void, Never>?

    private func menuIcon(for item: BrowserBookmarkItem) -> NSImage? {
        if let image = cache.image(for: item.faviconURL) {
            return BrowserImageThumbnailer.resizedImage(
                image,
                fitting: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize
            )
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(.init(
            pointSize: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize,
            weight: .medium
        ))
    }
}

// MARK: - BrowserNativeBookmarkButton

final class BrowserNativeBookmarkButton: BrowserNativePressableView {
    // MARK: Lifecycle

    init(cache: BrowserFaviconCache) {
        self.favicon = BrowserFaviconNSView(cache: cache)
        super.init(frame: .zero)
        cornerRadius = BrowserChromeLayout.bookmarksBarItemCornerRadius
        pressedScale = 1
        for view in [favicon, folder, label] {
            addSubview(view)
        }
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: BrowserChromeLayout.bookmarksBarIconSize,
                weight: .semibold
            ))
        folder.contentTintColor = BrowserChromeColors.secondaryText
        folder.imageScaling = .scaleProportionallyUpOrDown
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    var preferredWidth: CGFloat {
        min(
            BrowserChromeLayout.bookmarksBarItemMaximumWidth,
            ceil(label.intrinsicContentSize.width) + BrowserChromeLayout.bookmarksBarIconSize
                + BrowserChromeLayout.bookmarksBarLabelSpacing + BrowserChromeLayout
                .bookmarksBarItemHorizontalPadding * 2
        )
    }

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
        label.frame = NSRect(
            x: x + size + BrowserChromeLayout.bookmarksBarLabelSpacing,
            y: (bounds.height - 17) / 2,
            width: max(bounds.width - x * 2 - size - BrowserChromeLayout.bookmarksBarLabelSpacing, 0),
            height: 17
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

    // MARK: Private

    private let hoverAnimation = BrowserNativeAnimation()
    private var lastHover = false
    private let favicon: BrowserFaviconNSView
    private let folder = NSImageView()
    private let label = BrowserNativeControls.label(
        "",
        size: 12.5,
        weight: .medium,
        color: BrowserChromeColors.primaryText
    )
}

// MARK: - BrowserNativeBookmarksDocument

private final class BrowserNativeBookmarksDocument: NSView {
    override var isFlipped: Bool { true }

    var menuProvider: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
}
