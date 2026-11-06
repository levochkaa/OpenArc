// BrowserLibraryNSView.swift

import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - BrowserLibrarySection

enum BrowserLibrarySection: String, CaseIterable {
    case media
    case downloads
    case spaces
    case archive

    // MARK: Internal

    var title: String {
        switch self {
        case .media: BrowserStrings.libraryMedia
        case .downloads: BrowserStrings.libraryDownloads
        case .spaces: BrowserStrings.librarySpaces
        case .archive: BrowserStrings.libraryArchive
        }
    }

    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .downloads: "arrow.down.circle"
        case .spaces: "square.on.square"
        case .archive: "archivebox"
        }
    }
}

// MARK: - BrowserLibraryLayout

enum BrowserLibraryLayout {
    static let width: CGFloat = 417
    static let columnWidth: CGFloat = 105
    static let sectionSize = NSSize(width: 97, height: 80)
    static let sectionStride: CGFloat = 100
    static let searchX: CGFloat = 120
    static let searchHeight: CGFloat = 36
    static let searchCornerRadius: CGFloat = 12
    static let filterWidth: CGFloat = 73
    static let spaceCardWidth: CGFloat = 240
    /// The first window control's corner: lower and further in than on the sidebar.
    static let windowControlsOrigin = CGPoint(x: 16, y: 21)
}

// MARK: - BrowserLibraryNSView

/// Replaces the sidebar with sections of saved things: media, downloads, Spaces
/// and archived tabs. Spaces take the whole window, the others sit beside the page.
final class BrowserLibraryNSView: NSView, NSTextFieldDelegate {
    // MARK: Private

    private enum Row {
        case header(String)
        case item(BrowserLibraryRowContent)
        case tile(URL)
    }

    // MARK: Internal

    override var isFlipped: Bool { true }

    private let model: BrowserChromeModel
    private let listBackground = BrowserNativeSurface()
    private var sectionButtons = [BrowserLibrarySection: BrowserLibrarySectionButton]()
    private let windowControls = BrowserWindowControlsHostView()
    private let backButton = BrowserNativeChromeButton(
        symbol: "arrow.left",
        title: BrowserStrings.libraryBack,
        style: .sidebarNavigation,
        pressEffect: .left,
        action: {},
    )
    private let searchPill = BrowserNativeSurface()
    private let searchIcon = NSImageView()
    private let searchField = NSTextField()
    private let filterPill = BrowserNativeSurface()
    private let filterButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let scroll = NSScrollView()
    private let document = BrowserLibraryDocument()
    private let spacesScroll = NSScrollView()
    private let spacesDocument = BrowserLibraryDocument()
    private let emptyState = BrowserLibraryEmptyState()
    private var observations = Set<AnyCancellable>()
    private var shownSection: BrowserLibrarySection?
    private var filter: String?
    private var rows = [Row]()
    private var rowViews = [NSView]()
    private var spaceCards = [String: BrowserLibrarySpaceCard]()
    private var archiveEntries = [BrowserTabArchiveEntry]()
    private var loadedArchiveKey: String?
    private var archiveTask: Task<Void, Never>?

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    init(model: BrowserChromeModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.library")
        addSubview(listBackground)
        listBackground.strokeWidth = 0
        listBackground.fillColor = NSColor.black.withAlphaComponent(0.15)
        for section in BrowserLibrarySection.allCases {
            let button = BrowserLibrarySectionButton(section: section)
            button.onClick = { [weak model] _ in model?.librarySection = section }
            sectionButtons[section] = button
            addSubview(button)
        }
        windowControls.managesSystemButtons = false
        windowControls.showsInSidebar = true
        addSubview(windowControls)
        backButton.onAction = { [weak model] in model?.closeLibrary() }
        backButton.setAccessibilityIdentifier("browser.library.back")
        addSubview(backButton)
        for pill in [searchPill, filterPill] {
            pill.strokeWidth = 0
            pill.cornerRadius = BrowserLibraryLayout.searchCornerRadius
            pill.fillColor = BrowserChromeColors.currentURLRow
            addSubview(pill)
        }
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        searchIcon.contentTintColor = BrowserChromeColors.currentURLText
        searchPill.addSubview(searchIcon)
        searchField.font = .systemFont(ofSize: 14)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.textColor = BrowserChromeColors.primaryText
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.setAccessibilityIdentifier("browser.library.search")
        searchPill.addSubview(searchField)
        filterPill.addSubview(filterButton)
        filterButton.isBordered = false
        (filterButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        (filterButton.cell as? NSPopUpButtonCell)?.imagePosition = .imageLeading
        filterButton.alignment = .center
        filterButton.contentTintColor = BrowserChromeColors.currentURLText
        filterButton.font = .systemFont(ofSize: 13, weight: .medium)
        filterButton.setAccessibilityIdentifier("browser.library.filter")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        addSubview(scroll)
        spacesScroll.drawsBackground = false
        spacesScroll.hasHorizontalScroller = true
        spacesScroll.autohidesScrollers = true
        spacesScroll.scrollerStyle = .overlay
        spacesScroll.documentView = spacesDocument
        addSubview(spacesScroll)
        addSubview(emptyState)
        for publisher in [
            model.objectWillChange.eraseToAnyPublisher(),
            model.downloadsModel.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &observations)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = bounds.height
        let group = CGFloat(BrowserLibrarySection.allCases.count) * BrowserLibraryLayout.sectionStride
        var y = (height - group) / 2
        for section in BrowserLibrarySection.allCases {
            sectionButtons[section]?.frame = NSRect(
                x: 4,
                y: y,
                width: BrowserLibraryLayout.sectionSize.width,
                height: BrowserLibraryLayout.sectionSize.height,
            )
            y += BrowserLibraryLayout.sectionStride
        }
        backButton.frame = NSRect(x: 8, y: height - 40, width: 32, height: 32)
        let controlsWidth = windowControls.intrinsicContentSize.width
        windowControls.frame = NSRect(
            origin: BrowserLibraryLayout.windowControlsOrigin,
            size: NSSize(width: controlsWidth, height: BrowserWindowControlsLayout.controlsHeight),
        )
        let listX = BrowserLibraryLayout.columnWidth
        listBackground.frame = NSRect(x: listX, y: 0, width: max(bounds.width - listX, 0), height: height)
        let showsSpaces = model.librarySection == .spaces
        listBackground.fillColor = showsSpaces
            ? BrowserChromeColors.solidBackground
            : NSColor.black.withAlphaComponent(0.15)
        let showsFilter = model.librarySection == .archive || model.librarySection == .downloads
        let searchX = BrowserLibraryLayout.searchX
        let trailing = BrowserLibraryLayout.width - 8
        let searchWidth = trailing - searchX - (showsFilter ? BrowserLibraryLayout.filterWidth + 3 : 0)
        searchPill.frame = NSRect(x: searchX, y: 10, width: searchWidth, height: BrowserLibraryLayout.searchHeight)
        searchIcon.frame = NSRect(x: 14, y: (BrowserLibraryLayout.searchHeight - 15) / 2, width: 15, height: 15)
        searchField.frame = NSRect(
            x: 44,
            y: (BrowserLibraryLayout.searchHeight - 18) / 2,
            width: max(searchWidth - 44 - 10, 0),
            height: 18,
        )
        filterPill.frame = NSRect(
            x: trailing - BrowserLibraryLayout.filterWidth,
            y: 10,
            width: BrowserLibraryLayout.filterWidth,
            height: BrowserLibraryLayout.searchHeight,
        )
        filterButton.frame = filterPill.bounds
        scroll.frame = NSRect(x: listX, y: 52, width: BrowserLibraryLayout.width - listX, height: max(height - 52, 0))
        spacesScroll.frame = NSRect(x: listX, y: 0, width: max(bounds.width - listX, 0), height: height)
        emptyState.frame = NSRect(x: listX, y: 0, width: BrowserLibraryLayout.width - listX, height: height)
        searchPill.isHidden = showsSpaces
        filterPill.isHidden = !showsFilter
        scroll.isHidden = showsSpaces
        spacesScroll.isHidden = !showsSpaces
        layoutDocument()
        layoutSpaces()
    }

    private static func matches(fileName: String, kind: String) -> Bool {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
        return switch kind {
        case "image": type?.conforms(to: .image) == true
        case "document": type?.conforms(to: .pdf) == true || type?.conforms(to: .text) == true
            || type?.conforms(to: .presentation) == true || type?.conforms(to: .spreadsheet) == true
        case "archive": type?.conforms(to: .archive) == true
        default: true
        }
    }

    func refresh() {
        guard let section = model.librarySection else { return }
        for (candidate, button) in sectionButtons {
            button.isSelected = candidate == section
        }
        if section != shownSection {
            shownSection = section
            searchField.stringValue = ""
            searchField.placeholderString = BrowserStrings.librarySearch(section.title)
            // VoiceOver names the field; the placeholder goes once text is typed.
            searchField.setAccessibilityLabel(BrowserStrings.librarySearch(section.title))
            filter = nil
            reloadFilterMenu()
        }
        switch section {
        case .archive: reloadArchiveIfNeeded()
        case .downloads: rows = downloadRows()
        case .media: rows = mediaRows()
        case .spaces: rows = []
        }
        updateEmptyState()
        needsLayout = true
    }

    func controlTextDidChange(_: Notification) {
        if model.librarySection == .archive {
            loadedArchiveKey = nil
        }
        refresh()
    }

    private func reloadFilterMenu() {
        filterButton.removeAllItems()
        filterButton.addItem(withTitle: BrowserStrings.libraryFilter)
        filterButton.menu?.items.first?.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: nil,
        )
        let options: [(title: String, value: String?)] =
            switch model.librarySection {
            case .archive:
                [(BrowserStrings.libraryFilterAll, nil)] + model.spaces.map { ($0.title, $0.id) }
            case .downloads:
                [
                    (BrowserStrings.libraryFilterAll, nil),
                    (BrowserStrings.libraryFilterImages, "image"),
                    (BrowserStrings.libraryFilterDocuments, "document"),
                    (BrowserStrings.libraryFilterArchives, "archive"),
                ]
            default: []
            }
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(chooseFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.value
            filterButton.menu?.addItem(item)
        }
    }

    @objc private func chooseFilter(_ sender: NSMenuItem) {
        filter = sender.representedObject as? String
        loadedArchiveKey = nil
        refresh()
    }

    private func reloadArchiveIfNeeded() {
        let key = "\(query)|\(filter ?? "")|\(model.archiveRevision)"
        guard key != loadedArchiveKey else {
            rows = archiveRows()
            return
        }
        loadedArchiveKey = key
        archiveTask?.cancel()
        let query = query
        archiveTask = Task { [weak self, model] in
            let page = try? await model.loadArchivedTabs(query: query, before: nil, limit: 200)
            guard let self, !Task.isCancelled else { return }
            archiveEntries = page?.entries ?? []
            rows = archiveRows()
            updateEmptyState()
            needsLayout = true
        }
    }

    private func archiveRows() -> [Row] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var result = [Row]()
        var lastHeader: String?
        let model = model
        for entry in archiveEntries {
            if let filter, entry.tab.spaceID != filter { continue }
            let date = Date(timeIntervalSince1970: entry.archivedAt)
            let header: String =
                if calendar.isDateInToday(date) {
                    BrowserStrings.libraryToday
                } else if calendar.isDateInYesterday(date) {
                    BrowserStrings.libraryYesterday
                } else {
                    formatter.string(from: date)
                }
            if header != lastHeader {
                result.append(.header(header))
                lastHeader = header
            }
            let urlString = entry.tab.urlString
            let host = URLComponents(string: urlString)?.host.map { $0.replacingOccurrences(of: "www.", with: "") }
            let id = entry.id
            result.append(.item(BrowserLibraryRowContent(
                title: entry.title ?? host ?? urlString,
                detail: host ?? urlString,
                faviconPageURL: urlString,
                fileIcon: nil,
                progress: nil,
                onOpen: { [weak model] in
                    _ = model?.restoreArchivedTab(id: id)
                    model?.closeLibrary()
                },
                menu: { [weak model] in
                    let menu = BrowserNativeMenus.menu()
                    BrowserNativeMenus.add(BrowserStrings.archiveRestore, to: menu) {
                        _ = model?.restoreArchivedTab(id: id)
                    }
                    BrowserNativeMenus.add(BrowserStrings.archiveRemove, to: menu) {
                        Task { _ = await model?.deleteArchivedTab(id: id) }
                    }
                    return menu
                },
            )))
        }
        return result
    }

    private func downloadRows() -> [Row] {
        let downloads = model.downloadsModel
        return downloads.items.compactMap { item -> Row? in
            let name = item.fileName
            if !query.isEmpty, !name.lowercased().contains(query) { return nil }
            if let filter, !Self.matches(fileName: name, kind: filter) { return nil }
            let total = item.totalBytes
            let progress: Double? = item.state == .inProgress && total > 0
                ? Double(item.receivedBytes) / Double(total)
                : nil
            return .item(BrowserLibraryRowContent(
                title: name,
                detail: downloads.detailText(for: item),
                faviconPageURL: nil,
                fileIcon: NSWorkspace.shared
                    .icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data),
                progress: progress,
                onOpen: { [weak downloads] in downloads?.open(item) },
                menu: { [weak downloads] in
                    let menu = BrowserNativeMenus.menu()
                    BrowserNativeMenus.add(BrowserStrings.libraryRevealInFinder, to: menu) { downloads?.reveal(item) }
                    return menu
                },
            ))
        }
    }

    /// Pictures and videos in the download folder, newest first.
    private func mediaRows() -> [Row] {
        let directory = BrowserDownloadLocation.directory(
            customPath: model.userPreferencesStore.downloadDirectoryPath,
        )
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        )) ?? []
        let media = files.compactMap { url -> (URL, Date)? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let type = values?.contentType, type.conforms(to: .image) else { return nil }
            if !query.isEmpty, !url.lastPathComponent.lowercased().contains(query) { return nil }
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        return media.sorted { $0.1 > $1.1 }.prefix(120).map { .tile($0.0) }
    }

    private func updateEmptyState() {
        let section = model.librarySection
        emptyState.isHidden = section == .spaces || !rows.isEmpty
        guard let section else { return }
        emptyState.configure(
            symbol: section.symbol,
            detail: section == .media ? BrowserStrings.libraryEmptyMedia : BrowserStrings.libraryEmptyDetail,
        )
    }

    /// One row or tile per entry; rows are rebuilt with the section's contents.
    private func layoutDocument() {
        for view in rowViews {
            view.removeFromSuperview()
        }
        rowViews.removeAll()
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        var tileColumn = 0
        let tileSize = (width - 24) / 2
        for row in rows {
            switch row {
            case .header(let title):
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = BrowserChromeColors.sidebarDimText
                label.frame = NSRect(x: 12, y: y + 10, width: width - 24, height: 14)
                document.addSubview(label)
                rowViews.append(label)
                y += 30
            case .item(let content):
                let view = BrowserLibraryRow(content: content)
                view.frame = NSRect(x: 4, y: y, width: width - 8, height: 42)
                document.addSubview(view)
                rowViews.append(view)
                y += 42
            case .tile(let url):
                let view = BrowserLibraryMediaTile(url: url)
                let x = 8 + CGFloat(tileColumn) * (tileSize + 8)
                view.frame = NSRect(x: x, y: y, width: tileSize, height: tileSize)
                document.addSubview(view)
                rowViews.append(view)
                tileColumn += 1
                if tileColumn == 2 {
                    tileColumn = 0
                    y += tileSize + 8
                }
            }
        }
        if tileColumn != 0 { y += tileSize + 8 }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 12, scroll.contentSize.height))
    }

    /// A card per Space, in dock order, each looking like its sidebar.
    private func layoutSpaces() {
        guard model.librarySection == .spaces else { return }
        let height = spacesScroll.contentSize.height
        let ids = Set(model.spaces.map(\.id))
        for id in Set(spaceCards.keys).subtracting(ids) {
            spaceCards.removeValue(forKey: id)?.removeFromSuperview()
        }
        var x: CGFloat = 20
        let model = model
        for space in model.spaces {
            let card = spaceCards[space.id] ?? BrowserLibrarySpaceCard()
            if spaceCards[space.id] == nil {
                spaceCards[space.id] = card
                spacesDocument.addSubview(card)
            }
            card.update(
                space: space,
                theme: model.spaceThemesByID[space.id],
                tabs: model.tabs.filter { $0.spaceID == space.id && $0.placement != .app }.map(\.displayTitle),
                isSelected: space.id == model.selectedSpaceID,
            )
            card.onOpen = { [weak model] in
                model?.selectSpace(id: space.id)
                model?.closeLibrary()
            }
            card.frame = NSRect(x: x, y: 50, width: BrowserLibraryLayout.spaceCardWidth, height: max(height - 100, 0))
            x += BrowserLibraryLayout.spaceCardWidth + 20
        }
        spacesDocument.frame = NSRect(x: 0, y: 0, width: max(x, spacesScroll.contentSize.width), height: height)
    }
}

// MARK: - BrowserLibraryDocument

private final class BrowserLibraryDocument: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserLibrarySectionButton

/// A column button: an icon over a title, lit when its section shows.
private final class BrowserLibrarySectionButton: BrowserNativePressableView {
    // MARK: Internal

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: Private

    private let section: BrowserLibrarySection

    init(section: BrowserLibrarySection) {
        self.section = section
        super.init(frame: .zero)
        setAccessibilityLabel(section.title)
        setAccessibilityIdentifier("browser.library.section.\(section.rawValue)")
        cornerRadius = 12
        strokeWidth = 0
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected || isHovered {
            (isSelected ? BrowserChromeColors.rowSelected : BrowserChromeColors.rowHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
        let tint = isSelected ? BrowserChromeColors.sidebarRowText : BrowserChromeColors.sidebarDimText
        if let image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(
                in: NSRect(
                    x: bounds.midX - image.size.width / 2,
                    y: 20,
                    width: image.size.width,
                    height: image.size.height,
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil,
            )
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: tint,
        ]
        let size = (section.title as NSString).size(withAttributes: attributes)
        (section.title as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: 48),
            withAttributes: attributes,
        )
    }
}

// MARK: - BrowserLibraryRowContent

struct BrowserLibraryRowContent {
    let title: String
    let detail: String
    let faviconPageURL: String?
    let fileIcon: NSImage?
    let progress: Double?
    let onOpen: () -> Void
    let menu: () -> NSMenu
}

// MARK: - BrowserLibraryRow

private final class BrowserLibraryRow: BrowserNativePressableView {
    // MARK: Private

    private let content: BrowserLibraryRowContent
    private let favicon = BrowserFaviconNSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    // MARK: Internal

    init(content: BrowserLibraryRowContent) {
        self.content = content
        super.init(frame: .zero)
        setAccessibilityLabel(content.title)
        onClick = { [content] _ in content.onOpen() }
        menuProvider = { [content] in content.menu() }
        pressedScale = 1
        if let page = content.faviconPageURL {
            favicon.update(url: nil, pageURLString: page)
            addSubview(favicon)
        } else if let icon = content.fileIcon {
            let image = NSImageView(image: icon)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.frame = NSRect(x: 10, y: 11, width: 20, height: 20)
            addSubview(image)
        }
        title.stringValue = content.title
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = BrowserChromeColors.sidebarRowText
        title.lineBreakMode = .byTruncatingTail
        detail.stringValue = content.detail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = BrowserChromeColors.sidebarDimText
        detail.lineBreakMode = .byTruncatingTail
        addSubview(title)
        addSubview(detail)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        favicon.frame = NSRect(x: 12, y: 13, width: 16, height: 16)
        title.frame = NSRect(x: 38, y: 6, width: max(bounds.width - 46, 0), height: 16)
        detail.frame = NSRect(x: 38, y: 22, width: max(bounds.width - 46, 0), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            BrowserChromeColors.rowHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        if let progress = content.progress {
            BrowserChromeColors.rowHover.setFill()
            NSRect(x: 38, y: bounds.height - 4, width: bounds.width - 46, height: 2).fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: 38, y: bounds.height - 4, width: (bounds.width - 46) * progress, height: 2).fill()
        }
    }
}

// MARK: - BrowserLibraryMediaTile

/// A picture from the download folder; a click opens it.
private final class BrowserLibraryMediaTile: BrowserNativePressableView {
    private let url: URL
    private let image = NSImageView()

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = BrowserChromeColors.rowHover.cgColor
        setAccessibilityLabel(url.lastPathComponent)
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        onClick = { _ in NSWorkspace.shared.open(url) }
        menuProvider = {
            let menu = BrowserNativeMenus.menu()
            BrowserNativeMenus.add(BrowserStrings.libraryRevealInFinder, to: menu) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return menu
        }
        Task.detached { [weak self] in
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            let thumbnail = data.flatMap { BrowserImageThumbnailer.image(data: $0, maximumPixelSize: 400) }
            await MainActor.run { self?.image.image = thumbnail }
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        image.frame = bounds
    }
}

// MARK: - BrowserLibraryEmptyState

private final class BrowserLibraryEmptyState: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    // MARK: Private

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: BrowserStrings.libraryEmptyTitle)
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = BrowserChromeColors.sidebarRowText
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = BrowserChromeColors.sidebarDimText
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        for view in [icon, title, detail] {
            addSubview(view)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        icon.frame = NSRect(x: bounds.midX - 24, y: midY - 76, width: 48, height: 48)
        title.frame = NSRect(x: 12, y: midY - 18, width: bounds.width - 24, height: 20)
        detail.frame = NSRect(x: 24, y: midY + 6, width: bounds.width - 48, height: 48)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    func configure(symbol: String, detail text: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 36, weight: .light))
        icon.contentTintColor = BrowserChromeColors.sidebarDimText
        detail.stringValue = text
    }
}

// MARK: - BrowserLibrarySpaceCard

/// A Space drawn like its sidebar, on its own theme. A click goes to it.
private final class BrowserLibrarySpaceCard: BrowserNativePressableView {
    override var isFlipped: Bool { true }

    // MARK: Internal

    var onOpen: () -> Void = {}

    // MARK: Private

    private let background = BrowserChromeBackgroundNSView()
    private let title = NSTextField(labelWithString: "")
    private var tabLabels = [NSTextField]()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        pressedScale = 0.985
        onClick = { [weak self] _ in self?.onOpen() }
        addSubview(background)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        title.frame = NSRect(x: 14, y: 14, width: bounds.width - 28, height: 18)
        var y: CGFloat = 44
        for label in tabLabels {
            label.frame = NSRect(x: 14, y: y, width: bounds.width - 28, height: 17)
            label.isHidden = y + 17 > bounds.height - 12
            y += 31
        }
    }

    func update(space: BrowserChromeModel.Space, theme: BrowserSpaceTheme?, tabs: [String], isSelected: Bool) {
        background.setTheme(theme, animated: false)
        background.mode = .black
        let palette = theme?.palette
        appearance = palette.flatMap { NSAppearance(named: $0.isLightContent ? .aqua : .darkAqua) }
        title.stringValue = space.title
        title.textColor = BrowserChromeColors.sidebarDimText
        setAccessibilityLabel(space.title)
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : BrowserChromeColors.sidebarDivider).cgColor
        for label in tabLabels.dropFirst(tabs.count) {
            label.removeFromSuperview()
        }
        tabLabels = Array(tabLabels.prefix(tabs.count))
        while tabLabels.count < tabs.count {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 14)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            tabLabels.append(label)
        }
        for (label, tab) in zip(tabLabels, tabs) {
            label.stringValue = tab
            label.textColor = palette?.title.nsColor ?? BrowserChromeColors.sidebarRowText
        }
        needsLayout = true
    }
}
