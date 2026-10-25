import AppKit
import Testing

// MARK: - BrowserNativePinnedRemovalTests

@Suite(.serialized) @MainActor struct BrowserNativePinnedRemovalTests {
    @Test(arguments: [BrowserTabPlacement.spacePinned, .app])
    func refusedCancelledAndRepeatedPersistentRemovalLeaveLogicalStateUntouched(
        placement: BrowserTabPlacement
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try prepareRemoval(f, placement: placement)
        let sidebar = PinnedRemovalSidebar(model: f.model)
        defer { sidebar.close() }
        let before = try f.evidence()
        let tabs = f.model.tabs
        let selections = f.driver.selectedTabIDs
        f.driver.closeRequestAdmissionResult = false
        try requestRemoval(f, sidebar: sidebar, id: id, placement: placement)
        #expect(f.driver.confirmedCloseRequests.isEmpty)
        #expect(try f.evidence() == before)
        f.driver.closeRequestAdmissionResult = true
        try requestRemoval(f, sidebar: sidebar, id: id, placement: placement)
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(request.id == id)
        try requestRemoval(f, sidebar: sidebar, id: id, placement: placement)
        #expect(f.driver.confirmedCloseRequests.count == 1)
        #expect(f.model.tabs == tabs && f.driver.selectedTabIDs == selections)
        #expect(f.recording.attempts.isEmpty && !f.model.undoManager.canUndo)
        #expect(try f.evidence() == before)
        f.finish(request, .cancelled)
        #expect(f.model.tabs == tabs && f.driver.selectedTabIDs == selections)
        #expect(try f.evidence() == before)
        try requestRemoval(f, sidebar: sidebar, id: id, placement: placement)
        let retry = try #require(f.driver.confirmedCloseRequests.last)
        #expect(retry.requestID != request.requestID)
        f.driver.emitCloseRequestOutcome(
            id: id, requestID: request.requestID, outcome: .closed, emitsClosedEvent: false
        )
        #expect(f.model.tabs == tabs)
        f.finish(retry, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.recording.attempts.isEmpty && !f.model.undoManager.canUndo)
        #expect(!sidebar.window.isVisible)
    }

    @Test(arguments: [BrowserTabPlacement.spacePinned, .app, .temporary])
    func nativeRemovalCapturesLatestStateAndRepeatedHistoryNeverBecomesArchive(
        finalPlacement: BrowserTabPlacement
    ) throws {
        let f = try ConfirmedCloseFixture(tabIDs: ["a", "b", "c"])
        defer { f.close() }
        let id = try prepareRemoval(f, placement: .spacePinned)
        let sidebar = PinnedRemovalSidebar(model: f.model)
        defer { sidebar.close() }
        try sidebar.closeRow(id)
        let close = try #require(f.driver.confirmedCloseRequests.last)
        #expect(f.model.tabs.contains { $0.id == id })

        // The row's removal intent is fixed even when its current placement
        // becomes Today before the engine confirms the close.
        if finalPlacement != .spacePinned {
            f.model.moveTab(withID: id, toPlacement: finalPlacement, atSectionIndex: 0)
        }
        f.model.setUserTitleOverride("Latest removal override", forTabID: id)
        f.driver.emitUpdate(id: id, title: "Latest page title", urlString: "https://example.com/latest-removal")
        if finalPlacement == .spacePinned {
            #expect(f.model.setPinnedURLString("https://example.com/latest-home", forTabID: id))
        }
        let current = try #require(f.model.tabs.first { $0.id == id })
        let order = f.model.tabs.map(\.syncID)
        let originalIndex = try #require(order.firstIndex(of: "a"))
        let survivor = try f.runtimeID("c")
        f.model.selectTab(id: survivor)
        let selections = f.driver.selectedTabIDs
        let queuePrefix = try f.evidence().queue
        f.recording.reset()
        f.finish(close, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == "a" })
        #expect(f.model.selectedTabID == survivor && f.driver.selectedTabIDs == selections)
        #expect(try f.hasTombstone("a"))
        #expect(try f.operations().filter { $0 == .deleteTab(id: "a") }.count == 1)
        #expect(f.recording.attempts.count == 1)
        #expect(f.recording.attempts.flatMap { $0 }.allSatisfy { $0.archiveAction == nil })
        #expect(try Array(f.evidence().queue.prefix(queuePrefix.count)) == queuePrefix)
        let committed = try f.evidence()
        f.finish(close, .closed)
        f.driver.emitClose(id: id)
        #expect(try f.evidence() == committed)

        var previousSyncID = "a"
        var identities: Set<String> = [previousSyncID]
        for cycle in 0..<2 {
            #expect(f.model.undoManager.canUndo)
            f.model.undoManager.undo()
            f.flushReady()
            let restored = try #require(f.model.tabs.first { $0.userTitleOverride == "Latest removal override" })
            let isFreshIdentity = identities.insert(restored.syncID).inserted
            #expect(restored.syncID != previousSyncID && isFreshIdentity)
            #expect(restored.placement == finalPlacement && restored.spaceID == current.spaceID)
            #expect(restored.urlString == current.urlString && restored.pinnedURLString == current.pinnedURLString)
            #expect(restored.title == current.title && restored.userTitleOverride == current.userTitleOverride)
            #expect(restored.pinnedFolderID == current.pinnedFolderID && restored.pinnedSiblingRank == current
                .pinnedSiblingRank)
            #expect(f.model.tabs[originalIndex].syncID == restored.syncID)
            #expect(f.model.selectedTabID == survivor && f.driver.selectedTabIDs == selections)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            #expect(f.model.undoManager.canRedo)
            let beforeRedo = try f.evidence()
            f.model.undoManager.redo()
            let cancelled = try #require(f.driver.confirmedCloseRequests.last)
            #expect(cancelled.id == restored.id && f.model.undoManager.isTabTransitionPending)
            #expect(try f.evidence() == beforeRedo)
            let requests = f.driver.confirmedCloseRequests.count
            f.model.undoManager.redo()
            #expect(f.driver.confirmedCloseRequests.count == requests)
            f.finish(cancelled, .cancelled)
            #expect(f.model.undoManager.canRedo && !f.model.undoManager.isTabTransitionPending)
            #expect(try f.evidence() == beforeRedo)
            if cycle == 1 {
                break
            }
            f.model.undoManager.redo()
            let confirmed = try #require(f.driver.confirmedCloseRequests.last)
            #expect(confirmed.requestID != cancelled.requestID)
            f.finish(confirmed, .closed)
            #expect(!f.model.tabs.contains { $0.syncID == restored.syncID })
            #expect(try f.hasTombstone(restored.syncID))
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            previousSyncID = restored.syncID
        }
        #expect(identities.count == 3)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        let currentSnapshot = try f.store.loadSnapshotStrict()
        #expect(try reopened.loadSnapshotStrict() == currentSnapshot)
        #expect(try reopened.loadArchivePage().entries.isEmpty)
    }

    @Test(arguments: [BrowserTabPlacement.spacePinned, .app])
    func dormantPersistentRemovalNeedsNoEngineAdmissionAndRemainsUndoable(placement: BrowserTabPlacement) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try prepareRemoval(f, placement: placement)
        f.model.selectTab(id: id)
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        let dormant = try #require(f.model.tabs.first { $0.id == id })
        try f.model.selectTab(id: f.runtimeID("b"))
        f.model.undoManager.removeAllActions()
        let sidebar = PinnedRemovalSidebar(model: f.model)
        defer { sidebar.close() }
        let requests = f.driver.confirmedCloseRequests.count
        let closes = f.driver.closedTabRequests.count
        let creations = f.driver.createdTabRequests.count
        f.driver.closeRequestAdmissionResult = false
        try requestRemoval(f, sidebar: sidebar, id: id, placement: placement)
        #expect(!f.model.tabs.contains { $0.syncID == "a" })
        #expect(f.driver.confirmedCloseRequests.count == requests && f.driver.closedTabRequests.count == closes)
        #expect(f.driver.createdTabRequests.count == creations)
        #expect(try f.hasTombstone("a"))
        #expect(f.model.undoManager.canUndo)
        f.model.undoManager.undo()
        f.flushReady()
        let restored = try #require(f.model.tabs.first { $0.syncID != "b" })
        #expect(restored.syncID != "a" && restored.placement == placement && restored.urlString == dormant.urlString)
        #expect(restored.pinnedURLString == dormant.pinnedURLString && restored.pinnedFolderID == dormant
            .pinnedFolderID)
        #expect(f.driver.createdTabRequests.count == creations + 1)
        #expect(f.model.undoManager.canRedo)
        // Redo now owns a live runtime; admission failure preserves its branch.
        let beforeRedo = try f.evidence()
        f.model.undoManager.redo()
        #expect(f.model.undoManager.canRedo && !f.model.undoManager.isTabTransitionPending)
        #expect(try f.evidence() == beforeRedo)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test func failedNativeRemovalKeepsItsFIFOAheadOfLaterEditsAndRetriesOneDelete() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try prepareRemoval(f, placement: .spacePinned)
        let sidebar = PinnedRemovalSidebar(model: f.model)
        defer { sidebar.close() }
        let before = try f.evidence()
        try f.sql("""
        CREATE TRIGGER fail_pinned_removal BEFORE INSERT ON browser_sync_outbox
        BEGIN SELECT RAISE(ABORT,'injected removal'); END
        """)
        try sidebar.closeRow(id)
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(request, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == "a" })
        #expect(f.model.hasUncommittedSessionWrites && !f.model.undoManager.canUndo)
        #expect(try f.evidence() == before)
        let first = try #require(f.recording.attempts.last)
        #expect(first.count == 1 && first.first?.archiveAction == nil)
        try f.model.setUserTitleOverride("Later survivor edit", forTabID: f.runtimeID("b"))
        let fifo = try #require(f.recording.attempts.last)
        #expect(fifo.count == 2 && Array(fifo.prefix(first.count)) == first)
        #expect(!f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo)
        #expect(try f.evidence() == before)
        try f.sql("DROP TRIGGER fail_pinned_removal")
        #expect(f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo && !f.model.hasUncommittedSessionWrites)
        #expect(f.model.undoManager.canUndo)
        #expect(try f.store
            .loadSnapshotStrict()?
            .tabs
            .first { $0.id == "b" }?
            .userTitleOverride == "Later survivor edit")
        #expect(try f.operations().filter { $0 == .deleteTab(id: "a") }.count == 1)
        #expect(try f.hasTombstone("a"))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        let committed = try f.evidence()
        f.finish(request, .closed)
        #expect(try f.evidence() == committed)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        let currentSnapshot = try f.store.loadSnapshotStrict()
        #expect(try reopened.loadSnapshotStrict() == currentSnapshot)
    }

    @Test func failedLogicalUndoKeepsItsFreshIdentityAndRebuildsFromLaterSurvivorEdits() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try prepareRemoval(f, placement: .spacePinned)
        let sidebar = PinnedRemovalSidebar(model: f.model)
        defer { sidebar.close() }
        try sidebar.closeRow(id)
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        let before = try f.evidence()
        let creations = f.driver.createdTabRequests.count
        f.recording.reset()
        try f.sql("""
        CREATE TRIGGER fail_pinned_undo BEFORE INSERT ON browser_tabs
        WHEN NEW.id != 'b' BEGIN SELECT RAISE(ABORT,'injected restore'); END
        """)
        f.model.undoManager.undo()
        let first = try #require(f.recording.attempts.last?.first)
        let proposed = try #require(first.snapshot.tabs.first { $0.id != "b" })
        let freshID = try #require(proposed.id)
        #expect(freshID != "a" && first.archiveAction == nil)
        #expect(f.model.hasUncommittedSessionWrites && f.model.undoManager.isTabTransitionPending)
        #expect(f.driver.createdTabRequests.count == creations)
        #expect(try f.evidence() == before)
        try f.model.setUserTitleOverride("Saved while Undo awaits Retry", forTabID: f.runtimeID("b"))
        let later = try f.evidence()
        #expect(later.snapshot?.tabs.first { $0.id == "b" }?.userTitleOverride == "Saved while Undo awaits Retry")
        #expect(!f.model.retrySessionPersistence())
        let retried = try #require(f.recording.attempts.last?.first)
        #expect(retried.snapshot.tabs.first { $0.id != "b" }?.id == freshID)
        #expect(retried.snapshot.tabs.first { $0.id == "b" }?.userTitleOverride == "Saved while Undo awaits Retry")
        #expect(try f.evidence() == later)
        try f.sql("DROP TRIGGER fail_pinned_undo")
        #expect(f.model.retrySessionPersistence())
        f.flushReady()
        #expect(!f.model.hasUncommittedSessionWrites && !f.model.undoManager.isTabTransitionPending)
        #expect(f.model.tabs.filter { $0.syncID == freshID }.count == 1)
        #expect(f.driver.createdTabRequests.count == creations + 1)
        #expect(f.model.tabs.first { $0.syncID == "b" }?.userTitleOverride == "Saved while Undo awaits Retry")
        #expect(try f.hasTombstone("a"))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(f.model.undoManager.canRedo)
        let createsAfterRetry = f.driver.createdTabRequests.count
        #expect(f.model.retrySessionPersistence())
        #expect(f.driver.createdTabRequests.count == createsAfterRetry)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        let currentSnapshot = try f.store.loadSnapshotStrict()
        #expect(try reopened.loadSnapshotStrict() == currentSnapshot)
    }

    @Test(arguments: [false, true]) func selectedLogicalRemovalSkipsDormantPinnedFallback(hasLiveToday: Bool) throws {
        let f = try ConfirmedCloseFixture(tabIDs: hasLiveToday ? ["a", "b", "c"] : ["a", "b"])
        defer { f.close() }
        let removedID = try f.runtimeID("a")
        let dormantID = try f.runtimeID("b")
        _ = try #require(f.model.createPinnedTabFolder(containingTabIDs: [removedID, dormantID]))
        f.model.selectTab(id: dormantID)
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        f.model.selectTab(id: removedID)
        f.model.undoManager.removeAllActions()
        let selections = f.driver.selectedTabIDs.count
        let creations = f.driver.createdTabRequests.count
        let expectedSelection = hasLiveToday ? try f.runtimeID("c") : nil

        // This is the explicit logical-removal API. The selected pin's native
        // X is a different action: persistent unload, covered by its own suite.
        #expect(f.model.closeTab(id: removedID))
        #expect(f.model.selectedTabID == removedID)
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        #expect(f.model.selectedTabID == expectedSelection)
        #expect(!Array(f.driver.selectedTabIDs.dropFirst(selections)).contains(dormantID))
        #expect(f.driver.createdTabRequests.count == creations)
        #expect(f.model.tabs.contains { $0.id == dormantID })
        #expect(!f.model.tabs.contains { $0.syncID == "a" })
        #expect(try f.hasTombstone("a"))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test(arguments: ["remote", "shutdown"])
    func supersededNativeRemovalCannotRegisterHistoryOrWriteAfterLateConfirmation(supersession: String) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try prepareRemoval(f, placement: .spacePinned)
        let sidebar = PinnedRemovalSidebar(model: f.model)
        defer { sidebar.close() }
        try sidebar.closeRow(id)
        let request = try #require(f.driver.confirmedCloseRequests.last)
        if supersession == "remote" {
            let projected = try f.store.applyRemoteSyncEvents([
                .init(
                    serverSeq: 100, deviceID: "remote", entityType: "tab", entityID: "a", op: "delete",
                    data: .deleted(id: "a"), createdAt: "2026-10-03T00:00:00Z"
                ),
            ], cursor: 100, for: f.owner)
            f.model.applyRemoteSyncSnapshot(projected)
            #expect(!f.model.tabs.contains { $0.syncID == "a" })
        } else {
            #expect(f.model.prepareSessionForClosure())
            f.model.prepareForTermination()
            f.model.closeAllTabs()
        }
        let before = try f.evidence()
        let creations = f.driver.createdTabRequests.count
        f.recording.reset()
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: id)
        #expect(try f.evidence() == before)
        #expect(f.recording.attempts.isEmpty && f.driver.createdTabRequests.count == creations)
        #expect(!f.model.undoManager.canUndo && !f.model.undoManager.isTabTransitionPending)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }
}

@MainActor private func prepareRemoval(_ f: ConfirmedCloseFixture, placement: BrowserTabPlacement) throws -> String {
    let id = try f.runtimeID("a")
    if placement == .spacePinned {
        _ = try #require(f.model.createPinnedTabFolder(containingTabIDs: [id]))
    } else {
        f.model.moveTab(withID: id, toPlacement: placement, atSectionIndex: 0)
    }
    f.driver.emitUpdate(id: id, title: "Persistent away page", urlString: "https://example.com/away")
    try f.model.selectTab(id: f.runtimeID("b"))
    f.model.undoManager.removeAllActions()
    f.recording.reset()
    return id
}

@MainActor private func requestRemoval(
    _ f: ConfirmedCloseFixture, sidebar: PinnedRemovalSidebar, id: String, placement: BrowserTabPlacement
) throws {
    if placement == .spacePinned {
        try sidebar.closeRow(id)
    } else {
        // A Favorite's native X unloads it; closeTab is the independent logical
        // removal API. Do not change that sidebar policy to exercise this case.
        _ = f.model.closeTab(id: id)
    }
}

// MARK: - PinnedRemovalSidebar

@MainActor private final class PinnedRemovalSidebar {
    // MARK: Lifecycle

    init(model: BrowserChromeModel) {
        _ = NSApplication.shared
        self.state = BrowserNativeSidebarState(model: model, snapshot: model.sidebarSnapshot, sidebarWidth: 260)
        self.view = BrowserNativeSidebarNSView(state: state, header: NSView(), footer: NSView())
        self.window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 260, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 640)
        view.refresh()
        view.layoutSubtreeIfNeeded()
    }

    // MARK: Internal

    let window: NSWindow
    let state: BrowserNativeSidebarState
    let view: BrowserNativeSidebarNSView

    func closeRow(_ id: String) throws {
        let row = try #require(descendants(view).first {
            $0.accessibilityIdentifier() == "browser.sidebar.tab.\(id)"
        } as? BrowserNativeSidebarRowNSView)
        #expect(state.snapshot.selectedTabID != id)
        row.onClose()
    }

    func close() {
        view.cancelDragging()
        window.contentView = nil
        window.close()
    }

    // MARK: Private

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
}
