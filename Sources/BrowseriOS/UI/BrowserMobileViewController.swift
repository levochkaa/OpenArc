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

final class BrowserMobileTabsViewController: UITableViewController, UITableViewDragDelegate, UITableViewDropDelegate {
    // MARK: Lifecycle

    init(workspace: BrowserMobileWorkspace) {
        self.workspace = workspace
        super.init(style: .insetGrouped)
        title = String(localized: "Tabs", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        guard isHoldingRows else { return super.keyCommands }
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(cancelSidebarDrag)
        )
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    let workspace: BrowserMobileWorkspace
    var didSelectTab: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Tab")
        tableView.accessibilityIdentifier = "browser.tabs"
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.allowsSelectionDuringEditing = true
        tableView.estimatedRowHeight = 60
        selectionButton.accessibilityIdentifier = "browser.selectTabs"
        nonSelectionRightButtons = navigationItem.rightBarButtonItems ?? []
        updateSelectionButton()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "New Tab", table: "Mobile"), image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.workspace.newTab()
                self?.didSelectTab?()
            }
        )
        let accountButton = UIBarButtonItem(
            title: String(localized: "Account", table: "Mobile"), image: UIImage(systemName: "person.crop.circle"),
            primaryAction: UIAction { [weak self] _ in self?.showAccount() }
        )
        accountButton.accessibilityIdentifier = "browser.account"
        navigationItem.leftBarButtonItems = [navigationItem.leftBarButtonItem!, accountButton]
        spaceButton.showsMenuAsPrimaryAction = true
        spaceButton.accessibilityIdentifier = "browser.spaces"
        spaceButton.titleLabel?.lineBreakMode = .byTruncatingTail
        spaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spaceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        render()
    }

    override func numberOfSections(in _: UITableView) -> Int { rows.count }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        terminalRefreshTask?.cancel()
        terminalRefreshTask = nil
        cancelSidebarDrag()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        render()
    }

    override func tableView(_: UITableView, heightForHeaderInSection _: Int) -> CGFloat {
        workspace.profileDocument == nil ? UITableView.automaticDimension : 44
    }

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
        configure(cell, at: indexPath)
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isHoldingRows else { return }
        if isSelectingRows {
            guard let row = row(at: indexPath) else { return }
            selectedItems.insert(row.reference)
            if let cell = tableView.cellForRow(at: indexPath) {
                configure(cell, at: indexPath)
            }
            return
        }
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

    override func tableView(_: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isSelectingRows, !isHoldingRows, let row = row(at: indexPath) else { return }
        selectedItems.remove(row.reference)
        if let cell = tableView.cellForRow(at: indexPath) {
            configure(cell, at: indexPath)
        }
    }

    override func tableView(_: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        isHoldingRows ? nil : indexPath
    }

    override func tableView(_: UITableView, willDeselectRowAt indexPath: IndexPath) -> IndexPath? {
        isHoldingRows ? nil : indexPath
    }

    override func tableView(_: UITableView, shouldBeginMultipleSelectionInteractionAt _: IndexPath) -> Bool { false }

    override func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard !isSelectingRows, workspace.isReady, workspace.profileDocument?.canEdit != false,
              case .tab(let id, _) = row(at: indexPath),
              let tab = workspace.tabs.first(where: { $0.id == id }) else { return nil }
        let removes = workspace.profileDocument != nil && tab.placement != .temporary
        let close = UIContextualAction(
            style: .destructive,
            title: removes
                ? String(localized: "Remove", table: "Mobile")
                : String(localized: "Close", table: "Mobile")
        ) { [weak self] _, _, completion in
            guard let self, !isSelectingRows else { completion(false)
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
        guard !isSelectingRows, let row = row(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.menu(for: row) })
    }

    func render() {
        guard isViewLoaded else { return }
        if renderedSpaceID != workspace.selectedSpaceID || renderedDocument !== workspace.profileDocument {
            selectedItems.removeAll()
        }
        if isHoldingRows || tableView.hasUncommittedUpdates {
            needsStructuralRefresh = true
            if renderedSpaceID != workspace.selectedSpaceID || renderedDocument !== workspace.profileDocument {
                cancelSidebarDrag()
            }
            if !isHoldingRows {
                scheduleTerminalRefresh()
            }
            return
        }
        let canEdit = workspace.isReady && (workspace.profileDocument?.canEdit ?? true)
        navigationItem.leftBarButtonItem?.isEnabled = canEdit && !isSelectingRows
        navigationItem.leftBarButtonItems?.last?.isEnabled = workspace.syncSession != nil
        updateSelectionButton()
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
            applyRows(sharedRows(document.snapshot), snapshot: document.snapshot)
        } else {
            navigationItem.titleView = nil
            applyRows([workspace.tabs.map { .tab($0.id, depth: 0) }], snapshot: nil)
        }
    }

    func tableView(
        _: UITableView,
        itemsForBeginning session: any UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        let sessionID = ObjectIdentifier(session)
        if sourceSessionID == sessionID, let payload = activeSource {
            guard !payload.isCancelled, payload.document === workspace.profileDocument,
                  payload.spaceID == workspace.selectedSpaceID, let row = row(at: indexPath) else { return [] }
            return initialDragItem(for: row.reference)
        }
        guard !isHoldingRows, workspace.isReady, let document = workspace.profileDocument, document.canEdit,
              let row = row(at: indexPath) else { return [] }
        let requestedItems = isSelectingRows && selectedItems.contains(row.reference)
            ? rows.flatMap { $0 }.map(\.reference).filter { selectedItems.contains($0) }
            : [row.reference]
        guard let source = BrowserMobileSidebarDrop.source(items: requestedItems, in: document.snapshot)
        else { return [] }
        // UIKit may never begin a session for a row that returns no items.
        // A selected descendant must not freeze the table before its root lifts.
        guard source.items.contains(row.reference) else { return [] }
        if isSelectingRows, !selectedItems.contains(row.reference) {
            selectedItems = [row.reference]
            restoreRowSelection()
        }
        let payload = SidebarDragPayload(
            owner: self,
            document: document,
            spaceID: workspace.selectedSpaceID,
            source: source,
            sourceSessionID: sessionID
        )
        initialDragItems.removeAll(keepingCapacity: true)
        suppliedInitialItems.removeAll(keepingCapacity: true)
        for reference in source.items {
            let label = dragLabel(for: reference)
            let item = UIDragItem(itemProvider: NSItemProvider(object: label as NSString))
            item.localObject = payload
            initialDragItems[reference] = item
        }
        payload.dragItemIDs = Set(initialDragItems.values.map(ObjectIdentifier.init))
        session.localContext = payload
        activeSource = payload
        sourceSessionID = sessionID
        updateSelectionButton()
        becomeFirstResponder()
        return initialDragItem(for: row.reference)
    }

    func tableView(
        _: UITableView,
        itemsForAddingTo _: any UIDragSession,
        at _: IndexPath,
        point _: CGPoint
    ) -> [UIDragItem] { [] }
    func tableView(_: UITableView, dragSessionAllowsMoveOperation _: any UIDragSession) -> Bool { true }
    func tableView(_: UITableView, dragSessionIsRestrictedToDraggingApplication _: any UIDragSession) -> Bool { true }

    func tableView(_: UITableView, dragSessionDidEnd session: any UIDragSession) {
        guard sourceSessionID == ObjectIdentifier(session) else { return }
        sourceSessionID = nil
        activeSource = nil
        initialDragItems.removeAll(keepingCapacity: true)
        suppliedInitialItems.removeAll(keepingCapacity: true)
        finishInteractionIfPossible()
    }

    func tableView(_: UITableView, canHandle session: any UIDropSession) -> Bool { payload(for: session) != nil }

    func tableView(_: UITableView, dropSessionDidEnter session: any UIDropSession) {
        guard payload(for: session) != nil else { return }
        dropSessionID = ObjectIdentifier(session)
    }

    func tableView(_: UITableView, dropSessionDidExit session: any UIDropSession) {
        guard dropSessionID == ObjectIdentifier(session) else { return }
        dropSessionID = nil
        hover = nil
        clearDropFeedback()
        finishInteractionIfPossible()
    }

    func tableView(_: UITableView, dropSessionDidEnd session: any UIDropSession) {
        guard dropSessionID == ObjectIdentifier(session) else { return }
        dropSessionID = nil
        hover = nil
        clearDropFeedback()
        finishInteractionIfPossible()
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath _: IndexPath?
    ) -> UITableViewDropProposal {
        clearDropFeedback()
        guard let payload = payload(for: session), let document = workspace.profileDocument,
              let target = dropTarget(at: session.location(in: tableView)),
              validatedPlan(source: payload.source, target: target.target, snapshot: document.snapshot) != nil
        else {
            hover = nil
            return .init(operation: .forbidden)
        }
        dropSessionID = ObjectIdentifier(session)
        hover = target
        if let index = target.insideFolder, let cell = tableView.cellForRow(at: index) {
            var background = UIBackgroundConfiguration.listCell()
            background.backgroundColor = view.tintColor.withAlphaComponent(0.16)
            cell.backgroundConfiguration = background
            highlightedFolder = index
        } else {
            insertionLine.backgroundColor = view.tintColor
            insertionLine.isUserInteractionEnabled = false
            insertionLine.accessibilityIdentifier = "browser.dropBoundary"
            insertionLine.frame = CGRect(
                x: tableView.layoutMargins.left + target.indentation,
                y: target.point.y - 1,
                width: max(
                    0,
                    tableView.bounds.width - tableView.layoutMargins.left - tableView.layoutMargins.right - target
                        .indentation
                ),
                height: 2
            )
            if insertionLine.superview == nil {
                tableView.addSubview(insertionLine)
            }
            tableView.bringSubviewToFront(insertionLine)
            insertionLine.isHidden = false
        }
        // Flattened folder rows do not share UIKit's insertion index semantics.
        // Draw the exact sibling boundary, including the whole visible subtree.
        return .init(
            operation: .move,
            intent: target.insideFolder == nil
                ? .unspecified
                : .insertIntoDestinationIndexPath
        )
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: any UITableViewDropCoordinator) {
        guard coordinator.proposal.operation == .move,
              let payload = payload(for: coordinator.session), let document = workspace.profileDocument,
              matches(coordinator.items.map(\.dragItem), payload: payload),
              dropSessionID == ObjectIdentifier(coordinator.session), let hover,
              let finalTarget = dropTarget(at: coordinator.session.location(in: tableView)),
              finalTarget.target == hover.target,
              coordinator.proposal
                  .intent == (hover.insideFolder == nil ? .unspecified : .insertIntoDestinationIndexPath),
                  let plan = validatedPlan(source: payload.source, target: hover.target, snapshot: document.snapshot)
        else { return }
        // Keep the data source frozen through synchronous document observers and
        // UIKit's drop animation. The terminal refresh reads the latest tree.
        isCommittingDrop = true
        defer {
            isCommittingDrop = false
            finishInteractionIfPossible()
        }
        let moved = document.move(
            items: plan.items,
            destination: plan.destination,
            before: plan.before,
            after: plan.after
        )
        guard moved else { return }
        payload.isCancelled = true
        needsStructuralRefresh = true
        let batchID = UUID()
        animationBatchID = batchID
        pendingDropAnimations = payload.dragItemIDs
        let target = UIDragPreviewTarget(container: tableView, center: hover.point)
        for item in coordinator.items {
            let itemID = ObjectIdentifier(item.dragItem)
            coordinator.drop(item.dragItem, to: target).addCompletion { [weak self] _ in
                guard let self, animationBatchID == batchID, pendingDropAnimations.remove(itemID) != nil else { return }
                if pendingDropAnimations.isEmpty {
                    animationBatchID = nil
                }
                finishInteractionIfPossible()
            }
        }
    }

    func tabMenu(id: String) -> UIMenu? {
        guard !isSelectingRows else { return nil }
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
        guard !isSelectingRows, let document = workspace.profileDocument,
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

    private enum Row: Equatable {
        case tab(String, depth: Int)
        case folder(String, depth: Int)

        // MARK: Internal

        var reference: BrowserSyncEntityReference {
            switch self {
            case .tab(let id, _): .init(entityType: .tab, entityID: id)
            case .folder(let id, _): .init(entityType: .folder, entityID: id)
            }
        }

        var depth: Int {
            switch self { case .tab(_, let depth), .folder(_, let depth): depth }
        }
    }

    private final class SidebarDragPayload {
        // MARK: Lifecycle

        init(
            owner: BrowserMobileTabsViewController,
            document: BrowserMobileProfileDocument,
            spaceID: String?,
            source: BrowserMobileSidebarDrop.Source,
            sourceSessionID: ObjectIdentifier
        ) {
            self.owner = owner
            self.document = document
            self.spaceID = spaceID
            self.source = source
            self.sourceSessionID = sourceSessionID
        }

        // MARK: Internal

        weak var owner: BrowserMobileTabsViewController?
        weak var document: BrowserMobileProfileDocument?
        let spaceID: String?
        let source: BrowserMobileSidebarDrop.Source
        let sourceSessionID: ObjectIdentifier
        var dragItemIDs = Set<ObjectIdentifier>()
        var isCancelled = false
    }

    private struct DropHover {
        let target: BrowserMobileSidebarDrop.Target
        let point: CGPoint
        var insideFolder: IndexPath?
        var indentation: CGFloat = 0
    }

    private struct TargetKey: Hashable {
        let item: BrowserSyncEntityReference
        let position: Int
    }

    private struct PlanCache {
        let source: BrowserMobileSidebarDrop.Source
        let target: BrowserMobileSidebarDrop.Target
        let snapshot: BrowserTabSessionSnapshot
        let plan: BrowserMobileSidebarDrop.Plan?
    }

    private let spaceButton = UIButton(type: .system)
    private lazy var selectionButton = UIBarButtonItem(
        title: String(localized: "Select", table: "Mobile"), style: .plain,
        target: self, action: #selector(toggleSidebarSelection)
    )
    private var nonSelectionRightButtons = [UIBarButtonItem]()
    private var isSelectingRows = false
    private var selectedItems = Set<BrowserSyncEntityReference>()
    private var rows = [[Row]]()
    private var renderedSnapshot: BrowserTabSessionSnapshot?
    private var renderedTabs = [String: BrowserMobileTab]()
    private weak var renderedDocument: BrowserMobileProfileDocument?
    private var renderedSpaceID: String?
    private var activeSource: SidebarDragPayload?
    private var initialDragItems = [BrowserSyncEntityReference: UIDragItem]()
    private var suppliedInitialItems = Set<BrowserSyncEntityReference>()
    private var sourceSessionID: ObjectIdentifier?
    private var dropSessionID: ObjectIdentifier?
    private var hover: DropHover?
    private var highlightedFolder: IndexPath?
    private var needsStructuralRefresh = false
    private var isCommittingDrop = false
    private var pendingDropAnimations = Set<ObjectIdentifier>()
    private var animationBatchID: UUID?
    private let insertionLine = UIView()
    private var capturedTargets = [TargetKey: BrowserMobileSidebarDrop.Target]()
    private var planCache: PlanCache?
    private var terminalRefreshTask: Task<Void, Never>?

    private var isHoldingRows: Bool {
        sourceSessionID != nil || dropSessionID != nil || isCommittingDrop || !pendingDropAnimations.isEmpty
    }

    @objc private func toggleSidebarSelection() {
        guard !isHoldingRows, !tableView.hasUncommittedUpdates,
              isSelectingRows || (workspace.isReady && workspace.profileDocument?.canEdit == true) else { return }
        isSelectingRows.toggle()
        selectedItems.removeAll()
        super.setEditing(isSelectingRows, animated: true)
        restoreRowSelection()
        render()
    }

    private func updateSelectionButton() {
        selectionButton.title = isSelectingRows
            ? String(localized: "Done", table: "Mobile")
            : String(localized: "Select", table: "Mobile")
        selectionButton
            .isEnabled = !isHoldingRows &&
            (isSelectingRows || (workspace.isReady && workspace.profileDocument?.canEdit == true))
        navigationItem.rightBarButtonItems = isSelectingRows
            ? [selectionButton]
            : nonSelectionRightButtons + [selectionButton]
    }

    private func restoreRowSelection() {
        for index in tableView.indexPathsForSelectedRows ?? [] {
            if !isSelectingRows || row(at: index).map({ !selectedItems.contains($0.reference) }) != false {
                tableView.deselectRow(at: index, animated: false)
            }
        }
        if isSelectingRows {
            for item in selectedItems {
                if let index = indexPath(for: item) {
                    tableView.selectRow(
                        at: index,
                        animated: false,
                        scrollPosition: .none
                    )
                }
            }
        }
        for index in tableView.indexPathsForVisibleRows ?? [] {
            if let cell = tableView.cellForRow(at: index) {
                configure(cell, at: index)
            }
        }
    }

    private func dragLabel(for item: BrowserSyncEntityReference) -> String {
        switch item.entityType {
        case .tab: renderedTabs[item.entityID].map(displayTitle) ?? String(localized: "Tabs", table: "Mobile")
        case .folder: renderedSnapshot?.pinnedTabFolders?.first(where: { $0.id == item.entityID })?.title ?? String(
                localized: "Tabs",
                table: "Mobile"
            )
        case .space: String(localized: "Spaces", table: "Mobile")
        }
    }

    private func initialDragItem(for reference: BrowserSyncEntityReference) -> [UIDragItem] {
        guard let item = initialDragItems[reference], suppliedInitialItems.insert(reference).inserted else { return [] }
        return [item]
    }

    private func configure(_ cell: UITableViewCell, at indexPath: IndexPath) {
        cell.accessoryType = .none
        cell.accessibilityTraits = [.button]
        cell.accessibilityIdentifier = nil
        cell.accessibilityValue = nil
        cell.indentationWidth = 16
        cell.indentationLevel = 0
        cell.contentConfiguration = nil
        cell.backgroundConfiguration = .listCell()
        var content = cell.defaultContentConfiguration()
        switch row(at: indexPath) {
        case .tab(let id, let depth):
            guard let tab = renderedTabs[id] else { return }
            content.text = displayTitle(tab)
            content.secondaryText = tab.urlString == "about:blank" ? nil : tab.urlString
            content.secondaryTextProperties.numberOfLines = 1
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            content.image = UIImage(systemName: tab.state.error == nil ? "globe" : "exclamationmark.circle")
            cell.indentationLevel = depth
            cell.accessoryType = !isSelectingRows && workspace.selectedTabID == id ? .checkmark : .none
            cell.accessibilityIdentifier = "browser.tab." + id
            cell.accessibilityTraits = (isSelectingRows
                ? selectedItems.contains(.init(entityType: .tab, entityID: id))
                : workspace.selectedTabID == id)
                ? [.button, .selected]
                : [.button]
        case .folder(let id, let depth):
            guard let folder = renderedSnapshot?.pinnedTabFolders?.first(where: { $0.id == id })
            else { return }
            content.text = folder.title
            content
                .image = UIImage(systemName: folder.systemImageName ?? (folder.isExpanded ? "folder.fill" : "folder"))
            cell.indentationLevel = depth
            cell.accessoryType = isSelectingRows || folder.isExpanded ? .none : .disclosureIndicator
            if isSelectingRows,
               selectedItems
                   .contains(.init(entityType: .folder, entityID: id))
            {
                cell.accessibilityTraits.insert(.selected)
            }
            cell.accessibilityIdentifier = "browser.folder." + id
            cell.accessibilityValue = folder.isExpanded
                ? String(localized: "Expanded", table: "Mobile")
                : String(localized: "Collapsed", table: "Mobile")
        case nil: break
        }
        cell.contentConfiguration = content
    }

    private func payload(for session: any UIDropSession) -> SidebarDragPayload? {
        guard workspace.isReady, let document = workspace.profileDocument, document.canEdit,
              session.allowsMoveOperation, let local = session.localDragSession,
              let payload = local.localContext as? SidebarDragPayload,
              payload.owner === self, payload.document === document, !payload.isCancelled,
              activeSource === payload, sourceSessionID == payload.sourceSessionID,
              ObjectIdentifier(local) == payload.sourceSessionID,
              payload.spaceID == workspace.selectedSpaceID,
              matches(session.items, payload: payload), matches(local.items, payload: payload)
        else { return nil }
        return payload
    }

    private func matches(_ items: [UIDragItem], payload: SidebarDragPayload) -> Bool {
        items.count == payload.source.items.count && !items.isEmpty
            && Set(items.map(ObjectIdentifier.init)) == payload.dragItemIDs
            && payload.dragItemIDs.count == items.count
            && items.allSatisfy { $0.localObject as? SidebarDragPayload === payload }
    }

    private func dropTarget(at point: CGPoint) -> DropHover? {
        guard tableView.bounds.contains(point), let snapshot = renderedSnapshot else { return nil }
        if let index = tableView.indexPathForRow(at: point), let row = row(at: index) {
            let rect = tableView.rectForRow(at: index)
            let position: BrowserMobileSidebarDrop.Position
            let inside: Bool
            if case .folder = row, point.y >= rect.minY + rect.height * 0.25,
               point.y <= rect.maxY - rect.height * 0.25
            {
                position = .inside
                inside = true
            } else {
                position = point.y < rect.midY ? .before : .after
                inside = false
            }
            guard let target = capturedTarget(relativeTo: row.reference, position: position, snapshot: snapshot)
            else { return nil }
            var boundary = position == .before ? rect.minY : rect.maxY
            if case .folder = row, position == .after {
                var last = index.row
                while rows[index.section].indices.contains(last + 1),
                      rows[index.section][last + 1].depth > row.depth
                {
                    last += 1
                }
                boundary = tableView.rectForRow(at: .init(row: last, section: index.section)).maxY
            }
            return .init(
                target: target,
                point: CGPoint(x: rect.midX + CGFloat(row.depth) * 8, y: inside ? rect.midY : boundary),
                insideFolder: inside
                    ? index
                    : nil,
                indentation: CGFloat(row.depth) * 16
            )
        }
        for section in rows.indices {
            let rect = tableView.rect(forSection: section)
            guard rect.contains(point) || (section == rows.count - 1 && point.y >= rect.maxY) else { continue }
            if let first = rows[section].first,
               point.y < tableView.rectForRow(at: .init(row: 0, section: section)).minY,
               let target = capturedTarget(relativeTo: first.reference, position: .before, snapshot: snapshot)
            {
                return .init(
                    target: target,
                    point: CGPoint(x: rect.midX, y: tableView.rectForRow(at: .init(row: 0, section: section)).minY)
                )
            }
            let placement: BrowserTabPlacement
            switch section {
            case 0: placement = .app
            case 1: placement = .spacePinned
            case 2: placement = .temporary
            default: return nil
            }
            let spaceID = renderedSpaceID ?? (placement == .app
                ? snapshot.tabs.first(where: { $0.placement == .app })?.spaceID
                : nil)
            guard let spaceID else { return nil }
            let boundaryY = rows[section].isEmpty
                ? tableView.rectForHeader(inSection: section).maxY
                : tableView.rectForRow(at: .init(row: rows[section].count - 1, section: section)).maxY
            return .init(
                target: BrowserMobileSidebarDrop.rootTarget(spaceID: spaceID, placement: placement),
                point: CGPoint(x: rect.midX, y: boundaryY)
            )
        }
        return nil
    }

    @objc private func cancelSidebarDrag() {
        guard isHoldingRows else { return }
        activeSource?.isCancelled = true
        hover = nil
        clearDropFeedback()
        needsStructuralRefresh = true
        finishInteractionIfPossible()
    }

    private func clearDropFeedback() {
        insertionLine.isHidden = true
        if let index = highlightedFolder, let cell = tableView.cellForRow(at: index) {
            cell.backgroundConfiguration = .listCell()
        }
        highlightedFolder = nil
    }

    private func capturedTarget(
        relativeTo item: BrowserSyncEntityReference,
        position: BrowserMobileSidebarDrop.Position,
        snapshot: BrowserTabSessionSnapshot
    ) -> BrowserMobileSidebarDrop.Target? {
        let positionID =
            switch position { case .before: 0
            case .after: 1
            case .inside: 2 }
        let key = TargetKey(item: item, position: positionID)
        if let target = capturedTargets[key] {
            return target
        }
        guard let target = BrowserMobileSidebarDrop.target(relativeTo: item, position: position, in: snapshot)
        else { return nil }
        if capturedTargets.count >= 256 {
            capturedTargets.removeAll(keepingCapacity: true)
        }
        capturedTargets[key] = target
        return target
    }

    private func validatedPlan(
        source: BrowserMobileSidebarDrop.Source,
        target: BrowserMobileSidebarDrop.Target,
        snapshot: BrowserTabSessionSnapshot
    ) -> BrowserMobileSidebarDrop.Plan? {
        if let cache = planCache, cache.source == source, cache.target == target,
           cache.snapshot == snapshot
        {
            return cache.plan
        }
        let plan = BrowserMobileSidebarDrop.plan(source: source, target: target, in: snapshot)
        planCache = .init(source: source, target: target, snapshot: snapshot, plan: plan)
        return plan
    }

    private func finishInteractionIfPossible() {
        guard !isHoldingRows else { return }
        guard !tableView.hasUncommittedUpdates else {
            needsStructuralRefresh = true
            scheduleTerminalRefresh()
            return
        }
        planCache = nil
        clearDropFeedback()
        updateSelectionButton()
        if needsStructuralRefresh {
            needsStructuralRefresh = false
            render()
        }
    }

    private func scheduleTerminalRefresh() {
        guard terminalRefreshTask == nil, viewIfLoaded?.window != nil else { return }
        terminalRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            terminalRefreshTask = nil
            finishInteractionIfPossible()
        }
    }

    private func applyRows(_ newRows: [[Row]], snapshot: BrowserTabSessionSnapshot?) {
        let anchor = tableView.indexPathsForVisibleRows?.sorted().first.flatMap { index -> (
            BrowserSyncEntityReference,
            CGFloat
        )? in
            guard let row = row(at: index) else { return nil }
            return (row.reference, tableView.rectForRow(at: index).minY - tableView.contentOffset.y)
        }
        let structuralChange = rows != newRows
        if renderedSnapshot != snapshot {
            capturedTargets.removeAll(keepingCapacity: true)
        }
        rows = newRows
        selectedItems.formIntersection(Set(newRows.flatMap { $0 }.map(\.reference)))
        renderedSnapshot = snapshot
        renderedDocument = workspace.profileDocument
        renderedSpaceID = workspace.selectedSpaceID
        renderedTabs = Dictionary(workspace.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if structuralChange {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            if let anchor, let index = indexPath(for: anchor.0) {
                let y = tableView.rectForRow(at: index).minY - anchor.1
                let minY = -tableView.adjustedContentInset.top
                let maxY = max(
                    minY,
                    tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
                )
                tableView.setContentOffset(
                    CGPoint(x: tableView.contentOffset.x, y: min(maxY, max(minY, y))),
                    animated: false
                )
            }
        } else {
            for index in tableView.indexPathsForVisibleRows ?? [] {
                if let cell = tableView.cellForRow(at: index) {
                    configure(cell, at: index)
                }
            }
        }
        restoreRowSelection()
    }

    private func indexPath(for item: BrowserSyncEntityReference) -> IndexPath? {
        for section in rows.indices {
            if let row = rows[section].firstIndex(where: { $0.reference == item }) {
                return .init(
                    row: row,
                    section: section
                )
            }
        }
        return nil
    }

    private func showAccount() {
        guard presentedViewController == nil, let session = workspace.syncSession else { return }
        let controller = BrowserMobileAccountViewController(session: session)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

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
