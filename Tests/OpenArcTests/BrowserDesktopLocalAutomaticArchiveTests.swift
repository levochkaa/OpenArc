// BrowserDesktopLocalAutomaticArchiveTests.swift

import AppKit
import GRDB
import Testing

// MARK: - BrowserDesktopLocalAutomaticArchiveTests

@Suite(.serialized) @MainActor struct BrowserDesktopLocalAutomaticArchiveTests {
    @Test func thirtyDayCutoffPreservesSelectedOtherSpacePersistentAndYoungerTabsUntilConfirmation() throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        #expect(f.model.temporaryTabLifetime == .thirtyDays)
        #expect(try f.store.syncOwner() == nil)
        let before = try f.evidence()
        let initialIDs = f.model.tabs.map(\.syncID)
        let selection = f.model.selectedTabID
        f.clock.now = LocalAutomaticArchiveFixture.start + 30 * LocalAutomaticArchiveFixture.day - 0.25
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.driver.confirmedCloseRequests.isEmpty)
        f.clock.now += 0.25
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(try request.id == f.runtimeID("b"))
        #expect(f.driver.confirmedCloseRequests.count == 1)
        #expect(f.model.tabs.map(\.syncID) == initialIDs && f.model.selectedTabID == selection)
        #expect(try f.evidence() == before)
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.driver.confirmedCloseRequests.count == 1)
        f.finish(request, .closed)
        #expect(f.model.tabs.map(\.syncID) == initialIDs.filter { $0 != "b" })
        #expect(f.model.selectedTabID == selection)
        let entry = try #require(try f.store.loadArchivePage().entries.first)
        #expect(entry.tab.id == "b" && entry.archivedAt == f.clock.now)
        #expect(try f.evidence().queue.isEmpty)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        let committed = try f.evidence()
        f.finish(request, .closed)
        f.driver.emitClose(id: request.id)
        #expect(try f.evidence() == committed)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadArchivePage().entries == [entry])
        #expect(try reopened.loadSnapshotStrict()?.tabs.compactMap(\.id) == initialIDs.filter { $0 != "b" })
    }

    @Test func cancellationLeavesTheProfileUntouchedAndAdvancesOneCapturedCandidateAtATime() throws {
        let f = try LocalAutomaticArchiveFixture(candidateIDs: ["b", "d"])
        defer { f.close() }
        f.expireCandidates()
        let before = try f.evidence()
        f.model.archiveExpiredTemporaryTabs()
        let first = try #require(f.driver.confirmedCloseRequests.last)
        #expect(try first.id == f.runtimeID("b") && f.driver.confirmedCloseRequests.count == 1)
        f.model.archiveExpiredTemporaryTabs()
        f.finish(first, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.model.tabs.contains { $0.syncID == "b" })
        let second = try #require(f.driver.confirmedCloseRequests.last)
        #expect(try second.id == f.runtimeID("d") && f.driver.confirmedCloseRequests.count == 2)
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.driver.confirmedCloseRequests.count == 2)
        f.finish(second, .closed)
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["d"])
        #expect(f.driver.confirmedCloseRequests.count == 2, "Cancel must not retry the same candidate in its sweep")
        #expect(f.model.tabs.contains { $0.syncID == "b" })
        #expect(!f.model.undoManager.canUndo)
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.driver.confirmedCloseRequests.count == 3)
        let laterSweep = try #require(f.driver.confirmedCloseRequests.last)
        #expect(laterSweep.id == first.id && laterSweep.requestID != first.requestID)
        f.finish(laterSweep, .cancelled)
    }

    @Test func confirmationArchivesLatestSavedAndLoadedTitlesWithoutRegisteringUserUndo() throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.setUserTitleOverride("Renamed while waiting", forTabID: request.id)
        f.driver.emitUpdate(id: request.id, title: "Latest loaded page title")
        let preclose = try #require(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "b" })
        f.recording.reset()
        f.finish(request, .closed)
        let entry = try #require(try f.store.loadArchivePage().entries.first)
        #expect(entry.tab == preclose && entry.title == "Latest loaded page title")
        #expect(f.recording.attempts.count == 1 && f.recording.attempts.first?.count == 1)
        let write = try #require(f.recording.attempts.first?.first)
        #expect(write.archiveAction == .insert(entry) && write.origin == .local(syncMove: nil))
        #expect(write.archiveProjectionSnapshot == nil)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(try f.evidence().queue.isEmpty)
    }

    @Test(arguments: ["navigation", "move", "pin"])
    func queuedCandidateIsRevalidatedBeforeRequestingItsEngineClose(change: String) throws {
        let f = try LocalAutomaticArchiveFixture(candidateIDs: ["b", "d"])
        defer { f.close() }
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let first = try #require(f.driver.confirmedCloseRequests.last)
        let waiting = try f.runtimeID("d")
        if change == "navigation" {
            f.driver.emitUpdate(id: waiting, urlString: "https://example.com/new-waiting-activity")
        } else if change == "move" {
            f.model.moveTab(withID: waiting, toPlacement: .temporary, atSectionIndex: 0, targetSpaceID: "other")
        } else {
            f.model.moveTab(withID: waiting, toPlacement: .spacePinned, atSectionIndex: 0)
        }
        let updated = try #require(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "d" })
        f.finish(first, .closed)
        #expect(f.driver.confirmedCloseRequests.count == 1)
        #expect(f.model.tabs.first { $0.syncID == "d" }?.id == waiting)
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "d" } == updated)
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["b"])
    }

    @Test(arguments: LocalAutomaticInvalidation.allCases)
    func changedEligibilityPreservesLatestLogicalStateAfterTheEngineAlreadyClosed(
        change: LocalAutomaticInvalidation,
    ) throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        if change == .longerLifetime {
            f.model.setTemporaryTabLifetime(.twelveHours)
            f.clock.now = LocalAutomaticArchiveFixture.start + 13 * 60 * 60
        } else {
            f.expireCandidates()
        }
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(try request.id == f.runtimeID("b"))
        switch change {
        case .selected: f.model.selectTab(id: request.id)
        case .navigation:
            f.driver.emitUpdate(id: request.id, title: "New page", urlString: "https://example.com/new-activity")
        case .otherSpace:
            f.model.moveTab(withID: request.id, toPlacement: .temporary, atSectionIndex: 0, targetSpaceID: "other")
        case .selectedSpace: f.model.selectSpace(id: "other")
        case .pinned: f.model.moveTab(withID: request.id, toPlacement: .spacePinned, atSectionIndex: 0)
        case .favorite: f.model.moveTab(withID: request.id, toPlacement: .app, atSectionIndex: 0)
        case .clockRollback: f.clock.now = LocalAutomaticArchiveFixture.start + LocalAutomaticArchiveFixture.day
        case .longerLifetime: f.model.setTemporaryTabLifetime(.thirtyDays)
        }
        let beforeCompletion = try f.evidence()
        let order = f.model.tabs.map(\.syncID)
        let selected = f.model.tabs.first { $0.id == f.model.selectedTabID }?.syncID
        let selectedSpace = f.model.selectedSpaceID
        let latest = try #require(f.model.tabs.first { $0.syncID == "b" })
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        f.finish(request, .closed)
        let retained = try #require(f.model.tabs.first { $0.syncID == "b" })
        #expect(retained.id != request.id)
        #expect(retained.placement == latest.placement && retained.spaceID == latest.spaceID)
        #expect(retained.urlString == latest.urlString && retained.userTitleOverride == latest.userTitleOverride)
        #expect(retained.title == latest.title && retained.lastActivityAt == latest.lastActivityAt)
        #expect(f.model.tabs.map(\.syncID) == order && f.model.selectedSpaceID == selectedSpace)
        #expect(f.model.tabs.first { $0.id == f.model.selectedTabID }?.syncID == selected)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(f.recording.attempts.isEmpty, "Replacing only the closed runtime must not persist a logical edit")
        #expect(try f.evidence() == beforeCompletion)
        f.finish(request, .closed)
        f.driver.emitClose(id: request.id)
        f.flushReady()
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(f.model.tabs.count(where: { $0.syncID == "b" }) == 1)
        #expect(try f.evidence() == beforeCompletion)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test func failedAutomaticArchiveRetainsItsExactWriteForRetryAfterANewerEdit() throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        f.expireCandidates()
        let before = try f.evidence()
        try f.sql("""
        CREATE TRIGGER reject_automatic_archive BEFORE INSERT ON browser_tab_archive
        BEGIN SELECT RAISE(ABORT,'injected'); END
        """)
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(request, .closed)
        #expect(f.model.hasUncommittedSessionWrites && f.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(try f.evidence() == before)
        #expect(!f.model.tabs.contains { $0.syncID == "b" })
        let failed = try #require(f.recording.attempts.last)
        let archiveAction = try #require(failed.first?.archiveAction)
        guard case .insert(let entry) = archiveAction else {
            Issue.record("Automatic close must retain its Archive insertion")
            return
        }
        f.model.archiveExpiredTemporaryTabs()
        #expect(f.driver.confirmedCloseRequests.count == 1)
        try f.model.setUserTitleOverride("Surviving newer edit", forTabID: f.runtimeID("a"))
        let fifo = try #require(f.recording.attempts.last)
        #expect(fifo.count > failed.count && Array(fifo.prefix(failed.count)) == failed)
        #expect(fifo.compactMap(\.archiveAction) == [archiveAction])
        #expect(!f.model.retrySessionPersistence())
        #expect(try f.recording.attempts.last == fifo && (f.evidence()) == before)
        try f.sql("DROP TRIGGER reject_automatic_archive")
        #expect(f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo)
        #expect(try f.store.loadArchivePage().entries == [entry])
        #expect(try f.store
            .loadSnapshotStrict()?
            .tabs
            .first { $0.id == "a" }?
            .userTitleOverride == "Surviving newer edit")
        #expect(!f.model.hasUncommittedSessionWrites && !f.model.undoManager.canUndo)
        #expect(try f.evidence().queue.isEmpty)
    }

    @Test func oneSweepCapturesAtMostOneHundredCandidates() throws {
        let candidates = (0..<101).map { "old-\($0)" }
        let f = try LocalAutomaticArchiveFixture(candidateIDs: candidates)
        defer { f.close() }
        f.expireCandidates()
        let before = try f.evidence()
        f.model.archiveExpiredTemporaryTabs()
        for index in 0..<100 {
            #expect(f.driver.confirmedCloseRequests.count == index + 1)
            let request = try #require(f.driver.confirmedCloseRequests.last)
            #expect(try request.id == f.runtimeID(candidates[index]))
            f.finish(request, .cancelled)
        }
        #expect(f.driver.confirmedCloseRequests.count == 100)
        #expect(try f.evidence() == before)
        #expect(f.model.tabs.count(where: { $0.syncID.hasPrefix("old-") }) == 101)
        #expect(!f.model.undoManager.canUndo)
    }
}

// MARK: - LocalAutomaticInvalidation

enum LocalAutomaticInvalidation: CaseIterable {
    case selected, navigation, otherSpace, selectedSpace, pinned, favorite, clockRollback, longerLifetime
}

// MARK: - LocalAutomaticArchiveFixture

@MainActor final class LocalAutomaticArchiveFixture {
    // MARK: Internal

    static let start: TimeInterval = 1_800_000_000
    static let day: TimeInterval = 24 * 60 * 60

    let directory: URL
    let databaseURL: URL
    let suite: String
    let defaults: UserDefaults
    let store: BrowserSQLiteSessionStore
    let recording: ConfirmedCloseRecordingStore
    let clock = ConfirmedCloseClock()
    let driver = FakeBrowserTabDriver()
    let model: BrowserChromeModel

    init(candidateIDs: [String] = ["b"]) throws {
        self.directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("LocalAutomaticArchive-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.suite = BrowserTestDefaults.suiteName("LocalAutomaticArchive")
        self.defaults = try #require(UserDefaults(suiteName: suite))
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.recording = ConfirmedCloseRecordingStore(store)
        let rows = ["favorite", "pin", "a"] + candidateIDs + ["younger", "other"]
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "work", title: "Work", systemImageName: "globe", selectedTabIndex: 1),
                .init(id: "other", title: "Other", systemImageName: "star", selectedTabIndex: 0),
            ], tabs: rows.map { id in
                .init(
                    id: id, urlString: "https://example.com/\(id)",
                    pinnedURLString: id == "pin" ? "https://example.com/pin" : nil,
                    placement: id == "favorite" ? .app : id == "pin" ? .spacePinned : .temporary,
                    spaceID: id == "other" ? "other" : "work",
                    lastActivityTimestamp: Self.start + (id == "younger" ? 1 : 0),
                )
            },
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        store.saveSelectedSpaceIndex(0)
        store.saveSelectedTabIndex(2)
        driver.automaticallyConfirmsCloseRequests = false
        let fixtureClock = clock
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: recording, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            dateProvider: { Date(timeIntervalSince1970: fixtureClock.now) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
        model.handleContextReady()
        flushReady()
        model.undoManager.removeAllActions()
        recording.reset()
    }

    func expireCandidates() { clock.now = Self.start + 30 * Self.day }
    func runtimeID(_ id: String) throws -> String { try #require(model.tabs.first { $0.syncID == id }).id }
    func finish(_ request: FakeBrowserTabDriver.ConfirmedCloseRequest, _ outcome: BrowserTabCloseOutcome) {
        driver.emitCloseRequestOutcome(id: request.id, requestID: request.requestID, outcome: outcome)
    }

    func flushReady() {
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
    }

    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func evidence() throws -> ConfirmedCloseEvidence {
        let rows = try DatabaseQueue(path: databaseURL.path).read { db in
            try (
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id,'') FROM browser_tab_archive_receipts ORDER BY id",
                ),
                String.fetchAll(db, sql: "SELECT key || ':' || value FROM browser_preferences ORDER BY key"),
            )
        }
        return try .init(
            snapshot: store.loadSnapshotStrict(),
            queue: rows.0,
            baseline: rows.1,
            archive: rows.2,
            receipts: rows.3,
            preferences: rows.4,
        )
    }

    func close() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
