// BrowserMobilePhoneSettingsViewController.swift

import UIKit
import WebKit

// MARK: - BrowserMobileSearchEngineSetting

/// The search engine typed searches go to, kept for the app.
enum BrowserMobileSearchEngineSetting {
    private static let key = "BrowserMobileSettings.searchEngine"

    static func current(_ defaults: UserDefaults = .standard) -> BrowserSearchEngine {
        defaults.string(forKey: key).flatMap(BrowserSearchEngine.init(rawValue:)) ?? .google
    }

    static func set(_ engine: BrowserSearchEngine, defaults: UserDefaults = .standard) {
        defaults.set(engine.rawValue, forKey: key)
    }
}

// MARK: - BrowserMobilePhoneSettingsViewController

/// Settings from the switcher's gear on iPhone and the sidebar's on iPad:
/// Downloads and Archive, the search engine and website data, then the
/// account and the licenses.
final class BrowserMobilePhoneSettingsViewController: UITableViewController {
    // MARK: Private

    private struct Row {
        let title: String
        let symbol: String
        let color: UIColor
        let id: String
        let isEnabled: Bool
        var value: String?
        var opensPage = true
        let action: () -> Void
    }

    // MARK: Internal

    /// Pushes Downloads and Archive here unless the host shows them itself.
    var showDownloads: (() -> Void)?
    var showArchive: (() -> Void)?
    var didRestoreFromArchive: (() -> Void)?
    var defaults = UserDefaults.standard
    var websiteDataStore = WKWebsiteDataStore.default()

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
                    { [weak self] in self?.openDownloads() },
                .init(
                    title: String(localized: "Archive", table: "Mobile"),
                    symbol: "archivebox",
                    color: .systemPurple,
                    id: "browser.settings.archive",
                    isEnabled: workspace.supportsArchive,
                )
                    { [weak self] in self?.openArchive() },
            ],
            [
                .init(
                    title: String(localized: "Search Engine", table: "Mobile"),
                    symbol: "magnifyingglass",
                    color: .systemBlue,
                    id: "browser.settings.searchEngine",
                    isEnabled: true,
                    value: BrowserMobileSearchEngineSetting.current(defaults).title,
                )
                    { [weak self] in self?.showSearchEngines() },
                .init(
                    title: String(localized: "Clear Website Data", table: "Mobile"),
                    symbol: "trash",
                    color: .systemRed,
                    id: "browser.settings.clearWebsiteData",
                    isEnabled: true,
                    opensPage: false,
                )
                    { [weak self] in self?.confirmClearWebsiteData() },
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
        var content = row.value == nil ? UIListContentConfiguration.cell() : .valueCell()
        content.text = row.title
        content.secondaryText = row.value
        content.image = UIImage(systemName: row.symbol)
        content.imageProperties.tintColor = row.color
        content.textProperties.color = row.isEnabled ? .label : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = row.opensPage ? .disclosureIndicator : .none
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The search engine may have changed on its page.
        if let index = rows.indices.first(where: { rows[$0].contains { $0.id == "browser.settings.searchEngine" } }),
           let row = rows[index].firstIndex(where: { $0.id == "browser.settings.searchEngine" })
        {
            rows[index][row].value = BrowserMobileSearchEngineSetting.current(defaults).title
            tableView.reloadRows(at: [IndexPath(row: row, section: index)], with: .none)
        }
    }

    private func openDownloads() {
        if let showDownloads {
            showDownloads()
        } else if let downloads = workspace.downloads {
            navigationController?.pushViewController(
                BrowserMobileDownloadsViewController(downloads: downloads), animated: true,
            )
        }
    }

    private func openArchive() {
        if let showArchive {
            showArchive()
            return
        }
        let archive = BrowserMobileArchiveViewController(workspace: workspace)
        archive.didRestore = { [weak self] in
            self?.dismiss(animated: true)
            self?.didRestoreFromArchive?()
        }
        navigationController?.pushViewController(archive, animated: true)
    }

    private func showSearchEngines() {
        let controller = BrowserMobileSearchEnginesViewController(defaults: defaults)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func confirmClearWebsiteData() {
        let alert = UIAlertController(
            title: String(localized: "Clear Website Data?", table: "Mobile"),
            message: String(
                localized: "This removes cookies, caches and other data websites keep on this device. You will be signed out of websites. Your tabs stay.",
                table: "Mobile",
            ),
            preferredStyle: .actionSheet,
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "Clear Website Data", table: "Mobile"), style: .destructive,
        ) { [weak self] _ in self?.clearWebsiteData() })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        if let index = rows.indices
            .first(where: { rows[$0].contains { $0.id == "browser.settings.clearWebsiteData" } }),
           let row = rows[index].firstIndex(where: { $0.id == "browser.settings.clearWebsiteData" }),
           let cell = tableView.cellForRow(at: IndexPath(row: row, section: index))
        {
            alert.popoverPresentationController?.sourceView = cell
            alert.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(alert, animated: true)
    }

    private func clearWebsiteData() {
        websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
        ) {}
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

// MARK: - BrowserMobileSearchEnginesViewController

/// The search engines to choose from, the chosen one checked.
final class BrowserMobileSearchEnginesViewController: UITableViewController {
    // MARK: Private

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(style: .insetGrouped)
        title = String(localized: "Search Engine", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.searchEngines"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Engine")
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        BrowserSearchEngine.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let engine = BrowserSearchEngine.allCases[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Engine", for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = engine.title
        cell.contentConfiguration = content
        cell.accessoryType = engine == BrowserMobileSearchEngineSetting.current(defaults) ? .checkmark : .none
        cell.accessibilityIdentifier = "browser.searchEngine.\(engine.rawValue)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        BrowserMobileSearchEngineSetting.set(BrowserSearchEngine.allCases[indexPath.row], defaults: defaults)
        for cell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell) else { continue }
            cell.accessoryType = path == indexPath ? .checkmark : .none
        }
    }
}
