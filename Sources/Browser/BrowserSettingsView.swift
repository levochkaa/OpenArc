import AppKit
import SwiftUI

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

// MARK: - BrowserSettingsView

struct BrowserSettingsView: View {
    // MARK: Lifecycle

    init(
        model: BrowserChromeModel,
        profileStore: BrowserProfileStore,
        currentProfileID: String,
        accountStore: BrowserAccountStore? = nil,
        pane: BrowserSettingsPane? = nil,
        openProfile: @escaping (BrowserProfile) -> Void,
        openURL: @escaping (URL) -> Void
    ) {
        self.model = model
        _profileStore = ObservedObject(wrappedValue: profileStore)
        self.currentProfileID = currentProfileID
        self.accountStore = accountStore
        self.pane = pane
        self.openProfile = openProfile
        _preferences = ObservedObject(wrappedValue: model.userPreferencesStore)
        _shortcutStore = ObservedObject(wrappedValue: model.shortcutStore)
        self.openURL = openURL
    }

    // MARK: Internal

    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        Group {
            if let pane {
                content(for: pane)
            } else {
                TabView(selection: $selectedTab) {
                    accountsTab
                        .tabItem { Text(BrowserStrings.settingsAccountsTab) }
                        .tag(BrowserSettingsPane.accounts)

                    generalTab
                        .tabItem { Text(BrowserStrings.settingsGeneralTab) }
                        .tag(BrowserSettingsPane.general)

                    profilesTab
                        .tabItem { Text(BrowserStrings.settingsProfilesTab) }
                        .tag(BrowserSettingsPane.profiles)

                    shortcutsTab
                        .tabItem { Text(BrowserStrings.settingsShortcutsTab) }
                        .tag(BrowserSettingsPane.shortcuts)

                    contentTab
                        .tabItem { Text(BrowserStrings.settingsContentTab) }
                        .tag(BrowserSettingsPane.content)
                }
            }
        }
        .frame(width: BrowserSettingsLayout.windowWidth, height: BrowserSettingsLayout.windowHeight)
        .background(settingsBackground.ignoresSafeArea())
        .onAppear(perform: refreshDefaultBrowserState)
    }

    // MARK: Private

    @ObservedObject private var preferences: BrowserUserPreferencesStore
    @ObservedObject private var shortcutStore: BrowserShortcutStore
    @ObservedObject private var profileStore: BrowserProfileStore

    @State private var selectedTab = BrowserSettingsPane.accounts
    @State private var shortcutSearchText = ""
    @State private var recordingCommandID: BrowserCommandID?
    @State private var shortcutConflictMessage: String?
    @State private var profileBackupInProgressID: BrowserProfile.ID?
    @State private var profileBackupMessage: String?
    @State private var isDefaultBrowser = false

    private let currentProfileID: String
    private let openProfile: (BrowserProfile) -> Void
    private let openURL: (URL) -> Void
    private let accountStore: BrowserAccountStore?
    private let pane: BrowserSettingsPane?
    private let defaultBrowserService = BrowserDefaultBrowserService()

    private var settingsBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var filteredCommandIDs: [BrowserCommandID] {
        let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return shortcutStore.commandIDs
        }

        return shortcutStore.commandIDs.filter { commandID in
            let descriptor = shortcutStore.descriptor(for: commandID)
            return descriptor.menuTitle.localizedCaseInsensitiveContains(query)
                || descriptor.helpTitle.localizedCaseInsensitiveContains(query)
                || (descriptor.shortcut.isAssigned
                    && descriptor.shortcut.displayText.localizedCaseInsensitiveContains(query))
        }
    }

    private var accountsTab: some View {
        settingsScrollContent {
            settingsSection(title: BrowserStrings.settingsGeneralTab) {
                defaultBrowserRow
            }

            settingsSection(title: BrowserStrings.settingsAccountsCurrentAccounts) {
                if let accountStore {
                    BrowserAccountSettingsView(accountStore: accountStore)
                } else {
                    Text(BrowserStrings.settingsAccountsEmpty)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var generalTab: some View {
        settingsScrollContent {
            settingsSection(title: BrowserStrings.settingsGeneralTab) {
                toggleRow(
                    title: BrowserStrings.settingsAutomaticUpdates,
                    detail: BrowserStrings.settingsAutomaticUpdatesDetail,
                    isOn: $preferences.automaticUpdatesEnabled
                )

                settingsDivider

                pickerRow(
                    title: BrowserStrings.settingsUpdateChannel,
                    detail: BrowserStrings.settingsUpdateChannelDetail,
                    selection: $preferences.updateChannel
                ) {
                    ForEach(BrowserUpdateChannel.allCases) { channel in
                        Text(channel.title)
                            .tag(channel)
                    }
                }

                settingsDivider

                pickerRow(
                    title: BrowserStrings.settingsAppearance,
                    detail: BrowserStrings.settingsAppearanceDetail,
                    selection: $preferences.appearancePreference
                ) {
                    ForEach(BrowserAppearancePreference.allCases) { preference in
                        Text(preference.title)
                            .tag(preference)
                    }
                }

                settingsDivider

                toggleRow(
                    title: BrowserStrings.settingsWarnBeforeQuitting,
                    isOn: $preferences.warnBeforeQuitting
                )

                settingsDivider

                toggleRow(
                    title: BrowserStrings.settingsBlurredBackground,
                    isOn: $preferences.blurredChromeBackgroundEnabled
                )

                settingsDivider

                toggleRow(
                    title: BrowserStrings.settingsBatterySaver,
                    detail: BrowserStrings.settingsBatterySaverDetail,
                    isOn: $preferences.batterySaverEnabled
                )
            }

            searchSettingsSection

            settingsSection(title: BrowserStrings.settingsTemporaryTabsTitle) {
                pickerRow(
                    title: BrowserStrings.settingsTemporaryTabsLifetimeLabel,
                    selection: Binding(
                        get: { model.temporaryTabLifetime },
                        set: { model.setTemporaryTabLifetime($0) }
                    )
                ) {
                    ForEach(BrowserTemporaryTabLifetime.allCases, id: \.self) { lifetime in
                        Text(BrowserStrings.title(for: lifetime))
                            .tag(lifetime)
                    }
                }
            }
        }
    }

    private var profilesTab: some View {
        settingsScrollContent {
            Text(BrowserStrings.settingsProfilesIntro)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            settingsSection(title: BrowserStrings.settingsProfilesTab) {
                ForEach(profileStore.profiles) { profile in
                    profileRow(profile)

                    if profile.id != profileStore.profiles.last?.id {
                        settingsDivider
                    }
                }
            }

            if let profileBackupMessage {
                Text(profileBackupMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                let profile = profileStore.createProfile()
                openProfile(profile)
            } label: {
                Label(BrowserStrings.settingsNewProfile, systemImage: "plus")
            }

            settingsSection(title: BrowserStrings.settingsProfilesTab) {
                linkButton(title: BrowserStrings.settingsPrivacyAndSecurity, url: BrowserSettingsRoute.privacyURL)
                settingsDivider
                linkButton(title: BrowserStrings.settingsPasswords, url: BrowserSettingsRoute.passwordManagerURL)
                settingsDivider
                linkButton(title: BrowserStrings.settingsCreditCards, url: BrowserSettingsRoute.paymentsURL)
                settingsDivider
                linkButton(title: BrowserStrings.settingsNotifications, url: BrowserSettingsRoute.notificationsURL)
                settingsDivider
                linkButton(title: BrowserStrings.settingsClearBrowsingData, url: BrowserSettingsRoute.privacyURL)
            }
        }
    }

    private var searchSettingsSection: some View {
        settingsSection(title: BrowserStrings.settingsSearch) {
            pickerRow(
                title: BrowserStrings.settingsSearchEngine,
                selection: $preferences.searchEngine
            ) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.title)
                        .tag(engine)
                }
            }

            settingsDivider

            toggleRow(
                title: BrowserStrings.settingsSearchSuggestions,
                isOn: $preferences.searchEngineSuggestionsEnabled
            )

            settingsDivider

            pickerRow(
                title: BrowserStrings.settingsAISearchProvider,
                selection: $preferences.aiSearchProvider
            ) {
                ForEach(BrowserAISearchProvider.allCases) { provider in
                    Text(provider.title)
                        .tag(provider)
                }
            }

            settingsDivider

            linkButton(title: BrowserStrings.settingsManageSearch, url: BrowserSettingsRoute.searchEnginesURL)
        }
    }

    private var shortcutsTab: some View {
        settingsScrollContent {
            HStack(spacing: 12) {
                TextField(BrowserStrings.settingsShortcutsSearchPlaceholder, text: $shortcutSearchText)
                    .textFieldStyle(.roundedBorder)

                Button(BrowserStrings.settingsShortcutResetAll) {
                    shortcutStore.resetAllShortcuts()
                    recordingCommandID = nil
                    shortcutConflictMessage = nil
                }

                Button(BrowserStrings.settingsExtensionShortcuts) {
                    openURL(BrowserSettingsRoute.extensionShortcutsURL)
                }
            }

            if let shortcutConflictMessage {
                Text(shortcutConflictMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsSection(title: BrowserStrings.settingsShortcutsTab) {
                ForEach(filteredCommandIDs) { commandID in
                    shortcutRow(for: commandID)

                    if commandID != filteredCommandIDs.last {
                        settingsDivider
                    }
                }
            }
        }
    }

    private var contentTab: some View {
        settingsScrollContent {
            settingsSection(title: BrowserStrings.settingsContentTab) {
                toggleRow(
                    title: BrowserStrings.settingsHapticFeedback,
                    isOn: $preferences.hapticFeedbackEnabled
                )

                settingsDivider

                toggleRow(
                    title: BrowserStrings.settingsRestoreWindows,
                    isOn: $preferences.restoreWindowsOnLaunch
                )

                settingsDivider

                toggleRow(
                    title: BrowserStrings.settingsPictureInPicture,
                    isOn: $preferences.pictureInPictureEnabled
                )

                settingsDivider

                toggleRow(
                    title: BrowserStrings.settingsShowBookmarksBar,
                    isOn: $preferences.bookmarksBarVisible
                )
            }

            bookmarksImportSection

            settingsSection(title: BrowserStrings.settingsContentTab) {
                linkButton(title: BrowserStrings.settingsMoreSettings, url: BrowserSettingsRoute.rootURL)
                settingsDivider
                linkButton(title: BrowserStrings.settingsTranslateSitePrompts, url: BrowserSettingsRoute.languageURL)
            }
        }
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 1)
    }

    private var bookmarksImportSection: some View {
        settingsSection(title: BrowserStrings.bookmarksImport) {
            ForEach(BrowserBookmarkImportSource.allCases) { source in
                bookmarkImportButton(for: source)

                if source.id != BrowserBookmarkImportSource.allCases.last?.id {
                    settingsDivider
                }
            }
        }
    }

    private var defaultBrowserRow: some View {
        HStack(spacing: 16) {
            Text(BrowserStrings.settingsDefaultBrowserPrompt)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(BrowserStrings.settingsDefaultBrowserAction) {
                _ = defaultBrowserService.setAsDefaultBrowser()
                refreshDefaultBrowserState()
            }
            .disabled(isDefaultBrowser)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func content(for pane: BrowserSettingsPane) -> some View {
        switch pane {
        case .accounts:
            accountsTab
        case .general:
            generalTab
        case .profiles:
            profilesTab
        case .shortcuts:
            shortcutsTab
        case .content:
            contentTab
        }
    }

    private func settingsScrollContent(
        @ViewBuilder content: () -> some View
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSettingsLayout.contentSpacing) {
                content()
            }
            .padding(BrowserSettingsLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(settingsBackground)
        .scrollContentBackground(.hidden)
    }

    private func settingsSection(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: BrowserSettingsLayout.rowSpacing) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bookmarkImportButton(for source: BrowserBookmarkImportSource) -> some View {
        Button {
            _ = model.importBookmarks(from: source)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(source.title)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    private func toggleRow(
        title: String,
        detail: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 16) {
            titleDetailLabel(title: title, detail: detail)

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }

    private func profileRow(_ profile: BrowserProfile) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                titleDetailLabel(
                    title: profile.displayName,
                    detail: BrowserStrings.settingsProfileDirectory(profile.directoryName)
                )
            }

            Spacer(minLength: 0)

            if profile.id == currentProfileID {
                Text(BrowserStrings.settingsCurrentProfile)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button(BrowserStrings.settingsOpenProfile) {
                    openProfile(profile)
                }
            }

            Button(BrowserStrings.settingsBackUpProfile) {
                createProfileBackup(profile)
            }
            .disabled(profileBackupInProgressID != nil)

            Button(BrowserStrings.settingsDeleteProfile, role: .destructive) {
                _ = profileStore.deleteProfile(profile)
            }
            .disabled(profile.id == currentProfileID || profile.isDefault)
        }
        .padding(.vertical, 6)
    }

    private func pickerRow(
        title: String,
        detail: String? = nil,
        selection: Binding<some Hashable>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 16) {
            titleDetailLabel(title: title, detail: detail)

            Spacer(minLength: 0)

            Picker("", selection: selection) {
                content()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: BrowserSettingsLayout.pickerWidth, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func linkButton(title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    private func titleDetailLabel(title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(for commandID: BrowserCommandID) -> some View {
        let descriptor = shortcutStore.descriptor(for: commandID)
        let isRecording = recordingCommandID == commandID

        return HStack(spacing: 12) {
            titleDetailLabel(title: descriptor.menuTitle)

            Spacer(minLength: 0)

            if isRecording {
                shortcutCapture(for: commandID)
            } else {
                Text(
                    descriptor.shortcut.isAssigned
                        ? descriptor.shortcut.displayText
                        : BrowserStrings.settingsShortcutNotSet
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: BrowserSettingsLayout.shortcutCaptureWidth, alignment: .trailing)
            }

            Button(isRecording ? BrowserStrings.settingsShortcutPressShortcut : BrowserStrings.settingsShortcutRecord) {
                recordingCommandID = isRecording ? nil : commandID
                shortcutConflictMessage = nil
            }
            .frame(width: 92)

            Button(BrowserStrings.settingsShortcutReset) {
                shortcutStore.resetShortcut(for: commandID)
                if recordingCommandID == commandID {
                    recordingCommandID = nil
                }
                shortcutConflictMessage = nil
            }
            .disabled(!shortcutStore.isCustomized(commandID))
            .frame(width: 72)
        }
        .padding(.vertical, 6)
    }

    private func shortcutCapture(for commandID: BrowserCommandID) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 1)

            Text(BrowserStrings.settingsShortcutPressShortcut)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            BrowserShortcutCaptureView(
                onCapture: { shortcut in
                    apply(shortcut, to: commandID)
                },
                onCancel: {
                    recordingCommandID = nil
                }
            )
        }
        .frame(width: BrowserSettingsLayout.shortcutCaptureWidth, height: 28)
    }

    private func refreshDefaultBrowserState() {
        isDefaultBrowser = defaultBrowserService.isDefaultBrowser
    }

    private func apply(_ shortcut: BrowserKeyboardShortcut, to commandID: BrowserCommandID) {
        if shortcutStore.setShortcut(shortcut, for: commandID) {
            recordingCommandID = nil
            shortcutConflictMessage = nil
            return
        }

        let conflictTitle = shortcutStore.conflictDescription(for: shortcut, excluding: commandID) ?? ""
        shortcutConflictMessage = BrowserStrings.settingsShortcutConflict(conflictTitle)
    }

    private func createProfileBackup(_ profile: BrowserProfile) {
        let rootCacheURL = profileStore.rootCacheURL
        profileBackupInProgressID = profile.id
        profileBackupMessage = nil

        Task { @MainActor in
            do {
                let backupURL = try await Task.detached {
                    try BrowserProfileBackupArchiver(rootCacheURL: rootCacheURL).createBackup(for: profile)
                }
                .value
                profileBackupInProgressID = nil
                profileBackupMessage = BrowserStrings.settingsProfileBackupCreated(backupURL.lastPathComponent)
                BrowserTelemetry.captureUsage(
                    .profileBackupCreated,
                    properties: ["profile": profile.isDefault ? "default" : "custom"]
                )
                NSWorkspace.shared.activateFileViewerSelecting([backupURL])
            } catch {
                profileBackupInProgressID = nil
                profileBackupMessage = BrowserStrings.settingsProfileBackupFailed(error.localizedDescription)
                BrowserTelemetry.captureError(
                    error,
                    event: .profileBackupFailed,
                    properties: ["profile": profile.isDefault ? "default" : "custom"]
                )
            }
        }
    }
}

// MARK: - BrowserAccountSettingsView

private struct BrowserAccountSettingsView: View {
    // MARK: Internal

    @ObservedObject var accountStore: BrowserAccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = accountStore.session {
                titleDetailLabel(
                    title: session.userEmail ?? BrowserStrings.syncAccountSignedIn,
                    detail: BrowserStrings.syncAccountDevice(session.deviceID)
                )

                Button(BrowserStrings.syncAccountSignOut) {
                    accountStore.signOut()
                }
            } else {
                Text(accountStore.isConfigured
                    ? BrowserStrings.settingsAccountsEmpty
                    : BrowserStrings
                        .syncAccountServerNotConfigured)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Button(BrowserStrings.syncAccountSignInWithApple) {
                    Task {
                        await accountStore.signInWithApple()
                    }
                }
                .disabled(!accountStore.isConfigured || accountStore.isSigningIn)
            }

            if let lastError = accountStore.lastError {
                Text(lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    private func titleDetailLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - BrowserShortcutCaptureView

private struct BrowserShortcutCaptureView: NSViewRepresentable {
    let onCapture: (BrowserKeyboardShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> BrowserShortcutCaptureNSView {
        let view = BrowserShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: BrowserShortcutCaptureNSView, context _: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel

        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

// MARK: - BrowserShortcutCaptureNSView

private final class BrowserShortcutCaptureNSView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }

    var onCapture: ((BrowserKeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        guard let shortcut = BrowserKeyboardShortcut(recordedEvent: event) else {
            NSSound.beep()
            return
        }

        onCapture?(shortcut)
    }
}

private extension BrowserKeyboardShortcut {
    init?(recordedEvent event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.contains(.command) else {
            return nil
        }

        guard
            let characters = event.charactersIgnoringModifiers?.lowercased(),
            let firstCharacter = characters.first,
            String(firstCharacter).rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return nil
        }

        self.init(String(firstCharacter), modifiers: modifiers)
    }
}
