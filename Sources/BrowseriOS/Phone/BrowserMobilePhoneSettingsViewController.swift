// BrowserMobilePhoneSettingsViewController.swift

import UIKit
import WebKit

/// Settings from the switcher's gear: Downloads and Archive up top, then the
/// account and the licenses.
final class BrowserMobilePhoneSettingsViewController: UITableViewController {
    // MARK: Private

    private struct Row {
        let title: String
        let symbol: String
        let color: UIColor
        let id: String
        let isEnabled: Bool
        let action: () -> Void
    }

    // MARK: Internal

    var showDownloads: (() -> Void)?
    var showArchive: (() -> Void)?

    private let workspace: BrowserMobileWorkspace
    private var rows = [[Row]]()

    init(workspace: BrowserMobileWorkspace) {
        self.workspace = workspace
        super.init(style: .insetGrouped)
        title = String(localized: "Settings", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.settingsList"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        rows = [
            [
                .init(
                    title: String(localized: "Downloads", table: "Mobile"),
                    symbol: "arrow.down.circle",
                    color: .systemBlue,
                    id: "browser.settings.downloads",
                    isEnabled: workspace.downloads != nil,
                )
                    { [weak self] in self?.showDownloads?() },
                .init(
                    title: String(localized: "Archive", table: "Mobile"),
                    symbol: "archivebox",
                    color: .systemPurple,
                    id: "browser.settings.archive",
                    isEnabled: workspace.supportsArchive,
                )
                    { [weak self] in self?.showArchive?() },
            ],
        ]
        if let session = workspace.syncSession {
            rows.append([
                .init(
                    title: String(localized: "Account", table: "Mobile"),
                    symbol: "person.crop.circle",
                    color: .systemIndigo,
                    id: "browser.settings.account",
                    isEnabled: true,
                ) { [weak self] in
                    self?.navigationController?.pushViewController(
                        BrowserMobileAccountViewController(session: session), animated: true,
                    )
                },
            ])
        }
        rows.append([
            .init(
                title: String(localized: "Open Source Licenses", table: "Mobile"),
                symbol: "doc.text",
                color: .systemGray,
                id: "browser.settings.licenses",
                isEnabled: true,
            )
                { [weak self] in self?.showLicenses() },
        ])
    }

    override func numberOfSections(in _: UITableView) -> Int { rows.count }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { rows[section].count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.section][indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = row.title
        content.image = UIImage(systemName: row.symbol)
        content.imageProperties.tintColor = row.color
        content.textProperties.color = row.isEnabled ? .label : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = row.id
        cell.selectionStyle = row.isEnabled ? .default : .none
        return cell
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == rows.count - 1 else { return nil }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "OpenArc \(version) (\(build))"
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.section][indexPath.row]
        guard row.isEnabled else { return }
        row.action()
    }

    private func showLicenses() {
        guard let url = Bundle.main.url(forResource: "Credits", withExtension: "html") else { return }
        let controller = UIViewController()
        controller.title = String(localized: "Open Source Licenses", table: "Mobile")
        let webView = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }())
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        controller.view = webView
        navigationController?.pushViewController(controller, animated: true)
    }
}
