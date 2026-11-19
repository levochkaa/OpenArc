// BrowserMobileExtensionActionsViewController.swift

import Combine
import UIKit
import WebKit

// MARK: - BrowserMobileExtensionActionsViewController

/// The running extensions' actions for the selected tab, with their icons
/// and badges, as the page menu shows them. A tap closes the list and runs
/// the action, which may open its popup.
final class BrowserMobileExtensionActionsViewController: UITableViewController {
    // MARK: Internal

    var showSettings: (() -> Void)?

    // MARK: Private

    private let engine: BrowserWebKitEngine
    private let extensions: BrowserMobileExtensions
    private weak var anchor: UIView?
    private var rows = [(record: BrowserWebExtensionRecord, action: WKWebExtension.Action)]()
    private var observation: AnyCancellable?

    init(engine: BrowserWebKitEngine, extensions: BrowserMobileExtensions = .shared, anchor: UIView?) {
        self.engine = engine
        self.extensions = extensions
        self.anchor = anchor
        super.init(style: .insetGrouped)
        title = String(localized: "Extensions", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.extensionActions"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        observation = extensions.changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.reload() }
        reload()
    }

    override func numberOfSections(in _: UITableView) -> Int { 2 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? max(rows.count, 1) : 1
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0, rows.isEmpty else { return nil }
        return String(
            localized: "Open an extension’s page in the Chrome Web Store or on addons.mozilla.org and tap Add to OpenArc.",
            table: "Mobile",
        )
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryView = nil
        if indexPath.section == 1 {
            content.text = String(localized: "Manage Extensions", table: "Mobile")
            content.image = UIImage(systemName: "gearshape")
            cell.accessibilityIdentifier = "browser.extensionActions.manage"
            cell.accessoryType = .disclosureIndicator
        } else if rows.isEmpty {
            content.text = String(localized: "No Extensions", table: "Mobile")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else {
            let row = rows[indexPath.row]
            content.text = row.action.label.isEmpty ? row.record.name : row.action.label
            content.image = row.action.icon(for: CGSize(width: 28, height: 28))
                ?? UIImage(systemName: "puzzlepiece.extension")
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
            content.textProperties.color = row.action.isEnabled ? .label : .secondaryLabel
            if !row.action.badgeText.isEmpty {
                let badge = UILabel()
                badge.text = row.action.badgeText
                badge.font = .systemFont(ofSize: 13, weight: .semibold)
                badge.textColor = .white
                badge.backgroundColor = .systemRed
                badge.textAlignment = .center
                badge.layer.cornerRadius = 10
                badge.clipsToBounds = true
                let width = max(20, badge.intrinsicContentSize.width + 12)
                badge.frame = CGRect(x: 0, y: 0, width: width, height: 20)
                cell.accessoryView = badge
            }
            cell.accessoryType = .none
            cell.accessibilityIdentifier = "browser.extensionAction.\(row.record.id)"
            cell.selectionStyle = row.action.isEnabled ? .default : .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            let showSettings = showSettings
            dismiss(animated: true) { showSettings?() }
            return
        }
        guard rows.indices.contains(indexPath.row) else { return }
        let row = rows[indexPath.row]
        guard row.action.isEnabled else { return }
        // A popup opens where the list was: from the toolbar button, or as a sheet.
        let source = anchor ?? engine.hostView
        let extensions = extensions
        let engine = engine
        dismiss(animated: true) {
            extensions.performAction(id: row.record.id, in: engine, from: source)
        }
    }

    /// Presents the list as a sheet, or a popover from `anchor` in a wide window.
    static func present(
        engine: BrowserWebKitEngine, from presenter: UIViewController, anchor: UIView?,
        showSettings: @escaping () -> Void,
    ) {
        let list = BrowserMobileExtensionActionsViewController(engine: engine, anchor: anchor)
        list.showSettings = showSettings
        let navigation = UINavigationController(rootViewController: list)
        if presenter.traitCollection.horizontalSizeClass == .regular, let anchor {
            navigation.modalPresentationStyle = .popover
            navigation.popoverPresentationController?.sourceView = anchor
            navigation.popoverPresentationController?.sourceRect = anchor.bounds
            navigation.preferredContentSize = CGSize(width: 340, height: 380)
        } else {
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }

    private func reload() {
        rows = extensions.actions(in: engine)
        tableView.reloadData()
    }
}
