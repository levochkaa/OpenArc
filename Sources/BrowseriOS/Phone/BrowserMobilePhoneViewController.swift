// BrowserMobilePhoneViewController.swift

import UIKit

// MARK: - BrowserMobilePhoneViewController

/// The phone's browser: the page fills the screen under a bottom bar. The bar
/// grows into the page menu or the search panel, and the tab stack opens a
/// switcher of tab pictures.
final class BrowserMobilePhoneViewController: UIViewController {
    // MARK: Internal

    enum Mode: Equatable {
        case browsing
        case pageMenu
        case search
        case switcher
    }

    /// Text size steps Safari uses, as page zoom.
    static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: Tab stack flights

    /// The stack shows two cards; the others hide behind the back one.
    private static let hiddenStackSlot = 2

    /// How long after a switch, or after its page stops loading, a tab's last
    /// picture keeps deciding the bar: WebKit reports its empty background
    /// for a moment after the page finishes.
    private static let backdropSettleDelay: CFTimeInterval = 0.6

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(
            title: String(localized: "Find in Page", table: "Mobile"),
            action: #selector(findInPage), input: "f", modifierFlags: .command,
        )
        find.wantsPriorityOverSystemBehavior = true
        return [
            find,
            UIKeyCommand(
                title: String(localized: "Open Location", table: "Mobile"),
                action: #selector(editAddress), input: "l", modifierFlags: .command,
            ),
            UIKeyCommand(
                title: String(localized: "New Tab", table: "Mobile"),
                action: #selector(newTab), input: "t", modifierFlags: .command,
            ),
            UIKeyCommand(
                title: String(localized: "Close Tab", table: "Mobile"),
                action: #selector(closeCurrentTab), input: "w", modifierFlags: .command,
            ),
            UIKeyCommand(
                title: String(localized: "Reload", table: "Mobile"),
                action: #selector(reload), input: "r", modifierFlags: .command,
            ),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
        ]
    }

    /// Where the status corner is its own block (iPhone Duo), search and the
    /// switcher hide the status bar: their cards pass under the block.
    override var prefersStatusBarHidden: Bool {
        statusCorner != nil && Self.hidesStatusCorner(mode)
    }

    /// Where the status bar is a column at the side (iPhone Duo), it lies
    /// down along the top while the page menu stands taller than the column,
    /// so the menu's top row is not under it.
    @available(iOS 27.1, *) override var preferredVerticalBarBehavior: UIVerticalBarBehavior {
        pageMenuReachesStatus ? .disabled : .automatic
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        // Leaving the switcher, the status bar takes the page's colors as its card starts to grow.
        if mode == .switcher && !isLeavingSwitcher || mode == .search || showsHome { return .lightContent }
        // A swipe's row of cards shows the app's backdrop until it lets go.
        if let swipe, swipe.isRow, !swipe.isSettling { return .lightContent }
        // The empty state or the load error fills the page's place.
        if contentView.isHidden { return traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent }
        return isStatusBandDark ? .lightContent : .darkContent
    }

    let workspace: BrowserMobileWorkspace

    private(set) var mode = Mode.browsing {
        didSet {
            // The mark sinks behind search and the panels, and comes back with the backdrop.
            if (mode == .browsing) != (oldValue == .browsing) {
                let visible = mode == .browsing
                UIView.animate(withDuration: visible ? 0.25 : 0.15, delay: 0, options: [.beginFromCurrentState]) {
                    self.homeLogo.alpha = visible ? 1 : 0
                }
            }
            if mode != .pageMenu {
                updateVerticalBar(pageMenuHeight: nil)
            }
            if statusCorner != nil, Self.hidesStatusCorner(mode) != Self.hidesStatusCorner(oldValue) {
                setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    lazy var javaScriptDialogPresenter =
        BrowserMobileJavaScriptDialogPresenter(host: self) { [weak self] id, response in
            self?.workspace.resolveJavaScriptDialog(id: id, response: response)
        }

    lazy var httpAuthenticationPresenter =
        BrowserMobileHTTPAuthenticationPresenter(host: self) { [weak self] id, response in
            self?.workspace.resolveHTTPAuthentication(id: id, response: response)
        }

    // MARK: Private

    private let contentView: UIView
    private let pageContainer = UIView()
    /// Covers the page under the status bar in the page's theme color, or
    /// its background, so scrolled content never shows there.
    private let statusBand = UIView()
    /// The page's background beside it in the side insets, such as the
    /// camera column on iPhone Duo, which WebKit leaves unpainted on some
    /// systems.
    private let sideBands = [UIView(), UIView()]
    private var isStatusBandDark = false
    /// The last picture `isPictureTopDark` read, and what it found.
    private var pictureTopDarkness: (image: UIImage, dark: Bool)?
    /// Darkens the page while it is the search panel's card.
    private let pageDim = UIView()
    private let bar = BrowserMobilePhoneBarView()
    /// Fills the screen while no page is open.
    private let appBackdrop = BrowserMobileAppBackdrop()
    private let homeLogo = BrowserMobileHomeLogo()
    /// No page is open: the backdrop shows, with Spaces and Settings in the bar.
    private var showsHome = false
    /// The switcher's chosen card is growing into the page.
    private var isLeavingSwitcher = false
    private var statusCorner: CGRect?
    /// The bottom of the status column, while the status bar is one.
    private var statusColumnBottom: CGFloat?
    private var pageMenuReachesStatus = false
    private var appliedObscuredInsets: UIEdgeInsets?
    private let emptyState = UIStackView()
    private let emptyTitle = UILabel()
    private let emptyMessage = UILabel()
    private let emptyAction = UIButton(type: .system)
    private let loadError = BrowserMobileLoadErrorView()
    private let thumbnails = BrowserMobileTabThumbnails.shared
    private let favicons = BrowserMobileFavicons.shared
    private var isBackdropSampleScheduled = false
    /// A tab just switched to: until its page has loaded and drawn for a
    /// moment, its last picture decides the bar, not WebKit's empty background.
    private var settlingTab: (id: String, until: CFTimeInterval)?
    private var isSettledSampleScheduled = false
    private var renderedTabID: String?
    private var wasLoading = [String: Bool]()
    private var didAutoOpenSearch = false
    /// What the Home Screen widget asked for, done once the tabs are ready.
    private var pendingAppLink: BrowserMobileAppLink?
    private var shownOpenedLinkCount: Int

    // Bar collapse while scrolling.
    private var scrollObservation: NSKeyValueObservation?
    private var lastScrollY: CGFloat = 0
    private var scrollTravel: CGFloat = 0

    /// Panels.
    /// A panel grown out of the bar; while it is up, it is the bar.
    private var surface: UIView? {
        didSet { bar.background.isCovered = surface != nil }
    }

    /// A dark panel's material: the bar's own while the panel is the bar,
    /// turning into the panel's glass as it rises.
    private var surfaceTint: BrowserMobileBarMaterial?
    private var dismissCatcher: UIView?
    /// Drags the open search panel down to close it.
    private weak var surfacePan: UIPanGestureRecognizer?
    private var surfaceGhosts = [UIView]()
    private var surfaceDragStartTop: CGFloat = 0
    /// Where the finger last turned, in the drag's translation, and whether it
    /// was going up from there: a panel brought back up is let go open.
    private var surfaceDragTurn: CGFloat = 0
    private var surfaceDragGoesUp = false
    /// Search opened from the switcher: it rises over the cards, and closing
    /// it goes back to them instead of to the last tab.
    private var searchOverSwitcher = false
    private lazy var pagePanel = BrowserMobilePagePanel()
    private lazy var searchPanel = BrowserMobileSearchPanel()
    private var searchReplacesPage = false
    private var keyboardTop: CGFloat?
    /// The keyboard went down while search stayed open, so the panel sits at the bottom.
    private var isSearchKeyboardDismissed = false
    /// Follows the keyboard's top, as it moves under a finger too.
    private let keyboardTracker = BrowserMobileKeyboardTracker()
    private var laidOutSize = CGSize.zero

    /// Switcher.
    private var switcher: BrowserMobileTabSwitcherView?
    /// Holds the cards flying between the switcher and the tab stack, over the bar.
    private var switcherFlight: UIView?
    /// The page's card that the flying older tabs pass under, and the mask
    /// that hides them there.
    private var isAnimatingSwitcher = false
    private weak var presentedTabs: BrowserMobileTabsViewController?

    /// Bar swipe between tabs.
    private var swipe: BarSwipe?
    /// The tap a sideways swipe gives as it snaps into the row or back out of it.
    private let rowSnapHaptic = UIImpactFeedbackGenerator(style: .light)
    /// Tabs a swipe in from the left edge closed, the last one last: the
    /// right edge brings one back while its neighbor is still showing.
    private var edgeClosedTabs = [EdgeClosedTab]()
    /// The last picture of a tab that was switched to while its page still
    /// loads, so a cold tab does not flash blank.
    private var loadingCover: (view: UIView, tabID: String)?
    private let translator = BrowserMobilePageTranslator()
    /// The translation filling in a tab, if one is.
    private var translationRun: (id: UUID, tabID: String)?

    private var thumbnailWidth: CGFloat { (view.bounds.width * 0.66).rounded() }
    private var safeBottom: CGFloat { view.safeAreaInsets.bottom }
    private var expandedBarHeight: CGFloat { BrowserMobilePhoneBarView.height(safeBottom: safeBottom, collapsed: false)
    }

    /// The bar keeps its full height; collapsed, it slides down until only
    /// the home indicator's strip shows, so its material never resizes.
    private var barFrame: CGRect {
        let shown = BrowserMobilePhoneBarView.height(safeBottom: safeBottom, collapsed: bar.isCollapsed)
        return CGRect(
            x: 0, y: view.bounds.height - shown, width: view.bounds.width, height: expandedBarHeight,
        )
    }

    private var expandedBarFrame: CGRect {
        CGRect(
            x: 0, y: view.bounds.height - expandedBarHeight, width: view.bounds.width, height: expandedBarHeight,
        )
    }

    private var shareURL: URL? {
        guard let url = workspace.selectedTab.flatMap({ URL(string: $0.urlString) }),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The open page's site, for Site Settings.
    private var siteHost: String? {
        shareURL.flatMap { BrowserMobileFavicons.host(forPage: $0.absoluteString) }
    }

    /// Where the search panel ends: the keyboard's top, the screen's bottom once the keyboard
    /// was pulled down, or where the keyboard will come up while it is on its way.
    private var searchKeyboardTop: CGFloat {
        keyboardTop ?? (isSearchKeyboardDismissed ? view.bounds.height : view.bounds.height * 0.655)
    }

    init(workspace: BrowserMobileWorkspace, contentView: UIView) {
        self.workspace = workspace
        self.contentView = contentView
        self.shownOpenedLinkCount = workspace.openedLinkCount
        super.init(nibName: nil, bundle: nil)
        workspace.onChange = { [weak self] in self?.render() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        translator.install(in: self)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            if self.contentView.isHidden { self.setBackdropDark(self.traitCollection.userInterfaceStyle == .dark) }
        }
        // Shows around the page while it is a card above the search panel.
        view.backgroundColor = UIColor(red: 22 / 255, green: 22 / 255, blue: 37 / 255, alpha: 1)
        pageContainer.backgroundColor = .systemBackground
        pageContainer.layer.cornerCurve = .continuous
        pageContainer.clipsToBounds = true
        appBackdrop.isHidden = true
        // A finger across the empty backdrop turns the mark.
        appBackdrop.isUserInteractionEnabled = true
        appBackdrop.addGestureRecognizer(homeLogo.backdropPan)
        view.addSubview(appBackdrop)
        homeLogo.isHidden = true
        view.addSubview(homeLogo)
        view.addSubview(pageContainer)
        pageContainer.addSubview(contentView)
        statusBand.isUserInteractionEnabled = false
        statusBand.backgroundColor = .white
        pageContainer.addSubview(statusBand)
        for band in sideBands {
            band.isUserInteractionEnabled = false
            band.isHidden = true
            pageContainer.addSubview(band)
        }
        pageDim.backgroundColor = .black
        pageDim.alpha = 0
        pageDim.isUserInteractionEnabled = false
        pageContainer.addSubview(pageDim)
        configureEmptyState()
        view.addSubview(bar)
        bar.tabStack.addAction(UIAction { [weak self] _ in self?.openSwitcher() }, for: .touchUpInside)
        // Holding the tab stack opens the Spaces sheet.
        let holdStack = UILongPressGestureRecognizer(target: self, action: #selector(stackHeld(_:)))
        holdStack.minimumPressDuration = 0.5
        bar.tabStack.addGestureRecognizer(holdStack)
        bar.plusButton.addAction(
            UIAction { [weak self] _ in self?.openSearch(text: "", replacesPage: false) },
            for: .touchUpInside,
        )
        bar.moreButton.addAction(UIAction { [weak self] _ in self?.openPageMenu() }, for: .touchUpInside)
        bar.spacesButton.addAction(UIAction { [weak self] _ in self?.showSpaces() }, for: .touchUpInside)
        bar.settingsButton.addAction(UIAction { [weak self] _ in self?.showSettings() }, for: .touchUpInside)
        bar.expandRecognizer.addTarget(self, action: #selector(expandBar))
        configureBarSwipe()
        NotificationCenter.default.addObserver(
            self, selector: #selector(iconsChanged), name: BrowserMobileFavicons.didChange, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailsChanged), name: BrowserMobileTabThumbnails.didChange, object: nil,
        )
        keyboardTracker.isUserInteractionEnabled = false
        keyboardTracker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardTracker)
        NSLayoutConstraint.activate([
            keyboardTracker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardTracker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardTracker.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            keyboardTracker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        keyboardTracker.onResize = { [weak self] in self?.followKeyboardUnderFinger() }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardChanged(_:)), name: name, object: nil,
            )
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneBecameInactive(_:)), name: name, object: nil,
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneBecameActive(_:)), name: UIScene.didActivateNotification, object: nil,
        )
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        appBackdrop.frame = view.bounds
        let logoSize = homeLogo.intrinsicContentSize
        homeLogo.bounds = CGRect(origin: .zero, size: logoSize)
        homeLogo.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        updateStatusCorner()
        if laidOutSize != view.bounds.size {
            laidOutSize = view.bounds.size
            layoutOpenPanel()
        }
        layoutPage()
        if surface == nil {
            layoutBar()
        }
        switcher?.frame = view.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if #available(iOS 27.1, *) {
            setNeedsUpdateOfVerticalBarConfiguration()
        }
        // Folding or turning moves the status corner, and the system reports
        // its new block only after the size changes; look again once it settles.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.refreshStatusCorner()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshStatusCorner() }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateObscuredInsets()
    }

    static func nextZoom(from zoom: CGFloat, larger: Bool) -> CGFloat {
        larger
            ? zoomSteps.first { $0 > zoom + 0.001 } ?? zoomSteps[zoomSteps.count - 1]
            : zoomSteps.last { $0 < zoom - 0.001 } ?? zoomSteps[0]
    }

    private static func hidesStatusCorner(_ mode: Mode) -> Bool {
        mode == .search || mode == .switcher
    }

    /// Whether a page's background is dark; nil before it reports one.
    private static func isDark(_ state: BrowserMobilePageState) -> Bool? {
        state.backgroundColor.flatMap(BrowserMobileBackdrop.luminance(of:)).map(BrowserMobileBackdrop.isDark)
    }

    func render() {
        guard isViewLoaded else { return }
        let tab = workspace.selectedTab
        if renderedTabID != tab?.id {
            if let previous = renderedTabID, mode == .browsing {
                capturePageIfFullScreen(previous)
            }
            renderedTabID = tab?.id
            settlingTab = tab.map { ($0.id, CACurrentMediaTime() + Self.backdropSettleDelay) }
            observeScrolling()
            removeLoadingCover()
            setBarCollapsed(false, animated: false)
        }
        if let tab, loadingCover?.tabID == tab.id, !tab.state.isLoading {
            removeLoadingCover()
        }
        if let tab, wasLoading[tab.id] == true, !tab.state.isLoading {
            // A page that finished loading is worth a fresh picture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, workspace.selectedTabID == tab.id, mode == .browsing else { return }
                thumbnails.capture(tab.id, workspace: workspace, width: thumbnailWidth)
            }
        }
        if let tab { wasLoading[tab.id] = tab.state.isLoading }
        if let tab, tab.state.isLoading, let settling = settlingTab, settling.id == tab.id {
            settlingTab?.until = max(settling.until, CACurrentMediaTime() + Self.backdropSettleDelay)
        }
        sampleBackdrop()
        updateTabStack()
        bar.insecureBadge.isHidden = tab?.state.url?.scheme?.lowercased() != "http"
        requestIcons()
        updateEmptyState()
        updateStatusBand()
        bar.isHidden = workspace.isFindInPageVisible && mode == .browsing
        if mode == .pageMenu { updatePagePanel() }
        if mode == .search { searchPanel.candidates = searchCandidates() }
        if mode == .switcher, !isAnimatingSwitcher { refreshSwitcherEntries() }
        presentedTabs?.render()
        javaScriptDialogPresenter.update(workspace.javaScriptDialog)
        httpAuthenticationPresenter.update(workspace.httpAuthentication)
        // A link from another app shows its page, not search, the switcher or a panel.
        if shownOpenedLinkCount != workspace.openedLinkCount {
            shownOpenedLinkCount = workspace.openedLinkCount
            didAutoOpenSearch = true
            showOpenedLink()
        }
        performPendingAppLink()
        // A launch opens search over the last tab too, unless Settings turn that off.
        if !didAutoOpenSearch, workspace.isReady, mode == .browsing, view.window != nil,
           tab == nil || tab?.urlString == "about:blank" || BrowserMobileAutoOpenKeyboardSetting.isOn()
        {
            didAutoOpenSearch = true
            let openedLinkCount = workspace.openedLinkCount
            DispatchQueue.main.async { [weak self] in
                // A link that launched the app may open right after the tabs restore.
                guard let self, mode == .browsing, presentedViewController == nil,
                      workspace.openedLinkCount == openedLinkCount
                else { return }
                openSearch(text: "", replacesPage: false)
            }
        }
    }

    /// The Home Screen widget's search, voice search or new tab.
    func open(_ link: BrowserMobileAppLink) {
        pendingAppLink = link
        didAutoOpenSearch = true
        performPendingAppLink()
    }

    private func refreshStatusCorner() {
        if #available(iOS 27.1, *) {
            setNeedsUpdateOfVerticalBarConfiguration()
        }
        updateStatusCorner()
        view.setNeedsLayout()
    }

    /// The bar stays opaque; the page lays out above its full height even
    /// while it is collapsed, so fixed footers never jump. Beside a status
    /// corner block (iPhone Duo) the page keeps the system's side inset, which
    /// WebKit fills with the page's background.
    private func updateObscuredInsets() {
        let safe = view.safeAreaInsets
        let insets = UIEdgeInsets(top: 0, left: safe.left, bottom: expandedBarHeight, right: safe.right)
        guard insets != appliedObscuredInsets else { return }
        appliedObscuredInsets = insets
        workspace.setObscuredInsets(insets)
    }

    /// The block the system keeps for the camera and the status bar in a
    /// corner of the screen (iPhone Duo), in this view's coordinates. It
    /// grows with what the status bar shows, a Live Activity for one.
    private func updateStatusCorner() {
        var corner: CGRect?
        if #available(iOS 27.1, *) {
            let size = view.bounds.size
            corner = view.reservedRegions(kind: .occlusion).map(\.frame).first { frame in
                frame.minY <= 1 && (frame.minX <= 1 || frame.maxX >= size.width - 1)
                    && frame.width < size.width / 2 && frame.height < size.height / 2
            }
        }
        // The regions are briefly empty while the device folds or rotates,
        // and the block shrinks to the camera while search hides the status
        // bar; the last block stays until the next one is reported.
        guard let corner, corner != statusCorner else { return }
        statusCorner = corner
        if corner.height > corner.width {
            statusColumnBottom = corner.maxY
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func layoutPage() {
        if pageContainer.transform.isIdentity {
            pageContainer.frame = view.bounds
        } else if pageContainer.bounds.size != view.bounds.size {
            // The search card scales a screen-sized page; any other size is mid-animation.
            return
        }
        // Pages start below the status bar, which the band covers, so the
        // viewport units of a page leave it out.
        let top = view.safeAreaInsets.top
        contentView.frame = pageContainer.bounds.inset(by: UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0))
        thumbnails.statusBarShare = top / max(view.bounds.width, 1)
        statusBand.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.safeAreaInsets.top)
        let safe = view.safeAreaInsets
        sideBands[0].frame = CGRect(x: 0, y: 0, width: safe.left, height: pageContainer.bounds.height)
        sideBands[1].frame = CGRect(
            x: pageContainer.bounds.width - safe.right, y: 0, width: safe.right, height: pageContainer.bounds.height,
        )
        pageDim.frame = pageContainer.bounds
        emptyState.frame = pageContainer.bounds.inset(by: UIEdgeInsets(
            top: view.safeAreaInsets.top, left: 24, bottom: expandedBarHeight, right: 24,
        ))
        loadError.frame = pageContainer.bounds
        loadError.contentInsets = UIEdgeInsets(
            top: view.safeAreaInsets.top, left: view.safeAreaInsets.left,
            bottom: expandedBarHeight, right: view.safeAreaInsets.right,
        )
    }

    private func layoutBar() {
        bar.frame = barFrame
    }

    /// Folding, unfolding or turning with a panel up: the panel and the
    /// page's search card take the new size.
    private func layoutOpenPanel() {
        guard let surface, surfacePan.map({ $0.state != .began && $0.state != .changed }) ?? true else { return }
        let size = view.bounds.size
        switch mode {
        case .search:
            let top = searchPanelTop(keyboardTop: searchKeyboardTop)
            surface.frame = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
            applyPageCard(searchCardFrame())
        case .pageMenu:
            let height = pagePanel.contentHeight + safeBottom
            surface.frame = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
            pagePanel.frame.size = CGSize(width: size.width, height: height)
            updateVerticalBar(pageMenuHeight: height)
        case .browsing, .switcher: break
        }
    }

    // MARK: Theme, icons, tab stack

    /// Turns the bar dark over a page whose background is dark. Before the
    /// page reports its background, a picture of the page under the bar
    /// decides.
    private func sampleBackdrop() {
        // Over the switcher the bar stays dark.
        guard mode != .switcher else { return }
        guard let tab = workspace.selectedTab, !contentView.isHidden else {
            // The bar sits over the home backdrop or the empty state, not a page.
            setBackdropDark(showsHome || traitCollection.userInterfaceStyle == .dark)
            return
        }
        if let settling = settlingTab, settling.id == tab.id {
            let wait = settling.until - CACurrentMediaTime()
            if wait > 0, let dark = pictureBarDark(tab.id) {
                setBackdropDark(dark)
                if !isSettledSampleScheduled {
                    isSettledSampleScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.02) { [weak self] in
                        self?.isSettledSampleScheduled = false
                        self?.sampleBackdrop()
                    }
                }
                return
            }
            if wait <= 0 { settlingTab = nil }
        }
        if let dark = Self.isDark(tab.state) {
            setBackdropDark(dark)
            return
        }
        guard !isBackdropSampleScheduled else { return }
        isBackdropSampleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            isBackdropSampleScheduled = false
            guard mode != .switcher, let id = workspace.selectedTabID, !contentView.isHidden,
                  workspace.selectedTab.flatMap({ Self.isDark($0.state) }) == nil else { return }
            let height = expandedBarHeight
            let rect = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
            workspace.snapshot(tabID: id, rect: rect, width: 32) { [weak self] image in
                guard let self, workspace.selectedTabID == id, let image = image?.cgImage,
                      let luminance = BrowserMobileBackdrop.luminance(of: image) else { return }
                setBackdropDark(BrowserMobileBackdrop.isDark(luminance: luminance))
            }
        }
    }

    private func updateStatusBand() {
        let state = workspace.selectedTab?.state
        statusBand.isHidden = contentView.isHidden
        let sideColor = state?.backgroundColor ?? state?.themeColor
        for band in sideBands {
            band.isHidden = contentView.isHidden || sideColor == nil
            band.backgroundColor = sideColor
        }
        let dark: Bool
        if let id = workspace.selectedTabID, isCoveredByPicture(id), let pictureDark = isPictureTopDark(id) {
            // A page still loading under its picture reports WebKit's empty
            // background, black in dark mode; the picture is what shows.
            dark = pictureDark
        } else if let color = state?.themeColor ?? state?.backgroundColor {
            statusBand.backgroundColor = color
            dark = BrowserMobileBackdrop.luminance(of: color).map(BrowserMobileBackdrop.isDark) ?? false
        } else {
            // Before the page reports its colors, the top of its last picture
            // stands in, or the bar's reading of it, rather than the last page's.
            dark = workspace.selectedTabID.flatMap(isPictureTopDark) ?? bar.isDark
        }
        guard dark != isStatusBandDark else { return }
        isStatusBandDark = dark
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Whether a tab's last picture stands in for its page, which may not
    /// have drawn yet: while a swipe lands on it, or as its loading cover.
    private func isCoveredByPicture(_ tabID: String) -> Bool {
        loadingCover?.tabID == tabID || swipe.map { $0.isSettling && $0.toID == tabID } == true
    }

    /// Whether the top of the page in a tab's last picture, just below the
    /// status bar, is dark; the picture leaves the status bar's place empty.
    private func isPictureTopDark(_ tabID: String) -> Bool? {
        guard let image = thumbnails.image(for: tabID), let cgImage = image.cgImage, cgImage.height > 0 else {
            return nil
        }
        if let cached = pictureTopDarkness, cached.image === image { return cached.dark }
        let pixelsPerPoint = CGFloat(cgImage.width) / max(view.bounds.width, 1)
        let top = view.safeAreaInsets.top * pixelsPerPoint
        guard top + 16 * pixelsPerPoint <= CGFloat(cgImage.height), let strip = cgImage.cropping(to: CGRect(
            x: 0, y: top, width: CGFloat(cgImage.width), height: 16 * pixelsPerPoint,
        )), let luminance = BrowserMobileBackdrop.luminance(of: strip) else { return nil }
        let dark = BrowserMobileBackdrop.isDark(luminance: luminance)
        pictureTopDarkness = (image, dark)
        return dark
    }

    /// Turns the bar to match a tab's background, or its last picture, before
    /// its page shows, so the color changes along with a switch instead of
    /// after it.
    private func matchBackdrop(toPictureOf tabID: String) {
        if !isCoveredByPicture(tabID), let tab = workspace.tabs.first(where: { $0.id == tabID }),
           let dark = Self.isDark(tab.state)
        {
            setBackdropDark(dark)
            return
        }
        if let dark = pictureBarDark(tabID) {
            setBackdropDark(dark)
        }
    }

    /// Whether the page is dark under the bar in a tab's last picture.
    private func pictureBarDark(_ tabID: String) -> Bool? {
        guard let image = thumbnails.image(for: tabID)?.cgImage, image.height > 0 else { return nil }
        let screenHeight = view.bounds.height * CGFloat(image.width) / view.bounds.width
        let barHeight = expandedBarHeight * CGFloat(image.width) / view.bounds.width
        let bottom = min(CGFloat(image.height), screenHeight)
        guard let strip = image.cropping(to: CGRect(
            x: 0, y: max(0, bottom - barHeight), width: CGFloat(image.width), height: barHeight,
        )), let luminance = BrowserMobileBackdrop.luminance(of: strip) else { return nil }
        return BrowserMobileBackdrop.isDark(luminance: luminance)
    }

    /// How much the dark panel looks like the bar: 1 is the bar's own
    /// material, 0 the panel's glass. `interactive` holds a share between
    /// them as a finger moves the panel.
    private func setSurfaceTint(_ share: CGFloat, interactive: Bool = false) {
        surfaceTint?.setGlassShare(1 - share, interactive: interactive)
    }

    /// The bar may have changed under the panel, as when the switcher it was
    /// over went away.
    private func matchSurfaceTintToBar() {
        guard let tint = surfaceTint else { return }
        tint.overrideUserInterfaceStyle = bar.isDark ? .dark : .light
        tint.showsMaterial = bar.background.showsMaterial
    }

    private func setBackdropDark(_ dark: Bool) {
        guard bar.isDark != dark else { return }
        UIView.transition(with: bar, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.bar.isDark = dark
            (self.surface as? UIVisualEffectView)?.overrideUserInterfaceStyle = dark ? .dark : .light
        }
        let state = workspace.selectedTab?.state
        if state?.themeColor == nil, state?.backgroundColor == nil { updateStatusBand() }
    }

    private func updateTabStack() {
        let ordered = workspace.switcherTabs.filter { $0.id != workspace.selectedTabID }
        let front = ordered.last
        let back = ordered.dropLast().last
        let width = max(view.bounds.width, 1)
        bar.tabStack.sideCrop = (view.safeAreaInsets.left / width, view.safeAreaInsets.right / width)
        bar.tabStack.setImages(
            front: front.flatMap { thumbnails.image(for: $0.id) },
            back: back.flatMap { thumbnails.image(for: $0.id) },
        )
        bar.tabStack.accessibilityValue = String(workspace.switcherTabs.count)
    }

    private func requestIcons() {
        favicons.requestIcons(for: workspace.switcherTabs, in: workspace)
    }

    @objc private func iconsChanged() {
        switcher?.reloadIcons()
        searchPanel.reloadIcons()
    }

    @objc private func thumbnailsChanged(_ notification: Notification) {
        updateTabStack()
        if let id = notification.userInfo?["tabID"] as? String, let switcher, !isAnimatingSwitcher,
           switcher.card(for: id)?.livePicture == nil
        {
            switcher.setPicture(thumbnails.image(for: id), for: id)
        }
    }

    // MARK: Empty and error states

    private func configureEmptyState() {
        emptyState.axis = .vertical
        emptyState.alignment = .center
        emptyState.distribution = .equalCentering
        emptyState.spacing = 12
        emptyTitle.font = .preferredFont(forTextStyle: .title2)
        emptyTitle.adjustsFontForContentSizeCategory = true
        emptyTitle.numberOfLines = 0
        emptyTitle.textAlignment = .center
        emptyMessage.font = .preferredFont(forTextStyle: .body)
        emptyMessage.adjustsFontForContentSizeCategory = true
        emptyMessage.textColor = .secondaryLabel
        emptyMessage.numberOfLines = 0
        emptyMessage.textAlignment = .center
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        emptyAction.configuration = configuration
        emptyAction.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if workspace.sessionError != nil {
                Task { await self.workspace.retryPersistence() }
            } else if workspace.selectedTab?.state.error != nil {
                workspace.reloadOrStop()
            } else {
                openSearch(text: "", replacesPage: false)
            }
        }, for: .touchUpInside)
        let inner = UIStackView(arrangedSubviews: [emptyTitle, emptyMessage, emptyAction])
        inner.axis = .vertical
        inner.alignment = .center
        inner.spacing = 12
        emptyState.addArrangedSubview(UIView())
        emptyState.addArrangedSubview(inner)
        emptyState.addArrangedSubview(UIView())
        pageContainer.addSubview(emptyState)
        loadError.isHidden = true
        loadError.onReload = { [weak self] in self?.workspace.reload() }
        pageContainer.insertSubview(loadError, belowSubview: pageDim)
    }

    private func updateEmptyState() {
        let tab = workspace.selectedTab
        let error = workspace.sessionError ?? tab?.state.error ?? workspace.navigationError
        let isBlank = tab == nil || tab?.urlString == "about:blank"
        let home = workspace.isReady && error == nil && isBlank
        emptyState.isHidden = home || workspace.isReady && error == nil && !isBlank
        contentView.isHidden = !workspace.isReady || tab?.state.error != nil || isBlank
        setShowsHome(home)
        let pageError = workspace.isReady && workspace.sessionError == nil ? tab?.state.error : nil
        loadError.isHidden = pageError == nil
        loadError.setMessage(pageError)
        setNeedsStatusBarAppearanceUpdate()
        if contentView.isHidden {
            // The bar sits over this view, not the page it last matched.
            setBackdropDark(home || traitCollection.userInterfaceStyle == .dark)
        }
        if !workspace.isReady {
            emptyTitle.text = String(localized: "Opening your tabs", table: "Mobile")
            emptyMessage.text = workspace.sessionError ?? String(
                localized: "Restoring this window’s session…", table: "Mobile",
            )
            emptyAction.isHidden = workspace.sessionError == nil
            emptyAction.setTitle(String(localized: "Retry", table: "Mobile"), for: .normal)
        } else if let error {
            emptyTitle.text = workspace.sessionError == nil
                ? String(localized: "Page could not load", table: "Mobile")
                : String(localized: "Changes could not be saved", table: "Mobile")
            emptyMessage.text = error
            emptyAction.isHidden = false
            emptyAction.setTitle(
                workspace.sessionError == nil
                    ? String(localized: "Try Again", table: "Mobile")
                    : String(localized: "Retry", table: "Mobile"),
                for: .normal,
            )
            // A page's own error shows in the load error view.
            emptyState.isHidden = pageError != nil
        } else {
            emptyTitle.text = String(localized: "Where next?", table: "Mobile")
            emptyMessage.text = String(localized: "Search the web or enter an address.", table: "Mobile")
            emptyAction.isHidden = false
            emptyAction.setTitle(String(localized: "Search or Enter Address", table: "Mobile"), for: .normal)
        }
    }

    /// With no page open the backdrop fills the screen, as it does behind
    /// the switcher, and the bar offers Spaces and Settings.
    private func setShowsHome(_ home: Bool) {
        // The switcher may close onto the home after its last tab closed.
        if mode == .browsing, bar.showsSwitcherControls != home {
            bar.setShowsSwitcherControls(home, showsMaterial: true)
            setBarCollapsed(false, animated: false)
        }
        guard home != showsHome else { return }
        showsHome = home
        pageContainer.isHidden = home
        appBackdrop.isHidden = !home
        homeLogo.isHidden = !home
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: Bar collapse

    private func observeScrolling() {
        scrollObservation = nil
        guard let id = workspace.selectedTabID, let scrollView = workspace.scrollView(tabID: id) else {
            // The page's view may appear after the selection; look again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, scrollObservation == nil, workspace.selectedTabID != nil,
                      workspace.selectedTabID.flatMap({ self.workspace.scrollView(tabID: $0) }) != nil
                else { return }
                observeScrolling()
            }
            return
        }
        lastScrollY = scrollView.contentOffset.y
        scrollTravel = 0
        scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.scrolled(scrollView) }
        }
    }

    private func scrolled(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        defer { lastScrollY = y }
        sampleBackdrop()
        guard mode == .browsing, scrollView.isTracking || scrollView.isDecelerating else { return }
        guard BrowserMobileSiteSettings.collapsesBar(onPage: workspace.selectedTab?.urlString) else {
            setBarCollapsed(false, animated: true)
            return
        }
        if y <= 0 {
            setBarCollapsed(false, animated: true)
            return
        }
        let delta = y - lastScrollY
        if delta.sign != scrollTravel.sign { scrollTravel = 0 }
        scrollTravel += delta
        if scrollTravel > 14 {
            setBarCollapsed(true, animated: true)
        } else if scrollTravel < -14 {
            setBarCollapsed(false, animated: true)
        }
    }

    private func setBarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard bar.isCollapsed != collapsed, surface == nil else { return }
        guard animated, view.window != nil else {
            bar.setCollapsed(collapsed)
            layoutBar()
            return
        }
        // Both ways take a few frames; the controls fade a little faster
        // collapsing and a little slower expanding than the bar moves.
        UIView.animate(withDuration: collapsed ? 0.05 : 0.12, delay: 0, options: [
            .beginFromCurrentState, .allowUserInteraction,
        ]) {
            self.bar.setCollapsed(collapsed)
        }
        UIView.animate(withDuration: collapsed ? 0.06 : 0.09, delay: 0, options: [
            .beginFromCurrentState, .allowUserInteraction, .curveEaseOut,
        ]) {
            self.layoutBar()
        }
    }

    @objc private func expandBar(_: UITapGestureRecognizer) {
        guard bar.isCollapsed else { return }
        setBarCollapsed(false, animated: true)
    }

    // MARK: Morphing panels

    /// Grows a panel out of the bar: a surface takes the bar's frame and color,
    /// then springs up to `height` while the bar's controls fade.
    /// The page menu grows out of the bar, its address row widening out of
    /// the New Tab capsule.
    private func openPagePanel(height: CGFloat) {
        guard let surface = makeSurface(height: height, dark: false, content: pagePanel, revealsContent: true)
        else { return }
        pagePanel.setAddressExpanded(false)
        addSurfacePan(to: surface)
        let target = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        // Rises fast and settles without overshoot: an ease-out cubic over 0.24 s.
        let rise = UIViewPropertyAnimator(
            duration: 0.24, controlPoint1: CGPoint(x: 0.215, y: 0.61), controlPoint2: CGPoint(x: 0.355, y: 1),
        ) {
            surface.frame = target
            surface.layer.cornerRadius = 36
            self.setSurfaceTint(0)
            self.pagePanel.setAddressExpanded(true)
        }
        rise.isUserInteractionEnabled = true
        rise.startAnimation()
    }

    /// Puts a surface over the bar with the bar's frame and color, holding
    /// `content` laid out at `height`. Content that shows from the start
    /// (`revealsContent`) is not faded in.
    /// `followsFinger`: the panel comes up under a finger, which fades the
    /// tab stack and the page menu button as it goes.
    private func makeSurface(
        height: CGFloat, dark: Bool, content: UIView, revealsContent: Bool, followsFinger: Bool = false,
    ) -> UIView? {
        guard surface == nil else { return nil }
        setBarCollapsed(false, animated: false)
        layoutBar()
        let catcher = UIControl(frame: view.bounds)
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.accessibilityIdentifier = "browser.dismissPanel"
        catcher.accessibilityLabel = String(localized: "Close", table: "Mobile")
        catcher.addAction(UIAction { [weak self] _ in self?.closePanel() }, for: .touchUpInside)
        view.insertSubview(catcher, belowSubview: bar)
        dismissCatcher = catcher
        if !dark {
            // The page dims under the page menu, status bar included.
            catcher.backgroundColor = .black
            catcher.alpha = 0
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction]) {
                catcher.alpha = 0.18
            }
        }
        let surface: UIView
        let container: UIView
        if dark {
            surface = UIView(frame: bar.frame)
            container = surface
            // Starts as the bar it grows from and turns into the panel's glass.
            let tint = BrowserMobileBarMaterial()
            tint.frame = surface.bounds
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Leans the glass toward the backdrop so it reads darker over light pages.
            tint.shadeColor = view.backgroundColor?.withAlphaComponent(0.1)
            surface.addSubview(tint)
            surfaceTint = tint
            matchSurfaceTintToBar()
            setSurfaceTint(1)
        } else {
            let glass = BrowserMobileBarMaterial()
            glass.frame = bar.frame
            glass.overrideUserInterfaceStyle = bar.isDark ? .dark : .light
            surface = glass
            container = glass.contentView
        }
        surface.layer.cornerCurve = .continuous
        surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        surface.clipsToBounds = true
        content.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        content.autoresizingMask = [.flexibleWidth]
        content.alpha = revealsContent ? 1 : 0
        container.addSubview(content)
        // The tab stack and the page menu button ride the panel's top edge
        // and fade; they come back the same way when it closes.
        surfaceGhosts = bar.sideControls.compactMap { control in
            // The pressed button opening the panel would be copied dimmed.
            control.isHighlighted = false
            guard let ghost = control.snapshotView(afterScreenUpdates: true) else { return nil }
            ghost.frame = control.frame
            ghost.isUserInteractionEnabled = false
            container.addSubview(ghost)
            return ghost
        }
        view.insertSubview(surface, aboveSubview: bar)
        self.surface = surface
        if revealsContent {
            // The content takes over the New Tab capsule in place.
            bar.plusButton.alpha = 0
        }
        let sideControls = bar.sideControls
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState]) {
            sideControls.forEach { $0.alpha = 0 }
            self.bar.plusButton.alpha = 0
        }
        if !followsFinger {
            let ghosts = surfaceGhosts
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                ghosts.forEach { $0.alpha = 0 }
            }
        }
        return surface
    }

    /// Shrinks the open panel back into the bar. A panel let go by a finger
    /// passes `velocity`, the finger's downward speed: it takes longer the
    /// farther it has to go and starts at the finger's speed.
    private func closePanel(velocity: CGFloat? = nil, completion: (() -> Void)? = nil) {
        guard let surface else {
            completion?()
            return
        }
        let closingMode = mode
        mode = closingMode == .search && searchOverSwitcher ? .switcher : .browsing
        searchOverSwitcher = false
        if closingMode == .search {
            searchPanel.stopDictation()
            searchPanel.field.resignFirstResponder()
        }
        if let catcher = dismissCatcher {
            catcher.isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
                catcher.alpha = 0
            } completion: { _ in
                catcher.removeFromSuperview()
            }
        }
        dismissCatcher = nil
        surfacePan = nil
        let ghosts = surfaceGhosts
        matchSurfaceTintToBar()
        let distance = max(expandedBarFrame.minY - surface.frame.minY, 1)
        // Let go slowly, the panel takes longer the farther it has to go;
        // flicked, it goes quicker the faster the finger was, down to 0.24 s
        // (most of the way in about 0.15 s) for 2500 points a second.
        let slowDuration = min(max(0.22 + Double(distance) / 1200, 0.3), 0.6)
        let flick = min(max((Double(velocity ?? 0) - 500) / 2000, 0), 1)
        let duration = velocity == nil ? 0.3 : slowDuration - (slowDuration - 0.24) * flick
        // A critically damped spring started faster than its own pace
        // overshoots, so a hard flick is capped there.
        let springVelocity = min(max(velocity ?? 0, 0) / distance, CGFloat(2 * Double.pi / duration))
        // Settles into the bar without dipping below its height.
        UIView.animate(springDuration: duration, bounce: 0, initialSpringVelocity: springVelocity, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = self.expandedBarFrame
            surface.layer.cornerRadius = 0
            self.setSurfaceTint(1)
            // The field or the address row narrows back into the New Tab capsule.
            if closingMode == .search {
                self.searchPanel.setFieldExpanded(false)
                self.pageContainer.transform = .identity
                self.pageContainer.frame = self.view.bounds
                self.pageContainer.layer.cornerRadius = 0
                self.pageDim.alpha = 0
            } else {
                self.pagePanel.setAddressExpanded(false)
            }
        } completion: { _ in
            if self.surface === surface {
                self.bar.sideControls.forEach { $0.alpha = 1 }
                self.bar.plusButton.alpha = 1
                surface.removeFromSuperview()
                self.surface = nil
                self.surfaceGhosts = []
                self.surfaceTint = nil
                self.layoutPage()
                self.layoutBar()
            }
            completion?()
        }
        UIView.animate(withDuration: 0.25, delay: 0.04, options: [.beginFromCurrentState]) {
            ghosts.forEach { $0.alpha = 1 }
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: Page menu

    private func openPageMenu() {
        guard mode == .browsing, workspace.isReady else { return }
        workspace.dismissFindInPage()
        mode = .pageMenu
        pagePanel.onBack = { [weak self] in self?.workspace.goBack() }
        pagePanel.onForward = { [weak self] in self?.workspace.goForward() }
        pagePanel.onReload = { [weak self] in self?.workspace.reloadOrStop() }
        pagePanel.onCopy = { [weak self] in self?.copyLink() }
        pagePanel.onAddress = { [weak self] in
            self?.closePanel { self?.editAddress() }
        }
        pagePanel.onZoomOut = { [weak self] in self?.changeZoom(larger: false) }
        pagePanel.onZoomIn = { [weak self] in self?.changeZoom(larger: true) }
        pagePanel.onToggleDesktop = { [weak self] in
            guard let self else { return }
            workspace.prefersDesktopSite.toggle()
            closePanel()
        }
        pagePanel.onTranslate = { [weak self] in
            self?.closePanel { self?.toggleTranslation() }
        }
        pagePanel.onReader = { [weak self] in
            guard let self else { return }
            workspace.isReading.toggle()
            closePanel()
        }
        pagePanel.onSiteSettings = { [weak self] in self?.showSiteSettings() }
        pagePanel.onExtensions = { [weak self] in self?.showExtensions() }
        pagePanel.onContentHeightChange = { [weak self] layout in self?.resizePagePanel(layout) }
        updatePagePanel()
        let height = pagePanel.contentHeight + safeBottom
        openPagePanel(height: height)
        updateVerticalBar(pageMenuHeight: height)
    }

    /// Lays the status column down along the top while the page menu reaches it.
    private func updateVerticalBar(pageMenuHeight: CGFloat?) {
        let reaches = mode == .pageMenu && pageMenuHeight.flatMap { height in
            statusColumnBottom.map { view.bounds.height - height < $0 }
        } == true
        guard reaches != pageMenuReachesStatus else { return }
        pageMenuReachesStatus = reaches
        if #available(iOS 27.1, *) {
            setNeedsUpdateOfVerticalBarConfiguration()
        }
    }

    private func updatePagePanel() {
        let tab = workspace.selectedTab
        let isWebPage = shareURL != nil
        let document = workspace.profileDocument
        let isPinned = tab.flatMap { workspace.pinnedSpaceTabID(urlString: $0.urlString) } != nil
        var tiles = [BrowserMobilePagePanel.Tile]()
        tiles.append(.init(
            title: String(localized: "Find on Page", table: "Mobile"), symbol: "doc.text.magnifyingglass",
            identifier: "browser.findInPage", isEnabled: isWebPage,
        ) { [weak self] in
            self?.closePanel { self?.findInPage() }
        })
        tiles.append(.init(
            title: String(localized: "Downloads", table: "Mobile"), symbol: "arrow.down.circle",
            identifier: "browser.downloads", isEnabled: workspace.downloads != nil,
        ) { [weak self] in
            self?.closePanel { self?.showDownloads() }
        })
        tiles.append(.init(
            title: isPinned ? String(localized: "Unpin", table: "Mobile") : String(localized: "Pin", table: "Mobile"),
            symbol: isPinned ? "pin.slash" : "pin", identifier: "browser.pin",
            isEnabled: document?.canEdit == true && !workspace.spaces.isEmpty && tab?.isPrivate == false && isWebPage,
            menu: isPinned ? nil : pinMenu(),
        ) { [weak self] in
            self?.togglePin()
        })
        tiles.append(.init(
            title: String(localized: "Share", table: "Mobile"), symbol: "square.and.arrow.up",
            identifier: "browser.share", isEnabled: isWebPage,
        ) { [weak self] in
            self?.closePanel { self?.sharePage() }
        })
        let zoom = workspace.pageZoom
        pagePanel.update(
            host: BrowserMobilePageViewController.displayAddress(tab?.urlString),
            canGoBack: tab?.state.canGoBack == true, canGoForward: tab?.state.canGoForward == true,
            isLoading: tab?.state.isLoading == true, canCopy: isWebPage,
            canReload: tab != nil && tab?.urlString != "about:blank",
            tiles: tiles,
            display: isWebPage
                ? .init(
                    zoomPercent: Int((zoom * 100).rounded()), canZoomOut: zoom > Self.zoomSteps[0] + 0.001,
                    canZoomIn: zoom < Self.zoomSteps[Self.zoomSteps.count - 1] - 0.001,
                    prefersDesktop: workspace.prefersDesktopSite,
                    isTranslated: tab?.state.isTranslated == true || (tab != nil && translationRun?.tabID == tab?.id),
                    canRead: tab?.state.canRead == true,
                    isReading: tab?.state.isReading == true,
                )
                : nil,
            hasSiteSettings: siteHost != nil,
        )
    }

    /// The extensions' actions for the page, over the page menu.
    private func showExtensions() {
        guard let engine = workspace.extensionEngine, presentedViewController == nil else { return }
        BrowserMobileExtensionActionsViewController.present(engine: engine, from: self, anchor: nil) { [weak self] in
            self?.closePanel { self?.showSettings(opensExtensions: true) }
        }
    }

    private func showSiteSettings() {
        guard let host = siteHost, presentedViewController == nil else { return }
        let controller = BrowserMobileSiteSettingsViewController(host: host)
        controller.didChangeBlocking = { [weak self] in self?.workspace.reload() }
        controller.showAppSettings = { [weak self, weak controller] in
            controller?.dismiss(animated: true) {
                self?.closePanel { self?.showSettings() }
            }
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        navigation.sheetPresentationController?.preferredCornerRadius = 36
        navigation.view.backgroundColor = BrowserMobileSiteSettingsViewController.sheetBackground
        present(navigation, animated: true)
    }

    /// Display Options opened or closed: the panel grows or shrinks upward.
    private func resizePagePanel(_ layout: @escaping () -> Void) {
        guard mode == .pageMenu, let surface else {
            layout()
            return
        }
        let height = pagePanel.contentHeight + safeBottom
        updateVerticalBar(pageMenuHeight: height)
        UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = CGRect(
                x: 0, y: self.view.bounds.height - height, width: self.view.bounds.width, height: height,
            )
            self.pagePanel.frame.size.height = height
            layout()
        }
    }

    private func changeZoom(larger: Bool) {
        setZoom(Self.nextZoom(from: workspace.pageZoom, larger: larger))
    }

    private func setZoom(_ zoom: CGFloat) {
        workspace.pageZoom = zoom
        updatePagePanel()
    }

    private func copyLink() {
        guard let url = shareURL else { return }
        UIPasteboard.general.url = url
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        closePanel()
        BrowserMobileToast.show(
            String(localized: "Copied URL", table: "Mobile"), in: view, barTop: view.bounds.height - expandedBarHeight,
        )
    }

    /// Where Pin can put the page: Favorites, the top of any Space, or a
    /// folder of the Space the Spaces picker shows. The mobile tab stays.
    private func pinMenu() -> UIMenu? {
        guard let document = workspace.profileDocument, workspace.selectedTab != nil,
              let spaceID = workspace.selectedSpaceID ?? workspace.spaces.first?.id else { return nil }
        let pin = { [weak self] (space: String, placement: BrowserTabPlacement, folder: String?) in
            guard let self else { return }
            workspace.pinSelectedTab(spaceID: space, placement: placement, pinnedFolderID: folder)
            updatePagePanel()
        }
        var children = [UIMenuElement]()
        children.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Favorite in App", table: "Mobile"), image: UIImage(systemName: "iphone"),
            ) { _ in pin(spaceID, .app, nil) },
        ]))
        let spaces = workspace.spaces.map { space in
            UIAction(
                title: space.title, image: UIImage(systemName: space.systemImageName),
            ) { _ in pin(space.id, .spacePinned, nil) }
        }
        if !spaces.isEmpty {
            children.append(UIMenu(
                title: String(localized: "Pin to Space:", table: "Mobile"), options: .displayInline,
                children: spaces,
            ))
        }
        let folders = (document.snapshot.pinnedTabFolders ?? []).filter { $0.spaceID == spaceID }
        if !folders.isEmpty {
            children.append(UIMenu(options: .displayInline, children: [
                UIMenu(
                    title: String(localized: "Pin to Folder…", table: "Mobile"),
                    image: UIImage(systemName: "folder.badge.plus"),
                    children: folders.map { folder in
                        UIAction(
                            title: folder.title, image: UIImage(systemName: folder.systemImageName ?? "folder"),
                        ) { _ in pin(spaceID, .spacePinned, folder.id) }
                    },
                ),
            ]))
        }
        return UIMenu(children: children)
    }

    /// Pins the page to the Space the Spaces picker shows, or removes the
    /// Space's pinned copy of it.
    private func togglePin() {
        guard let document = workspace.profileDocument, let tab = workspace.selectedTab else { return }
        if let pinned = workspace.pinnedSpaceTabID(urlString: tab.urlString) {
            document.removeTab(id: pinned)
        } else {
            workspace.pinSelectedTab()
        }
        updatePagePanel()
    }

    private func showOpenedLink() {
        presentedViewController?.dismiss(animated: true)
        switch mode {
        case .browsing: break
        case .switcher: closeSwitcherInstantly()
        case .pageMenu: closePanel()
        case .search: closeSearchForPage()
        }
    }

    // MARK: Search

    /// Opens the search panel. With `replacesPage` the typed address loads in
    /// the current tab; otherwise it opens a new one.
    private func openSearch(text: String, replacesPage: Bool) {
        guard beginSearch(text: text, replacesPage: replacesPage) else { return }
        finishOpeningSearch()
    }

    /// Puts the search panel over the bar, its field still the New Tab
    /// capsule; `finishOpeningSearch` raises it.
    private func beginSearch(text: String, replacesPage: Bool, followsFinger: Bool = false) -> Bool {
        guard workspace.isReady else { return false }
        let overSwitcher = mode == .switcher && switcher != nil && !isAnimatingSwitcher
        if mode == .switcher, !overSwitcher {
            closeSwitcherInstantly()
        }
        guard mode == .browsing || overSwitcher else { return false }
        isSearchKeyboardDismissed = false
        // The page is still full screen: its picture is right for the switcher
        // only now, before it shrinks behind the panel.
        if !overSwitcher, let tab = workspace.selectedTab, !tab.state.isLoading {
            capturePageIfFullScreen(tab.id)
        }
        workspace.dismissFindInPage()
        searchOverSwitcher = overSwitcher
        mode = .search
        searchReplacesPage = replacesPage
        searchPanel.candidates = searchCandidates()
        searchPanel.onSubmit = { [weak self] text in self?.submitSearch(text) }
        searchPanel.onSelect = { [weak self] item in self?.selectSuggestion(item) }
        searchPanel.onPanelPull = { [weak self] offset in self?.pullSearchPanel(by: offset) }
        searchPanel.onRemove = { [weak self] item in
            guard let self, let page = item.iconPage else { return }
            BrowserMobileRemovedSuggestions.remove(page)
            searchPanel.candidates = searchCandidates()
        }
        // Editing a private tab's address stays private.
        searchPanel.isIncognito = workspace.isIncognito || (replacesPage && workspace.selectedTab?.isPrivate == true)
        searchPanel.onIncognitoChange = { [weak self] isOn in self?.workspace.isIncognito = isOn }
        searchPanel.prepare(text: text)
        let top = searchPanelTop(keyboardTop: searchKeyboardTop)
        guard let surface = makeSurface(
            height: view.bounds.height - top, dark: true, content: searchPanel, revealsContent: true,
            followsFinger: followsFinger,
        ) else {
            mode = overSwitcher ? .switcher : .browsing
            searchOverSwitcher = false
            return false
        }
        searchPanel.setFieldExpanded(false)
        addSurfacePan(to: surface)
        pageContainer.layer.cornerRadius = 0
        setNeedsStatusBarAppearanceUpdate()
        return true
    }

    /// Raises the search panel above the keyboard: the capsule widens into the
    /// field and the page shrinks into a card.
    private func finishOpeningSearch() {
        guard mode == .search, let surface else { return }
        searchPanel.focus()
        let top = searchPanelTop(keyboardTop: searchKeyboardTop)
        let card = searchCardFrame()
        UIView.animate(springDuration: 0.42, bounce: 0.12, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = CGRect(x: 0, y: top, width: self.view.bounds.width, height: self.view.bounds.height - top)
            surface.layer.cornerRadius = 36
            self.setSurfaceTint(0)
            self.searchPanel.setFieldExpanded(true)
            self.surfaceGhosts.forEach { $0.alpha = 0 }
        }
        UIView.animate(springDuration: 0.42, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            self.applyPageCard(card)
        }
    }

    /// The page shrinks into a card above the search panel.
    private func searchCardFrame() -> CGRect {
        let inset: CGFloat = 10.5
        let width = view.bounds.width - inset * 2
        let height = width * view.bounds.height / view.bounds.width
        return CGRect(x: inset, y: view.safeAreaInsets.top + 1, width: width, height: height)
    }

    /// The page behind search follows the panel's top edge at `y`: its search
    /// card with the panel in place, growing back to the full screen as the
    /// panel goes down into the bar, and shrinking further about its middle as
    /// a finger lifts the panel past its place.
    private func searchCardFrame(panelTop y: CGFloat) -> CGRect {
        let card = searchCardFrame()
        let rest = searchPanelTop(keyboardTop: searchKeyboardTop)
        guard y < rest else {
            let progress = (y - rest) / max(expandedBarFrame.minY - rest, 1)
            return interpolate(card, view.bounds, min(progress, 1))
        }
        let width = max(card.width - (rest - y) * 0.12, card.width * 0.85)
        let height = width * card.height / card.width
        return CGRect(x: card.midX - width / 2, y: card.midY - height / 2, width: width, height: height)
    }

    private func applyPageCard(_ frame: CGRect) {
        let scale = frame.width / view.bounds.width
        pageContainer.bounds = view.bounds
        pageContainer.center = CGPoint(x: frame.midX, y: frame.midY)
        pageContainer.transform = CGAffineTransform(scaleX: scale, y: scale)
        pageContainer.layer.cornerRadius = 24 / scale
        pageDim.frame = pageContainer.bounds
        // The card darkens as it shrinks, to 0.2 at its search size.
        let cardScale = searchCardFrame().width / view.bounds.width
        pageDim.alpha = 0.2 * min(max((1 - scale) / max(1 - cardScale, 0.01), 0), 1)
    }

    private func searchPanelTop(keyboardTop: CGFloat) -> CGFloat {
        max(view.safeAreaInsets.top + 160, keyboardTop - 301)
    }

    private func layoutSearchPanel(keyboardTop: CGFloat) {
        guard let surface else { return }
        let panelTop = searchPanelTop(keyboardTop: keyboardTop)
        surface.frame = CGRect(x: 0, y: panelTop, width: view.bounds.width, height: view.bounds.height - panelTop)
        searchPanel.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: keyboardTop - panelTop)
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let hides = notification.name == UIResponder.keyboardWillHideNotification
        let top = hides ? view.bounds.height : view.convert(frame, from: nil).minY
        keyboardTop = top < view.bounds.height ? top : nil
        bar.isHidden = workspace.isFindInPageVisible && mode == .browsing
        guard mode == .search, surface != nil, keyboardTop != nil || searchPanel.isFieldExpanded else { return }
        // The keyboard pulled away under a finger takes search with it, so
        // the drag goes on into closing instead of leaving the panel at the bottom.
        if hides, searchPanel.isPullingKeyboard {
            // A keyboard pulled all the way off is announced inside the
            // keyboard's own animation, or with animations off; closing a
            // turn later keeps the panel's own animation.
            DispatchQueue.main.async { [weak self] in
                guard let self, mode == .search else { return }
                closePanel(velocity: searchPanel.suggestionsReleaseVelocity)
            }
            return
        }
        // Search stays open only with its keyboard: a keyboard that goes for
        // any other reason, while the app is in front and nothing covers
        // search, closes it.
        if hides, searchPanel.isFieldExpanded, presentedViewController == nil,
           view.window?.windowScene?.activationState == .foregroundActive
        {
            closePanel()
            return
        }
        isSearchKeyboardDismissed = keyboardTop == nil
        // A panel a finger holds stays under it; let go, it settles on the keyboard.
        guard !searchPanel.isPullingPanel else { return }
        let bottom = searchKeyboardTop
        let height = searchPanel.frame.height
        UIView.animate(springDuration: 0.42, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            self.layoutSearchPanel(keyboardTop: bottom)
            self.holdSearchPanelHeight(height)
            if self.searchPanel.isFieldExpanded {
                self.applyPageCard(self.searchCardFrame())
            }
        } completion: { _ in
            self.fitSearchPanelAfterHold()
        }
    }

    /// A drag down the suggestions pulls the keyboard, and the panel stays on top of it,
    /// unless the drag holds the panel itself.
    private func followKeyboardUnderFinger() {
        guard mode == .search, surface != nil, searchPanel.isFieldExpanded, searchPanel.isDraggingSuggestions,
              !searchPanel.isPullingPanel,
              surfacePan.map({ $0.state != .began && $0.state != .changed }) ?? true
        else { return }
        let top = keyboardTracker.frame.minY
        UIView.performWithoutAnimation {
            layoutSearchPanel(keyboardTop: top < view.bounds.height ? top : view.bounds.height)
            if let surface { applyPageCard(searchCardFrame(panelTop: surface.frame.minY)) }
        }
    }

    /// A drag on the suggestions past their top moves the panel with the
    /// finger: down it slides under the keyboard until the finger reaches the
    /// keyboard and takes it along, up it comes harder with each point. Let go, it goes
    /// back on top of the keyboard, unless the keyboard leaves and closes search.
    private func pullSearchPanel(by offset: CGFloat?) {
        guard mode == .search, let surface, searchPanel.isFieldExpanded else { return }
        let keyboardTop = searchKeyboardTop
        guard let offset else {
            // A keyboard the finger took along either leaves, and search
            // closes from here, or comes back, and the panel rides it up;
            // springing back now would jump the panel up before either.
            if keyboardTracker.frame.minY > keyboardTop + 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    // A finger back on the list holds the panel again.
                    guard let self, !searchPanel.isDraggingSuggestions else { return }
                    settleSearchPanel()
                }
                return
            }
            settleSearchPanel()
            return
        }
        let restTop = searchPanelTop(keyboardTop: keyboardTop)
        let y = offset >= 0 ? restTop + offset : restTop - liftResistance(-offset, from: restTop)
        UIView.performWithoutAnimation {
            surface.frame = CGRect(x: 0, y: y, width: view.bounds.width, height: view.bounds.height - y)
            fitSearchPanel(top: y)
            applyPageCard(searchCardFrame(panelTop: y))
        }
    }

    /// An open search panel let go goes back on top of the keyboard.
    private func settleSearchPanel() {
        guard mode == .search, let surface, searchPanel.isFieldExpanded else { return }
        let keyboardTop = searchKeyboardTop
        guard surface.frame.minY != searchPanelTop(keyboardTop: keyboardTop) else { return }
        let height = searchPanel.frame.height
        UIView.animate(springDuration: 0.32, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            self.layoutSearchPanel(keyboardTop: keyboardTop)
            self.holdSearchPanelHeight(height)
            self.applyPageCard(self.searchCardFrame())
        } completion: { _ in
            self.fitSearchPanelAfterHold()
        }
    }

    /// A table cut shorter in an animation drops the rows below its new
    /// bottom at once, so a lifted list going back would lose its lower rows
    /// before the panel gets there. It keeps its height, the rest hidden by
    /// the keyboard, until the panel has settled.
    private func holdSearchPanelHeight(_ height: CGFloat) {
        if searchPanel.frame.height < height {
            searchPanel.frame.size.height = height
        }
    }

    private func fitSearchPanelAfterHold() {
        guard mode == .search, let surface, !searchPanel.isDraggingSuggestions,
              surfacePan.map({ $0.state != .began && $0.state != .changed }) ?? true
        else { return }
        UIView.performWithoutAnimation {
            fitSearchPanel(top: surface.frame.minY)
        }
    }

    /// The search panel's content reaches down to the keyboard from wherever
    /// the panel is lifted to, so a lifted list shows more rows instead of
    /// ending short; lowered, it keeps its size and slides under the keyboard.
    private func fitSearchPanel(top y: CGFloat) {
        let keyboardTop = searchKeyboardTop
        let restTop = searchPanelTop(keyboardTop: keyboardTop)
        searchPanel.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: keyboardTop - min(y, restTop))
    }

    private func searchCandidates() -> [BrowserMobileSearchSuggestions.Candidate] {
        // Private tabs are not suggested.
        var result = workspace.switcherTabs.reversed().filter { !$0.isPrivate }.map { tab in
            BrowserMobileSearchSuggestions.Candidate(
                tabID: tab.id, title: tab.userTitleOverride ?? tab.title, urlString: tab.urlString,
                location: location(of: tab),
            )
        }
        // Favorites and pinned tabs of the Spaces open as mobile tabs.
        let listedURLs = Set(result.map(\.urlString))
        for tab in workspace.spaceTabs where !listedURLs.contains(tab.urlString) && tab.placement != .temporary {
            result.append(.init(
                tabID: tab.id, title: tab.userTitleOverride ?? tab.title, urlString: tab.urlString,
                location: location(of: tab),
            ))
        }
        let removed = BrowserMobileRemovedSuggestions.pages()
        return result.filter { $0.urlString != "about:blank" && !removed.contains($0.urlString) }
    }

    private func location(of tab: BrowserMobileTab) -> String? {
        let space = workspace.spaces.first { $0.id == tab.spaceID }?.title
        let place =
            switch tab.placement {
            case .app: String(localized: "Favorites", table: "Mobile")
            case .temporary where tab.spaceID == nil: String(localized: "Tab", table: "Mobile")
            case .temporary: String(localized: "Today", table: "Mobile")
            default: String(localized: "Pinned", table: "Mobile")
            }
        return space.map { String(localized: "\(place) in \($0)", table: "Mobile") } ?? place
    }

    private func submitSearch(_ text: String) {
        let isPrivate = searchPanel.isIncognito
        // A page loads in the current tab only when that keeps it as private
        // as the search asked; otherwise it gets a tab of its own.
        let replaces = searchReplacesPage && workspace.selectedTab?.isPrivate == isPrivate
        closeSearchForPage()
        if replaces {
            workspace.submit(text)
        } else if isPrivate {
            workspace.submitInNewPrivateTab(text)
        } else {
            workspace.submitInNewTab(text)
        }
    }

    /// Closes search for a page it chose; search over the switcher takes the
    /// switcher with it.
    private func closeSearchForPage() {
        let overSwitcher = searchOverSwitcher
        closePanel()
        if overSwitcher { closeSwitcherInstantly() }
    }

    private func selectSuggestion(_ item: BrowserMobileSearchSuggestions.Item) {
        switch item.kind {
        case .address(let address): submitSearch(address)
        case .search(let query): submitSearch(query)
        case .tab(let id):
            closeSearchForPage()
            if id != workspace.selectedTabID {
                if let current = workspace.selectedTabID { capturePageIfFullScreen(current) }
                if workspace.tabs.contains(where: { $0.id == id }) {
                    workspace.selectTab(id: id)
                } else {
                    workspace.openSpaceTab(id: id)
                }
            }
        }
    }

    // MARK: Switcher

    private func refreshSwitcherEntries() {
        guard let switcher else { return }
        let entries = switcherEntries()
        guard entries != switcher.entries else { return }
        switcher.setEntries(entries, focus: switcher.position)
        for entry in entries where switcher.card(for: entry.id)?.livePicture == nil {
            switcher.setPicture(thumbnails.image(for: entry.id), for: entry.id)
        }
    }

    private func switcherEntries() -> [BrowserMobileTabSwitcherView.Entry] {
        workspace.switcherTabs.map {
            // A page that failed to load keeps the title of the one before it.
            let title = $0.state.error == nil ? $0.title : String(localized: "Cannot Load Page", table: "Mobile")
            return .init(
                id: $0.id, title: $0.userTitleOverride ?? title, urlString: $0.urlString, isPrivate: $0.isPrivate,
            )
        }
    }

    /// Shrinks the page into its card at the right while the other tabs grow
    /// out of the tab stack's cards into the row, centered on the previous tab.
    private func openSwitcher() {
        guard mode == .browsing, workspace.isReady, switcher == nil else { return }
        workspace.dismissFindInPage()
        let entries = switcherEntries()
        guard !entries.isEmpty else {
            openSearch(text: "", replacesPage: false)
            return
        }
        setBarCollapsed(false, animated: false)
        mode = .switcher
        let currentID = workspace.selectedTabID
        if let currentID {
            thumbnails.capture(currentID, workspace: workspace, width: thumbnailWidth)
        }
        let switcher = BrowserMobileTabSwitcherView(frame: view.bounds)
        wireSwitcher(switcher)
        switcher.pageSideInsets = (view.safeAreaInsets.left, view.safeAreaInsets.right)
        switcher.pageTopInset = view.safeAreaInsets.top
        let currentIndex = entries.firstIndex { $0.id == currentID } ?? entries.count - 1
        let focus = CGFloat(max(currentIndex - 1, 0))
        switcher.setEntries(entries, focus: focus)
        for entry in entries {
            switcher.setPicture(thumbnails.image(for: entry.id), for: entry.id)
        }
        let live = currentID.flatMap { _ in pageContainer.snapshotView(afterScreenUpdates: false) }
        if let currentID, let live {
            live.frame = view.bounds
            switcher.setLivePicture(live, for: currentID)
        }
        // The bar stays: its controls change over the switcher.
        view.insertSubview(switcher, belowSubview: bar)
        self.switcher = switcher
        isAnimatingSwitcher = true
        setNeedsStatusBarAppearanceUpdate()
        // The tabs' cards take the place of the stack's pictures, hidden
        // before the bar's crossfade pictures it; a blank card fades with the bar.
        let slots = stackSlots(around: currentID, in: entries.map(\.id))
        hideStackCards(under: Set(slots.values))
        setBackdropDark(true)

        // The page's card is the page from here on: no copy of it stays
        // behind to fade, and the switcher's backdrop shows around it at once.
        pageContainer.isHidden = true
        var flying = [(card: BrowserMobileTabSwitcherView.Card, slot: Int, isOlder: Bool)]()
        for (index, entry) in entries.enumerated() {
            guard let card = switcher.card(for: entry.id) else { continue }
            let frame = switcher.cardFrame(index: index, position: focus)
            if entry.id == currentID {
                // The page itself shrinks from full screen into its card.
                card.bounds.size = view.bounds.size
                card.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                card.titleAlpha = 0
                card.layoutIfNeeded()
            } else {
                // The stack's two cards are these cards, small; the rest come from behind them.
                let slot = slots[entry.id] ?? Self.hiddenStackSlot
                let pose = stackPose(slot: slot, width: frame.width)
                card.bounds.size = pose.size
                card.center = pose.center
                card.transform = pose.transform
                card.titleAlpha = 0
                card.alpha = slot < Self.hiddenStackSlot ? 1 : 0
                card.layoutIfNeeded()
                flying.append((card, slot, index < currentIndex))
            }
        }
        let flight = makeSwitcherFlight()
        // Tabs before the page fly under it: the page stays under the bar,
        // so they are hidden where it covers them, through a hole that moves
        // with it in the same animation.
        let under = UIView(frame: flight.bounds)
        flight.addSubview(under)
        let over = UIView(frame: flight.bounds)
        flight.addSubview(over)
        let ordered = flying.sorted { $0.slot > $1.slot }
        switcher.lift(ordered.filter(\.isOlder).map(\.card), into: under)
        switcher.lift(ordered.filter { !$0.isOlder }.map(\.card), into: over)
        let page = currentID.flatMap { switcher.card(for: $0) }
        let hole = page.map { makeFlightHole(in: under, around: $0) }
        // The bar's material and controls give way within a couple of frames.
        UIView.animate(withDuration: 0.05) {
            self.bar.setShowsSwitcherControls(true)
        }
        UIView.animate(withDuration: 0.15) {
            for card in entries.compactMap({ switcher.card(for: $0.id) }) where card.alpha == 0 {
                card.alpha = 1
            }
        }
        // The page drops into its card at once, slowing down as it lands;
        // the other cards take a little longer to grow out of the stack.
        UIView.animate(springDuration: 0.12, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction,
        ]) {
            switcher.layoutCards { $0 == currentID }
            page?.layoutIfNeeded()
            if let hole, let page {
                self.placeFlightHole(hole, in: under, around: page)
            }
        }
        UIView.animate(springDuration: 0.2, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction,
        ]) {
            let others = entries.filter { $0.id != currentID }.compactMap { switcher.card(for: $0.id) }
            for card in others {
                card.transform = .identity
            }
            switcher.layoutCards { $0 != currentID }
            for card in others {
                card.layoutIfNeeded()
            }
        } completion: { _ in
            switcher.restoreLiftedCards()
            self.hideStackCards(under: [])
            self.removeSwitcherFlight()
            self.isAnimatingSwitcher = false
            self.refreshSwitcherEntries()
        }
    }

    private func wireSwitcher(_ switcher: BrowserMobileTabSwitcherView) {
        switcher.onOpen = { [weak self] id in self?.closeSwitcher(opening: id) }
        switcher.onClose = { [weak self] id in
            guard let self else { return }
            thumbnails.remove(id)
            workspace.closeTab(id: id)
            if workspace.switcherTabs.isEmpty {
                closeSwitcherInstantly()
                openSearch(text: "", replacesPage: false)
            }
        }
        switcher.onDismiss = { [weak self] in self?.returnFromSwitcher() }
    }

    /// The chosen card grows to fill the screen, then the page takes its
    /// place. Choosing the open tab sends the other cards back into the tab
    /// stack, the way they came; choosing another zooms the row around it,
    /// so the others slide out past the sides.
    private func closeSwitcher(opening id: String) {
        guard let switcher, mode == .switcher, !isAnimatingSwitcher, let card = switcher.card(for: id) else { return }
        isAnimatingSwitcher = true
        let wasOpen = id == workspace.selectedTabID
        if !wasOpen {
            workspace.selectTab(id: id)
        }
        matchBackdrop(toPictureOf: id)
        isLeavingSwitcher = true
        setNeedsStatusBarAppearanceUpdate()
        card.superview?.bringSubviewToFront(card)
        card.titleAlpha = 0
        guard wasOpen else {
            zoomRow(of: switcher, into: card, keeping: id)
            return
        }
        let others = liftIntoStackFlight(switcher, keeping: id)
        UIView.animate(withDuration: 0.1) {
            self.bar.setShowsSwitcherControls(false)
        }
        UIView.animate(springDuration: 0.26, bounce: 0, initialSpringVelocity: 0, delay: 0, options: []) {
            card.bounds.size = self.view.bounds.size
            card.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            card.depthDim = 0
            card.layoutIfNeeded()
            self.flyIntoStack(others)
        } completion: { _ in
            self.landInStack()
        }
        fadeHiddenStackCards(others)
    }

    /// Grows `card` to fill the screen and the rest of the row with it, as
    /// if the camera moved in on it.
    private func zoomRow(
        of switcher: BrowserMobileTabSwitcherView, into card: BrowserMobileTabSwitcherView.Card, keeping id: String,
    ) {
        let scale = view.bounds.width / max(card.frame.width, 1)
        let from = card.center
        let to = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let others = switcher.entries.compactMap { $0.id == id ? nil : switcher.card(for: $0.id) }
        updateTabStack()
        hideStackCards(under: [])
        UIView.animate(withDuration: 0.1) {
            self.bar.setShowsSwitcherControls(false)
        }
        UIView.animate(springDuration: 0.26, bounce: 0, initialSpringVelocity: 0, delay: 0, options: []) {
            card.bounds.size = self.view.bounds.size
            card.center = to
            card.depthDim = 0
            card.layoutIfNeeded()
            for other in others {
                other.titleAlpha = 0
                other.center = CGPoint(
                    x: to.x + (other.center.x - from.x) * scale, y: to.y + (other.center.y - from.y) * scale,
                )
                other.transform = other.transform.scaledBy(x: scale, y: scale)
            }
        } completion: { _ in
            self.landInStack()
        }
    }

    /// A tap between the cards: the open tab grows back to full screen while
    /// the others fly into the tab stack, the way they came.
    private func returnFromSwitcher() {
        guard let switcher, mode == .switcher, !isAnimatingSwitcher else { return }
        let selected = workspace.selectedTabID.flatMap { switcher.card(for: $0) == nil ? nil : $0 }
        guard let id = selected ?? switcher.entries.last?.id, let card = switcher.card(for: id) else {
            finishSwitcher()
            return
        }
        isAnimatingSwitcher = true
        if id != workspace.selectedTabID {
            workspace.selectTab(id: id)
        }
        matchBackdrop(toPictureOf: id)
        isLeavingSwitcher = true
        setNeedsStatusBarAppearanceUpdate()
        card.superview?.bringSubviewToFront(card)
        let others = liftIntoStackFlight(switcher, keeping: id)
        UIView.animate(springDuration: 0.26, bounce: 0, initialSpringVelocity: 0, delay: 0, options: []) {
            card.titleAlpha = 0
            card.bounds.size = self.view.bounds.size
            card.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            card.depthDim = 0
            card.layoutIfNeeded()
            self.flyIntoStack(others)
        } completion: { _ in
            self.landInStack()
        }
        fadeHiddenStackCards(others)
        UIView.animate(withDuration: 0.15) {
            self.bar.setShowsSwitcherControls(false)
        }
    }

    /// Which of the tab stack's cards each tab is when `selectedID` is open:
    /// 0 the front, 1 the back, `hiddenStackSlot` behind them.
    private func stackSlots(around selectedID: String?, in ids: [String]) -> [String: Int] {
        var slots = [String: Int]()
        for (rank, id) in ids.filter({ $0 != selectedID }).reversed().enumerated() {
            slots[id] = min(rank, Self.hiddenStackSlot)
        }
        return slots
    }

    /// A switcher card `width` points wide placed as one of the tab stack's
    /// cards: its size before the transform and where it sits in the view.
    private func stackPose(slot: Int, width: CGFloat) -> (
        center: CGPoint, size: CGSize, transform: CGAffineTransform,
    ) {
        let stack = BrowserMobileTabStackButton.self
        let isFront = slot == 0
        let offset = isFront ? stack.frontOffset : stack.backOffset
        let center = bar.convert(bar.tabStack.center, to: view)
        let scale = stack.cardSize.width / max(width, 1)
        return (
            CGPoint(x: center.x + offset.x, y: center.y + offset.y),
            CGSize(width: width, height: width * stack.cardSize.height / stack.cardSize.width),
            CGAffineTransform(rotationAngle: isFront ? stack.frontAngle : stack.backAngle).scaledBy(x: scale, y: scale),
        )
    }

    private func makeSwitcherFlight() -> UIView {
        removeSwitcherFlight()
        let flight = UIView(frame: view.bounds)
        flight.isUserInteractionEnabled = false
        view.insertSubview(flight, aboveSubview: bar)
        switcherFlight = flight
        return flight
    }

    private func removeSwitcherFlight() {
        switcherFlight?.removeFromSuperview()
        switcherFlight = nil
    }

    /// Masks `host` with a hole the shape of `card`, so what flies in it is
    /// hidden where the card covers it. Move the hole with `placeFlightHole`
    /// in the card's own animation.
    private func makeFlightHole(in host: UIView, around card: UIView) -> UIView {
        let mask = UIView(frame: host.bounds)
        let ring = UIView()
        ring.layer.borderColor = UIColor.black.cgColor
        ring.layer.cornerCurve = .continuous
        mask.addSubview(ring)
        host.mask = mask
        placeFlightHole(ring, in: host, around: card)
        return ring
    }

    /// The hole is the inside of a ring reaching past the screen: its inner
    /// edge is the card's rounded outline.
    private func placeFlightHole(_ ring: UIView, in host: UIView, around card: UIView) {
        guard let superview = card.superview else { return }
        let frame = superview.convert(card.frame, to: host)
        let reach = max(view.bounds.width, view.bounds.height) * 2
        ring.frame = frame.insetBy(dx: -reach, dy: -reach)
        ring.layer.borderWidth = reach
        ring.layer.cornerRadius = BrowserMobileTabSwitcherView.cornerRadius + reach
    }

    /// Lifts the cards other than `id`'s over the bar for their flight into
    /// the stack, which shows the tabs it will have, but not where they land.
    private func liftIntoStackFlight(
        _ switcher: BrowserMobileTabSwitcherView, keeping id: String,
    ) -> [(card: BrowserMobileTabSwitcherView.Card, slot: Int)] {
        let slots = stackSlots(around: id, in: switcher.entries.map(\.id))
        updateTabStack()
        hideStackCards(under: Set(slots.values))
        let others = switcher.entries
            .compactMap { entry in
                slots[entry.id].flatMap { slot in switcher.card(for: entry.id).map { (card: $0, slot: slot) } }
            }
            .sorted { $0.slot > $1.slot }
        switcher.lift(others.map(\.card), into: makeSwitcherFlight())
        return others
    }

    /// Hides the stack's pictures that switcher cards stand in for.
    private func hideStackCards(under slots: Set<Int>) {
        bar.tabStack.front.alpha = slots.contains(0) ? 0 : 1
        bar.tabStack.back.alpha = slots.contains(1) ? 0 : 1
    }

    /// The flown cards have landed: the stack shows its pictures under them,
    /// and once it has drawn so, the switcher goes. A crossfade of the bar
    /// starting then pictures the stack whole.
    private func landInStack() {
        hideStackCards(under: [])
        let landing = switcher
        DispatchQueue.main.async { [weak self] in
            guard let self, let landing, switcher === landing else { return }
            finishSwitcher()
        }
    }

    /// Call inside an animation: each card shrinks onto its card of the stack.
    private func flyIntoStack(_ cards: [(card: BrowserMobileTabSwitcherView.Card, slot: Int)]) {
        for (card, slot) in cards {
            let pose = stackPose(slot: slot, width: card.bounds.width)
            card.titleAlpha = 0
            card.bounds.size = pose.size
            card.center = pose.center
            card.transform = pose.transform
            card.layoutIfNeeded()
        }
    }

    /// The cards the stack does not show fade as they go behind its back card.
    private func fadeHiddenStackCards(_ cards: [(card: BrowserMobileTabSwitcherView.Card, slot: Int)]) {
        UIView.animate(withDuration: 0.12, delay: 0.1) {
            for (card, slot) in cards where slot >= Self.hiddenStackSlot {
                card.alpha = 0
            }
        }
    }

    private func finishSwitcher() {
        let id = workspace.selectedTabID
        // The page that was live before the switcher opened needs no cover.
        let picture = id.flatMap { switcher?.card(for: $0)?.livePicture == nil ? pagePicture(for: $0) : nil }
        switcher?.removeFromSuperview()
        switcher = nil
        isLeavingSwitcher = false
        removeSwitcherFlight()
        pageContainer.isHidden = showsHome
        hideStackCards(under: [])
        isAnimatingSwitcher = false
        mode = .browsing
        bar.setShowsSwitcherControls(false)
        // The picture covers the page before the page's colors are read.
        if let id, let picture {
            coverWhileLoading(id, with: picture)
        }
        setNeedsStatusBarAppearanceUpdate()
        render()
    }

    private func closeSwitcherInstantly() {
        guard switcher != nil else { return }
        finishSwitcher()
    }

    private func showSpaces() {
        guard presentedViewController == nil else { return }
        let controller = BrowserMobileTabsViewController(workspace: workspace, isPhoneSheet: true)
        controller.didSelectTab = { [weak self, weak controller] in
            controller?.dismiss(animated: true)
            guard let self, let id = workspace.selectedTabID else { return }
            refreshSwitcherEntries()
            closeSwitcher(opening: id)
        }
        // A small filled circle with the sheet's color showing through the cross.
        let close = UIButton(type: .system)
        close.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)),
            for: .normal,
        )
        close.tintColor = UIColor(white: 1, alpha: 0.25)
        close.accessibilityLabel = String(localized: "Close", table: "Mobile")
        close.accessibilityIdentifier = "browser.spaces.close"
        // The circle sits at the button's leading edge, 31 points in from the sheet's.
        close.contentHorizontalAlignment = .leading
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 40), close.heightAnchor.constraint(equalToConstant: 36),
        ])
        close.addAction(
            UIAction { [weak controller] _ in controller?.dismiss(animated: true) },
            for: .primaryActionTriggered,
        )
        let closeItem = UIBarButtonItem(customView: close)
        closeItem.hidesSharedBackground = true
        controller.navigationItem.rightBarButtonItem = closeItem
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.preferredCornerRadius = 40
        navigation.view.backgroundColor = BrowserMobileTabsViewController.phoneSheetColor
        presentedTabs = controller
        present(navigation, animated: true)
    }

    private func showSettings(opensExtensions: Bool = false) {
        guard presentedViewController == nil else { return }
        let controller = BrowserMobilePhoneSettingsViewController(workspace: workspace)
        controller.didRestoreFromArchive = { [weak self] in
            guard let self, let id = workspace.selectedTabID else { return }
            refreshSwitcherEntries()
            closeSwitcher(opening: id)
        }
        // A store link opens its tab over the switcher Settings came from.
        controller.didOpenTab = controller.didRestoreFromArchive
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.sheetPresentationController?.preferredCornerRadius = 36
        if opensExtensions {
            controller.showExtensions(animated: false)
        }
        present(navigation, animated: true)
    }

    @objc private func stackHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, mode == .browsing else { return }
        bar.tabStack.cancelTracking(with: nil)
        showSpaces()
    }

    @objc private func findInPage() {
        guard mode == .browsing, workspace.canFindInPage else { return }
        workspace.presentFindInPage()
    }

    /// Translates the page in place, or puts its own text back.
    private func toggleTranslation() {
        guard let tab = workspace.selectedTab else { return }
        if tab.state.isTranslated || translationRun?.tabID == tab.id {
            translationRun = nil
            workspace.restoreOriginalText()
            return
        }
        let tabID = tab.id
        let url = tab.state.url
        let run = UUID()
        translationRun = (run, tabID)
        // Translations arrive one by one; they stop when the page changes or
        // the original comes back.
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self, translationRun?.id == run else { return false }
            guard workspace.tabs.first(where: { $0.id == tabID })?.state.url == url else {
                translationRun = nil
                return false
            }
            return true
        }
        workspace.pageText { [weak self] text in
            guard let self, isCurrent() else { return }
            guard let text else {
                translationRun = nil
                return
            }
            translator.translate(text) { [weak self] start, texts in
                guard isCurrent() else { return }
                self?.workspace.applyTranslatedText(tabID: tabID, start: start, texts: texts)
            } finish: { [weak self] error in
                guard let self, translationRun?.id == run else { return }
                translationRun = nil
                if let error {
                    showTranslationFailure(error)
                }
            }
        }
    }

    private func showTranslationFailure(_ error: Error) {
        let message: String =
            switch error as? BrowserMobilePageTranslator.Failure {
            case .sameLanguage(let language):
                String(localized: "This page is already in \(language).", table: "Mobile")
            case .unsupported:
                String(localized: "This page's language can't be translated on this device.", table: "Mobile")
            case nil:
                error.localizedDescription
            }
        // Closing the system's download sheet cancels; that needs no message.
        if (error as? CancellationError) != nil { return }
        let alert = UIAlertController(
            title: String(localized: "Couldn't Translate", table: "Mobile"), message: message, preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK", table: "Mobile"), style: .default))
        guard presentedViewController == nil else { return }
        present(alert, animated: true)
    }

    @objc private func editAddress() {
        guard mode == .browsing else { return }
        let url = workspace.selectedTab?.urlString
        openSearch(text: url == nil || url == "about:blank" ? "" : url!, replacesPage: true)
    }

    private func performPendingAppLink() {
        guard let link = pendingAppLink, workspace.isReady, view.window != nil else { return }
        pendingAppLink = nil
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        if link == .appIcon {
            if mode != .browsing { closePanel() }
            BrowserMobileAppIconViewController.present(from: self)
            return
        }
        if mode != .search {
            newTab()
        }
        if link == .voiceSearch {
            searchPanel.startDictation()
        }
    }

    @objc private func newTab() {
        if mode == .pageMenu { closePanel() }
        openSearch(text: "", replacesPage: false)
    }

    @objc private func closeCurrentTab() {
        guard mode == .browsing, let id = workspace.selectedTabID else { return }
        thumbnails.remove(id)
        workspace.closeTab(id: id)
    }

    @objc private func reload() { workspace.reload() }

    @objc private func escape() {
        switch mode {
        case .pageMenu,
             .search: closePanel()
        case .switcher:
            if let id = workspace.selectedTabID { closeSwitcher(opening: id) }
        case .browsing: workspace.dismissFindInPage()
        }
    }

    /// Search is open only with its field focused: a field that could not
    /// take focus while the app was starting or away takes it now.
    @objc private func sceneBecameActive(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === view.window?.windowScene,
              mode == .search, surface != nil, searchPanel.isFieldExpanded, presentedViewController == nil,
              !searchPanel.field.isFirstResponder else { return }
        searchPanel.field.becomeFirstResponder()
    }

    @objc private func sceneBecameInactive(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === view.window?.windowScene else { return }
        workspace.dismissFindInPage()
        if let id = workspace.selectedTabID, mode == .browsing {
            thumbnails.capture(id, workspace: workspace, width: thumbnailWidth)
        }
    }

    private func showDownloads() {
        guard let downloads = workspace.downloads, presentedViewController == nil else { return }
        let controller = BrowserMobileDownloadsViewController(downloads: downloads)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func sharePage() {
        guard let url = shareURL else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = bar.moreButton
        controller.popoverPresentationController?.sourceRect = bar.moreButton.bounds
        present(controller, animated: true)
    }
}

// MARK: UIGestureRecognizerDelegate

extension BrowserMobilePhoneViewController: UIGestureRecognizerDelegate {
    /// A drag from the bar to another tab. Sideways, the page turns into a
    /// card in a row with its neighbor, right to the previous tab out of the
    /// tab stack, left to the next one from the side; up from the tab stack,
    /// it pulls the previous tab out of the stack while the page shrinks
    /// into a card. Each picture rides in a card that clips and rounds it.
    fileprivate struct EdgeClosedTab {
        let archiveID: String
        /// The tab that showed once it closed.
        let revealedID: String
    }

    @MainActor fileprivate final class BarSwipe {
        enum Kind {
            case sideways
            case up
        }

        /// What a swipe in from the screen's edge does as it lands, on a page
        /// with no history that way.
        enum EdgeAction {
            case close
            case reopen(EdgeClosedTab)
        }

        struct PulledCard {
            var center: CGPoint
            var scale: CGFloat
            var contentHeight: CGFloat
            var angle: CGFloat
            var radius: CGFloat
        }

        let kind: Kind
        let fromID: String
        let toID: String?
        /// 1 when the row moves right, to the previous tab; -1 left, to the next.
        let direction: CGFloat
        let incoming: UIView
        let incomingCard: UIView
        let outgoing: UIView
        let outgoingCard: UIView
        let backdrop: UIView
        var edgeAction: EdgeAction?
        /// The page has turned into a card in the row.
        var isRow = false
        /// The finger has let go and the cards are on their way.
        var isSettling = false
        /// Where the finger is, and where it first touched.
        var finger = CGPoint.zero
        var fingerStart: CGPoint?
        /// The pulled-out card of an up swipe: where it heads and where it
        /// is, trailing the finger.
        var pullTarget: PulledCard?
        var pullNow: PulledCard?
        var pullLink: CADisplayLink?
        var pullLastTime: CFTimeInterval = 0

        init(
            kind: Kind, fromID: String, toID: String?, direction: CGFloat,
            incoming: UIView, outgoing: UIView, backdrop: UIView,
        ) {
            self.kind = kind
            self.fromID = fromID
            self.toID = toID
            self.direction = direction
            self.incoming = incoming
            self.outgoing = outgoing
            self.backdrop = backdrop
            self.incomingCard = Self.card(holding: incoming)
            self.outgoingCard = Self.card(holding: outgoing)
        }

        private static func card(holding picture: UIView) -> UIView {
            let card = UIView(frame: picture.frame)
            card.clipsToBounds = true
            card.layer.cornerCurve = .continuous
            picture.frame.origin = .zero
            card.addSubview(picture)
            return card
        }
    }

    /// How far a sideways drag moves the page before it turns into a card.
    private static let rowThreshold: CGFloat = 52
    /// How far a swipe from the screen's edge goes before the page snaps
    /// into the row, and the share of it the page follows before that.
    private static let edgeRowThreshold: CGFloat = 76
    private static let edgeResistance: CGFloat = 0.11
    /// The row's cards: their top on the screen, their bottom's distance
    /// above the bar, the room between them and their corner radius.
    private static let rowCardTop: CGFloat = 62
    private static let rowCardBottomGap: CGFloat = 20
    private static let rowCardGap: CGFloat = 30
    private static let rowCardRadius: CGFloat = 34

    /// How far up the finger goes for the page to reach its smallest card.
    private static let upSwipeTravel: CGFloat = 380
    /// The page's card in an up swipe: its left edge and its bottom's
    /// distance above the bar.
    private static let pullCardLeft: CGFloat = 24
    private static let pullCardBottomGap: CGFloat = 23
    /// The pulled card at its full size, as a share of the screen's width;
    /// the point of it the finger holds; how long it takes to catch up.
    private static let pullCardScale: CGFloat = 0.4
    private static let pullGrip = CGPoint(x: 0.65, y: 0.28)
    private static let pullLag: CFTimeInterval = 0.12

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if let edgePan = gesture as? UIScreenEdgePanGestureRecognizer {
            return edgeAction(for: edgePan.edges) != nil
        }
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        if pan === surfacePan {
            guard mode == .search || mode == .pageMenu, abs(velocity.y) > abs(velocity.x) else { return false }
            return mode == .pageMenu
                || searchPanel.dragMovesPanel(at: pan.location(in: searchPanel), downward: velocity.y > 0)
        }
        // The bar: sideways for tabs, up for search or the previous tab.
        guard mode == .browsing, swipe == nil, surface == nil else { return false }
        return abs(velocity.x) > abs(velocity.y) || velocity.y < 0
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer,
    ) -> Bool {
        // The suggestions scroll only when a drag does not move the panel;
        // their other gestures, such as a row's menu, do not wait for it.
        // A page scrolls only once a swipe from the screen's edge fails.
        (gesture === surfacePan || gesture is UIScreenEdgePanGestureRecognizer && gesture.view === view)
            && other === (other.view as? UIScrollView)?.panGestureRecognizer
    }

    private func configureBarSwipe() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(barSwiped(_:)))
        pan.delegate = self
        bar.addGestureRecognizer(pan)
        for edges in [UIRectEdge.left, .right] {
            let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
            edgePan.edges = edges
            edgePan.delegate = self
            view.addGestureRecognizer(edgePan)
        }
    }

    /// With no page to go back to, a swipe in from the left edge closes the
    /// tab as it moves to the previous one; with none to go forward to, one
    /// from the right brings back the tab it closed, the same way reversed.
    private func edgeAction(for edges: UIRectEdge) -> BarSwipe.EdgeAction? {
        guard mode == .browsing, swipe == nil, surface == nil, let tab = workspace.selectedTab else { return nil }
        if edges == .left {
            let tabs = workspace.switcherTabs
            guard !tab.state.canGoBack, let index = tabs.firstIndex(where: { $0.id == tab.id }), index > 0
            else { return nil }
            return .close
        }
        guard !tab.state.canGoForward, workspace.canRestoreArchivedTab, let closed = edgeClosedTabs.last,
              closed.revealedID == tab.id
        else { return nil }
        return .reopen(closed)
    }

    @objc private func edgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let action = edgeAction(for: gesture.edges) else { return }
            rowSnapHaptic.prepare()
            beginTabSwipe(.sideways, toPrevious: gesture.edges == .left, edge: action)
        case .changed:
            if let swipe {
                // The finger's distance from the edge, not from where the
                // recognizer began, sets how far the swipe has gone.
                let x = gesture.location(in: view).x
                let travel = gesture.edges == .left ? x : x - view.bounds.width
                updateSwipe(progress: swipeProgress(swipe, translation: CGPoint(x: travel, y: 0)))
            }
        case .cancelled, .ended, .failed:
            if swipe?.edgeAction != nil {
                endTabSwipe(gesture)
            }
        default: break
        }
    }

    @objc private func barSwiped(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let velocity = gesture.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) {
                rowSnapHaptic.prepare()
                beginTabSwipe(.sideways, toPrevious: velocity.x > 0)
            } else if bar.tabStack.frame.insetBy(dx: -8, dy: -8).contains(gesture.location(in: bar)),
                      !bar.isCollapsed
            {
                beginTabSwipe(.up, toPrevious: true)
                let location = gesture.location(in: view)
                let translation = gesture.translation(in: view)
                swipe?.finger = location
                swipe?.fingerStart = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            } else if beginSearch(text: "", replacesPage: false, followsFinger: true), let surface {
                surfaceDragStartTop = surface.frame.minY
            }
        case .changed:
            let translation = gesture.translation(in: view)
            if let swipe {
                swipe.finger = gesture.location(in: view)
                updateSwipe(progress: swipeProgress(swipe, translation: translation))
            } else if mode == .search, let surface, surfacePan != nil {
                dragSearchUp(surface, by: translation.y)
            }
        case .cancelled, .ended, .failed:
            if swipe != nil {
                endTabSwipe(gesture)
            } else if mode == .search, let surface, searchPanel.isFieldExpanded == false {
                let travel = surfaceDragStartTop - surface.frame.minY
                if gesture.state == .ended, travel > 50 || gesture.velocity(in: view).y < -400 {
                    finishOpeningSearch()
                } else {
                    closePanel()
                }
            }
        default: break
        }
    }

    /// The search panel follows the finger up out of the bar, its field still
    /// the New Tab capsule.
    private func dragSearchUp(_ surface: UIView, by translation: CGFloat) {
        let top = searchPanelTop(keyboardTop: searchKeyboardTop)
        let lift = max(-translation, 0)
        let reach = surfaceDragStartTop - top
        // Past where the panel settles it gives only a little.
        let travel = lift <= reach ? lift : reach + rubberBand(lift - reach, limit: 40)
        let y = surfaceDragStartTop - travel
        surface.frame = CGRect(x: 0, y: y, width: view.bounds.width, height: view.bounds.height - y)
        let progress = min(travel / max(reach, 1), 1)
        surface.layer.cornerRadius = 36 * min(progress * 3, 1)
        setSurfaceTint(1 - min(progress * 2, 1), interactive: true)
        // The page recedes into its card as the panel comes up.
        applyPageCard(searchCardFrame(panelTop: y))
        // The page menu button goes within the first points, the tab stack
        // over a longer way.
        for (ghost, fadeDistance) in zip(surfaceGhosts, [CGFloat(100), 20]) {
            ghost.alpha = 1 - min(travel / fadeDistance, 1)
        }
    }

    private func addSurfacePan(to surface: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(surfaceDragged(_:)))
        pan.delegate = self
        surface.addGestureRecognizer(pan)
        surfacePan = pan
    }

    /// Drags an open panel: down follows the finger (and lets the page grow
    /// back from its search card), up gives only a little.
    @objc private func surfaceDragged(_ gesture: UIPanGestureRecognizer) {
        guard mode == .search || mode == .pageMenu, let surface else { return }
        let isSearch = mode == .search
        let card = searchCardFrame()
        switch gesture.state {
        case .began:
            surfaceDragStartTop = surface.frame.minY
            surfaceDragTurn = 0
            surfaceDragGoesUp = false
        case .changed:
            let dy = gesture.translation(in: view).y
            // A few points of jitter are not a turn.
            if surfaceDragGoesUp ? dy > surfaceDragTurn + 6 : dy < surfaceDragTurn - 6 {
                surfaceDragGoesUp.toggle()
            }
            surfaceDragTurn = surfaceDragGoesUp ? min(surfaceDragTurn, dy) : max(surfaceDragTurn, dy)
            let y = dy >= 0
                ? surfaceDragStartTop + dy
                : surfaceDragStartTop - liftResistance(-dy, from: surfaceDragStartTop)
            surface.frame = CGRect(x: 0, y: y, width: view.bounds.width, height: view.bounds.height - y)
            if isSearch {
                fitSearchPanel(top: y)
                applyPageCard(searchCardFrame(panelTop: y))
            }
        case .cancelled, .ended, .failed:
            let dy = gesture.translation(in: view).y
            let velocity = gesture.velocity(in: view).y
            if gesture.state == .ended, velocity > 500 || dy > 80 && !surfaceDragGoesUp && velocity > -100 {
                closePanel(velocity: velocity)
                return
            }
            let top = surfaceDragStartTop
            let height = searchPanel.frame.height
            UIView.animate(springDuration: 0.32, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
                .allowUserInteraction, .beginFromCurrentState,
            ]) {
                surface.frame = CGRect(
                    x: 0,
                    y: top,
                    width: self.view.bounds.width,
                    height: self.view.bounds.height - top,
                )
                if isSearch {
                    self.fitSearchPanel(top: top)
                    self.holdSearchPanelHeight(height)
                    self.applyPageCard(card)
                }
            } completion: { _ in
                if isSearch {
                    self.fitSearchPanelAfterHold()
                }
            }
        default: break
        }
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress,
        )
    }

    private func beginTabSwipe(_ kind: BarSwipe.Kind, toPrevious: Bool, edge: BarSwipe.EdgeAction? = nil) {
        guard mode == .browsing, swipe == nil, let current = workspace.selectedTabID else { return }
        let tabs = workspace.switcherTabs
        let index = tabs.firstIndex { $0.id == current }
        // Right and up go back in time, left forward; past either end the
        // page only rubber-bands. The tab coming back is its archived picture.
        let target: String? =
            if case .reopen(let closed)? = edge {
                closed.archiveID
            } else {
                index.flatMap { index in
                    let next = toPrevious ? index - 1 : index + 1
                    return tabs.indices.contains(next) ? tabs[next].id : nil
                }
            }
        thumbnails.capture(current, workspace: workspace, width: thumbnailWidth)
        // The app's backdrop shows behind the cards.
        let backdrop = BrowserMobileAppBackdrop(frame: view.bounds)
        view.insertSubview(backdrop, belowSubview: pageContainer)
        let outgoing = pageContainer.snapshotView(afterScreenUpdates: false) ?? UIView()
        outgoing.frame = view.bounds
        let incoming = target.flatMap { pagePicture(for: $0) } ?? UIView(frame: view.bounds)
        incoming.backgroundColor = incoming.backgroundColor ?? .white
        let swipe = BarSwipe(
            kind: kind, fromID: current, toID: target, direction: toPrevious ? 1 : -1,
            incoming: incoming, outgoing: outgoing, backdrop: backdrop,
        )
        swipe.edgeAction = edge
        swipe.incomingCard.isHidden = target == nil
        view.insertSubview(swipe.incomingCard, belowSubview: bar)
        view.insertSubview(swipe.outgoingCard, belowSubview: bar)
        if kind == .up, target != nil {
            // The stack's front card itself comes out, over the page and the bar.
            view.insertSubview(swipe.incomingCard, aboveSubview: bar)
            bar.tabStack.front.isHidden = true
        }
        pageContainer.isHidden = true
        self.swipe = swipe
        if kind == .sideways {
            placeIncomingAtItsSource(swipe)
        }
        updateSwipe(progress: 0)
    }

    private func swipeProgress(_ swipe: BarSwipe, translation: CGPoint) -> CGFloat {
        let width = view.bounds.width
        switch swipe.kind {
        case .sideways:
            // Toward the other tab the page follows the finger; without one,
            // or back past where it started, it only gives a little.
            let along = translation.x * swipe.direction
            let travel = swipe.toID == nil || along < 0
                ? (along < 0 ? -rubberBand(-along, limit: width * 0.12) : rubberBand(along, limit: width * 0.12))
                : along
            return travel * swipe.direction / width
        case .up:
            let lift = max(-translation.y, 0)
            let travel = Self.upSwipeTravel
            return lift <= travel ? lift / travel : 1 + rubberBand(lift - travel, limit: 60) / travel
        }
    }

    private func endTabSwipe(_ gesture: UIPanGestureRecognizer) {
        guard let swipe else { return }
        let width = view.bounds.width
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let completes: Bool =
            switch swipe.kind {
            // From the edge, the row lands unless the finger flicks back; the
            // page held back lands only on a fast flick.
            case .sideways where swipe.edgeAction != nil:
                gesture.state == .ended && swipe.toID != nil
                    && (swipe.isRow ? velocity.x * swipe.direction > -300 : velocity.x * swipe.direction > 800)
            case .sideways:
                gesture.state == .ended && swipe.toID != nil
                    && translation.x * swipe.direction > 0
                    && (translation.x * swipe.direction > width * 0.3 || velocity.x * swipe.direction > 400)
            case .up:
                // Any real lift lands on the previous tab unless the finger
                // heads back down.
                gesture.state == .ended && swipe.toID != nil
                    && -translation.y > 40 && velocity.y < 300
            }
        swipe.isSettling = true
        swipe.pullLink?.invalidate()
        swipe.pullLink = nil
        let landedID = completes ? land(swipe) : nil
        if let landedID {
            matchBackdrop(toPictureOf: landedID)
            updateStatusBand()
        }
        UIView.animate(withDuration: 0.2) { self.setNeedsStatusBarAppearanceUpdate() }
        UIView.animate(
            springDuration: swipe.kind == .sideways ? 0.32 : 0.3,
            bounce: completes ? 0 : 0.15,
            initialSpringVelocity: 0,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
        ) {
            if completes {
                self.landSwipe(swipe)
            } else if swipe.kind == .sideways {
                self.cancelSidewaysSwipe(swipe)
            } else {
                self.updateSwipe(progress: 0)
            }
        } completion: { _ in
            swipe.outgoingCard.removeFromSuperview()
            swipe.backdrop.removeFromSuperview()
            self.bar.tabStack.front.isHidden = false
            self.bar.tabStack.back.isHidden = false
            self.pageContainer.isHidden = false
            // The picture keeps covering the page before the swipe lets go of it.
            if let landedID {
                self.coverWhileLoading(landedID, with: swipe.incomingCard)
            } else {
                swipe.incomingCard.removeFromSuperview()
            }
            if self.swipe === swipe { self.swipe = nil }
            self.render()
        }
    }

    /// Selects the tab a finished swipe lands on and returns it: closing the
    /// page's tab or bringing back a closed one for a swipe from the edge.
    private func land(_ swipe: BarSwipe) -> String? {
        guard let toID = swipe.toID else { return nil }
        switch swipe.edgeAction {
        case .close:
            workspace.selectTabInPlace(id: toID)
            if let archiveID = workspace.closeTab(id: swipe.fromID) {
                if let image = thumbnails.image(for: swipe.fromID) {
                    thumbnails.store(image, for: archiveID, persist: false)
                }
                edgeClosedTabs.append(EdgeClosedTab(archiveID: archiveID, revealedID: toID))
            }
            return toID
        case .reopen(let closed):
            edgeClosedTabs.removeAll { $0.archiveID == closed.archiveID }
            guard let restoredID = workspace.restoreArchivedTab(id: closed.archiveID) else { return nil }
            if let image = thumbnails.image(for: closed.archiveID) {
                thumbnails.store(image, for: restoredID)
            }
            return restoredID
        case nil:
            // A swipe moves along the row without reordering it.
            if swipe.kind == .sideways {
                workspace.selectTabInPlace(id: toID)
            } else {
                workspace.selectTab(id: toID)
            }
            return toID
        }
    }

    /// Keeps `cover` over the page until the tab finishes loading, at most a
    /// few seconds; a tab that is already loaded drops it at once.
    private func coverWhileLoading(_ tabID: String, with cover: UIView) {
        removeLoadingCover(animated: false)
        guard workspace.selectedTabID == tabID, workspace.selectedTab?.state.isLoading == true else {
            cover.removeFromSuperview()
            return
        }
        cover.transform = .identity
        cover.frame = view.bounds
        cover.layer.cornerRadius = 0
        cover.isUserInteractionEnabled = false
        view.insertSubview(cover, aboveSubview: pageContainer)
        loadingCover = (cover, tabID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak cover] in
            guard let self, let cover, loadingCover?.view === cover else { return }
            removeLoadingCover()
        }
    }

    private func removeLoadingCover(animated: Bool = true) {
        guard let cover = loadingCover?.view else { return }
        loadingCover = nil
        updateStatusBand()
        guard animated else {
            cover.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.15) {
            cover.alpha = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    /// Takes the tab's picture unless its page is shrunk into a card (or
    /// still growing back from one), where WebKit draws it without the
    /// status bar's band.
    private func capturePageIfFullScreen(_ tabID: String) {
        let layer = pageContainer.layer.presentation() ?? pageContainer.layer
        guard pageContainer.transform.isIdentity, layer.affineTransform().isIdentity else { return }
        thumbnails.capture(tabID, workspace: workspace, width: thumbnailWidth)
    }

    /// The tab's last picture as the screen shows its page, from the top of
    /// the screen, on the page's color where the picture has none.
    private func pagePicture(for tabID: String) -> UIView? {
        guard let image = thumbnails.image(for: tabID), image.size.width > 0 else { return nil }
        let bounds = view.bounds
        let state = workspace.tabs.first { $0.id == tabID }?.state
        let cover = UIView(frame: bounds)
        cover.backgroundColor = state?.themeColor ?? state?.backgroundColor
            ?? (isPictureTopDark(tabID) == true ? .black : .white)
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleToFill
        picture.frame = CGRect(
            x: 0, y: 0, width: bounds.width, height: bounds.width * image.size.height / image.size.width,
        )
        cover.addSubview(picture)
        return cover
    }

    /// How far an open panel at `top` rises for a finger that lifts it `value`
    /// points past its place: a scroll view's rubber band over most of the
    /// screen, about half the finger's way at first and harder with each
    /// point after that, and never past the safe area's top.
    private func liftResistance(_ value: CGFloat, from top: CGFloat) -> CGFloat {
        let reach = top - view.safeAreaInsets.top
        guard value > 0, reach > 0 else { return 0 }
        return min(rubberBand(value, limit: view.bounds.height * 0.8), reach)
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard value > 0 else { return value }
        return limit * (1 - 1 / (value / limit * 0.55 + 1))
    }

    /// Lays out both pages for a swipe that is `progress` of the way done.
    private func updateSwipe(progress: CGFloat) {
        guard let swipe else { return }
        switch swipe.kind {
        case .sideways: layoutSidewaysSwipe(swipe, progress: progress)
        case .up: layoutUpSwipe(swipe, progress: progress)
        }
    }

    /// Lays out `card` at `center` showing the part `content` of its
    /// picture, `scale` times its size, its corners rounded `radius` on the screen.
    private func place(
        _ card: UIView, content: CGRect, center: CGPoint, scale: CGFloat, angle: CGFloat = 0, radius: CGFloat,
    ) {
        card.bounds = content
        card.center = center
        card.transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
        card.layer.cornerRadius = radius / max(scale, 0.05)
    }

    /// The part of a page a card in the row shows: all of it below the
    /// status bar.
    private var rowCardContent: CGRect {
        let top = view.safeAreaInsets.top
        return CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
    }

    private var rowCardScale: CGFloat {
        let bottom = expandedBarFrame.minY - Self.rowCardBottomGap
        return (bottom - Self.rowCardTop) / max(rowCardContent.height, 1)
    }

    /// Where the other tab's card waits before the row shows it: the
    /// previous tab in the tab stack, the next one past the side.
    private func placeIncomingAtItsSource(_ swipe: BarSwipe) {
        let bounds = view.bounds
        let card = swipe.incomingCard
        let content = rowCardContent
        if swipe.direction > 0 {
            let stack = bar.convert(bar.tabStack.center, to: view)
            let scale = BrowserMobileTabStackButton.cardSize.width / bounds.width
            place(
                card, content: content, center: stack, scale: scale, angle: BrowserMobileTabStackButton.frontAngle,
                radius: 4,
            )
            card.alpha = 0
        } else {
            let scale = rowCardScale
            place(
                card, content: content,
                center: CGPoint(x: bounds.maxX + content.width * scale / 2 + Self.rowCardGap, y: rowCardCenterY),
                scale: scale, radius: Self.rowCardRadius,
            )
            card.alpha = 1
        }
    }

    private var rowCardCenterY: CGFloat {
        (Self.rowCardTop + expandedBarFrame.minY - Self.rowCardBottomGap) / 2
    }

    /// Toward another tab the page holds until the finger is past a
    /// threshold: there it snaps, with a tap, into a card in a row with that
    /// tab's card, which the row then carries along with the finger; back
    /// short of the threshold it snaps back the same way. Along the bar the
    /// page follows the finger at full size, its corners rounding; from the
    /// screen's edge it gives only a little.
    private func layoutSidewaysSwipe(_ swipe: BarSwipe, progress: CGFloat) {
        let bounds = view.bounds
        let travel = progress * bounds.width
        let along = travel * swipe.direction
        let fromEdge = swipe.edgeAction != nil
        let threshold = fromEdge ? Self.edgeRowThreshold : Self.rowThreshold
        let isRow = swipe.toID != nil && along >= threshold
        let layout = {
            if isRow {
                self.layoutRow(swipe, travel: travel)
                return
            }
            let shift = fromEdge ? max(along, 0) * Self.edgeResistance * swipe.direction : travel
            let rounding = fromEdge ? max(along, 0) / 20 : abs(travel) / threshold
            self.place(
                swipe.outgoingCard, content: bounds, center: CGPoint(x: bounds.midX + shift, y: bounds.midY),
                scale: 1, radius: Self.rowCardRadius * min(rounding, 1),
            )
        }
        guard isRow != swipe.isRow else {
            layout()
            return
        }
        swipe.isRow = isRow
        rowSnapHaptic.impactOccurred()
        UIView.animate(withDuration: 0.2) { self.setNeedsStatusBarAppearanceUpdate() }
        swipe.incomingCard.alpha = 1
        UIView.animate(
            springDuration: fromEdge ? 0.25 : 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
        ) {
            layout()
            if !isRow {
                self.placeIncomingAtItsSource(swipe)
            }
        }
    }

    /// The page's card and the other tab's beside it, the row moved by
    /// `travel`: along the bar the card's near side stays where the page's
    /// was, from the edge it trails the finger a little.
    private func layoutRow(_ swipe: BarSwipe, travel: CGFloat) {
        let scale = rowCardScale
        let content = rowCardContent
        let bounds = view.bounds
        let trail: CGFloat = swipe.edgeAction != nil ? 10 : 0
        let center = CGPoint(
            x: bounds.midX + travel - swipe.direction * ((bounds.width - content.width * scale) / 2 + trail),
            y: rowCardCenterY,
        )
        place(swipe.outgoingCard, content: content, center: center, scale: scale, radius: Self.rowCardRadius)
        let step = content.width * scale + Self.rowCardGap
        place(
            swipe.incomingCard, content: content, center: CGPoint(x: center.x - swipe.direction * step, y: center.y),
            scale: scale, radius: Self.rowCardRadius,
        )
    }

    /// The page grows back to the screen while the other tab's card goes
    /// back where it came from.
    private func cancelSidewaysSwipe(_ swipe: BarSwipe) {
        let bounds = view.bounds
        place(
            swipe.outgoingCard, content: bounds, center: CGPoint(x: bounds.midX, y: bounds.midY), scale: 1,
            radius: 0,
        )
        if swipe.toID != nil {
            placeIncomingAtItsSource(swipe)
        }
    }

    /// The other tab's card grows to fill the screen. Going back, the row
    /// carries the page's card off to the right; otherwise it drops into the
    /// tab stack where the tab now sits, over the bar.
    private func landSwipe(_ swipe: BarSwipe) {
        let bounds = view.bounds
        let intoStack = swipe.kind == .up || swipe.direction < 0
        if intoStack {
            // The page's card drops over the bar, which stays over the tab
            // coming in.
            view.insertSubview(swipe.outgoingCard, aboveSubview: bar)
            view.insertSubview(swipe.incomingCard, belowSubview: bar)
        } else {
            view.insertSubview(swipe.incomingCard, aboveSubview: swipe.outgoingCard)
        }
        swipe.incomingCard.alpha = 1
        place(
            swipe.incomingCard, content: bounds, center: CGPoint(x: bounds.midX, y: bounds.midY), scale: 1,
            radius: 0,
        )
        guard intoStack else {
            let scale = rowCardScale
            let content = rowCardContent
            place(
                swipe.outgoingCard, content: content,
                center: CGPoint(x: bounds.midX + content.width * scale + Self.rowCardGap, y: rowCardCenterY),
                scale: scale, radius: Self.rowCardRadius,
            )
            return
        }
        let others = workspace.switcherTabs.filter { $0.id != workspace.selectedTabID }.map(\.id)
        let isBack = others.last != swipe.fromID && others.dropLast().last == swipe.fromID
        let stackCard = isBack ? bar.tabStack.back : bar.tabStack.front
        let lands = others.suffix(2).contains(swipe.fromID)
        // The stack shows the tab already; its card waits for this one to land.
        stackCard.isHidden = lands
        let card = BrowserMobileTabStackButton.cardSize
        place(
            swipe.outgoingCard,
            content: CGRect(
                x: 0, y: view.safeAreaInsets.top, width: bounds.width, height: bounds.width * card.height / card.width,
            ),
            center: bar.tabStack.convert(stackCard.center, to: view), scale: card.width / bounds.width,
            angle: isBack ? BrowserMobileTabStackButton.backAngle : BrowserMobileTabStackButton.frontAngle, radius: 4,
        )
        if !lands {
            swipe.outgoingCard.alpha = 0
        }
    }

    /// The page shrinks into a card that rests on the bar, its left edge in
    /// from the screen's, while the stack's front card, the previous tab,
    /// comes out over it and trails the finger.
    private func layoutUpSwipe(_ swipe: BarSwipe, progress: CGFloat) {
        let bounds = view.bounds
        let p = max(progress, 0)
        let early = min(1, p * 2)
        let scale = 1 - 0.29 * p
        let top = view.safeAreaInsets.top * early
        let content = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        let bottom = bounds.height - (bounds.height - expandedBarFrame.minY + Self.pullCardBottomGap) * early
        let left = Self.pullCardLeft * early
        place(
            swipe.outgoingCard, content: content,
            center: CGPoint(
                x: left + content.width * scale / 2,
                y: bottom - content.height * scale / 2,
            ),
            scale: scale, radius: Self.rowCardRadius * min(p * 4, 1),
        )
        guard swipe.toID != nil else { return }
        let target = pulledCard(for: swipe, progress: swipe.isSettling ? 0 : min(p, 1))
        swipe.pullTarget = target
        if swipe.isSettling || swipe.pullNow == nil {
            swipe.pullNow = target
            placePulledCard(swipe)
        } else if swipe.pullLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepPulledCard(_:)))
            link.add(to: .main, forMode: .common)
            swipe.pullLink = link
            swipe.pullLastTime = CACurrentMediaTime()
        }
    }

    /// Where the pulled card heads for `q` of the way up: from the stack's
    /// front card to a card held by the finger near its upper right.
    private func pulledCard(for swipe: BarSwipe, progress q: CGFloat) -> BarSwipe.PulledCard {
        let width = view.bounds.width
        let rowHeight = rowCardContent.height
        let stackCard = BrowserMobileTabStackButton.cardSize
        let front = bar.tabStack.convert(bar.tabStack.front.center, to: view)
        let scale = stackCard.width / width + (Self.pullCardScale - stackCard.width / width) * q
        // A stack card shows the top of the page; the pulled one grows to all of it.
        let stackHeight = width * stackCard.height / stackCard.width
        let contentHeight = stackHeight + (rowHeight - stackHeight) * min(1, q * 1.5)
        let start = swipe.fingerStart ?? front
        let size = CGSize(width: width * scale, height: contentHeight * scale)
        let held = CGPoint(
            x: swipe.finger.x + (0.5 - Self.pullGrip.x) * size.width + (front.x - start.x) * (1 - q),
            y: swipe.finger.y + (0.5 - Self.pullGrip.y) * size.height + (front.y - start.y) * (1 - q),
        )
        return BarSwipe.PulledCard(
            center: q == 0 ? front : held, scale: scale, contentHeight: contentHeight,
            angle: BrowserMobileTabStackButton.frontAngle * (1 - q), radius: 4 + 12 * q,
        )
    }

    private func placePulledCard(_ swipe: BarSwipe) {
        guard let card = swipe.pullNow else { return }
        let top = view.safeAreaInsets.top
        place(
            swipe.incomingCard,
            content: CGRect(x: 0, y: top, width: view.bounds.width, height: card.contentHeight),
            center: card.center, scale: card.scale, angle: card.angle, radius: card.radius,
        )
        swipe.incomingCard.alpha = 1
    }

    /// Moves the pulled card a step toward where it heads, so it trails the finger.
    @objc private func stepPulledCard(_ link: CADisplayLink) {
        guard let swipe, swipe.pullLink === link, let target = swipe.pullTarget, var now = swipe.pullNow else {
            link.invalidate()
            return
        }
        let time = CACurrentMediaTime()
        let k = 1 - exp(-(time - swipe.pullLastTime) / Self.pullLag)
        swipe.pullLastTime = time
        func step(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        now.center = CGPoint(x: step(now.center.x, target.center.x), y: step(now.center.y, target.center.y))
        now.scale = step(now.scale, target.scale)
        now.contentHeight = step(now.contentHeight, target.contentHeight)
        now.angle = step(now.angle, target.angle)
        now.radius = step(now.radius, target.radius)
        swipe.pullNow = now
        placePulledCard(swipe)
    }
}

// MARK: - BrowserMobileKeyboardTracker

/// Stretches from the keyboard's top to the screen's bottom and says when that changes.
private final class BrowserMobileKeyboardTracker: UIView {
    var onResize: () -> Void = {}

    override func layoutSubviews() {
        super.layoutSubviews()
        onResize()
    }
}
