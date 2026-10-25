import Foundation
import Testing

// MARK: - BrowserDesktopArchiveProjectionTests

@Suite(.serialized)
@MainActor struct BrowserDesktopArchiveProjectionTests {
    @Test(arguments: [false, true]) func confirmedCloseArchivesLiveURLDuringPendingRemoteCreationWithoutEcho(
        failsArchiveInsert: Bool
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let runtimeA = try f.runtimeID("a")
        let liveURL = "https://example.com/a"
        let canonicalURL = "https://example.com/a-from-other-device"
        let createdURL = "https://example.com/c"
        let sequence = try f.store.syncCursor(for: f.owner)
        let activity = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: f.clock.now))
        let remote = try f.store.applyRemoteSyncEvents([
            archiveProjectionTabEvent(
                id: "a", url: canonicalURL, rank: 0, sequence: sequence + 1,
                activity: activity, userTitle: "Saved title"
            ),
            archiveProjectionTabEvent(
                id: "c", url: createdURL, rank: 2, sequence: sequence + 2, activity: activity
            ),
        ], cursor: sequence + 2, for: f.owner)
        #expect(remote.tabs.first { $0.id == "a" }?.urlString == canonicalURL)
        f.model.applyRemoteSyncSnapshot(remote)
        let pendingC = try #require(f.driver.createdTabRequests.last)
        #expect(pendingC.urlString == createdURL && !pendingC.makeActive)
        #expect(f.model.tabs.map(\.syncID) == ["a", "b"])
        #expect(f.model.tabs.first { $0.id == runtimeA }?.urlString == liveURL)
        #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "a" }?.urlString == canonicalURL)
        #expect(try f.store.pendingSyncQueue(for: f.owner).isEmpty)
        f.recording.reset()
        let beforeClose = try f.evidence()
        let revision = f.model.archiveRevision

        if failsArchiveInsert {
            try f.sql("""
            CREATE TRIGGER fail_projection_archive BEFORE INSERT ON browser_tab_archive
            BEGIN SELECT RAISE(ABORT,'injected'); END
            """)
        }
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(request.id == runtimeA)
        #expect(try f.evidence() == beforeClose)
        f.finish(request, .closed)
        #expect(f.model.tabs.map(\.syncID) == ["b"])
        #expect(try f.model.selectedTabID == (f.runtimeID("b")))
        let firstAttempt = try #require(f.recording.attempts.first)
        try #require(firstAttempt.count == 1)
        let archiveWrite = try #require(firstAttempt.first)
        let projection = try #require(archiveWrite.archiveProjectionSnapshot)
        #expect(projection.tabs.map(\.id) == ["a", "b", "c"])
        #expect(projection.tabs.first { $0.id == "a" }?.urlString == liveURL)
        #expect(archiveWrite.origin == .local(syncMove: nil))
        #expect(archiveWrite.snapshot.tabs.map(\.id) == ["b", "c"])
        guard case .insert(let entry) = try #require(archiveWrite.archiveAction) else {
            Issue.record("Confirmed Close must insert the live page into Archive")
            return
        }
        #expect(entry.tab.id == "a" && entry.tab.urlString == liveURL)
        #expect(entry.tab.userTitleOverride == "Saved title")

        if failsArchiveInsert {
            // The projection ran inside the failed transaction: even its
            // live URL must roll back with Archive, snapshot and the delete row.
            #expect(try f.evidence() == beforeClose)
            #expect(f.model.hasUncommittedSessionWrites)
            #expect(f.model.archiveRevision == revision)
            #expect(!f.model.undoManager.canUndo)
            f.flushReady()
            #expect(f.model.tabs.map(\.syncID) == ["b", "c"])
            #expect(f.model.tabs.last?.id == pendingC.id)
            #expect(try f.evidence() == beforeClose)
            #expect(f.recording.attempts.count >= 2)
            #expect(f.recording.attempts.allSatisfy { $0.first == archiveWrite })
            let callbackAttempt = try #require(f.recording.attempts.last)
            #expect(callbackAttempt.count == 2)
            #expect(callbackAttempt.last?.origin == .remoteProjection)
            #expect(callbackAttempt.last?.archiveAction == nil)
            #expect(callbackAttempt.last?.archiveProjectionSnapshot == nil)
            try f.sql("DROP TRIGGER fail_projection_archive")
            #expect(f.model.retrySessionPersistence())
        } else {
            #expect(!f.model.hasUncommittedSessionWrites)
            #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
            #expect(try f.store.loadSnapshotStrict()?.tabs.map(\.id) == ["b", "c"])
            let queueBeforeCallback = try f.store.pendingSyncQueue(for: f.owner)
            f.flushReady()
            #expect(try f.store.pendingSyncQueue(for: f.owner) == queueBeforeCallback)
        }

        #expect(!f.model.hasUncommittedSessionWrites)
        #expect(f.model.archiveRevision == revision + 1)
        #expect(f.model.tabs.map(\.syncID) == ["b", "c"])
        #expect(f.model.tabs.last?.id == pendingC.id)
        #expect(f.model.tabs.last?.urlString == createdURL)
        #expect(f.driver.createdTabRequests.count == 3)
        #expect(f.model.undoManager.canUndo)
        #expect(try f.hasTombstone("a"))
        #expect(try f.store.loadArchivePage().entries == [entry])
        // Neither the preserved live URL nor the remote-created C is a local
        // mutation. Only the explicitly confirmed deletion goes to the server.
        #expect(try f.operations() == [.deleteTab(id: "a")])
        #expect(try f.store.syncCursor(for: f.owner) == sequence + 2)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadSnapshotStrict()?.tabs.map(\.id) == ["b", "c"])
        #expect(try reopened.loadSnapshotStrict()?.tabs.last?.urlString == createdURL)
        #expect(try reopened.loadArchivePage().entries == [entry])
        #expect(try reopened.pendingSyncQueue(for: f.owner) == f.store.pendingSyncQueue(for: f.owner))

        // A receipt replay must skip the projection and its old post-close
        // snapshot together. It cannot erase a later edit or restore live A.
        try f.model.setUserTitleOverride("B edited after Archive", forTabID: f.runtimeID("b"))
        let afterRename = try f.evidence()
        #expect(afterRename.snapshot?.tabs.first { $0.id == "b" }?.userTitleOverride == "B edited after Archive")
        #expect(afterRename.queue.count == 2)
        try reopened.writeSessionBatch([archiveWrite])
        #expect(try f.evidence() == afterRename)
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "a" } == false)
        #expect(try f.hasTombstone("a"))
        #expect(f.model.tabs.map(\.syncID) == ["b", "c"])
        #expect(f.driver.createdTabRequests.count == 3)
    }
}

private func archiveProjectionTabEvent(
    id: String, url: String, rank: Double, sequence: Int, activity: String, userTitle: String? = nil
) -> BrowserSyncEvent {
    BrowserSyncEvent(
        serverSeq: sequence, deviceID: "other-device", entityType: "tab", entityID: id, op: "upsert",
        data: .tab(.init(
            id: id, spaceID: "work", placement: .temporary, rank: rank,
            urlString: url, pinnedURLString: nil, title: nil, userTitleOverride: userTitle,
            faviconURLString: nil, lastActivityAt: activity
        )),
        createdAt: "2026-10-03T00:00:00Z"
    )
}
