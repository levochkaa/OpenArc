// BrowserLibraryNSView.swift

import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - BrowserLibrarySection

enum BrowserLibrarySection: String, CaseIterable {
    case media
    case downloads
    case easels
    case spaces
    case boosts
    case archive

    // MARK: Internal

    var title: String {
        switch self {
        case .media: BrowserStrings.libraryMedia
        case .downloads: BrowserStrings.libraryDownloads
        case .easels: BrowserStrings.libraryEasels
        case .spaces: BrowserStrings.librarySpaces
        case .boosts: BrowserStrings.libraryBoosts
        case .archive: BrowserStrings.libraryArchive
        }
    }

    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .downloads: "arrow.down.circle"
        case .easels: "scribble.variable"
        case .spaces: "square.on.square"
        case .boosts: "paintbrush.pointed"
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

    /// Spaces show only as wide as their cards and the new Space button, after the
    /// column of sections.
    static func spacesWidth(spaceCount: Int) -> CGFloat {
        columnWidth + 20 + CGFloat(spaceCount) * (spaceCardWidth + 20) + 4 + 28 + 28
    }
}

// MARK: - BrowserLibraryNSView

/// Replaces the sidebar with sections of saved things: media, downloads, Spaces
/// and archived tabs, beside the page. Spaces are as wide as their cards.
final class BrowserLibraryNSView: NSView, NSTextFieldDelegate {
    // MARK: Private

    private enum Row {
        case header(String)
        case item(BrowserLibraryRowContent)
        case tile(URL)

        /// What a row shows; a download's file icon follows its name.
        var signature: [AnyHashable?] {
            switch self {
            case .header(let title): ["header", title]
            case .item(let content): [
                    "item",
                    content.identity,
                    content.title,
                    content.detail,
                    content.faviconPageURL,
                    content.faviconImage.map(ObjectIdentifier.init),
                    content.fileIcon != nil,
                    content.progress,
                    content.isOn,
                ]
            case .tile(let url): ["tile", url]
            }
        }
    }

    /// The archive store hands out at most this many entries at a time.
    private static let archivePageSize = 100
    private static let archiveMaximumCount = 500

    // MARK: Internal

    override var isFlipped: Bool { true }

    /// Set while a hidden Library skipped a refresh; it refreshes as it shows again.
    private(set) var hasDeferredRefresh = false
    /// How many times the list's row views were built, for tests.
    private(set) var documentBuildCount = 0
    /// Easel pictures by Easel, edit time and appearance.
    private var easelThumbnails = [String: NSImage?]()

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
    private let scroll = BrowserLibraryScrollView()
    private let document = BrowserLibraryDocument()
    private let spacesScroll = BrowserLibraryScrollView()
    private let spacesDocument = BrowserLibraryDocument()
    private let emptyState = BrowserLibraryEmptyState()
    /// Model changes refresh the view once per run loop pass.
    private lazy var coalescedRefresh = BrowserCoalescedRefresh { [weak self] in self?.refresh() }
    private var shownSection: BrowserLibrarySection?
    private var filter: String?
    private var rows = [Row]() {
        didSet { rowsGeneration &+= 1 }
    }

    private var rowsGeneration = 0
    /// The rows and width the document's views were last built for.
    private var builtDocument: (generation: Int, width: CGFloat)?
    private var rowViews = [NSView]()
    /// Archive favicons decoded at row size, kept while their page icon stays the same.
    private var archiveFavicons = [String: (data: Data, image: NSImage)]()
    private var listScrollObservation: NSObjectProtocol?
    private var spaceCards = [String: BrowserLibrarySpaceCard]()
    private let newSpaceButton = BrowserLibraryNewSpaceButton()
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
        // Rows scrolled under a still pointer take and drop its hover.
        scroll.contentView.postsBoundsChangedNotifications = true
        self.listScrollObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rowViews.forEach { ($0 as? BrowserNativePressableView)?.syncHoverWithPointer() }
            }
        }
        spacesScroll.drawsBackground = false
        spacesScroll.hasHorizontalScroller = true
        spacesScroll.autohidesScrollers = true
        spacesScroll.scrollerStyle = .overlay
        spacesScroll.documentView = spacesDocument
        addSubview(spacesScroll)
        addSubview(emptyState)
        coalescedRefresh.observe([
            model.objectWillChange.eraseToAnyPublisher(),
            model.downloadsModel.objectWillChange.eraseToAnyPublisher(),
            model.userPreferencesStore.objectWillChange.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: BrowserEaselStore.didChangeNotification)
                .map { _ in () }.eraseToAnyPublisher(),
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    isolated deinit {
        if let listScrollObservation {
            NotificationCenter.default.removeObserver(listScrollObservation)
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let sections = model.librarySections
        for (section, button) in sectionButtons {
            button.isHidden = !sections.contains(section)
        }
        let group = CGFloat(sections.count) * BrowserLibraryLayout.sectionStride
        var y = (height - group) / 2
        for section in sections {
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
        let showsSpaces = shownSection == .spaces
        listBackground.fillColor = showsSpaces
            ? BrowserChromeColors.solidBackground
            : NSColor.black.withAlphaComponent(0.15)
        let showsFilter = shownSection == .archive || shownSection == .downloads
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
        guard !isHiddenOrHasHiddenAncestor else { return }
        layoutDocument()
        layoutSpaces()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard hasDeferredRefresh else { return }
        refresh()
    }

    /// The newest archived tabs, read page by page within the store's page size.
    static func loadArchive(
        model: BrowserChromeModel,
        query: String,
        maximumCount: Int = BrowserLibraryNSView.archiveMaximumCount,
    ) async -> [BrowserTabArchiveEntry] {
        var entries = [BrowserTabArchiveEntry]()
        var cursor: BrowserTabArchiveCursor?
        while entries.count < maximumCount, !Task.isCancelled {
            let limit = min(Self.archivePageSize, maximumCount - entries.count)
            guard let page = try? await model.loadArchivedTabs(query: query, before: cursor, limit: limit)
            else { break }
            entries += page.entries
            guard let next = page.nextCursor, !page.entries.isEmpty else { break }
            cursor = next
        }
        return entries
    }

    /// Pictures saved to these folders, newest first, without looking into subfolders.
    static func mediaFiles(in folders: [URL], query: String, limit: Int = 120) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey]
        var seen = Set<String>()
        let media = folders.filter { seen.insert($0.standardizedFileURL.path).inserted }.flatMap { folder in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
            )) ?? []
            return files.compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard let type = values?.contentType, type.conforms(to: .image) else { return nil }
                if !query.isEmpty, !url.lastPathComponent.lowercased().contains(query) { return nil }
                return (url, values?.contentModificationDate ?? .distantPast)
            }
        }
        return media.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// "Today", "Yesterday" or the date, over the rows of that day.
    static func dayHeader(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return BrowserStrings.libraryToday
        }
        if calendar.isDateInYesterday(date) {
            return BrowserStrings.libraryYesterday
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// A finished download's kind as Finder names it and the site it came from,
    /// such as "Disk Image from example.com".
    static func downloadDetail(kind: String?, urlString: String) -> String? {
        let host = URLComponents(string: urlString)?.host.map {
            $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
        }
        guard let kind, !kind.isEmpty else { return host }
        guard let host, !host.isEmpty else { return kind }
        return BrowserStrings.libraryDownloadKindFromHost(kind: kind, host: host)
    }

    /// The archived page's address without `https://` and `www.`, its path and
    /// query kept; other schemes stay whole.
    static func archiveDetail(for urlString: String) -> String {
        var text = urlString
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        }
        if text.hasSuffix("/"), text.dropLast().contains(where: { $0 != "/" }) {
            text.removeLast()
        }
        return text
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

    /// The Space menu, as on its sidebar header; Rename goes back to the sidebar to type.
    private static func spaceMenu(_ space: BrowserChromeModel.Space, model: BrowserChromeModel) -> NSMenu {
        BrowserNativeMenus.space(
            space,
            canDelete: model.spaces.count > 1,
            canResetTabs: model.canResetSpaceTabs(spaceID: space.id),
            onRename: { [weak model] in
                model?.closeLibrary()
                model?.selectSpace(id: space.id)
                model?.sidebarSpaceRenameRequestID &+= 1
            },
            onChangeIcon: { [weak model] in model?.setIcon($0, forSpaceID: space.id) },
            onEditTheme: { [weak model] in model?.onEditSpaceTheme?(space.id) },
            profiles: model.profileDirectories?.profiles() ?? [],
            selectedProfile: model.profileDirectory(forSpaceID: space.id),
            onSetProfile: { [weak model] in model?.requestProfile($0, forSpaceID: space.id) },
            onShare: model.onShareSpace.map { share in { share(space.id) } },
            exportTargets: model.spaces.filter { $0.id != space.id },
            onExport: { [weak model] targetID in
                _ = model?.exportSpace(id: space.id, intoFolderInSpaceID: targetID)
            },
            onResetTabs: { [weak model] in model?.resetSpaceTabs(spaceID: space.id) },
            onDelete: { [weak model] in _ = model?.deleteSpace(id: space.id) },
        )
    }

    /// Whether the Spaces cards can still scroll the way a sideways swipe with this delta
    /// goes; a swipe that has nowhere to scroll them closes the Library instead.
    func canScrollSpaces(byDelta delta: CGFloat) -> Bool {
        guard shownSection == .spaces, !spacesScroll.isHidden else { return false }
        let offset = spacesScroll.contentView.bounds.origin.x
        let maxOffset = max(spacesDocument.frame.width - spacesScroll.contentView.bounds.width, 0)
        return delta < 0 ? offset < maxOffset - 0.5 : offset > 0.5
    }

    func refresh() {
        // Closed, it keeps the section it opens on, so a swipe brings that one in.
        let section = model.librarySection ?? model.lastLibrarySection
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
        // Hidden, it builds no rows: the archive still loads, so it opens filled.
        guard !isHiddenOrHasHiddenAncestor else {
            hasDeferredRefresh = true
            if section == .archive {
                loadArchiveIfNeeded()
            }
            return
        }
        hasDeferredRefresh = false
        switch section {
        case .archive:
            loadArchiveIfNeeded()
            show(archiveRows())
        case .downloads: show(downloadRows())
        case .media: show(mediaRows())
        case .spaces: show([])
        case .boosts: show(boostRows())
        case .easels: show(easelRows())
        }
        updateEmptyState()
        needsLayout = true
    }

    func controlTextDidChange(_: Notification) {
        if shownSection == .archive {
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
            switch shownSection {
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

    private func loadArchiveIfNeeded() {
        let key = "\(query)|\(filter ?? "")|\(model.archiveRevision)"
        guard key != loadedArchiveKey else { return }
        loadedArchiveKey = key
        archiveTask?.cancel()
        let query = query
        archiveTask = Task { [weak self, model] in
            let entries = await Self.loadArchive(model: model, query: query)
            guard let self, !Task.isCancelled else { return }
            archiveEntries = entries
            guard !isHiddenOrHasHiddenAncestor else {
                hasDeferredRefresh = true
                return
            }
            show(archiveRows())
            updateEmptyState()
            needsLayout = true
        }
    }

    /// Takes new rows only when they differ from the shown ones, so opening the Library
    /// or a model change that leaves its contents alone keeps the row views.
    private func show(_ newRows: [Row]) {
        guard newRows.map(\.signature) != rows.map(\.signature) else { return }
        rows = newRows
    }

    private func archiveFavicon(for urlString: String, data: Data?) -> NSImage? {
        guard let data else {
            archiveFavicons[urlString] = nil
            return nil
        }
        if let cached = archiveFavicons[urlString], cached.data == data {
            return cached.image
        }
        guard let image = BrowserImageThumbnailer.image(data: data, maximumPixelSize: 32) else { return nil }
        archiveFavicons[urlString] = (data, image)
        return image
    }

    private func archiveRows() -> [Row] {
        var result = [Row]()
        var lastHeader: String?
        let model = model
        let icons = model.pageIcons(for: archiveEntries.map(\.tab.urlString))
        for entry in archiveEntries {
            if let filter, entry.tab.spaceID != filter { continue }
            let date = Date(timeIntervalSince1970: entry.archivedAt)
            let header = Self.dayHeader(for: date)
            if header != lastHeader {
                result.append(.header(header))
                lastHeader = header
            }
            let urlString = entry.tab.urlString
            let host = URLComponents(string: urlString)?.host.map { $0.replacingOccurrences(of: "www.", with: "") }
            let id = entry.id
            result.append(.item(BrowserLibraryRowContent(
                title: entry.title ?? host ?? urlString,
                detail: Self.archiveDetail(for: urlString),
                faviconPageURL: urlString,
                faviconImage: archiveFavicon(for: urlString, data: icons[urlString]),
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
                identity: id,
            )))
        }
        return result
    }

    private func downloadRows() -> [Row] {
        let downloads = model.downloadsModel
        var result = [Row]()
        var lastHeader: String?
        // A canceled download left nothing behind to list.
        for item in downloads.items where item.state != .canceled {
            let name = item.fileName
            if !query.isEmpty, !name.lowercased().contains(query) { continue }
            if let filter, !Self.matches(fileName: name, kind: filter) { continue }
            let header = Self.dayHeader(for: item.finishedAt ?? item.startedAt)
            if header != lastHeader {
                result.append(.header(header))
                lastHeader = header
            }
            let total = item.totalBytes
            let progress: Double? = item.state == .inProgress && total > 0
                ? Double(item.receivedBytes) / Double(total)
                : nil
            let kind = item.state == .completed
                ? item.fileURL
                    .flatMap { try? $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]) }?
                    .localizedTypeDescription
                : nil
            let detail = item.state == .completed
                ? Self.downloadDetail(kind: kind, urlString: item.urlString) ?? downloads.detailText(for: item)
                : downloads.detailText(for: item)
            result.append(.item(BrowserLibraryRowContent(
                title: name,
                detail: detail,
                faviconPageURL: nil,
                fileIcon: NSWorkspace.shared
                    .icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data),
                progress: progress,
                onOpen: { [weak downloads] in downloads?.open(item) },
                menu: { [weak downloads] in
                    let menu = BrowserNativeMenus.menu()
                    if item.state == .inProgress {
                        BrowserNativeMenus
                            .add(BrowserStrings.downloadsCancelAction, to: menu) { downloads?.cancel(item) }
                    }
                    BrowserNativeMenus.add(BrowserStrings.libraryRevealInFinder, to: menu) { downloads?.reveal(item) }
                    return menu
                },
                identity: item.id,
            )))
        }
        return result
    }

    /// Each Boost with its site and a switch; a click opens the site with its editor.
    private func boostRows() -> [Row] {
        let model = model
        let defaultTitle = BrowserStrings.boostDefaultTitle
        return model.userPreferencesStore.boosts.compactMap { boost -> Row? in
            let host = boost.host
            let title = boost.displayTitle(defaultTitle: defaultTitle)
            if !query.isEmpty, !title.lowercased().contains(query), !host.contains(query) {
                return nil
            }
            let isEnabled = boost.isEnabled
            return .item(BrowserLibraryRowContent(
                title: title,
                detail: isEnabled ? host : "\(host) · \(BrowserStrings.boostStateOff)",
                faviconPageURL: "https://\(host)/",
                fileIcon: nil,
                progress: nil,
                onOpen: { [weak model] in model?.openBoostedSite(host: host) },
                menu: { [weak self, weak model] in
                    let menu = BrowserNativeMenus.menu()
                    BrowserNativeMenus.add(BrowserStrings.boostRenameMenu, to: menu) {
                        guard let self, let model else { return }
                        BrowserBoostDialogs.rename(
                            title: model.boost(forHost: host).title ?? "",
                            in: self.window,
                        ) { model.renameBoost(host: host, title: $0) }
                    }
                    BrowserNativeMenus.add(
                        isEnabled ? BrowserStrings.boostTurnOff : BrowserStrings.boostTurnOn,
                        to: menu,
                    ) { model?.setBoostEnabled(host: host, !isEnabled) }
                    menu.addItem(.separator())
                    BrowserNativeMenus.add(BrowserStrings.boostDeleteMenu, to: menu) {
                        guard let self else { return }
                        BrowserBoostDialogs.confirmDelete(in: self.window) { model?.removeBoost(host: host) }
                    }
                    return menu
                },
                identity: "boost.\(host)",
                isOn: isEnabled,
                onToggle: { [weak model] on in model?.setBoostEnabled(host: host, on) },
            ))
        }
    }

    /// Each Easel with a picture of its top, newest first; a click opens it.
    private func easelRows() -> [Row] {
        let model = model
        let store = model.easelStore
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return store.allDocuments.compactMap { document -> Row? in
            let title = document.title
            if !query.isEmpty, !title.lowercased().contains(query) {
                return nil
            }
            let id = document.id
            let thumbnailKey = "\(id).\(document.modifiedAt.timeIntervalSince1970).\(isDark)"
            let thumbnail = easelThumbnails[thumbnailKey] ?? {
                let image = BrowserEaselRenderer.thumbnail(document, store: store, isDark: isDark)
                easelThumbnails = easelThumbnails.filter { !$0.key.hasPrefix(id + ".") }
                easelThumbnails[thumbnailKey] = image
                return image
            }()
            return .item(BrowserLibraryRowContent(
                title: title,
                detail: BrowserStrings.easelEdited(document.modifiedAt),
                faviconPageURL: nil,
                faviconImage: thumbnail,
                fileIcon: nil,
                progress: nil,
                onOpen: { [weak model] in _ = model?.openEasel(id: id) },
                menu: { [weak self, weak model] in
                    let menu = BrowserNativeMenus.menu()
                    BrowserNativeMenus.add(BrowserStrings.easelOpenMenu, to: menu) { _ = model?.openEasel(id: id) }
                    menu.addItem(.separator())
                    BrowserNativeMenus.add(BrowserStrings.easelDeleteMenu, to: menu) {
                        BrowserEaselDialogs.confirmDelete(in: self?.window) { model?.deleteEasel(id: id) }
                    }
                    return menu
                },
                identity: "easel.\(id).\(thumbnailKey)",
            ))
        }
    }

    /// Pictures and videos in the download folder, newest first.
    private func mediaRows() -> [Row] {
        let preferences = model.userPreferencesStore
        let folders = BrowserLibraryMediaSource.allCases
            .filter { !preferences.hiddenMediaSources.contains($0) }
            .compactMap { $0.folder(downloadDirectoryPath: preferences.downloadDirectoryPath) }
        return Self.mediaFiles(in: folders, query: query).map { .tile($0) }
    }

    private func updateEmptyState() {
        let section = shownSection
        emptyState.isHidden = section == .spaces || !rows.isEmpty
        guard let section else { return }
        let detail =
            switch section {
            case .media: BrowserStrings.libraryEmptyMedia
            case .boosts: BrowserStrings.libraryEmptyBoosts
            case .easels: BrowserStrings.libraryEmptyEasels
            default: BrowserStrings.libraryEmptyDetail
            }
        emptyState.configure(symbol: section.symbol, detail: detail)
    }

    /// One row or tile per entry; rows are rebuilt with the section's contents.
    private func layoutDocument() {
        let width = scroll.contentSize.width
        guard builtDocument?.generation != rowsGeneration || builtDocument?.width != width else { return }
        builtDocument = (rowsGeneration, width)
        documentBuildCount += 1
        for view in rowViews {
            view.removeFromSuperview()
        }
        rowViews.removeAll()
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
        guard shownSection == .spaces else { return }
        let height = spacesScroll.contentSize.height
        let ids = Set(model.spaces.map(\.id))
        for id in Set(spaceCards.keys).subtracting(ids) {
            spaceCards.removeValue(forKey: id)?.removeFromSuperview()
        }
        var x: CGFloat = 20
        let model = model
        let snapshot = model.sidebarSnapshot
        for space in model.spaces {
            let card = spaceCards[space.id] ?? BrowserLibrarySpaceCard()
            if spaceCards[space.id] == nil {
                spaceCards[space.id] = card
                spacesDocument.addSubview(card)
            }
            card.update(
                space: space,
                theme: model.spaceThemesByID[space.id],
                rows: BrowserLibrarySpaceRow.rows(for: space.id, in: snapshot),
                isSelected: space.id == model.selectedSpaceID,
            )
            card.onOpen = { [weak model] in
                model?.selectSpace(id: space.id)
                model?.closeLibrary()
            }
            card.onEditTheme = { [weak model] in model?.onEditSpaceTheme?(space.id) }
            // A card dragged sideways takes the place it is dropped at.
            let restingX = x
            card.onDragChanged = { [weak self, weak card] value in
                guard let self, let card else { return }
                if card !== spacesDocument.subviews.last {
                    spacesDocument.addSubview(card, positioned: .above, relativeTo: nil)
                }
                card.frame.origin.x = restingX + value.translation.width
            }
            card.onDragEnded = { [weak self, weak model] value in
                let step = BrowserLibraryLayout.spaceCardWidth + 20
                let index = Int(((restingX - 20 + value.translation.width) / step).rounded())
                model?.moveSpace(id: space.id, toIndex: index)
                self?.layoutSpaces()
            }
            card.menuProvider = { [weak model] in
                guard let model else { return NSMenu() }
                return Self.spaceMenu(space, model: model)
            }
            card.frame = NSRect(x: x, y: 50, width: BrowserLibraryLayout.spaceCardWidth, height: max(height - 100, 0))
            x += BrowserLibraryLayout.spaceCardWidth + 20
        }
        // A new Space starts from the button after the last one, halfway down.
        if newSpaceButton.superview == nil {
            newSpaceButton.onClick = { [weak model] _ in
                model?.closeLibrary()
                model?.beginCreatingSpace()
            }
            spacesDocument.addSubview(newSpaceButton)
        }
        let buttonSize: CGFloat = 28
        newSpaceButton.frame = NSRect(x: x + 4, y: (height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        x += buttonSize + 28
        spacesDocument.frame = NSRect(x: 0, y: 0, width: max(x, spacesScroll.contentSize.width), height: height)
    }
}

// MARK: - BrowserLibraryDocument

private final class BrowserLibraryDocument: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - BrowserLibraryScrollView

/// Scrolls on the main thread. A responsive scroll view takes a gesture's later events off
/// the main event path, out of reach of the swipe that closes the Library.
private final class BrowserLibraryScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
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
    /// The page's saved icon, in place of the square.
    var faviconImage: NSImage?
    let fileIcon: NSImage?
    let progress: Double?
    let onOpen: () -> Void
    let menu: () -> NSMenu
    /// The archived tab or download the row stands for.
    var identity = ""
    /// A switch at the row's end, shown when set.
    var isOn: Bool?
    var onToggle: ((Bool) -> Void)?
}

// MARK: - BrowserLibraryRow

private final class BrowserLibraryRow: BrowserNativePressableView {
    // MARK: Private

    private let content: BrowserLibraryRowContent
    private let favicon = BrowserFaviconNSView()
    private let pageIcon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let toggle = BrowserActionToggle()

    // MARK: Internal

    init(content: BrowserLibraryRowContent) {
        self.content = content
        super.init(frame: .zero)
        setAccessibilityLabel(content.title)
        onClick = { [content] _ in content.onOpen() }
        menuProvider = { [content] in content.menu() }
        pressedScale = 1
        if let image = content.faviconImage {
            pageIcon.image = image
            pageIcon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(pageIcon)
        } else if let page = content.faviconPageURL {
            // A page without its icon is a plain square, as in the sidebar.
            favicon.fallback = .square
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
        if let isOn = content.isOn {
            toggle.controlSize = .mini
            toggle.state = isOn ? .on : .off
            toggle.setAccessibilityLabel(content.title)
            toggle.setAccessibilityIdentifier("browser.library.row-switch.\(content.identity)")
            toggle.onChange = { [content] on in content.onToggle?(on) }
            addSubview(toggle)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        favicon.frame = NSRect(x: 12, y: 13, width: 16, height: 16)
        pageIcon.frame = favicon.frame
        let trailing: CGFloat = content.isOn == nil ? 8 : 8 + 26 + 8
        if content.isOn != nil {
            toggle.frame = NSRect(x: bounds.width - 8 - 26, y: (bounds.height - 16) / 2, width: 26, height: 16)
        }
        title.frame = NSRect(x: 38, y: 6, width: max(bounds.width - 38 - trailing, 0), height: 16)
        detail.frame = NSRect(x: 38, y: 22, width: max(bounds.width - 38 - trailing, 0), height: 14)
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

/// A Space drawn like its sidebar, on its own theme: its icon and name, then its
/// rows with their icons. A click goes to it.
private final class BrowserLibrarySpaceCard: BrowserNativePressableView {
    // MARK: Private

    private static let rowStep: CGFloat = 31

    override var isFlipped: Bool { true }

    // MARK: Internal

    var onOpen: () -> Void = {}
    var onEditTheme: () -> Void = {}

    private let editButton = BrowserNativeChromeButton(symbol: "pencil", title: "", style: .chrome, action: {})
    private let moreButton = BrowserNativeChromeButton(symbol: "ellipsis", title: "", style: .chrome, action: {})
    private let background = BrowserChromeBackgroundNSView()
    private let icon = NSImageView()
    /// Shows the card moves; the whole card can be dragged.
    private let handle = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var rowViews = [NSView]()
    private var rows = [BrowserLibrarySpaceRow]()

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
        addSubview(icon)
        addSubview(title)
        editButton.setAccessibilityLabel(BrowserStrings.spaceEditThemeAction)
        editButton.toolTip = BrowserStrings.spaceEditThemeAction
        editButton.onRelease = { [weak self] in self?.onEditTheme() }
        moreButton.setAccessibilityLabel(BrowserStrings.libraryMoreActions)
        moreButton.onRelease = { [weak self] in
            guard let self else { return }
            menuProvider?().popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 4), in: moreButton)
        }
        handle.image = NSImage(
            systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
            accessibilityDescription: nil,
        )?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        addSubview(handle)
        addSubview(editButton)
        addSubview(moreButton)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        background.frame = bounds
        icon.frame = NSRect(x: 14, y: 15, width: 16, height: 16)
        editButton.frame = NSRect(x: bounds.width - 34, y: 9, width: 24, height: 24)
        moreButton.frame = NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 24, height: 24)
        handle.frame = NSRect(x: 14, y: bounds.height - 30, width: 16, height: 16)
        let titleX: CGFloat = icon.image == nil ? 14 : 36
        title.frame = NSRect(x: titleX, y: 14, width: max(editButton.frame.minX - 6 - titleX, 0), height: 18)
        var y: CGFloat = 44
        for (view, row) in zip(rowViews, rows) {
            let isDivider = row == .divider
            let height: CGFloat = isDivider ? 1 : 17
            let top = isDivider ? y + 6 : y
            view.frame = NSRect(x: 14, y: top, width: bounds.width - 28, height: height)
            view.isHidden = top + height > bounds.height - 44
            y += isDivider ? 14 : Self.rowStep
        }
    }

    func update(
        space: BrowserChromeModel.Space,
        theme: BrowserSpaceTheme?,
        rows: [BrowserLibrarySpaceRow],
        isSelected: Bool,
    ) {
        background.setTheme(theme, animated: false)
        background.mode = .black
        let palette = theme?.palette
        appearance = palette.flatMap { NSAppearance(named: $0.isLightContent ? .aqua : .darkAqua) }
        title.stringValue = space.title
        title.textColor = BrowserChromeColors.sidebarDimText
        icon.image = BrowserIconImage.image(named: space.systemImageName, pointSize: 13)
        icon.contentTintColor = BrowserChromeColors.sidebarDimText
        handle.contentTintColor = BrowserChromeColors.sidebarDimText
        setAccessibilityLabel(space.title)
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : BrowserChromeColors.sidebarDivider).cgColor
        guard rows != self.rows else { return }
        self.rows = rows
        rowViews.forEach { $0.removeFromSuperview() }
        let textColor = palette?.title.nsColor ?? BrowserChromeColors.sidebarRowText
        rowViews = rows.map { row in
            let view: NSView =
                switch row {
                case .divider:
                    BrowserLibrarySpaceDivider()
                case .tab(let title, let faviconURL, let urlString):
                    BrowserLibrarySpaceRowView(title: title, color: textColor) { favicon in
                        favicon.update(url: faviconURL, pageURLString: urlString)
                    }
                case .folder(let title):
                    BrowserLibrarySpaceRowView(title: title, color: textColor, folder: true)
                }
            addSubview(view)
            return view
        }
        needsLayout = true
    }
}

// MARK: - BrowserLibraryNewSpaceButton

/// A light disc with a dark plus after the last Space; it starts a new one.
private final class BrowserLibraryNewSpaceButton: BrowserNativePressableView {
    // MARK: Private

    private let plus = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        pressedScale = 0.92
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        plus.contentTintColor = .black
        addSubview(plus)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(BrowserStrings.spaceNewAction)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    // MARK: Internal

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        plus.frame = bounds.insetBy(dx: 6, dy: 6)
    }
}

// MARK: - BrowserLibrarySpaceRowView

private final class BrowserLibrarySpaceRowView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    // MARK: Private

    private let favicon = BrowserFaviconNSView()
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(title: String, color: NSColor, folder: Bool = false, configure: (BrowserFaviconNSView) -> Void = { _ in }) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: folder ? .semibold : .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        if folder {
            symbol.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            symbol.contentTintColor = color
            addSubview(symbol)
        } else {
            configure(favicon)
            addSubview(favicon)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        favicon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        symbol.frame = favicon.frame
        label.frame = NSRect(x: 26, y: 0, width: max(bounds.width - 26, 0), height: bounds.height)
    }
}

// MARK: - BrowserLibrarySpaceDivider

/// The line between a Space's pinned rows and its temporary tabs.
private final class BrowserLibrarySpaceDivider: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = BrowserChromeColors.sidebarDivider.cgColor
    }
}

// MARK: - BrowserLibrarySpaceRow

/// One line of a Space's card: what its sidebar shows, pinned rows first.
enum BrowserLibrarySpaceRow: Equatable {
    case tab(title: String, faviconURL: URL?, urlString: String)
    case folder(title: String)
    case divider

    /// Pinned tabs and top-level folders in sidebar order, then the temporary tabs,
    /// with a divider between them when there are both.
    static func rows(for spaceID: String, in snapshot: BrowserSidebarSnapshot) -> [Self] {
        let tree = BrowserSidebarTabTree(snapshot: snapshot)
        let pinned: [Self] = tree.items(in: .pinned(spaceID)).compactMap { item in
            switch item {
            case .tab(let id):
                snapshot.tab(withID: id).map {
                    .tab(title: $0.displayTitle, faviconURL: $0.faviconURL, urlString: $0.urlString)
                }
            case .folder(let id):
                snapshot.pinnedTabFolder(withID: id).map { .folder(title: $0.title) }
            }
        }
        let temporary: [Self] = tree.items(in: .temporary(spaceID)).compactMap { item in
            guard case .tab(let id) = item, let tab = snapshot.tab(withID: id) else { return nil }
            return .tab(title: tab.displayTitle, faviconURL: tab.faviconURL, urlString: tab.urlString)
        }
        return pinned.isEmpty || temporary.isEmpty ? pinned + temporary : pinned + [.divider] + temporary
    }
}
