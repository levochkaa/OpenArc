// BrowserMobileOpenTabsViewController.swift

import UIKit

// MARK: - BrowserMobileOpenTabsViewController

/// The iPad sidebar: this window's tabs, the mobile tabs every phone and
/// tablet of the account shares, then its private tabs. Spaces sit behind
/// the Spaces button, whose tabs open here as mobile tabs.
final class BrowserMobileOpenTabsViewController: UITableViewController {
    /// Keyboard focus can rest on the sidebar; page commands still reach the page.
    override var canBecomeFirstResponder: Bool { true }

    // MARK: Internal

    let workspace: BrowserMobileWorkspace
    var didSelectTab: (() -> Void)?

    // MARK: Private

    private var tabIDs = [String]()
    private lazy var spacesButton = UIBarButtonItem(
        title: String(localized: "Spaces", table: "Mobile"), image: UIImage(systemName: "square.stack"),
        primaryAction: UIAction { [weak self] _ in self?.showSpaces() },
    )
    private lazy var archiveButton = UIBarButtonItem(
        title: String(localized: "Archive", table: "Mobile"), image: UIImage(systemName: "archivebox"),
        primaryAction: UIAction { [weak self] _ in self?.showArchive() },
    )
    private lazy var settingsButton = UIBarButtonItem(
        title: String(localized: "Settings", table: "Mobile"), image: UIImage(systemName: "gearshape"),
        primaryAction: UIAction { [weak self] _ in self?.showSettings() },
    )
    private weak var presentedSpaces: BrowserMobileTabsViewController?
    private weak var presentedArchive: BrowserMobileArchiveViewController?

    init(workspace: BrowserMobileWorkspace) {
        self.workspace = workspace
        super.init(style: .insetGrouped)
        title = String(localized: "Tabs", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Tab")
        tableView.accessibilityIdentifier = "browser.openTabs"
        tableView.estimatedRowHeight = 60
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "New Tab", table: "Mobile"), image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.workspace.newTab()
                self?.didSelectTab?()
            },
        )
        spacesButton.accessibilityIdentifier = "browser.spaces"
        archiveButton.accessibilityIdentifier = "browser.archive"
        settingsButton.accessibilityIdentifier = "browser.settings"
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshVisibleRows), name: BrowserMobileFavicons.didChange, object: nil,
        )
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.refreshVisibleRows()
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func numberOfSections(in _: UITableView) -> Int { 1 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { tabIDs.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Tab", for: indexPath)
        configure(cell, id: tabIDs[indexPath.row])
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard tabIDs.indices.contains(indexPath.row) else { return }
        workspace.selectTab(id: tabIDs[indexPath.row])
        didSelectTab?()
    }

    override func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard workspace.isReady, tabIDs.indices.contains(indexPath.row) else { return nil }
        let id = tabIDs[indexPath.row]
        let close = UIContextualAction(style: .destructive, title: String(localized: "Close", table: "Mobile")) {
            [weak self] _, _, completion in
            guard let self else { return completion(false) }
            workspace.closeTab(id: id)
            completion(!workspace.tabs.contains { $0.id == id })
        }
        close.image = UIImage(systemName: "xmark")
        return UISwipeActionsConfiguration(actions: [close])
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard tabIDs.indices.contains(indexPath.row) else { return nil }
        let id = tabIDs[indexPath.row]
        workspace.dismissFindInPage()
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.menu(id: id) })
    }

    private static func title(_ tab: BrowserMobileTab) -> String {
        if let title = tab.userTitleOverride, !title.isEmpty { return title }
        if !tab.title.isEmpty { return tab.title }
        return tab.urlString == "about:blank"
            ? String(localized: "New Tab", table: "Mobile")
            : URL(string: tab.urlString)?.host ?? tab.urlString
    }

    func render() {
        guard isViewLoaded else { return }
        presentedSpaces?.render()
        presentedArchive?.render()
        navigationItem.leftBarButtonItem?.isEnabled = workspace.isReady
        let ids = workspace.tabs.map(\.id)
        if ids != tabIDs {
            tabIDs = ids
            tableView.reloadData()
        } else {
            refreshVisibleRows()
        }
        var items = [UIBarButtonItem]()
        if workspace.supportsArchive {
            archiveButton.isEnabled = workspace.isReady
            items += [archiveButton, .flexibleSpace()]
        }
        if workspace.profileDocument != nil {
            spacesButton.isEnabled = workspace.isReady
            items += [spacesButton, .flexibleSpace()]
        }
        items.append(settingsButton)
        if items.count == 1 {
            items.insert(.flexibleSpace(), at: 0)
        }
        setToolbarItems(items, animated: false)
    }

    /// The Spaces of the account's computers; a tab chosen there opens here.
    func showSpaces() {
        guard workspace.profileDocument != nil, presentedViewController == nil else { return }
        workspace.dismissFindInPage()
        let controller = BrowserMobileTabsViewController(workspace: workspace)
        controller.title = String(localized: "Spaces", table: "Mobile")
        controller.didSelectTab = { [weak self, weak controller] in
            controller?.dismiss(animated: true)
            self?.didSelectTab?()
        }
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) },
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.sourceItem = spacesButton
        navigation.preferredContentSize = CGSize(width: 375, height: 640)
        presentedSpaces = controller
        present(navigation, animated: true)
    }

    @objc private func refreshVisibleRows() {
        guard isViewLoaded else { return }
        for index in tableView.indexPathsForVisibleRows ?? [] where tabIDs.indices.contains(index.row) {
            if let cell = tableView.cellForRow(at: index) {
                configure(cell, id: tabIDs[index.row])
            }
        }
    }

    private func configure(_ cell: UITableViewCell, id: String) {
        guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return }
        var content = cell.defaultContentConfiguration()
        content.text = Self.title(tab)
        let site = BrowserMobilePageViewController.displayAddress(tab.urlString)
        content.secondaryText = site.isEmpty ? nil : site
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        let favicons = BrowserMobileFavicons.shared
        let icon = traitCollection.userInterfaceStyle == .dark
            ? favicons.iconOnDark(forPage: tab.urlString)
            : favicons.icon(forPage: tab.urlString)
        if tab.isPrivate {
            content.image = UIImage(systemName: "eyeglasses")
        } else if tab.state.error == nil, let icon {
            content.image = icon
            content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
            content.imageProperties.cornerRadius = 4
        } else {
            content.image = UIImage(systemName: tab.state.error == nil ? "globe" : "exclamationmark.circle")
        }
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
        cell.contentConfiguration = content
        let selected = workspace.selectedTabID == id
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityIdentifier = "browser.tab." + id
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }

    private func menu(id: String) -> UIMenu? {
        guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return nil }
        var actions = [UIMenuElement]()
        if let url = URL(string: tab.urlString), tab.urlString != "about:blank" {
            actions.append(UIAction(
                title: String(localized: "Copy Link", table: "Mobile"), image: UIImage(systemName: "link"),
            ) { _ in UIPasteboard.general.url = url })
        }
        actions.append(UIAction(
            title: String(localized: "Close Tab", table: "Mobile"), image: UIImage(systemName: "xmark"),
            attributes: .destructive,
        ) { [weak self] _ in self?.workspace.closeTab(id: id) })
        return UIMenu(children: actions)
    }

    private func showArchive() {
        guard workspace.supportsArchive, presentedViewController == nil else { return }
        workspace.dismissFindInPage()
        let controller = BrowserMobileArchiveViewController(workspace: workspace)
        controller.didRestore = { [weak self] in self?.didSelectTab?() }
        presentedArchive = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        workspace.dismissFindInPage()
        let controller = BrowserMobilePhoneSettingsViewController(workspace: workspace)
        controller.didRestoreFromArchive = { [weak self] in self?.didSelectTab?() }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }
}
