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

    override var preferredStatusBarStyle: UIStatusBarStyle {
        mode == .switcher || mode == .search ? .lightContent : .default
    }

    let workspace: BrowserMobileWorkspace

    private(set) var mode = Mode.browsing

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
    private let bar = BrowserMobilePhoneBarView()
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
    private var iconRequests = Set<String>()

    // Bar collapse while scrolling.
    private var scrollObservation: NSKeyValueObservation?
    private var lastScrollY: CGFloat = 0
    private var scrollTravel: CGFloat = 0

    // Panels.
    private var surface: UIView?
    private var surfaceTint: UIView?
    private var dismissCatcher: UIView?
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

    private var thumbnailWidth: CGFloat { (view.bounds.width * 0.66).rounded() }
    private var safeBottom: CGFloat { view.safeAreaInsets.bottom }
    private var expandedBarHeight: CGFloat { BrowserMobilePhoneBarView.height(safeBottom: safeBottom, collapsed: false)
    }

    private var barFrame: CGRect {
        let height = BrowserMobilePhoneBarView.height(safeBottom: safeBottom, collapsed: bar.isCollapsed)
        return CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
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

    init(workspace: BrowserMobileWorkspace, contentView: UIView) {
        self.workspace = workspace
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
        workspace.onChange = { [weak self] in self?.render() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pageContainer.backgroundColor = .systemBackground
        pageContainer.layer.cornerCurve = .continuous
        pageContainer.clipsToBounds = true
        view.addSubview(pageContainer)
        pageContainer.addSubview(contentView)
        configureEmptyState()
        view.addSubview(bar)
        bar.tabStack.addAction(UIAction { [weak self] _ in self?.openSwitcher() }, for: .touchUpInside)
        bar.plusButton.addAction(
            UIAction { [weak self] _ in self?.openSearch(text: "", replacesPage: false) },
            for: .touchUpInside,
        )
        bar.moreButton.addAction(UIAction { [weak self] _ in self?.openPageMenu() }, for: .touchUpInside)
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
        layoutPage()
        if surface == nil {
            layoutBar()
        }
        switcher?.frame = view.bounds
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The bar stays opaque; the page lays out above its full height even
        // while it is collapsed, so fixed footers never jump.
        workspace.setObscuredInsets(UIEdgeInsets(
            top: view.safeAreaInsets.top, left: view.safeAreaInsets.left,
            bottom: expandedBarHeight, right: view.safeAreaInsets.right,
        ))
    }

    static func nextZoom(from zoom: CGFloat, larger: Bool) -> CGFloat {
        larger
            ? zoomSteps.first { $0 > zoom + 0.001 } ?? zoomSteps[zoomSteps.count - 1]
            : zoomSteps.last { $0 < zoom - 0.001 } ?? zoomSteps[0]
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
        requestIcons()
        updateEmptyState()
        bar.isHidden = workspace.isFindInPageVisible && mode == .browsing
        if mode == .pageMenu { updatePagePanel() }
        if mode == .search { searchPanel.candidates = searchCandidates() }
        if mode == .switcher, !isAnimatingSwitcher { refreshSwitcherEntries() }
        presentedTabs?.render()
        javaScriptDialogPresenter.update(workspace.javaScriptDialog)
        httpAuthenticationPresenter.update(workspace.httpAuthentication)
        if !didAutoOpenSearch, workspace.isReady, mode == .browsing, view.window != nil,
           tab == nil || tab?.urlString == "about:blank"
        {
            didAutoOpenSearch = true
            DispatchQueue.main.async { [weak self] in
                guard let self, mode == .browsing, presentedViewController == nil else { return }
                openSearch(text: "", replacesPage: false)
            }
        }
    }

    private func layoutPage() {
        guard pageContainer.transform.isIdentity else { return }
        pageContainer.frame = view.bounds
        contentView.frame = pageContainer.bounds
        emptyState.frame = pageContainer.bounds.inset(by: UIEdgeInsets(
            top: view.safeAreaInsets.top, left: 24, bottom: expandedBarHeight, right: 24,
        ))
    }

    private func layoutBar() {
        bar.frame = barFrame
    }

    // MARK: Theme, icons, tab stack

    /// Looks at the page under the bar shortly after a change and turns the
    /// bar's glass dark over a dark page.
    private func sampleBackdrop() {
        guard !isBackdropSampleScheduled else { return }
        isBackdropSampleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            isBackdropSampleScheduled = false
            guard let id = workspace.selectedTabID, !contentView.isHidden else {
                setBackdropDark(false)
                return
            }
            let height = expandedBarHeight
            let rect = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
            workspace.snapshot(tabID: id, rect: rect, width: 32) { [weak self] image in
                guard let self, workspace.selectedTabID == id, let image = image?.cgImage,
                      let luminance = BrowserMobileBackdrop.luminance(of: image) else { return }
                setBackdropDark(BrowserMobileBackdrop.isDark(luminance: luminance, current: bar.isDark))
            }
        }
    }

    /// Turns the bar to match a tab's last picture before its page shows, so
    /// the color changes along with a switch instead of after it.
    private func matchBackdrop(toPictureOf tabID: String) {
        guard let image = thumbnails.image(for: tabID)?.cgImage, image.height > 0 else { return }
        let screenHeight = view.bounds.height * CGFloat(image.width) / view.bounds.width
        let barHeight = expandedBarHeight * CGFloat(image.width) / view.bounds.width
        let bottom = min(CGFloat(image.height), screenHeight)
        guard let strip = image.cropping(to: CGRect(
            x: 0, y: max(0, bottom - barHeight), width: CGFloat(image.width), height: barHeight,
        )), let luminance = BrowserMobileBackdrop.luminance(of: strip) else { return }
        setBackdropDark(BrowserMobileBackdrop.isDark(luminance: luminance, current: bar.isDark))
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
            showsFront: true, showsBack: back != nil,
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
        emptyState.isHidden = workspace.isReady && error == nil && !isBlank
        contentView.isHidden = !workspace.isReady || tab?.state.error != nil || isBlank
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
        // Controls go first when collapsing and come back last when expanding.
        UIView.animate(withDuration: collapsed ? 0.08 : 0.2, delay: collapsed ? 0 : 0.06, options: [
            .beginFromCurrentState, .allowUserInteraction,
        ]) {
            self.bar.setCollapsed(collapsed)
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [
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
    private func openSurface(height: CGFloat, dark: Bool, content: UIView) {
        guard surface == nil else { return }
        setBarCollapsed(false, animated: false)
        layoutBar()
        let catcher = UIControl(frame: view.bounds)
        catcher.accessibilityIdentifier = "browser.dismissPanel"
        catcher.accessibilityLabel = String(localized: "Close", table: "Mobile")
        catcher.addAction(UIAction { [weak self] _ in self?.closePanel() }, for: .touchUpInside)
        view.insertSubview(catcher, belowSubview: bar)
        dismissCatcher = catcher
        let surface: UIView
        let container: UIView
        if dark {
            surface = UIView(frame: bar.frame)
            container = surface
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
            blur.frame = surface.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            surface.addSubview(blur)
            let shade = UIView(frame: surface.bounds)
            shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shade.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 0.45)
            surface.addSubview(shade)
            // Starts the color of the bar it grows from.
            let tint = UIView(frame: surface.bounds)
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tint.backgroundColor = bar.isDark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.86, alpha: 1)
            surface.addSubview(tint)
            surfaceTint = tint
        } else {
            let glass = UIVisualEffectView(effect: BrowserMobileBackdrop.glass())
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
        content.alpha = 0
        container.addSubview(content)
        view.insertSubview(surface, aboveSubview: bar)
        self.surface = surface
        let target = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState]) {
            self.bar.tabStack.alpha = 0
            self.bar.plusButton.alpha = 0
            self.bar.moreButton.alpha = 0
        }
        UIView.animate(springDuration: 0.42, bounce: 0.12, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = target
            surface.layer.cornerRadius = 36
            self.surfaceTint?.alpha = 0
        }
        UIView.animate(withDuration: 0.22, delay: 0.06, options: [.beginFromCurrentState]) {
            content.alpha = 1
        }
    }

    /// Shrinks the open panel back into the bar, which settles with a small bounce.
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
        dismissCatcher?.removeFromSuperview()
        dismissCatcher = nil
        let content = ((surface as? UIVisualEffectView)?.contentView ?? surface).subviews.last
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState]) {
            content?.alpha = 0
        }
        UIView.animate(springDuration: 0.5, bounce: 0.28, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            surface.frame = self.expandedBarFrame
            surface.layer.cornerRadius = 0
            self.surfaceTint?.alpha = 1
            if closingMode == .search {
                self.pageContainer.transform = .identity
                self.pageContainer.frame = self.view.bounds
                self.pageContainer.layer.cornerRadius = 0
            }
        } completion: { _ in
            if self.surface === surface {
                surface.removeFromSuperview()
                self.surface = nil
                self.surfaceTint = nil
                self.layoutPage()
                self.layoutBar()
            }
            completion?()
        }
        UIView.animate(withDuration: 0.25, delay: 0.12, options: [.beginFromCurrentState]) {
            self.bar.tabStack.alpha = 1
            self.bar.plusButton.alpha = 1
            self.bar.moreButton.alpha = 1
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
        updatePagePanel()
        openSurface(height: pagePanel.contentHeight + safeBottom, dark: false, content: pagePanel)
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
        pagePanel.update(
            host: BrowserMobilePageViewController.displayAddress(tab?.urlString),
            canGoBack: tab?.state.canGoBack == true, canGoForward: tab?.state.canGoForward == true,
            isLoading: tab?.state.isLoading == true, canCopy: isWebPage,
            canReload: tab != nil && tab?.urlString != "about:blank",
            tiles: tiles, displayMenu: isWebPage ? displayMenu() : nil,
        )
    }

    private func displayMenu() -> UIMenu {
        let zoom = workspace.pageZoom
        let smaller = UIAction(
            title: String(localized: "Smaller Text", table: "Mobile"),
            image: UIImage(systemName: "textformat.size.smaller"),
            attributes: zoom <= Self.zoomSteps[0] ? [.disabled, .keepsMenuPresented] : .keepsMenuPresented,
        ) { [weak self] _ in self?.changeZoom(larger: false) }
        let reset = UIAction(
            title: Double(zoom).formatted(.percent.precision(.fractionLength(0))),
            attributes: abs(zoom - 1) < 0.001 ? [.disabled, .keepsMenuPresented] : .keepsMenuPresented,
        ) { [weak self] _ in self?.setZoom(1) }
        reset.accessibilityLabel = String(localized: "Actual Size", table: "Mobile")
        let larger = UIAction(
            title: String(localized: "Larger Text", table: "Mobile"),
            image: UIImage(systemName: "textformat.size.larger"),
            attributes: zoom >= Self.zoomSteps[Self.zoomSteps.count - 1]
                ? [.disabled, .keepsMenuPresented]
                : .keepsMenuPresented,
        ) { [weak self] _ in self?.changeZoom(larger: true) }
        let textSize = UIMenu(options: .displayInline, preferredElementSize: .small, children: [smaller, reset, larger])
        let desktop = workspace.prefersDesktopSite
        let layout = UIAction(
            title: desktop
                ? String(localized: "Request Mobile Website", table: "Mobile")
                : String(localized: "Request Desktop Website", table: "Mobile"),
            image: UIImage(systemName: desktop ? "iphone" : "desktopcomputer"),
        ) { [weak self] _ in
            guard let self else { return }
            workspace.prefersDesktopSite = !desktop
            closePanel()
        }
        return UIMenu(children: [textSize, layout])
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

    // MARK: Search

    /// Opens the search panel. With `replacesPage` the typed address loads in
    /// the current tab; otherwise it opens a new one.
    private func openSearch(text: String, replacesPage: Bool) {
        guard workspace.isReady else { return }
        if mode == .switcher {
            closeSwitcherInstantly()
        }
        guard mode == .browsing else { return }
        workspace.dismissFindInPage()
        mode = .search
        searchReplacesPage = replacesPage
        searchPanel.candidates = searchCandidates()
        searchPanel.onSubmit = { [weak self] text in self?.submitSearch(text) }
        searchPanel.onSelect = { [weak self] item in self?.selectSuggestion(item) }
        let top = searchPanelTop(keyboardTop: keyboardTop ?? view.bounds.height * 0.655)
        openSurface(height: view.bounds.height - top, dark: true, content: searchPanel)
        searchPanel.begin(text: text)
        pageContainer.layer.cornerRadius = 0
        let card = searchCardFrame()
        UIView.animate(springDuration: 0.42, bounce: 0.1, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            self.applyPageCard(card)
        }
        setNeedsStatusBarAppearanceUpdate()
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
                location: tab.placement == .temporary ? nil : location(of: tab),
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
        let place = tab.placement == .app
            ? String(localized: "Favorites", table: "Mobile")
            : String(localized: "Pinned", table: "Mobile")
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
        switcher.backdrop.image = currentID.flatMap { thumbnails.image(for: $0) }
        view.addSubview(switcher)
        self.switcher = switcher
        isAnimatingSwitcher = true
        setNeedsStatusBarAppearanceUpdate()

        let chrome = [switcher.backdrop, switcher.spacesButton, switcher.plusButton, switcher.settingsButton]
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
        bar.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.15) {
            self.bar.alpha = 0
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
        switcher.onNewTab = { [weak self] in self?.openSearch(text: "", replacesPage: false) }
        switcher.onSpaces = { [weak self] in self?.showSpaces() }
        switcher.onSettings = { [weak self] in self?.showSettings() }
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
            switcher.spacesButton.alpha = 0
            switcher.plusButton.alpha = 0
            switcher.settingsButton.alpha = 0
        }
        UIView.animate(springDuration: 0.24, bounce: 0, initialSpringVelocity: 0, delay: 0, options: []) {
            card.bounds.size = self.view.bounds.size
            card.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            card.layoutIfNeeded()
        } completion: { _ in
            self.finishSwitcher()
        }
        bar.isUserInteractionEnabled = true
        // The bar comes back over the growing card, not after it.
        view.bringSubviewToFront(bar)
        UIView.animate(withDuration: 0.12, delay: 0.04) {
            self.bar.alpha = 1
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
        bar.alpha = 1
        bar.isUserInteractionEnabled = true
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
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) },
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.preferredCornerRadius = 40
        navigation.view.backgroundColor = BrowserMobileTabsViewController.phoneSheetColor
        presentedTabs = controller
        present(navigation, animated: true)
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let controller = BrowserMobilePhoneSettingsViewController(workspace: workspace)
        controller.showDownloads = { [weak self, weak controller] in
            guard let downloads = self?.workspace.downloads else { return }
            controller?.navigationController?.pushViewController(
                BrowserMobileDownloadsViewController(downloads: downloads), animated: true,
            )
        }
        controller.showArchive = { [weak self, weak controller] in
            guard let self else { return }
            let archive = BrowserMobileArchiveViewController(workspace: workspace)
            archive.didRestore = { [weak self, weak controller] in
                controller?.dismiss(animated: true)
                guard let self, let id = workspace.selectedTabID else { return }
                refreshSwitcherEntries()
                closeSwitcher(opening: id)
            }
            controller?.navigationController?.pushViewController(archive, animated: true)
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.sheetPresentationController?.preferredCornerRadius = 36
        present(navigation, animated: true)
    }

    @objc private func findInPage() {
        guard mode == .browsing, workspace.canFindInPage else { return }
        workspace.presentFindInPage()
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

// MARK: - Bar swipe between tabs

extension BrowserMobilePhoneViewController {
    /// A sideways drag on the bar moves to the previous tab, as on the system's
    /// home indicator; the next tab's picture grows out of the tab stack.
    fileprivate final class BarSwipe {
        let fromID: String
        let toID: String?
        let incoming: UIImageView
        let outgoing: UIView
        let backdrop: UIView

        init(fromID: String, toID: String?, incoming: UIImageView, outgoing: UIView, backdrop: UIView) {
            self.fromID = fromID
            self.toID = toID
            self.incoming = incoming
            self.outgoing = outgoing
            self.backdrop = backdrop
        }
    }

    private func configureBarSwipe() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(barSwiped(_:)))
        bar.addGestureRecognizer(pan)
    }

    @objc private func barSwiped(_ gesture: UIPanGestureRecognizer) {
        let width = view.bounds.width
        switch gesture.state {
        case .began:
            guard mode == .browsing, swipe == nil, let current = workspace.selectedTabID else { return }
            let velocity = gesture.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) else { return }
            let tabs = workspace.switcherTabs
            let index = tabs.firstIndex { $0.id == current }
            // Right goes back in time; left from the newest tab only rubber-bands.
            let target = velocity.x > 0 ? index.flatMap { $0 > 0 ? tabs[$0 - 1].id : nil } : nil
            thumbnails.capture(current, workspace: workspace, width: thumbnailWidth)
            let backdrop = UIView(frame: view.bounds)
            backdrop.backgroundColor = .black
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
            swipe = BarSwipe(fromID: current, toID: target, incoming: incoming, outgoing: outgoing, backdrop: backdrop)
            updateSwipe(progress: 0)
        case .changed:
            guard let swipe else { return }
            let x = gesture.translation(in: view).x
            let progress = swipe.toID == nil ? -rubberBand(-x, limit: width * 0.12) / width : max(x, 0) / width
            updateSwipe(progress: progress)
        case .cancelled, .ended, .failed:
            guard let swipe else { return }
            let x = gesture.translation(in: view).x
            let velocity = gesture.velocity(in: view).x
            let completes = gesture.state == .ended && swipe.toID != nil && (x > width * 0.3 || velocity > 400)
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
                self.updateSwipe(progress: completes ? 1 : 0)
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
        default: break
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

    /// Lays out both pages for a swipe that is `progress` of the way done:
    /// the current page slides right and shrinks while the previous one grows
    /// out of the tab stack.
    private func updateSwipe(progress: CGFloat) {
        guard let swipe else { return }
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
}
