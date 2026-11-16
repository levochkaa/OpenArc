// BrowserDesktopArchiveTests.swift

import AppKit
import Combine
import GRDB
import Testing

// MARK: - BrowserDesktopArchiveTests

@Suite(.serialized) @MainActor struct BrowserDesktopArchiveTests {
    /// The SQLite archive serves at most 100 entries a page; the Library reads page by page.
    @Test func theLibraryListsTheArchiveWithinTheStoresPageSize() async throws {
        let f = try DesktopArchiveFixture(archivedIDs: ["a", "b", "c"])
        defer { f.close() }
        f.restoreModel()
        let all = await BrowserLibraryNSView.loadArchive(model: f.model, query: "")
        #expect(all.map(\.id) == ["archive-c", "archive-b", "archive-a"], "Newest first, none lost to the page size")
        let two = await BrowserLibraryNSView.loadArchive(model: f.model, query: "", maximumCount: 2)
        #expect(two.count == 2)
    }

    /// Opening the Library again on an unchanged archive keeps its row views.
    @Test func reopeningTheLibraryKeepsTheArchiveRows() async throws {
        let f = try DesktopArchiveFixture(archivedIDs: ["a", "b", "c"])
        defer { f.close() }
        f.restoreModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,
        )
        let library = BrowserLibraryNSView(model: f.model)
        library.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        window.contentView?.addSubview(library)
        library.refresh()
        for _ in 0..<50 where library.documentBuildCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
            library.layoutSubtreeIfNeeded()
        }
        let built = library.documentBuildCount
        #expect(built >= 1)
        for _ in 0..<3 {
            library.isHidden = true
            library.refresh()
            library.isHidden = false
            try await Task.sleep(for: .milliseconds(30))
            library.layoutSubtreeIfNeeded()
        }
        #expect(library.documentBuildCount == built)
    }

    @Test func restoreCommitsFreshIdentityBeforeEngineCreationAndPreservesTheOriginalTombstone() throws {
        let f = try DesktopArchiveFixture()
        defer { f.close() }
        f.restoreModel()
        let originalTabs = f.model.tabs
        let frozen = try f.evidence()
        let requests = f.driver.createdTabRequests.count
        let revision = f.model.archiveRevision
        let restoredID = try #require(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target"))
        #expect(restoredID != "a")
        #expect(try f.store.loadArchiveEntry(id: "archive-a") == nil)
        let saved = try #require(try f.store.loadSnapshotStrict())
        let restored = try #require(saved.tabs.first { $0.id == restoredID })
        #expect(restored.urlString == "https://example.com/a?q=100%25_")
        #expect(restored.userTitleOverride == "Saved café")
        #expect(restored.placement == .temporary && restored.spaceID == "target")
        #expect(!saved.tabs.contains { $0.id == "a" })
        #expect(try f.hasTombstone("a"))
        #expect(f.model.archiveRevision > revision)
        #expect(f.driver.createdTabRequests.count == requests + 1)
        #expect(f.model.tabs.filter { $0.syncID != restoredID }.map(\.id) == originalTabs.map(\.id))
        #expect(f.model.selectedSpaceID == "target")
        #expect(f.model.tabs.first { $0.id == f.model.selectedTabID }?.syncID == restoredID)
        let queue = try f.store.pendingSyncQueue(for: f.owner)
        #expect(queue.count == frozen.queue.count + 1)
        guard case .folders(let mutation) = try #require(queue.last) else {
            Issue.record("Archive restore must create an ordinary v4 tab")
            return
        }
        try #require(mutation.operations.count == 1)
        guard case .createTab(let id, let data, _, _) = mutation.operations[0] else {
            Issue.record("Restore must queue a fresh create, never revive the old tab")
            return
        }
        #expect(id == restoredID && data.base.urlString == restored.urlString)
        #expect(data.base.userTitleOverride == restored.userTitleOverride && data.base.spaceID == "target")
        #expect(try Array(f.queueBytes().prefix(frozen.queue.count)) == frozen.queue)
        let committed = try f.evidence()
        f.flushReady()
        #expect(try f.evidence() == committed)
        #expect(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target") == nil)
        #expect(try f.evidence() == committed)
        #expect(f.driver.createdTabRequests.count == requests + 1)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == restoredID } == true)
        #expect(try reopened.loadArchivePage().entries.isEmpty)
    }

    @Test(arguments: ["receipt", "outbox"])
    func failedRestoreLeavesBothModelAndEngineUntouchedAndRetryUsesLatestState(failure: String) throws {
        let f = try DesktopArchiveFixture()
        defer { f.close() }
        f.restoreModel()
        let before = try f.evidence()
        let modelIDs = f.model.tabs.map(\.id)
        let requests = f.driver.createdTabRequests.count
        let trigger = failure == "receipt"
            ? "BEFORE UPDATE OF restored_tab_id ON browser_tab_archive_receipts"
            : "BEFORE INSERT ON browser_sync_outbox"
        try f.sql("CREATE TRIGGER fail_restore \(trigger) BEGIN SELECT RAISE(ABORT, 'injected'); END")
        #expect(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target") == nil)
        #expect(try f.evidence() == before)
        #expect(f.model.tabs.map(\.id) == modelIDs)
        #expect(f.driver.createdTabRequests.count == requests)
        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(!f.model.isArchiveOperationInFlight && f.model.canRestoreArchivedTab)
        #expect(f.model.archiveError != nil)
        try f.sql("DROP TRIGGER fail_restore")
        let survivor = try #require(f.model.tabs.first { $0.syncID == "survivor" })
        f.model.setUserTitleOverride("Edit after failed restore", forTabID: survivor.id)
        let freshID = try #require(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target"))
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "survivor" }?.userTitleOverride ==
            "Edit after failed restore")
        #expect(try f.store.loadSnapshotStrict()?.tabs.contains { $0.id == freshID } == true)
        #expect(try f.store.loadArchiveEntry(id: "archive-a") == nil)
        #expect(f.driver.createdTabRequests.count == requests + 1)
        #expect(f.model.archiveError == nil)
    }

    @Test func missingOriginalSpaceRequiresExplicitLiveDestinationWithoutCreatingFallbackSpace() throws {
        let f = try DesktopArchiveFixture(removeSource: true)
        defer { f.close() }
        f.restoreModel()
        let before = try f.evidence()
        let requests = f.driver.createdTabRequests.count
        #expect(f.model.restoreArchivedTab(id: "archive-a") == nil)
        #expect(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "source") == nil)
        #expect(try f.evidence() == before)
        #expect(f.driver.createdTabRequests.count == requests)
        #expect(f.model.spaces.map(\.id) == ["target"])
        let restored = try #require(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target"))
        #expect(try f.store.loadSnapshotStrict()?.spaces?.map(\.id) == ["target"])
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == restored }?.spaceID == "target")
        #expect(try f.hasTombstone("a"))
    }

    @Test func pendingSessionWriteBlocksRestoreAndReadyLifecycleControlsAdmission() throws {
        let f = try DesktopArchiveFixture()
        defer { f.close() }
        #expect(f.model.canBrowseArchive && !f.model.canRestoreArchivedTab)
        #expect(f.model.restoreArchivedTab(id: "archive-a") == nil)
        f.model.handleContextReady()
        // Startup rows are synchronously hydrated, even before engine callbacks.
        #expect(f.model.canRestoreArchivedTab)
        f.model.createNewTab()
        #expect(!f.model.canRestoreArchivedTab)
        f.flushReady()
        #expect(f.model.canRestoreArchivedTab)
        let survivor = try #require(f.model.tabs.first { $0.syncID == "survivor" })
        try f.sql("CREATE TRIGGER fail_session BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT,'injected'); END")
        f.model.setUserTitleOverride("Pending rename", forTabID: survivor.id)
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.model.canBrowseArchive && !f.model.canRestoreArchivedTab)
        let before = try f.evidence()
        let requests = f.driver.createdTabRequests.count
        #expect(f.model.restoreArchivedTab(id: "archive-a") == nil)
        #expect(try f.evidence() == before && f.driver.createdTabRequests.count == requests)
        try f.sql("DROP TRIGGER fail_session")
        #expect(f.model.retrySessionPersistence())
        #expect(f.model.canRestoreArchivedTab)
        #expect(f.model.prepareSessionForClosure())
        f.model.prepareForTermination()
        #expect(!f.model.canBrowseArchive && !f.model.canRestoreArchivedTab)
        #expect(f.model.restoreArchivedTab(id: "archive-a") == nil)
    }

    @Test(arguments: [false, true])
    func privateAndInstalledWebAppWindowsCannotUseProfileArchive(webApp: Bool) async throws {
        let f = try DesktopArchiveFixture(windowMode: webApp ? desktopArchiveWebAppMode() : .incognito)
        defer { f.close() }
        let before = try f.evidence()
        #expect(!f.model.canBrowseArchive && !f.model.canRestoreArchivedTab)
        #expect(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target") == nil)
        #expect(await !f.model.deleteArchivedTab(id: "archive-a"))
        #expect(await !f.model.clearArchive(through: .init(insertionSequence: Int64.max)))
        do {
            _ = try await f.model.loadArchivedTabs(query: "")
            Issue.record("A private/web-app window must not expose the regular profile Archive")
        } catch {}
        #expect(try f.evidence() == before)
        #expect(f.driver.createdTabRequests.isEmpty)
    }

    @Test func refusedEngineCreationKeepsDurableRestorationAndRuntimeRetryDoesNotConsumeAgain() throws {
        let f = try DesktopArchiveFixture()
        defer { f.close() }
        f.restoreModel()
        let freshID = try #require(f.model.restoreArchivedTab(id: "archive-a", toSpaceID: "target"))
        let runtime = try #require(f.model.tabs.first { $0.syncID == freshID })
        f.driver.emitTabCreationState(id: runtime.id, state: .failed)
        f.driver.flushPendingCreateEvents()
        #expect(f.model.tabs.first { $0.id == runtime.id }?.creationState == .failed)
        #expect(try f.store.loadArchiveEntry(id: "archive-a") == nil)
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == freshID }?.urlString == runtime.urlString)
        let committed = try f.evidence()
        f.driver.retryTabCreationAdmissionResult = false
        #expect(!f.model.retrySelectedTabCreation())
        #expect(try f.evidence() == committed)
        f.driver.retryTabCreationAdmissionResult = true
        #expect(f.model.retrySelectedTabCreation())
        f.driver.emitTabCreationState(id: runtime.id, state: .ready)
        #expect(f.model.tabs.first { $0.id == runtime.id }?.creationState == .ready)
        #expect(f.driver.retryCreationRequests.map(\.id) == [runtime.id, runtime.id])
        #expect(try f.evidence() == committed)
        #expect(try f.hasTombstone("a"))
    }

    @Test func searchDeleteAndCapturedClearPreserveSyncStateAndPublishArchiveChanges() async throws {
        let f = try DesktopArchiveFixture(archivedIDs: ["a", "b"])
        defer { f.close() }
        #expect(f.model.canBrowseArchive)
        let folded = try await f.model.loadArchivedTabs(query: "CAFE", before: nil, limit: 1)
        #expect(folded.entries.map(\.id) == ["archive-a"])
        let literal = try await f.model.loadArchivedTabs(query: "%25_", before: nil, limit: 50)
        #expect(literal.entries.map(\.id) == ["archive-a"])
        let first = try await f.model.loadArchivedTabs(query: "", before: nil, limit: 1)
        let cursor = try #require(first.nextCursor)
        #expect(try await f.model.loadArchivedTabs(query: "", before: cursor, limit: 1).entries.count == 1)
        let boundary = try await f.model.archiveClearBoundary()
        // Another archive insertion during confirmation has an earlier wall clock
        // but a later durable insertion sequence, so Clear must retain it.
        _ = try f.archive("c", archivedAt: 1)
        let before = try f.evidence()
        let revision = f.model.archiveRevision
        var notifications = 0
        var observedBusy = false
        let observer = f.model.objectWillChange.sink {
            notifications += 1
            observedBusy = observedBusy || f.model.isArchiveOperationInFlight
        }
        defer { observer.cancel() }
        #expect(await f.model.clearArchive(through: boundary))
        #expect(try f.store.loadArchivePage().entries.map(\.id) == ["archive-c"])
        let cleared = try f.evidence()
        #expect(cleared.snapshot == before.snapshot && cleared.queue == before.queue && cleared.baseline == before
            .baseline)
        #expect(cleared.cursor == before.cursor)
        #expect(f.model.archiveRevision > revision && notifications > 0 && observedBusy)
        #expect(!f.model.isArchiveOperationInFlight)
        #expect(await f.model.deleteArchivedTab(id: "archive-c"))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(await f.model.deleteArchivedTab(id: "archive-c"))
        let finished = try f.evidence()
        #expect(finished.snapshot == before.snapshot && finished.queue == before.queue && finished.baseline == before
            .baseline)
        #expect(f.driver.createdTabRequests.isEmpty)
        let importedRevision = f.model.archiveRevision
        f.model.syncArchiveDidChange()
        #expect(f.model.archiveRevision > importedRevision)
    }

    @Test func archiveRemovalFailureIsVisibleAndRetryRetainsTheCapturedBoundary() async throws {
        let f = try DesktopArchiveFixture(archivedIDs: ["a", "b"])
        defer { f.close() }
        let boundary = try await f.model.archiveClearBoundary()
        let before = try f.evidence()
        try f
            .sql(
                "CREATE TRIGGER fail_clear BEFORE DELETE ON browser_tab_archive BEGIN SELECT RAISE(ABORT,'injected'); END",
            )
        #expect(await !f.model.clearArchive(through: boundary))
        #expect(try f.evidence() == before)
        #expect(f.model.archiveError != nil && !f.model.isArchiveOperationInFlight)
        try f.sql("DROP TRIGGER fail_clear")
        _ = try f.archive("c", archivedAt: 1)
        #expect(await f.model.clearArchive(through: boundary))
        #expect(try f.store.loadArchivePage().entries.map(\.id) == ["archive-c"])
        #expect(f.model.archiveError == nil)
    }
}

// MARK: - DesktopArchiveFixture

@MainActor private final class DesktopArchiveFixture {
    // MARK: Internal

    let directory: URL
    let databaseURL: URL
    let suite: String
    let defaults: UserDefaults
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://desktop-archive.example")!, userID: "owner")
    let store: BrowserSQLiteSessionStore
    let driver = FakeBrowserTabDriver()
    let model: BrowserChromeModel

    init(archivedIDs: [String] = ["a"], removeSource: Bool = false, windowMode: BrowserWindowMode = .normal) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopArchive-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.suite = BrowserTestDefaults.suiteName("DesktopArchive")
        self.defaults = UserDefaults(suiteName: suite)!
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        try store.bindSyncOwner(owner)
        let seed = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "source", title: "Source", systemImageName: "globe"),
                .init(id: "target", title: "Target", systemImageName: "star"),
            ],
            tabs: ["a", "b", "c", "survivor"].map { id in
                .init(
                    id: id,
                    urlString: "https://example.com/\(id)" + (id == "a" ? "?q=100%25_" : ""),
                    userTitleOverride: id == "a" ? "Saved café" : nil,
                    spaceID: id == "survivor" ? "target" : "source",
                    lastActivityTimestamp: 1_800_000_000,
                )
            },
        )
        let events = try desktopArchiveEvents(seed)
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        for (offset, id) in archivedIDs.enumerated() {
            _ = try Self.archive(id, archivedAt: 1_800_000_010 + Double(offset), store: store)
        }
        if removeSource {
            let current = try #require(try store.loadSnapshotStrict())
            try store.writeSessionBatch([.init(snapshot: .init(
                spaces: current.spaces?.filter { $0.id != "source" },
                tabs: current.tabs.filter { $0.spaceID != "source" },
            ), origin: .local(syncMove: nil))])
        }
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(), windowMode: windowMode,
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {},
        )
    }

    // MARK: Private

    private static func archive(
        _ id: String,
        archivedAt: TimeInterval,
        store: BrowserSQLiteSessionStore,
    ) throws -> BrowserTabArchiveEntry {
        let snapshot = try #require(try store.loadSnapshotStrict())
        let tab = try #require(snapshot.tabs.first { $0.id == id })
        let entry = BrowserTabArchiveEntry(id: "archive-\(id)", tab: tab, archivedAt: archivedAt, title: "Loaded \(id)")
        try store.writeSessionBatch([.init(snapshot: .init(
            spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders,
            tabs: snapshot.tabs.filter { $0.id != id },
        ), origin: .local(syncMove: nil), archiveAction: .insert(entry))])
        return entry
    }

    func restoreModel() {
        model.handleContextReady()
        flushReady()
    }

    func flushReady() {
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
    }

    func sql(_ sql: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) }
    }

    func queueBytes() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read {
            try Data.fetchAll($0, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position")
        }
    }

    func hasTombstone(_ id: String) throws -> Bool {
        try DatabaseQueue(path: databaseURL.path).read {
            let bytes = try #require(try Data.fetchOne($0, sql: "SELECT payload FROM browser_sync_baseline WHERE id=1"))
            return try JSONDecoder()
                .decode(BrowserSyncOutboxBaseline.self, from: bytes)
                .deletedKeys
                .contains("tab:\(id)")
        }
    }

    func evidence() throws -> DesktopArchiveEvidence {
        let rows = try DatabaseQueue(path: databaseURL.path).read { db in
            try (
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id,'') FROM browser_tab_archive_receipts ORDER BY id",
                ),
            )
        }
        return try .init(
            snapshot: store.loadSnapshotStrict(),
            queue: rows.0,
            baseline: rows.1,
            archive: rows.2,
            receipts: rows.3,
            cursor: store.syncCursor(for: owner),
        )
    }

    @discardableResult func archive(_ id: String, archivedAt: TimeInterval) throws -> BrowserTabArchiveEntry {
        try Self.archive(id, archivedAt: archivedAt, store: store)
    }

    func close() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - DesktopArchiveEvidence

private struct DesktopArchiveEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [Data]
    let baseline: [Data]
    let archive: [Data]
    let receipts: [String]
    let cursor: Int
}

private func desktopArchiveEvents(_ snapshot: BrowserTabSessionSnapshot) throws -> [BrowserSyncEvent] {
    try BrowserSyncFolderProjection.canonicalChanges(snapshot).enumerated().map { index, change in
        let encoded = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        var data = encoded["data"] as? [String: Any] ?? [:]
        data["id"] = change.entityID
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: [
            "serverSeq": index + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
            "entityID": change.entityID, "op": change.op.rawValue, "data": data, "createdAt": "2026-10-03T00:00:00Z",
        ]))
    }
}

private func desktopArchiveWebAppMode() -> BrowserWindowMode {
    let url = URL(string: "https://example.com/")!
    return .webApp(.init(
        identifier: "test-app",
        name: "Test app",
        startURL: url,
        scopeURL: url,
        profileDirectoryName: "Default",
        profileName: "Default",
        hostBundleURL: URL(fileURLWithPath: "/tmp/OpenArc.app"),
        bundleURL: URL(fileURLWithPath: "/tmp/TestWebApp.app"),
    ))
}
