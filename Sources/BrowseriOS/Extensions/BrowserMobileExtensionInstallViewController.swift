// BrowserMobileExtensionInstallViewController.swift

import UIKit
import WebKit

// MARK: - BrowserMobileExtensionInstallViewController

/// The permissions prompt before an extension installs: what it may do, and
/// what it asks for that does not run here.
final class BrowserMobileExtensionInstallViewController: UITableViewController {
    // MARK: Private

    private enum Section: Int, CaseIterable {
        case permissions
        case unsupported
    }

    // MARK: Internal

    var onAnswer: ((Bool) -> Void)?

    private let name: String
    private let version: String
    private let sourceLabel: String
    private let isPartiallyCompatible: Bool
    private let icon: UIImage?
    private let permissionLines: [String]
    private let unsupported: [String]
    private var hasAnswered = false

    init(pending: BrowserWebExtensionPendingInstall) {
        self.name = pending.name
        self.version = pending.version
        self.isPartiallyCompatible = pending.item.source == .firefoxAddons
        self.sourceLabel = pending.item.source == .firefoxAddons
            ? String(localized: "Firefox Add-on", table: "Mobile")
            : String(localized: "Chrome Web Store", table: "Mobile")
        self.icon = pending.webExtension.icon(for: CGSize(width: 64, height: 64))
        self.permissionLines = pending.permissionLines
        self.unsupported = pending.unsupportedFeatures
        super.init(style: .insetGrouped)
        title = String(localized: "Add Extension", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.extensionInstall"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.answer(false) },
        )
        let add = UIBarButtonItem(
            title: String(localized: "Add", table: "Mobile"), style: .prominent, target: nil, action: nil,
        )
        add.primaryAction = UIAction(title: String(localized: "Add", table: "Mobile")) { [weak self] _ in
            self?.answer(true)
        }
        add.accessibilityIdentifier = "browser.extensionInstall.add"
        navigationItem.rightBarButtonItem = add
        tableView.tableHeaderView = header()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel,
        )
        if header.frame.height != size.height {
            header.frame.size = size
            tableView.tableHeaderView = header
        }
    }

    override func numberOfSections(in _: UITableView) -> Int { unsupported.isEmpty ? 1 : 2 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .permissions: max(permissionLines.count, 1)
        case .unsupported: unsupported.count
        case nil: 0
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .permissions: String(localized: "It Can", table: "Mobile")
        case .unsupported: String(localized: "Not Supported Here", table: "Mobile")
        case nil: nil
        }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .unsupported:
            String(
                localized: "The extension installs without these. Parts of it that need them may not work.",
                table: "Mobile",
            )
        default:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.cell()
        switch Section(rawValue: indexPath.section) {
        case .permissions:
            content.text = permissionLines.isEmpty
                ? String(localized: "Run without access to your data", table: "Mobile")
                : permissionLines[indexPath.row]
            content.image = UIImage(systemName: "checkmark.shield")
            content.imageProperties.tintColor = .systemBlue
        case .unsupported:
            content.text = unsupported[indexPath.row]
            content.image = UIImage(systemName: "nosign")
            content.imageProperties.tintColor = .secondaryLabel
            content.textProperties.color = .secondaryLabel
        case nil:
            break
        }
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    /// Presents the prompt and waits for the answer; dismissing it declines.
    @MainActor static func ask(
        _ pending: BrowserWebExtensionPendingInstall,
        presenter: UIViewController,
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let prompt = BrowserMobileExtensionInstallViewController(pending: pending)
            prompt.onAnswer = { continuation.resume(returning: $0) }
            let navigation = UINavigationController(rootViewController: prompt)
            navigation.presentationController?.delegate = prompt
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
            presenter.present(navigation, animated: true)
        }
    }

    private func header() -> UIView {
        let iconView = UIImageView(image: icon ?? UIImage(systemName: "puzzlepiece.extension"))
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = UILabel()
        title.text = name
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        let detail = UILabel()
        var parts = [sourceLabel]
        if !version.isEmpty { parts.append(String(localized: "Version \(version)", table: "Mobile")) }
        detail.text = parts.joined(separator: " · ")
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [iconView, title, detail])
        if isPartiallyCompatible {
            let note = UILabel()
            note.text = String(
                localized: "Partially compatible: written for Firefox. Standard extension features work; Firefox’s own do not.",
                table: "Mobile",
            )
            note.font = .preferredFont(forTextStyle: .footnote)
            note.adjustsFontForContentSizeCategory = true
            note.textColor = .secondaryLabel
            note.textAlignment = .center
            note.numberOfLines = 0
            stack.addArrangedSubview(note)
        }
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 16, leading: 20, bottom: 8, trailing: 20)
        let container = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func answer(_ approved: Bool) {
        guard !hasAnswered else { return }
        hasAnswered = true
        let onAnswer = onAnswer
        self.onAnswer = nil
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: true) { onAnswer?(approved) }
        } else {
            onAnswer?(approved)
        }
    }
}

// MARK: UIAdaptivePresentationControllerDelegate

extension BrowserMobileExtensionInstallViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_: UIPresentationController) {
        guard !hasAnswered else { return }
        hasAnswered = true
        onAnswer?(false)
        onAnswer = nil
    }
}

// MARK: - BrowserMobileExtensionPageViewController

/// An extension's own page, such as its options, with the extension's configuration.
final class BrowserMobileExtensionPageViewController: UIViewController {
    private let url: URL
    private let configuration: WKWebViewConfiguration

    init(url: URL, configuration: WKWebViewConfiguration, title: String?) {
        self.url = url
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.accessibilityIdentifier = "browser.extensionPage"
        webView.load(URLRequest(url: url))
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
    }
}
