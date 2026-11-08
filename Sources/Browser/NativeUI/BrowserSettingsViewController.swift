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
        panel.title = BrowserStrings.bookmarksImportSafari
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
    private var profileDeleteButtons = [(BrowserProfile, BrowserActionButton)]()
    private let passwordsBody = NSStackView()
    private let addressesBody = NSStackView()
    private let cardsBody = NSStackView()
    private let shortcutsBody = NSStackView()
    private let profilesBody = NSStackView()
    private let accountsBody = NSStackView()
    /// Kept across refreshes, so typing survives the account store's updates.
    private let accountEmailField = NSTextField()
    private let accountCodeField = NSTextField()
    private var isShowingEmailCodeEntry = false
    private let linkRoutesBody = NSStackView()
    private var linkRouteFields = [UUID: NSTextField]()
    private let siteSearchesBody = NSStackView()
    private let sitePermissionsBody = NSStackView()
    private var shownSitePermissions = [BrowserSitePermissionDecision]()
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
        syncControls()
    }

    private static func signInTitle(for provider: BrowserAccountProvider) -> String {
        switch provider {
        case .apple: BrowserStrings.syncAccountContinueWithApple
        case .google: BrowserStrings.syncAccountContinueWithGoogle
        case .github: BrowserStrings.syncAccountContinueWithGitHub
        case .email: BrowserStrings.syncAccountSendCode
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

    private func observe(_ publisher: ObservableObjectPublisher, action: @escaping () -> Void) {
        publisher.receive(on: RunLoop.main).sink { action() }.store(in: &observations)
    }

    private func syncControls() {
        updateBindings.forEach { $0() }
        refreshSitePermissions()
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
        scrollView.setViews([
            section(
                BrowserStrings.settingsGeneralTab,
                rows: [row(BrowserStrings.settingsDefaultBrowserPrompt, control: button)],
            ),
            section(BrowserStrings.settingsAccountsCurrentAccounts, body: accountsBody),
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
        ])
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
        for source in BrowserBookmarkImportSource.allCases where source != .safari {
            importButton.addItem(withTitle: source.browserName)
            importButton.lastItem?.representedObject = source.rawValue
            importButton.lastItem?.target = self
            importButton.lastItem?.action = #selector(importSiteSearches(_:))
        }
        importButton.setAccessibilityIdentifier("browser.settings.site-search.import")
        replaceRows(
            [BrowserNativeControls.padded(detail, vertical: 8)]
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

    private func siteSearchRow(_ site: BrowserSiteSearch) -> NSView {
        let id = site.id
        func field(
            _ value: String,
            placeholder: String,
            width: CGFloat,
            keyPath: WritableKeyPath<BrowserSiteSearch, String>,
            identifier: String,
        ) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
            field.setAccessibilityIdentifier("browser.settings.site-search.\(identifier)")
            siteSearchFields.append((field, id, keyPath))
            return field
        }
        let name = field(
            site.name,
            placeholder: BrowserStrings.settingsSiteSearchName,
            width: 110,
            keyPath: \.name,
            identifier: "name",
        )
        let keyword = field(
            site.keyword,
            placeholder: BrowserStrings.settingsSiteSearchKeyword,
            width: 100,
            keyPath: \.keyword,
            identifier: "keyword",
        )
        let url = field(
            site.urlTemplate,
            placeholder: BrowserStrings.settingsSiteSearchURL,
            width: 200,
            keyPath: \.urlTemplate,
            identifier: "url",
        )
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keyword.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        url.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let remove = BrowserActionButton("") { [weak self] in
            self?.preferences.siteSearches.removeAll { $0.id == id }
            self?.refreshSiteSearches()
        }
        remove.image = NSImage(
            systemSymbolName: "minus.circle",
            accessibilityDescription: BrowserStrings.settingsSiteSearchRemove,
        )
        remove.isBordered = false
        remove.toolTip = BrowserStrings.settingsSiteSearchRemove
        remove.setAccessibilityIdentifier("browser.settings.site-search.remove")
        return BrowserNativeControls.padded(
            BrowserNativeControls.stack([name, keyword, url, remove], orientation: .horizontal, spacing: 8),
            vertical: 4,
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
            label: label,
            control: BrowserNativeControls.stack([reset, choose], orientation: .horizontal, spacing: 8),
        )
    }

    private func automaticArchivalRows() -> [NSView] {
        let model = model
        let localRow = picker(
            "temporary-tab-lifetime",
            BrowserStrings.settingsTemporaryTabsLifetimeLabel,
            options: BrowserTemporaryTabLifetime.allCases,
            title: BrowserStrings.title,
            get: { model.temporaryTabLifetime },
            set: { [weak self] lifetime in
                model.setTemporaryTabLifetime(lifetime)
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
        replaceRows(logins.map { login in
            let host = BrowserNativeControls.label(login.host, size: 13, weight: .medium, color: .labelColor)
            let name = BrowserNativeControls.label(
                login.username,
                size: 12,
                weight: .regular,
                color: .secondaryLabelColor,
            )
            let text = BrowserNativeControls.stack([host, name], orientation: .vertical, spacing: 1)
            let copy = BrowserActionButton(BrowserStrings.passwordCopy) {
                guard let password = store?.password(for: login) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
            }
            let delete = BrowserActionButton(BrowserStrings.passwordDelete) { [weak self] in
                store?.delete(login)
                self?.refreshPasswords()
            }
            return BrowserNativeControls.stack([text, NSView(), copy, delete], orientation: .horizontal, spacing: 8)
        }, in: passwordsBody)
    }

    private func configureIcon() {
        let preferences = preferences
        let body = NSStackView()
        func rows() -> [NSView] {
            BrowserAppIcon.choices.map { icon in
                let selected = preferences.appIcon == icon || (icon == .standard && preferences.appIcon == .ring)
                let radio = BrowserActionButton("") { [weak self] in
                    preferences.appIcon = icon
                    icon.apply()
                    self?.configureContent()
                }
                radio.setButtonType(.radio)
                radio.state = selected ? .on : .off
                let image = NSImageView(image: icon.image ?? NSImage())
                image.imageScaling = .scaleProportionallyUpOrDown
                image.widthAnchor.constraint(equalToConstant: 40).isActive = true
                image.heightAnchor.constraint(equalToConstant: 40).isActive = true
                let name = BrowserNativeControls.label(icon.title, size: 13, weight: .medium, color: .labelColor)
                return BrowserNativeControls.stack([radio, image, name], orientation: .horizontal, spacing: 12)
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
            section(BrowserStrings.settingsSitePermissionsTitle, body: sitePermissionsBody),
            section(
                BrowserStrings.bookmarksImport,
                rows: [arcSidebarImportRow()] + BrowserBookmarkImportSource.allCases.map { source in
                    let button = BrowserActionButton(source.title) { [weak self] in
                        guard let self else { return }
                        if source == .safari {
                            guard let url = BrowserSafariBookmarkImportPanel.chooseSourceURL() else { return }
                            _ = model.bookmarksModel.importSafariBookmarks(from: url)
                        } else {
                            _ = model.importBookmarks(from: source)
                        }
                    }
                    button.isBordered = false
                    button.alignment = .left
                    button.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
                    button.imagePosition = .imageLeading
                    return BrowserNativeControls.padded(button, vertical: 8)
                },
            ),
            section(BrowserStrings.settingsAdvancedTab, rows: [
                link(BrowserStrings.settingsMoreSettings, url: BrowserSettingsRoute.rootURL),
                link(BrowserStrings.settingsTranslateSitePrompts, url: BrowserSettingsRoute.languageURL),
                row(BrowserStrings.settingsExportDataDetail, control: exportData),
            ]),
        ])
    }

    /// Arc's sidebar import, reported in an alert because it adds Spaces.
    private func arcSidebarImportRow() -> NSView {
        let model = model
        let button = BrowserActionButton(BrowserStrings.settingsImportArcSidebar) { [weak self] in
            let message: String
            if !model.canImportArcSidebar {
                message = BrowserStrings.arcImportUnavailable
            } else if let url = BrowserArcSidebar.defaultFileURL {
                do {
                    let result = try model.importArcSidebar(BrowserArcSidebar.load(from: url))
                    message = result.isEmpty
                        ? BrowserStrings.arcImportNothing
                        : BrowserStrings.arcImportResult(
                            spaces: result.spaceCount,
                            pinnedTabs: result.pinnedTabCount,
                            folders: result.folderCount,
                            favorites: result.favoriteCount,
                        )
                } catch BrowserArcSidebar.ImportError.missing {
                    message = BrowserStrings.arcImportMissing
                } catch {
                    message = BrowserStrings.arcImportUnreadable
                }
            } else {
                message = BrowserStrings.arcImportMissing
            }
            let alert = NSAlert()
            alert.messageText = BrowserStrings.settingsImportArcSidebar
            alert.informativeText = message
            if let window = self?.view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
        button.setAccessibilityIdentifier("browser.settings.import-arc-sidebar")
        button.isBordered = false
        button.alignment = .left
        button.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return BrowserNativeControls.padded(button, vertical: 8)
    }

    private func refreshAccounts() {
        guard pane == .accounts else { return }
        var rows = [NSView]()
        if let accountStore {
            if let session = accountStore.session {
                rows.append(titleDetail(
                    session.userEmail ?? BrowserStrings.syncAccountSignedIn,
                    detail: BrowserStrings.syncAccountDevice(session.deviceID),
                ))
                switch accountStore.bindingState {
                case .needsConsent:
                    rows.append(BrowserNativeControls.label(
                        BrowserStrings.syncAccountEnableDetail, color: .secondaryLabelColor, wraps: true,
                    ))
                    rows.append(BrowserActionButton(BrowserStrings.syncAccountEnable) { accountStore.enableSync() })
                case .differentAccount:
                    rows.append(BrowserNativeControls.label(
                        BrowserStrings.syncAccountDifferentOwner, color: .secondaryLabelColor, wraps: true,
                    ))
                case .enabled:
                    rows.append(BrowserNativeControls.label(
                        BrowserStrings.syncAccountEnabled, color: .secondaryLabelColor, wraps: true,
                    ))
                case nil,
                     .paused: break
                }
                rows.append(BrowserActionButton(BrowserStrings.syncAccountSignOut) { accountStore.signOut() })
            } else {
                rows.append(BrowserNativeControls.label(
                    accountStore.isConfigured
                        ? BrowserStrings.settingsAccountsEmpty
                        : accountStore.unavailableMessage,
                    color: .secondaryLabelColor,
                    wraps: true,
                ))
                if accountStore.isConfigured {
                    rows.append(contentsOf: signInRows(accountStore))
                }
            }
            if let error = accountStore.lastError {
                rows.append(BrowserNativeControls.label(
                    error,
                    size: 12,
                    color: .systemRed,
                    wraps: true,
                ))
            }
        } else {
            rows.append(BrowserNativeControls.label(
                BrowserStrings.settingsAccountsEmpty,
                color: .secondaryLabelColor,
            ))
        }
        accountsBody.spacing = 10
        BrowserNativeControls.replaceViews(rows, in: accountsBody)
        scrollView.needsLayout = true
        let showsCodeEntry = accountStore?.emailSignIn != nil
        if showsCodeEntry, !isShowingEmailCodeEntry {
            view.window?.makeFirstResponder(accountCodeField)
        }
        isShowingEmailCodeEntry = showsCodeEntry
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
    /// sent by email.
    private func signInRows(_ accountStore: BrowserAccountStore) -> [NSView] {
        guard let providers = accountStore.providers else {
            guard accountStore.lastError != nil else { return [] }
            return [BrowserActionButton(BrowserStrings.syncAccountLoadProviders) {
                Task { await accountStore.loadProviders() }
            }]
        }
        let isEnabled = !accountStore.isSigningIn
        var rows = [NSView]()
        for provider in providers where provider.isWeb {
            let button = BrowserActionButton(Self.signInTitle(for: provider)) {
                Task { await accountStore.signIn(with: provider) }
            }
            button.isEnabled = isEnabled
            button.setAccessibilityIdentifier("browser.settings.account.continue-with-\(provider.rawValue)")
            rows.append(button)
        }
        guard providers.contains(.email) else { return rows }
        accountEmailField.isEnabled = isEnabled
        accountCodeField.isEnabled = isEnabled
        guard let request = accountStore.emailSignIn else {
            let send = BrowserActionButton(BrowserStrings.syncAccountSendCode) { [weak self] in
                self?.requestEmailCode()
            }
            send.isEnabled = isEnabled
            send.setAccessibilityIdentifier("browser.settings.account.send-code")
            rows.append(BrowserNativeControls.stack([accountEmailField, send], orientation: .horizontal, spacing: 8))
            return rows
        }
        rows.append(BrowserNativeControls.label(
            BrowserStrings.syncAccountCodeSent(to: request.email),
            color: .secondaryLabelColor,
            wraps: true,
        ))
        let signIn = BrowserActionButton(BrowserStrings.syncAccountSignInWithCode) { [weak self] in
            self?.signInWithEmailCode()
        }
        signIn.isEnabled = isEnabled
        signIn.setAccessibilityIdentifier("browser.settings.account.sign-in-with-code")
        rows.append(BrowserNativeControls.stack([accountCodeField, signIn], orientation: .horizontal, spacing: 8))
        let sendAgain = BrowserActionButton(BrowserStrings.syncAccountSendAgain) {
            Task { await accountStore.requestEmailCode(email: request.email) }
        }
        sendAgain.isEnabled = isEnabled && accountStore.canResendEmailCode
        sendAgain.setAccessibilityIdentifier("browser.settings.account.send-again")
        let differentEmail = BrowserActionButton(BrowserStrings.syncAccountUseDifferentEmail) { [weak self] in
            self?.accountCodeField.stringValue = ""
            accountStore.cancelEmailSignIn()
        }
        rows.append(BrowserNativeControls.stack([sendAgain, differentEmail], orientation: .horizontal, spacing: 8))
        return rows
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
            let title = titleDetail(
                profile.displayName,
                detail: BrowserStrings.settingsProfileDirectory(profile.directoryName),
            )
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
        replaceRows(commands.map(shortcutRow), in: shortcutsBody)
    }

    private func shortcutRow(_ command: BrowserCommandID) -> NSView {
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
        value.widthAnchor.constraint(equalToConstant: BrowserSettingsLayout.shortcutCaptureWidth).isActive = true
        let record = BrowserActionButton(recording
            ? BrowserStrings.settingsShortcutPressShortcut
            : BrowserStrings.settingsShortcutRecord)
        { [weak self] in
            self?.recordingCommandID = recording ? nil : command
            self?.shortcutMessage.isHidden = true
            self?.refreshShortcuts()
        }
        record.widthAnchor.constraint(equalToConstant: 92).isActive = true
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
        reset.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let title = titleDetail(descriptor.menuTitle)
        let actions = BrowserNativeControls.stack([value, record, reset], orientation: .horizontal, spacing: 12)
        return row(label: title, control: actions)
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

    private func row(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        row(label: titleDetail(title, detail: detail), control: control)
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
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
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
        return row(title, detail: detail, control: control)
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
        return row(title, detail: detail, control: container)
    }

    private func link(_ title: String, url: URL) -> NSView {
        let button = BrowserActionButton(title) { [weak self] in self?.openURL(url) }
        button.isBordered = false
        button.alignment = .left
        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        return BrowserNativeControls.padded(button, vertical: 8)
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let body = NSStackView()
        let section = section(title, body: body)
        replaceRows(rows, in: body)
        return section
    }

    private func section(_ title: String, body: NSStackView) -> NSView {
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        let surface = BrowserNativeSurface()
        surface.fillColor = .controlBackgroundColor
        surface.cornerRadius = 8
        let padded = BrowserNativeControls.padded(body, horizontal: 12, vertical: 8)
        surface.addSubview(padded)
        padded.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            padded.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            padded.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            padded.topAnchor.constraint(equalTo: surface.topAnchor),
            padded.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        let label = BrowserNativeControls.label(title, size: 12, weight: .semibold, color: .secondaryLabelColor)
        let section = BrowserNativeControls.stack([label], spacing: BrowserSettingsLayout.rowSpacing)
        BrowserNativeControls.fillWidth(surface, in: section)
        return section
    }

    private func replaceRows(_ rows: [NSView], in stack: NSStackView) {
        var divided = [NSView]()
        for (index, row) in rows.enumerated() {
            if index > 0 {
                divided.append(BrowserNativeControls.divider())
            }
            divided.append(row)
        }
        BrowserNativeControls.replaceViews(divided, in: stack)
        scrollView.needsLayout = true
    }
}
