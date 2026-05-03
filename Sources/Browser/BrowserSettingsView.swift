import AppKit
import SwiftUI

enum BrowserSettingsLayout {
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 560
    static let contentPadding: CGFloat = 24
    static let contentSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    static let pickerWidth: CGFloat = 190
    static let shortcutCaptureWidth: CGFloat = 132
}

struct BrowserSettingsView: View {
    private enum Tab: Hashable {
        case accounts
        case general
        case profiles
        case shortcuts
        case content
    }

    @ObservedObject var model: BrowserChromeModel
    @ObservedObject private var preferences: BrowserUserPreferencesStore
    @ObservedObject private var shortcutStore: BrowserShortcutStore

    @State private var selectedTab: Tab = .accounts
    @State private var shortcutSearchText = ""
    @State private var recordingCommandID: BrowserCommandID?
    @State private var shortcutConflictMessage: String?

    private let openURL: (URL) -> Void

    init(model: BrowserChromeModel, openURL: @escaping (URL) -> Void) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.userPreferencesStore)
        _shortcutStore = ObservedObject(wrappedValue: model.shortcutStore)
        self.openURL = openURL
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            accountsTab
                .tabItem { Text(BrowserStrings.settingsAccountsTab) }
                .tag(Tab.accounts)

            generalTab
                .tabItem { Text(BrowserStrings.settingsGeneralTab) }
                .tag(Tab.general)

            profilesTab
                .tabItem { Text(BrowserStrings.settingsProfilesTab) }
                .tag(Tab.profiles)

            shortcutsTab
                .tabItem { Text(BrowserStrings.settingsShortcutsTab) }
                .tag(Tab.shortcuts)

            contentTab
                .tabItem { Text(BrowserStrings.settingsContentTab) }
                .tag(Tab.content)
        }
        .frame(width: BrowserSettingsLayout.windowWidth, height: BrowserSettingsLayout.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accountsTab: some View {
        settingsScrollContent {
            settingsSection(title: BrowserStrings.settingsAccountsCurrentAccounts) {
                Text(BrowserStrings.settingsAccountsEmpty)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                toggleRow(
                    title: BrowserStrings.settingsWarnBeforeQuitting,
                    isOn: $preferences.warnBeforeQuitting
                )
            }

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
                detailRow(
                    title: BrowserStrings.settingsDefaultProfile,
                    detail: BrowserStrings.settingsDefaultProfileDetail
                )
            }

            settingsSection(title: BrowserStrings.settingsSearchEngine) {
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

                linkButton(title: BrowserStrings.settingsManageSearch, url: BrowserSettingsRoute.searchEnginesURL)
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
            }

            settingsSection(title: BrowserStrings.settingsContentTab) {
                linkButton(title: BrowserStrings.settingsMoreSettings, url: BrowserSettingsRoute.rootURL)
                settingsDivider
                linkButton(title: BrowserStrings.settingsTranslateSitePrompts, url: BrowserSettingsRoute.languageURL)
            }
        }
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
                || descriptor.shortcut.displayText.localizedCaseInsensitiveContains(query)
        }
    }

    private func settingsScrollContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSettingsLayout.contentSpacing) {
                content()
            }
            .padding(BrowserSettingsLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
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

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 1)
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

    private func detailRow(title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            titleDetailLabel(title: title, detail: detail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func pickerRow<Selection: Hashable, Content: View>(
        title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            titleDetailLabel(title: title)

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
                Text(descriptor.shortcut.displayText)
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

    private func apply(_ shortcut: BrowserKeyboardShortcut, to commandID: BrowserCommandID) {
        if shortcutStore.setShortcut(shortcut, for: commandID) {
            recordingCommandID = nil
            shortcutConflictMessage = nil
            return
        }

        let conflictTitle = shortcutStore.conflictDescription(for: shortcut, excluding: commandID) ?? ""
        shortcutConflictMessage = BrowserStrings.settingsShortcutConflict(conflictTitle)
    }
}

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

private final class BrowserShortcutCaptureNSView: NSView {
    var onCapture: ((BrowserKeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

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
