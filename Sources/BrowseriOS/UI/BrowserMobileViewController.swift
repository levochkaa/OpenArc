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
        spaceButton.showsMenuAsPrimaryAction = true
        spaceButton.accessibilityIdentifier = "browser.spaces"
        spaceButton.titleLabel?.lineBreakMode = .byTruncatingTail
        spaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spaceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        render()
    }

    override func numberOfSections(in _: UITableView) -> Int { rows.count }
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.indices.contains(section) ? rows[section].count : 0
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard workspace.profileDocument != nil else { return nil }
        switch section {
        case 0: return String(localized: "Favorites", table: "Mobile")
        case 1: return String(localized: "Pinned", table: "Mobile")
        case 2: return String(localized: "Today", table: "Mobile")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Tab", for: indexPath)
        cell.accessoryType = .none
        cell.accessibilityTraits = [.button]
        cell.accessibilityIdentifier = nil
        cell.accessibilityValue = nil
        cell.indentationWidth = 16
        cell.indentationLevel = 0
        cell.contentConfiguration = nil
        var content = cell.defaultContentConfiguration()
        switch row(at: indexPath) {
        case .tab(let id, let depth):
            guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return cell }
            content.text = displayTitle(tab)
            content.secondaryText = tab.urlString == "about:blank" ? nil : tab.urlString
            content.secondaryTextProperties.numberOfLines = 1
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            content.image = UIImage(systemName: tab.state.error == nil ? "globe" : "exclamationmark.circle")
            cell.indentationLevel = depth
            cell.accessoryType = workspace.selectedTabID == id ? .checkmark : .none
            cell.accessibilityIdentifier = "browser.tab." + id
            cell.accessibilityTraits = workspace.selectedTabID == id ? [.button, .selected] : [.button]
        case .folder(let id, let depth):
            guard let folder = workspace.profileDocument?.snapshot.pinnedTabFolders?.first(where: { $0.id == id })
            else { return cell }
            content.text = folder.title
            content
                .image = UIImage(systemName: folder.systemImageName ?? (folder.isExpanded ? "folder.fill" : "folder"))
            cell.indentationLevel = depth
            cell.accessoryType = folder.isExpanded ? .none : .disclosureIndicator
            cell.accessibilityIdentifier = "browser.folder." + id
            cell.accessibilityValue = folder.isExpanded
                ? String(localized: "Expanded", table: "Mobile")
                : String(localized: "Collapsed", table: "Mobile")
        case nil: break
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch row(at: indexPath) {
        case .tab(let id, _):
            guard workspace.tabs.contains(where: { $0.id == id }) else { return }
            workspace.selectTab(id: id)
            didSelectTab?()
        case .folder(let id, _):
            guard let document = workspace.profileDocument,
                  let folder = document.snapshot.pinnedTabFolders?.first(where: { $0.id == id }) else { return }
            document.setFolderExpanded(id: id, isExpanded: !folder.isExpanded)
            render()
        case nil: break
        }
    }

    override func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard workspace.isReady, workspace.profileDocument?.canEdit != false,
              case .tab(let id, _) = row(at: indexPath),
              let tab = workspace.tabs.first(where: { $0.id == id }) else { return nil }
        let removes = workspace.profileDocument != nil && tab.placement != .temporary
        let close = UIContextualAction(
            style: .destructive,
            title: removes
                ? String(localized: "Remove", table: "Mobile")
                : String(localized: "Close", table: "Mobile")
        ) { [weak self] _, _, completion in
            guard let self else { completion(false)
                return
            }
            completion(removeTab(id: id))
        }
        close.image = UIImage(systemName: "xmark")
        return UISwipeActionsConfiguration(actions: [close])
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard let row = row(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.menu(for: row) })
    }

    func render() {
        guard isViewLoaded else { return }
        let canEdit = workspace.isReady && (workspace.profileDocument?.canEdit ?? true)
        navigationItem.leftBarButtonItem?.isEnabled = canEdit
        if let document = workspace.profileDocument {
            var configuration = UIButton.Configuration.plain()
            configuration.title = workspace.spaces.first { $0.id == workspace.selectedSpaceID }?.title
                ?? String(localized: "Spaces", table: "Mobile")
            configuration.image = UIImage(systemName: "chevron.down")
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 6
            configuration.titleLineBreakMode = .byTruncatingTail
            spaceButton.configuration = configuration
            spaceButton.isEnabled = workspace.isReady
            spaceButton.menu = spaceMenu(document)
            navigationItem.titleView = spaceButton
            rows = sharedRows(document.snapshot)
        } else {
            navigationItem.titleView = nil
            rows = [workspace.tabs.map { .tab($0.id, depth: 0) }]
        }
        tableView.reloadData()
    }

    func tabMenu(id: String) -> UIMenu? {
        guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return nil }
        guard let document = workspace.profileDocument else {
            return UIMenu(children: [UIAction(
                title: String(localized: "Close Tab", table: "Mobile"),
                image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { [weak self] _ in self?.removeTab(id: id) }])
        }
        let disabled: UIMenuElement.Attributes = document.canEdit ? [] : .disabled
        var actions = [UIMenuElement]()
        if tab.placement != .app {
            actions.append(UIAction(
                title: tab.placement == .spacePinned
                    ? String(localized: "Unpin", table: "Mobile")
                    : String(localized: "Pin", table: "Mobile"),
                image: UIImage(systemName: tab.placement == .spacePinned ? "pin.slash" : "pin"),
                attributes: disabled
            ) { [weak document] _ in
                document?.setTabPinned(id: id, isPinned: tab.placement != .spacePinned)
            })
        }
        actions.append(UIAction(
            title: tab.placement == .app
                ? String(localized: "Remove from Favorites", table: "Mobile")
                : String(localized: "Add to Favorites", table: "Mobile"),
            image: UIImage(systemName: "star"),
            attributes: disabled
        ) { [weak self, weak document] _ in
            document?.setPlacement(
                tabID: id,
                placement: tab.placement == .app ? .temporary : .app,
                spaceID: tab.placement == .app ? self?.workspace.selectedSpaceID : nil
            )
        })
        actions.append(UIAction(
            title: String(localized: "Rename", table: "Mobile"),
            image: UIImage(systemName: "pencil"),
            attributes: disabled
        ) { [weak self, weak document] _ in
            let latest = self?.workspace.tabs.first { $0.id == id }
            self?.prompt(
                title: String(localized: "Rename", table: "Mobile"),
                value: latest?.userTitleOverride ?? latest?.title ?? "",
                allowsEmpty: true
            ) { [weak document] in
                document?.renameTab(id: id, title: $0)
            }
        })
        actions.append(moveMenu(item: .init(entityType: .tab, entityID: id), document: document))
        actions.append(UIAction(
            title: tab.placement == .temporary
                ? String(localized: "Close Tab", table: "Mobile")
                : String(localized: "Remove", table: "Mobile"),
            image: UIImage(systemName: "xmark"),
            attributes: disabled.union(.destructive)
        ) { [weak self] _ in self?.removeTab(id: id) })
        return UIMenu(children: actions)
    }

    func folderMenu(id: String) -> UIMenu? {
        guard let document = workspace.profileDocument,
              let folder = document.snapshot.pinnedTabFolders?.first(where: { $0.id == id }) else { return nil }
        let disabled: UIMenuElement.Attributes = document.canEdit ? [] : .disabled
        return UIMenu(children: [
            UIAction(
                title: String(localized: "Rename", table: "Mobile"),
                image: UIImage(systemName: "pencil"),
                attributes: disabled
            ) { [weak self, weak document] _ in
                guard let value = document?.snapshot.pinnedTabFolders?.first(where: { $0.id == id })?.title
                else { return }
                self?
                    .prompt(title: String(localized: "Rename", table: "Mobile"), value: value) { [weak document] in
                        document?.renameFolder(
                            id: id,
                            title: $0
                        )
                    }
            },
            UIAction(
                title: String(localized: "New Folder", table: "Mobile"),
                image: UIImage(systemName: "folder.badge.plus"),
                attributes: disabled
            ) { [weak self, weak document] _ in
                guard let current = document?.snapshot.pinnedTabFolders?.first(where: { $0.id == id }) else { return }
                self?.createFolder(spaceID: current.spaceID, parent: id)
            },
            moveMenu(item: .init(entityType: .folder, entityID: id), document: document),
            UIAction(
                title: String(localized: "Delete Folder and Contents", table: "Mobile"),
                image: UIImage(systemName: "trash"),
                attributes: disabled.union(.destructive)
            ) { [weak self, weak document] _ in
                self?.confirmFolderRemoval(title: folder.title) { [weak document] in document?.delete(entity: .init(
                    entityType: .folder,
                    entityID: id
                )) }
            },
        ])
    }

    // MARK: Private

    private enum Row {
        case tab(String, depth: Int)
        case folder(String, depth: Int)
    }

    private let spaceButton = UIButton(type: .system)
    private var rows = [[Row]]()

    private func row(at indexPath: IndexPath) -> Row? {
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].indices.contains(indexPath.row) else { return nil }
        return rows[indexPath.section][indexPath.row]
    }

    private func sharedRows(_ snapshot: BrowserTabSessionSnapshot) -> [[Row]] {
        let available = Set(workspace.visibleTabs.map(\.id))
        let folders = Dictionary(
            (snapshot.pinnedTabFolders ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = [[Row](), [Row](), [Row]()]
        func visibleDepth(parent: String?) -> Int? {
            var next = parent, depth = 0, seen = Set<String>()
            while let id = next {
                guard seen.insert(id).inserted, let folder = folders[id], folder.isExpanded else { return nil }
                depth += 1
                next = folder.parentFolderID
            }
            return depth
        }
        for change in BrowserSyncFolderProjection.canonicalChanges(snapshot) {
            if let folder = change.folderData, folder.spaceID == workspace.selectedSpaceID,
               let depth = visibleDepth(parent: folder.parentFolderID)
            {
                result[1].append(.folder(change.entityID, depth: depth))
            } else if let tab = change.tabData, available.contains(change.entityID) {
                switch tab.placement {
                case .app: result[0].append(.tab(change.entityID, depth: 0))
                case .spacePinned:
                    if let depth = visibleDepth(parent: tab.pinnedFolderID) {
                        result[1].append(.tab(change.entityID, depth: depth))
                    }
                case .temporary: result[2].append(.tab(change.entityID, depth: 0))
                }
            }
        }
        return result
    }

    private func displayTitle(_ tab: BrowserMobileTab) -> String {
        if let title = tab.userTitleOverride, !title.isEmpty {
            return title
        }
        if !tab.title.isEmpty {
            return tab.title
        }
        return tab.urlString == "about:blank"
            ? String(localized: "New Tab", table: "Mobile")
            : URL(string: tab.urlString)?.host ?? tab.urlString
    }

    @discardableResult private func removeTab(id: String) -> Bool {
        guard workspace.tabs.contains(where: { $0.id == id }) else { return false }
        if let document = workspace.profileDocument {
            return document.removeTab(id: id)
        }
        workspace.closeTab(id: id)
        return true
    }

    private func spaceMenu(_ document: BrowserMobileProfileDocument) -> UIMenu {
        var actions: [UIMenuElement] = workspace.spaces.map { space in
            UIAction(
                title: space.title,
                image: UIImage(systemName: space.systemImageName),
                state: workspace.selectedSpaceID == space.id ? .on : .off
            ) { [weak self] _ in
                self?.workspace.selectSpace(id: space.id)
                self?.render()
            }
        }
        let disabled: UIMenuElement.Attributes = document.canEdit ? [] : .disabled
        var edits: [UIMenuElement] = [UIAction(
            title: String(localized: "New Space", table: "Mobile"),
            image: UIImage(systemName: "plus"),
            attributes: disabled
        ) { [weak self] _ in
            self?.prompt(title: String(localized: "New Space", table: "Mobile"), value: "") { [
                weak self,
                weak document
            ] name in
                guard let id = document?.createSpace(title: name) else { return }
                self?.workspace.selectSpace(id: id)
            }
        }]
        if let id = workspace.selectedSpaceID {
            edits.append(UIAction(
                title: String(localized: "Rename Space", table: "Mobile"),
                image: UIImage(systemName: "pencil"),
                attributes: disabled
            ) { [weak self, weak document] _ in
                guard let title = document?.snapshot.spaces?.first(where: { $0.id == id })?.title else { return }
                self?
                    .prompt(
                        title: String(localized: "Rename Space", table: "Mobile"),
                        value: title
                    ) { [weak document] in
                        document?.renameSpace(id: id, title: $0)
                    }
            })
            edits.append(UIAction(
                title: String(localized: "New Folder", table: "Mobile"),
                image: UIImage(systemName: "folder.badge.plus"),
                attributes: disabled
            ) { [weak self] _ in
                self?.createFolder(spaceID: id, parent: nil)
            })
        }
        actions.append(UIMenu(options: .displayInline, children: edits))
        return UIMenu(children: actions)
    }

    private func menu(for row: Row) -> UIMenu? {
        switch row {
        case .tab(let id, _): tabMenu(id: id)
        case .folder(let id, _): folderMenu(id: id)
        }
    }

    private func moveMenu(item: BrowserSyncEntityReference, document: BrowserMobileProfileDocument) -> UIMenu {
        let disabled: UIMenuElement.Attributes = document.canEdit ? [] : .disabled
        let folders = document.snapshot.pinnedTabFolders ?? []
        func isDescendant(_ folder: BrowserPinnedTabFolderSessionSnapshot) -> Bool {
            guard item.entityType == .folder else { return false }
            var next: String? = folder.id, seen = Set<String>()
            while let id = next, seen.insert(id).inserted {
                if id == item.entityID {
                    return true
                }
                next = folders.first { $0.id == id }?.parentFolderID
            }
            return false
        }
        func moveAction(_ title: String, spaceID: String, placement: BrowserTabPlacement, parent: String?) -> UIAction {
            UIAction(title: title, attributes: disabled) { [weak document] _ in
                document?.move(
                    items: [item],
                    destination: .tabs(spaceID: spaceID, placement: placement, pinnedFolderID: parent)
                )
            }
        }
        let spaces = workspace.spaces.map { space -> UIMenu in
            var children: [UIMenuElement] = [moveAction(
                String(localized: "Pinned", table: "Mobile"),
                spaceID: space.id,
                placement: .spacePinned,
                parent: nil
            )]
            if item.entityType == .tab {
                children.append(moveAction(
                    String(localized: "Today", table: "Mobile"),
                    spaceID: space.id,
                    placement: .temporary,
                    parent: nil
                ))
            }
            for folder in folders where folder.spaceID == space.id && !isDescendant(folder) {
                var names = [folder.title], parent = folder.parentFolderID, seen: Set<String> = [folder.id]
                while let id = parent, seen.insert(id).inserted, let ancestor = folders.first(where: { $0.id == id }) {
                    names.insert(ancestor.title, at: 0)
                    parent = ancestor.parentFolderID
                }
                children.append(moveAction(
                    names.joined(separator: " / "),
                    spaceID: space.id,
                    placement: .spacePinned,
                    parent: folder.id
                ))
            }
            return UIMenu(title: space.title, image: UIImage(systemName: space.systemImageName), children: children)
        }
        return UIMenu(
            title: String(localized: "Move To", table: "Mobile"),
            image: UIImage(systemName: "folder"),
            children: spaces
        )
    }

    private func createFolder(spaceID: String, parent: String?) {
        prompt(title: String(localized: "New Folder", table: "Mobile"), value: "") { [weak self] name in
            self?.workspace.profileDocument?.createFolder(spaceID: spaceID, parentFolderID: parent, title: name)
        }
    }

    private func prompt(title: String, value: String, allowsEmpty: Bool = false, apply: @escaping (String) -> Void) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in field.text = value
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        alert
            .addAction(UIAlertAction(
                title: String(localized: "Save", table: "Mobile"),
                style: .default
            ) { [weak alert] _ in
                let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard allowsEmpty || !text.isEmpty else { return }
                apply(text)
            })
        present(alert, animated: true)
    }

    private func confirmFolderRemoval(title: String, apply: @escaping () -> Void) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "Delete Folder and Contents", table: "Mobile"),
            message: title,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        alert
            .addAction(UIAlertAction(title: String(localized: "Delete", table: "Mobile"), style: .destructive) { _ in
                apply()
            })
        present(alert, animated: true)
    }
}
