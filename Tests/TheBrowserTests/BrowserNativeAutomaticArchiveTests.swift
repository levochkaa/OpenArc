import AppKit
import GRDB
import Testing

// MARK: - BrowserNativeAutomaticArchiveTests

@Suite(.serialized) @MainActor struct BrowserNativeAutomaticArchiveTests {
    @Test(arguments: ["enabled", "paused", "signed-out"])
    func boundProfileRetainsOffUntilNativeSelectionAndPersistsOffAcrossReopen(state: String) async throws {
        try await withNativeAutomaticArchive(state: state) { f in
            let controller = f.controller()
            let popup = try f.popup("automatic-tab-archival", in: controller)
            let local = try f.popup("temporary-tab-lifetime", in: controller)
            #expect(popup.numberOfItems == 6)
            let expectedTitles = [
                BrowserStrings.settingsAutomaticArchivalOff,
                BrowserStrings.title(for: .twelveHours),
                BrowserStrings.title(for: .twentyFourHours),
                BrowserStrings.title(for: .threeDays),
                BrowserStrings.title(for: .sevenDays),
                BrowserStrings.settingsAutomaticArchivalThirtyDays,
            ]
            #expect(popup.itemTitles == expectedTitles)
            #expect(popup.indexOfSelectedItem == 0 && popup.isEnabled)
            #expect(local.isHiddenOrHasHiddenAncestor)
            #expect(f.model.temporaryTabLifetime == .thirtyDays && !f.model.automaticTabArchivalEnabled)
            let queue = try f.queueBytes()
            let before = try f.store.loadSnapshotStrict()
            try f.choose(1, popup: popup)
            #expect(popup.indexOfSelectedItem == 1)
            #expect(f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .twelveHours)
            #expect(try f.store.loadAutomaticTabArchivalSettings().enabled)
            #expect(try f.store.loadAutomaticTabArchivalSettings().lifetime == .twelveHours)
            try f.choose(0, popup: popup)
            #expect(!f.model.automaticTabArchivalEnabled && popup.indexOfSelectedItem == 0)
            #expect(f.model.temporaryTabLifetime == .twelveHours)
            let reopenedStore = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try !reopenedStore.loadAutomaticTabArchivalSettings().enabled)
            #expect(try reopenedStore.loadAutomaticTabArchivalSettings().lifetime == .twelveHours)
            let reopened = f.makeModel(store: reopenedStore)
            defer { f.stop(reopened) }
            let reopenedController = f.controller(model: reopened)
            let reopenedPopup = try f.popup("automatic-tab-archival", in: reopenedController)
            #expect(reopenedPopup.indexOfSelectedItem == 0 && reopenedPopup.isEnabled)
            #expect(try f.store.loadSnapshotStrict() == before)
            #expect(try f.queueBytes() == queue)
            #expect(f.driver.createdTabRequests.isEmpty)
        }
    }

    @Test func failedNativeEnableAndOffKeepCommittedChoiceAndRetryExactRequestedValue() async throws {
        try await withNativeAutomaticArchive(state: "enabled") { f in
            let controller = f.controller()
            let popup = try f.popup("automatic-tab-archival", in: controller)
            let retry = try #require(nativeAutomaticArchiveView(
                "automatic-tab-archival-retry",
                in: controller.view
            ) as? BrowserActionButton)
            let message = try #require(nativeAutomaticArchiveView(
                "temporary-tab-error",
                in: controller.view
            ) as? NSTextField)
            let before = try f.queueBytes()
            try f.installPreferenceFailure()
            try f.choose(3, popup: popup)
            #expect(popup.indexOfSelectedItem == 0, "A rejected save cannot leave the requested value selected")
            #expect(!f.model.automaticTabArchivalEnabled)
            #expect(f.model.temporaryTabLifetime == .thirtyDays)
            #expect(try !f.store.loadAutomaticTabArchivalSettings().enabled)
            #expect(message.stringValue == BrowserStrings.settingsTemporaryTabsSaveFailed)
            #expect(!retry.isHiddenOrHasHiddenAncestor && retry.isEnabled)
            try f.sql("DROP TRIGGER fail_archival_setting")
            retry.performClick(nil)
            #expect(popup.indexOfSelectedItem == 3)
            #expect(f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .threeDays)
            #expect(try f.store.loadAutomaticTabArchivalSettings().lifetime == .threeDays)
            #expect(retry.isHiddenOrHasHiddenAncestor)

            try f.installPreferenceFailure()
            try f.choose(0, popup: popup)
            #expect(popup.indexOfSelectedItem == 3 && f.model.automaticTabArchivalEnabled)
            #expect(try f.store.loadAutomaticTabArchivalSettings().enabled)
            #expect(retry.isEnabled)
            try f.sql("DROP TRIGGER fail_archival_setting")
            retry.performClick(nil)
            #expect(popup.indexOfSelectedItem == 0 && !f.model.automaticTabArchivalEnabled)
            #expect(try !f.store.loadAutomaticTabArchivalSettings().enabled)
            #expect(try f.store.loadAutomaticTabArchivalSettings().lifetime == .threeDays)
            #expect(try f.queueBytes() == before)
            controller.view.layoutSubtreeIfNeeded()
            for control in [popup, retry] where !control.isHiddenOrHasHiddenAncestor {
                #expect(control.frame.width > 0 && control.frame.height > 0)
            }
        }
    }

    @Test func unreadableSettingsStayOffAndNativeRetryReadsWithoutEnablingRetainedLifetime() async throws {
        try await withNativeAutomaticArchive(state: "corrupt") { f in
            let controller = f.controller()
            let popup = try f.popup("automatic-tab-archival", in: controller)
            let retry = try #require(nativeAutomaticArchiveView(
                "automatic-tab-archival-retry",
                in: controller.view
            ) as? BrowserActionButton)
            let message = try #require(nativeAutomaticArchiveView(
                "temporary-tab-error",
                in: controller.view
            ) as? NSTextField)
            #expect(popup.indexOfSelectedItem == 0 && popup.isEnabled)
            #expect(message.stringValue == BrowserStrings.settingsTemporaryTabsLoadFailed)
            #expect(retry.isEnabled && !retry.isHiddenOrHasHiddenAncestor)
            retry.performClick(nil)
            #expect(message.stringValue == BrowserStrings.settingsTemporaryTabsLoadFailed)
            #expect(popup.indexOfSelectedItem == 0)
            try f
                .sql(
                    "UPDATE browser_preferences SET value='0' WHERE key='browser.settings.automaticTabArchivalEnabled'"
                )
            retry.performClick(nil)
            #expect(popup.indexOfSelectedItem == 0 && !f.model.automaticTabArchivalEnabled)
            #expect(f.model.temporaryTabLifetime == .thirtyDays)
            #expect(retry.isHiddenOrHasHiddenAncestor)
            try f
                .sql(
                    "UPDATE browser_preferences SET value='invalid' WHERE key='browser.settings.automaticTabArchivalEnabled'"
                )
            #expect(!f.model.reloadAutomaticTabArchivalSettings())
            controller.viewWillAppear()
            try f.choose(2, popup: popup)
            #expect(popup.indexOfSelectedItem == 2)
            #expect(try f.store.loadAutomaticTabArchivalSettings().enabled)
            #expect(try f.store.loadAutomaticTabArchivalSettings().lifetime == .twentyFourHours)
            #expect(retry.isHiddenOrHasHiddenAncestor)
        }
    }

    @Test func neverBoundLifetimePickerKeepsExistingDefaultAndBindingSwitchesToOffWithoutRebuildingPane() async throws {
        try await withNativeAutomaticArchive(state: "local") { f in
            let controller = f.controller()
            let local = try f.popup("temporary-tab-lifetime", in: controller)
            let synchronized = try f.popup("automatic-tab-archival", in: controller)
            #expect(!local.isHiddenOrHasHiddenAncestor && local.isEnabled)
            #expect(synchronized.isHiddenOrHasHiddenAncestor)
            #expect(local.itemTitles == BrowserTemporaryTabLifetime.allCases.map(BrowserStrings.title))
            #expect(local.titleOfSelectedItem == BrowserStrings.title(for: .thirtyDays))
            try f.choose(2, popup: local)
            #expect(f.model.temporaryTabLifetime == .threeDays)
            #expect(try !f.store.loadAutomaticTabArchivalSettings().enabled)
            #expect(try f.store.syncOwner() == nil)
            try f.store.bindSyncOwner(f.owner)
            #expect(f.model.reloadAutomaticTabArchivalSettings())
            controller.viewWillAppear()
            #expect(local.isHiddenOrHasHiddenAncestor)
            #expect(!synchronized.isHiddenOrHasHiddenAncestor && synchronized.isEnabled)
            #expect(synchronized.indexOfSelectedItem == 0)
            #expect(f.model.temporaryTabLifetime == .threeDays)
            #expect(nativeAutomaticArchiveView("temporary-tab-lifetime", in: controller.view) === local)
            #expect(nativeAutomaticArchiveView("automatic-tab-archival", in: controller.view) === synchronized)
        }
    }
}

@MainActor private func nativeAutomaticArchiveView(_ id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == "browser.settings." + id {
        return view
    }
    return view.subviews.lazy.compactMap { nativeAutomaticArchiveView(id, in: $0) }.first
}

@MainActor private func withNativeAutomaticArchive(
    state: String,
    _ body: @MainActor (NativeAutomaticArchiveFixture) async throws -> Void
) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runNativeAutomaticArchive(directory: directory, state: state, body)
}

@MainActor private func runNativeAutomaticArchive(
    directory: URL,
    state: String,
    _ body: @MainActor (NativeAutomaticArchiveFixture) async throws -> Void
) async throws {
    let fixture = try NativeAutomaticArchiveFixture(directory: directory, state: state)
    defer { fixture.stop(fixture.model)
        fixture.preferences.removePersistentDomain(forName: fixture.suite)
    }
    try await body(fixture)
}

// MARK: - NativeAutomaticArchiveFixture

@MainActor private final class NativeAutomaticArchiveFixture {
    // MARK: Lifecycle

    init(directory: URL, state: String) throws {
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.preferences = try #require(UserDefaults(suiteName: suite))
        self.profiles = BrowserProfileStore(rootCacheURL: directory.appendingPathComponent("Profiles"))
        try store.writeSessionBatch([.init(snapshot: .init(
            spaces: [.init(id: "work", title: "Work", systemImageName: "globe")],
            tabs: [.init(
                id: "active",
                urlString: "https://active.example",
                spaceID: "work",
                lastActivityTimestamp: 100
            )]
        ), origin: .local(syncMove: nil))])
        try store.saveTemporaryTabLifetimeStrict(.thirtyDays)
        if state != "local" {
            try store.bindSyncOwner(owner)
        }
        if state == "paused" {
            try store.pauseSync()
        }
        if state == "signed-out" {
            try store.requireSyncSignIn()
        }
        if state == "corrupt" {
            try DatabaseQueue(path: databaseURL.path).write { db in
                try db
                    .execute(
                        sql: "INSERT INTO browser_preferences(key,value) VALUES ('browser.settings.automaticTabArchivalEnabled','invalid')"
                    )
            }
        }
        self.model = makeModel(store: store)
    }

    // MARK: Internal

    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let profiles: BrowserProfileStore
    let preferences: UserDefaults
    let suite = "NativeAutomaticArchive." + UUID().uuidString
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://native-automatic-archive.example")!, userID: "owner")
    let driver = FakeBrowserTabDriver()
    private(set) var model: BrowserChromeModel!

    func makeModel(store: BrowserSQLiteSessionStore) -> BrowserChromeModel {
        BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: store,
            sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: preferences),
            shortcutStore: BrowserShortcutStore(userDefaults: preferences),
            extensionManager: FakeBrowserExtensionManager(),
            dateProvider: { Date(timeIntervalSince1970: 100) },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )
    }

    func controller(model: BrowserChromeModel? = nil) -> BrowserSettingsViewController {
        BrowserSettingsViewController(
            model: model ?? self.model,
            profileStore: profiles,
            currentProfileID: BrowserProfile.defaultProfile.id,
            accountStore: nil,
            pane: .general,
            openProfile: { _ in },
            openURL: { _ in }
        )
    }

    func popup(_ id: String, in controller: BrowserSettingsViewController) throws -> BrowserActionPopUpButton {
        try #require(nativeAutomaticArchiveView(id, in: controller.view) as? BrowserActionPopUpButton)
    }

    func choose(_ index: Int, popup: BrowserActionPopUpButton) throws {
        try #require(popup.isEnabled && popup.itemArray.indices.contains(index))
        popup.selectItem(at: index)
        #expect(popup.sendAction(popup.action, to: popup.target))
    }

    func stop(_ model: BrowserChromeModel) {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
    }

    func sql(_ query: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: query) } }

    func queueBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { try Data.fetchAll(
            $0,
            sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"
        ) }
    }

    func installPreferenceFailure() throws {
        try sql(
            "CREATE TRIGGER fail_archival_setting BEFORE INSERT ON browser_preferences WHEN NEW.key IN ('browser.settings.automaticTabArchivalEnabled','browser.settings.temporaryTabLifetime') BEGIN SELECT RAISE(ABORT,'injected'); END"
        )
    }
}
