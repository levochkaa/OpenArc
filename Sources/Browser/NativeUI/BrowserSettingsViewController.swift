// BrowserSettingsViewController.swift

import AppKit
import Combine
import Settings
import UniformTypeIdentifiers

// MARK: - BrowserSettingsLayout

enum BrowserSettingsLayout {
    static let windowWidth: CGFloat = 684
    static let windowHeight: CGFloat = 562
    static let contentPadding: CGFloat = 24
    static let contentSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    static let pickerWidth: CGFloat = 190
    static let shortcutCaptureWidth: CGFloat = 132
    static let siteSearchNameWidth: CGFloat = 140
    static let siteSearchKeywordWidth: CGFloat = 120
    static let siteSearchColumnSpacing: CGFloat = 12
    static let cardCornerRadius: CGFloat = 10
    static let cardHorizontalPadding: CGFloat = 14
    static let cardVerticalPadding: CGFloat = 6
    /// Sign-in buttons and fields share one width, centered in the account card.
    static let signInWidth: CGFloat = 280
    static let accountIconSize: CGFloat = 64
    static let avatarSize: CGFloat = 36

    /// A card stands off the window: lighter in Dark Mode, white in Light Mode.
    static let cardFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.white
    }

    /// A card's outline: just enough to separate it from the window.
    static let cardStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.08)
    }
}

// MARK: - BrowserSettingsIcon

/// The colored badge before a setting: a white symbol on a rounded square,
/// colored by the setting's group.
struct BrowserSettingsIcon {
    static let side: CGFloat = 20

    /// Badges by setting ID.
    static let icons: [String: BrowserSettingsIcon] = [
        // General
        "automatic-updates": .init("arrow.down.circle.fill", .systemGray),
        "update-channel": .init("shippingbox.fill", .systemGray),
        "appearance": .init("circle.lefthalf.filled", .systemIndigo),
        "sidebar-position": .init("sidebar.left", .systemIndigo),
        "recent-pages-previews": .init("rectangle.stack.fill", .systemBlue),
        "mail-previews": .init("envelope.fill", .systemBlue),
        "folder-previews": .init("folder.fill", .systemBlue),
        "warn-before-quitting": .init("exclamationmark.triangle.fill", .systemOrange),
        "confirm-profile-moves": .init("person.2.fill", .systemTeal),
        "blurred-background": .init("camera.filters", .systemPurple),
        "battery-saver": .init("battery.75percent", .systemGreen),
        "block-ads": .init("hand.raised.fill", .systemRed),
        "block-trackers": .init("eye.slash.fill", .systemBlue),
        "block-cookie-banners": .init("checkmark.shield.fill", .systemOrange),
        "filter-lists": .init("list.bullet.rectangle.fill", .systemGray),
        // Links
        "little-arc": .init("macwindow", .systemGreen),
        "little-window-option-command-click": .init("command", .systemGreen),
        "little-window-any-app": .init("square.on.square", .systemGreen),
        "small-window-lifetime": .init("timer", .systemGreen),
        "peek": .init("eye.fill", .systemPurple),
        "peek-other-sites": .init("arrow.up.forward.square.fill", .systemPurple),
        // Profiles
        "temporary-tab-lifetime": .init("archivebox.fill", .systemOrange),
        "automatic-tab-archival": .init("archivebox.fill", .systemOrange),
        "search-engine": .init("magnifyingglass", .systemBlue),
        "search-suggestions": .init("text.magnifyingglass", .systemBlue),
        "ai-search-suggestion": .init("sparkles", .systemPurple),
        "ai-search-provider": .init("sparkle.magnifyingglass", .systemPurple),
        "new-documents-app": .init("doc.badge.plus", .systemGray),
        "download-location": .init("arrow.down.to.line", .systemBlue),
        // Advanced
        "sound-effects": .init("speaker.wave.2.fill", .systemBlue),
        "haptic-feedback": .init("hand.tap.fill", .systemBlue),
        "restore-windows": .init("macwindow.on.rectangle", .systemGreen),
        "window-dragging-from-page-top": .init("rectangle.topthird.inset.filled", .systemGreen),
        "bookmarks-bar": .init("bookmark.fill", .systemRed),
        "toolbar-full-url": .init("ellipsis.rectangle.fill", .systemRed),
        "picture-in-picture": .init("pip.fill", .systemPurple),
        "streaming-in-webkit": .init("play.tv.fill", .systemRed),
        "fairplay-in-chromium": .init("lock.shield.fill", .systemIndigo),
        "site-engines-reset": .init("arrow.uturn.backward", .systemGray),
        "chrome-engine": .init("cpu.fill", .systemOrange),
        "webkit-engine": .init("safari.fill", .systemBlue),
        "ladybird-engine": .init("ladybug.fill", .systemRed),
        "share-theme-with-websites": .init("paintpalette.fill", .systemPurple),
        "agent-access": .init("terminal.fill", .systemGray),
        // Accounts
        "account.sync": .init("arrow.triangle.2.circlepath", .systemBlue),
        "default-browser": .init("globe", .systemBlue),
    ]

    let symbol: String
    let color: NSColor

    /// Drawn for the current appearance each time it shows.
    var image: NSImage {
        let side = Self.side
        let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [.white])))
        let color = color
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height,
                ))
            }
            return true
        }
    }

    init(_ symbol: String, _ color: NSColor) {
        self.symbol = symbol
        self.color = color
    }
}

// MARK: - BrowserShortcutSettingsRow

/// A Shortcuts row: the command, its shortcut and Record and Reset. It lays
/// out by frames, since a hundred rows of nested constraints took a second.
final class BrowserShortcutSettingsRow: NSView {
    // MARK: Internal

    static let height: CGFloat = 36

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    /// A hairline above the row, as other sections put between their rows.
    var drawsSeparator = true { didSet { needsDisplay = true } }

    // MARK: Private

    private let title: NSTextField
    private let value: NSView
    private let record: NSButton
    private let reset: NSButton

    init(title: NSTextField, value: NSView, record: NSButton, reset: NSButton) {
        self.title = title
        self.value = value
        self.record = record
        self.reset = reset
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        for view in [title, value, record, reset] {
            addSubview(view)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        guard drawsSeparator else { return }
        NSColor.separatorColor.setFill()
        let scale = window?.backingScaleFactor ?? 2
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).fill()
    }

    override func layout() {
        super.layout()
        let spacing: CGFloat = 12
        let resetWidth: CGFloat = 72
        let recordWidth: CGFloat = 92
        let valueWidth = BrowserSettingsLayout.shortcutCaptureWidth
        func centered(_ view: NSView, x: CGFloat, width: CGFloat) {
            let natural = view.intrinsicContentSize.height
            let height = min(natural > 0 ? natural : 22, bounds.height)
            view.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        }
        let resetX = bounds.width - resetWidth
        let recordX = resetX - spacing - recordWidth
        let valueX = recordX - spacing - valueWidth
        centered(reset, x: resetX, width: resetWidth)
        centered(record, x: recordX, width: recordWidth)
        centered(value, x: valueX, width: valueWidth)
        centered(title, x: 0, width: max(valueX - spacing, 0))
    }

    static func empty() -> BrowserShortcutSettingsRow {
        BrowserShortcutSettingsRow(
            title: NSTextField(labelWithString: ""),
            value: NSView(),
            record: NSButton(),
            reset: NSButton(),
        )
    }
}

// MARK: - BrowserShortcutSettingsList

/// The Shortcuts rows, one under another, each made as it comes into view.
final class BrowserShortcutSettingsList: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(count) * BrowserShortcutSettingsRow.height)
    }

    // MARK: Private

    private let count: Int
    private let makeRow: (Int) -> BrowserShortcutSettingsRow
    private var rows = [Int: BrowserShortcutSettingsRow]()

    init(count: Int, makeRow: @escaping (Int) -> BrowserShortcutSettingsRow) {
        self.count = count
        self.makeRow = makeRow
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip,
        )
    }

    override func layout() {
        super.layout()
        makeVisibleRows()
        for (index, row) in rows {
            row.frame = frame(ofRow: index)
        }
    }

    /// Every row, as scrolling through all of them would make.
    func makeAllRows() {
        makeRows(in: 0..<count)
    }

    @objc private func clipBoundsChanged() {
        makeVisibleRows()
    }

    private func frame(ofRow index: Int) -> NSRect {
        let height = BrowserShortcutSettingsRow.height
        return NSRect(x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
    }

    /// The rows in view and a screen's worth either side.
    private func makeVisibleRows() {
        guard window != nil else { return }
        let visible = visibleRect.insetBy(dx: 0, dy: -max(visibleRect.height, 300))
        let height = BrowserShortcutSettingsRow.height
        let first = max(Int(floor(visible.minY / height)), 0)
        let last = min(Int(ceil(visible.maxY / height)), count)
        guard first < last else { return }
        makeRows(in: first..<last)
    }

    private func makeRows(in range: Range<Int>) {
        for index in range where rows[index] == nil {
            let row = makeRow(index)
            row.frame = frame(ofRow: index)
            addSubview(row)
            rows[index] = row
        }
    }
}

// MARK: - BrowserSettingsClickableRow

/// A settings row that acts on a click anywhere in it; its own controls still
/// take their clicks first.
final class BrowserSettingsClickableRow: NSView {
    // MARK: Private

    private let onClick: () -> Void

    // MARK: Internal

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with _: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}

// MARK: - BrowserSafariBookmarkImportPanel

@MainActor private enum BrowserSafariBookmarkImportPanel {
    static func chooseSourceURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = BrowserStrings.bookmarksImport
        panel.title = BrowserBookmarkImportSource.safari.title
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - BrowserDownloadLocationPanel

@MainActor private enum BrowserDownloadLocationPanel {
    static func chooseDirectory(startingAt directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = BrowserStrings.settingsDownloadLocationChoose
        panel.title = BrowserStrings.settingsDownloadLocation
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - BrowserSettingsPane

enum BrowserSettingsPane: String, CaseIterable, Hashable {
    case accounts
    case general
    case profiles
    case links
    case shortcuts
    case icon
    case advanced

    // MARK: Internal

    static var available: [Self] {
        allCases.filter { $0 != .accounts || BrowserHostedService.isEnabled }
    }

    var title: String {
        switch self {
        case .accounts:
            BrowserStrings.settingsAccountsTab
        case .general:
            BrowserStrings.settingsGeneralTab
        case .links:
            BrowserStrings.settingsLinksTab
        case .profiles:
            BrowserStrings.settingsProfilesTab
        case .shortcuts:
            BrowserStrings.settingsShortcutsTab
        case .icon:
            BrowserStrings.settingsIconTab
        case .advanced:
            BrowserStrings.settingsAdvancedTab
        }
    }

    var systemImageName: String {
        switch self {
        case .accounts:
            "person.crop.circle"
        case .general:
            "gearshape"
        case .links:
            "link"
        case .profiles:
            "person.2"
        case .shortcuts:
            "keyboard"
        case .icon:
            "app.badge"
        case .advanced:
            "gearshape.2"
        }
    }
}

// MARK: - BrowserSettingsViewController

final class BrowserSettingsViewController: NSViewController, @MainActor SettingsPane, NSSearchFieldDelegate {
    // MARK: Private

    private let model: BrowserChromeModel
    private let preferences: BrowserUserPreferencesStore
    private let shortcutStore: BrowserShortcutStore
    private let profileStore: BrowserProfileStore
    private let currentProfileID: String
    private let accountStore: BrowserAccountStore?
    private let pane: BrowserSettingsPane
    private let canDeleteProfile: (BrowserProfile) -> Bool
    private let openProfile: (BrowserProfile) -> Void
    private let openURL: (URL) -> Void
    private let defaultBrowserService = BrowserDefaultBrowserService()
    private let scrollView = BrowserNativeScrollingStack()
    private let searchField = NSSearchField()
    private var observations = Set<AnyCancellable>()
    private var updateBindings = [() -> Void]()
    /// Each card's dividers, by card, following its rows' visibility.
    private var rowDividers = [ObjectIdentifier: BrowserSettingsRowDividers]()
    private var profileDeleteButtons = [(BrowserProfile, BrowserActionButton)]()
    private let passwordsBody = NSStackView()
    private let addressesBody = NSStackView()
    private let cardsBody = NSStackView()
    private let shortcutsBody = NSStackView()
    private let profilesBody = NSStackView()
    private let accountsBody = NSStackView()
    private let sharedLinksBody = NSStackView()
    private var sharedLinksSection: NSView?
    /// Kept across refreshes, so typing survives the account store's updates.
    private let accountEmailField = NSTextField()
    private let accountCodeField = NSTextField()
    private var isShowingEmailCodeEntry = false
    private let linkRoutesBody = NSStackView()
    private var linkRouteFields = [UUID: NSTextField]()
    private let siteSearchesBody = NSStackView()
    private let sitePermissionsBody = NSStackView()
    private var shownSitePermissions = [BrowserSitePermissionDecision]()
    private let allowedSitesBody = NSStackView()
    private var shownAllowedSites: [String]?
    private var siteSearchFields = [(
        field: NSTextField,
        id: UUID,
        keyPath: WritableKeyPath<BrowserSiteSearch, String>,
    )]()
    private let shortcutMessage = BrowserNativeControls.label("", size: 12, color: .systemRed, wraps: true)
    private let backupMessage = BrowserNativeControls.label("", size: 12, color: .secondaryLabelColor, wraps: true)
    private var recordingCommandID: BrowserCommandID?
    private var profileBackupInProgressID: BrowserProfile.ID?

    // MARK: Internal

    var paneIdentifier: Settings.PaneIdentifier { .init(pane.rawValue) }
    var paneTitle: String { pane.title }
    var toolbarItemIcon: NSImage { NSImage(
        systemSymbolName: pane.systemImageName,
        accessibilityDescription: pane.title,
    ) ?? NSImage() }

    init(
        model: BrowserChromeModel,
        profileStore: BrowserProfileStore,
        currentProfileID: String,
        accountStore: BrowserAccountStore?,
        pane: BrowserSettingsPane,
        canDeleteProfile: @escaping (BrowserProfile) -> Bool = { _ in true },
        openProfile: @escaping (BrowserProfile) -> Void,
        openURL: @escaping (URL) -> Void,
    ) {
        self.model = model
        self.preferences = model.userPreferencesStore
        self.shortcutStore = model.shortcutStore
        self.profileStore = profileStore
        self.currentProfileID = currentProfileID
        self.accountStore = accountStore
        self.pane = pane
        self.canDeleteProfile = canDeleteProfile
        self.openProfile = openProfile
        self.openURL = openURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = BrowserNativeSurface(frame: NSRect(
            x: 0,
            y: 0,
            width: BrowserSettingsLayout.windowWidth,
            height: BrowserSettingsLayout.windowHeight,
        ))
        background.fillColor = .windowBackgroundColor
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.windowWidth),
            background.heightAnchor.constraint(equalToConstant: BrowserSettingsLayout.windowHeight),
        ])
        background.setAccessibilityIdentifier("browser.settings.\(pane.rawValue)")
        scrollView.frame = background.bounds
        scrollView.autoresizingMask = [.width, .height]
        background.addSubview(scrollView)
        view = background
        searchField.placeholderString = BrowserStrings.settingsShortcutsSearchPlaceholder
        searchField.setAccessibilityIdentifier("browser.settings.shortcut-search")
        searchField.delegate = self
        configureAccountFields()
        configureContent()
        observe(preferences.objectWillChange) { [weak self] in self?.syncControls() }
        observe(model.objectWillChange) { [weak self] in self?.syncControls() }
        observe(shortcutStore.objectWillChange) { [weak self] in self?.refreshShortcuts() }
        observe(profileStore.objectWillChange) { [weak self] in self?.refreshProfiles() }
        if let accountStore {
            observe(accountStore.objectWillChange) { [weak self] in
                self?.refreshAccounts()
                self?.syncControls()
            }
        }
        if let shareStore = model.shareStore {
            observe(shareStore.objectWillChange) { [weak self] in self?.refreshSharedLinks() }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if pane == .links {
            // Spaces may have changed since the pane was built.
            refreshLinkRoutes()
        }
        if pane == .accounts, let accountStore, !accountStore.isAuthenticated, accountStore.providers == nil {
            Task { await accountStore.loadProviders() }
        }
        if pane == .accounts, accountStore?.isAuthenticated == true, let shareStore = model.shareStore {
            Task { await shareStore.refresh() }
        }
        syncControls()
    }

    /// What deletion removes and what stays, with Cancel as the default.
    /// Clearing browsing data is the user's choice: the checkbox opens its
    /// page once the account is gone.
    static func accountDeletionAlert() -> (alert: NSAlert, clearBrowsingData: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BrowserStrings.syncAccountDeleteTitle
        alert.informativeText = BrowserStrings.syncAccountDeleteMessage
        let delete = alert.addButton(withTitle: BrowserStrings.syncAccountDeleteConfirm)
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: BrowserStrings.syncAccountDeleteCancel)
        cancel.keyEquivalent = "\r"
        let clearBrowsingData = NSButton(
            checkboxWithTitle: BrowserStrings.syncAccountDeleteClearBrowsingData,
            target: nil,
            action: nil,
        )
        clearBrowsingData.setAccessibilityIdentifier("browser.settings.account.delete.clear-browsing-data")
        alert.accessoryView = clearBrowsingData
        return (alert, clearBrowsingData)
    }

    private static func signInTitle(for provider: BrowserAccountProvider) -> String {
        switch provider {
        case .apple: BrowserStrings.syncAccountContinueWithApple
        case .google: BrowserStrings.syncAccountContinueWithGoogle
        case .github: BrowserStrings.syncAccountContinueWithGitHub
        case .email: BrowserStrings.syncAccountSendCode
        }
    }

    /// The provider's mark before its name; GitHub's follows the text color.
    private static func signInLogo(for provider: BrowserAccountProvider) -> NSImage? {
        let image: NSImage? =
            switch provider {
            case .apple: NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)
            case .google: NSImage(named: "GoogleLogo")
            case .github: NSImage(named: "GitHubLogo")
            default: nil
            }
        guard let image, provider != .apple else { return image }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// The installed app's icon at a badge's size, or the import badge when the app is gone.
    private static func applicationIcon(_ bundleIdentifiers: [String]) -> NSImage {
        let side = BrowserSettingsIcon.side
        guard let url = bundleIdentifiers.lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first
        else {
            return BrowserSettingsIcon("square.and.arrow.down", .systemGray).image
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // App icons leave a margin inside their square; drawn a little larger they sit like the badges.
            icon.draw(in: rect.insetBy(dx: -side * 0.1, dy: -side * 0.1))
            return true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField {
            refreshShortcuts()
        }
        if let field = notification.object as? NSTextField,
           let id = linkRouteFields.first(where: { $0.value === field })?.key
        {
            updateLinkRoute(id) { $0.pattern = field.stringValue }
        }
        if let field = notification.object as? NSTextField,
           let entry = siteSearchFields.first(where: { $0.field === field }),
           let index = preferences.siteSearches.firstIndex(where: { $0.id == entry.id })
        {
            preferences.siteSearches[index][keyPath: entry.keyPath] = field.stringValue
        }
    }

    /// Makes every Shortcuts row, which otherwise appear as they scroll into view.
    func loadAllShortcutRows() {
        for case let list as BrowserShortcutSettingsList in shortcutsBody.arrangedSubviews {
            list.makeAllRows()
        }
    }

    private func observe(_ publisher: ObservableObjectPublisher, action: @escaping () -> Void) {
        publisher.receive(on: RunLoop.main).sink { action() }.store(in: &observations)
    }

    private func syncControls() {
        updateBindings.forEach { $0() }
        refreshSitePermissions()
        refreshAllowedSites()
        for (profile, button) in profileDeleteButtons {
            let isClosed = canDeleteProfile(profile)
            button.isEnabled = profile.id != currentProfileID && !profile.isDefault && isClosed
            button.toolTip = isClosed ? nil : BrowserStrings.sessionRecoveryCloseProfileBeforeDeleting
        }
    }

    private func configureContent() {
        switch pane {
        case .accounts: configureAccounts()
        case .general: configureGeneral()
        case .links: configureLinks()
        case .profiles: configureProfiles()
        case .shortcuts: configureShortcuts()
        case .icon: configureIcon()
        case .advanced: configureAdvanced()
        }
        syncControls()
    }

    private func configureAccounts() {
        let button = BrowserActionButton(BrowserStrings.settingsDefaultBrowserAction) { [weak self] in
            guard let self else { return }
            _ = defaultBrowserService.setAsDefaultBrowser()
            syncControls()
        }
        button.setAccessibilityIdentifier("browser.settings.default-browser")
        updateBindings
            .append { [weak self, weak button] in
                button?.isEnabled = !(self?.defaultBrowserService.isDefaultBrowser ?? true)
            }
        defer { releaseEmailFieldFocus() }
        let sharedLinksSection = section(BrowserStrings.settingsSharedLinksSection, body: sharedLinksBody)
        self.sharedLinksSection = sharedLinksSection
        scrollView.setViews([
            card(accountsBody),
            sharedLinksSection,
            section(
                BrowserStrings.settingsDefaultBrowserSection,
                rows: [row(BrowserStrings.settingsDefaultBrowserPrompt, icon: "default-browser", control: button)],
            ),
        ])
        refreshAccounts()
    }

    private func configureGeneral() {
        let preferences = preferences
        let updateChannelRow = picker(
            "update-channel",
            BrowserStrings.settingsUpdateChannel,
            detail: BrowserStrings.settingsUpdateChannelDetail,
            options: BrowserUpdateChannel.allCases,
            title: { $0.title },
            get: { preferences.updateChannel },
            set: { preferences.updateChannel = $0 },
        )
        updateChannelRow.isHidden = !BrowserHostedService.isEnabled
        scrollView.setViews([
            section(BrowserStrings.settingsGeneralTab, rows: [
                toggle(
                    "automatic-updates",
                    BrowserStrings.settingsAutomaticUpdates,
                    detail: BrowserStrings.settingsAutomaticUpdatesDetail,
                    get: { preferences.automaticUpdatesEnabled },
                    set: { preferences.automaticUpdatesEnabled = $0 },
                ),
                updateChannelRow,
                picker(
                    "appearance",
                    BrowserStrings.settingsAppearance,
                    detail: BrowserStrings.settingsAppearanceDetail,
                    options: BrowserAppearancePreference.allCases,
                    title: { $0.title },
                    get: { preferences.appearancePreference },
                    set: { preferences.appearancePreference = $0 },
                ),
                picker(
                    "sidebar-position",
                    BrowserStrings.settingsSidebarPosition,
                    options: BrowserSidebarPosition.allCases,
                    title: { $0.title },
                    get: { preferences.sidebarPosition },
                    set: { preferences.sidebarPosition = $0 },
                ),
                toggle(
                    "recent-pages-previews",
                    BrowserStrings.settingsRecentPagesPreviews,
                    get: { preferences.recentPagesPreviewsEnabled },
                    set: { preferences.recentPagesPreviewsEnabled = $0 },
                ),
                toggle(
                    "mail-previews",
                    BrowserStrings.settingsMailPreviews,
                    get: { preferences.mailPreviewsEnabled },
                    set: { preferences.mailPreviewsEnabled = $0 },
                ),
                toggle(
                    "folder-previews",
                    BrowserStrings.settingsFolderPreviews,
                    get: { preferences.folderPreviewsEnabled },
                    set: { preferences.folderPreviewsEnabled = $0 },
                ),
                toggle(
                    "warn-before-quitting",
                    BrowserStrings.settingsWarnBeforeQuitting,
                    get: { preferences.warnBeforeQuitting },
                    set: { preferences.warnBeforeQuitting = $0 },
                ),
                toggle(
                    "blurred-background",
                    BrowserStrings.settingsBlurredBackground,
                    get: { preferences.blurredChromeBackgroundEnabled },
                    set: { preferences.blurredChromeBackgroundEnabled = $0 },
                ),
                toggle(
                    "battery-saver",
                    BrowserStrings.settingsBatterySaver,
                    detail: BrowserStrings.settingsBatterySaverDetail,
                    get: { preferences.batterySaverEnabled },
                    set: { preferences.batterySaverEnabled = $0 },
                ),
            ]),
            section(BrowserStrings.settingsPrivacySection, rows: [
                blockerToggle(
                    .ads,
                    "block-ads",
                    BrowserStrings.settingsBlockAds,
                    BrowserStrings.settingsBlockAdsDetail,
                ),
                blockerToggle(
                    .trackers,
                    "block-trackers",
                    BrowserStrings.settingsBlockTrackers,
                    BrowserStrings.settingsBlockTrackersDetail,
                ),
                blockerToggle(
                    .cookieBanners,
                    "block-cookie-banners",
                    BrowserStrings.settingsBlockCookieBanners,
                    BrowserStrings.settingsBlockCookieBannersDetail,
                ),
                filterListsRow(),
            ]),
            section(BrowserStrings.settingsAllowedSites, body: allowedSitesBody),
        ])
    }

    // MARK: Content blocking

    private func blockerToggle(
        _ kind: BrowserFilterListKind,
        _ id: String,
        _ title: String,
        _ detail: String,
    ) -> NSView {
        let preferences = preferences
        return toggle(
            id,
            title,
            detail: detail,
            get: { preferences.contentBlocking.blocks(kind) },
            set: { preferences.contentBlocking.setBlocks(kind, $0) },
        )
    }

    /// The lists' age and Update Now, which downloads them at once.
    private func filterListsRow() -> NSView {
        let updater = BrowserFilterListUpdater.shared
        let status = BrowserNativeControls.label("", size: 12, color: .secondaryLabelColor, wraps: true)
        let button = BrowserActionButton(BrowserStrings.settingsFilterListsUpdateNow) {
            Task { @MainActor in await updater.checkForUpdates(force: true) }
        }
        button.setAccessibilityIdentifier("browser.settings.filter-lists.update")
        let sync = { [weak status, weak button] in
            status?.stringValue =
                if updater.isUpdating {
                    BrowserStrings.settingsFilterListsUpdating
                } else if let date = updater.lastDownloaded {
                    BrowserStrings.settingsFilterListsUpdated(date)
                } else {
                    BrowserStrings.settingsFilterListsBundled
                }
            button?.isEnabled = !updater.isUpdating && BrowserContentBlocker.shared.settings.isEnabled
        }
        updater.changes.receive(on: RunLoop.main).sink { sync() }.store(in: &observations)
        updateBindings.append(sync)
        let label = BrowserNativeControls.stack(
            [BrowserNativeControls.label(BrowserStrings.settingsFilterLists, wraps: true), status],
            spacing: 2,
        )
        return row(label: withIcon("filter-lists", label), control: button)
    }

    /// Sites allowed to show ads, each with Remove. Rebuilt only when they change.
    private func refreshAllowedSites() {
        guard pane == .general else { return }
        let sites = preferences.contentBlocking.allowedSites
        guard sites != shownAllowedSites else { return }
        shownAllowedSites = sites
        let detail = BrowserNativeControls.label(
            BrowserStrings.settingsAllowedSitesDetail,
            size: 12,
            color: .secondaryLabelColor,
            wraps: true,
        )
        let rows = sites.map { site -> NSView in
            let remove = BrowserActionButton(BrowserStrings.settingsAllowedSitesRemove) { [weak self] in
                self?.preferences.contentBlocking.removeAllowedSite(site)
            }
            remove.setAccessibilityIdentifier("browser.settings.allowed-sites.remove")
            return row(label: titleDetail(site), control: remove)
        }
        let empty = BrowserNativeControls.label(
            BrowserStrings.settingsAllowedSitesEmpty,
            size: 12,
            color: .secondaryLabelColor,
        )
        replaceRows(
            [BrowserNativeControls.padded(detail, vertical: 8)]
                + (rows.isEmpty ? [BrowserNativeControls.padded(empty, vertical: 8)] : rows),
            in: allowedSitesBody,
        )
    }

    // MARK: Site permissions

    /// This profile's remembered camera and microphone answers, one row per
    /// site with Forget. Rebuilt only when the answers change.
    private func refreshSitePermissions() {
        guard pane == .advanced else { return }
        let decisions = model.rememberedSitePermissions
        guard decisions != shownSitePermissions || sitePermissionsBody.arrangedSubviews.isEmpty else { return }
        shownSitePermissions = decisions
        let detail = BrowserNativeControls.label(
            BrowserStrings.settingsSitePermissionsDetail,
            size: 12,
            color: .secondaryLabelColor,
            wraps: true,
        )
        var origins = [String]()
        for decision in decisions where !origins.contains(decision.origin) {
            origins.append(decision.origin)
        }
        let rows = origins.map { origin -> NSView in
            let kinds = decisions.filter { $0.origin == origin }
            let state = BrowserStrings.settingsSitePermissionsState(
                camera: kinds.last { $0.kind == .camera }?.allowed,
                microphone: kinds.last { $0.kind == .microphone }?.allowed,
            )
            let host = URLComponents(string: origin)?.host ?? origin
            let forget = BrowserActionButton(BrowserStrings.settingsSitePermissionsForget) { [weak self] in
                self?.model.forgetSitePermissions(forOrigin: origin)
            }
            forget.setAccessibilityIdentifier("browser.settings.site-permissions.forget")
            return row(label: titleDetail(host, detail: state), control: forget)
        }
        let empty = BrowserNativeControls.label(
            BrowserStrings.settingsSitePermissionsEmpty,
            size: 12,
            color: .secondaryLabelColor,
        )
        replaceRows(
            [BrowserNativeControls.padded(detail, vertical: 8)]
                + (rows.isEmpty ? [BrowserNativeControls.padded(empty, vertical: 8)] : rows),
            in: sitePermissionsBody,
        )
    }

    // MARK: Site search

    /// Site searches: one editable row each, then Add, Restore and Import.
    private func refreshSiteSearches() {
        siteSearchFields.removeAll()
        let detail = BrowserNativeControls.label(
            BrowserStrings.settingsSiteSearchDetail,
            size: 12,
            color: .secondaryLabelColor,
            wraps: true,
        )
        let add = BrowserActionButton(BrowserStrings.settingsSiteSearchAdd) { [weak self] in self?.addSiteSearch() }
        add.setAccessibilityIdentifier("browser.settings.site-search.add")
        let restore = BrowserActionButton(BrowserStrings.settingsSiteSearchRestoreDefaults) { [weak self] in
            guard let self else { return }
            let current = preferences.siteSearches
            preferences.siteSearches = current + BrowserSiteSearch.arcDefaults
                .filter { site in
                    !current.contains {
                        $0.normalizedKeyword == site.normalizedKeyword || $0.hasSameAddress(as: site.urlTemplate)
                    }
                }
                .map(\.withNewID)
            refreshSiteSearches()
        }
        restore.setAccessibilityIdentifier("browser.settings.site-search.restore")
        let importButton = NSPopUpButton(frame: .zero, pullsDown: true)
        importButton.addItem(withTitle: BrowserStrings.settingsSiteSearchImport)
        for source in BrowserBookmarkImportSource.allCases
            where source.engine == .chromium && !source.chromiumProfileDirectories().isEmpty
        {
            importButton.addItem(withTitle: source.browserName)
            importButton.lastItem?.representedObject = source.rawValue
            importButton.lastItem?.target = self
            importButton.lastItem?.action = #selector(importSiteSearches(_:))
        }
        importButton.setAccessibilityIdentifier("browser.settings.site-search.import")
        replaceRows(
            [BrowserNativeControls.padded(detail, vertical: 8)]
                + (preferences.siteSearches.isEmpty ? [] : [siteSearchHeader()])
                + preferences.siteSearches.map(siteSearchRow)
                + [BrowserNativeControls.padded(
                    BrowserNativeControls.stack([add, restore, importButton], orientation: .horizontal, spacing: 8),
                    vertical: 8,
                )],
            in: siteSearchesBody,
        )
    }

    private func addSiteSearch() {
        preferences.siteSearches.append(BrowserSiteSearch(name: "", keyword: "", urlTemplate: ""))
        refreshSiteSearches()
        if let id = preferences.siteSearches.last?.id,
           let field = siteSearchFields.first(where: { $0.id == id })?.field
        {
            view.window?.makeFirstResponder(field)
        }
    }

    @objc private func importSiteSearches(_ sender: NSMenuItem) {
        guard let source = (sender.representedObject as? String).flatMap(BrowserBookmarkImportSource.init) else {
            return
        }
        let message: String
        if let imported = BrowserSiteSearchImport.load(from: source) {
            preferences.siteSearches = BrowserSiteSearchImport.merge(imported, into: preferences.siteSearches)
            refreshSiteSearches()
            message = imported.isEmpty
                ? BrowserStrings.settingsSiteSearchImportNothing
                : BrowserStrings.settingsSiteSearchImportResult(imported.count)
        } else {
            message = BrowserStrings.settingsSiteSearchImportMissing
        }
        let alert = NSAlert()
        alert.messageText = BrowserStrings.settingsSiteSearchTitle
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Column titles above the site searches, at the rows' widths.
    private func siteSearchHeader() -> NSView {
        func title(_ text: String, width: CGFloat?) -> NSTextField {
            let label = BrowserNativeControls.label(text, size: 11, weight: .medium, color: .tertiaryLabelColor)
            if let width {
                label.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            return label
        }
        let row = BrowserNativeControls.stack([
            title(BrowserStrings.settingsSiteSearchName, width: BrowserSettingsLayout.siteSearchNameWidth),
            title(BrowserStrings.settingsSiteSearchKeyword, width: BrowserSettingsLayout.siteSearchKeywordWidth),
            title(BrowserStrings.settingsSiteSearchURL, width: nil),
        ], orientation: .horizontal, spacing: BrowserSettingsLayout.siteSearchColumnSpacing)
        return BrowserNativeControls.padded(row, vertical: 6)
    }

    /// One site search: its name, its shortcut in a tag and its address,
    /// each edited in place; borderless until focused, in fixed columns.
    private func siteSearchRow(_ site: BrowserSiteSearch) -> NSView {
        let id = site.id
        func field(
            _ value: String,
            placeholder: String,
            keyPath: WritableKeyPath<BrowserSiteSearch, String>,
            identifier: String,
        ) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.delegate = self
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.setAccessibilityIdentifier("browser.settings.site-search.\(identifier)")
            siteSearchFields.append((field, id, keyPath))
            return field
        }
        let name = field(
            site.name,
            placeholder: BrowserStrings.settingsSiteSearchName,
            keyPath: \.name,
            identifier: "name",
        )
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.siteSearchNameWidth).isActive = true
        let keyword = field(
            site.keyword,
            placeholder: BrowserStrings.settingsSiteSearchKeyword,
            keyPath: \.keyword,
            identifier: "keyword",
        )
        keyword.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let tag = BrowserNativeSurface()
        tag.fillColor = .quaternaryLabelColor
        tag.strokeWidth = 0
        tag.cornerRadius = 6
        tag.addSubview(keyword)
        keyword.translatesAutoresizingMaskIntoConstraints = false
        tag.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tag.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.siteSearchKeywordWidth),
            keyword.leadingAnchor.constraint(equalTo: tag.leadingAnchor, constant: 6),
            keyword.trailingAnchor.constraint(equalTo: tag.trailingAnchor, constant: -6),
            keyword.topAnchor.constraint(equalTo: tag.topAnchor, constant: 3),
            keyword.bottomAnchor.constraint(equalTo: tag.bottomAnchor, constant: -3),
        ])
        let url = field(
            site.urlTemplate,
            placeholder: BrowserStrings.settingsSiteSearchURL,
            keyPath: \.urlTemplate,
            identifier: "url",
        )
        url.font = .systemFont(ofSize: 12)
        url.textColor = .secondaryLabelColor
        url.lineBreakMode = .byTruncatingMiddle
        url.setContentHuggingPriority(.defaultLow, for: .horizontal)
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let remove = BrowserActionButton("") { [weak self] in
            self?.preferences.siteSearches.removeAll { $0.id == id }
            self?.refreshSiteSearches()
        }
        remove.image = NSImage(
            systemSymbolName: "minus.circle",
            accessibilityDescription: BrowserStrings.settingsSiteSearchRemove,
        )
        remove.contentTintColor = .secondaryLabelColor
        remove.isBordered = false
        remove.setContentHuggingPriority(.required, for: .horizontal)
        remove.toolTip = BrowserStrings.settingsSiteSearchRemove
        remove.setAccessibilityIdentifier("browser.settings.site-search.remove")
        return BrowserNativeControls.padded(
            BrowserNativeControls.stack(
                [name, tag, url, remove],
                orientation: .horizontal,
                spacing: BrowserSettingsLayout.siteSearchColumnSpacing,
            ),
            vertical: 6,
        )
    }

    /// Links pane: the small window, Peek and link routes.
    private func configureLinks() {
        let preferences = preferences
        scrollView.setViews([
            section(BrowserStrings.settingsSmallWindowSection, rows: [
                toggle(
                    "little-arc",
                    BrowserStrings.settingsLittleArc,
                    detail: BrowserStrings.settingsLittleArcDetail,
                    get: { preferences.littleArcEnabled },
                    set: { preferences.littleArcEnabled = $0 },
                ),
                toggle(
                    "little-window-option-command-click",
                    BrowserStrings.settingsLittleWindowOptionCommandClick,
                    get: { preferences.opensOptionCommandClicksInLittleWindow },
                    set: { preferences.opensOptionCommandClicksInLittleWindow = $0 },
                ),
                toggle(
                    "little-window-any-app",
                    BrowserStrings.settingsLittleWindowFromAnyApp,
                    get: { preferences.opensLittleWindowFromAnyApp },
                    set: { preferences.opensLittleWindowFromAnyApp = $0 },
                ),
                picker(
                    "small-window-lifetime",
                    BrowserStrings.settingsSmallWindowLifetime,
                    options: BrowserSmallWindowLifetime.allCases,
                    title: { $0.title },
                    get: { preferences.smallWindowLifetime },
                    set: { preferences.smallWindowLifetime = $0 },
                ),
            ]),
            section(BrowserStrings.settingsPeekSection, rows: [
                toggle(
                    "peek",
                    BrowserStrings.settingsPeek,
                    detail: BrowserStrings.settingsPeekDetail,
                    get: { preferences.peekEnabled },
                    set: { preferences.peekEnabled = $0 },
                ),
                toggle(
                    "peek-other-sites",
                    BrowserStrings.settingsPeekOtherSites,
                    detail: BrowserStrings.settingsPeekOtherSitesDetail,
                    get: { preferences.peeksLinksToOtherSites },
                    set: { preferences.peeksLinksToOtherSites = $0 },
                ),
            ]),
            section(BrowserStrings.settingsLinkRoutesTitle, body: linkRoutesBody),
        ])
        refreshLinkRoutes()
    }

    // MARK: Link routes

    /// Link routes: one row per rule, in order, then Add Rule.
    private func refreshLinkRoutes() {
        linkRouteFields.removeAll()
        let detail = BrowserNativeControls.label(
            BrowserStrings.settingsLinkRoutesDetail,
            size: 12,
            color: .secondaryLabelColor,
            wraps: true,
        )
        let add = BrowserActionButton(BrowserStrings.settingsLinkRouteAdd) { [weak self] in self?.addLinkRoute() }
        add.setAccessibilityIdentifier("browser.settings.link-routes.add")
        replaceRows(
            [BrowserNativeControls.padded(detail, vertical: 8)]
                + preferences.linkRoutes.map(linkRouteRow)
                + [BrowserNativeControls.padded(add, vertical: 8)],
            in: linkRoutesBody,
        )
    }

    /// This profile's Spaces, then the small window.
    private func linkRouteDestinations() -> [(title: String, destination: BrowserLinkRoute.Destination)] {
        model.spaces.map { ($0.title, .space(profileID: currentProfileID, spaceID: $0.id)) }
            + [(BrowserStrings.settingsLinkRouteLittleWindow, .littleWindow)]
    }

    private func addLinkRoute() {
        let space = model.spaces.first { $0.id == model.selectedSpaceID } ?? model.spaces.first
        preferences.linkRoutes.append(BrowserLinkRoute(
            destination: space.map { .space(profileID: currentProfileID, spaceID: $0.id) } ?? .littleWindow,
            spaceTitle: space?.title,
        ))
        refreshLinkRoutes()
        if let id = preferences.linkRoutes.last?.id, let field = linkRouteFields[id] {
            view.window?.makeFirstResponder(field)
        }
    }

    private func updateLinkRoute(_ id: UUID, _ change: (inout BrowserLinkRoute) -> Void) {
        guard let index = preferences.linkRoutes.firstIndex(where: { $0.id == id }) else { return }
        change(&preferences.linkRoutes[index])
    }

    private func linkRouteRow(_ route: BrowserLinkRoute) -> NSView {
        let id = route.id
        let matches = BrowserLinkRoute.Match.allCases
        let match = BrowserActionPopUpButton(titles: matches.map { match in
            switch match {
            case .site: BrowserStrings.settingsLinkRouteSite
            case .contains: BrowserStrings.settingsLinkRouteContains
            }
        })
        match.selectItem(at: matches.firstIndex(of: route.match) ?? 0)
        match.onChange = { [weak self] index in
            guard matches.indices.contains(index) else { return }
            self?.updateLinkRoute(id) { $0.match = matches[index] }
        }
        match.setAccessibilityIdentifier("browser.settings.link-routes.match")

        let field = NSTextField(string: route.pattern)
        field.placeholderString = BrowserStrings.settingsLinkRoutePatternPlaceholder
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        field.setAccessibilityIdentifier("browser.settings.link-routes.pattern")
        linkRouteFields[id] = field

        var destinations = linkRouteDestinations()
        if !destinations.contains(where: { $0.destination == route.destination }) {
            destinations.insert((unavailableSpaceTitle(route), route.destination), at: 0)
        }
        let destination = BrowserActionPopUpButton(titles: destinations.map(\.title))
        destination.selectItem(at: destinations.firstIndex { $0.destination == route.destination } ?? 0)
        destination.onChange = { [weak self] index in
            guard destinations.indices.contains(index) else { return }
            let chosen = destinations[index]
            self?.updateLinkRoute(id) { route in
                guard chosen.destination != route.destination else { return }
                route.destination = chosen.destination
                if case .space = chosen.destination {
                    route.spaceTitle = chosen.title
                }
            }
        }
        destination.setAccessibilityIdentifier("browser.settings.link-routes.destination")

        let remove = BrowserActionButton("") { [weak self] in
            self?.preferences.linkRoutes.removeAll { $0.id == id }
            self?.refreshLinkRoutes()
        }
        remove.image = NSImage(
            systemSymbolName: "minus.circle",
            accessibilityDescription: BrowserStrings.settingsLinkRouteRemove,
        )
        remove.isBordered = false
        remove.toolTip = BrowserStrings.settingsLinkRouteRemove
        remove.setAccessibilityIdentifier("browser.settings.link-routes.remove")

        let opensIn = BrowserNativeControls.label(
            BrowserStrings.settingsLinkRouteOpensIn,
            size: 12,
            color: .secondaryLabelColor,
        )
        return BrowserNativeControls.padded(
            BrowserNativeControls.stack(
                [match, field, opensIn, destination, remove],
                orientation: .horizontal,
                spacing: 8,
            ),
            vertical: 6,
        )
    }

    private func unavailableSpaceTitle(_ route: BrowserLinkRoute) -> String {
        guard case .space(let profileID, _) = route.destination, profileID != currentProfileID else {
            return BrowserStrings.settingsLinkRouteUnavailableSpace(route.spaceTitle, profileName: nil)
        }
        let profile = profileStore.profiles.first { $0.id == profileID }
        return BrowserStrings.settingsLinkRouteUnavailableSpace(
            route.spaceTitle,
            profileName: profile?.displayName ?? profileID,
        )
    }

    /// The chosen folder, abbreviated, with Choose… and, for a custom folder,
    /// Use Downloads. A folder that no longer exists shows the fallback.
    private func downloadLocationRow() -> NSView {
        let preferences = preferences
        let path = BrowserNativeControls.label("", size: 12, color: .secondaryLabelColor)
        path.lineBreakMode = .byTruncatingMiddle
        path.setAccessibilityIdentifier("browser.settings.download-location.path")
        let choose = BrowserActionButton(BrowserStrings.settingsDownloadLocationChoose) {
            let current = BrowserDownloadLocation.directory(customPath: preferences.downloadDirectoryPath)
            if let url = BrowserDownloadLocationPanel.chooseDirectory(startingAt: current) {
                preferences.downloadDirectoryPath = url.path
            }
        }
        choose.setAccessibilityIdentifier("browser.settings.download-location.choose")
        let reset = BrowserActionButton(BrowserStrings.settingsDownloadLocationReset) {
            preferences.downloadDirectoryPath = nil
        }
        reset.setAccessibilityIdentifier("browser.settings.download-location.reset")
        updateBindings.append { [weak path, weak reset] in
            let directory = BrowserDownloadLocation.directory(customPath: preferences.downloadDirectoryPath)
            path?.stringValue = (directory.path as NSString).abbreviatingWithTildeInPath
            reset?.isHidden = preferences.downloadDirectoryPath == nil
        }
        let label = BrowserNativeControls.stack([
            BrowserNativeControls.label(BrowserStrings.settingsDownloadLocation, wraps: true),
            path,
        ], spacing: 2)
        return row(
            label: withIcon("download-location", label),
            control: BrowserNativeControls.stack([reset, choose], orientation: .horizontal, spacing: 8),
        )
    }

    private func automaticArchivalRows() -> [NSView] {
        let model = model
        let localRow = picker(
            "temporary-tab-lifetime",
            BrowserStrings.settingsTemporaryTabsLifetimeLabel,
            options: [nil] + BrowserTemporaryTabLifetime.allCases.map(Optional.some),
            title: { lifetime in
                lifetime.map(BrowserStrings.title(for:)) ?? BrowserStrings.settingsAutomaticArchivalNever
            },
            get: { model.localAutomaticArchivalOff ? nil : model.temporaryTabLifetime },
            set: { [weak self] lifetime in
                model.setLocalAutomaticArchival(lifetime: lifetime)
                self?.syncControls()
            },
            enabled: { !model.usesSynchronizedAutomaticArchival },
        )
        let synchronizedRow = picker(
            "automatic-tab-archival",
            BrowserStrings.settingsTemporaryTabsLifetimeLabel,
            options: [nil] + BrowserTemporaryTabLifetime.allCases.map(Optional.some),
            title: { lifetime in
                guard let lifetime else { return BrowserStrings.settingsAutomaticArchivalOff }
                return lifetime == .thirtyDays
                    ? BrowserStrings.settingsAutomaticArchivalThirtyDays
                    : BrowserStrings.title(for: lifetime)
            },
            get: { model.automaticTabArchivalEnabled ? model.temporaryTabLifetime : nil },
            set: { [weak self] lifetime in
                _ = model.setAutomaticTabArchival(lifetime: lifetime)
                self?.syncControls()
            },
            enabled: { model.canConfigureAutomaticTabArchival },
        )
        let description = BrowserNativeControls.label("", size: 12, color: .secondaryLabelColor, wraps: true)
        let error = BrowserNativeControls.label("", size: 12, color: .systemRed, wraps: true)
        let retry = BrowserActionButton(BrowserStrings.sessionRecoveryRetry) { [weak self] in
            _ = model.retryAutomaticTabArchivalSettings()
            self?.syncControls()
        }
        description.setAccessibilityIdentifier("browser.settings.temporary-tab-availability")
        error.setAccessibilityIdentifier("browser.settings.temporary-tab-error")
        retry.setAccessibilityIdentifier("browser.settings.automatic-tab-archival-retry")
        let errorRow = BrowserNativeControls.stack([error, retry], orientation: .horizontal, spacing: 12)
        updateBindings.append { [
            weak model,
            weak localRow,
            weak synchronizedRow,
            weak description,
            weak error,
            weak retry,
            weak errorRow,
        ] in
            guard let model else { return }
            let synchronized = model.usesSynchronizedAutomaticArchival
            localRow?.isHidden = synchronized
            synchronizedRow?.isHidden = !synchronized
            description?.stringValue = synchronized
                ? BrowserStrings.settingsAutomaticArchivalSyncDescription
                : BrowserStrings.settingsTemporaryTabsDescription
            error?.stringValue = model.automaticArchivalSettingsError ?? ""
            errorRow?.isHidden = model.automaticArchivalSettingsError == nil
            retry?.isEnabled = model.canRetryAutomaticTabArchivalSettings
        }
        return [localRow, synchronizedRow, description, errorRow]
    }

    private func configureProfiles() {
        let preferences = preferences
        backupMessage.isHidden = true
        let newProfile = BrowserActionButton(BrowserStrings.settingsNewProfile) { [weak self] in
            guard let self else { return }
            openProfile(profileStore.createProfile())
        }
        newProfile.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newProfile.imagePosition = .imageLeading
        newProfile.setAccessibilityIdentifier("browser.settings.new-profile")
        scrollView.setViews([
            BrowserNativeControls.label(BrowserStrings.settingsProfilesIntro, color: .secondaryLabelColor, wraps: true),
            section(BrowserStrings.settingsProfilesTab, body: profilesBody),
            backupMessage,
            BrowserNativeControls.stack([newProfile], orientation: .horizontal),
            section(BrowserStrings.settingsSearch, rows: [
                picker(
                    "search-engine",
                    BrowserStrings.settingsSearchEngine,
                    options: BrowserSearchEngine.allCases,
                    title: { $0.title },
                    get: { preferences.searchEngine },
                    set: { preferences.searchEngine = $0 },
                ),
                toggle(
                    "search-suggestions",
                    BrowserStrings.settingsSearchSuggestions,
                    get: { preferences.searchEngineSuggestionsEnabled },
                    set: { preferences.searchEngineSuggestionsEnabled = $0 },
                ),
                toggle(
                    "ai-search-suggestion",
                    BrowserStrings.settingsShowAISearchSuggestion,
                    get: { preferences.showsAISearchSuggestion },
                    set: { preferences.showsAISearchSuggestion = $0 },
                ),
                picker(
                    "ai-search-provider",
                    BrowserStrings.settingsAISearchProvider,
                    options: BrowserAISearchProvider.allCases,
                    title: { $0.title },
                    get: { preferences.aiSearchProvider },
                    set: { preferences.aiSearchProvider = $0 },
                ),
                link(BrowserStrings.settingsManageSearch, url: BrowserSettingsRoute.searchEnginesURL),
            ]),
            section(BrowserStrings.settingsSiteSearchTitle, body: siteSearchesBody),
            section(BrowserStrings.settingsTemporaryTabsTitle, rows: automaticArchivalRows()),
            section(BrowserStrings.settingsNewDocumentsTitle, rows: [
                picker(
                    "new-documents-app",
                    BrowserStrings.settingsNewDocumentsApp,
                    options: BrowserNewDocumentsApp.allCases,
                    title: { $0.title },
                    get: { preferences.newDocumentsApp },
                    set: { preferences.newDocumentsApp = $0 },
                ),
            ]),
            section(BrowserStrings.settingsDownloadsTitle, rows: [downloadLocationRow()]),
            section(BrowserStrings.settingsPasswords, body: passwordsBody),
            section(BrowserStrings.settingsAddresses, body: addressesBody),
            section(BrowserStrings.settingsCards, body: cardsBody),
            section(BrowserStrings.settingsYourData, rows: [
                link(BrowserStrings.settingsPrivacyAndSecurity, url: BrowserSettingsRoute.privacyURL),
                link(BrowserStrings.settingsNotifications, url: BrowserSettingsRoute.notificationsURL),
                link(BrowserStrings.settingsClearBrowsingData, url: BrowserSettingsRoute.privacyURL),
            ]),
        ])
        refreshSiteSearches()
        refreshPasswords()
        refreshAddresses()
        refreshCards()
        refreshProfiles()
    }

    private func refreshCards() {
        let store = model.cardStore
        let cards = store?.cards() ?? []
        guard !cards.isEmpty else {
            replaceRows(
                [BrowserNativeControls.label(
                    BrowserStrings.cardNoneSaved,
                    size: 13,
                    weight: .regular,
                    color: .secondaryLabelColor,
                )],
                in: cardsBody,
            )
            return
        }
        replaceRows(cards.map { card in
            let text = BrowserNativeControls.label(card.summary, size: 13, weight: .regular, color: .labelColor)
            let delete = BrowserActionButton(BrowserStrings.passwordDelete) { [weak self] in
                store?.setCards(cards.filter { $0 != card })
                self?.refreshCards()
            }
            return BrowserNativeControls.stack([text, NSView(), delete], orientation: .horizontal, spacing: 8)
        }, in: cardsBody)
    }

    private func refreshAddresses() {
        let store = model.addressStore
        let addresses = store?.addresses() ?? []
        guard !addresses.isEmpty else {
            replaceRows(
                [BrowserNativeControls.label(
                    BrowserStrings.addressNoneSaved,
                    size: 13,
                    weight: .regular,
                    color: .secondaryLabelColor,
                )],
                in: addressesBody,
            )
            return
        }
        replaceRows(addresses.map { address in
            let text = BrowserNativeControls.label(address.summary, size: 13, weight: .regular, color: .labelColor)
            let delete = BrowserActionButton(BrowserStrings.passwordDelete) { [weak self] in
                store?.setAddresses(addresses.filter { $0 != address })
                self?.refreshAddresses()
            }
            return BrowserNativeControls.stack([text, NSView(), delete], orientation: .horizontal, spacing: 8)
        }, in: addressesBody)
    }

    private func refreshPasswords() {
        let store = model.passwordStore
        let logins = store?.allLogins() ?? []
        guard !logins.isEmpty else {
            replaceRows(
                [BrowserNativeControls.label(
                    BrowserStrings.passwordNoneSaved,
                    size: 13,
                    weight: .regular,
                    color: .secondaryLabelColor,
                )],
                in: passwordsBody,
            )
            return
        }
        replaceRows(logins.map { passwordRow($0, store: store) }, in: passwordsBody)
    }

    /// A saved sign-in: the site's icon, host and username, then Copy and Edit.
    private func passwordRow(_ login: BrowserSavedLogin, store: BrowserPasswordStoring?) -> NSView {
        let favicon = BrowserFaviconNSView()
        favicon.update(
            url: BrowserFaviconCache.pageIconURL(forPageURLString: login.origin),
            pageURLString: login.origin,
        )
        favicon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            favicon.widthAnchor.constraint(equalToConstant: BrowserSettingsIcon.side),
            favicon.heightAnchor.constraint(equalToConstant: BrowserSettingsIcon.side),
        ])
        let label = BrowserNativeControls.stack(
            [favicon, titleDetail(login.host, detail: login.username.isEmpty ? nil : login.username)],
            orientation: .horizontal,
            spacing: 10,
        )
        label.alignment = .centerY
        let copy = BrowserActionButton("") {
            guard let password = store?.password(for: login) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
        }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: BrowserStrings.passwordCopy)
        copy.imagePosition = .imageOnly
        copy.toolTip = BrowserStrings.passwordCopy
        copy.setAccessibilityLabel(BrowserStrings.passwordCopy)
        let edit = BrowserActionButton(BrowserStrings.passwordEdit) { [weak self] in
            self?.editPassword(login)
        }
        edit.setAccessibilityLabel("\(BrowserStrings.passwordEdit) \(login.host)")
        let controls = BrowserNativeControls.stack([copy, edit], orientation: .horizontal, spacing: 8)
        return row(label: label, control: controls)
    }

    /// Asks for Touch ID or the Mac's password, then opens the sign-in in a sheet to change or delete it.
    private func editPassword(_ login: BrowserSavedLogin) {
        guard let store = model.passwordStore else { return }
        Task { @MainActor [weak self] in
            let reason = String(format: BrowserStrings.passwordEditReason, login.host)
            guard await BrowserCardAuthentication.ask(reason: reason),
                  let password = store.password(for: login)
            else { return }
            self?.presentPasswordEditor(login, password: password, store: store)
        }
    }

    private func presentPasswordEditor(_ login: BrowserSavedLogin, password: String, store: BrowserPasswordStoring) {
        guard let window = view.window else { return }
        let username = NSTextField(string: login.username)
        let secure = NSSecureTextField(string: password)
        let plain = NSTextField(string: password)
        plain.isHidden = true
        for field in [username, secure, plain] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        let passwordField = NSView()
        for field in [secure, plain] {
            passwordField.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: passwordField.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: passwordField.trailingAnchor),
                field.topAnchor.constraint(equalTo: passwordField.topAnchor),
                field.bottomAnchor.constraint(equalTo: passwordField.bottomAnchor),
            ])
        }
        let show = NSButton(checkboxWithTitle: BrowserStrings.passwordShow, target: nil, action: nil)
        let toggle = BrowserPasswordVisibilityToggle(secure: secure, plain: plain)
        show.target = toggle
        show.action = #selector(BrowserPasswordVisibilityToggle.toggle(_:))
        let grid = NSGridView(views: [
            [BrowserNativeControls.label(BrowserStrings.passwordUsername), username],
            [BrowserNativeControls.label(BrowserStrings.passwordPassword), passwordField],
            [NSGridCell.emptyContentView, show],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame.size = grid.fittingSize

        let alert = NSAlert()
        alert.messageText = String(format: BrowserStrings.passwordEditTitle, login.host)
        alert.accessoryView = grid
        alert.addButton(withTitle: BrowserStrings.passwordSave)
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        let delete = alert.addButton(withTitle: BrowserStrings.passwordDelete)
        delete.hasDestructiveAction = true
        alert.window.initialFirstResponder = secure
        alert.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(toggle) {}
            switch response {
            case .alertFirstButtonReturn:
                let newPassword = toggle.isShowing ? plain.stringValue : secure.stringValue
                let newUsername = username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if store.update(login, username: newUsername, password: newPassword) == nil {
                    let failure = NSAlert()
                    failure.messageText = BrowserStrings.passwordUsernameTaken
                    failure.beginSheetModal(for: window)
                }
            case .alertThirdButtonReturn:
                store.delete(login)
            default:
                return
            }
            self?.refreshPasswords()
        }
    }

    private func configureIcon() {
        let preferences = preferences
        let body = NSStackView()
        func rows() -> [NSView] {
            BrowserAppIcon.choices.map { icon in
                let selected = preferences.appIcon == icon
                let choose = { [weak self] in
                    preferences.appIcon = icon
                    icon.apply()
                    self?.configureContent()
                }
                let radio = BrowserActionButton("", action: choose)
                radio.setButtonType(.radio)
                radio.state = selected ? .on : .off
                let image = NSImageView(image: icon.image ?? NSImage())
                image.imageScaling = .scaleProportionallyUpOrDown
                image.widthAnchor.constraint(equalToConstant: 52).isActive = true
                image.heightAnchor.constraint(equalToConstant: 52).isActive = true
                let name = BrowserNativeControls.label(icon.title, size: 13, weight: .medium, color: .labelColor)
                // A click anywhere on the row picks the icon, not only on its radio button.
                let row = BrowserSettingsClickableRow(onClick: choose)
                let content = BrowserNativeControls.stack([radio, image, name], orientation: .horizontal, spacing: 12)
                row.addSubview(content)
                content.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    content.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
                    content.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
                    content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
                ])
                return row
            }
        }
        let section = section(BrowserStrings.settingsIconTab, body: body)
        replaceRows(rows(), in: body)
        scrollView.setViews([section])
    }

    private func configureShortcuts() {
        let reset = BrowserActionButton(BrowserStrings.settingsShortcutResetAll) { [weak self] in
            self?.shortcutStore.resetAllShortcuts()
            self?.recordingCommandID = nil
            self?.shortcutMessage.isHidden = true
            self?.refreshShortcuts()
        }
        let extensions = BrowserActionButton(BrowserStrings.settingsExtensionShortcuts) { [weak self] in
            self?.openURL(BrowserSettingsRoute.extensionShortcutsURL)
        }
        let header = BrowserNativeControls.stack(
            [searchField, reset, extensions],
            orientation: .horizontal,
            spacing: 12,
        )
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shortcutMessage.isHidden = true
        scrollView.setViews([
            header,
            shortcutMessage,
            section(BrowserStrings.settingsShortcutsTab, body: shortcutsBody),
        ])
        refreshShortcuts()
    }

    private func configureAdvanced() {
        let preferences = preferences
        let exportData = BrowserActionButton(BrowserStrings.settingsExportData) { [weak self] in
            guard let self, let window = view.window else { return }
            BrowserSessionRecoveryExporter.present(model: model, window: window)
        }
        exportData.setAccessibilityIdentifier("browser.settings.export-data")
        scrollView.setViews([
            section(BrowserStrings.settingsAdvancedTab, rows: [
                toggle(
                    "sound-effects",
                    BrowserStrings.settingsSoundEffects,
                    get: { preferences.soundEffectsEnabled },
                    set: { preferences.soundEffectsEnabled = $0 },
                ),
                toggle(
                    "haptic-feedback",
                    BrowserStrings.settingsHapticFeedback,
                    get: { preferences.hapticFeedbackEnabled },
                    set: { preferences.hapticFeedbackEnabled = $0 },
                ),
                toggle(
                    "restore-windows",
                    BrowserStrings.settingsRestoreWindows,
                    get: { preferences.restoreWindowsOnLaunch },
                    set: { preferences.restoreWindowsOnLaunch = $0 },
                ),
                toggle(
                    "confirm-profile-moves",
                    BrowserStrings.settingsConfirmProfileMoves,
                    get: { preferences.confirmsProfileMoves },
                    set: { preferences.confirmsProfileMoves = $0 },
                ),
                toggle(
                    "picture-in-picture",
                    BrowserStrings.settingsPictureInPicture,
                    get: { preferences.pictureInPictureEnabled },
                    set: { preferences.pictureInPictureEnabled = $0 },
                ),
                toggle(
                    "agent-access",
                    BrowserStrings.settingsAgentAccess,
                    detail: BrowserStrings.settingsAgentAccessDetail,
                    get: { preferences.agentAccessEnabled },
                    set: { preferences.agentAccessEnabled = $0 },
                ),
                toggle(
                    "window-dragging-from-page-top",
                    BrowserStrings.settingsWindowDraggingFromPageTop,
                    get: { preferences.windowDraggingFromPageTopEnabled },
                    set: { preferences.windowDraggingFromPageTopEnabled = $0 },
                ),
                toggle(
                    "bookmarks-bar",
                    BrowserStrings.settingsShowBookmarksBar,
                    get: { preferences.bookmarksBarVisible },
                    set: { preferences.bookmarksBarVisible = $0 },
                ),
                toggle(
                    "toolbar-full-url",
                    BrowserStrings.settingsToolbarFullURL,
                    get: { preferences.siteToolbarShowsFullURL },
                    set: { preferences.siteToolbarShowsFullURL = $0 },
                ),
                toggle(
                    "share-theme-with-websites",
                    BrowserStrings.settingsShareThemeWithWebsites,
                    get: { preferences.sharesThemeWithWebsites },
                    set: { preferences.sharesThemeWithWebsites = $0 },
                ),
            ]),
            section(BrowserStrings.settingsProtectedVideoSection, rows: [
                toggle(
                    "streaming-in-webkit",
                    BrowserStrings.settingsStreamingInWebKit,
                    detail: BrowserStrings.settingsStreamingInWebKitDetail,
                    get: { BrowserPageEnginePolicy.movesProtectedVideoToWebKit },
                    set: { BrowserPageEnginePolicy.movesProtectedVideoToWebKit = $0 },
                ),
                toggle(
                    "fairplay-in-chromium",
                    BrowserStrings.settingsFairPlayInChromium,
                    detail: BrowserStrings.settingsFairPlayInChromiumDetail,
                    get: { BrowserPageEnginePolicy.playsProtectedMediaInChromium },
                    set: { BrowserPageEnginePolicy.playsProtectedMediaInChromium = $0 },
                ),
                row(
                    BrowserStrings.settingsSiteEnginesResetDetail,
                    icon: "site-engines-reset",
                    control: BrowserActionButton(BrowserStrings.settingsSiteEnginesReset) {
                        BrowserPageEnginePolicy.resetSiteEngines()
                    },
                ),
            ]),
            section(
                BrowserStrings.settingsEngineSection,
                rows: [engineRow(), webKitEngineRow(), ladybirdEngineRow()],
            ),
            section(BrowserStrings.settingsSitePermissionsTitle, body: sitePermissionsBody),
            section(BrowserStrings.settingsBoostsTitle, rows: [
                toggle(
                    "boosts",
                    BrowserStrings.settingsBoostsEnabled,
                    detail: BrowserStrings.settingsBoostsDetail,
                    get: { preferences.boostsEnabled },
                    set: { preferences.boostsEnabled = $0 },
                ),
            ]),
            section(
                BrowserStrings.bookmarksImport,
                rows: [arcSidebarImportRow()] + BrowserBookmarkImportSource.allCases
                    .filter { source in
                        source.importsFromExportArchive || !source.importProfiles().isEmpty
                    }
                    .map { source in
                        importRow(
                            source.browserName,
                            bundleIdentifiers: source.bundleIdentifiers,
                            id: "import-\(source.rawValue)",
                        ) { [weak self] in
                            guard let self else { return }
                            if source == .safari {
                                guard let url = BrowserSafariBookmarkImportPanel.chooseSourceURL() else { return }
                                _ = model.bookmarksModel.importSafariBookmarks(from: url)
                            } else {
                                _ = model.importBookmarks(from: source)
                            }
                        }
                    },
            ),
            section(BrowserStrings.settingsAdvancedTab, rows: [
                link(BrowserStrings.settingsMoreSettings, url: BrowserSettingsRoute.rootURL),
                link(BrowserStrings.settingsTranslateSitePrompts, url: BrowserSettingsRoute.languageURL),
                row(BrowserStrings.settingsExportDataDetail, control: exportData),
            ]),
        ])
    }

    /// The Chrome engine instead of CEF, from the next launch. Off and dimmed in a build without its framework,
    /// and dimmed while WebKit or Ladybird draws every page, which keeps this choice for when it is turned off.
    private func engineRow() -> NSView {
        let available = BrowserEngineChoice.isChromeEngineAvailable && BrowserEngineChoice.isCEFAvailable
        let control = BrowserActionToggle()
        control.setAccessibilityLabel(BrowserStrings.settingsChromeEngine)
        control.setAccessibilityIdentifier("browser.settings.chrome-engine")
        control.onChange = { [weak self] isOn in
            BrowserEngineChoice.setPreferredChromiumEngine(isOn ? .chrome : .cef)
            self?.offerRelaunchForEngineChange()
        }
        updateBindings.append { [weak control] in
            let webKit = BrowserEngineChoice.isWebKitPreferred() || BrowserEngineChoice.isLadybirdPreferred()
            control?.isEnabled = available && !webKit
            control?.state = available && !webKit && BrowserEngineChoice.preferredChromiumEngine() == .chrome
                ? .on
                : .off
        }
        let detail = available ? BrowserStrings.settingsChromeEngineDetail : BrowserStrings.settingsChromeEngineMissing
        return row(BrowserStrings.settingsChromeEngine, detail: detail, icon: "chrome-engine", control: control)
    }

    /// WebKit for every page, with no Chromium loaded, from the next launch. A separate toggle: off, the app goes
    /// back to CEF or Chrome as chosen above. On and dimmed in a build without CEF, which runs on WebKit only.
    private func webKitEngineRow() -> NSView {
        let cefAvailable = BrowserEngineChoice.isCEFAvailable
        let control = BrowserActionToggle()
        control.setAccessibilityLabel(BrowserStrings.settingsWebKitEngine)
        control.setAccessibilityIdentifier("browser.settings.webkit-engine")
        control.isEnabled = cefAvailable
        control.onChange = { [weak self] isOn in
            BrowserEngineChoice.setWebKitPreferred(isOn)
            self?.syncControls()
            self?.offerRelaunchForEngineChange()
        }
        updateBindings.append { [weak control] in
            control?.state = !cefAvailable || BrowserEngineChoice.isWebKitPreferred() ? .on : .off
        }
        let detail = cefAvailable ? BrowserStrings.settingsWebKitEngineDetail : BrowserStrings.settingsWebKitEngineOnly
        return row(BrowserStrings.settingsWebKitEngine, detail: detail, icon: "webkit-engine", control: control)
    }

    /// Ladybird for every page, with no Chromium loaded, from the next launch. A separate toggle like WebKit's;
    /// turning one on turns the other off. Off and dimmed in a build without Ladybird's framework.
    private func ladybirdEngineRow() -> NSView {
        let available = BrowserEngineChoice.isLadybirdEngineAvailable
        let control = BrowserActionToggle()
        control.setAccessibilityLabel(BrowserStrings.settingsLadybirdEngine)
        control.setAccessibilityIdentifier("browser.settings.ladybird-engine")
        control.isEnabled = available
        control.onChange = { [weak self] isOn in
            BrowserEngineChoice.setLadybirdPreferred(isOn)
            self?.syncControls()
            self?.offerRelaunchForEngineChange()
        }
        updateBindings.append { [weak control] in
            control?.state = available && BrowserEngineChoice.isLadybirdPreferred() ? .on : .off
        }
        let detail = available
            ? BrowserStrings.settingsLadybirdEngineDetail
            : BrowserStrings.settingsLadybirdEngineMissing
        return row(BrowserStrings.settingsLadybirdEngine, detail: detail, icon: "ladybird-engine", control: control)
    }

    /// The engine changes only at launch, so the setting offers to relaunch now.
    private func offerRelaunchForEngineChange() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = BrowserStrings.settingsChromeEngineRelaunchTitle
        alert.informativeText = BrowserStrings.settingsChromeEngineRelaunchMessage
        alert.addButton(withTitle: BrowserStrings.settingsChromeEngineRelaunch)
        alert.addButton(withTitle: BrowserStrings.settingsChromeEngineLater)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NotificationCenter.default.post(name: BrowserEngineChoice.relaunchRequestedNotification, object: nil)
        }
    }

    /// Arc's sidebar import, reported in an alert because it adds Spaces.
    private func arcSidebarImportRow() -> NSView {
        let model = model
        return importRow(
            BrowserStrings.settingsImportArcSidebar,
            bundleIdentifiers: BrowserBookmarkImportSource.arc.bundleIdentifiers,
            id: "import-arc-sidebar",
        ) { [weak self] in
            let message = model.importSidebarFromDisk(of: .arc)
            let alert = NSAlert()
            alert.messageText = BrowserStrings.settingsImportArcSidebar
            alert.informativeText = message
            if let window = self?.view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    /// A browser to import from: its app icon and name, and an Import button at the row's end.
    private func importRow(
        _ title: String,
        bundleIdentifiers: [String],
        id: String,
        action: @escaping () -> Void,
    ) -> NSView {
        let button = BrowserActionButton(BrowserStrings.settingsImport, action: action)
        button.setAccessibilityLabel("\(BrowserStrings.settingsImport) \(title)")
        button.setAccessibilityIdentifier("browser.settings.\(id)")
        let icon = NSImageView(image: Self.applicationIcon(bundleIdentifiers))
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = BrowserNativeControls.stack(
            [icon, titleDetail(title, detail: nil)],
            orientation: .horizontal,
            spacing: 10,
        )
        label.alignment = .centerY
        return row(label: label, control: button)
    }

    private func refreshAccounts() {
        guard pane == .accounts else { return }
        var rows = [NSView]()
        if let accountStore, let session = accountStore.session {
            rows.append(signedInRow(email: session.userEmail, deviceID: session.deviceID, accountStore: accountStore))
            switch accountStore.bindingState {
            case .needsConsent:
                let enable = BrowserActionButton(BrowserStrings.syncAccountEnable) { accountStore.enableSync() }
                enable.keyEquivalent = "\r"
                rows.append(row(label: titleDetail(
                    BrowserStrings.syncAccountEnable,
                    detail: BrowserStrings.syncAccountEnableDetail,
                ), control: enable))
            case .differentAccount:
                rows.append(note(BrowserStrings.syncAccountDifferentOwner))
            case .enabled,
                 .paused:
                rows.append(syncRow(accountStore))
            case nil: break
            }
            if let error = accountStore.lastError {
                rows.append(note(error, symbol: "exclamationmark.triangle.fill", tint: .systemRed))
            }
            rows.append(deleteAccountRow(accountStore))
            replaceRows(rows, in: accountsBody)
        } else {
            BrowserNativeControls.replaceViews([signInPanel()], in: accountsBody)
        }
        refreshSharedLinks()
        scrollView.needsLayout = true
        let showsCodeEntry = accountStore?.emailSignIn != nil
        if showsCodeEntry, !isShowingEmailCodeEntry {
            view.window?.makeFirstResponder(accountCodeField)
        }
        isShowingEmailCodeEntry = showsCodeEntry
    }

    /// The account's shared links, each with Copy Link and Stop Sharing; shown
    /// while signed in.
    private func refreshSharedLinks() {
        guard pane == .accounts, let sharedLinksSection else { return }
        guard accountStore?.isAuthenticated == true, let shareStore = model.shareStore, shareStore.canPublish else {
            sharedLinksSection.isHidden = true
            // Another account's links never show after signing out.
            model.shareStore?.reset()
            return
        }
        sharedLinksSection.isHidden = false
        if shareStore.loadState == .idle {
            Task { await shareStore.refresh() }
        }
        let rows: [NSView] =
            switch shareStore.loadState {
            case .idle,
                 .loading:
                shareStore.links.isEmpty
                    ? [note(BrowserStrings.settingsSharedLinksLoading)]
                    : shareStore.links.map { sharedLinkRow($0, store: shareStore) }
            case .failed(let message):
                [row(
                    label: note(message, symbol: "exclamationmark.triangle.fill", tint: .systemRed),
                    control: BrowserActionButton(BrowserStrings.settingsSharedLinksRetry) {
                        Task { await shareStore.refresh() }
                    },
                )]
            case .loaded:
                shareStore.links.isEmpty
                    ? [note(BrowserStrings.settingsSharedLinksEmpty)]
                    : shareStore.links.map { sharedLinkRow($0, store: shareStore) }
            }
        replaceRows(rows, in: sharedLinksBody)
    }

    private func sharedLinkRow(_ link: BrowserSharedLink, store: BrowserShareStore) -> NSView {
        let symbol =
            switch link.kind {
            case .space: "square.stack"
            case .folder: "folder"
            case .quote: "quote.opening"
            }
        let what: String =
            if link.kind == .quote, let excerpt = link.excerpt {
                "“\(excerpt)”"
            } else {
                BrowserStrings.shareTabCount(link.itemCount)
            }
        let detail = [
            BrowserStrings.shareKindName(link.kind),
            what,
            link.updatedAt.formatted(date: .abbreviated, time: .omitted),
        ].joined(separator: " · ")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = titleDetail(link.title, detail: detail)
        let label = BrowserNativeControls.stack([icon, text], orientation: .horizontal, spacing: 10)
        label.alignment = .centerY
        let copy = BrowserActionButton(BrowserStrings.settingsSharedLinksCopy) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(link.url.absoluteString, forType: .URL)
            pasteboard.setString(link.url.absoluteString, forType: .string)
        }
        copy.toolTip = link.url.absoluteString
        copy.setAccessibilityIdentifier("browser.settings.shared-link.copy.\(link.id)")
        let stop = BrowserActionButton(BrowserStrings.settingsSharedLinksStop) { [weak self] in
            self?.confirmStopSharing(link, store: store)
        }
        stop.setAccessibilityIdentifier("browser.settings.shared-link.stop.\(link.id)")
        let controls = BrowserNativeControls.stack([copy, stop], orientation: .horizontal, spacing: 8)
        return row(label: label, control: controls)
    }

    private func confirmStopSharing(_ link: BrowserSharedLink, store: BrowserShareStore) {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.settingsSharedLinksStopTitle(link.title)
        alert.informativeText = BrowserStrings.settingsSharedLinksStopDetail
        alert.addButton(withTitle: BrowserStrings.settingsSharedLinksStop)
        alert.addButton(withTitle: BrowserStrings.shareCancel)
        let stop: @MainActor () -> Void = { [weak self] in
            Task { @MainActor in
                do {
                    try await store.remove(link)
                } catch {
                    let failure = NSAlert()
                    failure.messageText = BrowserStrings.shareFailed
                    failure.informativeText = BrowserShareStore.message(for: error)
                    if let window = self?.view.window {
                        failure.beginSheetModal(for: window) { _ in }
                    } else {
                        failure.runModal()
                    }
                }
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { stop() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            stop()
        }
    }

    /// Opening Accounts must not start typing into the email field, which
    /// AppKit focuses as the window's first text field.
    private func releaseEmailFieldFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = view.window, accountStore?.emailSignIn == nil,
                  (window.firstResponder as? NSText)?.delegate === accountEmailField
                  || window.firstResponder === accountEmailField
            else { return }
            window.makeFirstResponder(nil)
        }
    }

    /// The signed-in account: its initial in a circle, the address and this
    /// device, and Sign Out.
    private func signedInRow(email: String?, deviceID: String, accountStore: BrowserAccountStore) -> NSView {
        let name = email ?? BrowserStrings.syncAccountSignedIn
        let size = BrowserSettingsLayout.avatarSize
        let avatar = BrowserNativeSurface()
        avatar.fillColor = .controlAccentColor
        avatar.strokeWidth = 0
        avatar.cornerRadius = size / 2
        let initial = BrowserNativeControls.label(
            String(name.prefix(1)).uppercased(),
            size: 16,
            weight: .semibold,
            color: .white,
        )
        initial.alignment = .center
        avatar.addSubview(initial)
        initial.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: size),
            avatar.heightAnchor.constraint(equalToConstant: size),
            initial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
        ])
        let signOut = BrowserActionButton(BrowserStrings.syncAccountSignOut) { accountStore.signOut() }
        signOut.setAccessibilityIdentifier("browser.settings.account.sign-out")
        let text = BrowserNativeControls.stack([
            BrowserNativeControls.label(name, size: 14, weight: .semibold),
            BrowserNativeControls.label(
                BrowserStrings.syncAccountDevice(deviceID),
                size: 12,
                color: .secondaryLabelColor,
            ),
        ], spacing: 2)
        let leading = BrowserNativeControls.stack([avatar, text], orientation: .horizontal, spacing: 12)
        return BrowserNativeControls.padded(row(label: leading, control: signOut), vertical: 4)
    }

    /// Sync Sidebar: the switch pauses and resumes the profile's sync, and the
    /// line under it says when it last reached the server.
    private func syncRow(_ accountStore: BrowserAccountStore) -> NSView {
        let isOn = accountStore.bindingState == .enabled
        let control = BrowserActionToggle()
        control.state = isOn ? .on : .off
        control.setAccessibilityLabel(BrowserStrings.syncAccountSyncSidebar)
        control.setAccessibilityIdentifier("browser.settings.account.sync")
        control.onChange = { accountStore.setSyncEnabled($0) }
        let status: String =
            if !isOn {
                BrowserStrings.syncAccountPaused
            } else if let date = accountStore.lastSyncDate {
                BrowserStrings.syncAccountLastSynced(
                    date.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                )
            } else {
                BrowserStrings.syncAccountSyncing
            }
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular)) ?? NSImage())
        dot.contentTintColor = isOn ? .systemGreen : .tertiaryLabelColor
        dot.setContentHuggingPriority(.required, for: .horizontal)
        let detail = BrowserNativeControls.stack([
            dot,
            BrowserNativeControls.label(status, size: 12, color: .secondaryLabelColor, wraps: true),
        ], orientation: .horizontal, spacing: 6)
        let label = BrowserNativeControls.stack([
            BrowserNativeControls.label(BrowserStrings.syncAccountSyncSidebar, wraps: true),
            detail,
        ], spacing: 4)
        return row(label: withIcon("account.sync", label), control: control)
    }

    /// Delete Account…, which asks first. While the server deletes, the
    /// button says so and stays disabled.
    private func deleteAccountRow(_ accountStore: BrowserAccountStore) -> NSView {
        let isDeleting = accountStore.isDeletingAccount
        let button = BrowserActionButton(
            isDeleting ? BrowserStrings.syncAccountDeleting : BrowserStrings.syncAccountDelete,
        ) { [weak self] in
            self?.confirmAccountDeletion(accountStore)
        }
        button.isEnabled = !isDeleting
        button.setAccessibilityIdentifier("browser.settings.account.delete")
        let detail = BrowserNativeControls.label(
            BrowserStrings.syncAccountDeleteDetail,
            size: 12,
            color: .secondaryLabelColor,
            wraps: true,
        )
        return row(label: detail, control: button)
    }

    private func confirmAccountDeletion(_ accountStore: BrowserAccountStore) {
        guard !accountStore.isDeletingAccount else { return }
        let (alert, clearBrowsingData) = Self.accountDeletionAlert()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let clears = clearBrowsingData.state == .on
            Task { @MainActor [weak self] in
                guard await accountStore.deleteAccount() else { return }
                self?.showAccountDeleted(clearingBrowsingData: clears)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func showAccountDeleted(clearingBrowsingData: Bool) {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.syncAccountDeletedTitle
        alert.informativeText = BrowserStrings.syncAccountDeletedMessage
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] _ in
            if clearingBrowsingData {
                self?.openURL(BrowserSettingsRoute.clearBrowsingDataURL)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// One line of status with an optional symbol before it.
    private func note(_ text: String, symbol: String? = nil, tint: NSColor = .secondaryLabelColor) -> NSView {
        let label = BrowserNativeControls.label(text, size: 12, color: .secondaryLabelColor, wraps: true)
        guard let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return BrowserNativeControls.padded(label, vertical: 10)
        }
        let icon = NSImageView(image: image)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        return BrowserNativeControls.padded(
            BrowserNativeControls.stack([icon, label], orientation: .horizontal, spacing: 6),
            vertical: 10,
        )
    }

    /// Signed out: the app's icon and what an account is for above the
    /// server's sign-in methods, all centered.
    private func signInPanel() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let iconSize = BrowserSettingsLayout.accountIconSize
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        let title = BrowserNativeControls.label(BrowserStrings.settingsAccountsSignInTitle, size: 17, weight: .semibold)
        let configured = accountStore?.isConfigured == true
        let detail = BrowserNativeControls.label(
            configured
                ? BrowserStrings.settingsAccountsSignInDetail
                : accountStore?.unavailableMessage ?? BrowserStrings.settingsAccountsEmpty,
            size: 13,
            color: .secondaryLabelColor,
            wraps: true,
        )
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = BrowserSettingsLayout.signInWidth + 80
        var views: [NSView] = [icon, title, detail]
        if configured, let accountStore {
            views.append(contentsOf: signInRows(accountStore))
        }
        if let error = accountStore?.lastError {
            let label = BrowserNativeControls.label(error, size: 12, color: .systemRed, wraps: true)
            label.alignment = .center
            label.preferredMaxLayoutWidth = BrowserSettingsLayout.signInWidth
            views.append(label)
        }
        let stack = BrowserNativeControls.stack(views, spacing: 10)
        stack.alignment = .centerX
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: detail)
        return BrowserNativeControls.padded(stack, vertical: 22)
    }

    private func configureAccountFields() {
        for (field, placeholder, identifier) in [
            (accountEmailField, BrowserStrings.syncAccountEmailPlaceholder, "email"),
            (accountCodeField, BrowserStrings.syncAccountCodePlaceholder, "code"),
        ] {
            field.placeholderString = placeholder
            field.cell?.usesSingleLineMode = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.target = self
            field.setAccessibilityIdentifier("browser.settings.account.\(identifier)")
        }
        accountEmailField.contentType = .emailAddress
        accountCodeField.contentType = .oneTimeCode
        accountEmailField.action = #selector(requestEmailCode)
        accountCodeField.action = #selector(signInWithEmailCode)
    }

    /// The server's sign-in methods: a button per web provider, then a code
    /// sent by email. Each is as wide as the column.
    private func signInRows(_ accountStore: BrowserAccountStore) -> [NSView] {
        guard let providers = accountStore.providers else {
            guard accountStore.lastError != nil else { return [] }
            return [signInWidth(BrowserActionButton(BrowserStrings.syncAccountLoadProviders) {
                Task { await accountStore.loadProviders() }
            })]
        }
        let isEnabled = !accountStore.isSigningIn
        var rows = [NSView]()
        for provider in providers where provider.isWeb {
            let button = BrowserActionButton(Self.signInTitle(for: provider)) {
                Task { await accountStore.signIn(with: provider) }
            }
            button.isEnabled = isEnabled
            if let logo = Self.signInLogo(for: provider) {
                button.image = logo
                button.imagePosition = .imageLeading
            }
            button.setAccessibilityIdentifier("browser.settings.account.continue-with-\(provider.rawValue)")
            rows.append(signInWidth(button))
        }
        guard providers.contains(.email) else { return rows }
        if !rows.isEmpty {
            rows.append(orDivider())
        }
        accountEmailField.isEnabled = isEnabled
        accountCodeField.isEnabled = isEnabled
        guard let request = accountStore.emailSignIn else {
            let send = BrowserActionButton(BrowserStrings.syncAccountSendCode) { [weak self] in
                self?.requestEmailCode()
            }
            send.isEnabled = isEnabled
            send.setAccessibilityIdentifier("browser.settings.account.send-code")
            rows.append(signInWidth(accountEmailField))
            rows.append(signInWidth(send))
            return rows
        }
        let sent = BrowserNativeControls.label(
            BrowserStrings.syncAccountCodeSent(to: request.email),
            size: 12,
            color: .secondaryLabelColor,
            wraps: true,
        )
        sent.alignment = .center
        sent.preferredMaxLayoutWidth = BrowserSettingsLayout.signInWidth
        rows.append(sent)
        let signIn = BrowserActionButton(BrowserStrings.syncAccountSignInWithCode) { [weak self] in
            self?.signInWithEmailCode()
        }
        signIn.isEnabled = isEnabled
        signIn.keyEquivalent = "\r"
        signIn.setAccessibilityIdentifier("browser.settings.account.sign-in-with-code")
        rows.append(signInWidth(accountCodeField))
        rows.append(signInWidth(signIn))
        let sendAgain = BrowserActionButton(BrowserStrings.syncAccountSendAgain) {
            Task { await accountStore.requestEmailCode(email: request.email) }
        }
        sendAgain.isEnabled = isEnabled && accountStore.canResendEmailCode
        sendAgain.setAccessibilityIdentifier("browser.settings.account.send-again")
        let differentEmail = BrowserActionButton(BrowserStrings.syncAccountUseDifferentEmail) { [weak self] in
            self?.accountCodeField.stringValue = ""
            accountStore.cancelEmailSignIn()
        }
        differentEmail.setAccessibilityIdentifier("browser.settings.account.use-different-email")
        for link in [sendAgain, differentEmail] {
            link.isBordered = false
            link.contentTintColor = .linkColor
            link.font = .systemFont(ofSize: 12)
        }
        rows.append(BrowserNativeControls.stack([sendAgain, differentEmail], orientation: .horizontal, spacing: 16))
        return rows
    }

    /// Sizes a sign-in control to the column, large like a sheet's buttons.
    private func signInWidth(_ control: NSControl) -> NSView {
        control.controlSize = .large
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.signInWidth).isActive = true
        return control
    }

    /// A thin line on each side of "or", between the providers and email.
    private func orDivider() -> NSView {
        let row = NSView()
        let label = BrowserNativeControls.label(BrowserStrings.settingsAccountsOr, size: 12, color: .tertiaryLabelColor)
        let leading = NSBox()
        let trailing = NSBox()
        for view in [leading, trailing] {
            view.boxType = .separator
        }
        for view in [leading, label, trailing] as [NSView] {
            row.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.signInWidth),
            label.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leading.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -10),
            leading.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            leading.heightAnchor.constraint(equalToConstant: 1),
            trailing.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            trailing.heightAnchor.constraint(equalToConstant: 1),
        ])
        return row
    }

    @objc private func requestEmailCode() {
        guard let accountStore, accountStore.emailSignIn == nil else { return }
        let email = accountEmailField.stringValue
        accountCodeField.stringValue = ""
        Task { await accountStore.requestEmailCode(email: email) }
    }

    @objc private func signInWithEmailCode() {
        guard let accountStore, let request = accountStore.emailSignIn else { return }
        let code = accountCodeField.stringValue
        Task { await accountStore.signIn(email: request.email, code: code) }
    }

    private func refreshProfiles() {
        guard pane == .profiles else { return }
        profileDeleteButtons.removeAll()
        let rows = profileStore.profiles.map { profile -> NSView in
            let icon = NSImageView(image: NSImage(
                systemSymbolName: "person.crop.circle",
                accessibilityDescription: nil,
            ) ?? NSImage())
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            // The folder keeps the name it was made with; the profile's own name can change.
            let title = titleDetail(profile.displayName)
            title.toolTip = BrowserStrings.settingsProfileDirectory(profile.directoryName)
            var items = [NSView]()
            if profile.id == currentProfileID {
                items.append(BrowserNativeControls.label(
                    BrowserStrings.settingsCurrentProfile,
                    size: 12,
                    weight: .semibold,
                    color: .secondaryLabelColor,
                ))
            } else {
                items.append(BrowserActionButton(BrowserStrings.settingsOpenProfile) { [weak self] in
                    self?.openProfile(profile)
                })
            }
            let rename = BrowserActionButton(BrowserStrings.settingsRenameProfile) { [weak self] in
                self?.promptRenaming(profile)
            }
            rename.setAccessibilityIdentifier("browser.settings.profile.rename.\(profile.id)")
            items.append(rename)
            let backup = BrowserActionButton(BrowserStrings.settingsBackUpProfile) { [weak self] in
                self?.createProfileBackup(profile)
            }
            backup.isEnabled = profileBackupInProgressID == nil
            let delete = BrowserActionButton(BrowserStrings.settingsDeleteProfile) { [weak self] in
                guard let self, profile.id != currentProfileID, !profile.isDefault,
                      canDeleteProfile(profile) else { return }
                _ = profileStore.deleteProfile(profile)
            }
            delete.setAccessibilityIdentifier("browser.settings.profile.delete.\(profile.id)")
            delete.contentTintColor = .systemRed
            profileDeleteButtons.append((profile, delete))
            delete.isEnabled = profile.id != currentProfileID && !profile.isDefault && canDeleteProfile(profile)
            if !canDeleteProfile(profile) {
                delete.toolTip = BrowserStrings.sessionRecoveryCloseProfileBeforeDeleting
            }
            items += [backup, delete]
            let label = BrowserNativeControls.stack([icon, title], orientation: .horizontal, spacing: 10)
            let actions = BrowserNativeControls.stack(items, orientation: .horizontal, spacing: 16)
            return row(label: label, control: actions)
        }
        replaceRows(rows, in: profilesBody)
    }

    private func promptRenaming(_ profile: BrowserProfile) {
        guard let window = view.window else { return }
        let field = NSTextField(string: profile.displayName)
        field.placeholderString = profile.displayName
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityIdentifier("browser.settings.profile.rename-field")
        let alert = NSAlert()
        alert.messageText = BrowserStrings.settingsRenameProfileTitle
        alert.accessoryView = field
        alert.addButton(withTitle: BrowserStrings.settingsRenameProfileConfirm)
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, weak field] response in
            guard response == .alertFirstButtonReturn, let self, let field else { return }
            profileStore.renameProfile(profile, to: field.stringValue)
        }
    }

    private func refreshShortcuts() {
        guard pane == .shortcuts, isViewLoaded else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = shortcutStore.commandIDs.filter { command in
            let descriptor = shortcutStore.descriptor(for: command)
            return query.isEmpty || descriptor.menuTitle.localizedCaseInsensitiveContains(query)
                || descriptor.helpTitle.localizedCaseInsensitiveContains(query)
                ||
                (descriptor.shortcut.isAssigned && descriptor.shortcut
                    .displayText
                    .localizedCaseInsensitiveContains(query))
        }
        // A hundred rows of controls took a third of a second to open; the
        // list makes only the rows that scroll into view.
        let list = BrowserShortcutSettingsList(count: commands.count) { [weak self] index in
            let row = self?.shortcutRow(commands[index]) ?? BrowserShortcutSettingsRow.empty()
            row.drawsSeparator = index > 0
            return row
        }
        BrowserNativeControls.replaceViews([list], in: shortcutsBody)
        scrollView.needsLayout = true
    }

    private func shortcutRow(_ command: BrowserCommandID) -> BrowserShortcutSettingsRow {
        let descriptor = shortcutStore.descriptor(for: command)
        let recording = recordingCommandID == command
        let value: NSView
        if recording {
            let capture = BrowserShortcutCaptureNSView()
            capture.onCapture = { [weak self] in self?.apply($0, to: command) }
            capture.onCancel = { [weak self] in self?.recordingCommandID = nil
                self?.refreshShortcuts()
            }
            value = capture
        } else {
            let label = BrowserNativeControls.label(
                descriptor.shortcut.isAssigned
                    ? descriptor.shortcut.displayText
                    : BrowserStrings.settingsShortcutNotSet,
                size: 12,
                weight: .semibold,
            )
            label.alignment = .right
            value = label
        }
        let record = BrowserActionButton(recording
            ? BrowserStrings.settingsShortcutPressShortcut
            : BrowserStrings.settingsShortcutRecord)
        { [weak self] in
            self?.recordingCommandID = recording ? nil : command
            self?.shortcutMessage.isHidden = true
            self?.refreshShortcuts()
        }
        record.setAccessibilityIdentifier("browser.settings.shortcut.record.\(command.rawValue)")
        let reset = BrowserActionButton(BrowserStrings.settingsShortcutReset) { [weak self] in
            guard let self else { return }
            shortcutStore.resetShortcut(for: command)
            if recordingCommandID == command {
                recordingCommandID = nil
            }
            shortcutMessage.isHidden = true
            refreshShortcuts()
        }
        reset.isEnabled = shortcutStore.isCustomized(command)
        let title = BrowserNativeControls.label(descriptor.menuTitle)
        return BrowserShortcutSettingsRow(title: title, value: value, record: record, reset: reset)
    }

    private func apply(_ shortcut: BrowserKeyboardShortcut, to command: BrowserCommandID) {
        if shortcutStore.setShortcut(shortcut, for: command) {
            recordingCommandID = nil
            shortcutMessage.isHidden = true
        } else {
            let conflict = shortcutStore.conflictDescription(for: shortcut, excluding: command) ?? ""
            shortcutMessage.stringValue = BrowserStrings.settingsShortcutConflict(conflict)
            shortcutMessage.isHidden = false
        }
        refreshShortcuts()
    }

    private func createProfileBackup(_ profile: BrowserProfile) {
        let rootCacheURL = profileStore.rootCacheURL
        profileBackupInProgressID = profile.id
        backupMessage.isHidden = true
        refreshProfiles()
        Task { @MainActor [weak self] in
            do {
                let url = try await Task
                    .detached { try BrowserProfileBackupArchiver(rootCacheURL: rootCacheURL).createBackup(for: profile)
                    }
                    .value
                guard let self else { return }
                profileBackupInProgressID = nil
                backupMessage.stringValue = BrowserStrings.settingsProfileBackupCreated(url.lastPathComponent)
                backupMessage.isHidden = false
                BrowserTelemetry.captureUsage(.profileBackupCreated, properties: ["profile": profile.isDefault
                        ? "default"
                        : "custom"])
                refreshProfiles()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                guard let self else { return }
                profileBackupInProgressID = nil
                backupMessage.stringValue = BrowserStrings.settingsProfileBackupFailed(error.localizedDescription)
                backupMessage.isHidden = false
                BrowserTelemetry.captureError(
                    error,
                    event: .profileBackupFailed,
                    properties: ["profile": profile.isDefault
                        ? "default"
                        : "custom"],
                )
                refreshProfiles()
            }
        }
    }

    private func titleDetail(_ title: String, detail: String? = nil) -> NSStackView {
        var labels: [NSView] = [BrowserNativeControls.label(title, wraps: true)]
        if let detail {
            labels.append(BrowserNativeControls.label(
                detail,
                size: 12,
                color: .secondaryLabelColor,
                wraps: true,
            ))
        }
        return BrowserNativeControls.stack(labels, spacing: 2)
    }

    private func row(_ title: String, detail: String? = nil, icon id: String? = nil, control: NSView) -> NSView {
        row(label: withIcon(id, titleDetail(title, detail: detail)), control: control)
    }

    /// A setting's colored badge before its title, when it has one.
    private func withIcon(_ id: String?, _ label: NSView) -> NSView {
        guard let id, let icon = BrowserSettingsIcon.icons[id] else { return label }
        let badge = NSImageView(image: icon.image)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = BrowserNativeControls.stack([badge, label], orientation: .horizontal, spacing: 10)
        stack.alignment = .centerY
        return stack
    }

    private func row(label: NSView, control: NSView) -> NSView {
        let row = NSView()
        for child in [label, control] {
            row.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor, constant: 12),
        ])
        return row
    }

    private func toggle(
        _ id: String,
        _ title: String,
        detail: String? = nil,
        get: @escaping () -> Bool,
        set: @escaping (Bool) -> Void,
    ) -> NSView {
        let control = BrowserActionToggle()
        control.setAccessibilityLabel(title)
        control.setAccessibilityIdentifier("browser.settings.\(id)")
        control.onChange = set
        updateBindings.append { [weak control] in control?.state = get() ? .on : .off }
        return row(title, detail: detail, icon: id, control: control)
    }

    private func picker<Value: Equatable>(
        _ id: String,
        _ title: String,
        detail: String? = nil,
        options: [Value],
        title optionTitle: (Value) -> String,
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void,
        enabled: @escaping () -> Bool = { true },
    ) -> NSView {
        let control = BrowserActionPopUpButton(titles: options.map(optionTitle))
        control.setAccessibilityLabel(title)
        control.setAccessibilityIdentifier("browser.settings.\(id)")
        let container = NSView()
        container.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.pickerWidth),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        control.onChange = {
            index in if options.indices.contains(index) {
                set(options[index])
            }
        }
        updateBindings.append { [weak control] in
            control?.selectItem(at: options.firstIndex(of: get()) ?? -1)
            control?.isEnabled = enabled()
        }
        return row(title, detail: detail, icon: id, control: container)
    }

    private func link(_ title: String, url: URL) -> NSView {
        let button = BrowserActionButton(title) { [weak self] in self?.openURL(url) }
        return listButton(button, symbol: "chevron.right", trailing: true)
    }

    /// A borderless button filling a row: title in the label color, its
    /// symbol in the secondary one, before the title or at the row's end.
    private func listButton(_ button: BrowserActionButton, symbol: String, trailing: Bool = false) -> NSView {
        button.isBordered = false
        button.alignment = .left
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        guard trailing else {
            button.image = image
            button.imagePosition = .imageLeading
            return BrowserNativeControls.padded(button, vertical: 8)
        }
        let chevron = NSImageView(image: image ?? NSImage())
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = BrowserNativeControls.stack([button, chevron], orientation: .horizontal, spacing: 8)
        return BrowserNativeControls.padded(row, vertical: 8)
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let body = NSStackView()
        let section = section(title, body: body)
        replaceRows(rows, in: body)
        return section
    }

    private func section(_ title: String, body: NSStackView) -> NSView {
        let label = BrowserNativeControls.label(title, size: 13, weight: .semibold, color: .secondaryLabelColor)
        let section = BrowserNativeControls.stack(
            [BrowserNativeControls.padded(label, horizontal: 4, vertical: 0)],
            spacing: 8,
        )
        BrowserNativeControls.fillWidth(card(body), in: section)
        return section
    }

    /// A rounded, outlined surface around a section's rows.
    private func card(_ body: NSStackView) -> NSView {
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        let surface = BrowserNativeSurface()
        surface.fillColor = BrowserSettingsLayout.cardFill
        surface.strokeColor = BrowserSettingsLayout.cardStroke
        surface.strokeWidth = 1
        surface.cornerRadius = BrowserSettingsLayout.cardCornerRadius
        let padded = BrowserNativeControls.padded(
            body,
            horizontal: BrowserSettingsLayout.cardHorizontalPadding,
            vertical: BrowserSettingsLayout.cardVerticalPadding,
        )
        surface.addSubview(padded)
        padded.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            padded.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            padded.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            padded.topAnchor.constraint(equalTo: surface.topAnchor),
            padded.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        return surface
    }

    private func replaceRows(_ rows: [NSView], in stack: NSStackView) {
        var divided = [NSView]()
        var dividers = [NSView]()
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = BrowserNativeControls.divider()
                dividers.append(divider)
                divided.append(divider)
            }
            divided.append(row)
        }
        BrowserNativeControls.replaceViews(divided, in: stack)
        let dividerVisibility = BrowserSettingsRowDividers(rows: rows, dividers: dividers)
        dividerVisibility.update()
        rowDividers[ObjectIdentifier(stack)] = dividerVisibility
        scrollView.needsLayout = true
    }
}

// MARK: - BrowserPasswordVisibilityToggle

/// Swaps a password sheet's secure field for a plain one showing the same text, and back.
@MainActor final class BrowserPasswordVisibilityToggle: NSObject {
    private(set) var isShowing = false

    private let secure: NSSecureTextField
    private let plain: NSTextField

    init(secure: NSSecureTextField, plain: NSTextField) {
        self.secure = secure
        self.plain = plain
    }

    @objc func toggle(_ sender: NSButton) {
        isShowing = sender.state == .on
        if isShowing {
            plain.stringValue = secure.stringValue
        } else {
            secure.stringValue = plain.stringValue
        }
        plain.isHidden = !isShowing
        secure.isHidden = isShowing
    }
}

// MARK: - BrowserSettingsRowDividers

/// A card's dividers follow its rows: a hidden row hides the divider above it and the first shown row has none,
/// so a card never shows a line at its edge or two lines in a row.
@MainActor final class BrowserSettingsRowDividers {
    private let rows: [NSView]
    private let dividers: [NSView]
    private var observations = [NSKeyValueObservation]()

    init(rows: [NSView], dividers: [NSView]) {
        self.rows = rows
        self.dividers = dividers
        self.observations = rows.map { row in
            row.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    func update() {
        var shownAbove = rows.first.map { !$0.isHidden } ?? false
        for (index, divider) in dividers.enumerated() where rows.indices.contains(index + 1) {
            let row = rows[index + 1]
            divider.isHidden = row.isHidden || !shownAbove
            shownAbove = shownAbove || !row.isHidden
        }
    }
}
