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
    func exportURL(id: UUID) async throws -> URL
}

// MARK: - BrowserMobileDownloads + BrowserMobileDownloadsPresenting

extension BrowserMobileDownloads: BrowserMobileDownloadsPresenting {}

// MARK: - BrowserMobileDownloadsViewController

@MainActor final class BrowserMobileDownloadsViewController: UITableViewController,
    UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
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

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishExport(controller) }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt _: [URL]) {
        finishExport(controller)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let picker = presentationController.presentedViewController as? UIDocumentPickerViewController {
            finishExport(picker)
        } else if presentationController.presentedViewController === navigationController ||
            presentationController.presentedViewController === self
        {
            invalidate()
        }
    }

    func invalidate() {
        guard !isClosing else { return }
        isClosing = true
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
    private var exportAttempt: UUID?
    private var exportingID: UUID?
    private weak var exportPicker: UIDocumentPickerViewController?
    private var isClosing = false
    private var sceneAllowsPresentation = true
    private var interactionError: String?
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
        cell.configure(entry: entry, exportPending: exportingID == entry.id, exportAvailable: exportingID == nil)
        let id = entry.id
        cell.action = { [weak self] in self?.performAction(id: id) }
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
                let url = try await downloads.exportURL(id: id)
                guard let self, exportAttempt == attempt else { return }
                guard !Task.isCancelled, let window, viewIfLoaded?.window === window, canPresent,
                      downloads.entries.first(where: { $0.id == id })?.status == .completed
                else {
                    cancelPendingExport()
                    render()
                    return
                }
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                picker.loadViewIfNeeded()
                picker.shouldShowFileExtensions = true
                picker.modalPresentationStyle = .formSheet
                picker.delegate = self
                picker.view.accessibilityIdentifier = "browser.downloads.export"
                exportPicker = picker
                exportTask = nil
                exportPresenter(self, picker)
                picker.presentationController?.delegate = self
            } catch {
                guard let self, exportAttempt == attempt else { return }
                cancelPendingExport()
                interactionError = Self.localized("This file could not be prepared. Try Save to Files again.")
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

    func configure(entry: BrowserMobileDownload, exportPending: Bool, exportAvailable: Bool) {
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
        actionButton.isEnabled = entry.status == .downloading || exportAvailable
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
