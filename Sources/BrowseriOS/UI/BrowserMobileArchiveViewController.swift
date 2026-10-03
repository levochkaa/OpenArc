import UIKit

/// Bounded pages of profile-local recovery records. The document owns restore
/// identity, persistence, and publication to all windows.
final class BrowserMobileArchiveViewController: UITableViewController {
    // MARK: Lifecycle

    init(workspace: BrowserMobileWorkspace) {
        self.workspace = workspace
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }

    let workspace: BrowserMobileWorkspace
    var didRestore: (() -> Void)?

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
        newerButton = UIBarButtonItem(
            title: String(localized: "Newer", table: "Mobile"), style: .plain,
            target: self, action: #selector(showNewer)
        )
        olderButton = UIBarButtonItem(
            title: String(localized: "Older", table: "Mobile"), style: .plain,
            target: self, action: #selector(showOlder)
        )
        newerButton.accessibilityIdentifier = "browser.archive.newer"
        olderButton.accessibilityIdentifier = "browser.archive.older"
        toolbarItems = [newerButton, UIBarButtonItem(systemItem: .flexibleSpace), olderButton]
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
        guard mayRestore, entries.indices.contains(indexPath.row), presentedViewController == nil else { return }
        let entry = entries[indexPath.row]
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
            preferredStyle: .actionSheet
        )
        for space in workspace.spaces {
            picker.addAction(UIAlertAction(title: space.title, style: .default) { [weak self, weak picker] _ in
                guard let picker else { return }
                self?.chooseDestination(space.id, for: entry, dismissing: picker)
            })
        }
        picker.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        picker.popoverPresentationController?.sourceView = tableView
        picker.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
        present(picker, animated: true)
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

    // MARK: Private

    private var entries = [BrowserTabArchiveEntry]()
    private var cursors: [BrowserTabArchiveCursor?] = [nil]
    private var nextCursor: BrowserTabArchiveCursor?
    private var lastRevision: Int?
    private var loadError: String?
    private var interactionError: String?
    private var newerButton = UIBarButtonItem()
    private var olderButton = UIBarButtonItem()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let statusStack = UIStackView()
    private var isRetrying = false

    private var mayRestore: Bool { workspace.canRestoreArchivedTab && loadError == nil && !isRetrying }

    private func loadPage() {
        do {
            let page = try workspace.archivePage(before: cursors.last ?? nil, limit: 50)
            entries = page.entries
            nextCursor = page.nextCursor
            loadError = nil
        } catch {
            loadError = String(localized: "The archive could not be loaded. Try again.", table: "Mobile")
            nextCursor = nil
        }
        tableView.reloadData()
    }

    private func updatePresentation() {
        newerButton.isEnabled = cursors.count > 1 && !isRetrying
        olderButton.isEnabled = nextCursor != nil && !isRetrying
        errorLabel.text = workspace.sessionError ?? loadError ?? interactionError ?? workspace.archiveError
        retryButton.isHidden = workspace.sessionError == nil && loadError == nil
        retryButton.isEnabled = !isRetrying
        tableView.tableHeaderView = errorLabel.text == nil ? nil : statusStack
        sizeStatusHeader()
        if entries.isEmpty, errorLabel.text == nil {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.text = String(localized: "No Archived Tabs", table: "Mobile")
            empty.secondaryText = String(localized: "Tabs you close appear here.", table: "Mobile")
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
        for cell in tableView.visibleCells {
            cell.contentView.alpha = mayRestore ? 1 : 0.5
            cell.selectionStyle = mayRestore ? .default : .none
        }
    }

    private func sizeStatusHeader() {
        guard tableView.tableHeaderView === statusStack else { return }
        let width = tableView.bounds.width
        let size = statusStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        guard statusStack.frame.size != CGSize(width: width, height: size.height) else { return }
        statusStack.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        tableView.tableHeaderView = statusStack
    }

    private func restore(_ entry: BrowserTabArchiveEntry, to spaceID: String) {
        guard mayRestore else { return }
        if workspace.restoreArchivedTab(id: entry.id, toSpaceID: spaceID) != nil,
           workspace.sessionError == nil, workspace.canRestoreArchivedTab
        {
            let presenter = navigationController?.presentingViewController ?? presentingViewController
            presenter?.dismiss(animated: true, completion: didRestore)
        } else {
            render()
        }
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func showOlder() {
        guard let nextCursor, !isRetrying else { return }
        cursors.append(nextCursor)
        loadPage()
        updatePresentation()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
    }

    @objc private func showNewer() {
        guard cursors.count > 1, !isRetrying else { return }
        cursors.removeLast()
        loadPage()
        updatePresentation()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
    }

    @objc private func retry() {
        guard !isRetrying else { return }
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
