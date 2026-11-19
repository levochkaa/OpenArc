// BrowserMobileContentBlockingViewController.swift

import Combine
import UIKit

// MARK: - BrowserMobileContentBlockingViewController

/// Global Site Settings: the blocker's switches for every site, its filter
/// lists, and the sites where a list stays out.
final class BrowserMobileContentBlockingViewController: UITableViewController {
    // MARK: Private

    private struct Exception {
        let site: String
        let kinds: [BrowserFilterListKind]
    }

    // MARK: Internal

    var defaults = UserDefaults.standard

    private var switches = [BrowserFilterListKind: UISwitch]()
    private var exceptions = [Exception]()
    private var updaterObservation: AnyCancellable?

    init() {
        super.init(style: .insetGrouped)
        title = String(localized: "Global Site Settings", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "browser.contentBlocking"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Row")
        let settings = BrowserMobileContentBlocking.settings(defaults)
        for kind in BrowserFilterListKind.mobileOrder {
            let toggle = UISwitch()
            toggle.isOn = settings.blocks(kind)
            toggle.accessibilityIdentifier = "browser.contentBlocking.\(kind.rawValue)"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                BrowserMobileContentBlocking.update(defaults) { $0.setBlocks(kind, toggle.isOn) }
                tableView.reloadSections(IndexSet(integer: 1), with: .none)
            }, for: .valueChanged)
            switches[kind] = toggle
        }
        reloadExceptions()
        updaterObservation = BrowserFilterListUpdater.shared
            .changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isViewLoaded else { return }
                    self.tableView.reloadSections(IndexSet(integer: 1), with: .none)
                }
            }
    }

    override func numberOfSections(in _: UITableView) -> Int { exceptions.isEmpty ? 2 : 3 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: BrowserFilterListKind.mobileOrder.count
        case 1: 1
        default: exceptions.count
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 2 ? String(localized: "Sites with Exceptions", table: "Mobile") : nil
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            String(
                localized: "Blocks ads, trackers and cookie consent banners on every site. Turn a list off for one site in its Site Settings.",
                table: "Mobile",
            )
        case 1:
            if BrowserFilterListUpdater.shared.isUpdating {
                String(localized: "Updating filter lists…", table: "Mobile")
            } else if let date = BrowserFilterListUpdater.shared.lastDownloaded {
                String(
                    localized: "Filter lists updated \(date.formatted(.relative(presentation: .named))).",
                    table: "Mobile",
                )
            } else {
                String(localized: "Using the filter lists that came with the app.", table: "Mobile")
            }
        default:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Row", for: indexPath)
        var content = UIListContentConfiguration.cell()
        cell.accessoryView = nil
        cell.accessoryType = .none
        switch indexPath.section {
        case 0:
            let kind = BrowserFilterListKind.mobileOrder[indexPath.row]
            content.text = kind.mobileTitle
            content.image = kind.mobileTile
            cell.accessoryView = switches[kind]
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = nil
        case 1:
            let updater = BrowserFilterListUpdater.shared
            let isEnabled = !updater.isUpdating && BrowserMobileContentBlocking.settings(defaults).isEnabled
            content.text = String(localized: "Update Filter Lists", table: "Mobile")
            content.textProperties.color = isEnabled ? tableView.tintColor : .secondaryLabel
            cell.selectionStyle = isEnabled ? .default : .none
            cell.accessibilityIdentifier = "browser.contentBlocking.update"
        default:
            content = .subtitleCell()
            let exception = exceptions[indexPath.row]
            content.text = exception.site
            content.secondaryText = exception.kinds.count == BrowserFilterListKind.allCases.count
                ? String(localized: "Nothing blocked", table: "Mobile")
                : exception.kinds.map(\.mobileAllowedTitle).joined(separator: ", ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "browser.contentBlocking.site.\(exception.site)"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let updater = BrowserFilterListUpdater.shared
        guard !updater.isUpdating, BrowserMobileContentBlocking.settings(defaults).isEnabled else { return }
        Task { await updater.checkForUpdates(force: true) }
    }

    override func tableView(
        _: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 2 else { return nil }
        let site = exceptions[indexPath.row].site
        let remove = UIContextualAction(
            style: .destructive, title: String(localized: "Block", table: "Mobile"),
        ) { [weak self] _, _, done in
            guard let self else { return done(false) }
            BrowserMobileContentBlocking.update(defaults) { $0.removeAllowedSite(site) }
            let hadSection = !exceptions.isEmpty
            reloadExceptions()
            if exceptions.isEmpty, hadSection {
                tableView.deleteSections(IndexSet(integer: 2), with: .automatic)
            } else {
                tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    /// Each site with a list allowed, and which lists.
    private func reloadExceptions() {
        let settings = BrowserMobileContentBlocking.settings(defaults)
        var kindsBySite = [String: Set<BrowserFilterListKind>]()
        for site in settings.allowedSites {
            kindsBySite[site] = Set(BrowserFilterListKind.allCases)
        }
        for (rawKind, sites) in settings.allowedSitesByKind {
            guard let kind = BrowserFilterListKind(rawValue: rawKind) else { continue }
            for site in sites {
                kindsBySite[site, default: []].insert(kind)
            }
        }
        exceptions = kindsBySite.keys.sorted().map { site in
            Exception(
                site: site,
                kinds: BrowserFilterListKind.mobileOrder.filter { kindsBySite[site]?.contains($0) == true },
            )
        }
    }
}

extension BrowserFilterListKind {
    /// What a site's exception lets through, in the list of exceptions.
    var mobileAllowedTitle: String {
        switch self {
        case .ads: String(localized: "Ads allowed", table: "Mobile")
        case .cookieBanners: String(localized: "Cookie banners allowed", table: "Mobile")
        case .trackers: String(localized: "Trackers allowed", table: "Mobile")
        }
    }
}
