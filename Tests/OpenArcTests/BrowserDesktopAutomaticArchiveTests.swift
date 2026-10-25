import AppKit
import Combine
import GRDB
import Testing

// MARK: - BrowserDesktopAutomaticArchiveTests

@Suite(.serialized) @MainActor struct BrowserDesktopAutomaticArchiveTests {
    @Test func boundAutomaticArchiveRequiresOptInAndPersistsOffWithoutResettingTheInterval() throws {
        let f = try DesktopAutomaticArchiveFixture()
        defer { f.close() }
        f.restore()
        #expect(f.model.usesSynchronizedAutomaticArchival)
        #expect(f.model.canConfigureAutomaticTabArchival)
        #expect(!f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .thirtyDays)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        let before = try f.evidence()
        #expect(f.model.setAutomaticTabArchival(lifetime: .threeDays))
        #expect(f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .threeDays)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == 259_200)
        #expect(f.sync.sweeps > 0)
        #expect(try f.evidence() == before, "Changing timing must not directly delete or queue a tab")
        f.restart()
        f.restore()
        #expect(f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .threeDays)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == 259_200)
        #expect(f.model.setAutomaticTabArchival(lifetime: nil))
        #expect(!f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .threeDays)
        f.restart()
        f.restore()
        #expect(!f.model.automaticTabArchivalEnabled && f.model.temporaryTabLifetime == .threeDays)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        #expect(f.driver.closedTabRequests.isEmpty)
    }

    @Test(arguments: [DesktopAutomaticChoice.enable, .change, .off])
    func failedSettingTransactionKeepsBothValuesAndRetryReplaysTheExactChoice(choice: DesktopAutomaticChoice) throws {
        let f = try DesktopAutomaticArchiveFixture()
        defer { f.close() }
        f.restore()
        if choice != .enable {
            #expect(f.model.setAutomaticTabArchival(lifetime: .twelveHours))
        }
        let old = try f.store.loadAutomaticTabArchivalSettings()
        try f.store.saveAutomaticTabArchival(enabled: old.enabled, lifetime: old.lifetime)
        let before = try f.evidence()
        let sweeps = f.sync.sweeps
        try f.sql("""
        CREATE TRIGGER fail_timing BEFORE UPDATE ON browser_preferences
        WHEN NEW.key='browser.settings.temporaryTabLifetime'
        BEGIN SELECT RAISE(ABORT,'injected second-key failure'); END
        """)
        let target: BrowserTemporaryTabLifetime? = choice == .off ? nil : .threeDays
        #expect(!f.model.setAutomaticTabArchival(lifetime: target))
        let failed = try f.store.loadAutomaticTabArchivalSettings()
        #expect(failed.enabled == old.enabled && failed.lifetime == old.lifetime)
        #expect(f.model.automaticTabArchivalEnabled == old.enabled && f.model.temporaryTabLifetime == old.lifetime)
        #expect(f.model.automaticArchivalSettingsError != nil && f.model.canRetryAutomaticTabArchivalSettings)
        #expect(f.sync.sweeps == sweeps)
        #expect(try f.evidence() == before)
        try f.sql("DROP TRIGGER fail_timing")
        #expect(f.model.retryAutomaticTabArchivalSettings())
        let saved = try f.store.loadAutomaticTabArchivalSettings()
        #expect(saved.enabled == (target != nil) && saved.lifetime == (target ?? old.lifetime))
        #expect(f.model.automaticTabArchivalEnabled == saved.enabled && f.model.temporaryTabLifetime == saved.lifetime)
        #expect(f.model.automaticArchivalSettingsError == nil && !f.model.canRetryAutomaticTabArchivalSettings)
        #expect(f.sync.sweeps > sweeps)
        #expect(try f.evidence() == before)
    }

    @Test(arguments: [false, true])
    func strictSettingsFailureBlocksAdmissionUntilSuccessfulReload(missingTable: Bool) throws {
        let f = try DesktopAutomaticArchiveFixture()
        defer { f.close() }
        f.restore()
        #expect(f.model.setAutomaticTabArchival(lifetime: .twelveHours))
        if missingTable {
            try f.sql("ALTER TABLE browser_preferences RENAME TO unavailable_preferences")
        } else {
            try f
                .sql(
                    "UPDATE browser_preferences SET value='invalid' WHERE key='browser.settings.automaticTabArchivalEnabled'"
                )
        }
        #expect(!f.model.reloadAutomaticTabArchivalSettings())
        #expect(f.model.expirySchedulingState() == nil)
        #expect(!f.model.refreshExpiryActivity())
        #expect(f.model.automaticArchivalSettingsError != nil && f.model.canRetryAutomaticTabArchivalSettings)
        if missingTable {
            try f.sql("ALTER TABLE unavailable_preferences RENAME TO browser_preferences")
        } else {
            try f.store.saveAutomaticTabArchival(enabled: true, lifetime: .threeDays)
        }
        #expect(
            f.model.expirySchedulingState() == nil,
            "A successful repair alone must not silently clear failed admission"
        )
        #expect(f.model.retryAutomaticTabArchivalSettings())
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == (missingTable ? 43200 : 259_200))
        #expect(f.model.automaticArchivalSettingsError == nil)
        #expect(f.driver.closedTabRequests.isEmpty)
    }

    @Test func enabledDelegateRechecksSelectionPendingEnginesPersistenceBackgroundAndArchiveOperation() async throws {
        let f = try DesktopAutomaticArchiveFixture()
        defer { f.close() }
        #expect(f.model.setAutomaticTabArchival(lifetime: .twelveHours))
        #expect(f.model.expirySchedulingState() == nil)
        f.model.handleContextReady()
        f.driver.flushPendingCreateEvents()
        #expect(f.model.expirySchedulingState() == nil)
        f.makeReady()
        #expect(f.model.expirySchedulingState()?.protectedTabIDs == ["a"])
        let b = try #require(f.model.tabs.first { $0.syncID == "b" })
        f.model.selectTab(id: b.id)
        #expect(f.model.expirySchedulingState()?.protectedTabIDs == ["b"])
        f.model.createNewTab()
        #expect(f.model.expirySchedulingState() == nil)
        f.driver.flushPendingCreateEvents()
        let pending = try #require(f.model.tabs.first { $0.id == f.model.selectedTabID })
        f.driver.emitTabCreationState(id: pending.id, state: .failed)
        #expect(f.model.expirySchedulingState() == nil)
        f.driver.emitTabCreationState(id: pending.id, state: .ready)
        #expect(f.model.expirySchedulingState() == nil, "Late readiness must not revive a failed allocation")
        #expect(f.model.retrySelectedTabCreation())
        #expect(f.driver.retryCreationRequests.last?.id == pending.id)
        #expect(f.model.expirySchedulingState() == nil)
        f.driver.emitTabCreationState(id: pending.id, state: .ready)
        #expect(f.model.expirySchedulingState()?.protectedTabIDs == [pending.syncID])
        let loaded = try #require(try f.store.loadSnapshotStrict())
        let remote = BrowserTabSessionSnapshot(
            spaces: loaded.spaces,
            pinnedTabFolders: loaded.pinnedTabFolders,
            tabs: loaded.tabs + [.init(
                id: "remote-pending",
                urlString: "https://example.com/remote",
                spaceID: "work",
                lastActivityTimestamp: f.clock.now
            )]
        )
        try f.store.writeSessionBatch([.init(snapshot: remote, origin: .remoteProjection)])
        f.model.applyRemoteSyncSnapshot(remote)
        #expect(f.model.expirySchedulingState() == nil)
        f.driver.flushPendingCreateEvents()
        f.makeReady()
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == 43200)
        try f
            .sql("CREATE TRIGGER fail_activity BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT,'injected'); END")
        f.clock.now += 600
        #expect(!f.model.refreshExpiryActivity())
        #expect(f.model.hasUncommittedSessionWrites && f.model.expirySchedulingState() == nil)
        // Off remains available while engine or persistence work blocks expiry.
        #expect(f.model.setAutomaticTabArchival(lifetime: nil))
        #expect(!f.model.automaticTabArchivalEnabled)
        try f.sql("DROP TRIGGER fail_activity")
        #expect(f.model.retrySessionPersistence())
        #expect(f.model.setAutomaticTabArchival(lifetime: .twelveHours))
        f.model.handleApplicationWillResignActive()
        #expect(f.model.expirySchedulingState() == nil)
        #expect(f.model.setAutomaticTabArchival(lifetime: nil))
        f.model.handleApplicationDidBecomeActive()
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        #expect(f.model.setAutomaticTabArchival(lifetime: .twelveHours))
        var sawBusy = false
        var admittedWhileBusy = false
        let observation = f.model.objectWillChange.sink {
            if f.model.isArchiveOperationInFlight {
                sawBusy = true
                admittedWhileBusy = admittedWhileBusy || f.model.expirySchedulingState() != nil
            }
        }
        #expect(await f.model.deleteArchivedTab(id: "already-missing"))
        observation.cancel()
        #expect(sawBusy && !admittedWhileBusy)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == 43200)
    }

    @Test(arguments: [false, true])
    func legacyTimingSaveDoesNotHideAnUnresolvedStrictSettingsReadFailure(repaired: Bool) throws {
        let f = try DesktopAutomaticArchiveFixture(bound: false)
        defer { f.close() }
        f.restore()
        try f
            .sql(
                "INSERT INTO browser_preferences(key,value) VALUES ('browser.settings.automaticTabArchivalEnabled','invalid')"
            )
        #expect(!f.model.reloadAutomaticTabArchivalSettings())
        if repaired {
            try f.store.saveAutomaticTabArchival(enabled: false, lifetime: .thirtyDays)
        }
        f.model.setTemporaryTabLifetime(.threeDays)
        #expect(f.model.temporaryTabLifetime == .threeDays)
        #expect(f.store.loadTemporaryTabLifetime() == .threeDays)
        if repaired {
            #expect(f.model.automaticArchivalSettingsError == nil)
            #expect(!f.model.canRetryAutomaticTabArchivalSettings)
            #expect(f.model.expirySchedulingState() != nil)
        } else {
            #expect(f.model.automaticArchivalSettingsError != nil)
            #expect(f.model.canRetryAutomaticTabArchivalSettings)
            #expect(f.model.expirySchedulingState() == nil)
            try f.store.saveAutomaticTabArchival(enabled: false, lifetime: .threeDays)
            #expect(f.model.retryAutomaticTabArchivalSettings())
            #expect(f.model.expirySchedulingState() != nil)
        }
        try f.store.bindSyncOwner(f.owner)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        #expect(f.model.setAutomaticTabArchival(lifetime: .twelveHours))
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == 43200)
    }

    @Test(arguments: [DesktopAutomaticBinding.bound, .paused, .signedOut, .unreadable])
    func adoptingSyncDisablesLegacyDeletionAndOwnershipFailureNeverFallsBack(binding: DesktopAutomaticBinding) throws {
        let f = try DesktopAutomaticArchiveFixture(bound: false)
        defer { f.close() }
        f.restore()
        #expect(!f.model.usesSynchronizedAutomaticArchival)
        #expect(f.model.temporaryTabLifetime == .thirtyDays)
        try f.store.bindSyncOwner(f.owner)
        if binding == .paused {
            try f.store.pauseSync()
        }
        if binding == .signedOut {
            try f.store.requireSyncSignIn()
        }
        if binding == .unreadable {
            try f.sql("ALTER TABLE browser_sync_state RENAME TO unavailable_sync_state")
        }
        #expect(f.model.usesSynchronizedAutomaticArchival)
        f.clock.now += 31 * 24 * 60 * 60
        let before = try f.evidence()
        f.model.archiveExpiredTemporaryTabs()
        #expect(try f.evidence() == before)
        #expect(f.driver.closedTabRequests.isEmpty)
        if binding == .unreadable {
            #expect(!f.model.canConfigureAutomaticTabArchival)
            #expect(f.model.expirySchedulingState() == nil)
            try f.sql("ALTER TABLE unavailable_sync_state RENAME TO browser_sync_state")
            #expect(f.model.reloadAutomaticTabArchivalSettings())
        } else {
            #expect(f.sync.sweeps > 0)
            #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        }
    }

    @Test func neverBoundProfileRetainsThirtyDayActiveSpaceTimerAndCreatesDurableArchive() throws {
        let f = try DesktopAutomaticArchiveFixture(bound: false)
        defer { f.close() }
        f.restore()
        #expect(f.model.temporaryTabLifetime == .thirtyDays)
        #expect(!f.model.usesSynchronizedAutomaticArchival)
        #expect(!f.model.canConfigureAutomaticTabArchival)
        let oldB = try #require(f.model.tabs.first { $0.syncID == "b" }?.id)
        f.clock.now += 31 * 24 * 60 * 60
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.driver.closedTabRequests == [.init(id: oldB, forceClose: false)])
        #expect(Set(f.model.tabs.map(\.syncID)) == ["a", "other", "pin", "favorite"])
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["b"])
        #expect(!f.model.undoManager.canUndo)
        #expect(try f.store.syncOwner() == nil)
        #expect(try f.queueBytes().isEmpty)
    }
}

// MARK: - DesktopAutomaticChoice

enum DesktopAutomaticChoice: CaseIterable { case enable, change, off }

// MARK: - DesktopAutomaticBinding

enum DesktopAutomaticBinding: CaseIterable { case bound, paused, signedOut, unreadable }

// MARK: - DesktopAutomaticArchiveFixture

@MainActor private final class DesktopAutomaticArchiveFixture {
    // MARK: Lifecycle

    init(bound: Bool = true) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopAutomatic-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.suite = "DesktopAutomatic.\(UUID())"
        self.defaults = UserDefaults(suiteName: suite)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "work", title: "Work", systemImageName: "globe", selectedTabIndex: 1),
                .init(id: "other", title: "Other", systemImageName: "star"),
            ],
            tabs: ["favorite", "pin", "a", "b", "other"].map { id in
                .init(
                    id: id,
                    urlString: "https://example.com/\(id)",
                    pinnedURLString: id == "pin" ? "https://example.com/pin" : nil,
                    placement: id == "favorite" ? .app : id == "pin" ? .spacePinned : .temporary,
                    spaceID: id == "other" ? "other" : "work",
                    lastActivityTimestamp: clock.now
                )
            }
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        if bound {
            try store.bindSyncOwner(owner)
        }
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(2)
        self.model = makeModel()
    }

    // MARK: Internal

    let directory: URL
    let databaseURL: URL
    let suite: String
    let defaults: UserDefaults
    let store: BrowserSQLiteSessionStore
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://desktop-automatic.example")!, userID: "owner")
    let clock = DesktopAutomaticClock()
    let sync = DesktopAutomaticCoordinator()
    private(set) var driver = FakeBrowserTabDriver()
    private(set) var model: BrowserChromeModel!

    func restore() {
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        makeReady()
    }

    func makeReady() {
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
    }

    func restart() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        driver = FakeBrowserTabDriver()
        model = makeModel()
    }

    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func queueBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read {
            try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }

    func evidence() throws -> DesktopAutomaticEvidence {
        let rows = try DatabaseQueue(path: databaseURL.path).read { db in
            try (
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id")
            )
        }
        return try .init(snapshot: store.loadSnapshotStrict(), queue: rows.0, baseline: rows.1)
    }

    func close() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Private

    private func makeModel() -> BrowserChromeModel {
        let clock = clock
        return BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            dateProvider: { Date(timeIntervalSince1970: clock.now) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
    }
}

// MARK: - DesktopAutomaticEvidence

private struct DesktopAutomaticEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [Data]
    let baseline: [Data]
}

// MARK: - DesktopAutomaticClock

@MainActor private final class DesktopAutomaticClock { var now: TimeInterval = 1_800_000_000 }

// MARK: - DesktopAutomaticCoordinator

@MainActor private final class DesktopAutomaticCoordinator: BrowserSyncCoordinating {
    var sweeps = 0

    func schedulePush(snapshot _: BrowserTabSessionSnapshot) {}
    func schedulePull() {}
    func requestExpirySweep() { sweeps += 1 }
}
