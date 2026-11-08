// BrowserDesktopPersistentCloseTests.swift

import Foundation
import Testing

// MARK: - BrowserDesktopPersistentCloseTests

@Suite(.serialized) @MainActor struct BrowserDesktopPersistentCloseTests {
    @Test(arguments: [BrowserTabPlacement.app, .spacePinned])
    func refusalAndCancellationDoNotUnloadResetOrPersistThePersistentTab(placement: BrowserTabPlacement) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try preparePersistentClose(f, placement: placement)
        let original = try #require(f.model.tabs.first { $0.id == id })
        let before = try f.evidence()
        let selected = f.model.selectedTabID
        let selections = f.driver.selectedTabIDs
        let creates = f.driver.createdTabRequests.count
        f.driver.closeRequestAdmissionResult = false
        #expect(!f.model.archiveSelectedTab())
        #expect(f.driver.confirmedCloseRequests.isEmpty)
        #expect(try f.evidence() == before)
        f.driver.closeRequestAdmissionResult = true
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        #expect(!f.model.archiveSelectedTab())
        #expect(f.driver.confirmedCloseRequests.count == 1)
        #expect(f.model.selectedTabID == selected && f.driver.selectedTabIDs == selections)
        #expect(f.model.tabs.first { $0.id == id }?.urlString == original.urlString)
        #expect(try f.evidence() == before)
        #expect(f.recording.attempts.isEmpty)
        f.finish(request, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.model.tabs.first { $0.id == id }?.urlString == original.urlString)
        f.model.selectTab(id: id)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(f.model.selectedTabID == selected && !f.model.undoManager.canUndo)
        #expect(f.model.archiveSelectedTab())
        let retry = try #require(f.driver.confirmedCloseRequests.last)
        #expect(retry.requestID != request.requestID)
        f.driver.emitCloseRequestOutcome(
            id: id, requestID: request.requestID, outcome: .closed, emitsClosedEvent: false,
        )
        #expect(try f.evidence() == before)
        f.finish(retry, .cancelled)
        #expect(try f.evidence() == before)
        #expect(f.driver.createdTabRequests.count == creates)
    }

    @Test(arguments: [BrowserTabPlacement.app, .spacePinned])
    func confirmedUnloadUsesLatestMetadataPreservesSelectionAndReopensTheSameIdentity(
        placement: BrowserTabPlacement,
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try preparePersistentClose(f, placement: placement)
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.setUserTitleOverride("Edited during unload", forTabID: id)
        f.driver.emitUpdate(id: id, title: "Latest loaded title", urlString: "https://example.com/latest")
        if placement.keepsPinnedURL {
            #expect(f.model.setPinnedURLString("https://example.com/new-home", forTabID: id))
        }
        let current = try #require(f.model.tabs.first { $0.id == id })
        let survivor = try f.runtimeID("b")
        f.model.selectTab(id: survivor)
        let selections = f.driver.selectedTabIDs
        let order = f.model.tabs.map(\.syncID)
        let queueBefore = try f.evidence().queue
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        f.finish(request, .closed)
        let retained = try #require(f.model.tabs.first { $0.syncID == "a" })
        let expectedURL = placement.keepsPinnedURL ? "https://example.com/new-home" : current.urlString
        #expect(retained.id == id && retained.placement == placement)
        #expect(retained.urlString == expectedURL && retained.userTitleOverride == current.userTitleOverride)
        #expect(retained.pinnedURLString == current.pinnedURLString)
        #expect(retained.pinnedFolderID == current.pinnedFolderID && retained.pinnedSiblingRank == current
            .pinnedSiblingRank)
        #expect(f.model.tabs.map(\.syncID) == order)
        #expect(f.model.selectedTabID == survivor && f.driver.selectedTabIDs == selections)
        #expect(f.driver.createdTabRequests.count == creates)
        // Only the rename is undoable; the unload registers nothing.
        #expect(f.model.undoManager.undoTabActionName == BrowserStrings.undoRenameAction)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try !f.hasTombstone("a"))
        #expect(try !f.operations().contains(.deleteTab(id: "a")))
        #expect(try Array(f.evidence().queue.prefix(queueBefore.count)) == queueBefore)
        let reopenedStore = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        let persisted = try #require(try reopenedStore.loadSnapshotStrict()?.tabs.first { $0.id == "a" })
        #expect(persisted.urlString == expectedURL && persisted.placement == placement)
        #expect(persisted.pinnedFolderID == current.pinnedFolderID && persisted.pinnedSiblingRank == current
            .pinnedSiblingRank)
        let committed = try f.evidence()
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: id)
        #expect(try f.evidence() == committed)
        f.model.selectTab(id: id)
        f.flushReady()
        let reopened = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(reopened.id != id && reopened.urlString == expectedURL)
        #expect(reopened.pinnedFolderID == current.pinnedFolderID && reopened.pinnedSiblingRank == current
            .pinnedSiblingRank)
        #expect(f.model.selectedTabID == reopened.id && f.driver.createdTabRequests.count == creates + 1)
        #expect(f.driver.createdTabRequests.last?.urlString == expectedURL)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        f.driver.emitClose(id: id)
        #expect(f.model.tabs.count(where: { $0.syncID == "a" }) == 1)
    }

    @Test(arguments: ["app-to-pin", "pin-to-app", "app-to-today", "pin-to-today"])
    func placementChangedDuringUnloadKeepsTheLogicalIdentity(transition: String) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let originalPlacement: BrowserTabPlacement = transition.hasPrefix("app") ? .app : .spacePinned
        let destination: BrowserTabPlacement = transition.hasSuffix("today")
            ? .temporary
            : (transition.hasSuffix("pin") ? .spacePinned : .app)
        let id = try preparePersistentClose(f, placement: originalPlacement)
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.moveTab(withID: id, toPlacement: destination, atSectionIndex: 0)
        f.driver.emitUpdate(id: id, urlString: "https://example.com/changed-after-move")
        if destination.keepsPinnedURL {
            #expect(f.model.setPinnedURLString("https://example.com/moved-home", forTabID: id))
        }
        let current = try #require(f.model.tabs.first { $0.id == id })
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        f.finish(request, .closed)
        let retained = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(retained.placement == destination)
        #expect(retained.userTitleOverride == current.userTitleOverride)
        #expect(try !f.hasTombstone("a"))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try !f.operations().contains(.deleteTab(id: "a")))
        #expect(!f.model.undoManager.canUndo)
        if destination == .temporary {
            #expect(retained.id != id && retained.urlString == current.urlString)
            #expect(f.model.selectedTabID == retained.id && retained.creationState == .creating)
            #expect(f.driver.createdTabRequests.count == creates + 1)
            #expect(f.recording.attempts.isEmpty)
            #expect(try f.evidence() == before)
            f.driver.emitTabCreationState(id: retained.id, state: .failed)
            #expect(f.model.retrySelectedTabCreation())
            #expect(f.driver.retryCreationRequests.last == .init(id: retained.id, urlString: current.urlString))
            f.driver.emitTabCreationState(id: retained.id, state: .ready)
            f.driver.flushPendingCreateEvents()
            f.driver.emitCreatedTab(id: id, urlString: "https://example.com/stale", isActive: true)
            f.finish(request, .closed)
            #expect(f.model.selectedTabID == retained.id && f.model.tabs.count(where: { $0.syncID == "a" }) == 1)
            #expect(try f.evidence() == before)
            #expect(f.model.canRestoreArchivedTab, "Retired reopen bookkeeping must not block future Archive actions")
        } else {
            #expect(retained.id == id && f.driver.createdTabRequests.count == creates)
            #expect(retained.urlString == (destination.keepsPinnedURL ? current.pinnedURLString : current.urlString))
            f.model.selectTab(id: id)
            f.flushReady()
            #expect(f.model.tabs.first { $0.syncID == "a" }?.id != id)
            #expect(f.driver.createdTabRequests.count == creates + 1)
        }
    }

    @Test func failedPinnedResetKeepsItsFIFOBeforeLaterEditsAndRetriesWithoutArchiveOrDeletion() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try preparePersistentClose(f, placement: .spacePinned)
        let home = try #require(f.model.tabs.first { $0.id == id }?.pinnedURLString)
        let before = try f.evidence()
        try f.sql("""
        CREATE TRIGGER fail_persistent_close BEFORE DELETE ON browser_tabs
        BEGIN SELECT RAISE(ABORT,'injected persistent reset'); END
        """)
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(request, .closed)
        #expect(f.model.hasUncommittedSessionWrites && f.model.sessionPersistenceFailure?.isRetryable == true)
        #expect(f.model.tabs.first { $0.syncID == "a" }?.urlString == home)
        #expect(try f.evidence() == before)
        let first = try #require(f.recording.attempts.last)
        #expect(first.count == 1 && first.first?.archiveAction == nil)
        let survivor = try f.runtimeID("b")
        f.model.setUserTitleOverride("Later survivor rename", forTabID: survivor)
        let fifo = try #require(f.recording.attempts.last)
        #expect(fifo.count == 2 && Array(fifo.prefix(first.count)) == first)
        #expect(!f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo && !f.model.undoManager.canUndo)
        #expect(try f.evidence() == before)
        try f.sql("DROP TRIGGER fail_persistent_close")
        #expect(f.model.retrySessionPersistence())
        #expect(f.recording.attempts.last == fifo && !f.model.hasUncommittedSessionWrites)
        let snapshot = try #require(try f.store.loadSnapshotStrict())
        #expect(snapshot.tabs.first { $0.id == "a" }?.urlString == home)
        #expect(snapshot.tabs.first { $0.id == "b" }?.userTitleOverride == "Later survivor rename")
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try !f.hasTombstone("a"))
        #expect(try !f.operations().contains(.deleteTab(id: "a")))
        let committed = try f.evidence()
        f.finish(request, .closed)
        #expect(try f.evidence() == committed)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadSnapshotStrict() == snapshot)
    }

    @Test(arguments: ["remote", "shutdown"])
    func supersededPersistentRequestCannotResetReopenOrArchive(supersession: String) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try preparePersistentClose(f, placement: .spacePinned)
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        let creates = f.driver.createdTabRequests.count
        if supersession == "remote" {
            let projected = try f.store.applyRemoteSyncEvents([
                .init(
                    serverSeq: 100, deviceID: "remote", entityType: "tab", entityID: "a", op: "delete",
                    data: .deleted(id: "a"), createdAt: "2026-10-03T00:00:00Z",
                ),
            ], cursor: 100, for: f.owner)
            f.model.applyRemoteSyncSnapshot(projected)
            #expect(!f.model.tabs.contains { $0.syncID == "a" })
        } else {
            #expect(f.model.prepareSessionForClosure())
            f.model.prepareForTermination()
            f.model.closeAllTabs()
            #expect(f.model.isShuttingDown)
        }
        #expect(f.driver.closedTabRequests.contains(.init(id: id, forceClose: true)))
        let before = try f.evidence()
        f.finish(request, .closed)
        f.finish(request, .cancelled)
        f.driver.emitClose(id: id)
        #expect(try f.evidence() == before)
        #expect(f.driver.createdTabRequests.count == creates)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo)
    }

    @Test(arguments: [BrowserTabPlacement.app, .spacePinned], [false, true])
    func forcedAndAlreadyClosedPathsBypassManualConfirmation(
        placement: BrowserTabPlacement, engineAlreadyClosed: Bool,
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let id = try preparePersistentClose(f, placement: placement)
        let handled = placement == .app
            ? f.model.closeAppTabProcess(
                id: id,
                forceClose: !engineAlreadyClosed,
                engineAlreadyClosed: engineAlreadyClosed,
            )
            : f.model.closePinnedTabProcessOrReset(
                id: id, forceClose: !engineAlreadyClosed, engineAlreadyClosed: engineAlreadyClosed,
            )
        #expect(handled && f.driver.confirmedCloseRequests.isEmpty)
        #expect(f.driver.closedTabRequests == (engineAlreadyClosed ? [] : [.init(id: id, forceClose: true)]))
        #expect(f.model.tabs.contains { $0.syncID == "a" && $0.id == id && $0.placement == placement })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(try !f.hasTombstone("a"))
        #expect(!f.model.undoManager.canUndo)
        let before = try f.evidence()
        f.driver.emitClose(id: id)
        #expect(try f.evidence() == before)
    }

    @Test(arguments: [BrowserTabPlacement.app, .spacePinned])
    func cancellingPersistentUnloadPreservesReadinessThatArrivedDuringTheRequest(placement: BrowserTabPlacement) throws {
        let f = try ConfirmedCloseFixture(ready: false)
        defer { f.close() }
        let id = try preparePersistentClose(f, placement: placement)
        #expect(f.model.tabs.first { $0.id == id }?.creationState == .creating)
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.driver.emitTabCreationState(id: id, state: .ready)
        f.finish(request, .cancelled)
        #expect(f.model.tabs.first { $0.id == id }?.creationState == .ready)
        f.model.selectTab(id: id)
        #expect(f.driver.createdTabRequests.count == creates && f.driver.retryCreationRequests.isEmpty)
        #expect(try f.evidence() == before)
    }

    @Test(arguments: ["app-to-pin", "pin-to-app", "pin-to-today"])
    func delayedReopenAllocationCannotReplayOldPlacementSpaceOrSelection(transition: String) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let originalPlacement: BrowserTabPlacement = transition.hasPrefix("app") ? .app : .spacePinned
        let destination: BrowserTabPlacement = transition.hasSuffix("today")
            ? .temporary
            : (transition.hasSuffix("pin") ? .spacePinned : .app)
        let oldID = try preparePersistentClose(f, placement: originalPlacement)
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        f.model.selectTab(id: oldID)
        let reopenedID = try f.runtimeID("a")
        #expect(reopenedID != oldID)
        // Keep the reopened allocation callback pending while the user moves
        // the logical item and then selects a different page in the old Space.
        f.model.createNewSpace()
        let destinationSpace = try #require(f.model.selectedSpaceID)
        #expect(destinationSpace != "work")
        f.model.moveTab(
            withID: reopenedID, toPlacement: destination, atSectionIndex: 0, targetSpaceID: destinationSpace,
        )
        if destination == .spacePinned {
            _ = try #require(f.model.createPinnedTabFolder(containingTabIDs: [reopenedID]))
            #expect(f.model.setPinnedURLString("https://example.com/latest-reopen-home", forTabID: reopenedID))
        }
        f.model.setUserTitleOverride("Renamed after reopen", forTabID: reopenedID)
        let current = try #require(f.model.tabs.first { $0.id == reopenedID })
        // Favorites are global and retain their remembered home Space. The
        // ordinary pinned/Today move adopts its explicit destination Space.
        #expect(current.spaceID == (destination == .app ? "work" : destinationSpace))
        let survivor = try f.runtimeID("b")
        f.model.selectTab(id: survivor)
        let before = try f.evidence()
        let selections = f.driver.selectedTabIDs
        let order = f.model.tabs.map(\.syncID)
        f.recording.reset()
        f.flushReady()
        let delivered = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(delivered.id == reopenedID && delivered.placement == destination && delivered
            .spaceID == current.spaceID)
        #expect(delivered.pinnedFolderID == current.pinnedFolderID && delivered.pinnedSiblingRank == current
            .pinnedSiblingRank)
        #expect(delivered.pinnedURLString == current.pinnedURLString && delivered.urlString == current.urlString)
        #expect(delivered.userTitleOverride == "Renamed after reopen")
        #expect(f.model.selectedSpaceID == "work" && f.model.selectedTabID == survivor)
        #expect(f.driver.selectedTabIDs == selections && f.model.tabs.map(\.syncID) == order)
        #expect(try f.evidence() == before)
        #expect(f.recording.attempts.isEmpty && f.model.canRestoreArchivedTab)
    }

    @Test(arguments: [BrowserTabPlacement.app, .spacePinned])
    func repeatedUnloadBeforeAllocationStaysDormantAndRetiredPlaceholdersCannotCreateAnotherTab(
        placement: BrowserTabPlacement,
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/new-unattached")))
        let created = try #require(f.model.tabs.first { $0.id == f.model.selectedTabID })
        #expect(created.creationState == .creating)
        f.model.moveTab(withID: created.id, toPlacement: placement, atSectionIndex: 0)
        f.model.undoManager.removeAllActions()
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        f.model.selectTab(id: created.id)
        let second = try #require(f.model.tabs.first { $0.syncID == created.syncID })
        #expect(second.id != created.id && second.creationState == .creating)
        #expect(f.model.archiveSelectedTab())
        let unload = try #require(f.driver.confirmedCloseRequests.last)
        f.finish(unload, .closed)
        let before = try f.evidence()
        let selection = f.model.selectedTabID
        let creates = f.driver.createdTabRequests.count
        f.recording.reset()
        f.driver.flushPendingCreateEvents()
        for id in [created.id, second.id, created.id, second.id] {
            f.driver.emitCreatedTab(id: id, urlString: created.urlString, isActive: true)
            f.driver.emitTabCreationState(id: id, state: .ready)
        }
        f.finish(unload, .closed)
        #expect(f.model.tabs.filter { $0.syncID == created.syncID }.map(\.id) == [second.id])
        #expect(f.model.selectedTabID == selection && f.driver.createdTabRequests.count == creates)
        #expect(f.recording.attempts.isEmpty && !f.model.undoManager.canUndo)
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        // A late allocation must not clear the dormant marker: selection still
        // needs to allocate a third native record for the same logical tab.
        f.model.selectTab(id: second.id)
        f.flushReady()
        let third = try #require(f.model.tabs.first { $0.syncID == created.syncID })
        #expect(third.id != second.id && third.id != created.id)
        #expect(f.driver.createdTabRequests.count == creates + 1)
        #expect(f.model.selectedTabID == third.id && f.model.canRestoreArchivedTab)
        #expect(try !f.hasTombstone(created.syncID))
    }

    @Test(arguments: [false, true]) func favoriteUnloadSkipsDormantPinnedFallback(hasToday: Bool) throws {
        let f = try ConfirmedCloseFixture(tabIDs: hasToday ? ["favorite", "pinned", "today"] : ["favorite", "pinned"])
        defer { f.close() }
        let favorite = try f.runtimeID("favorite")
        let pinned = try f.runtimeID("pinned")
        f.model.moveTab(withID: favorite, toPlacement: .app, atSectionIndex: 0)
        f.model.moveTab(withID: pinned, toPlacement: .spacePinned, atSectionIndex: 0)
        #expect(f.model.closePinnedTabProcessOrReset(id: pinned))
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        #expect(f.model.selectedTabID == favorite)
        let creates = f.driver.createdTabRequests.count
        f.model.undoManager.removeAllActions()
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        let expectedSelection = hasToday ? try f.runtimeID("today") : nil
        #expect(f.model.selectedTabID == expectedSelection)
        #expect(f.model.selectedTabID != pinned && f.driver.createdTabRequests.count == creates)
        #expect(f.model.tabs.contains { $0.id == favorite && $0.placement == .app })
        #expect(f.model.tabs.contains { $0.id == pinned && $0.placement == .spacePinned })
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo)
    }

    @Test func demotionDuringAReopenedUnloadReleasesBothRetiredReopenBindings() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let initialID = try preparePersistentClose(f, placement: .spacePinned)
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        f.model.selectTab(id: initialID)
        let reopenedID = try f.runtimeID("a")
        #expect(reopenedID != initialID && !f.model.canRestoreArchivedTab)
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        f.model.moveTab(withID: reopenedID, toPlacement: .temporary, atSectionIndex: 0)
        let before = try f.evidence()
        f.recording.reset()
        f.finish(request, .closed)
        let replacementID = try f.runtimeID("a")
        #expect(replacementID != reopenedID && replacementID != initialID)
        f.flushReady()
        f.driver.emitCreatedTab(id: reopenedID, urlString: "https://example.com/stale", isActive: true)
        f.driver.emitClose(id: reopenedID)
        #expect(f.model.tabs.first { $0.syncID == "a" }?.placement == .temporary)
        #expect(f.model.selectedTabID == replacementID && f.model.canRestoreArchivedTab)
        #expect(f.recording.attempts.isEmpty && !f.model.undoManager.canUndo)
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
    }

    @Test(arguments: [BrowserTabPlacement.app, .spacePinned])
    func cancelledReopenedUnloadKeepsItsRuntimeAndLaterAllocationPreservesNewerSelection(
        placement: BrowserTabPlacement,
    ) throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let initialID = try preparePersistentClose(f, placement: placement)
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        f.model.selectTab(id: initialID)
        let reopenedID = try f.runtimeID("a")
        #expect(reopenedID != initialID && !f.model.canRestoreArchivedTab)
        // The current page changed before its allocation placeholder arrived.
        // Cancel must neither restore the placeholder URL nor mark it dormant.
        f.driver.emitUpdate(id: reopenedID, title: "Newer live title", urlString: "https://example.com/after-reopen")
        #expect(f.model.archiveSelectedTab())
        let request = try #require(f.driver.confirmedCloseRequests.last)
        let survivor = try f.runtimeID("b")
        f.model.selectTab(id: survivor)
        let current = try #require(f.model.tabs.first { $0.id == reopenedID })
        let before = try f.evidence()
        let creates = f.driver.createdTabRequests.count
        let selections = f.driver.selectedTabIDs
        f.recording.reset()
        f.finish(request, .cancelled)
        #expect(try f.evidence() == before)
        #expect(!f.model.canRestoreArchivedTab, "The pending allocation still owns its reopen binding")
        f.flushReady()
        let retained = try #require(f.model.tabs.first { $0.syncID == "a" })
        #expect(retained.id == reopenedID && retained.creationState == .ready && retained.placement == placement)
        #expect(retained.urlString == current.urlString && retained.pinnedURLString == current.pinnedURLString)
        #expect(retained.title == "Newer live title")
        #expect(retained.pinnedFolderID == current.pinnedFolderID && retained.pinnedSiblingRank == current
            .pinnedSiblingRank)
        #expect(f.model.selectedTabID == survivor && f.model.selectedSpaceID == "work")
        #expect(f.driver.selectedTabIDs == selections && f.driver.createdTabRequests.count == creates)
        #expect(f.recording.attempts.isEmpty && f.model.canRestoreArchivedTab)
        #expect(try f.evidence() == before)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(!f.model.undoManager.canUndo)
        f.model.selectTab(id: reopenedID)
        #expect(f.driver.createdTabRequests.count == creates, "Cancel keeps the original reopened engine usable")
    }
}

@MainActor private func preparePersistentClose(
    _ f: ConfirmedCloseFixture, placement: BrowserTabPlacement,
) throws -> String {
    let id = try f.runtimeID("a")
    if placement == .spacePinned {
        _ = try #require(f.model.createPinnedTabFolder(containingTabIDs: [id]))
        #expect(f.model.tabs.first { $0.id == id }?.pinnedFolderID != nil)
        f.driver.emitUpdate(id: id, title: "Away from home", urlString: "https://example.com/away")
    } else {
        f.model.moveTab(withID: id, toPlacement: .app, atSectionIndex: 0)
    }
    #expect(f.model.selectedTabID == id)
    f.model.undoManager.removeAllActions()
    f.recording.reset()
    return id
}
