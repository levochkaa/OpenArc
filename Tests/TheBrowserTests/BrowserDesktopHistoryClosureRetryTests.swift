import Foundation
import Testing

@Suite(.serialized)
@MainActor struct BrowserDesktopHistoryClosureRetryTests {
    @Test(arguments: [BrowserTabPlacement.spacePinned, .app])
    func undoCreationRemovesDormantPersistentIdentityWithoutRequestingANonexistentEngine(
        placement: BrowserTabPlacement
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let url = try #require(URL(string: "https://example.com/dormant-created"))
        f.model.openURLInNewTab(url)
        f.flushReady()
        let created = try #require(f.model.tabs.first { $0.urlString == url.absoluteString })
        f.model.moveTab(withID: created.id, toPlacement: placement, atSectionIndex: 0)
        #expect(f.model.archiveSelectedTab())
        f.driver.emitClose(id: created.id)
        #expect(f.model.tabs.contains { $0.id == created.id && $0.placement == placement })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        let requests = f.driver.confirmedCloseRequests.count
        let closes = f.driver.closedTabRequests.count
        let creates = f.driver.createdTabRequests.count
        // Native bridge has removed the unloaded record and would reject a new
        // confirmation request. The logical removal needs no second close.
        f.driver.closeRequestAdmissionResult = false
        #expect(f.model.undoManager.canUndo)
        f.model.undoManager.undo()
        #expect(!f.model.undoManager.isTabTransitionPending)
        #expect(!f.model.tabs.contains { $0.syncID == created.syncID })
        #expect(f.driver.confirmedCloseRequests.count == requests)
        #expect(f.driver.closedTabRequests.count == closes)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(try f.store.loadSnapshotStrict()?.tabs.contains { $0.id == created.syncID } == false)
        #expect(try f.hasTombstone(created.syncID))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(f.model.undoManager.canRedo)
        f.model.undoManager.redo()
        let restored = try #require(f.model.tabs.first { $0.urlString == url.absoluteString })
        #expect(restored.syncID != created.syncID && restored.id != created.id)
        #expect(restored.placement == placement)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test func nativeClosureRetryFinishesFailedHistoryRestoreWithItsOriginalIdentity() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        #expect(f.model.archiveSelectedTab())
        let close = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(close, .closed)
        let entry = try #require(try f.store.loadArchivePage().entries.first)
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        try f.sql("""
        CREATE TRIGGER fail_closure_history_restore BEFORE UPDATE ON browser_tab_archive_receipts
        BEGIN SELECT RAISE(ABORT,'injected'); END
        """)
        f.model.undoManager.undo()
        let restore = try #require(f.recording.attempts.flatMap { $0 }.compactMap(\.archiveAction).first)
        guard case .restore(let archiveID, let freshID) = restore else {
            Issue.record("Undo must retain its Archive restore action")
            return
        }
        #expect(archiveID == entry.id && freshID != entry.tab.id)
        #expect(f.model.hasUncommittedSessionWrites && f.model.undoManager.isTabTransitionPending)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(try f.evidence() == before)

        var confirmations = 0
        let prepared = BrowserSessionClosureGuard.prepare(models: { [f.model] }) { failed in
            confirmations += 1
            #expect(failed.count == 1 && failed.first === f.model)
            // Bound a regression instead of looping forever if preflight fails
            // to retry the separate history action after the fault is removed.
            guard confirmations == 1 else { return .cancel }
            do {
                try f.sql("DROP TRIGGER fail_closure_history_restore")
                return .retry
            } catch {
                Issue.record(error)
                return .cancel
            }
        }
        #expect(prepared && confirmations == 1)
        #expect(!f.model.hasUncommittedSessionWrites && !f.model.undoManager.isTabTransitionPending)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(f.model.tabs.filter { $0.syncID == freshID }.count == 1)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try f.store.loadSnapshotStrict()?.tabs.filter { $0.id == freshID }.count == 1)
        let attempts = f.recording.attempts.flatMap { $0 }.compactMap(\.archiveAction)
        #expect(attempts.count >= 3 && attempts.allSatisfy { $0 == restore })
        #expect(f.model.undoManager.canRedo)

        // Successful close preflight must not issue an unguarded second write
        // while teardown proceeds, nor restore a second runtime.
        let writesAfterPreflight = f.recording.attempts.count
        f.model.prepareForTermination()
        #expect(f.model.isShuttingDown)
        #expect(f.recording.attempts.count == writesAfterPreflight)
        #expect(f.driver.createdTabRequests.count == creates + 1)
    }
}
