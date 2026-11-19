// BrowserMobileExtensionsViewController.swift

import Combine
import UIKit
import WebKit

// MARK: - BrowserMobileExtensionsViewController

/// Settings › Extensions: the installed extensions with their source and
/// state, where to get more, and an update check.
final class BrowserMobileExtensionsViewController: UITableViewController {
    // MARK: Internal

    /// Opens a store page in a tab.
    var openURL: ((URL) -> Void)?

    // MARK: Private

    private let extensions: BrowserMobileExtensions
    private var records = [BrowserWebExtensionRecord]()
    private var observation: AnyCancellable?
    private var isChecking = false

    init(extensions: BrowserMobileExtensions = .shared) {
        self.extensions = extensions
        super.init(style: .insetGrouped)
        title = String(localized: "Extensions", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.extensionsList"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        observation = extensions.changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.reload() }
        reload()
    }

    override func numberOfSections(in _: UITableView) -> Int { 3 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: max(records.count, 1)
        case 1: 2
        default: 1
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: String(localized: "Installed", table: "Mobile")
        case 1: String(localized: "Get Extensions", table: "Mobile")
        default: nil
        }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 1:
            String(
                localized: "Open an extension’s page and tap Add to OpenArc. Firefox add-ons run their standard features only.",
                table: "Mobile",
            )
        case 2:
            String(localized: "Extensions also update about once a day when OpenArc opens.", table: "Mobile")
        default:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch (indexPath.section, records.isEmpty) {
        case (0, true):
            content = .cell()
            content.text = String(localized: "No Extensions", table: "Mobile")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case (0, false):
            let record = records[indexPath.row]
            content.text = record.name
            var details = [record.sourceLabel, record.version]
            if record.isPartiallyCompatible {
                details.append(String(localized: "Partially compatible", table: "Mobile"))
            }
            if extensions.library.loadErrors[record.id] != nil {
                details.append(String(localized: "Failed to load", table: "Mobile"))
            } else if !record.isEnabled {
                details.append(String(localized: "Off", table: "Mobile"))
            }
            content.secondaryText = details.filter { !$0.isEmpty }.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = icon(for: record)
            content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
            content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
            content.textProperties.color = record.isEnabled ? .label : .secondaryLabel
            cell.accessibilityIdentifier = "browser.extension.\(record.id)"
        case (1, _):
            content = .cell()
            content.text = indexPath.row == 0
                ? String(localized: "Chrome Web Store", table: "Mobile")
                : String(localized: "Firefox Add-ons", table: "Mobile")
            content.image = UIImage(systemName: "bag")
            cell.accessibilityIdentifier = indexPath.row == 0
                ? "browser.extensions.chrome"
                : "browser.extensions.firefox"
        default:
            content = .cell()
            content.text = isChecking
                ? String(localized: "Checking for Updates…", table: "Mobile")
                : String(localized: "Check for Updates", table: "Mobile")
            content.textProperties.color = isChecking ? .secondaryLabel : .tintColor
            cell.accessoryType = .none
            cell.accessibilityIdentifier = "browser.extensions.update"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            guard records.indices.contains(indexPath.row) else { return }
            navigationController?.pushViewController(
                BrowserMobileExtensionDetailViewController(id: records[indexPath.row].id, extensions: extensions),
                animated: true,
            )
        case 1:
            let url = URL(string: indexPath.row == 0
                ? "https://chromewebstore.google.com/"
                : "https://addons.mozilla.org/android/")!
            if let openURL {
                openURL(url)
            }
        default:
            checkForUpdates()
        }
    }

    private func reload() {
        records = extensions.library.records.filter { $0.source != .chromiumProfile }
        tableView.reloadData()
    }

    private func icon(for record: BrowserWebExtensionRecord) -> UIImage? {
        extensions.library.context(id: record.id)?.webExtension.icon(for: CGSize(width: 32, height: 32))
            ?? UIImage(systemName: "puzzlepiece.extension")
    }

    private func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        tableView.reloadSections(IndexSet(integer: 2), with: .none)
        Task {
            let updated = await extensions.library.checkForUpdates(force: true)
            isChecking = false
            reload()
            let alert = UIAlertController(
                title: updated.isEmpty
                    ? String(localized: "Extensions Are Up to Date", table: "Mobile")
                    : String(localized: "Updated \(updated.count) Extensions", table: "Mobile"),
                message: nil, preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK", table: "Mobile"), style: .default))
            present(alert, animated: true)
        }
    }
}

// MARK: - BrowserMobileExtensionDetailViewController

/// One extension: on or off, where it runs, private browsing, options,
/// what it cannot do here, and Remove.
final class BrowserMobileExtensionDetailViewController: UITableViewController {
    // MARK: Private

    private enum Row {
        case enabled
        case source
        case version
        case error(String)
        case allSites
        case selectedSites
        case site(String)
        case addSite
        case privateBrowsing
        case options
        case unsupported(String)
        case remove
    }

    private let id: String
    private let extensions: BrowserMobileExtensions
    private var sections = [(title: String?, footer: String?, rows: [Row])]()
    private var observation: AnyCancellable?
    private let enabledSwitch = UISwitch()
    private let privateSwitch = UISwitch()

    private var record: BrowserWebExtensionRecord? { extensions.library.record(id: id) }

    init(id: String, extensions: BrowserMobileExtensions) {
        self.id = id
        self.extensions = extensions
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.extensionDetail"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        enabledSwitch.accessibilityIdentifier = "browser.extensionDetail.enabled"
        enabledSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let isOn = enabledSwitch.isOn
            Task { await self.extensions.library.setEnabled(id: self.id, isOn) }
        }, for: .valueChanged)
        privateSwitch.accessibilityIdentifier = "browser.extensionDetail.private"
        privateSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            extensions.library.setAllowsPrivateBrowsing(id: id, privateSwitch.isOn)
        }, for: .valueChanged)
        observation = extensions.changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.reload() }
        reload()
    }

    override func numberOfSections(in _: UITableView) -> Int { sections.count }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        let record = record
        switch sections[indexPath.section].rows[indexPath.row] {
        case .enabled:
            content.text = String(localized: "Enabled", table: "Mobile")
            enabledSwitch.isOn = record?.isEnabled == true
            cell.accessoryView = enabledSwitch
            cell.selectionStyle = .none
        case .source:
            content.text = String(localized: "Source", table: "Mobile")
            content.secondaryText = record?.isPartiallyCompatible == true
                ? String(localized: "Firefox · Partially compatible", table: "Mobile")
                : record?.sourceLabel
            cell.selectionStyle = .none
        case .version:
            content.text = String(localized: "Version", table: "Mobile")
            content.secondaryText = record?.version
            cell.selectionStyle = .none
        case .error(let message):
            content = .cell()
            content.text = message
            content.textProperties.color = .systemRed
            content.textProperties.numberOfLines = 0
            cell.selectionStyle = .none
        case .allSites:
            content = .cell()
            content.text = String(localized: "All Requested Sites", table: "Mobile")
            cell.accessoryType = record?.siteAccess == .requested ? .checkmark : .none
            cell.accessibilityIdentifier = "browser.extensionDetail.allSites"
        case .selectedSites:
            content = .cell()
            content.text = String(localized: "Only Selected Sites", table: "Mobile")
            if case .sites = record?.siteAccess { cell.accessoryType = .checkmark }
            cell.accessibilityIdentifier = "browser.extensionDetail.selectedSites"
        case .site(let host):
            content = .cell()
            content.text = host
            content.image = UIImage(systemName: "globe")
            cell.selectionStyle = .none
        case .addSite:
            content = .cell()
            content.text = String(localized: "Add Site…", table: "Mobile")
            content.textProperties.color = .tintColor
        case .privateBrowsing:
            content.text = String(localized: "Allow in Private Browsing", table: "Mobile")
            privateSwitch.isOn = record?.allowsPrivateBrowsing == true
            cell.accessoryView = privateSwitch
            cell.selectionStyle = .none
        case .options:
            content = .cell()
            content.text = String(localized: "Extension Options", table: "Mobile")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "browser.extensionDetail.options"
        case .unsupported(let feature):
            content = .cell()
            content.text = feature
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case .remove:
            content = .cell()
            content.text = String(localized: "Remove Extension", table: "Mobile")
            content.textProperties.color = .systemRed
            cell.accessibilityIdentifier = "browser.extensionDetail.remove"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .allSites:
            extensions.library.setSiteAccess(id: id, .requested)
        case .selectedSites:
            if case .sites = record?.siteAccess { return }
            extensions.library.setSiteAccess(id: id, .sites([]))
        case .addSite:
            addSite()
        case .options:
            extensions.showOptions(id: id, from: self)
        case .remove:
            confirmRemove(from: tableView.cellForRow(at: indexPath))
        default:
            break
        }
    }

    override func tableView(
        _: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case .site(let host) = sections[indexPath.section].rows[indexPath.row],
              case .sites(let hosts) = record?.siteAccess else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Remove", table: "Mobile")) {
            [weak self] _, _, done in
            guard let self else { return done(false) }
            extensions.library.setSiteAccess(id: id, .sites(hosts.filter { $0 != host }))
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    /// The host of what the user typed: an address or a bare domain.
    static func host(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URL(string: candidate)?.host(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func reload() {
        guard let record else {
            if navigationController?.topViewController === self {
                navigationController?.popViewController(animated: true)
            }
            return
        }
        title = record.name
        var info: [Row] = [.enabled, .source, .version]
        if let error = extensions.library.loadErrors[id] { info.append(.error(error)) }
        var access: [Row] = [.allSites, .selectedSites]
        if case .sites(let hosts) = record.siteAccess {
            access += hosts.map(Row.site) + [.addSite]
        }
        sections = [
            (nil, nil, info),
            (
                String(localized: "Site Access", table: "Mobile"),
                String(
                    localized: "Content scripts and blocking run only on the sites the extension may access.",
                    table: "Mobile",
                ),
                access,
            ),
            (
                nil,
                String(
                    localized: "Private pages keep no history or website data. An extension allowed there can still see them.",
                    table: "Mobile",
                ),
                [.privateBrowsing],
            ),
        ]
        if extensions.library.context(id: id)?.optionsPageURL != nil {
            sections.append((nil, nil, [.options]))
        }
        if !record.unsupportedFeatures.isEmpty {
            sections.append((
                String(localized: "Not Supported Here", table: "Mobile"),
                record.isPartiallyCompatible
                    ? String(
                        localized: "Written for Firefox. WebKit runs its standard extension features.",
                        table: "Mobile",
                    )
                    : nil,
                record.unsupportedFeatures.map(Row.unsupported),
            ))
        }
        sections.append((nil, nil, [.remove]))
        tableView.reloadData()
    }

    private func addSite() {
        let alert = UIAlertController(
            title: String(localized: "Add Site", table: "Mobile"),
            message: String(localized: "The extension runs on this site and its subdomains.", table: "Mobile"),
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Add", table: "Mobile"), style: .default) {
            [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text,
                  let host = Self.host(from: text), case .sites(let hosts) = record?.siteAccess else { return }
            extensions.library.setSiteAccess(id: id, .sites(Array(Set(hosts + [host])).sorted()))
        })
        present(alert, animated: true)
    }

    private func confirmRemove(from cell: UIView?) {
        let name = record?.name ?? ""
        let sheet = UIAlertController(
            title: String(localized: "Remove “\(name)”?", table: "Mobile"),
            message: String(localized: "Its settings and data on this device are deleted.", table: "Mobile"),
            preferredStyle: .actionSheet,
        )
        sheet.addAction(UIAlertAction(
            title: String(localized: "Remove Extension", table: "Mobile"),
            style: .destructive,
        ) {
            [weak self] _ in
            guard let self else { return }
            extensions.library.remove(id: id)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        sheet.popoverPresentationController?.sourceRect = cell?.bounds ?? view.bounds
        present(sheet, animated: true)
    }
}
