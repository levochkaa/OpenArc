import UIKit

// MARK: - BrowserMobileViewController

/// Scene-owned composition. UIKit handles column collapse as the window resizes.
final class BrowserMobileViewController: UISplitViewController, UISplitViewControllerDelegate {
    // MARK: Lifecycle

    init(workspace: BrowserMobileWorkspace, contentView: UIView) {
        self.workspace = workspace
        self.pageController = BrowserMobilePageViewController(workspace: workspace, contentView: contentView)
        self.tabsController = BrowserMobileTabsViewController(workspace: workspace)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        minimumPrimaryColumnWidth = 240
        maximumPrimaryColumnWidth = 360
        preferredPrimaryColumnWidthFraction = 0.28
        setViewController(UINavigationController(rootViewController: tabsController), for: .primary)
        setViewController(pageController, for: .secondary)
        pageController.showTabs = { [weak self] in self?.showTabList() }
        tabsController.didSelectTab = { [weak self] in
            guard let self else { return }
            if isCollapsed {
                show(.secondary)
            }
        }
        workspace.onChange = { [weak self] in self?.render() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    let workspace: BrowserMobileWorkspace
    let pageController: BrowserMobilePageViewController
    let tabsController: BrowserMobileTabsViewController
    lazy var javaScriptDialogPresenter =
        BrowserMobileJavaScriptDialogPresenter(host: self) { [weak self] id, response in
            self?.workspace.resolveJavaScriptDialog(id: id, response: response)
        }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        render()
    }

    func render() {
        pageController.render()
        tabsController.render()
        presentedTabs?.render()
        javaScriptDialogPresenter.update(workspace.javaScriptDialog)
    }

    func splitViewController(_: UISplitViewController, topColumnForCollapsingToProposedTopColumn _: Column) -> Column {
        .secondary
    }

    // MARK: Private

    private weak var presentedTabs: BrowserMobileTabsViewController?

    private func showTabList() {
        if !isCollapsed {
            if displayMode == .secondaryOnly {
                show(.primary)
            } else {
                hide(.primary)
            }
            return
        }
        guard presentedViewController == nil else { return }
        let controller = BrowserMobileTabsViewController(workspace: workspace)
        controller.didSelectTab = { [weak controller] in controller?.dismiss(animated: true) }
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) }
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        presentedTabs = controller
        present(navigation, animated: true)
    }
}

// MARK: - BrowserMobileTabsViewController

final class BrowserMobileTabsViewController: UITableViewController {
    // MARK: Lifecycle

    init(workspace: BrowserMobileWorkspace) {
        self.workspace = workspace
        super.init(style: .insetGrouped)
        title = String(localized: "Tabs", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    let workspace: BrowserMobileWorkspace
    var didSelectTab: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Tab")
        tableView.accessibilityIdentifier = "browser.tabs"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "New Tab", table: "Mobile"), image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.workspace.newTab()
                self?.didSelectTab?()
            }
        )
        render()
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { workspace.tabs.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Tab", for: indexPath)
        let tab = workspace.tabs[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = tab.title.isEmpty
            ? (tab.urlString == "about:blank"
                ? String(localized: "New Tab", table: "Mobile")
                : URL(string: tab.urlString)?.host ?? tab.urlString)
            : tab.title
        content.secondaryText = tab.urlString == "about:blank" ? nil : tab.urlString
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        content.image = UIImage(systemName: tab.state.error == nil ? "globe" : "exclamationmark.circle")
        cell.contentConfiguration = content
        cell.accessoryType = workspace.selectedTabID == tab.id ? .checkmark : .none
        cell.accessibilityIdentifier = "browser.tab." + tab.id
        cell.accessibilityTraits = workspace.selectedTabID == tab.id ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard workspace.tabs.indices.contains(indexPath.row) else { return }
        workspace.selectTab(id: workspace.tabs[indexPath.row].id)
        didSelectTab?()
    }

    override func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard workspace.tabs.indices.contains(indexPath.row) else { return nil }
        let id = workspace.tabs[indexPath.row].id
        let close = UIContextualAction(style: .destructive, title: String(localized: "Close", table: "Mobile")) {
            [weak self] _, _, completion in
            self?.workspace.closeTab(id: id)
            completion(true)
        }
        close.image = UIImage(systemName: "xmark")
        return UISwipeActionsConfiguration(actions: [close])
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard workspace.tabs.indices.contains(indexPath.row) else { return nil }
        let id = workspace.tabs[indexPath.row].id
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [UIAction(
                title: String(localized: "Close Tab", table: "Mobile"), image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { _ in self?.workspace.closeTab(id: id) }])
        })
    }

    func render() {
        guard isViewLoaded else { return }
        navigationItem.leftBarButtonItem?.isEnabled = workspace.isReady
        tableView.reloadData()
    }
}
