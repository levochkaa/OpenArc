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

// MARK: - BrowserMobileAutoOpenKeyboardSetting

/// Whether a launch opens the search field with its keyboard up, over the last tab.
enum BrowserMobileAutoOpenKeyboardSetting {
    private static let key = "BrowserMobileSettings.autoOpenKeyboard"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

// MARK: - BrowserMobileAppLinksSetting

/// Whether a tapped link to another site opens in the app that claims it
/// (a universal link) instead of the tab.
enum BrowserMobileAppLinksSetting {
    private static let key = "BrowserMobileSettings.opensAppLinksInApps"

    static func opensInApps(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ inApps: Bool, defaults: UserDefaults = .standard) {
        defaults.set(inApps, forKey: key)
    }

    /// A tap on a web link that leaves the page's site; navigation within a
    /// site, typed addresses and redirects stay in the tab.
    static func mayOpenInApp(_ url: URL?, from page: URL?, isLinkTap: Bool, isMainFrame: Bool) -> Bool {
        guard isLinkTap, isMainFrame, let url, url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return false }
        let pageHost = page?.host()?.lowercased()
        return host != pageHost
    }
}

/// Settings from the switcher's gear on iPhone and the sidebar's on iPad:
/// Downloads and Archive, the blocker, the search engine and website data,
/// then the account and the licenses.
// MARK: - BrowserMobileDefaultBrowser

/// OpenArc as the system's default browser, which needs Apple's
/// `com.apple.developer.web-browser` entitlement; `OPENARC_DEFAULT_BROWSER`
/// says the build has it.
enum BrowserMobileDefaultBrowser {
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "OpenArcDefaultBrowser") as? String == "YES"
    }

    /// Whether OpenArc opens the web links of other apps. The system limits how
    /// often an app may ask; a refused check reads as no.
    @MainActor static func isDefault() -> Bool {
        (try? UIApplication.shared.isDefault(.webBrowser)) ?? false
    }

    @MainActor static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - BrowserMobilePhoneSettingsViewController

final class BrowserMobilePhoneSettingsViewController: UITableViewController {
    // MARK: Private

    private struct Row {
        let title: String
        var subtitle: String?
        let symbol: String
        let color: UIColor
        let id: String
        let isEnabled: Bool
        var value: String?
        var opensPage = true
        var toggle: UISwitch?
        /// A row that opens this menu where the finger lifts instead of acting.
        var menu: (() -> UIMenu)?
        let action: () -> Void
    }

    private static let defaultBrowserRowID = "browser.settings.defaultBrowser"
    private static let archivalRowID = "browser.settings.archiveInactiveTabs"
    private static let exportRowID = "browser.settings.exportData"
    private static let appLinksRowID = "browser.settings.appLinks"
    private static let menuButtonTag = 0x0A4C

    // MARK: Internal

    /// Pushes Downloads and Archive here unless the host shows them itself.
    var showDownloads: (() -> Void)?
    var showArchive: (() -> Void)?
    var didRestoreFromArchive: (() -> Void)?
    /// A link from Settings opened in a new tab, which is now the selected one.
    var didOpenTab: (() -> Void)?
    var defaults = UserDefaults.standard
    var websiteDataStore = WKWebsiteDataStore.default()

    private let workspace: BrowserMobileWorkspace
    private var rows = [[Row]]()

    private var archivalLifetime: BrowserTemporaryTabLifetime? {
        workspace.automaticTabArchivalEnabled ? workspace.temporaryTabLifetime : nil
    }

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MenuRow")
        tableView.rowHeight = 52
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done", table: "Mobile"), style: .plain,
            target: self, action: #selector(close),
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "browser.settings.done"
        tableView.tableHeaderView = makeShortcuts()
        rows = [
            [
                .init(
                    title: String(localized: "Global Site Settings", table: "Mobile"),
                    symbol: "hand.raised.fill",
                    color: .systemRed,
                    id: "browser.settings.globalSiteSettings",
                    isEnabled: true,
                ) { [weak self] in
                    guard let self else { return }
                    let controller = BrowserMobileContentBlockingViewController()
                    controller.defaults = defaults
                    navigationController?.pushViewController(controller, animated: true)
                },
                .init(
                    title: String(localized: "Extensions", table: "Mobile"),
                    symbol: "puzzlepiece.extension.fill",
                    color: .systemTeal,
                    id: "browser.settings.extensions",
                    isEnabled: true,
                ) { [weak self] in self?.showExtensions(animated: true) },
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
                    title: String(localized: "Auto-Open Keyboard", table: "Mobile"),
                    symbol: "keyboard.fill",
                    color: .systemYellow,
                    id: "browser.settings.autoOpenKeyboard",
                    isEnabled: true,
                    opensPage: false,
                    toggle: autoOpenSwitch(),
                ) {},
            ] + archivalRows() + [
                appLinksRow(),
                .init(
                    title: String(localized: "Clear Website Data", table: "Mobile"),
                    symbol: "trash.fill",
                    color: .systemRed,
                    id: "browser.settings.clearWebsiteData",
                    isEnabled: true,
                    opensPage: false,
                )
                    { [weak self] in self?.confirmClearWebsiteData() },
                .init(
                    title: String(localized: "Export Data", table: "Mobile"),
                    subtitle: String(localized: "Share your open tab URLs", table: "Mobile"),
                    symbol: "square.and.arrow.up",
                    color: .systemBlue,
                    id: Self.exportRowID,
                    isEnabled: true,
                    opensPage: false,
                )
                    { [weak self] in self?.exportTabURLs() },
            ],
        ]
        if BrowserMobileDefaultBrowser.isAvailable {
            rows.insert([
                .init(
                    title: String(localized: "Default Browser", table: "Mobile"),
                    symbol: "safari.fill",
                    color: .systemBlue,
                    id: Self.defaultBrowserRowID,
                    isEnabled: true,
                    value: BrowserMobileDefaultBrowser.isDefault() ? "OpenArc" : nil,
                ) { BrowserMobileDefaultBrowser.openSystemSettings() },
            ], at: 0)
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshDefaultBrowser),
                name: UIApplication.didBecomeActiveNotification, object: nil,
            )
        }
        if let session = workspace.syncSession {
            rows.append([
                .init(
                    title: String(localized: "Account", table: "Mobile"),
                    symbol: "person.crop.circle.fill",
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
                symbol: "doc.text.fill",
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
        let cell = tableView.dequeueReusableCell(withIdentifier: row.menu == nil ? "Row" : "MenuRow", for: indexPath)
        var content = row.subtitle != nil
            ? UIListContentConfiguration.subtitleCell()
            : row.value == nil ? .cell() : .valueCell()
        content.text = row.title
        content.secondaryText = row.subtitle ?? row.value
        if row.subtitle != nil {
            content.secondaryTextProperties.color = .secondaryLabel
        }
        content.image = Self.tile(symbol: row.symbol, color: row.isEnabled ? row.color : .systemGray)
        content.textProperties.color = row.isEnabled ? .label : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = row.opensPage ? .disclosureIndicator : .none
        cell.accessoryView = row.toggle
        cell.accessibilityIdentifier = row.id
        cell.selectionStyle = row.isEnabled && row.toggle == nil && row.menu == nil ? .default : .none
        if let menu = row.menu {
            let button = cell.contentView.viewWithTag(Self.menuButtonTag) as? UIButton ?? {
                let button = UIButton(type: .system)
                button.tag = Self.menuButtonTag
                button.showsMenuAsPrimaryAction = true
                button.frame = cell.contentView.bounds
                button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cell.contentView.addSubview(button)
                return button
            }()
            button.menu = menu()
            button.isEnabled = row.isEnabled
            button.accessibilityLabel = row.title
            button.accessibilityValue = row.value
        }
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
        refreshDefaultBrowser()
        // Archive's own page sets the same timing.
        refreshArchival()
        // The search engine may have changed on its page.
        if let index = rows.indices.first(where: { rows[$0].contains { $0.id == "browser.settings.searchEngine" } }),
           let row = rows[index].firstIndex(where: { $0.id == "browser.settings.searchEngine" })
        {
            rows[index][row].value = BrowserMobileSearchEngineSetting.current(defaults).title
            tableView.reloadRows(at: [IndexPath(row: row, section: index)], with: .none)
        }
    }

    /// Shares the open tabs' addresses through the share sheet.
    /// The tabs' addresses, one per line, leaving out private and blank tabs.
    static func exportedURLs(_ tabs: [BrowserMobileTab]) -> String? {
        let urls = tabs.filter { !$0.isPrivate }.map(\.urlString).filter { !$0.isEmpty && $0 != "about:blank" }
        return urls.isEmpty ? nil : urls.joined(separator: "\n")
    }

    /// A white symbol on a rounded square of the row's color.
    private static func tile(symbol: String, color: UIColor) -> UIImage {
        let side: CGFloat = 29
        let glyph = UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium),
        )?.withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 7).fill()
            guard let glyph else { return }
            let scale = min(1, 19 / max(glyph.size.width, glyph.size.height))
            let size = CGSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            glyph.draw(in: CGRect(
                x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height,
            ))
        }
    }

    private static func archivalTitle(_ lifetime: BrowserTemporaryTabLifetime?) -> String {
        switch lifetime {
        case nil: String(localized: "Off", table: "Mobile")
        case .twelveHours: String(localized: "After 12 Hours", table: "Mobile")
        case .twentyFourHours: String(localized: "After 1 Day", table: "Mobile")
        case .threeDays: String(localized: "After 3 Days", table: "Mobile")
        case .sevenDays: String(localized: "After 7 Days", table: "Mobile")
        case .thirtyDays: String(localized: "After 30 Days", table: "Mobile")
        }
    }

    private static func appLinksTitle(inApps: Bool) -> String {
        inApps ? String(localized: "Native App", table: "Mobile") : "OpenArc"
    }

    /// Settings › Extensions; a store link closes Settings and opens in a new tab.
    func showExtensions(animated: Bool) {
        let controller = BrowserMobileExtensionsViewController()
        controller.openURL = { [weak self] url in
            guard let self else { return }
            let workspace = workspace
            let opened = didOpenTab
            dismiss(animated: true) {
                workspace.openLinkInNewTab(url, inBackground: false)
                opened?()
            }
        }
        navigationController?.pushViewController(controller, animated: animated)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    /// How long a Today tab stays open before Archive takes it, picked from a
    /// menu in place.
    private func archivalRows() -> [Row] {
        guard workspace.supportsArchive else { return [] }
        return [.init(
            title: String(localized: "Archive Inactive Tabs", table: "Mobile"),
            symbol: "archivebox.fill",
            color: .systemPurple,
            id: Self.archivalRowID,
            isEnabled: workspace.canConfigureAutomaticTabArchival,
            value: Self.archivalTitle(archivalLifetime),
            opensPage: false,
            menu: { [weak self] in self?.archivalMenu() ?? UIMenu(children: []) },
        ) {}]
    }

    private func archivalMenu() -> UIMenu {
        let current = archivalLifetime
        let choices: [BrowserTemporaryTabLifetime?] = [nil] + BrowserTemporaryTabLifetime.allCases
        return UIMenu(children: choices.map { lifetime in
            UIAction(
                title: Self.archivalTitle(lifetime),
                identifier: .init("browser.settings.archiveInactiveTabs." + (lifetime?.rawValue ?? "off")),
                state: lifetime == current ? .on : .off,
            ) { [weak self] _ in
                guard let self else { return }
                workspace.setAutomaticTabArchival(lifetime: lifetime)
                refreshArchival()
            }
        })
    }

    /// Where a tapped link to a site with its own app opens, picked in place.
    private func appLinksRow() -> Row {
        .init(
            title: String(localized: "Open App Links in…", table: "Mobile"),
            symbol: "arrow.up.forward.app.fill",
            color: .systemBlue,
            id: Self.appLinksRowID,
            isEnabled: true,
            value: Self.appLinksTitle(inApps: BrowserMobileAppLinksSetting.opensInApps(defaults)),
            opensPage: false,
            menu: { [weak self] in self?.appLinksMenu() ?? UIMenu(children: []) },
        ) {}
    }

    private func appLinksMenu() -> UIMenu {
        let current = BrowserMobileAppLinksSetting.opensInApps(defaults)
        return UIMenu(children: [true, false].map { inApps in
            UIAction(
                title: Self.appLinksTitle(inApps: inApps),
                identifier: .init("browser.settings.appLinks." + (inApps ? "app" : "browser")),
                state: inApps == current ? .on : .off,
            ) { [weak self] _ in
                guard let self else { return }
                BrowserMobileAppLinksSetting.set(inApps, defaults: defaults)
                updateValue(Self.appLinksTitle(inApps: inApps), ofRow: Self.appLinksRowID)
            }
        })
    }

    private func updateValue(_ value: String, ofRow id: String) {
        guard let section = rows.firstIndex(where: { $0.contains { $0.id == id } }),
              let row = rows[section].firstIndex(where: { $0.id == id }),
              rows[section][row].value != value else { return }
        rows[section][row].value = value
        if isViewLoaded {
            tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
        }
    }

    private func refreshArchival() {
        updateValue(Self.archivalTitle(archivalLifetime), ofRow: Self.archivalRowID)
    }

    /// Downloads and Archive side by side above the list.
    private func makeShortcuts() -> UIView {
        func button(_ title: String, _ symbol: String, _ id: String, enabled: Bool, _ action: @escaping () -> Void)
            -> UIButton
        {
            // A press dims the title and glyph while the capsule keeps its fill.
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(
                systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium),
            )
            configuration.imagePadding = 8
            configuration.background.backgroundColor = .secondarySystemGroupedBackground
            configuration.baseForegroundColor = .label
            configuration.cornerStyle = .capsule
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
            button.configurationUpdateHandler = { button in
                button.configuration?.baseForegroundColor = button.isHighlighted ? .tertiaryLabel : .label
            }
            button.isEnabled = enabled
            button.accessibilityIdentifier = id
            return button
        }
        let stack = UIStackView(arrangedSubviews: [
            button(
                String(localized: "Downloads", table: "Mobile"), "folder", "browser.settings.downloads",
                enabled: workspace.downloads != nil,
            ) { [weak self] in self?.openDownloads() },
            button(
                String(localized: "Archive", table: "Mobile"), "archivebox", "browser.settings.archive",
                enabled: workspace.supportsArchive,
            ) { [weak self] in self?.openArchive() },
        ])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 72))
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: header.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            stack.heightAnchor.constraint(equalToConstant: 40),
        ])
        header.preservesSuperviewLayoutMargins = true
        return header
    }

    /// The system's Default Apps page is where OpenArc becomes the browser;
    /// coming back from it shows whether it did.
    @objc private func refreshDefaultBrowser() {
        guard let section = rows.indices.first(where: { rows[$0].contains { $0.id == Self.defaultBrowserRowID } }),
              let row = rows[section].firstIndex(where: { $0.id == Self.defaultBrowserRowID })
        else { return }
        let value: String? = BrowserMobileDefaultBrowser.isDefault() ? "OpenArc" : nil
        guard rows[section][row].value != value else { return }
        rows[section][row].value = value
        tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
    }

    private func autoOpenSwitch() -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = BrowserMobileAutoOpenKeyboardSetting.isOn(defaults)
        toggle.accessibilityIdentifier = "browser.settings.autoOpenKeyboard.switch"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            BrowserMobileAutoOpenKeyboardSetting.set(toggle.isOn, defaults: defaults)
        }, for: .valueChanged)
        return toggle
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

    private func exportTabURLs() {
        guard let text = Self.exportedURLs(workspace.tabs) else { return }
        let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let index = rows.indices.first(where: { rows[$0].contains { $0.id == Self.exportRowID } }),
           let row = rows[index].firstIndex(where: { $0.id == Self.exportRowID }),
           let cell = tableView.cellForRow(at: IndexPath(row: row, section: index))
        {
            share.popoverPresentationController?.sourceView = cell
            share.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(share, animated: true)
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
