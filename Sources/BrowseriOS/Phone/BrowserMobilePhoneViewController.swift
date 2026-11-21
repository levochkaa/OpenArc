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

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if mode == .switcher || mode == .search || showsHome { return .lightContent }
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
    private var isStatusBandDark = false
    /// Darkens the page while it is the search panel's card.
    private let pageDim = UIView()
    private let bar = BrowserMobilePhoneBarView()
    /// Fills the screen while no page is open.
    private let appBackdrop = BrowserMobileAppBackdrop()
    private let homeLogo = BrowserMobileHomeLogo()
    /// No page is open: the backdrop shows, with Spaces and Settings in the bar.
    private var showsHome = false
    private var statusCorner: CGRect?
    private var appliedObscuredInsets: UIEdgeInsets?
    private let emptyState = UIStackView()
    private let emptyTitle = UILabel()
    private let emptyMessage = UILabel()
    private let emptyAction = UIButton(type: .system)
    private let thumbnails = BrowserMobileTabThumbnails.shared
    private let favicons = BrowserMobileFavicons.shared
    private var isBackdropSampleScheduled = false
    private var renderedTabID: String?
    private var wasLoading = [String: Bool]()
    private var didAutoOpenSearch = false
    private var shownOpenedLinkCount: Int
    private var iconRequests = Set<String>()

    // Bar collapse while scrolling.
    private var scrollObservation: NSKeyValueObservation?
    private var lastScrollY: CGFloat = 0
    private var scrollTravel: CGFloat = 0

    // Panels.
    private var surface: UIView?
    private var surfaceTint: UIView?
    private var dismissCatcher: UIView?
    /// Drags the open search panel down to close it.
    private weak var surfacePan: UIPanGestureRecognizer?
    private var surfaceGhosts = [UIView]()
    private var surfaceDragStartTop: CGFloat = 0
    private lazy var pagePanel = BrowserMobilePagePanel()
    private lazy var searchPanel = BrowserMobileSearchPanel()
    private var searchReplacesPage = false
    private var keyboardTop: CGFloat?

    // Switcher.
    private var switcher: BrowserMobileTabSwitcherView?
    private var isAnimatingSwitcher = false
    private weak var presentedTabs: BrowserMobileTabsViewController?

    /// Bar swipe between tabs.
    private var swipe: BarSwipe?
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
        view.addSubview(appBackdrop)
        homeLogo.isHidden = true
        view.addSubview(homeLogo)
        view.addSubview(pageContainer)
        pageContainer.addSubview(contentView)
        statusBand.isUserInteractionEnabled = false
        statusBand.backgroundColor = .white
        pageContainer.addSubview(statusBand)
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
        layoutPage()
        if surface == nil {
            layoutBar()
        }
        switcher?.frame = view.bounds
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
                thumbnails.capture(previous, workspace: workspace, width: thumbnailWidth)
            }
            renderedTabID = tab?.id
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

    /// The bar stays opaque; the page lays out above its full height even
    /// while it is collapsed, so fixed footers never jump. Beside a status
    /// corner block (iPhone Duo) the page keeps the system's side inset, which
    /// WebKit fills with the page's background.
    private func updateObscuredInsets() {
        let safe = view.safeAreaInsets
        let insets = UIEdgeInsets(top: safe.top, left: safe.left, bottom: expandedBarHeight, right: safe.right)
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
        setNeedsStatusBarAppearanceUpdate()
    }

    private func layoutPage() {
        guard pageContainer.transform.isIdentity else { return }
        pageContainer.frame = view.bounds
        contentView.frame = pageContainer.bounds
        statusBand.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.safeAreaInsets.top)
        pageDim.frame = pageContainer.bounds
        emptyState.frame = pageContainer.bounds.inset(by: UIEdgeInsets(
            top: view.safeAreaInsets.top, left: 24, bottom: expandedBarHeight, right: 24,
        ))
    }

    private func layoutBar() {
        bar.frame = barFrame
    }

    // MARK: Theme, icons, tab stack

    /// Turns the bar dark over a page whose background is dark. Before the
    /// page reports its background, a picture of the page under the bar
    /// decides.
    private func sampleBackdrop() {
        // Over the switcher the bar stays dark.
        guard mode != .switcher else { return }
        guard let tab = workspace.selectedTab, !contentView.isHidden else {
            setBackdropDark(false)
            return
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
        guard let color = state?.themeColor ?? state?.backgroundColor else { return }
        statusBand.backgroundColor = color
        let dark = BrowserMobileBackdrop.luminance(of: color).map(BrowserMobileBackdrop.isDark) ?? false
        guard dark != isStatusBandDark else { return }
        isStatusBandDark = dark
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Turns the bar to match a tab's background, or its last picture, before
    /// its page shows, so the color changes along with a switch instead of
    /// after it.
    private func matchBackdrop(toPictureOf tabID: String) {
        if let tab = workspace.tabs.first(where: { $0.id == tabID }), let dark = Self.isDark(tab.state) {
            setBackdropDark(dark)
            return
        }
        guard let image = thumbnails.image(for: tabID)?.cgImage, image.height > 0 else { return }
        let screenHeight = view.bounds.height * CGFloat(image.width) / view.bounds.width
        let barHeight = expandedBarHeight * CGFloat(image.width) / view.bounds.width
        let bottom = min(CGFloat(image.height), screenHeight)
        guard let strip = image.cropping(to: CGRect(
            x: 0, y: max(0, bottom - barHeight), width: CGFloat(image.width), height: barHeight,
        )), let luminance = BrowserMobileBackdrop.luminance(of: strip) else { return }
        setBackdropDark(BrowserMobileBackdrop.isDark(luminance: luminance))
    }

    private func setBackdropDark(_ dark: Bool) {
        guard bar.isDark != dark else { return }
        UIView.transition(with: bar, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.bar.isDark = dark
            (self.surface as? UIVisualEffectView)?.overrideUserInterfaceStyle = dark ? .dark : .light
        }
    }

    private func updateTabStack() {
        let ordered = workspace.switcherTabs.filter { $0.id != workspace.selectedTabID }
        let front = ordered.last
        let back = ordered.dropLast().last
        bar.tabStack.setImages(
            front: front.flatMap { thumbnails.image(for: $0.id) },
            back: back.flatMap { thumbnails.image(for: $0.id) },
        )
        bar.tabStack.accessibilityValue = String(workspace.switcherTabs.count)
    }

    private func requestIcons() {
        for tab in workspace.switcherTabs {
            // The shown page lists its own icons once it has loaded; other
            // tabs, which may have no page yet, get the site's /favicon.ico.
            let fromPage = tab.id == workspace.selectedTabID
            if fromPage, tab.state.isLoading || tab.state.progress < 1 { continue }
            guard favicons.needsIcon(forPage: tab.urlString, fromPage: fromPage),
                  let host = BrowserMobileFavicons.host(forPage: tab.urlString), iconRequests.insert(host).inserted
            else { continue }
            let page = tab.urlString
            let finish: @MainActor ([URL]) -> Void = { [weak self] urls in
                guard let self else { return }
                iconRequests.remove(host)
                let candidates = urls.isEmpty
                    ? BrowserMobileFavicons.rankedIconURLs([], pageURL: URL(string: page))
                    : urls
                favicons.load(forPage: page, candidates: candidates, fromPage: fromPage)
            }
            if fromPage {
                workspace.iconURLs(tabID: tab.id, completion: finish)
            } else {
                finish([])
            }
        }
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
    }

    private func updateEmptyState() {
        let tab = workspace.selectedTab
        let error = workspace.sessionError ?? tab?.state.error ?? workspace.navigationError
        let isBlank = tab == nil || tab?.urlString == "about:blank"
        let home = workspace.isReady && error == nil && isBlank
        emptyState.isHidden = home || workspace.isReady && error == nil && !isBlank
        contentView.isHidden = !workspace.isReady || tab?.state.error != nil || isBlank
        setShowsHome(home)
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
            emptyState.isHidden = false
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
            self.surfaceTint?.alpha = 0
            self.pagePanel.setAddressExpanded(true)
        }
        rise.isUserInteractionEnabled = true
        rise.startAnimation()
    }

    /// Puts a surface over the bar with the bar's frame and color, holding
    /// `content` laid out at `height`. Content that shows from the start
    /// (`revealsContent`) is not faded in.
    private func makeSurface(height: CGFloat, dark: Bool, content: UIView, revealsContent: Bool) -> UIView? {
        guard surface == nil else { return nil }
        setBarCollapsed(false, animated: false)
        layoutBar()
        let catcher = UIControl(frame: view.bounds)
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
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            blur.frame = surface.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            surface.addSubview(blur)
            // Leans the material toward the backdrop so it reads darker over light pages.
            let shade = UIView(frame: surface.bounds)
            shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shade.backgroundColor = view.backgroundColor?.withAlphaComponent(0.1)
            surface.addSubview(shade)
            // Starts the color of the bar it grows from.
            let tint = UIView(frame: surface.bounds)
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tint.backgroundColor = bar.isDark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.86, alpha: 1)
            surface.addSubview(tint)
            surfaceTint = tint
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
        let ghosts = surfaceGhosts
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            ghosts.forEach { $0.alpha = 0 }
        }
        return surface
    }

    /// Shrinks the open panel back into the bar.
    private func closePanel(completion: (() -> Void)? = nil) {
        guard let surface else {
            completion?()
            return
        }
        let closingMode = mode
        mode = .browsing
        if closingMode == .search {
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
        // Settles into the bar without dipping below its height.
        UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = self.expandedBarFrame
            surface.layer.cornerRadius = 0
            self.surfaceTint?.alpha = 1
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
        openPagePanel(height: pagePanel.contentHeight + safeBottom)
    }

    private func updatePagePanel() {
        let tab = workspace.selectedTab
        let isWebPage = shareURL != nil
        let document = workspace.profileDocument
        let isPinned = tab.map { $0.placement != .temporary } ?? false
        var tiles = [BrowserMobilePagePanel.Tile]()
        tiles.append(.init(
            title: String(localized: "Find on Page", table: "Mobile"), symbol: "doc.text.magnifyingglass",
            identifier: "browser.findInPage", isEnabled: isWebPage,
        ) { [weak self] in
            self?.closePanel { self?.findInPage() }
        })
        tiles.append(.init(
            title: isPinned ? String(localized: "Unpin", table: "Mobile") : String(localized: "Pin", table: "Mobile"),
            symbol: isPinned ? "pin.slash" : "pin", identifier: "browser.pin",
            isEnabled: document?.canEdit == true && tab?.spaceID != nil && isWebPage,
        ) { [weak self] in
            self?.togglePin()
        })
        tiles.append(.init(
            title: String(localized: "Downloads", table: "Mobile"), symbol: "arrow.down.circle",
            identifier: "browser.downloads", isEnabled: workspace.downloads != nil,
        ) { [weak self] in
            self?.closePanel { self?.showDownloads() }
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

    private func togglePin() {
        guard let document = workspace.profileDocument, let tab = workspace.selectedTab,
              let spaceID = tab.spaceID else { return }
        document.move(
            items: [BrowserSyncEntityReference(entityType: .tab, entityID: tab.id)],
            destination: .tabs(
                spaceID: spaceID, placement: tab.placement == .temporary ? .spacePinned : .temporary,
                pinnedFolderID: nil,
            ),
        )
        updatePagePanel()
    }

    private func showOpenedLink() {
        presentedViewController?.dismiss(animated: true)
        switch mode {
        case .browsing: break
        case .switcher: closeSwitcherInstantly()
        case .pageMenu, .search: closePanel()
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
    private func beginSearch(text: String, replacesPage: Bool) -> Bool {
        guard workspace.isReady else { return false }
        if mode == .switcher {
            closeSwitcherInstantly()
        }
        guard mode == .browsing else { return false }
        workspace.dismissFindInPage()
        mode = .search
        searchReplacesPage = replacesPage
        searchPanel.candidates = searchCandidates()
        searchPanel.onSubmit = { [weak self] text in self?.submitSearch(text) }
        searchPanel.onSelect = { [weak self] item in self?.selectSuggestion(item) }
        searchPanel.prepare(text: text)
        let top = searchPanelTop(keyboardTop: keyboardTop ?? view.bounds.height * 0.655)
        guard let surface = makeSurface(
            height: view.bounds.height - top, dark: true, content: searchPanel, revealsContent: true,
        ) else {
            mode = .browsing
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
        let top = searchPanelTop(keyboardTop: keyboardTop ?? view.bounds.height * 0.655)
        let card = searchCardFrame()
        UIView.animate(springDuration: 0.42, bounce: 0.12, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = CGRect(x: 0, y: top, width: self.view.bounds.width, height: self.view.bounds.height - top)
            surface.layer.cornerRadius = 36
            self.surfaceTint?.alpha = 0
            self.searchPanel.setFieldExpanded(true)
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

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let top = notification.name == UIResponder.keyboardWillHideNotification
            ? view.bounds.height
            : view.convert(frame, from: nil).minY
        keyboardTop = top < view.bounds.height ? top : nil
        bar.isHidden = workspace.isFindInPageVisible && mode == .browsing
        guard mode == .search, let surface, let keyboardTop else { return }
        let panelTop = searchPanelTop(keyboardTop: keyboardTop)
        UIView.animate(springDuration: 0.42, bounce: 0.1) {
            surface.frame = CGRect(
                x: 0, y: panelTop, width: self.view.bounds.width, height: self.view.bounds.height - panelTop,
            )
            self.searchPanel.frame = CGRect(
                x: 0, y: 0, width: self.view.bounds.width, height: keyboardTop - panelTop,
            )
        }
    }

    private func searchCandidates() -> [BrowserMobileSearchSuggestions.Candidate] {
        var result = workspace.switcherTabs.reversed().map { tab in
            BrowserMobileSearchSuggestions.Candidate(
                tabID: tab.id, title: tab.userTitleOverride ?? tab.title, urlString: tab.urlString,
                location: location(of: tab),
            )
        }
        let listed = Set(result.map(\.tabID))
        for tab in workspace.tabs where !listed.contains(tab.id) && tab.placement != .temporary {
            result.append(.init(
                tabID: tab.id, title: tab.userTitleOverride ?? tab.title, urlString: tab.urlString,
                location: location(of: tab),
            ))
        }
        return result.filter { $0.urlString != "about:blank" }
    }

    private func location(of tab: BrowserMobileTab) -> String? {
        let space = workspace.spaces.first { $0.id == tab.spaceID }?.title
        let place =
            switch tab.placement {
            case .app: String(localized: "Favorites", table: "Mobile")
            case .temporary: String(localized: "Tab", table: "Mobile")
            default: String(localized: "Pinned", table: "Mobile")
            }
        return space.map { String(localized: "\(place) in \($0)", table: "Mobile") } ?? place
    }

    private func submitSearch(_ text: String) {
        let replaces = searchReplacesPage
        closePanel()
        if replaces {
            workspace.submit(text)
        } else {
            workspace.submitInNewTab(text)
        }
    }

    private func selectSuggestion(_ item: BrowserMobileSearchSuggestions.Item) {
        switch item.kind {
        case .address(let address): submitSearch(address)
        case .search(let query): submitSearch(query)
        case .tab(let id):
            closePanel()
            if id != workspace.selectedTabID {
                if let current = workspace.selectedTabID {
                    thumbnails.capture(current, workspace: workspace, width: thumbnailWidth)
                }
                workspace.selectTab(id: id)
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
            .init(id: $0.id, title: $0.userTitleOverride ?? $0.title, urlString: $0.urlString)
        }
    }

    /// Shrinks the page into its card at the right while the other tabs fly
    /// out of the tab stack into the row, centered on the previous tab.
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
        setBackdropDark(true)

        let chrome = [switcher.backdrop]
        let background = switcher.backgroundColor
        switcher.backgroundColor = .clear
        for view in chrome {
            view.alpha = 0
        }
        switcher.subviews
            .filter { $0 is UIVisualEffectView || $0.backgroundColor != nil && !($0 is UIButton) }
            .forEach { $0.alpha = 0 }
        let stackCenter = bar.convert(bar.tabStack.center, to: view)
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
                let scale = BrowserMobileTabStackButton.cardSize.width / frame.width
                card.center = stackCenter
                card.bounds.size = frame.size
                card.transform = CGAffineTransform(rotationAngle: BrowserMobileTabStackButton.frontAngle)
                    .scaledBy(x: scale, y: scale)
                card.alpha = 0
            }
        }
        UIView.animate(withDuration: 0.15) {
            self.bar.setShowsSwitcherControls(true)
            for card in entries.compactMap({ switcher.card(for: $0.id) }) where card.alpha == 0 {
                card.alpha = 1
            }
        }
        UIView.animate(springDuration: 0.36, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction,
        ]) {
            for card in entries.compactMap({ switcher.card(for: $0.id) }) {
                card.transform = .identity
            }
            switcher.layoutCards()
            for card in entries.compactMap({ switcher.card(for: $0.id) }) {
                card.layoutIfNeeded()
            }
        } completion: { _ in
            self.isAnimatingSwitcher = false
            self.refreshSwitcherEntries()
        }
        UIView.animate(withDuration: 0.2) {
            switcher.backgroundColor = background
            for view in chrome {
                view.alpha = 1
            }
            switcher.subviews.filter { $0.alpha == 0 && !($0 is UIButton) }.forEach { $0.alpha = 1 }
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

    /// The chosen card grows to fill the screen, then the page takes its place.
    private func closeSwitcher(opening id: String) {
        guard let switcher, mode == .switcher, !isAnimatingSwitcher, let card = switcher.card(for: id) else { return }
        isAnimatingSwitcher = true
        if id != workspace.selectedTabID {
            workspace.selectTab(id: id)
        }
        matchBackdrop(toPictureOf: id)
        card.superview?.bringSubviewToFront(card)
        card.titleAlpha = 0
        let others = switcher.entries.compactMap { $0.id == id ? nil : switcher.card(for: $0.id) }
        UIView.animate(withDuration: 0.1) {
            for other in others {
                other.alpha = 0
            }
            self.bar.setShowsSwitcherControls(false)
        }
        UIView.animate(springDuration: 0.24, bounce: 0, initialSpringVelocity: 0, delay: 0, options: []) {
            card.bounds.size = self.view.bounds.size
            card.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            card.layoutIfNeeded()
        } completion: { _ in
            self.finishSwitcher()
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
        card.superview?.bringSubviewToFront(card)
        let stackCenter = bar.convert(bar.tabStack.center, to: view)
        let others = switcher.entries.compactMap { $0.id == id ? nil : switcher.card(for: $0.id) }
        UIView.animate(springDuration: 0.26, bounce: 0, initialSpringVelocity: 0, delay: 0, options: []) {
            card.titleAlpha = 0
            card.bounds.size = self.view.bounds.size
            card.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            card.layoutIfNeeded()
            for other in others {
                let scale = BrowserMobileTabStackButton.cardSize.width / max(other.bounds.width, 1)
                other.titleAlpha = 0
                other.center = stackCenter
                other.transform = CGAffineTransform(rotationAngle: BrowserMobileTabStackButton.frontAngle)
                    .scaledBy(x: scale, y: scale)
            }
        } completion: { _ in
            self.finishSwitcher()
        }
        UIView.animate(withDuration: 0.12, delay: 0.1) {
            for other in others {
                other.alpha = 0
            }
        }
        UIView.animate(withDuration: 0.15) {
            self.bar.setShowsSwitcherControls(false)
        }
    }

    private func finishSwitcher() {
        let id = workspace.selectedTabID
        // The page that was live before the switcher opened needs no cover.
        let picture = id.flatMap { switcher?.card(for: $0)?.livePicture == nil ? pagePicture(for: $0) : nil }
        switcher?.removeFromSuperview()
        switcher = nil
        isAnimatingSwitcher = false
        mode = .browsing
        bar.setShowsSwitcherControls(false)
        setNeedsStatusBarAppearanceUpdate()
        render()
        if let id, let picture {
            coverWhileLoading(id, with: picture)
        }
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
    /// A drag from the bar to another tab: sideways goes to the previous tab
    /// as on the system's home indicator, up from the tab stack pulls the
    /// previous tab out of the stack while the page shrinks into a card.
    fileprivate final class BarSwipe {
        enum Kind {
            case sideways
            case up
        }

        let kind: Kind
        let fromID: String
        let toID: String?
        let incoming: UIImageView
        let outgoing: UIView
        let backdrop: UIView

        init(kind: Kind, fromID: String, toID: String?, incoming: UIImageView, outgoing: UIView, backdrop: UIView) {
            self.kind = kind
            self.fromID = fromID
            self.toID = toID
            self.incoming = incoming
            self.outgoing = outgoing
            self.backdrop = backdrop
        }
    }

    /// How far up the finger goes for the page to reach its smallest card.
    private static let upSwipeTravel: CGFloat = 380

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
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
        // The suggestions scroll only when a drag does not move the panel.
        gesture === surfacePan && other.view is UIScrollView
    }

    private func configureBarSwipe() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(barSwiped(_:)))
        pan.delegate = self
        bar.addGestureRecognizer(pan)
    }

    @objc private func barSwiped(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let velocity = gesture.velocity(in: view)
            if abs(velocity.x) > abs(velocity.y) {
                beginTabSwipe(.sideways, toPrevious: velocity.x > 0)
            } else if bar.tabStack.frame.insetBy(dx: -8, dy: -8).contains(gesture.location(in: bar)),
                      !bar.isCollapsed
            {
                beginTabSwipe(.up, toPrevious: true)
            } else if beginSearch(text: "", replacesPage: false), let surface {
                surfaceDragStartTop = surface.frame.minY
            }
        case .changed:
            let translation = gesture.translation(in: view)
            if let swipe {
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
        let top = searchPanelTop(keyboardTop: keyboardTop ?? view.bounds.height * 0.655)
        let lift = max(-translation, 0)
        let reach = surfaceDragStartTop - top
        // Past where the panel settles it gives only a little.
        let travel = lift <= reach ? lift : reach + rubberBand(lift - reach, limit: 40)
        let y = surfaceDragStartTop - travel
        surface.frame = CGRect(x: 0, y: y, width: view.bounds.width, height: view.bounds.height - y)
        let progress = min(travel / max(reach, 1), 1)
        surface.layer.cornerRadius = 36 * min(progress * 3, 1)
        surfaceTint?.alpha = 1 - min(progress * 2, 1)
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
        let card = isSearch ? searchCardFrame() : view.bounds
        switch gesture.state {
        case .began:
            surfaceDragStartTop = surface.frame.minY
        case .changed:
            let dy = gesture.translation(in: view).y
            let y = dy >= 0 ? surfaceDragStartTop + dy : surfaceDragStartTop - rubberBand(-dy, limit: 30)
            surface.frame = CGRect(x: 0, y: y, width: view.bounds.width, height: view.bounds.height - y)
            if isSearch {
                let progress = max(dy, 0) / max(expandedBarFrame.minY - surfaceDragStartTop, 1)
                applyPageCard(interpolate(card, view.bounds, min(progress, 1)))
            }
        case .cancelled, .ended, .failed:
            let dy = gesture.translation(in: view).y
            if gesture.state == .ended, dy > 80 || gesture.velocity(in: view).y > 500 {
                closePanel()
                return
            }
            let top = surfaceDragStartTop
            UIView.animate(springDuration: 0.4, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
                .allowUserInteraction, .beginFromCurrentState,
            ]) {
                surface.frame = CGRect(
                    x: 0,
                    y: top,
                    width: self.view.bounds.width,
                    height: self.view.bounds.height - top,
                )
                if isSearch {
                    self.applyPageCard(card)
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

    private func beginTabSwipe(_ kind: BarSwipe.Kind, toPrevious: Bool) {
        guard mode == .browsing, swipe == nil, let current = workspace.selectedTabID else { return }
        let tabs = workspace.switcherTabs
        let index = tabs.firstIndex { $0.id == current }
        // Right and up go back in time; left from the newest tab only rubber-bands.
        let target = toPrevious ? index.flatMap { $0 > 0 ? tabs[$0 - 1].id : nil } : nil
        thumbnails.capture(current, workspace: workspace, width: thumbnailWidth)
        // Dragging up shows the app's backdrop behind the shrinking page; sideways, black.
        let backdrop = kind == .up ? BrowserMobileAppBackdrop(frame: view.bounds) : UIView(frame: view.bounds)
        if kind != .up {
            backdrop.backgroundColor = .black
        }
        view.insertSubview(backdrop, belowSubview: pageContainer)
        let outgoing = pageContainer.snapshotView(afterScreenUpdates: false) ?? UIView()
        outgoing.frame = view.bounds
        outgoing.layer.cornerCurve = .continuous
        outgoing.clipsToBounds = true
        view.insertSubview(outgoing, belowSubview: bar)
        let incoming = target.flatMap { pagePicture(for: $0) } ?? UIImageView()
        incoming.backgroundColor = .white
        incoming.clipsToBounds = true
        incoming.layer.cornerCurve = .continuous
        incoming.frame = view.bounds
        incoming.isHidden = target == nil
        view.insertSubview(incoming, belowSubview: bar)
        pageContainer.isHidden = true
        swipe = BarSwipe(
            kind: kind, fromID: current, toID: target, incoming: incoming, outgoing: outgoing, backdrop: backdrop,
        )
        updateSwipe(progress: 0)
    }

    private func swipeProgress(_ swipe: BarSwipe, translation: CGPoint) -> CGFloat {
        let width = view.bounds.width
        switch swipe.kind {
        case .sideways:
            let x = translation.x
            return swipe.toID == nil ? -rubberBand(-x, limit: width * 0.12) / width : max(x, 0) / width
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
            case .sideways:
                gesture.state == .ended && swipe.toID != nil
                    && (translation.x > width * 0.3 || velocity.x > 400)
            case .up:
                // Any real lift lands on the previous tab unless the finger
                // heads back down.
                gesture.state == .ended && swipe.toID != nil
                    && -translation.y > 40 && velocity.y < 300
            }
        if completes, let toID = swipe.toID {
            workspace.selectTab(id: toID)
            matchBackdrop(toPictureOf: toID)
        }
        UIView.animate(
            springDuration: 0.3,
            bounce: completes ? 0 : 0.15,
            initialSpringVelocity: 0,
            delay: 0,
            options: [.allowUserInteraction],
        ) {
            if completes, swipe.kind == .up {
                self.landUpSwipe()
            } else {
                self.updateSwipe(progress: completes ? 1 : 0)
            }
        } completion: { _ in
            swipe.outgoing.removeFromSuperview()
            swipe.backdrop.removeFromSuperview()
            self.pageContainer.isHidden = false
            if self.swipe === swipe { self.swipe = nil }
            self.render()
            if completes, let toID = swipe.toID {
                self.coverWhileLoading(toID, with: swipe.incoming)
            } else {
                swipe.incoming.removeFromSuperview()
            }
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

    /// The tab's last picture sized to the screen, top aligned.
    private func pagePicture(for tabID: String) -> UIImageView? {
        guard let image = thumbnails.image(for: tabID), image.size.width > 0 else { return nil }
        let picture = UIImageView(image: image)
        picture.backgroundColor = .white
        picture.clipsToBounds = true
        picture.layer.cornerCurve = .continuous
        picture.contentMode = .scaleToFill
        picture.layer.contentsRect = CGRect(
            x: 0, y: 0, width: 1,
            height: min(1, view.bounds.height / (image.size.height * view.bounds.width / image.size.width)),
        )
        return picture
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

    /// The current page slides right and shrinks while the previous one grows
    /// out of the tab stack.
    private func layoutSidewaysSwipe(_ swipe: BarSwipe, progress: CGFloat) {
        let bounds = view.bounds
        let p = max(min(progress, 1), -1)
        let outgoingScale = 1 - 0.12 * max(p, 0)
        swipe.outgoing.transform = CGAffineTransform(translationX: bounds.width * p * 0.92, y: 0)
            .scaledBy(x: outgoingScale, y: outgoingScale)
        swipe.outgoing.layer.cornerRadius = 40 * min(abs(p) * 4, 1)
        guard swipe.toID != nil else { return }
        let stack = bar.convert(bar.tabStack.center, to: view)
        let startScale = BrowserMobileTabStackButton.cardSize.width / bounds.width
        let scale = startScale + (1 - startScale) * p
        let angle = BrowserMobileTabStackButton.frontAngle * (1 - p)
        let center = CGPoint(
            x: stack.x + (bounds.midX - stack.x) * p,
            y: stack.y + (bounds.midY - stack.y) * p,
        )
        swipe.incoming.bounds = bounds
        swipe.incoming.center = center
        swipe.incoming.transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
        swipe.incoming.layer.cornerRadius = 40 * (1 - p) / max(scale, 0.05)
        swipe.incoming.alpha = min(1, 0.4 + p * 3)
    }

    /// The page shrinks into a card that rests on the bar while the previous
    /// tab's picture comes out of the tab stack over it.
    private func layoutUpSwipe(_ swipe: BarSwipe, progress: CGFloat) {
        let bounds = view.bounds
        let p = max(progress, 0)
        let scale = 1 - 0.28 * p
        let bottom = bounds.height - (bounds.height - expandedBarFrame.minY + 6) * min(1, p * 2)
        let lift = bottom - bounds.midY - bounds.height * scale / 2
        swipe.outgoing.transform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: scale, y: scale)
        swipe.outgoing.layer.cornerRadius = 44 * min(p * 4, 1) / scale
        guard swipe.toID != nil else { return }
        let q = min(p, 1)
        let stack = bar.convert(bar.tabStack.center, to: view)
        let startScale = BrowserMobileTabStackButton.cardSize.width / bounds.width
        let scale2 = startScale + (0.36 - startScale) * q
        let target = CGPoint(x: bounds.width * 0.27, y: bounds.height * 0.62)
        swipe.incoming.bounds = bounds
        swipe.incoming.center = CGPoint(x: stack.x + (target.x - stack.x) * q, y: stack.y + (target.y - stack.y) * q)
        swipe.incoming.transform = CGAffineTransform(rotationAngle: BrowserMobileTabStackButton.frontAngle * (1 - q))
            .scaledBy(x: scale2, y: scale2)
        swipe.incoming.layer.cornerRadius = 40 / max(scale2, 0.05)
        swipe.incoming.alpha = min(1, 0.4 + q * 3)
    }

    /// The previous tab fills the screen while the page's card drops into the
    /// tab stack.
    private func landUpSwipe() {
        guard let swipe else { return }
        let bounds = view.bounds
        swipe.incoming.transform = .identity
        swipe.incoming.bounds = bounds
        swipe.incoming.center = CGPoint(x: bounds.midX, y: bounds.midY)
        swipe.incoming.layer.cornerRadius = 0
        swipe.incoming.alpha = 1
        let stack = bar.convert(bar.tabStack.center, to: view)
        let scale = BrowserMobileTabStackButton.cardSize.width / bounds.width
        swipe.outgoing.transform = CGAffineTransform(
            translationX: stack.x - bounds.midX, y: stack.y - bounds.midY,
        )
        .rotated(by: BrowserMobileTabStackButton.frontAngle)
        .scaledBy(x: scale, y: scale)
        swipe.outgoing.alpha = 0
    }
}
