// BrowserMobilePageViewController.swift

import UIKit

final class BrowserMobilePageViewController: UIViewController, UITextFieldDelegate {
    /// A page wide enough for the buttons and a roomy address (an iPad, a
    /// phone on its side) puts them in one row.
    static let oneRowMinimumWidth: CGFloat = 700

    // MARK: Internal

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
                title: String(localized: "Downloads", table: "Mobile"),
                action: #selector(showDownloads), input: "l", modifierFlags: [.command, .alternate],
            ),
            UIKeyCommand(
                title: String(localized: "Open Location", table: "Mobile"),
                action: #selector(focusAddress),
                input: "l",
                modifierFlags: .command,
            ),
            UIKeyCommand(
                title: String(localized: "New Tab", table: "Mobile"),
                action: #selector(createTab),
                input: "t",
                modifierFlags: .command,
            ),
            UIKeyCommand(
                title: String(localized: "Close Tab", table: "Mobile"),
                action: #selector(closeTab),
                input: "w",
                modifierFlags: .command,
            ),
            UIKeyCommand(
                title: String(localized: "Reload", table: "Mobile"),
                action: #selector(reload),
                input: "r",
                modifierFlags: .command,
            ),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelAddress)),
        ]
    }

    let workspace: BrowserMobileWorkspace
    var showTabs: (() -> Void)?
    var showExtensionSettings: (() -> Void)?
    let addressField = UITextField()
    private(set) var chromeIsAtBottom = true

    // MARK: Private

    private let engineView: UIView
    private var addressTabID: String?
    private let stack = UIStackView()
    private let content = UIView()
    private let chrome = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let chromeStack = UIStackView()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let banner = UIStackView()
    private let bannerLabel = UILabel()
    private let bannerAction = UIButton(type: .system)
    private let emptyState = UIStackView()
    private let emptyTitle = UILabel()
    private let emptyMessage = UILabel()
    private let emptyAction = UIButton(type: .system)
    private let loadError = BrowserMobileLoadErrorView()
    private var backButton = UIButton(type: .system)
    private var forwardButton = UIButton(type: .system)
    private var reloadButton = UIButton(type: .system)
    private var tabsButton = UIButton(type: .system)
    private var newButton = UIButton(type: .system)
    private var shareButton = UIButton(type: .system)
    private var findButton = UIButton(type: .system)
    private let toolbarSpacer = UIView()
    private var toolbarRow = UIStackView()
    private var isChromeOneRow: Bool?
    private var downloadsButton = UIButton(type: .system)
    private var extensionsButton = UIButton(type: .system)

    private var canPresentFind: Bool {
        guard workspace.canFindInPage, let window = viewIfLoaded?.window,
              !window.isHidden, window.windowScene?.activationState == .foregroundActive,
              !isBeingDismissed, !engineView.isHidden else { return false }
        var root: UIViewController = self
        while let parent = root.parent {
            root = parent
        }
        return !Self.hasPresentedController(root)
    }

    private var shareURL: URL? {
        guard let url = workspace.selectedTab.flatMap({ URL(string: $0.urlString) }),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    init(workspace: BrowserMobileWorkspace, contentView: UIView) {
        self.workspace = workspace
        self.engineView = contentView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureChrome()
        configureBanner()
        configureEmptyState()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        engineView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(engineView)
        content.addSubview(emptyState)
        loadError.isHidden = true
        loadError.translatesAutoresizingMaskIntoConstraints = false
        loadError.onReload = { [weak self] in self?.workspace.reload() }
        content.addSubview(loadError)
        NSLayoutConstraint.activate([
            loadError.topAnchor.constraint(equalTo: content.topAnchor),
            loadError.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            loadError.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            loadError.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            engineView.topAnchor.constraint(equalTo: content.topAnchor),
            engineView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            engineView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            engineView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ])
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (self: BrowserMobilePageViewController, _: UITraitCollection) in self.arrangeChrome()
        }
        arrangeChrome()
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneBecameInactive(_:)), name: name, object: nil,
            )
        }
        // The system's find bar rides above the keyboard; the toolbar steps
        // aside while it is up, so the two never overlap.
        for name in [
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardChanged), name: name, object: nil,
            )
        }
        // Find in Page waits for an active scene; the page may draw before that.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneBecameActive(_:)), name: UIScene.didActivateNotification, object: nil,
        )
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // On a phone the page sits in the tab list's navigation stack; its bar
        // would only repeat the toolbar's Show Tabs, so the page takes the room.
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        workspace.dismissFindInPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        arrangeChromeRows()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        arrangeChromeRows()
    }

    /// The address as the field shows it outside editing: the site's host
    /// without `www.`, or the whole address for pages without a web host.
    static func displayAddress(_ urlString: String?) -> String {
        guard let urlString, urlString != "about:blank" else { return "" }
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = components.host, !host.isEmpty
        else { return urlString }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func hasPresentedController(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains(where: hasPresentedController)
    }

    func render() {
        guard isViewLoaded else { return }
        let tab = workspace.selectedTab
        let selectionChanged = addressTabID != tab?.id
        addressTabID = tab?.id
        if selectionChanged {
            // A draft belongs to its tab. Ending editing also cancels any
            // marked text before another tab supplies the displayed address.
            addressField.resignFirstResponder()
        }
        if selectionChanged || !addressField.isFirstResponder {
            addressField.text = Self.displayAddress(tab?.urlString)
        }
        addressField.isEnabled = workspace.isReady
        backButton.isEnabled = tab?.state.canGoBack == true
        forwardButton.isEnabled = tab?.state.canGoForward == true
        newButton.isEnabled = workspace.isReady
        tabsButton.isEnabled = workspace.isReady
        tabsButton.accessibilityValue = String(workspace.tabs.count)
        reloadButton.isEnabled = workspace.isReady && tab != nil && tab?.urlString != "about:blank"
        let loading = tab?.state.isLoading == true
        reloadButton.setImage(UIImage(systemName: loading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = loading
            ? String(localized: "Stop Loading", table: "Mobile")
            : String(localized: "Reload", table: "Mobile")
        progress.progress = Float(tab?.state.progress ?? 0)
        progress.isHidden = !loading || workspace.isFindInPageVisible
        chrome.isHidden = workspace.isFindInPageVisible
        shareButton.isEnabled = shareURL != nil
        downloadsButton.isEnabled = workspace.isReady && workspace.downloads != nil
        let activeDownload = workspace.downloads?
            .entries
            .contains { $0.status == .downloading || $0.status == .saving } == true
        let downloadError = workspace.downloads?.error != nil
        downloadsButton.setImage(UIImage(systemName: downloadError
                ? "exclamationmark.circle"
                : activeDownload ? "arrow.down.circle.fill" : "arrow.down.circle"), for: .normal)
        downloadsButton.accessibilityValue = downloadError
            ? String(localized: "Failed", table: "Mobile")
            : activeDownload ? String(localized: "Downloading", table: "Mobile") : nil
        bannerLabel.text = workspace.sessionError ?? workspace.navigationError
        banner.isHidden = bannerLabel.text == nil
        bannerAction.setTitle(
            workspace.sessionError == nil
                ? String(localized: "Edit Address", table: "Mobile")
                : String(localized: "Retry", table: "Mobile"),
            for: .normal,
        )
        emptyState.isHidden = tab?.state.error == nil && tab?.urlString != "about:blank" && tab != nil
        engineView.isHidden = !emptyState.isHidden
        let pageError = workspace.isReady ? tab?.state.error : nil
        loadError.isHidden = pageError == nil
        loadError.setMessage(pageError)
        // A page's own error shows in the load error view.
        if pageError != nil { emptyState.isHidden = true }
        if !workspace.isReady {
            emptyTitle.text = String(localized: "Opening your tabs", table: "Mobile")
            emptyMessage.text = workspace.sessionError ?? String(
                localized: "Restoring this window’s session…",
                table: "Mobile",
            )
            emptyAction.isHidden = true
        } else {
            emptyTitle.text = String(localized: "Where next?", table: "Mobile")
            emptyMessage.text = String(localized: "Search the web or enter an address.", table: "Mobile")
            emptyAction.isHidden = false
            emptyAction.setTitle(String(localized: "Search or Enter Address", table: "Mobile"), for: .normal)
        }
        findButton.isEnabled = canPresentFind
        extensionsButton.isEnabled = workspace.isReady && workspace.extensionEngine != nil
    }

    @objc func focusAddress() {
        guard workspace.isReady else { return }
        workspace.dismissFindInPage()
        loadViewIfNeeded()
        addressField.becomeFirstResponder()
        addressField.selectAll(nil)
    }

    @objc func findInPage() {
        guard canPresentFind else { return }
        // Resigning cancels the address draft; Return is the only submit path.
        addressField.resignFirstResponder()
        workspace.presentFindInPage()
    }

    @objc func showDownloads() {
        guard workspace.isReady, let downloads = workspace.downloads,
              workspace.javaScriptDialog == nil, workspace.httpAuthentication == nil, presentedViewController == nil,
              let window = viewIfLoaded?.window, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive,
              !Self.hasPresentedController(window.rootViewController ?? self)
        else { return }
        workspace.dismissFindInPage()
        addressField.resignFirstResponder()
        let controller = BrowserMobileDownloadsViewController(downloads: downloads)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.markedTextRange == nil else { return false }
        let input = textField.text ?? ""
        textField.resignFirstResponder()
        workspace.submit(input)
        render()
        return true
    }

    func textFieldDidEndEditing(_: UITextField) { render() }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        workspace.dismissFindInPage()
        // Editing starts from the whole address, selected to type over.
        let address = workspace.selectedTab?.urlString
        textField.text = address == "about:blank" ? "" : address
        DispatchQueue.main.async { [weak textField] in
            guard let textField, textField.isFirstResponder else { return }
            textField.selectAll(nil)
        }
    }

    @objc private func keyboardChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateChromeForFind() }
    }

    private func updateChromeForFind() {
        let finding = workspace.isFindInPageVisible
        guard chrome.isHidden != finding else { return }
        chrome.isHidden = finding
        progress.isHidden = finding || workspace.selectedTab?.state.isLoading != true
    }

    @objc private func sceneBecameActive(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === viewIfLoaded?.window?.windowScene else { return }
        render()
    }

    @objc private func sceneBecameInactive(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === viewIfLoaded?.window?.windowScene else { return }
        workspace.dismissFindInPage()
    }

    @objc private func createTab() { workspace.newTab()
        focusAddress()
    }

    @objc private func closeTab() {
        guard let id = workspace.selectedTabID else { return }
        workspace.closeTab(id: id)
    }

    @objc private func reload() { workspace.reload() }
    @objc private func cancelAddress() { workspace.dismissFindInPage()
        addressField.resignFirstResponder()
        render()
    }

    private func arrangeChrome() {
        // A narrow iPad window gets the same reachable controls as a phone.
        // Landscape/short windows keep chrome above content and keyboard.
        chromeIsAtBottom = traitCollection.horizontalSizeClass != .regular && traitCollection
            .verticalSizeClass != .compact
        arrangeChromeRows()
        let ordered: [UIView] = chromeIsAtBottom
            ? [banner, content, progress, chrome]
            : [chrome, progress, banner, content]
        for (index, view) in ordered.enumerated() {
            if stack.arrangedSubviews.indices.contains(index), stack.arrangedSubviews[index] === view {
                continue
            }
            // Reorder without removing chrome from the view hierarchy so
            // resizing preserves address focus, selection and IME composition.
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: index)
        }
    }

    private func arrangeChromeRows() {
        // The sidebar floats over the page, so the safe area is the width the chrome gets.
        let oneRow = view.safeAreaLayoutGuide.layoutFrame.width >= Self.oneRowMinimumWidth
        guard isChromeOneRow != oneRow else { return }
        isChromeOneRow = oneRow
        chromeStack.axis = oneRow ? .horizontal : .vertical
        chromeStack.spacing = oneRow ? 8 : 4
        toolbarSpacer.isHidden = oneRow
        toolbarRow.setContentHuggingPriority(oneRow ? .required : .defaultLow, for: .horizontal)
        toolbarRow.setContentCompressionResistancePriority(oneRow ? .required : .defaultHigh, for: .horizontal)
    }

    private func configureChrome() {
        chrome.accessibilityIdentifier = "browser.chrome"
        chromeStack.axis = .vertical
        chromeStack.spacing = 4
        chromeStack.isLayoutMarginsRelativeArrangement = true
        chromeStack.directionalLayoutMargins = .init(top: 8, leading: 12, bottom: 4, trailing: 12)
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        chrome.contentView.addSubview(chromeStack)
        NSLayoutConstraint.activate([
            chromeStack.leadingAnchor.constraint(equalTo: chrome.contentView.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: chrome.contentView.trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: chrome.contentView.topAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: chrome.contentView.bottomAnchor),
        ])
        addressField.placeholder = String(localized: "Search or enter address", table: "Mobile")
        addressField.accessibilityLabel = String(localized: "Address", table: "Mobile")
        addressField.accessibilityIdentifier = "browser.address"
        addressField.delegate = self
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocorrectionType = .no
        addressField.autocapitalizationType = .none
        addressField.smartQuotesType = .no
        addressField.smartDashesType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.font = .preferredFont(forTextStyle: .body)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.borderStyle = .roundedRect
        addressField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        reloadButton = button("arrow.clockwise", "Reload", "browser.reload") { [weak self] in
            self?.workspace.reloadOrStop()
        }
        downloadsButton = button("arrow.down.circle", "Downloads", "browser.downloads") { [weak self] in
            self?.showDownloads()
        }
        extensionsButton = button("puzzlepiece.extension", "Extensions", "browser.extensions") { [weak self] in
            self?.showExtensions()
        }
        let addressRow = UIStackView(arrangedSubviews: [addressField, extensionsButton, downloadsButton, reloadButton])
        addressRow.spacing = 4
        chromeStack.addArrangedSubview(addressRow)
        backButton = button("chevron.backward", "Back", "browser.back") { [weak self] in self?.workspace.goBack() }
        forwardButton = button("chevron.forward", "Forward", "browser.forward") { [weak self] in
            self?.workspace.goForward()
        }
        tabsButton = button("sidebar.leading", "Show Tabs", "browser.showTabs") { [weak self] in
            self?.workspace.dismissFindInPage()
            self?.showTabs?()
        }
        newButton = button("plus", "New Tab", "browser.newTab") { [weak self] in self?.createTab() }
        shareButton = button("square.and.arrow.up", "Share", "browser.share") { [weak self] in self?.sharePage() }
        findButton = button("doc.text.magnifyingglass", "Find in Page", "browser.findInPage") { [weak self] in
            self?.findInPage()
        }
        let toolbar = UIStackView(arrangedSubviews: [
            backButton,
            forwardButton,
            toolbarSpacer,
            findButton,
            shareButton,
            tabsButton,
            newButton,
        ])
        toolbar.spacing = 4
        toolbarRow = toolbar
        chromeStack.addArrangedSubview(toolbar)
    }

    private func configureBanner() {
        banner.axis = .horizontal
        banner.alignment = .center
        banner.spacing = 8
        banner.isLayoutMarginsRelativeArrangement = true
        banner.directionalLayoutMargins = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        banner.backgroundColor = .secondarySystemBackground
        banner.accessibilityIdentifier = "browser.sessionError"
        bannerLabel.numberOfLines = 0
        bannerLabel.font = .preferredFont(forTextStyle: .footnote)
        bannerLabel.adjustsFontForContentSizeCategory = true
        banner.addArrangedSubview(bannerLabel)
        bannerAction.setContentCompressionResistancePriority(.required, for: .horizontal)
        bannerAction.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if workspace.sessionError != nil {
                Task { await self.workspace.retryPersistence() }
            } else {
                focusAddress()
            }
        }, for: .touchUpInside)
        banner.addArrangedSubview(bannerAction)
    }

    private func configureEmptyState() {
        emptyState.axis = .vertical
        emptyState.alignment = .center
        emptyState.spacing = 12
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.font = .preferredFont(forTextStyle: .title1)
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
        emptyAction.addAction(UIAction { [weak self] _ in self?.focusAddress() }, for: .touchUpInside)
        for view in [emptyTitle, emptyMessage, emptyAction] {
            emptyState.addArrangedSubview(view)
        }
    }

    private func button(_ symbol: String, _ title: String, _ id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = NSLocalizedString(title, tableName: "Mobile", comment: "Browser toolbar action")
        button.accessibilityIdentifier = id
        button.isPointerInteractionEnabled = true
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44),
        ])
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    /// The extensions' actions for the page, in a popover from the toolbar.
    private func showExtensions() {
        guard let engine = workspace.extensionEngine, presentedViewController == nil else { return }
        workspace.dismissFindInPage()
        BrowserMobileExtensionActionsViewController.present(
            engine: engine, from: self, anchor: extensionsButton,
        ) { [weak self] in self?.showExtensionSettings?() }
    }

    private func sharePage() {
        guard let url = shareURL else { return }
        workspace.dismissFindInPage()
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = shareButton
        controller.popoverPresentationController?.sourceRect = shareButton.bounds
        present(controller, animated: true)
    }
}
