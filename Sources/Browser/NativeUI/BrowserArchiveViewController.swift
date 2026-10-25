// BrowserArchiveViewController.swift

import AppKit
import Combine

// MARK: - BrowserArchiveViewController

/// A profile-owned recovery window. Every action keeps its stable archive ID;
/// search and page responses may arrive out of order without changing that intent.
@MainActor final class BrowserArchiveViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
NSSearchFieldDelegate {
    // MARK: Internal

    typealias PageLoader = @MainActor (String, BrowserTabArchiveCursor?, Int) async throws -> BrowserTabArchivePage
    typealias AlertPresenter = @MainActor (NSAlert, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void

    // MARK: Private

    private enum Intent {
        case restore(String, String?)
        case remove(String)
        case captureClear
        case clear(BrowserTabArchiveBoundary)
    }

    private struct Failure {
        let message: String
        let intent: Intent?
    }

    let model: BrowserChromeModel
    let searchField = NSSearchField()
    let table = BrowserArchiveTableView()
    let restoreButton = BrowserActionButton(BrowserStrings.archiveRestore, action: {})
    let removeButton = BrowserActionButton(BrowserStrings.archiveRemove, action: {})
    let clearButton = BrowserActionButton(BrowserStrings.archiveClear, action: {})
    let retryButton = BrowserActionButton(BrowserStrings.sessionRecoveryRetry, action: {})
    let newerButton = BrowserActionButton(BrowserStrings.archiveNewer, action: {})
    let olderButton = BrowserActionButton(BrowserStrings.archiveOlder, action: {})
    let statusLabel = BrowserNativeControls.label("", size: 12, color: BrowserChromeColors.secondaryText, wraps: true)
    private(set) var entries = [BrowserTabArchiveEntry]()
    private(set) var selectedArchiveID: String?
    private(set) var isLoading = false
    private(set) var pendingClearBoundary: BrowserTabArchiveBoundary?
    var onRestore: () -> Void = {}

    private let pageLoader: PageLoader
    private let alertPresenter: AlertPresenter?
    private let scroll = NSScrollView()
    private var observation: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var lastArchiveRevision = 0
    private var cursors: [BrowserTabArchiveCursor?] = [nil]
    private var pageIndex = 0
    private var nextCursor: BrowserTabArchiveCursor?
    private var failure: Failure?
    private var isWorking = false
    private var isClosed = false
    private var hasCurrentPage = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var canManage: Bool {
        !isClosed && !isWorking && pendingClearBoundary == nil && model.canBrowseArchive && !model
            .isArchiveOperationInFlight
    }

    private var canAct: Bool { canManage && !isLoading && hasCurrentPage }
    private var selectedEntry: BrowserTabArchiveEntry? { entries.first { $0.id == selectedArchiveID } }

    init(model: BrowserChromeModel, pageLoader: PageLoader? = nil, alertPresenter: AlertPresenter? = nil) {
        self.model = model
        self.pageLoader = pageLoader ?? { query, cursor, limit in
            try await model.loadArchivedTabs(query: query, before: cursor, limit: limit)
        }
        self.alertPresenter = alertPresenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = BrowserNativeSurface()
        root.fillColor = BrowserChromeColors.contentBackground
        root.setAccessibilityIdentifier("browser.archive.window")
        view = root
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 480)
        searchField.placeholderString = BrowserStrings.archiveSearch
        searchField.setAccessibilityLabel(BrowserStrings.archiveSearch)
        searchField.setAccessibilityIdentifier("browser.archive.search")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        table.setAccessibilityIdentifier("browser.archive.list")
        table.setAccessibilityLabel(BrowserStrings.archiveTitle)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 36
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [
            ("title", BrowserStrings.archiveColumnTitle, CGFloat(230)),
            ("url", BrowserStrings.archiveColumnURL, CGFloat(270)),
            ("date", BrowserStrings.archiveColumnDate, CGFloat(170)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.target = self
        table.doubleAction = #selector(restoreSelection)
        table.onRestore = { [weak self] in self?.restoreSelection() }
        table.onRemove = { [weak self] in self?.removeSelection() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        restoreButton.onAction = { [weak self] in self?.restoreSelection() }
        removeButton.onAction = { [weak self] in self?.removeSelection() }
        clearButton.onAction = { [weak self] in self?.requestClear() }
        retryButton.onAction = { [weak self] in self?.retry() }
        newerButton.onAction = { [weak self] in self?.loadNewerPage() }
        olderButton.onAction = { [weak self] in self?.loadOlderPage() }
        for (button, id) in [
            (restoreButton, "restore"), (removeButton, "delete"), (clearButton, "clear"),
            (retryButton, "retry"), (newerButton, "newer"), (olderButton, "older"),
        ] {
            button.setAccessibilityIdentifier("browser.archive.\(id)")
        }
        statusLabel.setAccessibilityIdentifier("browser.archive.status")
        let actions = BrowserNativeControls.stack(
            [restoreButton, removeButton, clearButton, NSView(), newerButton, olderButton],
            orientation: .horizontal, spacing: 8,
        )
        let status = BrowserNativeControls.stack([statusLabel, retryButton], orientation: .horizontal, spacing: 8)
        for subview in [searchField, scroll, status, actions] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            status.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            actions.heightAnchor.constraint(equalToConstant: 32),
        ])
        observation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.modelChanged() }
        lastArchiveRevision = model.archiveRevision
        loadPage()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusSearch()
    }

    override func cancelOperation(_: Any?) { view.window?.performClose(nil) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f"
        {
            focusSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func invalidate() {
        isClosed = true
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        actionTask?.cancel()
        actionTask = nil
        observation = nil
        pendingClearBoundary = nil
        if let sheet = viewIfLoaded?.window?.attachedSheet {
            viewIfLoaded?.window?.endSheet(sheet, returnCode: .cancel)
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { entries.count }

    func tableView(_: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column else { return nil }
        let entry = entries[row]
        let label = BrowserNativeControls.label("", size: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue =
            switch column.identifier.rawValue {
            case "title": title(for: entry)
            case "url": entry.tab.urlString
            default: dateFormatter.string(from: Date(timeIntervalSince1970: entry.archivedAt))
            }
        label.toolTip = label.stringValue
        label.setAccessibilityIdentifier("browser.archive.entry.\(entry.id).\(column.identifier.rawValue)")
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        selectedArchiveID = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil
        updateControls()
    }

    func controlTextDidChange(_: Notification) {
        guard !isClosed else { return }
        cursors = [nil]
        pageIndex = 0
        selectedArchiveID = nil
        failure = nil
        loadPage(debounce: true)
    }

    @objc func restoreSelection() {
        guard canAct, model.canRestoreArchivedTab, let entry = selectedEntry else { return }
        requestRestore(entry)
    }

    func removeSelection() {
        guard canAct, let id = selectedArchiveID else { return }
        run(.remove(id))
    }

    func requestClear() {
        guard canManage else { return }
        run(.captureClear)
    }

    /// Called only after confirmation of the captured insertion high-water mark.
    /// Search changes and entries created while the sheet is open cannot widen it.
    func confirmClear(_ boundary: BrowserTabArchiveBoundary) {
        guard !isClosed, pendingClearBoundary == boundary else { return }
        pendingClearBoundary = nil
        run(.clear(boundary))
    }

    func chooseDestination(_ spaceID: String, entryID: String) {
        guard canManage, model.canRestoreArchivedTab, model.spaces.contains(where: { $0.id == spaceID }) else {
            failure = .init(message: BrowserStrings.archiveDestinationMissing, intent: nil)
            updateControls()
            return
        }
        run(.restore(entryID, spaceID))
    }

    func retry() {
        guard !isClosed, !isWorking else { return }
        if let intent = failure?.intent {
            run(intent)
        } else {
            failure = nil
            loadPage()
        }
    }

    private func isAdmitted(_ intent: Intent) -> Bool {
        guard canManage else { return false }
        if case .restore = intent {
            return model.canRestoreArchivedTab
        }
        return true
    }

    private func title(for entry: BrowserTabArchiveEntry) -> String {
        for value in [entry.tab.userTitleOverride, entry.title] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return entry.tab.urlString
    }

    private func loadPage(debounce: Bool = false) {
        guard !isClosed else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        isLoading = true
        hasCurrentPage = false
        updateControls()
        let query = searchField.stringValue
        let cursor = cursors[pageIndex]
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard !Task.isCancelled, !isClosed, model.canBrowseArchive else {
                    if !isClosed, generation == loadGeneration {
                        finishLoadUnavailable()
                    }
                    return
                }
                let page = try await pageLoader(query, cursor, 50)
                guard !isClosed, !Task.isCancelled, generation == loadGeneration else { return }
                entries = page.entries
                nextCursor = page.nextCursor
                isLoading = false
                hasCurrentPage = true
                let previousSelection = selectedArchiveID
                table.reloadData()
                if let previousSelection, let index = entries.firstIndex(where: { $0.id == previousSelection }) {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                } else {
                    selectedArchiveID = nil
                    table.deselectAll(nil)
                }
                updateControls()
            } catch {
                guard !isClosed, !Task.isCancelled, generation == loadGeneration else { return }
                isLoading = false
                let invalid = error as? BrowserTabArchiveError == .invalidQuery
                failure = .init(
                    message: invalid ? BrowserStrings.archiveSearchInvalid : BrowserStrings.archiveActionFailed,
                    intent: nil,
                )
                updateControls()
            }
        }
    }

    private func finishLoadUnavailable() {
        isLoading = false
        failure = .init(message: BrowserStrings.archiveUnavailable, intent: nil)
        updateControls()
    }

    private func modelChanged() {
        guard !isClosed else { return }
        if lastArchiveRevision != model.archiveRevision {
            lastArchiveRevision = model.archiveRevision
            loadPage()
        }
        updateControls()
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        restoreButton.isEnabled = canAct && model.canRestoreArchivedTab && selectedEntry != nil
        removeButton.isEnabled = canAct && selectedEntry != nil
        clearButton.isEnabled = canManage
        searchField.isEnabled = !isWorking && pendingClearBoundary == nil
        olderButton.isEnabled = !isLoading && !isWorking && pendingClearBoundary == nil && nextCursor != nil
        newerButton.isEnabled = !isLoading && !isWorking && pendingClearBoundary == nil && pageIndex > 0
        retryButton.isHidden = failure == nil
        retryButton.isEnabled = !isLoading && (failure?.intent.map(isAdmitted) ?? canManage)
        statusLabel.stringValue = failure?.message
            ?? (isWorking || isLoading
                ? BrowserStrings.archiveLoading
                : entries.isEmpty
                    ? (searchField.stringValue.isEmpty ? BrowserStrings.archiveEmpty : BrowserStrings.archiveNoResults)
                    : "")
    }

    private func loadOlderPage() {
        guard !isLoading, let nextCursor else { return }
        cursors = Array(cursors.prefix(pageIndex + 1)) + [nextCursor]
        pageIndex += 1
        failure = nil
        loadPage()
    }

    private func loadNewerPage() {
        guard !isLoading, pageIndex > 0 else { return }
        pageIndex -= 1
        failure = nil
        loadPage()
    }

    private func requestRestore(_ entry: BrowserTabArchiveEntry) {
        guard model.spaces.contains(where: { $0.id == entry.tab.spaceID }) else {
            showDestination(entry)
            return
        }
        run(.restore(entry.id, nil))
    }

    private func showDestination(_ entry: BrowserTabArchiveEntry) {
        let spaces = model.spaces
        guard !spaces.isEmpty else {
            failure = .init(message: BrowserStrings.archiveDestinationMissing, intent: nil)
            updateControls()
            return
        }
        let alert = NSAlert()
        alert.messageText = BrowserStrings.archiveDestinationTitle
        alert.informativeText = BrowserStrings.archiveDestinationMessage
        alert.addButton(withTitle: BrowserStrings.archiveRestore)
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        picker.setAccessibilityIdentifier("browser.archive.destination")
        for space in spaces {
            picker.addItem(withTitle: space.title)
            picker.lastItem?.representedObject = space.id
        }
        alert.accessoryView = picker
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let id = picker.selectedItem?.representedObject as? String else { return }
            self?.chooseDestination(id, entryID: entry.id)
        }
    }

    private func run(_ intent: Intent) {
        guard !isClosed, !isWorking else { return }
        guard isAdmitted(intent) else {
            failure = .init(message: BrowserStrings.archiveUnavailable, intent: intent)
            updateControls()
            return
        }
        isWorking = true
        failure = nil
        updateControls()
        actionTask = Task { [weak self] in
            guard let self, !isClosed, !Task.isCancelled else { return }
            switch intent {
            case .restore(let id, let destination):
                if destination == nil, let entry = entries.first(where: { $0.id == id }),
                   !model.spaces.contains(where: { $0.id == entry.tab.spaceID })
                {
                    isWorking = false
                    showDestination(entry)
                    updateControls()
                    return
                }
                let restored = model.restoreArchivedTab(id: id, toSpaceID: destination)
                guard !isClosed else { return }
                finishAction(
                    restored != nil,
                    intent: intent,
                    message: model.archiveError ?? BrowserStrings.archiveRestoreFailed,
                )
                if restored != nil {
                    onRestore()
                }
            case .remove(let id):
                let success = await model.deleteArchivedTab(id: id)
                guard !isClosed else { return }
                finishAction(success, intent: intent)
            case .clear(let boundary):
                let success = await model.clearArchive(through: boundary)
                guard !isClosed else { return }
                finishAction(success, intent: intent)
            case .captureClear:
                do {
                    let boundary = try await model.archiveClearBoundary()
                    guard !isClosed else { return }
                    isWorking = false
                    pendingClearBoundary = boundary
                    let alert = NSAlert()
                    alert.messageText = BrowserStrings.archiveClearConfirm
                    alert.informativeText = BrowserStrings.archiveClearMessage
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: BrowserStrings.archiveClearConfirm)
                    alert.addButton(withTitle: BrowserStrings.cancelAction)
                    present(alert) { [weak self] response in
                        guard let self, !isClosed, pendingClearBoundary == boundary else { return }
                        if response == .alertFirstButtonReturn {
                            confirmClear(boundary)
                        } else {
                            pendingClearBoundary = nil
                            updateControls()
                        }
                    }
                    updateControls()
                } catch {
                    guard !isClosed else { return }
                    finishAction(false, intent: intent)
                }
            }
        }
    }

    private func finishAction(_ success: Bool, intent: Intent, message: String? = nil) {
        isWorking = false
        if success {
            failure = nil
            loadPage()
        } else {
            failure = .init(
                message: message ?? model.archiveError ?? BrowserStrings.archiveActionFailed,
                intent: intent,
            )
            updateControls()
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let alertPresenter {
            alertPresenter(alert, completion)
        } else if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(.cancel)
        }
    }
}

// MARK: - BrowserArchiveTableView

@MainActor final class BrowserArchiveTableView: NSTableView {
    var onRestore: () -> Void = {}
    var onRemove: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36,
             76: onRestore()
        case 51,
             117: onRemove()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - BrowserArchiveWindowController

@MainActor final class BrowserArchiveWindowController: NSWindowController, NSWindowDelegate {
    // MARK: Internal

    let archiveController: BrowserArchiveViewController
    var onClose: () -> Void = {}
    var onRestore: () -> Void = {}

    var model: BrowserChromeModel { archiveController.model }

    init(model: BrowserChromeModel) {
        self.archiveController = BrowserArchiveViewController(model: model)
        let window = NSWindow(contentViewController: archiveController)
        window.title = "\(BrowserStrings.archiveTitle) — \(model.profileDisplayName)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 740, height: 480))
        window.contentMinSize = NSSize(width: 680, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        archiveController.onRestore = { [weak self] in self?.onRestore() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_: Notification) {
        archiveController.invalidate()
        onClose()
    }
}
