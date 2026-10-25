import Foundation
import Testing

@Suite(.serialized) @MainActor struct BrowserDesktopAutomaticArchiveLifecycleTests {
    @Test(arguments: ["bound", "paused", "signed-out", "unreadable"])
    func ownershipChangeAfterAutomaticRequestKeepsLogicalTabAndReplacesOnlyItsRuntime(state: String) throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        let old = try #require(f.model.tabs.first { $0.id == request.id })
        let owner = try BrowserSyncOwner(
            baseURL: #require(URL(string: "https://auto-lifecycle.example")),
            userID: "owner"
        )
        if state == "unreadable" {
            try f.sql("ALTER TABLE browser_sync_state RENAME TO unavailable_sync_state")
        } else {
            try f.store.bindSyncOwner(owner)
            if state == "paused" {
                try f.store.pauseSync()
            }
            if state == "signed-out" {
                try f.store.requireSyncSignIn()
            }
        }
        let before = try f.evidence()
        let order = f.model.tabs.map(\.syncID)
        let selected = f.model.selectedTabID
        let remembered = f.model.spaces.first { $0.id == "work" }?.selectedTabID
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        f.finish(request, .closed)
        let replacement = try #require(f.model.tabs.first { $0.syncID == old.syncID })
        #expect(replacement.id != old.id && replacement.creationState == .creating)
        #expect(replacement.urlString == old.urlString && replacement.lastActivityAt == old.lastActivityAt)
        #expect(f.model.tabs.map(\.syncID) == order && f.model.selectedTabID == selected)
        #expect(f.model.spaces.first { $0.id == "work" }?.selectedTabID == remembered)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(f.driver.createdTabRequests.last?.makeActive == false)
        #expect(f.recording.attempts.isEmpty)
        #expect(try f.evidence() == before)

        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: old.id)
        f.driver.emitCreatedTab(id: old.id, urlString: old.urlString, isActive: false)
        f.flushReady()
        #expect(f.model.tabs.filter { $0.syncID == old.syncID }.count == 1)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo)
        if state == "unreadable" {
            try f.sql("ALTER TABLE unavailable_sync_state RENAME TO browser_sync_state")
        } else {
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try reopened.syncOwner() == owner)
            #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == old.syncID } == true)
            #expect(try reopened.isSyncPaused(for: owner) == (state != "bound"))
        }
    }

    @Test func selectedReplacementRetriesRefusedCreationAndIgnoresBothRetiredAllocationCallbacks() throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.selectTab(id: request.id)
        #expect(f.model.selectedTabID == request.id)
        f.driver.emitUpdate(id: request.id, title: "Latest page", urlString: "https://example.com/latest")
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        f.finish(request, .closed)
        let replacement = try #require(f.model.tabs.first { $0.syncID == "b" })
        #expect(replacement.id != request.id && f.model.selectedTabID == replacement.id)
        #expect(replacement.urlString == "https://example.com/latest")
        #expect(replacement.title == "Latest page" && !replacement.canGoBack && !replacement.canGoForward)
        #expect(f.driver.createdTabRequests.last?.makeActive == true)
        f.driver.emitTabCreationState(id: replacement.id, state: .failed)
        #expect(f.model.selectedTabCreationState == .failed)
        // The old engine can report closure/allocation again after the new one
        // has failed. Neither callback belongs to the retained logical tab.
        f.finish(request, .closed)
        f.driver.emitCreatedTab(id: request.id, urlString: "https://example.com/b", isActive: true)
        f.driver.emitTabCreationState(id: request.id, state: .ready)
        #expect(f.model.selectedTabID == replacement.id && f.model.selectedTabCreationState == .failed)
        #expect(f.model.retrySelectedTabCreation())
        #expect(f.driver.retryCreationRequests.last == .init(id: replacement.id, urlString: replacement.urlString))
        #expect(!f.model.retrySelectedTabCreation())
        f.driver.emitTabCreationState(id: replacement.id, state: .ready)
        f.driver.flushPendingCreateEvents()
        #expect(f.model.selectedTabCreationState == .ready)
        #expect(f.recording.attempts.isEmpty)
        #expect(try f.evidence() == before)
        #expect(f.driver.createdTabRequests.count == creates + 1)

        #expect(f.model.archiveSelectedTab())
        let manual = try #require(f.driver.confirmedCloseRequests.last)
        #expect(manual.id == replacement.id && manual.requestID != request.requestID)
        f.finish(manual, .closed)
        let committed = try f.evidence()
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["b"])
        f.driver.emitCreatedTab(id: replacement.id, urlString: replacement.urlString, isActive: true)
        f.driver.emitCreatedTab(id: request.id, urlString: "https://example.com/b", isActive: true)
        f.driver.emitClose(id: replacement.id)
        #expect(!f.model.tabs.contains { $0.syncID == "b" })
        #expect(try f.evidence() == committed)
    }

    @Test func originalCreationUndoFollowsTheReplacementRuntimeWithoutCreatingArchive() throws {
        let f = try LocalAutomaticArchiveFixture(candidateIDs: [])
        defer { f.close() }
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/created")))
        f.flushReady()
        let created = try #require(f.model.tabs.first { $0.id == f.model.selectedTabID })
        try f.model.selectTab(id: f.runtimeID("a"))
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let automatic = try #require(f.driver.confirmedCloseRequests.last)
        #expect(automatic.id == created.id)
        f.model.selectTab(id: created.id)
        f.finish(automatic, .closed)
        f.flushReady()
        let replacement = try #require(f.model.tabs.first { $0.syncID == created.syncID })
        #expect(replacement.id != created.id && f.model.selectedTabID == replacement.id)
        #expect(f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        f.model.undoManager.undo()
        let undoClose = try #require(f.driver.confirmedCloseRequests.last)
        #expect(undoClose.id == replacement.id && undoClose.requestID != automatic.requestID)
        f.finish(undoClose, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == created.syncID })
        #expect(try f.store.loadSnapshotStrict()?.tabs.contains { $0.id == created.syncID } == false)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(f.model.undoManager.canRedo && !f.model.undoManager.isTabTransitionPending)
    }

    @Test func automaticCloseBeforeAllocationCannotResurrectFromDuplicateCreatedCallbacks() throws {
        let f = try LocalAutomaticArchiveFixture(candidateIDs: [])
        defer { f.close() }
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/not-attached")))
        // Leave the ordinary local creation placeholder queued in the driver.
        let created = try #require(f.model.tabs.first { $0.id == f.model.selectedTabID })
        #expect(created.creationState == .creating)
        let anchor = try f.runtimeID("a")
        f.model.selectTab(id: anchor)
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(request.id == created.id)
        f.finish(request, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == created.syncID })
        let entry = try #require(try f.store.loadArchivePage().entries.first)
        #expect(entry.tab.id == created.syncID && entry.tab.urlString == created.urlString)
        let committed = try f.evidence()
        let order = f.model.tabs.map(\.syncID)
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()

        for _ in 0..<2 {
            f.driver.emitCreatedTab(id: created.id, urlString: created.urlString, isActive: true)
            #expect(f.model.tabs.map(\.syncID) == order && f.model.selectedTabID == anchor)
            #expect(f.recording.attempts.isEmpty)
            #expect(try f.evidence() == committed)
        }
        f.driver.flushPendingCreateEvents()
        f.driver.emitTabCreationState(id: created.id, state: .ready)
        f.driver.emitClose(id: created.id)
        #expect(f.model.tabs.map(\.syncID) == order && f.model.selectedTabID == anchor)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(f.recording.attempts.isEmpty)
        #expect(try f.evidence() == committed)
        #expect(try f.store.loadSnapshotStrict()?.tabs.contains { $0.id == created.syncID } == false)
    }

    @Test func remoteDeletionSupersedesAutomaticConfirmationWithoutReplacementOrArchiveEcho() throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        let creates = f.driver.createdTabRequests.count
        let owner = try BrowserSyncOwner(
            baseURL: #require(URL(string: "https://auto-lifecycle.example")),
            userID: "owner"
        )
        try f.store.bindSyncOwner(owner)
        let remote = try f.store.applyRemoteSyncEvents([
            .init(
                serverSeq: 100, deviceID: "other-device", entityType: "tab", entityID: "b", op: "delete",
                data: .deleted(id: "b"), createdAt: "2026-10-03T00:00:00Z"
            ),
        ], cursor: 100, for: owner)
        f.model.applyRemoteSyncSnapshot(remote)
        #expect(!f.model.tabs.contains { $0.syncID == "b" })
        #expect(f.driver.closedTabRequests.contains(.init(id: request.id, forceClose: true)))
        let committed = try f.evidence()
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: request.id)
        f.driver.emitCreatedTab(id: request.id, urlString: "https://example.com/b", isActive: false)
        #expect(try f.evidence() == committed)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(!f.model.tabs.contains { $0.syncID == "b" })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo)
    }

    @Test func shutdownSupersedesAutomaticConfirmationAndLeavesTheSavedSessionForRestart() throws {
        let f = try LocalAutomaticArchiveFixture()
        defer { f.close() }
        f.expireCandidates()
        f.model.archiveExpiredTemporaryTabs()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(f.model.prepareSessionForClosure())
        f.model.prepareForTermination()
        #expect(f.model.isShuttingDown)
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        f.model.closeAllTabs()
        #expect(f.driver.closedTabRequests.contains(.init(id: request.id, forceClose: true)))
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: request.id)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "b" } == true)
    }
}
