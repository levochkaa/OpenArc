import AppKit
import Combine
import Settings
import UniformTypeIdentifiers

// MARK: - BrowserSettingsLayout

enum BrowserSettingsLayout {
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 560
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

// MARK: - BrowserSettingsPane

enum BrowserSettingsPane: String, CaseIterable, Hashable {
    case accounts
    case general
    case profiles
    case shortcuts
    case content

    // MARK: Internal

    var title: String {
        switch self {
        case .accounts:
            BrowserStrings.settingsAccountsTab
        case .general:
            BrowserStrings.settingsGeneralTab
        case .profiles:
            BrowserStrings.settingsProfilesTab
        case .shortcuts:
            BrowserStrings.settingsShortcutsTab
        case .content:
            BrowserStrings.settingsContentTab
        }
    }

    var systemImageName: String {
        switch self {
        case .accounts:
            "person.crop.circle"
        case .general:
            "gearshape"
        case .profiles:
            "person.2"
        case .shortcuts:
            "keyboard"
        case .content:
            "doc.text"
        }
    }
}

// MARK: - BrowserSettingsViewController

final class BrowserSettingsViewController: NSViewController, @MainActor SettingsPane, NSSearchFieldDelegate {
    // MARK: Lifecycle

    init(
        model: BrowserChromeModel,
        profileStore: BrowserProfileStore,
        currentProfileID: String,
        accountStore: BrowserAccountStore?,
        pane: BrowserSettingsPane,
        canDeleteProfile: @escaping (BrowserProfile) -> Bool = { _ in true },
        openProfile: @escaping (BrowserProfile) -> Void,
        openURL: @escaping (URL) -> Void
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

    // MARK: Internal

    var paneIdentifier: Settings.PaneIdentifier { .init(pane.rawValue) }
    var paneTitle: String { pane.title }
    var toolbarItemIcon: NSImage { NSImage(
        systemSymbolName: pane.systemImageName,
        accessibilityDescription: pane.title
    ) ?? NSImage() }

    override func loadView() {
        let background = BrowserNativeSurface(frame: NSRect(
            x: 0,
            y: 0,
            width: BrowserSettingsLayout.windowWidth,
            height: BrowserSettingsLayout.windowHeight
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
        syncControls()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField {
            refreshShortcuts()
        }
    }

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
    private let shortcutsBody = NSStackView()
    private let profilesBody = NSStackView()
    private let accountsBody = NSStackView()
    private let shortcutMessage = BrowserNativeControls.label("", size: 12, color: .systemRed, wraps: true)
    private let backupMessage = BrowserNativeControls.label("", size: 12, color: .secondaryLabelColor, wraps: true)
    private var recordingCommandID: BrowserCommandID?
    private var profileBackupInProgressID: BrowserProfile.ID?

    private func observe(_ publisher: ObservableObjectPublisher, action: @escaping () -> Void) {
        publisher.receive(on: RunLoop.main).sink { action() }.store(in: &observations)
    }

    private func syncControls() {
        updateBindings.forEach { $0() }
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
        case .profiles: configureProfiles()
        case .shortcuts: configureShortcuts()
        case .content: configureContentSettings()
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
                rows: [row(BrowserStrings.settingsDefaultBrowserPrompt, control: button)]
            ),
            section(BrowserStrings.settingsAccountsCurrentAccounts, body: accountsBody),
        ])
        refreshAccounts()
    }

    private func configureGeneral() {
        let preferences = preferences
        scrollView.setViews([
            section(BrowserStrings.settingsGeneralTab, rows: [
                toggle(
                    "automatic-updates",
                    BrowserStrings.settingsAutomaticUpdates,
                    detail: BrowserStrings.settingsAutomaticUpdatesDetail,
                    get: { preferences.automaticUpdatesEnabled },
                    set: { preferences.automaticUpdatesEnabled = $0 }
                ),
                picker(
                    "update-channel",
                    BrowserStrings.settingsUpdateChannel,
                    detail: BrowserStrings.settingsUpdateChannelDetail,
                    options: BrowserUpdateChannel.allCases,
                    title: { $0.title },
                    get: { preferences.updateChannel },
                    set: { preferences.updateChannel = $0 }
                ),
                picker(
                    "appearance",
                    BrowserStrings.settingsAppearance,
                    detail: BrowserStrings.settingsAppearanceDetail,
                    options: BrowserAppearancePreference.allCases,
                    title: { $0.title },
                    get: { preferences.appearancePreference },
                    set: { preferences.appearancePreference = $0 }
                ),
                picker(
                    "sidebar-position",
                    BrowserStrings.settingsSidebarPosition,
                    options: BrowserSidebarPosition.allCases,
                    title: { $0.title },
                    get: { preferences.sidebarPosition },
                    set: { preferences.sidebarPosition = $0 }
                ),
                toggle(
                    "warn-before-quitting",
                    BrowserStrings.settingsWarnBeforeQuitting,
                    get: { preferences.warnBeforeQuitting },
                    set: { preferences.warnBeforeQuitting = $0 }
                ),
                toggle(
                    "blurred-background",
                    BrowserStrings.settingsBlurredBackground,
                    get: { preferences.blurredChromeBackgroundEnabled },
                    set: { preferences.blurredChromeBackgroundEnabled = $0 }
                ),
                toggle(
                    "battery-saver",
                    BrowserStrings.settingsBatterySaver,
                    detail: BrowserStrings.settingsBatterySaverDetail,
                    get: { preferences.batterySaverEnabled },
                    set: { preferences.batterySaverEnabled = $0 }
                ),
            ]),
            section(BrowserStrings.settingsSearch, rows: [
                picker(
                    "search-engine",
                    BrowserStrings.settingsSearchEngine,
                    options: BrowserSearchEngine.allCases,
                    title: { $0.title },
                    get: { preferences.searchEngine },
                    set: { preferences.searchEngine = $0 }
                ),
                toggle(
                    "search-suggestions",
                    BrowserStrings.settingsSearchSuggestions,
                    get: { preferences.searchEngineSuggestionsEnabled },
                    set: { preferences.searchEngineSuggestionsEnabled = $0 }
                ),
                picker(
                    "ai-search-provider",
                    BrowserStrings.settingsAISearchProvider,
                    options: BrowserAISearchProvider.allCases,
                    title: { $0.title },
                    get: { preferences.aiSearchProvider },
                    set: { preferences.aiSearchProvider = $0 }
                ),
                link(BrowserStrings.settingsManageSearch, url: BrowserSettingsRoute.searchEnginesURL),
            ]),
            section(BrowserStrings.settingsTemporaryTabsTitle, rows: automaticArchivalRows()),
        ])
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
            enabled: { !model.usesSynchronizedAutomaticArchival }
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
            enabled: { model.canConfigureAutomaticTabArchival }
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
            weak errorRow
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
            section(BrowserStrings.settingsProfilesTab, rows: [
                link(BrowserStrings.settingsPrivacyAndSecurity, url: BrowserSettingsRoute.privacyURL),
                link(BrowserStrings.settingsPasswords, url: BrowserSettingsRoute.passwordManagerURL),
                link(BrowserStrings.settingsCreditCards, url: BrowserSettingsRoute.paymentsURL),
                link(BrowserStrings.settingsNotifications, url: BrowserSettingsRoute.notificationsURL),
                link(BrowserStrings.settingsClearBrowsingData, url: BrowserSettingsRoute.privacyURL),
            ]),
        ])
        refreshProfiles()
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
            spacing: 12
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

    private func configureContentSettings() {
        let preferences = preferences
        scrollView.setViews([
            section(BrowserStrings.settingsContentTab, rows: [
                toggle(
                    "haptic-feedback",
                    BrowserStrings.settingsHapticFeedback,
                    get: { preferences.hapticFeedbackEnabled },
                    set: { preferences.hapticFeedbackEnabled = $0 }
                ),
                toggle(
                    "restore-windows",
                    BrowserStrings.settingsRestoreWindows,
                    get: { preferences.restoreWindowsOnLaunch },
                    set: { preferences.restoreWindowsOnLaunch = $0 }
                ),
                toggle(
                    "picture-in-picture",
                    BrowserStrings.settingsPictureInPicture,
                    get: { preferences.pictureInPictureEnabled },
                    set: { preferences.pictureInPictureEnabled = $0 }
                ),
                toggle(
                    "bookmarks-bar",
                    BrowserStrings.settingsShowBookmarksBar,
                    get: { preferences.bookmarksBarVisible },
                    set: { preferences.bookmarksBarVisible = $0 }
                ),
            ]),
            section(BrowserStrings.bookmarksImport, rows: BrowserBookmarkImportSource.allCases.map { source in
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
            }),
            section(BrowserStrings.settingsContentTab, rows: [
                link(BrowserStrings.settingsMoreSettings, url: BrowserSettingsRoute.rootURL),
                link(BrowserStrings.settingsTranslateSitePrompts, url: BrowserSettingsRoute.languageURL),
            ]),
        ])
    }

    private func refreshAccounts() {
        guard pane == .accounts else { return }
        var rows = [NSView]()
        if let accountStore {
            if let session = accountStore.session {
                rows.append(titleDetail(
                    session.userEmail ?? BrowserStrings.syncAccountSignedIn,
                    detail: BrowserStrings.syncAccountDevice(session.deviceID)
                ))
                switch accountStore.bindingState {
                case .needsConsent:
                    rows.append(BrowserNativeControls.label(
                        BrowserStrings.syncAccountEnableDetail, color: .secondaryLabelColor, wraps: true
                    ))
                    rows.append(BrowserActionButton(BrowserStrings.syncAccountEnable) { accountStore.enableSync() })
                case .differentAccount:
                    rows.append(BrowserNativeControls.label(
                        BrowserStrings.syncAccountDifferentOwner, color: .secondaryLabelColor, wraps: true
                    ))
                case .enabled:
                    rows.append(BrowserNativeControls.label(
                        BrowserStrings.syncAccountEnabled, color: .secondaryLabelColor, wraps: true
                    ))
                case nil, .paused: break
                }
                rows.append(BrowserActionButton(BrowserStrings.syncAccountSignOut) { accountStore.signOut() })
            } else {
                rows.append(BrowserNativeControls.label(
                    accountStore.isConfigured
                        ? BrowserStrings.settingsAccountsEmpty
                        : accountStore.unavailableMessage,
                    color: .secondaryLabelColor,
                    wraps: true
                ))
                let signIn = BrowserActionButton(BrowserStrings.syncAccountSignInWithApple) {
                    Task { await accountStore.signInWithApple() }
                }
                signIn.isEnabled = accountStore.isConfigured && !accountStore.isSigningIn
                rows.append(signIn)
            }
            if let error = accountStore.lastError {
                rows.append(BrowserNativeControls.label(
                    error,
                    size: 12,
                    color: .systemRed,
                    wraps: true
                ))
            }
        } else {
            rows.append(BrowserNativeControls.label(
                BrowserStrings.settingsAccountsEmpty,
                color: .secondaryLabelColor
            ))
        }
        accountsBody.spacing = 10
        BrowserNativeControls.replaceViews(rows, in: accountsBody)
        scrollView.needsLayout = true
    }

    private func refreshProfiles() {
        guard pane == .profiles else { return }
        profileDeleteButtons.removeAll()
        let rows = profileStore.profiles.map { profile -> NSView in
            let icon = NSImageView(image: NSImage(
                systemSymbolName: "person.crop.circle",
                accessibilityDescription: nil
            ) ?? NSImage())
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let title = titleDetail(
                profile.displayName,
                detail: BrowserStrings.settingsProfileDirectory(profile.directoryName)
            )
            var items = [NSView]()
            if profile.id == currentProfileID {
                items.append(BrowserNativeControls.label(
                    BrowserStrings.settingsCurrentProfile,
                    size: 12,
                    weight: .semibold,
                    color: .secondaryLabelColor
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
                weight: .semibold
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
                        : "custom"]
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
                wraps: true
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
        set: @escaping (Bool) -> Void
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
        enabled: @escaping () -> Bool = { true }
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
