import UIKit

// MARK: - BrowserMobileDownloadsPresenting

@MainActor protocol BrowserMobileDownloadsPresenting: AnyObject {
    var entries: [BrowserMobileDownload] { get }
    var isLoading: Bool { get }
    var error: String? { get }
    var canRetryPersistence: Bool { get }
    func load() async
    func observe(_ observer: @escaping @MainActor () -> Void) -> UUID
    func removeObserver(_ id: UUID)
    func cancel(id: UUID)
    func retryPersistence() async
    func acquireExport(id: UUID) async throws -> BrowserMobileDownloadExportLease
    func canDelete(id: UUID) -> Bool
    func isDeleting(id: UUID) -> Bool
    func remove(id: UUID) async -> Bool
}

// MARK: - BrowserMobileDownloads + BrowserMobileDownloadsPresenting

extension BrowserMobileDownloads: BrowserMobileDownloadsPresenting {}

// MARK: - BrowserMobileDownloadsViewController

@MainActor final class BrowserMobileDownloadsViewController: UITableViewController,
    UIAdaptivePresentationControllerDelegate
{
    // MARK: Lifecycle

    init(
        downloads: any BrowserMobileDownloadsPresenting,
        exportPresenter: (@MainActor (UIViewController, UIDocumentPickerViewController) -> Void)? = nil
    ) {
        self.downloads = downloads
        self.exportPresenter = exportPresenter ?? { owner, picker in owner.present(picker, animated: true) }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        exportTask?.cancel()
        loadTask?.cancel()
        retryTask?.cancel()
        if let observation {
            downloads.removeObserver(observation)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Internal

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.localized("Downloads")
        tableView.accessibilityIdentifier = "browser.downloads.list"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.register(BrowserMobileDownloadCell.self, forCellReuseIdentifier: "Download")
        let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        done.accessibilityIdentifier = "browser.downloads.done"
        navigationItem.rightBarButtonItem = done
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "browser.downloads.status"
        retryButton.setTitle(Self.localized("Retry"), for: .normal)
        retryButton.accessibilityIdentifier = "browser.downloads.retry"
        retryButton.addTarget(self, action: #selector(retryPersistence), for: .touchUpInside)
        retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        statusStack.axis = .vertical
        statusStack.spacing = 8
        statusStack.isLayoutMarginsRelativeArrangement = true
        statusStack.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(retryButton)
        observation = downloads.observe { [weak self] in self?.render() }
        for name in [
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification,
            UIScene.didActivateNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged), name: name, object: nil)
        }
        render()
        loadTask = Task { [weak self, downloads] in
            await downloads.load()
            guard let self, !isClosing else { return }
            render()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sceneAllowsPresentation = view.window?.windowScene?.activationState == .foregroundActive
        (navigationController?.presentationController ?? presentationController)?.delegate = self
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeStatusHeader()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true ||
            isMovingFromParent || navigationController?.isMovingFromParent == true
        {
            invalidate()
        } else if exportTask != nil {
            // Full-screen children can detach this view without ending its
            // lifetime. Keep its observation and any already presented picker.
            cancelPendingExport()
            render()
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { entries.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Download", for: indexPath)
        if let cell = cell as? BrowserMobileDownloadCell {
            configure(cell, entry: entries[indexPath.row])
        }
        return cell
    }

    override func tableView(
        _: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard entries.indices.contains(indexPath.row), downloads.canDelete(id: entries[indexPath.row].id) else {
            return nil
        }
        let id = entries[indexPath.row].id
        let action = UIContextualAction(style: .destructive, title: Self.localized("Delete")) {
            [weak self] _, _, completion in
            _ = self?.requestDeletion(id: id)
            // Opening confirmation has not removed a row.
            completion(false)
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func tableView(
        _: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard entries.indices.contains(indexPath.row) else { return nil }
        let entry = entries[indexPath.row]
        guard entry.status == .completed || downloads.canDelete(id: entry.id) else { return nil }
        return UIContextMenuConfiguration(identifier: entry.id as NSUUID, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let attributes: UIMenuElement.Attributes = downloads.canDelete(id: entry.id)
                ? .destructive
                : [.destructive, .disabled]
            return UIMenu(children: [UIAction(
                title: Self.localized("Delete"),
                image: UIImage(systemName: "trash"),
                attributes: attributes
            ) { [weak self] _ in
                _ = self?.requestDeletion(id: entry.id)
            }])
        }
    }

    func confirmDeletion(id: UUID, dismissing alert: UIAlertController) {
        guard deleteConfirmation === alert, deleteConfirmationID == id else { return }
        let originalWindow = deleteConfirmationWindow
        deleteConfirmation = nil
        deleteConfirmationID = nil
        deleteConfirmationWindow = nil
        alert.dismiss(animated: true) { [weak self, weak originalWindow] in
            guard let self, let originalWindow, viewIfLoaded?.window === originalWindow,
                  canPresent, deleteTask == nil else { return }
            guard downloads.entries.contains(where: { $0.id == id }), downloads.canDelete(id: id) else {
                interactionError = Self.localized("This download can no longer be deleted.")
                interactionErrorDownloadID = id
                render()
                return
            }
            interactionError = nil
            deleteTask = Task { [weak self, downloads] in
                let removed = await downloads.remove(id: id)
                guard let self else { return }
                deleteTask = nil
                if !removed {
                    // Shared persistence errors must clear when another window
                    // retries successfully. Keep only local admission errors here.
                    interactionError = downloads.error == nil
                        ? Self.localized("This download can no longer be deleted.")
                        : nil
                    interactionErrorDownloadID = interactionError == nil ? nil : id
                }
                render()
            }
        }
    }

    func cancelDeletion(dismissing alert: UIAlertController) {
        guard deleteConfirmation === alert else { return }
        deleteConfirmation = nil
        deleteConfirmationID = nil
        deleteConfirmationWindow = nil
        alert.dismiss(animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === navigationController ||
            presentationController.presentedViewController === self
        {
            invalidate()
        }
    }

    func invalidate() {
        guard !isClosing else { return }
        isClosing = true
        deleteConfirmation = nil
        deleteConfirmationID = nil
        deleteConfirmationWindow = nil
        exportPicker = nil
        cancelPendingExport()
        loadTask?.cancel()
        retryTask?.cancel()
        if let observation {
            downloads.removeObserver(observation)
            self.observation = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Private

    private let downloads: any BrowserMobileDownloadsPresenting
    private let exportPresenter: @MainActor (UIViewController, UIDocumentPickerViewController) -> Void
    private var entries = [BrowserMobileDownload]()
    private var observation: UUID?
    private var loadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private weak var deleteConfirmation: UIAlertController?
    private var deleteConfirmationID: UUID?
    private weak var deleteConfirmationWindow: UIWindow?
    private var exportAttempt: UUID?
    private var exportingID: UUID?
    private weak var exportPicker: UIDocumentPickerViewController?
    private var isClosing = false
    private var sceneAllowsPresentation = true
    private var interactionError: String?
    private var interactionErrorDownloadID: UUID?
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let statusStack = UIStackView()

    private var canPresent: Bool {
        guard !isClosing, sceneAllowsPresentation, let window = viewIfLoaded?.window, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive,
              !isBeingDismissed, navigationController?.isBeingDismissed != true else { return false }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            guard controller.presentedViewController == nil else { return false }
            ancestor = controller.parent
        }
        return true
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Mobile", comment: "Downloads")
    }

    private func render() {
        guard isViewLoaded, !isClosing else { return }
        if let id = interactionErrorDownloadID, !downloads.entries.contains(where: { $0.id == id }) {
            interactionError = nil
            interactionErrorDownloadID = nil
        }
        let previousIDs = entries.map(\.id)
        entries = downloads.entries
        if previousIDs != entries.map(\.id) {
            tableView.reloadData()
        } else {
            for index in tableView.indexPathsForVisibleRows ?? [] where entries.indices.contains(index.row) {
                if let cell = tableView.cellForRow(at: index) as? BrowserMobileDownloadCell {
                    configure(cell, entry: entries[index.row])
                }
            }
        }
        statusLabel.text = interactionError ?? downloads.error ?? (downloads.isLoading
            ? Self.localized("Loading Downloads…")
            : entries.isEmpty ? Self.localized("No Downloads") : nil)
        retryButton.isHidden = !downloads.canRetryPersistence
        retryButton.isEnabled = retryTask == nil && !downloads.isLoading
        statusStack.isHidden = statusLabel.text == nil && retryButton.isHidden
        sizeStatusHeader()
    }

    private func configure(_ cell: BrowserMobileDownloadCell, entry: BrowserMobileDownload) {
        cell.configure(
            entry: entry,
            exportPending: exportingID == entry.id,
            exportAvailable: exportingID == nil,
            deleting: downloads.isDeleting(id: entry.id)
        )
        let id = entry.id
        cell.action = { [weak self] in self?.performAction(id: id) }
        cell.deleteAction = downloads.canDelete(id: id)
            ? { [weak self] in self?.requestDeletion(id: id) ?? false }
            : nil
    }

    private func performAction(id: UUID) {
        guard !isClosing, let entry = downloads.entries.first(where: { $0.id == id }) else { return }
        switch entry.status {
        case .downloading:
            downloads.cancel(id: id)
        case .completed:
            beginExport(id: id)
        case .cancelled, .failed, .saving:
            break
        }
    }

    @discardableResult private func requestDeletion(id: UUID) -> Bool {
        guard canPresent, let window = view.window, deleteTask == nil, deleteConfirmation == nil,
              downloads.canDelete(id: id),
              let entry = downloads.entries.first(where: { $0.id == id }) else { return false }
        let alert = UIAlertController(
            title: Self.localized("Delete Download?"),
            message: String(
                format: Self.localized("Delete “%@” from this browser? Copies saved to Files will remain."),
                entry.filename
            ), preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "browser.downloads.delete-confirmation"
        deleteConfirmation = alert
        deleteConfirmationID = id
        deleteConfirmationWindow = window
        alert.addAction(UIAlertAction(title: Self.localized("Delete"), style: .destructive) {
            [weak self, weak alert] _ in
            guard let alert else { return }
            self?.confirmDeletion(id: id, dismissing: alert)
        })
        alert.addAction(UIAlertAction(title: Self.localized("Cancel"), style: .cancel) { [weak self, weak alert] _ in
            guard let alert else { return }
            self?.cancelDeletion(dismissing: alert)
        })
        present(alert, animated: true)
        return true
    }

    private func beginExport(id: UUID) {
        guard canPresent, exportingID == nil, let window = view.window,
              downloads.entries.first(where: { $0.id == id })?.status == .completed else { return }
        let attempt = UUID()
        exportAttempt = attempt
        exportingID = id
        interactionError = nil
        render()
        exportTask = Task { [weak self, weak window, downloads] in
            do {
                let lease = try await downloads.acquireExport(id: id)
                var transferred = false
                defer {
                    if !transferred {
                        lease.finish()
                    }
                }
                guard let self, exportAttempt == attempt else { return }
                guard !Task.isCancelled, let window, viewIfLoaded?.window === window, canPresent,
                      downloads.entries.first(where: { $0.id == id })?.status == .completed
                else {
                    cancelPendingExport()
                    render()
                    return
                }
                let picker = BrowserMobileDownloadExportPicker(lease: lease) { [weak self] picker in
                    self?.finishExport(picker)
                }
                transferred = true
                exportPicker = picker
                exportTask = nil
                exportPresenter(self, picker)
                picker.presentationController?.delegate = picker
            } catch {
                guard let self, exportAttempt == attempt else { return }
                cancelPendingExport()
                interactionError = error as? BrowserMobileDownloadError == .busy
                    ? Self.localized("This download cannot be saved while its removal is pending.")
                    : Self.localized("This file could not be prepared. Try Save to Files again.")
                interactionErrorDownloadID = id
                render()
            }
        }
    }

    private func finishExport(_ picker: UIDocumentPickerViewController) {
        guard exportPicker === picker else { return }
        exportPicker = nil
        cancelPendingExport()
        render()
    }

    private func cancelPendingExport() {
        exportAttempt = nil
        exportingID = nil
        exportTask?.cancel()
        exportTask = nil
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, viewIfLoaded?.window?.windowScene === scene else {
            return
        }
        sceneAllowsPresentation = notification.name == UIScene.didActivateNotification
        if !sceneAllowsPresentation, exportTask != nil {
            cancelPendingExport()
        }
        render()
    }

    @objc private func retryPersistence() {
        guard !isClosing, retryTask == nil, downloads.canRetryPersistence else { return }
        interactionError = nil
        retryTask = Task { [weak self, downloads] in
            await downloads.retryPersistence()
            guard let self else { return }
            retryTask = nil
            render()
        }
        render()
    }

    @objc private func close() {
        invalidate()
        (navigationController ?? self).dismiss(animated: true)
    }

    private func sizeStatusHeader() {
        guard isViewLoaded else { return }
        if statusStack.isHidden {
            if tableView.tableHeaderView != nil {
                tableView.tableHeaderView = nil
            }
            return
        }
        let width = tableView.bounds.width
        let size = statusStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        if statusStack.frame.size != size || tableView.tableHeaderView !== statusStack {
            statusStack.frame = CGRect(origin: .zero, size: size)
            tableView.tableHeaderView = statusStack
        }
    }
}

// MARK: - BrowserMobileDownloadExportPicker

@MainActor private final class BrowserMobileDownloadExportPicker: UIDocumentPickerViewController,
    UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
{
    // MARK: Lifecycle

    init(
        lease: BrowserMobileDownloadExportLease,
        onFinish: @escaping @MainActor (UIDocumentPickerViewController) -> Void
    ) {
        self.lease = lease
        self.onFinish = onFinish
        super.init(forExporting: [lease.url], asCopy: true)
        loadViewIfNeeded()
        shouldShowFileExtensions = true
        modalPresentationStyle = .formSheet
        delegate = self
        view.accessibilityIdentifier = "browser.downloads.export"
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { lease?.finish() }

    // MARK: Internal

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if controller === self {
            finish()
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt _: [URL]) {
        if controller === self {
            finish()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === self {
            finish()
        }
    }

    // MARK: Private

    private var lease: BrowserMobileDownloadExportLease?
    private var onFinish: (@MainActor (UIDocumentPickerViewController) -> Void)?

    private func finish() {
        guard let lease else { return }
        self.lease = nil
        lease.finish()
        let callback = onFinish
        onFinish = nil
        callback?(self)
    }
}

// MARK: - BrowserMobileDownloadCell

@MainActor private final class BrowserMobileDownloadCell: UITableViewCell {
    // MARK: Lifecycle

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        let stack = UIStackView(arrangedSubviews: [filenameLabel, statusLabel, progress, actionButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let actionHeight = actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        // UIStackView gives a hidden arranged view a required zero height.
        actionHeight.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            actionHeight,
        ])
        // A self-sizing row may temporarily retain its old height while a
        // Dynamic Type change relayouts it. Give extra space to the action.
        actionButton.setContentHuggingPriority(.init(251), for: .vertical)
        filenameLabel.setContentHuggingPriority(.init(252), for: .vertical)
        statusLabel.setContentHuggingPriority(.init(253), for: .vertical)
        progress.setContentHuggingPriority(.required, for: .vertical)
        filenameLabel.setContentCompressionResistancePriority(.init(750), for: .vertical)
        statusLabel.setContentCompressionResistancePriority(.init(751), for: .vertical)
        actionButton.setContentCompressionResistancePriority(.init(752), for: .vertical)
        progress.setContentCompressionResistancePriority(.required, for: .vertical)
        filenameLabel.font = .preferredFont(forTextStyle: .body)
        filenameLabel.adjustsFontForContentSizeCategory = true
        filenameLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        actionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        actionButton.titleLabel?.numberOfLines = 0
        actionButton.addTarget(self, action: #selector(activate), for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    var action: (() -> Void)?

    var deleteAction: (() -> Bool)? {
        didSet {
            filenameLabel.accessibilityCustomActions = deleteAction == nil
                ? nil
                : [
                    UIAccessibilityCustomAction(name: Self.localized("Delete")) { [deleteAction] _ in
                        deleteAction?() ?? false
                    },
                ]
        }
    }

    func configure(entry: BrowserMobileDownload, exportPending: Bool, exportAvailable: Bool, deleting: Bool) {
        let prefix = "browser.downloads." + entry.id.uuidString
        accessibilityIdentifier = prefix
        filenameLabel.text = entry.filename
        filenameLabel.accessibilityIdentifier = prefix + ".filename"
        statusLabel.accessibilityIdentifier = prefix + ".status"
        progress.accessibilityIdentifier = prefix + ".progress"
        actionButton.accessibilityIdentifier = prefix + ".action"
        let received = ByteCountFormatter.string(fromByteCount: max(0, entry.receivedBytes), countStyle: .file)
        var amount = received
        if let total = entry.totalBytes, total > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            amount = String(format: Self.localized("%@ of %@"), received, formatted)
            progress.progress = Float(min(1, max(0, Double(entry.receivedBytes) / Double(total))))
        }
        progress.isHidden = entry.status != .downloading || (entry.totalBytes ?? 0) <= 0
        actionButton.isHidden = entry.status != .downloading && entry.status != .completed
        actionButton.isEnabled = !deleting && (entry.status == .downloading || exportAvailable)
        if deleting {
            statusLabel.text = Self.localized("Deleting…")
            progress.isHidden = true
            return
        }
        switch entry.status {
        case .downloading:
            statusLabel.text = Self.localized("Downloading") + " · " + amount
            actionButton.setTitle(Self.localized("Cancel"), for: .normal)
        case .completed:
            statusLabel.text = (exportPending ? Self.localized("Preparing File…") : Self.localized("Completed")) +
                " · " + received
            actionButton.setTitle(Self.localized("Save to Files"), for: .normal)
        case .saving:
            statusLabel.text = Self.localized("Saving…")
        case .cancelled:
            statusLabel.text = Self.localized("Cancelled")
        case .failed:
            statusLabel.text = Self.localized("Failed") + (entry.error.map { "\n" + $0 } ?? "")
        }
    }

    // MARK: Private

    private let filenameLabel = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let actionButton = UIButton(type: .system)

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Mobile", comment: "Downloads")
    }

    @objc private func activate() { action?() }
}
