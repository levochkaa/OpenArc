// BrowserPersistentReopenArchiveObservationTests.swift

import AppKit
import Testing

// MARK: - BrowserPersistentReopenArchiveObservationTests

@Suite(.serialized) @MainActor struct BrowserPersistentReopenArchiveObservationTests {
    @Test(arguments: [BrowserTabPlacement.app, .spacePinned])
    func retiringReopenBindingEnablesObservedArchiveRestoreWithoutAnotherModelEvent(
        placement: BrowserTabPlacement,
    ) async throws {
        _ = NSApplication.shared
        let f = try ConfirmedCloseFixture()
        defer { f.close() }

        try f.model.selectTab(id: f.runtimeID("b"))
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        let archived = try #require(try f.store.loadArchivePage().entries.first)
        #expect(archived.tab.id == "b")

        let originalID = try f.runtimeID("a")
        f.model.selectTab(id: originalID)
        f.model.moveTab(withID: originalID, toPlacement: placement, atSectionIndex: 0)
        #expect(f.model.archiveSelectedTab())
        try f.finish(#require(f.driver.confirmedCloseRequests.last), .closed)
        f.model.selectTab(id: originalID)
        let reopenedID = try f.runtimeID("a")
        #expect(reopenedID != originalID)
        f.driver.emitUpdate(
            id: reopenedID, title: "Newer title than the allocation placeholder",
            urlString: "https://example.com/newer-reopened-page",
        )
        let current = try #require(f.model.tabs.first { $0.id == reopenedID })
        #expect(current.creationState == .creating && !f.model.canRestoreArchivedTab)

        // Subscribe only after setup, so queued notifications from URL, title,
        // selection, or readiness cannot make this observation test pass.
        let controller = BrowserArchiveViewController(model: f.model)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 680, height: 340),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false,
        )
        window.contentViewController = controller
        defer {
            controller.invalidate()
            window.contentViewController = nil
        }
        _ = controller.view
        try await persistentReopenArchiveWait { !controller.isLoading && controller.entries == [archived] }
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(controller.selectedArchiveID == archived.id)
        #expect(!controller.restoreButton.isEnabled && controller.removeButton.isEnabled)
        let before = try f.evidence()
        let archiveRevision = f.model.archiveRevision
        let selections = f.driver.selectedTabIDs
        let creations = f.driver.createdTabRequests
        f.recording.reset()

        // Deliver allocation alone. The stale placeholder metadata is ignored;
        // retiring its private binding must still notify the real Archive UI.
        // Engine readiness is deliberately not emitted here.
        f.driver.flushPendingCreateEvents()
        #expect(f.model.canRestoreArchivedTab)
        try await persistentReopenArchiveWait { controller.restoreButton.isEnabled }

        let retained = try #require(f.model.tabs.first { $0.id == reopenedID })
        #expect(retained.creationState == .creating)
        #expect(retained.title == current.title && retained.urlString == current.urlString)
        #expect(retained.placement == placement && retained.syncID == "a")
        #expect(f.model.selectedTabID == reopenedID && f.model.archiveRevision == archiveRevision)
        #expect(controller.selectedArchiveID == archived.id && controller.entries == [archived])
        #expect(f.driver.selectedTabIDs == selections && f.driver.createdTabRequests == creations)
        #expect(f.recording.attempts.isEmpty)
        #expect(try f.evidence() == before)
    }
}

@MainActor private func persistentReopenArchiveWait(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Archive controls did not observe the completed persistent reopen")
    throw PersistentReopenArchiveObservationError.timeout
}

// MARK: - PersistentReopenArchiveObservationError

private enum PersistentReopenArchiveObservationError: Error { case timeout }
