import Foundation
import GRDB
import Testing

@Test(arguments: ["enabled", "paused", "logged-out"])
@MainActor func automaticDesktopArchivalKeepsDurablyBoundTabsBeforePullAndAfterOfflineReopen(state: String) throws {
    try withAutomaticArchivalProfile { fixture in
        let store = try fixture.open()
        try fixture.seed(store)
        try store.bindSyncOwner(fixture.owner)
        if state == "paused" {
            try store.pauseSync()
        }
        if state == "logged-out" {
            try store.requireSyncSignIn()
        }
        let originalRows = try fixture.outboxRows()
        let driver = FakeBrowserTabDriver()
        let pullObserver = AutomaticArchivalPullObserver(store: store)
        let model = fixture.model(store: store, driver: driver, sync: pullObserver)
        defer { fixture.close(model) }

        model.handleContextReady()
        driver.flushPendingCreateEvents()
        #expect(model.tabs.map(\.syncID) == automaticArchivalTabIDs)
        #expect(driver.closedTabRequests.isEmpty)
        #expect(pullObserver.snapshots.count == 1)
        #expect(
            pullObserver.snapshots.first?.tabs.compactMap(\.id) == automaticArchivalTabIDs,
            "Startup must retain expired-looking local tabs before the first remote pull"
        )
        let rowsAfterRestore = try fixture.outboxRows()
        #expect(rowsAfterRestore == originalRows)

        model.handleApplicationDidBecomeActive()
        model.setTemporaryTabLifetime(.twentyFourHours)
        model.archiveExpiredTemporaryTabs() // The periodic timer enters this same method.
        #expect(model.tabs.map(\.syncID) == automaticArchivalTabIDs)
        #expect(driver.closedTabRequests.isEmpty)
        #expect(try fixture.outboxRows() == originalRows)

        fixture.close(model)
        let reopened = try fixture.open()
        #expect(try reopened.syncOwner() == fixture.owner)
        #expect(try reopened.isSyncPaused(for: fixture.owner) == (state != "enabled"))
        #expect(try reopened.requiresSyncSignIn() == (state == "logged-out"))
        let offlineDriver = FakeBrowserTabDriver()
        // No account coordinator or network is present after this reopen.
        let offlineModel = fixture.model(store: reopened, driver: offlineDriver)
        defer { fixture.close(offlineModel) }
        offlineModel.handleContextReady()
        offlineDriver.flushPendingCreateEvents()
        offlineModel.handleApplicationDidBecomeActive()
        offlineModel.archiveExpiredTemporaryTabs()
        #expect(offlineModel.tabs.map(\.syncID) == automaticArchivalTabIDs)
        #expect(offlineDriver.closedTabRequests.isEmpty)
        #expect(try fixture.outboxRows() == originalRows)

        let expired = try #require(offlineModel.tabs.first { $0.syncID == "expired" })
        #expect(offlineModel.closeTab(id: expired.id), "Manual Close remains available for bound profiles")
        #expect(!offlineModel.tabs.contains { $0.syncID == "expired" })
        #expect(offlineDriver.closedTabRequests.map(\.id) == [expired.id])
        #expect(reopened.loadSnapshot()?.tabs.contains { $0.id == "expired" } == false)
        let queue = try reopened.pendingSyncQueue(for: fixture.owner)
        let last = try #require(queue.last)
        guard case .legacy(let removal) = last else {
            Issue.record("The never-negotiated profile must retain its v2 queue")
            return
        }
        #expect(removal.changes.contains { $0.entityID == "expired" && $0.entityType == .tab && $0.op == .delete })
        #expect(try Array(fixture.outboxRows().prefix(originalRows.count)) == originalRows)
    }
}

@Test @MainActor func neverBoundDesktopProfileRetainsLocalAutomaticArchivalAndSelectedPinnedProtection() throws {
    try withAutomaticArchivalProfile { fixture in
        let store = try fixture.open()
        try fixture.seed(store)
        let driver = FakeBrowserTabDriver()
        let model = fixture.model(store: store, driver: driver)
        defer { fixture.close(model) }
        model.handleContextReady()
        driver.flushPendingCreateEvents()

        #expect(try store.syncOwner() == nil)
        #expect(model.tabs.map(\.syncID) == ["favorite", "pinned", "selected", "other-space"])
        #expect(model.tabs.first { $0.id == model.selectedTabID }?.syncID == "selected")
        #expect(driver.closedTabRequests.map(\.id) == ["tab-3"])
        #expect(store.loadSnapshot()?.tabs.compactMap(\.id) == model.tabs.map(\.syncID))
        #expect(try fixture.outboxRows().isEmpty)
        model.archiveExpiredTemporaryTabs()
        #expect(driver.closedTabRequests.count == 1)

        let selected = try #require(model.selectedTabID)
        #expect(model.closeTab(id: selected))
        #expect(!model.tabs.contains { $0.syncID == "selected" })
        let reopened = try fixture.open()
        #expect(reopened.loadSnapshot()?.tabs.compactMap(\.id) == ["favorite", "pinned", "other-space"])
    }
}

@Test @MainActor func desktopAutomaticArchivalRechecksBindingAddedAfterModelStartup() throws {
    try withAutomaticArchivalProfile { fixture in
        let store = try fixture.open()
        try fixture.seed(store)
        let clock = AutomaticArchivalClock(seconds: 60)
        let driver = FakeBrowserTabDriver()
        let model = fixture.model(store: store, driver: driver, clock: clock)
        defer { fixture.close(model) }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        #expect(model.tabs.map(\.syncID) == automaticArchivalTabIDs)
        #expect(try store.syncOwner() == nil)

        try store.bindSyncOwner(fixture.owner)
        let rows = try fixture.outboxRows()
        clock.seconds = 48 * 60 * 60
        model.archiveExpiredTemporaryTabs()
        model.handleApplicationDidBecomeActive()
        model.setTemporaryTabLifetime(.twentyFourHours)
        #expect(model.tabs.map(\.syncID) == automaticArchivalTabIDs)
        #expect(driver.closedTabRequests.isEmpty)
        #expect(try fixture.outboxRows() == rows)
    }
}

@Test @MainActor func desktopAutomaticArchivalFailsClosedOnOwnershipReadErrorAndRetriesTheRead() throws {
    try withAutomaticArchivalProfile { fixture in
        let store = try fixture.open()
        try fixture.seed(store)
        let failing = AutomaticArchivalOwnershipFailure(store: store)
        let driver = FakeBrowserTabDriver()
        let model = fixture.model(store: failing, preferences: store, driver: driver)
        defer { fixture.close(model) }
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        let startupReads = failing.readAttempts
        #expect(startupReads > 0)
        model.handleApplicationDidBecomeActive()
        let activeReads = failing.readAttempts
        #expect(activeReads > startupReads)
        model.setTemporaryTabLifetime(.twentyFourHours)
        let settingsReads = failing.readAttempts
        #expect(settingsReads > activeReads)
        model.archiveExpiredTemporaryTabs()
        #expect(failing.readAttempts > settingsReads)
        #expect(model.tabs.map(\.syncID) == automaticArchivalTabIDs)
        #expect(driver.closedTabRequests.isEmpty)
        #expect(!model.hasUncommittedSessionWrites, "The fault affects only ownership reads, not session writes")
        #expect(try fixture.outboxRows().isEmpty)

        let failedReads = failing.readAttempts
        failing.failRead = false
        model.archiveExpiredTemporaryTabs()
        #expect(failing.readAttempts > failedReads)
        #expect(model.tabs.map(\.syncID) == ["favorite", "pinned", "selected", "other-space"])
        #expect(driver.closedTabRequests.map(\.id) == ["tab-3"])
        #expect(store.loadSnapshot()?.tabs.compactMap(\.id) == model.tabs.map(\.syncID))
    }
}

private let automaticArchivalTabIDs = ["favorite", "pinned", "expired", "selected", "other-space"]

@MainActor private func withAutomaticArchivalProfile(_ body: (AutomaticArchivalProfile) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticArchival-\(UUID())")
    let suite = "AutomaticArchivalTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    // Every model and SQLite handle belongs to the inner frame and is released
    // before removing the directory; no open database is unlinked by cleanup.
    try body(AutomaticArchivalProfile(directory: directory, defaults: defaults))
}

// MARK: - AutomaticArchivalProfile

@MainActor private struct AutomaticArchivalProfile {
    let directory: URL
    let defaults: UserDefaults
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://automatic-archive.example")!, userID: "owner")

    var databaseURL: URL { directory.appendingPathComponent("Profile.sqlite") }

    func open() throws -> BrowserSQLiteSessionStore {
        try BrowserSQLiteSessionStore(databaseURL: databaseURL)
    }

    func seed(_ store: BrowserSQLiteSessionStore) throws {
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "work", title: "Work", systemImageName: "briefcase", selectedTabIndex: 2),
                .init(id: "other", title: "Other", systemImageName: "book", selectedTabIndex: 0),
            ],
            tabs: automaticArchivalTabIDs.map { id in
                let placement: BrowserTabPlacement = id == "favorite"
                    ? .app
                    : id == "pinned" ? .spacePinned : .temporary
                let url = "https://\(id).example/"
                return .init(
                    id: id, urlString: url, pinnedURLString: placement == .spacePinned ? url : nil,
                    placement: placement, spaceID: id == "other-space" ? "other" : "work",
                    lastActivityTimestamp: 0, pinnedSiblingRank: placement == .spacePinned ? 0 : nil
                )
            }
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        store.saveTemporaryTabLifetime(.twelveHours)
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(3)
    }

    func model(
        store: any BrowserTabSessionSnapshotStoring,
        preferences: (any BrowserSessionPreferencesStoring)? = nil,
        driver: FakeBrowserTabDriver,
        sync: (any BrowserSyncCoordinating)? = nil,
        clock: AutomaticArchivalClock = AutomaticArchivalClock(seconds: 48 * 60 * 60)
    ) -> BrowserChromeModel {
        let preferences = preferences ?? (store as! BrowserSQLiteSessionStore)
        return BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: preferences,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), syncCoordinator: sync,
            dateProvider: { Date(timeIntervalSince1970: clock.seconds) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
    }

    func close(_ model: BrowserChromeModel) {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
    }

    func outboxRows() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }
}

// MARK: - AutomaticArchivalClock

@MainActor private final class AutomaticArchivalClock {
    // MARK: Lifecycle

    init(seconds: TimeInterval) { self.seconds = seconds }

    // MARK: Internal

    var seconds: TimeInterval
}

// MARK: - AutomaticArchivalPullObserver

@MainActor private final class AutomaticArchivalPullObserver: BrowserSyncCoordinating {
    // MARK: Lifecycle

    init(store: BrowserSQLiteSessionStore) { self.store = store }

    // MARK: Internal

    let store: BrowserSQLiteSessionStore
    var snapshots = [BrowserTabSessionSnapshot]()

    func schedulePush(snapshot _: BrowserTabSessionSnapshot) {}
    func schedulePull() {
        if let snapshot = store.loadSnapshot() {
            snapshots.append(snapshot)
        }
    }
}

// MARK: - AutomaticArchivalOwnershipFailure

private final class AutomaticArchivalOwnershipFailure: BrowserTabSessionSnapshotStoring, BrowserSyncOwnershipReading,
BrowserTabArchiveStoring {
    // MARK: Lifecycle

    init(store: BrowserSQLiteSessionStore) { self.store = store }

    // MARK: Internal

    enum ReadFailure: Error { case unavailable }

    let store: BrowserSQLiteSessionStore
    var readAttempts = 0
    var failRead = true

    func syncOwner() throws -> BrowserSyncOwner? {
        readAttempts += 1
        if failRead {
            throw ReadFailure.unavailable
        }
        return try store.syncOwner()
    }

    func loadSnapshot() -> BrowserTabSessionSnapshot? { store.loadSnapshot() }
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) { store.saveSnapshot(snapshot) }
    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws { try store.writeSessionBatch(writes) }
    func loadArchiveEntry(id: String) throws -> BrowserTabArchiveEntry? { try store.loadArchiveEntry(id: id) }
    func loadArchivePage(before: BrowserTabArchiveCursor?, limit: Int) throws -> BrowserTabArchivePage {
        try store.loadArchivePage(before: before, limit: limit)
    }

    nonisolated(nonsending) func searchArchivePage(
        query: String, before: BrowserTabArchiveCursor?, limit: Int
    ) async throws -> BrowserTabArchivePage {
        try await store.searchArchivePage(query: query, before: before, limit: limit)
    }

    nonisolated(nonsending) func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        try await store.archiveClearBoundary()
    }

    nonisolated(nonsending) func removeArchiveEntry(id: String) async throws -> Bool {
        try await store.removeArchiveEntry(id: id)
    }

    nonisolated(nonsending) func clearArchive(through boundary: BrowserTabArchiveBoundary) async throws -> Int {
        try await store.clearArchive(through: boundary)
    }
}
