// BrowserMobileArchiveViewController.swift

import UIKit

/// Bounded pages of profile-local recovery records. The document owns restore
/// identity, persistence, and publication to all windows.
final class BrowserMobileArchiveViewController: UITableViewController, UISearchResultsUpdating,
    UISearchBarDelegate, UISearchControllerDelegate
{
    // MARK: Private

    private enum Removal {
        case entry(String)
        case clear(BrowserTabArchiveBoundary)
    }

    private enum ArchivalChoice {
        case off
        case interval(BrowserTemporaryTabLifetime)

        // MARK: Internal

        var lifetime: BrowserTemporaryTabLifetime? {
            switch self {
            case .off: nil
            case .interval(let value): value
            }
        }
    }

    // MARK: Internal

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelOrClose))]
    }

    let workspace: BrowserMobileWorkspace
    var didRestore: (() -> Void)?
    private(set) var pendingClearBoundary: BrowserTabArchiveBoundary?

    private let searchLoader: @MainActor (String, BrowserTabArchiveCursor?, Int) async throws -> BrowserTabArchivePage
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var query = ""
    private var pendingSearchAction: (() -> Void)?
    private var isClosing = false
    private var isLoading = false
    private var isChangingArchive = false
    private var isCapturingBoundary = false
    private var boundaryLoadFailed = false
    private var isQueryInvalid = false
    private var failedRemoval: Removal?
    private var actionError: String?
    private var entries = [BrowserTabArchiveEntry]()
    private var cursors: [BrowserTabArchiveCursor?] = [nil]
    private var nextCursor: BrowserTabArchiveCursor?
    private var lastRevision: Int?
    private var loadError: String?
    private var interactionError: String?
    private var newerButton = UIBarButtonItem()
    private var olderButton = UIBarButtonItem()
    private var clearButton = UIBarButtonItem()
    private var timingButton = UIBarButtonItem()
    private var failedAutomaticArchival: ArchivalChoice?
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let statusStack = UIStackView()
    private var isRetrying = false

    private var mayManage: Bool {
        workspace.canManageArchive && !isChangingArchive && !isCapturingBoundary && !isRetrying && !isClosing
    }

    private var mayRestore: Bool { mayManage && !isLoading && loadError == nil && failedRemoval == nil }

    init(
        workspace: BrowserMobileWorkspace,
        searchLoader: (@MainActor (String, BrowserTabArchiveCursor?, Int) async throws -> BrowserTabArchivePage)? = nil,
    ) {
        self.workspace = workspace
        self.searchLoader = searchLoader ?? { query, cursor, limit in
            try await workspace.searchArchivePage(query: query, before: cursor, limit: limit)
        }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Archive", table: "Mobile")
        tableView.accessibilityIdentifier = "browser.archive.list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Archive")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        done.accessibilityIdentifier = "browser.archive.done"
        navigationItem.rightBarButtonItem = done
        timingButton = UIBarButtonItem(
            title: String(localized: "Auto-Archive", table: "Mobile"),
            menu: UIMenu(children: []),
        )
        timingButton.accessibilityIdentifier = "browser.archive.timing"
        navigationItem.leftBarButtonItem = timingButton
        newerButton = UIBarButtonItem(
            title: String(localized: "Newer", table: "Mobile"), style: .plain,
            target: self, action: #selector(showNewer),
        )
        olderButton = UIBarButtonItem(
            title: String(localized: "Older", table: "Mobile"), style: .plain,
            target: self, action: #selector(showOlder),
        )
        newerButton.accessibilityIdentifier = "browser.archive.newer"
        olderButton.accessibilityIdentifier = "browser.archive.older"
        clearButton = UIBarButtonItem(
            image: UIImage(systemName: "trash"), style: .plain,
            target: self, action: #selector(requestClear),
        )
        clearButton.title = String(localized: "Clear Archive", table: "Mobile")
        clearButton.tintColor = .systemRed
        clearButton.accessibilityIdentifier = "browser.archive.clear"
        toolbarItems = [
            newerButton,
            UIBarButtonItem(systemItem: .flexibleSpace),
            clearButton,
            UIBarButtonItem(systemItem: .flexibleSpace),
            olderButton,
        ]
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.searchBar.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search Archive", table: "Mobile")
        searchController.searchBar.searchTextField.accessibilityIdentifier = "browser.archive.search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        errorLabel.font = .preferredFont(forTextStyle: .subheadline)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .secondaryLabel
        retryButton.setTitle(String(localized: "Retry", table: "Mobile"), for: .normal)
        retryButton.accessibilityIdentifier = "browser.archive.retry"
        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        statusStack.axis = .vertical
        statusStack.spacing = 8
        statusStack.isLayoutMarginsRelativeArrangement = true
        statusStack.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
        statusStack.addArrangedSubview(errorLabel)
        statusStack.addArrangedSubview(retryButton)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeStatusHeader()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            isClosing = true
            searchTask?.cancel()
            loadGeneration &+= 1
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { entries.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Archive", for: indexPath)
        let entry = entries[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.tab.userTitleOverride ?? entry.title ?? entry.tab.urlString
        let date = Date(timeIntervalSince1970: entry.archivedAt).formatted(date: .abbreviated, time: .shortened)
        content.secondaryText = entry.tab.urlString + "\n" + date
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 3
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "browser.archive.entry." + entry.id
        cell.accessibilityHint = String(localized: "Restore Tab", table: "Mobile")
        cell.selectionStyle = mayRestore ? .default : .none
        cell.contentView.alpha = mayRestore ? 1 : 0.5
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard mayRestore, entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        finishSearchThen { [weak self] in self?.selectEntry(entry) }
    }

    override func tableView(
        _: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard mayRestore, entries.indices.contains(indexPath.row) else { return nil }
        let id = entries[indexPath.row].id
        let action = UIContextualAction(
            style: .destructive, title: String(localized: "Delete", table: "Mobile"),
        ) { [weak self] _, _, completion in
            guard let self, mayRestore else { completion(false)
                return
            }
            remove(.entry(id), completion: completion)
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func updateSearchResults(for searchController: UISearchController) {
        guard searchController.searchBar.searchTextField.markedTextRange == nil else { return }
        let text = String((searchController.searchBar.text ?? "").prefix(256))
        if searchController.searchBar.text != text {
            searchController.searchBar.text = text
        }
        setQuery(text.trimmingCharacters(in: .whitespacesAndNewlines), debounce: true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        guard searchBar.searchTextField.markedTextRange == nil else { return }
        updateSearchResults(for: searchController)
    }

    func didDismissSearchController(_: UISearchController) {
        searchController.searchBar.text = ""
        setQuery("", debounce: false)
        let action = pendingSearchAction
        pendingSearchAction = nil
        if !isClosing {
            action?()
        }
    }

    func chooseClearBoundary(_ boundary: BrowserTabArchiveBoundary, dismissing picker: UIAlertController) {
        guard pendingClearBoundary == boundary else { return }
        pendingClearBoundary = nil
        picker.dismiss(animated: true) { [weak self] in self?.remove(.clear(boundary)) }
    }

    func cancelClear(dismissing picker: UIAlertController) {
        pendingClearBoundary = nil
        picker.dismiss(animated: true)
    }

    /// Used by the native menu. Publish the checkmark only after the profile's
    /// atomic preference write succeeds; Retry retains the exact chosen value.
    func chooseAutomaticArchival(_ lifetime: BrowserTemporaryTabLifetime?) {
        guard workspace.canConfigureAutomaticTabArchival, !isChangingArchive, !isCapturingBoundary,
              !isRetrying, !isClosing else { return }
        let succeeded = workspace.setAutomaticTabArchival(lifetime: lifetime)
        failedAutomaticArchival = succeeded ? nil : lifetime.map(ArchivalChoice.interval) ?? .off
        render()
    }

    func render() {
        guard isViewLoaded else { return }
        if !workspace.spaces.isEmpty {
            interactionError = nil
        }
        if lastRevision != workspace.archiveRevision {
            lastRevision = workspace.archiveRevision
            cursors = [nil]
            loadPage()
        }
        updatePresentation()
    }

    func chooseDestination(_ spaceID: String, for entry: BrowserTabArchiveEntry, dismissing picker: UIAlertController) {
        picker.dismiss(animated: true) { [weak self] in
            self?.restore(entry, to: spaceID)
        }
    }

    private func setQuery(_ value: String, debounce: Bool) {
        guard query != value, !isClosing else { return }
        query = value
        cursors = [nil]
        loadPage(debounce: debounce)
    }

    private func loadPage(debounce: Bool = false) {
        guard !isClosing else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        searchTask?.cancel()
        let query = query
        let cursor = cursors.last ?? nil
        let loader = searchLoader
        isLoading = true
        loadError = nil
        isQueryInvalid = false
        entries = []
        nextCursor = nil
        tableView.reloadData()
        updatePresentation()
        searchTask = Task { @MainActor [weak self] in
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(200))
                }
                try Task.checkCancellation()
                let page = try await loader(query, cursor, 50)
                guard let self, !Task.isCancelled, !isClosing, loadGeneration == generation else { return }
                entries = page.entries
                nextCursor = page.nextCursor
                isLoading = false
                tableView.reloadData()
                updatePresentation()
            } catch {
                guard let self, !Task.isCancelled, !isClosing, loadGeneration == generation else { return }
                isLoading = false
                isQueryInvalid = error as? BrowserTabArchiveError == .invalidQuery
                loadError = isQueryInvalid
                    ? String(localized: "Use a shorter search.", table: "Mobile")
                    : String(localized: "The archive could not be loaded. Try again.", table: "Mobile")
                updatePresentation()
            }
        }
    }

    private func finishSearchThen(_ action: @escaping () -> Void) {
        guard !isClosing else { return }
        if searchController.isActive {
            pendingSearchAction = action
            searchController.isActive = false
        } else {
            guard presentedViewController == nil else { return }
            view.endEditing(true)
            action()
        }
    }

    private func selectEntry(_ entry: BrowserTabArchiveEntry) {
        // Search dismissal may reload the list. The captured identity is checked
        // against the document again, independently of the new rendered rows.
        guard mayManage, presentedViewController == nil else { return }
        if let original = entry.tab.spaceID, workspace.spaces.contains(where: { $0.id == original }) {
            restore(entry, to: original)
            return
        }
        guard !workspace.spaces.isEmpty else {
            interactionError = String(localized: "Create a Space before restoring tabs.", table: "Mobile")
            updatePresentation()
            return
        }
        let picker = UIAlertController(
            title: String(localized: "Restore to Space", table: "Mobile"),
            message: String(localized: "The original Space is no longer available.", table: "Mobile"),
            preferredStyle: .actionSheet,
        )
        for space in workspace.spaces {
            picker.addAction(UIAlertAction(title: space.title, style: .default) { [weak self, weak picker] _ in
                guard let picker else { return }
                self?.chooseDestination(space.id, for: entry, dismissing: picker)
            })
        }
        picker.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        picker.popoverPresentationController?.sourceView = tableView
        picker.popoverPresentationController?.sourceRect = CGRect(
            x: tableView.bounds.midX, y: tableView.bounds.midY, width: 1, height: 1,
        )
        present(picker, animated: true)
    }

    private func remove(_ action: Removal, completion: ((Bool) -> Void)? = nil) {
        guard mayManage else { completion?(false)
            return
        }
        isChangingArchive = true
        failedRemoval = nil
        actionError = nil
        searchTask?.cancel()
        loadGeneration &+= 1
        isLoading = false
        updatePresentation()
        let workspace = workspace
        Task { @MainActor [weak self] in
            let succeeded: Bool =
                switch action {
                case .entry(let id): await workspace.deleteArchivedTab(id: id)
                case .clear(let boundary): await workspace.clearArchive(through: boundary)
                }
            completion?(succeeded)
            guard let self else { return }
            isChangingArchive = false
            if !succeeded {
                failedRemoval = action
                actionError = workspace.archiveError ?? String(
                    localized: "The archive could not be changed. Try again.", table: "Mobile",
                )
            }
            lastRevision = workspace.archiveRevision
            cursors = [nil]
            loadPage()
        }
    }

    private func updatePresentation() {
        updateTimingMenu()
        newerButton.isEnabled = cursors.count > 1 && !isLoading && !isChangingArchive && !isRetrying
        olderButton.isEnabled = nextCursor != nil && !isLoading && !isChangingArchive && !isRetrying
        clearButton.isEnabled = mayManage && failedRemoval == nil
        errorLabel.text = workspace.sessionError ?? actionError ?? loadError ?? interactionError ?? workspace
            .automaticTabArchivalError ?? workspace.archiveError
        retryButton.isHidden = workspace.sessionError == nil && (loadError == nil || isQueryInvalid)
            && failedRemoval == nil && !boundaryLoadFailed && workspace.automaticTabArchivalError == nil
        retryButton.isEnabled = !isRetrying && !isChangingArchive && !isCapturingBoundary
        tableView.tableHeaderView = errorLabel.text == nil ? nil : statusStack
        sizeStatusHeader()
        if entries.isEmpty, errorLabel.text == nil {
            var empty = UIContentUnavailableConfiguration.empty()
            if isLoading || isCapturingBoundary {
                empty.text = String(localized: "Loading Archive…", table: "Mobile")
            } else if !query.isEmpty {
                empty.text = String(localized: "No Matching Tabs", table: "Mobile")
            } else {
                empty.text = String(localized: "No Archived Tabs", table: "Mobile")
                empty.secondaryText = String(localized: "Tabs you close appear here.", table: "Mobile")
            }
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
        for cell in tableView.visibleCells {
            cell.contentView.alpha = mayRestore ? 1 : 0.5
            cell.selectionStyle = mayRestore ? .default : .none
        }
    }

    private func updateTimingMenu() {
        timingButton.isEnabled = workspace.canConfigureAutomaticTabArchival && mayManage
        let enabled = workspace.automaticTabArchivalEnabled
        var actions = [UIAction(
            title: String(localized: "Off", table: "Mobile"), identifier: .init("browser.archive.timing.off"),
            state: enabled ? .off : .on,
        ) { [weak self] _ in self?.chooseAutomaticArchival(nil) }]
        for lifetime in BrowserTemporaryTabLifetime.allCases {
            let title =
                switch lifetime {
                case .twelveHours: String(localized: "After 12 Hours", table: "Mobile")
                case .twentyFourHours: String(localized: "After 1 Day", table: "Mobile")
                case .threeDays: String(localized: "After 3 Days", table: "Mobile")
                case .sevenDays: String(localized: "After 7 Days", table: "Mobile")
                case .thirtyDays: String(localized: "After 30 Days", table: "Mobile")
                }
            actions.append(UIAction(
                title: title, identifier: .init("browser.archive.timing." + lifetime.rawValue),
                state: enabled && workspace.temporaryTabLifetime == lifetime ? .on : .off,
            ) { [weak self] _ in self?.chooseAutomaticArchival(lifetime) })
        }
        timingButton.menu = UIMenu(
            title: String(localized: "Auto-Archive Today Tabs", table: "Mobile"),
            children: actions,
        )
    }

    private func sizeStatusHeader() {
        guard tableView.tableHeaderView === statusStack else { return }
        let width = tableView.bounds.width
        let size = statusStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel,
        )
        guard statusStack.frame.size != CGSize(width: width, height: size.height) else { return }
        statusStack.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        tableView.tableHeaderView = statusStack
    }

    private func restore(_ entry: BrowserTabArchiveEntry, to spaceID: String) {
        guard mayManage, failedRemoval == nil else { return }
        if workspace.restoreArchivedTab(id: entry.id, toSpaceID: spaceID) != nil,
           workspace.sessionError == nil, workspace.canRestoreArchivedTab
        {
            let presenter = navigationController?.presentingViewController ?? presentingViewController
            presenter?.dismiss(animated: true, completion: didRestore)
        } else {
            render()
        }
    }

    @objc private func cancelOrClose() {
        if searchController.isActive {
            pendingSearchAction = nil
            searchController.isActive = false
            return
        }
        close()
    }

    @objc private func close() {
        isClosing = true
        searchTask?.cancel()
        loadGeneration &+= 1
        let presenter = navigationController?.presentingViewController ?? presentingViewController
        presenter?.dismiss(animated: true)
    }

    @objc private func requestClear() {
        guard mayManage, failedRemoval == nil else { return }
        finishSearchThen { [weak self] in self?.captureClearBoundary() }
    }

    private func captureClearBoundary() {
        guard mayManage, presentedViewController == nil else { return }
        isCapturingBoundary = true
        boundaryLoadFailed = false
        actionError = nil
        updatePresentation()
        let workspace = workspace
        Task { @MainActor [weak self] in
            do {
                let boundary = try await workspace.archiveClearBoundary()
                guard let self, !isClosing else { return }
                isCapturingBoundary = false
                guard presentedViewController == nil else { updatePresentation()
                    return
                }
                pendingClearBoundary = boundary
                let picker = UIAlertController(
                    title: String(localized: "Clear Archive?", table: "Mobile"),
                    message: String(
                        localized: "Remove all currently archived tabs, including those hidden by search? Tabs archived after this confirmation opens will be kept.",
                        table: "Mobile",
                    ), preferredStyle: .actionSheet,
                )
                picker.addAction(UIAlertAction(
                    title: String(localized: "Clear Archive", table: "Mobile"), style: .destructive,
                ) { [weak self, weak picker] _ in
                    guard let picker else { return }
                    self?.chooseClearBoundary(boundary, dismissing: picker)
                })
                picker.addAction(UIAlertAction(
                    title: String(localized: "Cancel", table: "Mobile"), style: .cancel,
                ) { [weak self, weak picker] _ in
                    guard let picker else { return }
                    self?.cancelClear(dismissing: picker)
                })
                picker.popoverPresentationController?.barButtonItem = clearButton
                present(picker, animated: true)
                updatePresentation()
            } catch {
                guard let self, !isClosing else { return }
                isCapturingBoundary = false
                boundaryLoadFailed = true
                actionError = String(localized: "The archive could not be loaded. Try again.", table: "Mobile")
                updatePresentation()
            }
        }
    }

    @objc private func showOlder() {
        guard let nextCursor, !isLoading, !isChangingArchive, !isRetrying else { return }
        cursors.append(nextCursor)
        loadPage()
        updatePresentation()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
    }

    @objc private func showNewer() {
        guard cursors.count > 1, !isLoading, !isChangingArchive, !isRetrying else { return }
        cursors.removeLast()
        loadPage()
        updatePresentation()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
    }

    @objc private func retry() {
        guard !isRetrying, !isChangingArchive, !isCapturingBoundary else { return }
        if let failedAutomaticArchival, workspace.sessionError == nil {
            chooseAutomaticArchival(failedAutomaticArchival.lifetime)
            return
        }
        if workspace.automaticTabArchivalError != nil, workspace.sessionError == nil {
            workspace.reloadAutomaticTabArchivalSettings()
            render()
            return
        }
        if boundaryLoadFailed, workspace.sessionError == nil {
            requestClear()
            return
        }
        if let failedRemoval, workspace.sessionError == nil {
            remove(failedRemoval)
            return
        }
        isRetrying = true
        updatePresentation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await workspace.retryPersistence()
            isRetrying = false
            lastRevision = workspace.archiveRevision
            cursors = [nil]
            loadPage()
            updatePresentation()
        }
    }
}
