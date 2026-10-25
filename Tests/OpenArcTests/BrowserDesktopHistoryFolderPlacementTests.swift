import Foundation
import Testing

@Suite(.serialized) @MainActor struct BrowserDesktopHistoryFolderPlacementTests {
    @Test func creationRedoDropsFolderMembershipWhenTheFolderMovedToAnotherSpace() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        f.model.createNewSpace()
        let destination = try #require(f.model.spaces.first { $0.id != "work" }).id
        f.model.selectSpace(id: "work")
        try f.model.openURLInNewTab(#require(URL(string: "https://example.com/folder-redo")))
        f.flushReady()
        let created = try #require(f.model.tabs.first { $0.urlString == "https://example.com/folder-redo" })
        let siblingID = try f.runtimeID("b")
        let folderID = try #require(f.model.createPinnedTabFolder(containingTabIDs: [siblingID, created.id]))
        let pinned = try #require(f.model.tabs.first { $0.id == created.id })
        #expect(pinned.placement == .spacePinned && pinned.spaceID == "work")
        #expect(pinned.pinnedFolderID == folderID && pinned.pinnedSiblingRank == 1)
        #expect(f.model.undoManager.canUndo)

        // Undo Create closes the current pinned incarnation but does not Archive
        // it. The surviving sibling keeps the folder live during its later move.
        f.model.undoManager.undo()
        let close = try #require(f.driver.confirmedCloseRequests.last)
        #expect(close.id == created.id)
        f.finish(close, .closed)
        #expect(!f.model.tabs.contains { $0.syncID == created.syncID })
        #expect(try f.hasTombstone(created.syncID))
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        #expect(f.model.undoManager.canRedo)
        f.model.movePinnedTabFolder(withID: folderID, toRootSectionIndex: 0, targetSpaceID: destination)
        #expect(f.model.pinnedTabFolders.first { $0.id == folderID }?.spaceID == destination)
        #expect(f.model.tabs.first { $0.id == siblingID }?.spaceID == destination)
        #expect(f.model.undoManager.canRedo)
        let queueBeforeRedo = try f.store.pendingSyncQueue(for: f.owner)
        f.recording.reset()

        f.model.undoManager.redo()
        f.flushReady()
        let restored = try #require(f.model.tabs.first { $0.urlString == created.urlString })
        #expect(restored.syncID != created.syncID && restored.id != created.id)
        #expect(restored.spaceID == "work" && restored.placement == .spacePinned)
        #expect(restored.pinnedFolderID == nil && restored.pinnedSiblingRank == nil)
        #expect(restored.pinnedURLString == pinned.pinnedURLString)
        #expect(f.model.selectedTabID == restored.id && f.model.selectedSpaceID == "work")
        #expect(f.model.tabs.first { $0.id == siblingID }?.pinnedFolderID == folderID)
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        #expect(tree.items(in: .pinned("work")) == [.tab(restored.id)])
        #expect(tree.items(in: .pinned(destination)) == [.folder(folderID)])
        #expect(tree.items(in: .pinned(destination, folderID: folderID)) == [.tab(siblingID)])

        let write = try #require(f.recording.attempts.flatMap { $0 }.last)
        let proposed = try #require(write.snapshot.tabs.first { $0.id == restored.syncID })
        #expect(proposed.pinnedFolderID == nil && proposed.pinnedSiblingRank == nil)
        #expect(write.archiveAction == nil)
        let saved = try #require(try f.store.loadSnapshotStrict())
        let durable = try #require(saved.tabs.first { $0.id == restored.syncID })
        #expect(durable.spaceID == "work" && durable.pinnedFolderID == nil)
        #expect(saved.pinnedTabFolders?.first { $0.id == folderID }?.spaceID == destination)
        #expect(try f.store.loadArchivePage().entries.isEmpty)
        let queue = try f.store.pendingSyncQueue(for: f.owner)
        #expect(Array(queue.prefix(queueBeforeRedo.count)) == queueBeforeRedo)
        let newOperations = queue.dropFirst(queueBeforeRedo.count).flatMap { queued in
            if case .folders(let mutation) = queued {
                return mutation.operations
            }
            return [BrowserSyncFolderOperation]()
        }
        let creations = newOperations.compactMap { operation -> BrowserSyncFolderTabCreate? in
            if case .createTab(let id, let data, _, _) = operation, id == restored.syncID {
                return data
            }
            return nil
        }
        try #require(creations.count == 1)
        let creation = try #require(creations.first)
        #expect(creation.base.spaceID == "work" && creation.pinnedFolderID == nil)

        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        #expect(try reopened.loadSnapshotStrict()?.tabs.first { $0.id == restored.syncID } == durable)
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == created.syncID } == false)
        #expect(try reopened.loadArchivePage().entries.isEmpty)
    }
}
