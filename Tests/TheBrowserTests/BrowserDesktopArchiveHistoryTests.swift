import AppKit
import Testing

// MARK: - BrowserDesktopArchiveHistoryTests

@Suite(.serialized) @MainActor struct BrowserDesktopArchiveHistoryTests {
    @Test func immediateRedoCompletesBeforeOlderCreationCallbacksArrive() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/unattached")))
        let original = try historyTab(in: f, path: "unattached")
        #expect(original.creationState == .creating)
        f.model.undoManager.undo()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(request.id == original.id)
        f.finish(request, .closed)
        #expect(f.model.undoManager.canRedo)
        f.model.undoManager.redo()
        let recreated = try historyTab(in: f, path: "unattached")
        #expect(recreated.syncID != original.syncID && recreated.id != original.id)
        #expect(recreated.creationState == .creating)
        #expect(f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(!f.model.hasUncommittedSessionWrites)
        let committed = try f.evidence()
        f.flushReady()
        #expect(try f.evidence() == committed)
        #expect(f.model.tabs.filter { $0.urlString == recreated.urlString }.map(\.syncID) == [recreated.syncID])
        #expect(try f.hasTombstone(original.syncID))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test func undoCloseConsumesArchiveAndOriginalCreationUndoFollowsTheFreshIdentity() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let created = try createHistoryTab(in: f, path: "created")
        try confirmHistoryClose(in: f, id: created.id)
        let archived = try #require(try f.store.loadArchivePage().entries.first)
        #expect(archived.tab.id == created.syncID)
        #expect(f.model.undoManager.canUndo)
        f.model.undoManager.undo()
        f.flushReady()
        let restored = try historyTab(in: f, path: "created")
        #expect(restored.syncID != created.syncID && restored.id != created.id)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try f.hasTombstone(created.syncID))
        #expect(f.model.undoManager.canUndo && f.model.undoManager.canRedo)

        // The original creation entry must target the restored incarnation.
        let beforeUndoCreate = try f.evidence()
        f.model.undoManager.undo()
        let cancelled = try #require(f.driver.confirmedCloseRequests.last)
        #expect(cancelled.id == restored.id)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(try f.evidence() == beforeUndoCreate)
        f.finish(cancelled, .cancelled)
        #expect(f.model.undoManager.canUndo && f.model.undoManager.canRedo)
        f.model.undoManager.undo()
        let accepted = try #require(f.driver.confirmedCloseRequests.last)
        #expect(accepted.requestID != cancelled.requestID && accepted.id == restored.id)
        f.finish(accepted, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == restored.syncID })
        #expect(try f.hasTombstone(restored.syncID))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo && f.model.undoManager.canRedo)

        f.model.undoManager.redo()
        f.flushReady()
        let recreated = try historyTab(in: f, path: "created")
        #expect(recreated.syncID != created.syncID && recreated.syncID != restored.syncID)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try f.store.loadSnapshotStrict()?.tabs.contains { $0.id == recreated.syncID } == true)
    }

    @Test func cancelledRedoRetainsItsEntryAndConfirmedRedoPreservesTheRemainingRedoStack() throws {
        let f = try ConfirmedCloseFixture(tabIDs: ["a", "b", "c"])
        defer { f.close() }
        try confirmHistoryClose(in: f, id: f.runtimeID("a"))
        try confirmHistoryClose(in: f, id: f.runtimeID("b"))
        let initialEntries = try f.store.loadArchivePage().entries
        #expect(Set(initialEntries.compactMap(\.tab.id)) == ["a", "b"])
        f.model.undoManager.undo()
        f.flushReady()
        f.model.undoManager.undo()
        f.flushReady()
        let restoredA = try historyTab(in: f, path: "a")
        let restoredB = try historyTab(in: f, path: "b")
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo && f.model.undoManager.canRedo)

        let before = try f.evidence()
        f.model.undoManager.redo()
        let cancelled = try #require(f.driver.confirmedCloseRequests.last)
        #expect(cancelled.id == restoredA.id)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        f.model.undoManager.undo()
        f.model.undoManager.redo()
        #expect(f.driver.confirmedCloseRequests.last == cancelled)
        f.finish(cancelled, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.model.undoManager.canRedo && !f.model.undoManager.canUndo)

        f.model.undoManager.redo()
        let firstRedo = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(firstRedo, .closed)
        let firstEntry = try #require(try f.store.loadArchivePage().entries.first)
        #expect(firstEntry.tab.id == restoredA.syncID)
        #expect(!initialEntries.contains { $0.id == firstEntry.id })
        #expect(f.model.undoManager.canUndo && f.model.undoManager.canRedo)
        let afterFirst = try f.evidence()
        f.finish(firstRedo, .closed)
        #expect(try f.evidence() == afterFirst && f.model.undoManager.canRedo)

        f.model.undoManager.redo()
        let secondRedo = try #require(f.driver.confirmedCloseRequests.last)
        #expect(secondRedo.id == restoredB.id)
        f.finish(secondRedo, .closed)
        let finalEntries = try f.store.loadArchivePage().entries
        #expect(Set(finalEntries.compactMap(\.tab.id)) == [restoredA.syncID, restoredB.syncID])
        #expect(Set(finalEntries.map(\.id)).isDisjoint(with: initialEntries.map(\.id)))
        #expect(!f.model.undoManager.canRedo && f.model.undoManager.canUndo)
        #expect(f.model.tabs.map(\.syncID) == ["c"])
    }

    @Test func failedUndoRetainsOneFreshIdentityAndRetriesAgainstLaterOrdinaryEdits() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try confirmHistoryClose(in: f, id: f.runtimeID("a"))
        let archived = try #require(try f.store.loadArchivePage().entries.first)
        let before = try f.evidence()
        let engineCount = f.driver.createdTabRequests.count
        f.recording.reset()
        try f.sql("""
        CREATE TRIGGER fail_history_restore BEFORE UPDATE ON browser_tab_archive_receipts
        BEGIN SELECT RAISE(ABORT,'injected'); END
        """)
        f.model.undoManager.undo()
        let action = try #require(f.recording.attempts.flatMap { $0 }.compactMap(\.archiveAction).last)
        guard case .restore(let archiveID, let freshID) = action else {
            Issue.record("Undo must use an atomic Archive restore action")
            return
        }
        #expect(archiveID == archived.id && freshID != "a")
        #expect(f.model.hasUncommittedSessionWrites && f.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(f.driver.createdTabRequests.count == engineCount)
        #expect(try f.evidence() == before)
        #expect(!f.model.tabs.contains { $0.syncID == freshID })
        #expect(!f.model.retrySessionPersistence())
        #expect(f.driver.createdTabRequests.count == engineCount)

        // Ordinary browsing is still admitted; Retry must not overwrite it.
        try f.model.setUserTitleOverride("Edited after failed Undo", forTabID: f.runtimeID("b"))
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/later")))
        let later = try historyTab(in: f, path: "later")
        #expect(later.creationState == .creating)
        #expect(f.model.hasUncommittedSessionWrites)
        #expect(f.model.tabs.contains { $0.syncID == later.syncID })
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        try f.sql("DROP TRIGGER fail_history_restore")
        #expect(f.model.retrySessionPersistence())
        f.flushReady()
        #expect(!f.model.hasUncommittedSessionWrites && f.model.sessionPersistenceFailure == nil)
        let restores = f.recording.attempts.flatMap { $0 }.compactMap(\.archiveAction).filter {
            if case .restore = $0 {
                return true
            }
            return false
        }
        #expect(restores.count >= 3 && restores.allSatisfy { $0 == action })
        let restored = try historyTab(in: f, path: "a")
        #expect(restored.syncID == freshID)
        #expect(f.model.tabs.contains { $0.syncID == later.syncID })
        #expect(f.model.tabs.first { $0.syncID == "b" }?.userTitleOverride == "Edited after failed Undo")
        let durable = try #require(try f.store.loadSnapshotStrict())
        #expect(Set(durable.tabs.compactMap(\.id)) == [freshID, "b", later.syncID])
        #expect(durable.tabs.first { $0.id == "b" }?.userTitleOverride == "Edited after failed Undo")
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try f.hasTombstone("a"))
        #expect(!f.model.undoManager.canRedo)
        // The newer Create remains the newest Undo after the older Undo finishes.
        f.model.undoManager.undo()
        let undoLater = try #require(f.driver.confirmedCloseRequests.last)
        #expect(undoLater.id == later.id)
        f.finish(undoLater, .cancelled)
    }

    @Test func failedCloseKeepsItsHistoryPositionBeforeANewerCreationThroughPersistenceRetry() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try f.sql("""
        CREATE TRIGGER fail_close_order BEFORE INSERT ON browser_sync_outbox
        BEGIN SELECT RAISE(ABORT,'injected'); END
        """)
        try confirmHistoryClose(in: f, id: f.runtimeID("a"))
        #expect(f.model.hasUncommittedSessionWrites && !f.model.undoManager.canUndo)
        let closeAction = try #require(f.recording.attempts.last?.first?.archiveAction)
        guard case .insert(let archived) = closeAction else {
            Issue.record("Confirmed close must retain its Archive insertion through Retry")
            return
        }
        let newer = try createHistoryTab(in: f, path: "after-failed-close")
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        try f.sql("DROP TRIGGER fail_close_order")
        #expect(f.model.retrySessionPersistence())
        #expect(try f.store.loadArchivePage().entries == [archived])
        #expect(f.model.undoManager.canUndo)

        f.model.undoManager.undo()
        let undoNewer = try #require(f.driver.confirmedCloseRequests.last)
        #expect(undoNewer.id == newer.id)
        f.finish(undoNewer, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == newer.syncID })
        #expect(try f.store.loadArchivePage().entries == [archived])
        #expect(f.model.undoManager.canUndo)
        f.model.undoManager.undo()
        f.flushReady()
        let restored = try historyTab(in: f, path: "a")
        #expect(restored.syncID != "a")
        #expect(f.model.tabs.contains { $0.syncID == "b" })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try f.hasTombstone("a"))
        #expect(!f.model.undoManager.canUndo && f.model.undoManager.canRedo)
    }

    @Test func redoCompletingAfterANewTabBecomesNewestUndoAtActualCompletion() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try confirmHistoryClose(in: f, id: f.runtimeID("a"))
        f.model.undoManager.undo()
        f.flushReady()
        let restored = try historyTab(in: f, path: "a")
        f.model.undoManager.redo()
        let redo = try #require(f.driver.confirmedCloseRequests.last)
        #expect(redo.id == restored.id)
        let later = try createHistoryTab(in: f, path: "during-redo")
        #expect(f.model.selectedTabID == later.id)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        f.finish(redo, .closed)
        #expect(f.model.selectedTabID == later.id)
        #expect(f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == [restored.syncID])

        f.model.undoManager.undo()
        f.flushReady()
        let restoredAgain = try historyTab(in: f, path: "a")
        #expect(restoredAgain.syncID != restored.syncID)
        #expect(f.model.tabs.contains { $0.syncID == later.syncID })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        f.model.undoManager.undo()
        let undoLater = try #require(f.driver.confirmedCloseRequests.last)
        #expect(undoLater.id == later.id)
        f.finish(undoLater, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == later.syncID })
        #expect(f.model.tabs.contains { $0.syncID == restoredAgain.syncID })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test(arguments: [BrowserTabCloseOutcome.cancelled, .closed])
    func newerCreationDuringPendingUndoDoesNotReviveAnObsoleteRedoBranch(outcome: BrowserTabCloseOutcome) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let first = try createHistoryTab(in: f, path: "first")
        f.model.undoManager.undo()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(request.id == first.id)
        let second = try createHistoryTab(in: f, path: "second")
        f.finish(request, outcome)
        #expect(f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        #expect(f.model.tabs.contains { $0.syncID == first.syncID } == (outcome == .cancelled))
        #expect(f.model.tabs.contains { $0.syncID == second.syncID })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        f.model.undoManager.undo()
        let undoSecond = try #require(f.driver.confirmedCloseRequests.last)
        #expect(undoSecond.id == second.id)
        f.finish(undoSecond, .closed)
        #expect(f.model.undoManager.canUndo == (outcome == .cancelled))
        if outcome == .cancelled {
            f.model.undoManager.undo()
            let undoFirst = try #require(f.driver.confirmedCloseRequests.last)
            #expect(undoFirst.id == first.id)
            f.finish(undoFirst, .cancelled)
        }
    }

    @Test func resettingHistoryWhileRedoIsPendingDoesNotReinstallHistoryOnLateConfirmation() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try confirmHistoryClose(in: f, id: f.runtimeID("a"))
        f.model.undoManager.undo()
        f.flushReady()
        let restored = try historyTab(in: f, path: "a")
        f.model.undoManager.redo()
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.undoManager.removeAllActions()
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        f.finish(request, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == restored.syncID })
        #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == [restored.syncID])
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
        let committed = try f.evidence()
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        #expect(try f.evidence() == committed)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
    }

    @Test(arguments: [false, true])
    func removedOrClearedArchiveCannotBeRecreatedByAStaleUndo(clearAll: Bool) async throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try confirmHistoryClose(in: f, id: f.runtimeID("a"))
        let archived = try #require(try f.store.loadArchivePage().entries.first)
        if clearAll {
            let boundary = try await f.model.archiveClearBoundary()
            #expect(await f.model.clearArchive(through: boundary))
        } else {
            #expect(await f.model.deleteArchivedTab(id: archived.id))
        }
        let removed = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        #expect(f.model.undoManager.canUndo)
        f.model.undoManager.undo()
        f.flushReady()
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(try f.evidence() == removed)
        #expect(f.model.tabs.map(\.syncID) == ["b"])
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try f.hasTombstone("a"))
        #expect(f.model.archiveError != nil)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.canRedo)
    }
}

@MainActor private func createHistoryTab(in fixture: ConfirmedCloseFixture, path: String) throws -> BrowserChromeModel
.Tab {
    try fixture.model.openURLInNewTab(#require(URL(string: "https://example.com/\(path)")))
    fixture.flushReady()
    return try historyTab(in: fixture, path: path)
}

@MainActor private func historyTab(in fixture: ConfirmedCloseFixture, path: String) throws -> BrowserChromeModel.Tab {
    try #require(fixture.model.tabs.first { $0.urlString == "https://example.com/\(path)" })
}

@MainActor private func confirmHistoryClose(in fixture: ConfirmedCloseFixture, id: String) throws {
    fixture.model.selectTab(id: id)
    #expect(fixture.model.archiveSelectedTab())
    let request = try #require(fixture.driver.confirmedCloseRequests.last)
    #expect(request.id == id)
    fixture.finish(request, .closed)
}
