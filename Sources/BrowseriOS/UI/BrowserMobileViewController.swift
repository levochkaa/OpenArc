// BrowserMobileViewController.swift

import UIKit

// MARK: - BrowserMobileViewController

/// Scene-owned composition. UIKit handles column collapse as the window resizes.
final class BrowserMobileViewController: UISplitViewController, UISplitViewControllerDelegate {
    // MARK: Internal

    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(
            title: String(localized: "Find in Page", table: "Mobile"),
            action: #selector(findInPage), input: "f", modifierFlags: .command,
        )
        find.wantsPriorityOverSystemBehavior = true
        let nextSpace = UIKeyCommand(
            title: String(localized: "Next Space", table: "Mobile"),
            action: #selector(selectNextSpace), input: UIKeyCommand.inputRightArrow,
            modifierFlags: [.command, .alternate],
        )
        let previousSpace = UIKeyCommand(
            title: String(localized: "Previous Space", table: "Mobile"),
            action: #selector(selectPreviousSpace), input: UIKeyCommand.inputLeftArrow,
            modifierFlags: [.command, .alternate],
        )
        return (super.keyCommands ?? []) + [find, nextSpace, previousSpace]
    }

    let workspace: BrowserMobileWorkspace
    let pageController: BrowserMobilePageViewController
    private var pendingAppLink: BrowserMobileAppLink?
    let tabsController: BrowserMobileTabsViewController

    lazy var javaScriptDialogPresenter =
        BrowserMobileJavaScriptDialogPresenter(host: self) { [weak self] id, response in
            self?.workspace.resolveJavaScriptDialog(id: id, response: response)
        }

    lazy var httpAuthenticationPresenter =
        BrowserMobileHTTPAuthenticationPresenter(host: self) { [weak self] id, response in
            self?.workspace.resolveHTTPAuthentication(id: id, response: response)
        }

    // MARK: Private

    private weak var presentedTabs: BrowserMobileTabsViewController?

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
        // The toolbar's Show Tabs shows and hides the sidebar; UIKit's own
        // button would be a second one for the same thing.
        displayModeButtonVisibility = .never
        setViewController(UINavigationController(rootViewController: tabsController), for: .primary)
        setViewController(pageController, for: .secondary)
        pageController.showTabs = { [weak self] in self?.showTabList() }
        pageController.showExtensionSettings = { [weak self] in self?.showExtensionSettings() }
        tabsController.didSelectTab = { [weak self] in
            guard let self else { return }
            if isCollapsed {
                show(.secondary)
            }
        }
        workspace.onChange = { [weak self] in self?.render() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

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
        httpAuthenticationPresenter.update(workspace.httpAuthentication)
        performPendingAppLink()
    }

    /// The Home Screen widget's links: each opens a new tab with its address field focused.
    func open(_ link: BrowserMobileAppLink) {
        pendingAppLink = link
        performPendingAppLink()
    }

    private func performPendingAppLink() {
        guard pendingAppLink != nil, workspace.isReady else { return }
        pendingAppLink = nil
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        workspace.newTab()
        pageController.focusAddress()
    }

    func splitViewController(_: UISplitViewController, topColumnForCollapsingToProposedTopColumn _: Column) -> Column {
        .secondary
    }

    /// Settings › Extensions, from the page's extension list.
    private func showExtensionSettings() {
        guard presentedViewController == nil else { return }
        let controller = BrowserMobilePhoneSettingsViewController(workspace: workspace)
        controller.didRestoreFromArchive = { [weak self] in self?.tabsController.didSelectTab?() }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        controller.showExtensions(animated: false)
        present(navigation, animated: true)
    }

    @objc private func findInPage() { pageController.findInPage() }

    @objc private func selectNextSpace() { tabsController.showSpace(offset: 1) }

    @objc private func selectPreviousSpace() { tabsController.showSpace(offset: -1) }

    private func showTabList() {
        workspace.dismissFindInPage()
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
            systemItem: .done, primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) },
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        presentedTabs = controller
        present(navigation, animated: true)
    }
}

// MARK: - BrowserMobileTabsViewController

final class BrowserMobileTabsViewController: UITableViewController, UITableViewDragDelegate, UITableViewDropDelegate,
    UIDropInteractionDelegate
{
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
            switch self { case .tab(_, let depth),
                 .folder(_, let depth): depth }
        }
    }

    private final class SpaceSpringBehavior: NSObject, UISpringLoadedInteractionBehavior {
        // MARK: Private

        private let canActivate: () -> Bool

        init(canActivate: @escaping () -> Bool) { self.canActivate = canActivate }

        // MARK: Internal

        func shouldAllow(_: UISpringLoadedInteraction, with _: any UISpringLoadedInteractionContext) -> Bool {
            canActivate()
        }
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

    private struct FolderHoverCandidate {
        let tokenID: ObjectIdentifier
        let sessionID: ObjectIdentifier
        let folderID: String
        let target: BrowserMobileSidebarDrop.Target
        let generation: UUID
        var isDue = false
        var retryCount = 0
        var retryScheduled = false
    }

    private struct FolderExpansionCache {
        let source: BrowserMobileSidebarDrop.Source
        let target: BrowserMobileSidebarDrop.Target
        let snapshot: BrowserTabSessionSnapshot
        let isEligible: Bool
    }

    static let phoneSheetColor = UIColor(white: 0.2, alpha: 1)

    private static let spaceBarItemWidth: CGFloat = 44

    // MARK: Internal

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        guard isHoldingRows else { return super.keyCommands }
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(cancelSidebarDrag),
        )
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    let workspace: BrowserMobileWorkspace
    var didSelectTab: (() -> Void)?
    /// The phone's Spaces sheet: the Space's name over plain rows with site
    /// icons, a line before Today, and the Spaces as icons along the bottom.
    let isPhoneSheet: Bool

    private var renderedSideInsets: (CGFloat, CGFloat) = (0, 0)

    private let hoverScheduler: any BrowserMobileSidebarHoverScheduling
    private let suppliedTableView: UITableView?
    private var folderHoverCandidate: FolderHoverCandidate?
    private var folderExpansionCache: FolderExpansionCache?
    private weak var hoverDropSession: (any UIDropSession)?
    private var transientExpandedFolderIDs = Set<String>()
    private var renderedAvailableTabIDs = Set<String>()
    private var isApplyingHoverProjection = false

    private let spaceButton = UIButton(type: .system)
    /// The Space's name over the rows, with the Space menu.
    private var spaceHeaderLeading = NSLayoutConstraint()
    private lazy var spaceHeader: UIView = {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        spaceButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(spaceButton)
        spaceHeaderLeading = spaceButton.leadingAnchor.constraint(equalTo: header.leadingAnchor)
        NSLayoutConstraint.activate([
            spaceHeaderLeading,
            spaceButton.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20),
            spaceButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }()

    private lazy var selectionButton = UIBarButtonItem(
        title: String(localized: "Select", table: "Mobile"), style: .plain,
        target: self, action: #selector(toggleSidebarSelection),
    )
    private var nonSelectionRightButtons = [UIBarButtonItem]()
    private var isSelectingRows = false
    private var selectedItems = Set<BrowserSyncEntityReference>()
    private var rows = [[Row]]()
    private var renderedSnapshot: BrowserTabSessionSnapshot?
    private var renderedTabs = [String: BrowserMobileTab]()
    private weak var renderedDocument: BrowserMobileProfileDocument?
    private var renderedSpaceID: String?
    private var activeSource: BrowserMobileSidebarDragSession?
    private var observedDragMembershipRevision: Int?
    private var initialDragItems = [BrowserSyncEntityReference: UIDragItem]()
    private var suppliedInitialItems = Set<BrowserSyncEntityReference>()
    private var sourceSessionID: ObjectIdentifier?
    private var dropSessionID: ObjectIdentifier?
    private var hover: DropHover?
    private weak var dragScene: UIWindowScene?
    private var spaceDropController: BrowserMobileSpaceDropViewController?
    private var spaceDropTopConstraint: NSLayoutConstraint?
    private var spaceDropBottomConstraint: NSLayoutConstraint?
    private var spaceDropSessionID: ObjectIdentifier?
    private weak var spaceHoverDropSession: (any UIDropSession)?
    private var spaceDropHover: BrowserMobileSpaceDropViewController.Target?
    private var spaceDropClosing = false
    private var spaceDropBatchID: UUID?
    private var spaceDropBatchSessionID: ObjectIdentifier?
    private var spaceDropPreviewTarget: BrowserMobileSpaceDropViewController.Target?
    private var registeredSpaceDropAnimations = Set<ObjectIdentifier>()
    private var highlightedFolder: IndexPath?
    private var needsStructuralRefresh = false
    private var isCommittingDrop = false
    private var dragAdmissionSuspended = false
    private let insertionLine = UIView()
    private var capturedTargets = [TargetKey: BrowserMobileSidebarDrop.Target]()
    private var planCache: PlanCache?
    private var terminalRefreshTask: Task<Void, Never>?

    private var archiveButton = UIBarButtonItem()
    private var settingsButton = UIBarButtonItem()
    private weak var presentedArchive: BrowserMobileArchiveViewController?

    private let phoneTitleButton = UIButton(type: .system)
    private var phoneSpaceItems = [String: UIBarButtonItem]()
    /// A sideways drag between Spaces (one finger in the phone sheet, two
    /// fingers or the trackpad in the sidebar): the neighbor's rows slide in
    /// beside the current ones.
    private var phoneSpacePage: (spaceID: String, side: CGFloat, preview: UIView)?
    private weak var phoneSpacePan: UIPanGestureRecognizer?

    var sidebarDragHasHoverProjection: Bool { isApplyingHoverProjection }

    var sidebarDragHasNativeHold: Bool {
        sourceSessionID != nil || dropSessionID != nil || spaceDropSessionID != nil || isCommittingDrop
            || isApplyingHoverProjection
    }

    private var pendingDropAnimations: Set<ObjectIdentifier> { activeSource?.pendingDropAnimations ?? [] }
    private var animationBatchID: UUID? { activeSource?.animationBatchID }

    private var isHoldingRows: Bool {
        sidebarDragHasNativeHold || activeSource?.isHoldingRows == true
    }

    private var canOpenSpaceDropTargets: Bool {
        guard workspace.isReady, let document = workspace.profileDocument, document.canEdit,
              let payload = activeSource, !payload.isCancelled, !payload.isCommitted, payload.document === document,
              payload.owner === self, sourceSessionID == payload.sourceSessionID,
              payload.spaceID == workspace.selectedSpaceID,
              acceptsSidebarDrops,
              view.window?.windowScene === dragScene,
              (document.snapshot.spaces ?? []).contains(where: { $0.id != payload.spaceID }) else { return false }
        return BrowserMobileSidebarDrop.source(items: payload.source.items, in: document.snapshot) == payload.source
    }

    private var acceptsSidebarDrops: Bool {
        !dragAdmissionSuspended && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    /// The line between pinned tabs and Today, when both have rows.
    private var showsPhoneDivider: Bool {
        rows.count > 2 && !rows[2].isEmpty && rows.prefix(2).contains { !$0.isEmpty }
    }

    init(
        workspace: BrowserMobileWorkspace,
        hoverScheduler: any BrowserMobileSidebarHoverScheduling = BrowserMobileSidebarHoverScheduler(),
        tableView: UITableView? = nil,
        isPhoneSheet: Bool = false,
    ) {
        self.workspace = workspace
        self.hoverScheduler = hoverScheduler
        self.suppliedTableView = tableView
        self.isPhoneSheet = isPhoneSheet
        super.init(style: isPhoneSheet ? .grouped : .insetGrouped)
        title = String(localized: "Tabs", table: "Mobile")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        if let suppliedTableView {
            tableView = suppliedTableView
        } else {
            super.loadView()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
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
            },
        )
        archiveButton = UIBarButtonItem(
            image: UIImage(systemName: "archivebox"), style: .plain,
            target: self, action: #selector(showArchive),
        )
        archiveButton.title = String(localized: "Archive", table: "Mobile")
        archiveButton.accessibilityIdentifier = "browser.archive"
        settingsButton = UIBarButtonItem(
            title: String(localized: "Settings", table: "Mobile"), image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.showSettings() },
        )
        settingsButton.accessibilityIdentifier = "browser.settings"
        // The sidebar's bar is too narrow for more: the Space's name heads the
        // rows, and Archive, the Spaces and Settings sit along the bottom.
        navigationItem.leftBarButtonItems = [navigationItem.leftBarButtonItem!]
        if !isPhoneSheet {
            navigationItem.title = ""
        }
        spaceButton.showsMenuAsPrimaryAction = true
        spaceButton.isSpringLoaded = false
        spaceButton.addTarget(self, action: #selector(showSpaceDropTargets), for: .primaryActionTriggered)
        spaceButton.addAction(UIAction { [weak self] _ in
            self?.workspace.dismissFindInPage()
        }, for: .menuActionTriggered)
        let behavior = SpaceSpringBehavior { [weak self] in self?.canOpenSpaceDropTargets == true }
        spaceButton.addInteraction(UISpringLoadedInteraction(
            interactionBehavior: behavior, interactionEffect: nil,
        ) { [weak spaceButton] _, _ in
            spaceButton?.sendActions(for: .primaryActionTriggered)
        })
        for name in [
            UIScene.willDeactivateNotification,
            UIScene.didActivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sidebarDragSceneChanged(_:)), name: name, object: nil,
            )
        }
        spaceButton.accessibilityIdentifier = "browser.spaces"
        spaceButton.titleLabel?.lineBreakMode = .byTruncatingTail
        spaceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if isPhoneSheet {
            configurePhoneSheet()
        } else {
            // One finger swipes a row to close it; two fingers, or two on the
            // trackpad, move between Spaces.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(phoneSpacePanned(_:)))
            pan.minimumNumberOfTouches = 2
            pan.allowedScrollTypesMask = .continuous
            pan.delegate = self
            tableView.addGestureRecognizer(pan)
            phoneSpacePan = pan
        }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // In line with the section titles.
        spaceHeaderLeading.constant = tableView.directionalLayoutMargins.leading + 20
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        spaceDropTopConstraint?.constant = tableView.safeAreaInsets.top + 8
        spaceDropBottomConstraint?.constant = -tableView.safeAreaInsets.bottom - 8
        let sides = (tableView.safeAreaInsets.left, tableView.safeAreaInsets.right)
        if isPhoneSheet, sides != renderedSideInsets {
            renderedSideInsets = sides
            // The selected row's highlight keeps clear of the sides.
            tableView.reconfigureRows(at: tableView.indexPathsForVisibleRows ?? [])
        }
    }

    override func numberOfSections(in _: UITableView) -> Int { rows.count }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        dragAdmissionSuspended = true
        terminalRefreshTask?.cancel()
        terminalRefreshTask = nil
        endSidebarDragForSceneLoss()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        dragAdmissionSuspended = view.window?.windowScene?.activationState != .foregroundActive
        render()
    }

    override func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if isPhoneSheet {
            return section == 2 && showsPhoneDivider ? 21 : .leastNormalMagnitude
        }
        return workspace.profileDocument == nil ? UITableView.automaticDimension : 44
    }

    override func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat {
        isPhoneSheet ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    override func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard isPhoneSheet, section == 2, showsPhoneDivider else { return nil }
        let header = UIView()
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.14)
        line.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 29),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -29),
            line.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return header
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.indices.contains(section) ? rows[section].count : 0
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard workspace.profileDocument != nil, !isPhoneSheet else { return nil }
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
        // In the phone sheet a sideways drag pages between Spaces.
        guard !isPhoneSheet, !isSelectingRows, workspace.isReady, workspace.profileDocument?.canEdit != false,
              case .tab(let id, _) = row(at: indexPath),
              let tab = workspace.tabs.first(where: { $0.id == id }) else { return nil }
        let removes = workspace.profileDocument != nil && tab.placement != .temporary
        let close = UIContextualAction(
            style: .destructive,
            title: removes
                ? String(localized: "Remove", table: "Mobile")
                : String(localized: "Close", table: "Mobile"),
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
        workspace.dismissFindInPage()
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.menu(for: row) })
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView, !isApplyingHoverProjection, let session = hoverDropSession else { return }
        _ = tableView(tableView, dropSessionDidUpdate: session, withDestinationIndexPath: nil)
    }

    func render() {
        guard isViewLoaded else { return }
        presentedArchive?.render()
        archiveButton.isHidden = !workspace.supportsArchive
        archiveButton.isEnabled = workspace.isReady && !isSelectingRows && !sidebarDragHasNativeHold
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
        updateSelectionButton()
        if let document = workspace.profileDocument {
            let configuration = spaceButtonConfiguration(title: phoneSpaceTitle(workspace.selectedSpaceID))
            spaceButton.configuration = configuration
            spaceButton.isEnabled = workspace.isReady
            spaceButton.menu = spaceMenu(document)
            if !isPhoneSheet, tableView.tableHeaderView !== spaceHeader {
                tableView.tableHeaderView = spaceHeader
            }
            applyRows(sharedRows(
                document.snapshot, spaceID: workspace.selectedSpaceID,
                available: Set(workspace.visibleTabs.map(\.id)), expanded: [],
            ), snapshot: document.snapshot)
        } else {
            if tableView.tableHeaderView === spaceHeader {
                tableView.tableHeaderView = nil
            }
            applyRows([workspace.tabs.map { .tab($0.id, depth: 0) }], snapshot: nil)
        }
        if isPhoneSheet {
            renderPhoneSheet(workspace.profileDocument)
        } else {
            renderSpaceBar()
        }
    }

    func tableView(
        _: UITableView,
        itemsForBeginning session: any UIDragSession,
        at indexPath: IndexPath,
    ) -> [UIDragItem] {
        let sessionID = ObjectIdentifier(session)
        if sourceSessionID == sessionID, let payload = activeSource {
            guard !payload.isCancelled, !payload.isCommitted, payload.document === workspace.profileDocument,
                  payload.spaceID == workspace.selectedSpaceID, let row = row(at: indexPath) else { return [] }
            return initialDragItem(for: row.reference)
        }
        guard !isHoldingRows, acceptsSidebarDrops, workspace.isReady, let document = workspace.profileDocument,
              document.canEdit,
              let row = row(at: indexPath) else { return [] }
        let requestedItems = isSelectingRows && selectedItems.contains(row.reference)
            ? rows.flatMap(\.self).map(\.reference).filter { selectedItems.contains($0) }
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
        let payload = BrowserMobileSidebarDragSession(
            owner: self,
            document: document,
            spaceID: workspace.selectedSpaceID,
            source: source,
            sourceSessionID: sessionID,
        )
        initialDragItems.removeAll(keepingCapacity: true)
        suppliedInitialItems.removeAll(keepingCapacity: true)
        for reference in source.items {
            let label = dragLabel(for: reference)
            let item = UIDragItem(itemProvider: NSItemProvider(object: label as NSString))
            item.localObject = payload
            initialDragItems[reference] = item
        }
        payload.setInitialItems(Array(initialDragItems.values))
        session.localContext = payload
        activeSource = payload
        observedDragMembershipRevision = payload.membershipRevision
        dragScene = view.window?.windowScene
        sourceSessionID = sessionID
        updateSelectionButton()
        becomeFirstResponder()
        return initialDragItem(for: row.reference)
    }

    func tableView(
        _ tableView: UITableView,
        itemsForAddingTo session: any UIDragSession,
        at indexPath: IndexPath,
        point: CGPoint,
    ) -> [UIDragItem] {
        guard acceptsSidebarDrops, workspace.isReady, let document = workspace.profileDocument, document.canEdit,
              let payload = activeSource, payload.canAddItems, ownsSidebarDrag(payload),
              session.localContext as? BrowserMobileSidebarDragSession === payload,
              ObjectIdentifier(session) == payload.sourceSessionID, payload.matches(session.items),
              renderedDocument === document, renderedSpaceID == workspace.selectedSpaceID,
              tableView.indexPathForRow(at: point) == indexPath, let row = row(at: indexPath),
              !payload.source.items.contains(row.reference), let snapshot = renderedSnapshot,
              let addition = BrowserMobileSidebarDrop.source(item: row.reference, in: snapshot)
        else { return [] }
        let references = Set(payload.source.items).union(addition.items)
        let ordered = rows.flatMap(\.self).map(\.reference).filter { references.contains($0) }
        guard let capturedGroup = BrowserMobileSidebarDrop.source(items: ordered, in: snapshot),
              capturedGroup.items == ordered,
              let extended = BrowserMobileSidebarDrop.extending(
                  source: payload.source, adding: addition, orderedItems: ordered, in: document.snapshot,
              ) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: dragLabel(for: row.reference) as NSString))
        item.localObject = payload
        guard payload.append(item, source: extended) else { return [] }
        initialDragItems[row.reference] = item
        suppliedInitialItems.insert(row.reference)
        if isSelectingRows {
            selectedItems.insert(row.reference)
            restoreRowSelection()
        }
        return [item]
    }

    func tableView(_: UITableView, dragSessionAllowsMoveOperation _: any UIDragSession) -> Bool { true }
    func tableView(_: UITableView, dragSessionIsRestrictedToDraggingApplication _: any UIDragSession) -> Bool { true }

    func tableView(_: UITableView, dragSessionDidEnd session: any UIDragSession) {
        guard sourceSessionID == ObjectIdentifier(session) else { return }
        cancelPendingFolderExpansion(clearSession: true)
        sourceSessionID = nil
        spaceDropClosing = true
        initialDragItems.removeAll(keepingCapacity: true)
        suppliedInitialItems.removeAll(keepingCapacity: true)
        activeSource?.notifyParticipants()
        finishInteractionIfPossible()
    }

    func tableView(_: UITableView, canHandle session: any UIDropSession) -> Bool { payload(for: session) != nil }

    func tableView(_: UITableView, dropSessionDidEnter session: any UIDropSession) {
        guard let payload = payload(for: session), joinSidebarDrag(payload) else { return }
        dropSessionID = ObjectIdentifier(session)
    }

    func tableView(_: UITableView, dropSessionDidExit session: any UIDropSession) {
        guard dropSessionID == ObjectIdentifier(session) else { return }
        cancelPendingFolderExpansion(clearSession: true)
        dropSessionID = nil
        hover = nil
        clearDropFeedback()
        activeSource?.notifyParticipants()
        finishInteractionIfPossible()
    }

    func tableView(_: UITableView, dropSessionDidEnd session: any UIDropSession) {
        guard dropSessionID == ObjectIdentifier(session) else { return }
        cancelPendingFolderExpansion(clearSession: true)
        dropSessionID = nil
        hover = nil
        clearDropFeedback()
        activeSource?.notifyParticipants()
        finishInteractionIfPossible()
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath _: IndexPath?,
    ) -> UITableViewDropProposal {
        clearDropFeedback()
        guard !isApplyingHoverProjection,
              let payload = payload(for: session), joinSidebarDrag(payload), let document = workspace.profileDocument,
              let target = dropTarget(at: session.location(in: tableView))
        else {
            cancelPendingFolderExpansion()
            hover = nil
            return .init(operation: .forbidden)
        }
        hoverDropSession = session
        dropSessionID = ObjectIdentifier(session)
        let canMove = validatedPlan(source: payload.source, target: target.target, snapshot: document.snapshot) != nil
        updateFolderExpansion(session: session, payload: payload, target: target)
        guard canMove else {
            hover = nil
            return .init(operation: .forbidden)
        }
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
                        .indentation,
                ),
                height: 2,
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
                : .insertIntoDestinationIndexPath,
        )
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: any UITableViewDropCoordinator) {
        guard !isApplyingHoverProjection, coordinator.proposal.operation == .move,
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
            activeSource?.notifyParticipants()
            finishInteractionIfPossible()
        }
        guard let batchID = commit(plan, document: document, payload: payload) else { return }
        let target = UIDragPreviewTarget(container: tableView, center: hover.point)
        for item in coordinator.items {
            let itemID = ObjectIdentifier(item.dragItem)
            coordinator.drop(item.dragItem, to: target).addCompletion { [payload] _ in
                payload.finishAnimation(itemID: itemID, batchID: batchID)
            }
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        isSpaceDropInteraction(interaction) && !spaceDropClosing && payload(for: session) != nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        guard dropInteraction(interaction, canHandle: session), let payload = payload(for: session),
              joinSidebarDrag(payload) else { return }
        spaceDropSessionID = ObjectIdentifier(session)
        spaceHoverDropSession = session
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: any UIDropSession,
    ) -> UIDropProposal {
        guard dropInteraction(interaction, canHandle: session), let palette = spaceDropController,
              let payload = payload(for: session), joinSidebarDrag(payload), let document = workspace.profileDocument
        else {
            if isSpaceDropInteraction(interaction) {
                spaceDropHover = nil
                spaceDropController?.highlight(nil)
            }
            return .init(operation: .forbidden)
        }
        spaceDropSessionID = ObjectIdentifier(session)
        spaceHoverDropSession = session
        guard let target = palette.target(at: session.location(in: palette.view)), target.isEnabled,
              validatedPlan(source: payload.source, target: target.plannerTarget, snapshot: document.snapshot) != nil
        else {
            spaceDropHover = nil
            palette.highlight(nil)
            return .init(operation: .forbidden)
        }
        spaceDropHover = target
        palette.highlight(target)
        return .init(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        endSpaceDropHover(interaction, session: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        endSpaceDropHover(interaction, session: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard !isApplyingHoverProjection, dropInteraction(interaction, canHandle: session),
              let palette = spaceDropController,
              let payload = payload(for: session), let document = workspace.profileDocument,
              spaceDropSessionID == ObjectIdentifier(session), let target = spaceDropHover,
              palette.target(at: session.location(in: palette.view)) == target, target.isEnabled,
              let plan = validatedPlan(
                  source: payload.source,
                  target: target.plannerTarget,
                  snapshot: document.snapshot,
              )
        else { return }
        isCommittingDrop = true
        defer {
            isCommittingDrop = false
            activeSource?.notifyParticipants()
            finishInteractionIfPossible()
        }
        guard let batchID = commit(plan, document: document, payload: payload) else { return }
        spaceDropBatchID = batchID
        spaceDropBatchSessionID = ObjectIdentifier(session)
        spaceDropPreviewTarget = target
        spaceDropClosing = true
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, previewForDropping item: UIDragItem,
        withDefault defaultPreview: UITargetedDragPreview,
    ) -> UITargetedDragPreview? {
        guard isSpaceDropInteraction(interaction), spaceDropBatchID == animationBatchID,
              pendingDropAnimations.contains(ObjectIdentifier(item)), let target = spaceDropPreviewTarget,
              let previewTarget = spaceDropController?.previewTarget(for: target) else { return nil }
        return defaultPreview.retargetedPreview(with: previewTarget)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, item: UIDragItem, willAnimateDropWith animator: any UIDragAnimating,
    ) {
        let itemID = ObjectIdentifier(item)
        guard isSpaceDropInteraction(interaction), let token = activeSource,
              let batchID = spaceDropBatchID, batchID == animationBatchID,
              pendingDropAnimations.contains(itemID),
              registeredSpaceDropAnimations.insert(itemID).inserted else { return }
        animator.addCompletion { [token] _ in
            token.finishAnimation(itemID: itemID, batchID: batchID)
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, concludeDrop session: any UIDropSession) {
        // UIKit calls this after every drop animation, including non-visible items.
        guard isSpaceDropInteraction(interaction), spaceDropBatchSessionID == ObjectIdentifier(session),
              let batchID = spaceDropBatchID, batchID == animationBatchID else { return }
        activeSource?.concludeAnimations(batchID: batchID)
    }

    func tabMenu(id: String) -> UIMenu? {
        guard !isSelectingRows, let tab = workspace.tabs.first(where: { $0.id == id }) else { return nil }
        guard let document = workspace.profileDocument else {
            return UIMenu(children: [UIAction(
                title: String(localized: "Close Tab", table: "Mobile"),
                image: UIImage(systemName: "xmark"),
                attributes: .destructive,
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
                attributes: disabled,
            ) { [weak document] _ in
                document?.setTabPinned(id: id, isPinned: tab.placement != .spacePinned)
            })
        }
        actions.append(UIAction(
            title: tab.placement == .app
                ? String(localized: "Remove from Favorites", table: "Mobile")
                : String(localized: "Add to Favorites", table: "Mobile"),
            image: UIImage(systemName: "star"),
            attributes: disabled,
        ) { [weak self, weak document] _ in
            document?.setPlacement(
                tabID: id,
                placement: tab.placement == .app ? .temporary : .app,
                spaceID: tab.placement == .app ? self?.workspace.selectedSpaceID : nil,
            )
        })
        actions.append(UIAction(
            title: String(localized: "Rename", table: "Mobile"),
            image: UIImage(systemName: "pencil"),
            attributes: disabled,
        ) { [weak self, weak document] _ in
            let latest = self?.workspace.tabs.first { $0.id == id }
            self?.prompt(
                title: String(localized: "Rename", table: "Mobile"),
                value: latest?.userTitleOverride ?? latest?.title ?? "",
                allowsEmpty: true,
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
            attributes: disabled.union(.destructive),
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
                attributes: disabled,
            ) { [weak self, weak document] _ in
                guard let value = document?.snapshot.pinnedTabFolders?.first(where: { $0.id == id })?.title
                else { return }
                self?
                    .prompt(title: String(localized: "Rename", table: "Mobile"), value: value) { [weak document] in
                        document?.renameFolder(
                            id: id,
                            title: $0,
                        )
                    }
            },
            UIAction(
                title: String(localized: "New Folder", table: "Mobile"),
                image: UIImage(systemName: "folder.badge.plus"),
                attributes: disabled,
            ) { [weak self, weak document] _ in
                guard let current = document?.snapshot.pinnedTabFolders?.first(where: { $0.id == id }) else { return }
                self?.createFolder(spaceID: current.spaceID, parent: id)
            },
            moveMenu(item: .init(entityType: .folder, entityID: id), document: document),
            UIAction(
                title: String(localized: "Delete Folder and Contents", table: "Mobile"),
                image: UIImage(systemName: "trash"),
                attributes: disabled.union(.destructive),
            ) { [weak self, weak document] _ in
                self?.confirmFolderRemoval(title: folder.title) { [weak document] in document?.delete(entity: .init(
                    entityType: .folder,
                    entityID: id,
                )) }
            },
        ])
    }

    func sidebarDragSessionDidChange(_ session: BrowserMobileSidebarDragSession) {
        guard activeSource === session else { return }
        if observedDragMembershipRevision != session.membershipRevision {
            observedDragMembershipRevision = session.membershipRevision
            cancelPendingFolderExpansion(clearSession: true)
            hover = nil
            spaceDropHover = nil
            spaceHoverDropSession = nil
            planCache = nil
            folderExpansionCache = nil
            clearDropFeedback()
            spaceDropController?.setIncludesFolders(session.source.items.contains { $0.entityType == .folder })
            spaceDropController?.highlight(nil)
        }
        if session.isCancelled || session.isCommitted {
            cancelPendingFolderExpansion(clearSession: true)
            spaceHoverDropSession = nil
        }
        if session.isCancelled {
            spaceDropClosing = true
            spaceDropHover = nil
            hover = nil
            clearDropFeedback()
            spaceDropController?.highlight(nil)
            if pendingDropAnimations.isEmpty {
                spaceDropController?.view.isHidden = true
            }
        }
        if session.isCommitted {
            needsStructuralRefresh = true
        }
        finishInteractionIfPossible()
    }

    func updateSidebarDragSceneState(_ state: UIScene.ActivationState) {
        switch state {
        case .foregroundActive: dragAdmissionSuspended = false
        case .foregroundInactive:
            cancelPendingFolderExpansion(clearSession: true)
            dragAdmissionSuspended = true
            hover = nil
            spaceDropHover = nil
            spaceHoverDropSession = nil
            clearDropFeedback()
            spaceDropController?.highlight(nil)
        case .background,
             .unattached:
            dragAdmissionSuspended = true
            endSidebarDragForSceneLoss()
        @unknown default:
            dragAdmissionSuspended = true
            endSidebarDragForSceneLoss()
        }
    }

    @objc func showArchive() {
        guard workspace.supportsArchive, presentedViewController == nil,
              !isSelectingRows, !sidebarDragHasNativeHold else { return }
        workspace.dismissFindInPage()
        let controller = BrowserMobileArchiveViewController(workspace: workspace)
        controller.didRestore = { [weak self] in self?.didSelectTab?() }
        presentedArchive = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    /// Goes to the Space `offset` places from the current one, if there is one.
    func showSpace(offset: Int) {
        let spaces = workspace.spaces
        guard workspace.isReady, !isHoldingRows,
              let index = spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }),
              spaces.indices.contains(index + offset) else { return }
        selectPhoneSpace(spaces[index + offset].id)
    }

    /// The sidebar's Space name with the menu's chevron.
    private func spaceButtonConfiguration(title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold),
        )
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 5
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFont.systemFont(ofSize: 22, weight: .bold)
            return attributes
        }
        return configuration
    }

    private func configurePhoneSheet() {
        title = nil
        tableView.backgroundColor = Self.phoneSheetColor
        tableView.separatorStyle = .none
        tableView.rowHeight = 56
        tableView.estimatedRowHeight = 56
        tableView.sectionHeaderTopPadding = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        // A grouped table leaves room above its first section without a header view.
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
        tableView.showsVerticalScrollIndicator = false
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        navigationItem.standardAppearance = bar
        navigationItem.scrollEdgeAppearance = bar
        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = UIColor(white: 0.26, alpha: 1)
        toolbar.shadowColor = .clear
        navigationController?.toolbar.standardAppearance = toolbar
        navigationController?.toolbar.scrollEdgeAppearance = toolbar
        navigationController?.view.backgroundColor = Self.phoneSheetColor
        phoneTitleButton.showsMenuAsPrimaryAction = true
        phoneTitleButton.accessibilityIdentifier = "browser.spaces"
        phoneTitleButton.contentHorizontalAlignment = .leading
        phoneTitleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        let title = UIBarButtonItem(customView: phoneTitleButton)
        title.hidesSharedBackground = true
        // New Tab, Archive and Account live in the switcher and Settings.
        navigationItem.leftBarButtonItems = [title]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(phoneSpacePanned(_:)))
        pan.delegate = self
        tableView.addGestureRecognizer(pan)
        phoneSpacePan = pan
    }

    private func setPhoneTitle(_ title: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.white,
            ]),
        )
        configuration.contentInsets = .init(top: 0, leading: 12, bottom: 0, trailing: 0)
        configuration.titleLineBreakMode = .byTruncatingTail
        phoneTitleButton.configuration = configuration
    }

    private func highlightPhoneSpace(_ id: String?) {
        for (spaceID, item) in phoneSpaceItems {
            item.tintColor =
                if isPhoneSheet {
                    spaceID == id ? .white : UIColor(white: 1, alpha: 0.3)
                } else {
                    spaceID == id ? .label : .tertiaryLabel
                }
            item.accessibilityTraits = spaceID == id ? [.button, .selected] : [.button]
        }
    }

    private func phoneSpaceTitle(_ id: String?) -> String {
        workspace.spaces.first { $0.id == id }?.title ?? String(localized: "Spaces", table: "Mobile")
    }

    @objc private func phoneSpacePanned(_ gesture: UIPanGestureRecognizer) {
        let width = tableView.bounds.width
        guard let host = tableView.superview else { return }
        let dx = gesture.translation(in: host).x
        let spaces = workspace.spaces
        guard let index = spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }) else { return }
        switch gesture.state {
        case .began, .changed:
            // Dragging left brings in the next Space, right the previous one.
            let side: CGFloat = dx < 0 ? 1 : -1
            let neighbor = index + Int(side)
            var offset = dx
            if dx != 0, spaces.indices.contains(neighbor) {
                if phoneSpacePage?.spaceID != spaces[neighbor].id {
                    phoneSpacePage?.preview.removeFromSuperview()
                    let preview = phoneSpacePreview(for: spaces[neighbor].id)
                    host.insertSubview(preview, aboveSubview: tableView)
                    phoneSpacePage = (spaces[neighbor].id, side, preview)
                }
            } else {
                phoneSpacePage?.preview.removeFromSuperview()
                phoneSpacePage = nil
                // No Space that way: the rows give only a little.
                offset = dx / (1 + abs(dx) / 120)
            }
            layoutPhoneSpacePage(offset: offset, width: width)
        case .cancelled, .ended, .failed:
            let velocity = gesture.velocity(in: host).x
            let page = phoneSpacePage
            let completes = gesture.state == .ended && page.map { page in
                let projected = dx + velocity * 0.15
                return -projected * page.side > width / 2
            } ?? false
            UIView.animate(springDuration: 0.32, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [
                .allowUserInteraction, .beginFromCurrentState,
            ]) {
                self.layoutPhoneSpacePage(offset: completes ? -(page?.side ?? 0) * width : 0, width: width)
            } completion: { _ in
                self.phoneSpacePage?.preview.removeFromSuperview()
                self.phoneSpacePage = nil
                self.tableView.transform = .identity
                self.phoneTitleButton.alpha = 1
                if completes, let page {
                    self.workspace.dismissFindInPage()
                    self.workspace.selectSpace(id: page.spaceID)
                    self.render()
                    self.tableView.setContentOffset(
                        CGPoint(x: 0, y: -self.tableView.adjustedContentInset.top), animated: false,
                    )
                } else {
                    self.render()
                }
            }
        default: break
        }
    }

    /// Moves the rows by `offset`, the neighbor's beside them, and crossfades
    /// the title and the Space under the rows at the halfway point.
    private func layoutPhoneSpacePage(offset: CGFloat, width: CGFloat) {
        tableView.transform = CGAffineTransform(translationX: offset, y: 0)
        let progress = min(abs(offset) / max(width, 1), 1)
        if let page = phoneSpacePage {
            page.preview.center = CGPoint(
                x: tableView.center.x + offset + page.side * width, y: tableView.center.y,
            )
        }
        let past = progress > 0.5 && phoneSpacePage != nil
        let shownID = past ? phoneSpacePage?.spaceID : workspace.selectedSpaceID
        // The sidebar's name heads the rows and slides with them.
        if isPhoneSheet {
            setPhoneTitle(phoneSpaceTitle(shownID))
            phoneTitleButton.alpha = abs(1 - progress * 2)
        }
        highlightPhoneSpace(shownID)
    }

    /// The rows another Space would show, laid out like the table at its top.
    private func phoneSpacePreview(for spaceID: String) -> UIView {
        let preview = UIView(frame: CGRect(origin: .zero, size: tableView.bounds.size))
        preview.backgroundColor = isPhoneSheet ? Self.phoneSheetColor : tableView.backgroundColor
        preview.clipsToBounds = true
        preview.isUserInteractionEnabled = false
        guard let document = workspace.profileDocument else { return preview }
        let tabs = workspace.tabs.filter { $0.placement == .app || $0.spaceID == spaceID }
        let sections = sharedRows(
            document.snapshot, spaceID: spaceID, available: Set(tabs.map(\.id)), expanded: [],
        )
        // Choosing the Space keeps the open tab only when it is in that Space.
        let selected = tabs.contains { $0.id == workspace.selectedTabID } ? workspace.selectedTabID : tabs.first?.id
        let width = tableView.bounds.width
        // Inset rows in the sidebar.
        let rowX = tableView.visibleCells.first?.frame.minX ?? 0
        let rowWidth = tableView.visibleCells.first?.frame.width ?? width
        let rowHeight = tableView.rowHeight > 0 ? tableView.rowHeight : tableView.visibleCells.first?.frame.height ?? 44
        var y = tableView.adjustedContentInset.top + (rows.isEmpty ? 0 : tableView.rect(forSection: 0).minY)
        if !isPhoneSheet {
            let name = UIButton(configuration: spaceButtonConfiguration(title: phoneSpaceTitle(spaceID)))
            name.sizeToFit()
            name.frame = CGRect(
                x: spaceHeaderLeading.constant, y: tableView.adjustedContentInset.top + (44 - name.bounds.height) / 2,
                width: min(name.bounds.width, width - spaceHeaderLeading.constant - 20), height: name.bounds.height,
            )
            preview.addSubview(name)
        }
        let divides = isPhoneSheet && sections.count > 2 && !sections[2].isEmpty
            && sections.prefix(2).contains { !$0.isEmpty }
        for (section, sectionRows) in sections.enumerated() {
            if !isPhoneSheet, section < tableView.numberOfSections {
                // The sections' titles are the same in every Space.
                let header = tableView.rectForHeader(inSection: section)
                if let title = tableView.headerView(forSection: section)?.snapshotView(afterScreenUpdates: false) {
                    title.frame.origin = CGPoint(x: header.minX, y: y)
                    preview.addSubview(title)
                }
                y += header.height
            }
            if section == 2, divides {
                let line = UIView(frame: CGRect(x: 29, y: y + 10, width: width - 58, height: 1))
                line.backgroundColor = UIColor(white: 1, alpha: 0.14)
                preview.addSubview(line)
                y += 21
            }
            for row in sectionRows {
                guard y < preview.bounds.height else { return preview }
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.frame = CGRect(x: rowX, y: y, width: rowWidth, height: rowHeight)
                configure(cell, row: row, selectedTabID: selected)
                cell.layoutIfNeeded()
                preview.addSubview(cell)
                y += rowHeight
            }
            if !isPhoneSheet, section < tableView.numberOfSections {
                y += tableView.rectForFooter(inSection: section).height
            }
        }
        return preview
    }

    private func renderPhoneSheet(_ document: BrowserMobileProfileDocument?) {
        guard phoneSpacePage == nil else { return }
        setPhoneTitle(phoneSpaceTitle(workspace.selectedSpaceID))
        phoneTitleButton.menu = document.map(spaceMenu)
        phoneTitleButton.isEnabled = workspace.isReady && document != nil
        phoneTitleButton.frame.size = CGSize(width: max(view.bounds.width - 140, 120), height: 44)
        var items = [UIBarButtonItem.flexibleSpace()]
        phoneSpaceItems.removeAll()
        for (index, space) in workspace.spaces.enumerated() {
            if index > 0 { items.append(.fixedSpace(28)) }
            let selected = space.id == workspace.selectedSpaceID
            let item = UIBarButtonItem(
                title: space.title, image: UIImage(systemName: space.systemImageName),
                primaryAction: UIAction { [weak self] _ in self?.selectPhoneSpace(space.id) },
            )
            item.tintColor = selected ? .white : UIColor(white: 1, alpha: 0.3)
            item.hidesSharedBackground = true
            item.accessibilityTraits = selected ? [.button, .selected] : [.button]
            phoneSpaceItems[space.id] = item
            items.append(item)
        }
        items.append(.flexibleSpace())
        setToolbarItems(workspace.spaces.count > 1 ? items : [], animated: false)
    }

    /// The sidebar's bottom bar: Archive, the Spaces as icons when they fit,
    /// and Settings.
    private func renderSpaceBar() {
        guard phoneSpacePage == nil else { return }
        var items = [UIBarButtonItem]()
        phoneSpaceItems.removeAll()
        if workspace.supportsArchive {
            items.append(archiveButton)
        }
        items.append(.flexibleSpace())
        let spaces = workspace.profileDocument == nil ? [] : workspace.spaces
        let fitting = Int((view.bounds.width - 140) / Self.spaceBarItemWidth)
        if spaces.count > 1, spaces.count <= max(fitting, 2) {
            for space in spaces {
                let selected = space.id == workspace.selectedSpaceID
                let item = UIBarButtonItem(
                    title: space.title, image: UIImage(systemName: space.systemImageName),
                    primaryAction: UIAction { [weak self] _ in self?.selectPhoneSpace(space.id) },
                )
                item.tintColor = selected ? .label : .tertiaryLabel
                item.isEnabled = workspace.isReady && !isSelectingRows && !sidebarDragHasNativeHold
                item.accessibilityIdentifier = "browser.space.\(space.id)"
                item.accessibilityTraits = selected ? [.button, .selected] : [.button]
                phoneSpaceItems[space.id] = item
                items.append(item)
            }
            items.append(.flexibleSpace())
        }
        items.append(settingsButton)
        setToolbarItems(items, animated: false)
    }

    private func selectPhoneSpace(_ id: String) {
        guard id != workspace.selectedSpaceID else { return }
        workspace.dismissFindInPage()
        UIView.transition(with: tableView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.workspace.selectSpace(id: id)
            self.render()
        }
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
        // The phone sheet closes tabs from each row's menu and has no Select.
        navigationItem.rightBarButtonItems = isPhoneSheet
            ? nonSelectionRightButtons
            : isSelectingRows ? [selectionButton] : nonSelectionRightButtons + [selectionButton]
    }

    private func restoreRowSelection() {
        for index in tableView.indexPathsForSelectedRows ?? []
            where !isSelectingRows || row(at: index).map({ !selectedItems.contains($0.reference) }) != false
        {
            tableView.deselectRow(at: index, animated: false)
        }
        if isSelectingRows {
            for item in selectedItems {
                if let index = indexPath(for: item) {
                    tableView.selectRow(
                        at: index,
                        animated: false,
                        scrollPosition: .none,
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
                table: "Mobile",
            )
        case .space: String(localized: "Spaces", table: "Mobile")
        }
    }

    private func initialDragItem(for reference: BrowserSyncEntityReference) -> [UIDragItem] {
        guard let item = initialDragItems[reference], suppliedInitialItems.insert(reference).inserted else { return [] }
        return [item]
    }

    private func configure(_ cell: UITableViewCell, at indexPath: IndexPath) {
        configure(cell, row: row(at: indexPath), selectedTabID: workspace.selectedTabID)
    }

    private func configure(_ cell: UITableViewCell, row: Row?, selectedTabID: String?) {
        cell.accessoryType = .none
        cell.accessibilityTraits = [.button]
        cell.accessibilityIdentifier = nil
        cell.accessibilityValue = nil
        cell.indentationWidth = 16
        cell.indentationLevel = 0
        cell.contentConfiguration = nil
        cell.backgroundConfiguration = .listCell()
        var content = cell.defaultContentConfiguration()
        switch row {
        case .tab(let id, let depth):
            guard let tab = renderedTabs[id] else { return }
            content.text = displayTitle(tab)
            // The site, as the address field shows it outside editing.
            let site = BrowserMobilePageViewController.displayAddress(tab.urlString)
            content.secondaryText = site.isEmpty ? nil : site
            content.secondaryTextProperties.numberOfLines = 1
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            content.image = UIImage(systemName: tab.state.error == nil ? "globe" : "exclamationmark.circle")
            cell.indentationLevel = depth
            cell.accessoryType = !isSelectingRows && selectedTabID == id ? .checkmark : .none
            cell.accessibilityIdentifier = "browser.tab." + id
            cell.accessibilityTraits = (isSelectingRows
                ? selectedItems.contains(.init(entityType: .tab, entityID: id))
                : selectedTabID == id)
                ? [.button, .selected]
                : [.button]
        case .folder(let id, let depth):
            guard let folder = renderedSnapshot?.pinnedTabFolders?.first(where: { $0.id == id })
            else { return }
            let isExpanded = folder.isExpanded || transientExpandedFolderIDs.contains(id)
            content.text = folder.title
            content
                .image = UIImage(systemName: folder.systemImageName ?? (isExpanded ? "folder.fill" : "folder"))
            cell.indentationLevel = depth
            cell.accessoryType = isSelectingRows || isExpanded ? .none : .disclosureIndicator
            if isSelectingRows,
               selectedItems
                .contains(.init(entityType: .folder, entityID: id))
            {
                cell.accessibilityTraits.insert(.selected)
            }
            cell.accessibilityIdentifier = "browser.folder." + id
            cell.accessibilityValue = isExpanded
                ? String(localized: "Expanded", table: "Mobile")
                : String(localized: "Collapsed", table: "Mobile")
        case nil: break
        }
        if isPhoneSheet {
            stylePhoneSheet(cell, content: &content, row: row, selectedTabID: selectedTabID)
        }
        cell.contentConfiguration = content
    }

    private func stylePhoneSheet(
        _ cell: UITableViewCell, content: inout UIListContentConfiguration, row: Row?, selectedTabID: String?,
    ) {
        content.secondaryText = nil
        content.textProperties.font = .systemFont(ofSize: 17)
        content.textProperties.color = .white
        content.textProperties.numberOfLines = 1
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
        content.imageProperties.cornerRadius = 4
        content.imageProperties.tintColor = .white
        content.imageToTextPadding = 10
        content.directionalLayoutMargins.leading = 28
        var background = UIBackgroundConfiguration.clear()
        switch row {
        case .tab(let id, _):
            if let tab = renderedTabs[id], tab.state.error == nil,
               let icon = BrowserMobileFavicons.shared.iconOnDark(forPage: tab.urlString)
            {
                content.image = icon
            }
            if !isSelectingRows {
                cell.accessoryType = .none
                if selectedTabID == id {
                    background.backgroundColor = UIColor(white: 1, alpha: 0.08)
                    background.cornerRadius = 12
                    // Clear of a status column at the side (iPhone Duo), as the rows' text is.
                    let safe = tableView.safeAreaInsets
                    background.backgroundInsets = .init(
                        top: 2, leading: 12 + safe.left, bottom: 2, trailing: 12 + safe.right,
                    )
                }
            }
        case .folder(let id, _):
            let folder = renderedSnapshot?.pinnedTabFolders?.first { $0.id == id }
            let isExpanded = folder?.isExpanded == true || transientExpandedFolderIDs.contains(id)
            if folder?.systemImageName == nil {
                content.image = UIImage(systemName: isExpanded ? "folder" : "folder.fill")
            }
            cell.accessoryType = .none
        case nil: break
        }
        cell.backgroundConfiguration = background
    }

    private func ownsSidebarDrag(_ payload: BrowserMobileSidebarDragSession) -> Bool {
        payload.owner === self && activeSource === payload && sourceSessionID == payload.sourceSessionID
            && payload.document === workspace.profileDocument && payload.spaceID == workspace.selectedSpaceID
            && viewIfLoaded?.window?.windowScene === dragScene
            && dragScene
            .map { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive } == true
    }

    private func payload(for session: any UIDropSession) -> BrowserMobileSidebarDragSession? {
        guard acceptsSidebarDrops, workspace.isReady, let document = workspace.profileDocument, document.canEdit,
              session.allowsMoveOperation, let local = session.localDragSession,
              let payload = local.localContext as? BrowserMobileSidebarDragSession,
              payload.document === document, !payload.isCancelled, !payload.isCommitted,
              activeSource == nil || activeSource === payload,
              payload.owner?.ownsSidebarDrag(payload) == true,
              ObjectIdentifier(local) == payload.sourceSessionID,
              renderedDocument === document, renderedSpaceID == workspace.selectedSpaceID,
              matches(session.items, payload: payload), matches(local.items, payload: payload)
        else { return nil }
        return payload
    }

    private func joinSidebarDrag(_ payload: BrowserMobileSidebarDragSession) -> Bool {
        guard activeSource == nil || activeSource === payload else { return false }
        if activeSource !== payload {
            cancelPendingFolderExpansion(clearSession: true)
            observedDragMembershipRevision = payload.membershipRevision
        }
        activeSource = payload
        dragScene = view.window?.windowScene
        payload.register(self)
        updateSelectionButton()
        return true
    }

    private func matches(_ items: [UIDragItem], payload: BrowserMobileSidebarDragSession) -> Bool {
        payload.matches(items)
    }

    private func cancelPendingFolderExpansion(clearSession: Bool = false) {
        hoverScheduler.cancel()
        folderHoverCandidate = nil
        if clearSession {
            hoverDropSession = nil
        }
    }

    private func updateFolderExpansion(
        session: any UIDropSession, payload: BrowserMobileSidebarDragSession, target: DropHover,
    ) {
        guard let index = target.insideFolder, case .folder(let folderID, _) = row(at: index),
              !transientExpandedFolderIDs.contains(folderID),
              renderedSnapshot?.pinnedTabFolders?.first(where: { $0.id == folderID })?.isExpanded == false,
              let document = workspace.profileDocument,
              canExpandFolder(source: payload.source, target: target.target, snapshot: document.snapshot)
        else { cancelPendingFolderExpansion()
            return
        }
        if let candidate = folderHoverCandidate, candidate.tokenID == ObjectIdentifier(payload),
           candidate.sessionID == ObjectIdentifier(session), candidate.folderID == folderID,
           candidate.target == target.target
        {
            if candidate.isDue {
                expandHoveredFolder(generation: candidate.generation)
            }
            return
        }
        cancelPendingFolderExpansion()
        let generation = UUID()
        folderHoverCandidate = .init(
            tokenID: ObjectIdentifier(payload), sessionID: ObjectIdentifier(session), folderID: folderID,
            target: target.target, generation: generation,
        )
        hoverScheduler.schedule(after: .milliseconds(600)) { [weak self] in
            guard let self, folderHoverCandidate?.generation == generation else { return }
            folderHoverCandidate?.isDue = true
            expandHoveredFolder(generation: generation)
        }
    }

    private func canExpandFolder(
        source: BrowserMobileSidebarDrop.Source, target: BrowserMobileSidebarDrop.Target,
        snapshot: BrowserTabSessionSnapshot,
    ) -> Bool {
        if let cache = folderExpansionCache, cache.source == source, cache.target == target,
           cache.snapshot == snapshot
        {
            return cache.isEligible
        }
        let eligible = BrowserMobileSidebarDrop.canExpandFolder(source: source, target: target, in: snapshot)
        folderExpansionCache = .init(source: source, target: target, snapshot: snapshot, isEligible: eligible)
        return eligible
    }

    private func scheduleFolderExpansionRetry(generation: UUID) {
        guard var candidate = folderHoverCandidate, candidate.generation == generation,
              !candidate.retryScheduled, candidate.retryCount < 10 else { return }
        candidate.retryScheduled = true
        candidate.retryCount += 1
        folderHoverCandidate = candidate
        // One bounded retry chain lets stationary hover outlast UIKit's short
        // insertion/gap transaction. Later native events may retry a due folder.
        hoverScheduler.schedule(after: .milliseconds(50)) { [weak self] in
            guard let self, folderHoverCandidate?.generation == generation else { return }
            folderHoverCandidate?.retryScheduled = false
            expandHoveredFolder(generation: generation)
        }
    }

    private func expandHoveredFolder(generation: UUID) {
        guard let candidate = folderHoverCandidate, candidate.generation == generation, candidate.isDue,
              !isApplyingHoverProjection, let session = hoverDropSession,
              ObjectIdentifier(session) == candidate.sessionID,
              let payload = payload(for: session), ObjectIdentifier(payload) == candidate.tokenID,
              dropSessionID == candidate.sessionID,
              let target = dropTarget(at: session.location(in: tableView)), target.target == candidate.target,
              let index = target.insideFolder, row(at: index)?.reference.entityID == candidate.folderID,
              let snapshot = renderedSnapshot, let document = workspace.profileDocument,
              canExpandFolder(source: payload.source, target: target.target, snapshot: document.snapshot)
        else { cancelPendingFolderExpansion()
            return
        }
        guard !tableView.hasUncommittedUpdates else {
            scheduleFolderExpansionRetry(generation: generation)
            return
        }
        var expanded = transientExpandedFolderIDs
        expanded.insert(candidate.folderID)
        let nextRows = sharedRows(
            snapshot,
            spaceID: renderedSpaceID,
            available: renderedAvailableTabIDs,
            expanded: expanded,
        )
        let previousRows = rows
        let previousIDs = Set(previousRows.flatMap(\.self).map(\.reference))
        let insertions = nextRows.enumerated().flatMap { section, values in
            values.enumerated().compactMap { row, item in
                previousIDs.contains(item.reference) ? nil : IndexPath(row: row, section: section)
            }
        }
        // Expansion may only reveal descendants; no source or existing target
        // may move because a concurrent document update has been deferred.
        guard zip(previousRows, nextRows).allSatisfy({ old, new in
            new.filter { previousIDs.contains($0.reference) } == old
        }) else { cancelPendingFolderExpansion()
            return
        }
        cancelPendingFolderExpansion()
        isApplyingHoverProjection = true
        transientExpandedFolderIDs = expanded
        needsStructuralRefresh = true
        hover = nil
        clearDropFeedback()
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates {
                self.rows = nextRows
                self.tableView.insertRows(at: insertions, with: .none)
            } completion: { [weak self, payload] _ in
                guard let self else { payload.notifyParticipants()
                    return
                }
                isApplyingHoverProjection = false
                if let folderIndex = indexPath(for: .init(entityType: .folder, entityID: candidate.folderID)),
                   let cell = tableView.cellForRow(at: folderIndex)
                {
                    configure(cell, at: folderIndex)
                }
                restoreRowSelection()
                payload.notifyParticipants()
                if let session = hoverDropSession {
                    _ = tableView(tableView, dropSessionDidUpdate: session, withDestinationIndexPath: nil)
                }
                finishInteractionIfPossible()
            }
        }
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
                indentation: CGFloat(row.depth) * 16,
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
                    point: CGPoint(x: rect.midX, y: tableView.rectForRow(at: .init(row: 0, section: section)).minY),
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
                point: CGPoint(x: rect.midX, y: boundaryY),
            )
        }
        return nil
    }

    @objc private func showSpaceDropTargets() {
        guard spaceDropController == nil, canOpenSpaceDropTargets, let payload = activeSource,
              let document = workspace.profileDocument else { return }
        let palette = BrowserMobileSpaceDropViewController(
            spaces: (document.snapshot.spaces ?? []).filter { $0.id != payload.spaceID },
            includesFolders: payload.source.items.contains { $0.entityType == .folder },
            dropDelegate: self,
        )
        palette.onScroll = { [weak self, weak palette] interaction in
            guard let self, let palette, spaceDropController === palette,
                  isSpaceDropInteraction(interaction), let session = spaceHoverDropSession,
                  spaceDropSessionID == ObjectIdentifier(session) else { return }
            _ = dropInteraction(interaction, sessionDidUpdate: session)
        }
        cancelPendingFolderExpansion(clearSession: true)
        spaceDropClosing = false
        spaceDropController = palette
        addChild(palette)
        palette.view.translatesAutoresizingMaskIntoConstraints = false
        tableView.addSubview(palette.view)
        let top = palette.view.topAnchor.constraint(
            equalTo: tableView.frameLayoutGuide.topAnchor, constant: tableView.safeAreaInsets.top + 8,
        )
        let bottom = palette.view.bottomAnchor.constraint(
            lessThanOrEqualTo: tableView.frameLayoutGuide.bottomAnchor, constant: -tableView.safeAreaInsets.bottom - 8,
        )
        spaceDropTopConstraint = top
        spaceDropBottomConstraint = bottom
        let height = palette.view.heightAnchor.constraint(equalToConstant: 400)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            palette.view.leadingAnchor.constraint(equalTo: tableView.frameLayoutGuide.leadingAnchor, constant: 8),
            palette.view.trailingAnchor.constraint(equalTo: tableView.frameLayoutGuide.trailingAnchor, constant: -8),
            top,
            bottom,
            height,
        ])
        palette.didMove(toParent: self)
        tableView.bringSubviewToFront(palette.view)
        hover = nil
        clearDropFeedback()
    }

    private func isSpaceDropInteraction(_ interaction: UIDropInteraction) -> Bool {
        guard let palette = spaceDropController else { return false }
        return interaction.view === palette.view
    }

    private func endSpaceDropHover(_ interaction: UIDropInteraction, session: any UIDropSession) {
        guard isSpaceDropInteraction(interaction), spaceDropSessionID == ObjectIdentifier(session) else { return }
        spaceDropSessionID = nil
        spaceHoverDropSession = nil
        spaceDropHover = nil
        spaceDropController?.highlight(nil)
        activeSource?.notifyParticipants()
        finishInteractionIfPossible()
    }

    private func dismissSpaceDropTargetsIfPossible() {
        guard spaceDropClosing, !isHoldingRows, let palette = spaceDropController else { return }
        // Once admission is cancelled no destination callback can mutate state.
        // The preview container stays alive until its last animation completes.
        spaceDropSessionID = nil
        spaceHoverDropSession = nil
        spaceDropHover = nil
        spaceDropBatchID = nil
        spaceDropBatchSessionID = nil
        spaceDropPreviewTarget = nil
        registeredSpaceDropAnimations.removeAll()
        palette.willMove(toParent: nil)
        palette.view.removeFromSuperview()
        palette.removeFromParent()
        spaceDropController = nil
        spaceDropTopConstraint = nil
        spaceDropBottomConstraint = nil
    }

    @objc private func sidebarDragSceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === (dragScene ?? viewIfLoaded?.window?.windowScene) else { return }
        switch notification.name {
        case UIScene.willDeactivateNotification: updateSidebarDragSceneState(.foregroundInactive)
        case UIScene.didActivateNotification: updateSidebarDragSceneState(.foregroundActive)
        case UIScene.didEnterBackgroundNotification: updateSidebarDragSceneState(.background)
        case UIScene.didDisconnectNotification: updateSidebarDragSceneState(.unattached)
        default: break
        }
    }

    private func endSidebarDragForSceneLoss() {
        cancelPendingFolderExpansion(clearSession: true)
        guard let token = activeSource else { return }
        // An already-exited destination must not cancel a drag elsewhere.
        if token.owner === self || sidebarDragHasNativeHold || spaceDropBatchID != nil {
            token.invalidate()
        }
        sourceSessionID = nil
        dropSessionID = nil
        spaceDropSessionID = nil
        spaceHoverDropSession = nil
        spaceDropClosing = true
        initialDragItems.removeAll(keepingCapacity: true)
        suppliedInitialItems.removeAll(keepingCapacity: true)
        token.notifyParticipants()
        finishInteractionIfPossible()
    }

    private func commit(
        _ plan: BrowserMobileSidebarDrop.Plan, document: BrowserMobileProfileDocument,
        payload: BrowserMobileSidebarDragSession,
    ) -> UUID? {
        cancelPendingFolderExpansion(clearSession: true)
        return payload.commit {
            document.move(items: plan.items, destination: plan.destination, before: plan.before, after: plan.after)
        }
    }

    @objc private func cancelSidebarDrag() {
        cancelPendingFolderExpansion(clearSession: true)
        guard isHoldingRows else { return }
        activeSource?.invalidate()
        spaceDropClosing = true
        spaceDropHover = nil
        spaceHoverDropSession = nil
        spaceDropController?.highlight(nil)
        if pendingDropAnimations.isEmpty {
            spaceDropController?.view.isHidden = true
        }
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
        snapshot: BrowserTabSessionSnapshot,
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
        snapshot: BrowserTabSessionSnapshot,
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
        dismissSpaceDropTargetsIfPossible()
        guard !isHoldingRows else { return }
        activeSource = nil
        observedDragMembershipRevision = nil
        dragScene = nil
        guard !tableView.hasUncommittedUpdates else {
            needsStructuralRefresh = true
            scheduleTerminalRefresh()
            return
        }
        cancelPendingFolderExpansion(clearSession: true)
        if !transientExpandedFolderIDs.isEmpty {
            transientExpandedFolderIDs.removeAll()
            needsStructuralRefresh = true
        }
        planCache = nil
        folderExpansionCache = nil
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
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self else { return }
            terminalRefreshTask = nil
            finishInteractionIfPossible()
        }
    }

    private func applyRows(_ newRows: [[Row]], snapshot: BrowserTabSessionSnapshot?) {
        let newItems = Set(newRows.flatMap(\.self).map(\.reference))
        let anchor = tableView.indexPathsForVisibleRows?
            .sorted()
            .compactMap { index -> (
                BrowserSyncEntityReference,
                CGFloat
            )? in
                guard let row = row(at: index), newItems.contains(row.reference) else { return nil }
                return (row.reference, tableView.rectForRow(at: index).minY - tableView.contentOffset.y)
            }
            .first
        let structuralChange = rows != newRows
        if renderedSnapshot != snapshot {
            capturedTargets.removeAll(keepingCapacity: true)
        }
        rows = newRows
        selectedItems.formIntersection(newItems)
        renderedSnapshot = snapshot
        renderedDocument = workspace.profileDocument
        renderedSpaceID = workspace.selectedSpaceID
        renderedAvailableTabIDs = Set(workspace.visibleTabs.map(\.id))
        renderedTabs = Dictionary(workspace.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if structuralChange {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            if let anchor, let index = indexPath(for: anchor.0) {
                let y = tableView.rectForRow(at: index).minY - anchor.1
                let minY = -tableView.adjustedContentInset.top
                let maxY = max(
                    minY,
                    tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom,
                )
                tableView.setContentOffset(
                    CGPoint(x: tableView.contentOffset.x, y: min(maxY, max(minY, y))),
                    animated: false,
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
                    section: section,
                )
            }
        }
        return nil
    }

    /// Settings, with Account inside, from the sidebar's bottom bar.
    private func showSettings() {
        guard presentedViewController == nil, !isSelectingRows, !sidebarDragHasNativeHold else { return }
        workspace.dismissFindInPage()
        let controller = BrowserMobilePhoneSettingsViewController(workspace: workspace)
        controller.didRestoreFromArchive = { [weak self] in self?.didSelectTab?() }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func row(at indexPath: IndexPath) -> Row? {
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].indices.contains(indexPath.row) else { return nil }
        return rows[indexPath.section][indexPath.row]
    }

    private func sharedRows(
        _ snapshot: BrowserTabSessionSnapshot, spaceID: String?, available: Set<String>, expanded: Set<String>,
    ) -> [[Row]] {
        let folders = Dictionary(
            (snapshot.pinnedTabFolders ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        var result = [[Row](), [Row](), [Row]()]
        func visibleDepth(parent: String?) -> Int? {
            var next = parent
            var depth = 0
            var seen = Set<String>()
            while let id = next {
                guard seen.insert(id).inserted, let folder = folders[id],
                      folder.isExpanded || expanded.contains(id) else { return nil }
                depth += 1
                next = folder.parentFolderID
            }
            return depth
        }
        for change in BrowserSyncFolderProjection.canonicalChanges(snapshot) {
            if let folder = change.folderData, folder.spaceID == spaceID,
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
            if document.snapshot.tabs.first(where: { $0.id == id })?.placement == .temporary {
                workspace.closeTab(id: id)
                return !workspace.tabs.contains(where: { $0.id == id })
            }
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
                state: workspace.selectedSpaceID == space.id ? .on : .off,
            ) { [weak self] _ in
                self?.workspace.selectSpace(id: space.id)
                self?.render()
            }
        }
        let disabled: UIMenuElement.Attributes = document.canEdit ? [] : .disabled
        var edits: [UIMenuElement] = [UIAction(
            title: String(localized: "New Space", table: "Mobile"),
            image: UIImage(systemName: "plus"),
            attributes: disabled,
        ) { [weak self, weak document] _ in
            self?.prompt(title: String(localized: "New Space", table: "Mobile"), value: "") { [
                weak self,
                weak document,
            ] name in
                guard let id = document?.createSpace(title: name) else { return }
                self?.workspace.selectSpace(id: id)
            }
        }]
        if let id = workspace.selectedSpaceID {
            edits.append(UIAction(
                title: String(localized: "Rename Space", table: "Mobile"),
                image: UIImage(systemName: "pencil"),
                attributes: disabled,
            ) { [weak self, weak document] _ in
                guard let title = document?.snapshot.spaces?.first(where: { $0.id == id })?.title else { return }
                self?
                    .prompt(
                        title: String(localized: "Rename Space", table: "Mobile"),
                        value: title,
                    ) { [weak document] in
                        document?.renameSpace(id: id, title: $0)
                    }
            })
            edits.append(UIAction(
                title: String(localized: "New Folder", table: "Mobile"),
                image: UIImage(systemName: "folder.badge.plus"),
                attributes: disabled,
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
            var next: String? = folder.id
            var seen = Set<String>()
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
                    destination: .tabs(spaceID: spaceID, placement: placement, pinnedFolderID: parent),
                )
            }
        }
        let spaces = workspace.spaces.map { space -> UIMenu in
            var children: [UIMenuElement] = [moveAction(
                String(localized: "Pinned", table: "Mobile"),
                spaceID: space.id,
                placement: .spacePinned,
                parent: nil,
            )]
            if item.entityType == .tab {
                children.append(moveAction(
                    String(localized: "Today", table: "Mobile"),
                    spaceID: space.id,
                    placement: .temporary,
                    parent: nil,
                ))
            }
            for folder in folders where folder.spaceID == space.id && !isDescendant(folder) {
                var names = [folder.title]
                var parent = folder.parentFolderID
                var seen: Set<String> = [folder.id]
                while let id = parent, seen.insert(id).inserted, let ancestor = folders.first(where: { $0.id == id }) {
                    names.insert(ancestor.title, at: 0)
                    parent = ancestor.parentFolderID
                }
                children.append(moveAction(
                    names.joined(separator: " / "),
                    spaceID: space.id,
                    placement: .spacePinned,
                    parent: folder.id,
                ))
            }
            return UIMenu(title: space.title, image: UIImage(systemName: space.systemImageName), children: children)
        }
        return UIMenu(
            title: String(localized: "Move To", table: "Mobile"),
            image: UIImage(systemName: "folder"),
            children: spaces,
        )
    }

    private func createFolder(spaceID: String, parent: String?) {
        prompt(title: String(localized: "New Folder", table: "Mobile"), value: "") { [weak self] name in
            self?.workspace.profileDocument?.createFolder(spaceID: spaceID, parentFolderID: parent, title: name)
        }
    }

    private func prompt(title: String, value: String, allowsEmpty: Bool = false, apply: @escaping (String) -> Void) {
        guard presentedViewController == nil else { return }
        workspace.dismissFindInPage()
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in field.text = value
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        alert
            .addAction(UIAlertAction(
                title: String(localized: "Save", table: "Mobile"),
                style: .default,
            ) { [weak alert] _ in
                let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard allowsEmpty || !text.isEmpty else { return }
                apply(text)
            })
        present(alert, animated: true)
    }

    private func confirmFolderRemoval(title: String, apply: @escaping () -> Void) {
        guard presentedViewController == nil else { return }
        workspace.dismissFindInPage()
        let alert = UIAlertController(
            title: String(localized: "Delete Folder and Contents", table: "Mobile"),
            message: title,
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", table: "Mobile"), style: .cancel))
        alert
            .addAction(UIAlertAction(title: String(localized: "Delete", table: "Mobile"), style: .destructive) { _ in
                apply()
            })
        present(alert, animated: true)
    }
}

// MARK: UIGestureRecognizerDelegate

extension BrowserMobileTabsViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === phoneSpacePan, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: tableView.superview)
        return abs(velocity.x) > abs(velocity.y) * 1.2 && workspace.spaces.count > 1 && workspace.isReady
            && !isSelectingRows && !isHoldingRows && !tableView.isEditing
    }
}
