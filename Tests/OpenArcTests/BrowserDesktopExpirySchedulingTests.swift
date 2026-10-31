// BrowserDesktopExpirySchedulingTests.swift

import AppKit
import GRDB
import Testing

// MARK: - BrowserDesktopExpirySchedulingTests

@Suite(.serialized) @MainActor struct BrowserDesktopExpirySchedulingTests {
    @Test func desktopReadinessProtectsStableIdentityAndDefaultOffChangesOnlyAfterExplicitReload() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        #expect(f.sync.scheduler === f.model)
        #expect(f.model.expirySchedulingState() == nil)
        f.model.handleContextReady()
        f.driver.flushPendingCreateEvents()
        #expect(f.model.expirySchedulingState() == nil)
        f.makeReady()
        let state = try #require(f.model.expirySchedulingState())
        #expect(state.protectedTabIDs == ["a"])
        #expect(state.inactiveForSeconds == nil)
        try f.store.saveAutomaticTabArchival(enabled: true, lifetime: .twelveHours)
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        #expect(!f.model.automaticTabArchivalEnabled)
        #expect(f.model.reloadAutomaticTabArchivalSettings())
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == 43200)
        let before = try f.store.loadSnapshotStrict()
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.sync.sweeps > 0)
        #expect(f.driver.closedTabRequests.isEmpty)
        #expect(try f.store.loadSnapshotStrict() == before)
        f.model.createNewTab()
        #expect(f.model.expirySchedulingState() == nil)
        f.driver.flushPendingCreateEvents()
        f.makeReady()
        let selected = try #require(f.model.tabs.first { $0.id == f.model.selectedTabID })
        #expect(f.model.expirySchedulingState()?.protectedTabIDs == [selected.syncID])
    }

    @Test func desktopSelectionPersistsOutgoingViewingAndMonotonicWholeSeconds() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        f.restore()
        let a = try f.runtimeID("a")
        let b = try f.runtimeID("b")
        f.clock.now = 200.9
        f.model.selectTab(id: b)
        #expect(try f.activity("a") == 200)
        #expect(try f.activity("b") == 200)
        f.clock.now = 201.9
        f.model.selectTab(id: b)
        #expect(try f.activity("b") == 201)
        let rows = try f.queueBytes()
        f.model.selectTab(id: b)
        #expect(try f.queueBytes() == rows)
        f.clock.now = 150
        f.model.selectTab(id: a)
        #expect(try f.activity("a") == 200)
        #expect(try f.activity("b") == 201)
        f.driver.emitUpdate(id: a, title: nil, urlString: "https://example.com/new", faviconURLString: nil)
        #expect(try f.activity("a") == 200)
        #expect(f.model.expirySchedulingState()?.protectedTabIDs == ["a"])
    }

    @Test func desktopBackgroundTransitionPersistsOnceAndStopsRuntimeUntilForeground() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        f.restore()
        f.clock.now = 300
        f.model.handleApplicationWillResignActive()
        #expect(try f.activity("a") == 300)
        #expect(f.sync.runtimeStates.last == false)
        #expect(f.model.expirySchedulingState() == nil)
        let rows = try f.queueBytes()
        f.clock.now = 400
        f.model.handleApplicationWillResignActive()
        #expect(try f.queueBytes() == rows)
        try f.model.selectTab(id: f.runtimeID("b"))
        #expect(try f.activity("b") == 20.25)
        f.clock.now = 500
        f.model.handleApplicationDidBecomeActive()
        #expect(f.sync.runtimeStates.last == true)
        #expect(try f.activity("b") == 500)
        let foregroundRows = try f.queueBytes()
        f.clock.now = 600
        f.model.handleApplicationDidBecomeActive()
        #expect(try f.queueBytes() == foregroundRows)
    }

    @Test func desktopRemoteActivitySurvivesLiveEngineProjectionAndLowerLocalClock() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        f.restore()
        let before = try #require(try f.store.loadSnapshotStrict())
        let originalQueue = try f.queueBytes()
        let runtimeIDs = f.model.tabs.map(\.id)
        let remote = BrowserTabSessionSnapshot(
            spaces: before.spaces, pinnedTabFolders: before.pinnedTabFolders,
            tabs: before.tabs.map { tab in
                .init(
                    id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride, placement: tab.placement,
                    spaceID: tab.spaceID, pinnedFolderID: tab.pinnedFolderID,
                    lastActivityTimestamp: tab.id == "a" ? 600.125 : tab.lastActivityTimestamp,
                    pinnedSiblingRank: tab.pinnedSiblingRank,
                )
            },
        )
        f.model.applyRemoteSyncSnapshot(remote)
        #expect(try f.activity("a") == 600.125)
        #expect(f.model.tabs.first { $0.syncID == "a" }?.lastActivityAt.timeIntervalSince1970 == 600.125)
        #expect(f.model.tabs.map(\.id) == runtimeIDs)
        #expect(try f.queueBytes() == originalQueue)
        f.clock.now = 500
        try f.driver.emitUpdate(
            id: f.runtimeID("a"),
            title: nil,
            urlString: "https://example.com/later",
            faviconURLString: nil,
        )
        #expect(try f.activity("a") == 600.125)
    }

    @Test func failedDesktopActivityBlocksSchedulingAndClosureUntilTheSameWriteRecovers() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        f.restore()
        try f
            .sql(
                "CREATE TRIGGER reject_activity BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT, 'fixture'); END",
            )
        f.clock.now = 300
        #expect(!f.model.refreshExpiryActivity())
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.model.expirySchedulingState() == nil)
        #expect(f.sync.persistenceBlocks.last == true)
        #expect(try f.activity("a") == 10.75)
        try f.sql("DROP TRIGGER reject_activity")
        #expect(f.model.retrySessionPersistence())
        #expect(try f.activity("a") == 300)
        #expect(f.model.expirySchedulingState() != nil)
        #expect(f.sync.persistenceBlocks.last == false)
        f.clock.now = 400
        #expect(f.model.prepareSessionForClosure())
        #expect(try f.activity("a") == 400)
        f.model.prepareForTermination()
        #expect(f.sync.runtimeStates.last == false)
        #expect(f.sync.scheduler == nil)
        #expect(f.model.expirySchedulingState() == nil)
        #expect(!f.model.refreshExpiryActivity())
        let sweeps = f.sync.sweeps
        f.model.handleApplicationDidBecomeActive()
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.sync.sweeps == sweeps)
    }

    @Test func explicitViewingDuringPendingRemoteCreationSurvivesItsLateCallbackWithoutEcho() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        f.restore()
        let original = try #require(try f.store.loadSnapshotStrict())
        let remote = BrowserTabSessionSnapshot(
            spaces: original.spaces, pinnedTabFolders: original.pinnedTabFolders,
            tabs: original.tabs + [.init(
                id: "pending-remote", urlString: "https://example.com/pending", spaceID: "work",
                lastActivityTimestamp: 50,
            )],
        )
        try f.store.writeSessionBatch([.init(snapshot: remote, origin: .remoteProjection)])
        let before = try f.queueBytes()
        f.model.applyRemoteSyncSnapshot(remote)
        #expect(f.model.expirySchedulingState() == nil)
        #expect(try f.queueBytes() == before)
        f.clock.now = 200
        try f.model.selectTab(id: f.runtimeID("b"))
        #expect(try f.activity("a") == 200)
        #expect(try f.activity("b") == 200)
        #expect(try f.activity("pending-remote") == 50)
        f.clock.now = 250
        f.model.handleApplicationWillResignActive()
        #expect(try f.activity("b") == 250)
        let queued = try f.queueBytes()
        f.driver.flushPendingCreateEvents()
        #expect(try f.activity("a") == 200)
        #expect(try f.activity("b") == 250)
        #expect(try f.activity("pending-remote") == 50)
        #expect(try f.queueBytes() == queued)
        #expect(f.model.tabs.first { $0.id == f.model.selectedTabID }?.syncID == "b")
    }

    @Test func desktopLifetimeSaveFailureIsVisibleAndSyncedSettingsRequireAnExplicitChoice() throws {
        let f = try DesktopExpiryFixture()
        defer { f.close() }
        f.restore()
        let original = f.model.temporaryTabLifetime
        try f
            .sql(
                "CREATE TRIGGER reject_timing BEFORE INSERT ON browser_preferences BEGIN SELECT RAISE(ABORT, 'fixture'); END",
            )
        f.model.setTemporaryTabLifetime(.threeDays)
        #expect(f.model.temporaryTabLifetime == original)
        #expect(f.store.loadTemporaryTabLifetime() == original)
        #expect(f.model.automaticArchivalSettingsError == BrowserStrings.settingsTemporaryTabsSaveFailed)
        try f.sql("DROP TRIGGER reject_timing")
        f.model.setTemporaryTabLifetime(.threeDays)
        #expect(f.model.temporaryTabLifetime == .threeDays)
        #expect(f.store.loadTemporaryTabLifetime() == .threeDays)
        #expect(f.model.automaticArchivalSettingsError == nil)
        let controller = BrowserSettingsViewController(
            model: f.model, profileStore: BrowserProfileStore(rootCacheURL: f.directory),
            currentProfileID: BrowserProfile.defaultProfile.id, accountStore: nil, pane: .profiles,
            openProfile: { _ in }, openURL: { _ in },
        )
        let picker = try #require(desktopExpiryView(
            "browser.settings.automatic-tab-archival",
            in: controller.view,
        ) as? BrowserActionPopUpButton)
        let description = try #require(desktopExpiryView(
            "browser.settings.temporary-tab-availability",
            in: controller.view,
        ) as? NSTextField)
        #expect(picker.isEnabled)
        #expect(picker.titleOfSelectedItem == BrowserStrings.settingsAutomaticArchivalOff)
        #expect(description.stringValue == BrowserStrings.settingsAutomaticArchivalSyncDescription)
        #expect(picker.itemTitles.contains(BrowserStrings.settingsLifetimeThreeDays))
        #expect(f.model.expirySchedulingState()?.inactiveForSeconds == nil)
        #expect(!f.store.loadAutomaticTabArchivalEnabled())
    }
}

// MARK: - DesktopExpiryFixture

@MainActor private final class DesktopExpiryFixture {
    // MARK: Internal

    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let driver = FakeBrowserTabDriver()
    let sync = DesktopExpiryCoordinator()
    let clock = DesktopExpiryClock()
    let model: BrowserChromeModel

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopExpiry-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.suite = "DesktopExpiry.\(UUID())"
        self.defaults = UserDefaults(suiteName: suite)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "work", title: "Work", systemImageName: "globe", selectedTabIndex: 0)],
            tabs: [
                .init(id: "a", urlString: "https://example.com/a", spaceID: "work", lastActivityTimestamp: 10.75),
                .init(id: "b", urlString: "https://example.com/b", spaceID: "work", lastActivityTimestamp: 20.25),
            ],
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        try store.bindSyncOwner(.init(baseURL: URL(string: "https://desktop-expiry.example")!, userID: "owner"))
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(0)
        let clock = clock
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            dateProvider: { Date(timeIntervalSince1970: clock.now) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
    }

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

    func runtimeID(_ id: String) throws -> String { try #require(model.tabs.first { $0.syncID == id }?.id) }
    func activity(_ id: String) throws -> Double? { try store.loadSnapshotStrict()?
        .tabs
        .first { $0.id == id }?
        .lastActivityTimestamp
    }

    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func queueBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { try Data.fetchAll(
            $0,
            sql: "SELECT payload FROM browser_sync_outbox ORDER BY position",
        ) }
    }

    func close() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - DesktopExpiryCoordinator

@MainActor private final class DesktopExpiryCoordinator: BrowserSyncCoordinating {
    weak var scheduler: (any BrowserSyncExpiryScheduling)?
    var runtimeStates = [Bool]()
    var persistenceBlocks = [Bool]()
    var sweeps = 0

    func schedulePush(snapshot _: BrowserTabSessionSnapshot) {}
    func schedulePull() {}
    func setLocalPersistenceBlocked(_ blocked: Bool) { persistenceBlocks.append(blocked) }
    func setRuntimeActive(_ active: Bool) { runtimeStates.append(active) }
    func setExpiryScheduler(_ scheduler: (any BrowserSyncExpiryScheduling)?) { self.scheduler = scheduler }
    func requestExpirySweep() { sweeps += 1 }
}

// MARK: - DesktopExpiryClock

@MainActor private final class DesktopExpiryClock { var now = 100.0 }

@MainActor private func desktopExpiryView(_ id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == id {
        return view
    }
    for child in view.subviews {
        if let match = desktopExpiryView(id, in: child) {
            return match
        }
    }
    return nil
}
