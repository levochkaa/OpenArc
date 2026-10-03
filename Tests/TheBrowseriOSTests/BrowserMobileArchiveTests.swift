import BrowserMobileTestHost
import Foundation
import GRDB
import Network
import Testing
import UIKit
import WebKit

extension BrowserMobileUITests {
    @Test func archiveCloseAndRestoreAreExactlyOnceAcrossTwoSharedScenes() async throws {
        try await withMobileArchiveFixture { f in
            let firstEngine = MobileArchiveEngine(), secondEngine = MobileArchiveEngine()
            let first = await f.workspace(engine: firstEngine, scene: "first")
            let second = await f.workspace(engine: secondEngine, scene: "second")
            first.selectTab(id: "a")
            second.selectTab(id: "b")
            let firstRuntime = try #require(first.tabs.first { $0.id == "a" }?.runtimeID)
            let secondRuntime = try #require(second.tabs.first { $0.id == "a" }?.runtimeID)
            firstEngine.onEvent?(.state(id: firstRuntime, .init(
                url: URL(string: "https://archive.example/latest"), title: "Latest document title"
            )))
            #expect(f.document.renameTab(id: "a", title: "User title"))
            let latest = try #require(f.document.snapshot.tabs.first { $0.id == "a" })
            let previous = try f.queue()
            first.closeTab(id: "a")
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            #expect(entry.tab == latest && entry.title == "Latest document title")
            #expect(entry.archivedAt == 1_800_000_100)
            #expect(!first.tabs.contains { $0.id == "a" } && !second.tabs.contains { $0.id == "a" })
            #expect(firstEngine.closed.contains(firstRuntime) && secondEngine.closed.contains(secondRuntime))
            #expect(second.selectedTabID == "b")
            let afterClose = try f.queue()
            #expect(afterClose.count == previous.count + 1)
            #expect(try f.lastOperations() == [.deleteTab(id: "a")])
            second.closeTab(id: "a")
            #expect(try f.queue() == afterClose)
            #expect(try f.store.loadArchivePage().entries == [entry])

            let restoredID = try #require(first.restoreArchivedTab(id: entry.id))
            #expect(restoredID != "a" && first.selectedTabID == restoredID)
            #expect(second.selectedTabID == "b")
            #expect(first.tabs.first { $0.id == restoredID }?.runtimeID != second.tabs
                .first { $0.id == restoredID }?
                .runtimeID)
            let restored = try #require(f.document.snapshot.tabs.first { $0.id == restoredID })
            #expect(restored.urlString == latest.urlString && restored.userTitleOverride == "User title")
            #expect(restored.placement == .temporary && restored.spaceID == "source" && restored.pinnedFolderID == nil)
            #expect(restored.lastActivityTimestamp == 1_800_000_100)
            let afterRestore = try f.queue()
            #expect(second.restoreArchivedTab(id: entry.id) == nil)
            #expect(try f.queue() == afterRestore)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try reopened.loadSnapshotStrict() == f.document.snapshot)
            #expect(try reopened.loadArchiveEntry(id: entry.id) == nil)
            #expect(try reopened.pendingSyncQueue(for: f.owner) == afterRestore)
        }
    }

    @Test func archiveRestoreRequiresExplicitLiveSpaceAfterOriginalWasDeleted() async throws {
        try await withMobileArchiveFixture { f in
            let workspace = await f.workspace(engine: MobileArchiveEngine(), scene: "first")
            #expect(f.document.updateURL(tabID: "a", urlString: "tb://settings"))
            workspace.closeTab(id: "a")
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            #expect(f.document.delete(entity: .init(entityType: .space, entityID: "source")))
            let before = try f.queue()
            #expect(workspace.restoreArchivedTab(id: entry.id) == nil)
            #expect(workspace.restoreArchivedTab(id: entry.id, toSpaceID: "nonexistent") == nil)
            #expect(try f.queue() == before)
            #expect(try f.store.loadArchivePage().entries == [entry])
            #expect(f.document.snapshot.spaces?.map(\.id) == ["target"])
            let restoredID = try #require(workspace.restoreArchivedTab(id: entry.id, toSpaceID: "target"))
            #expect(workspace.selectedSpaceID == "target" && workspace.selectedTabID == restoredID)
            #expect(f.document.snapshot.tabs.first { $0.id == restoredID }?.urlString == "tb://settings")
            #expect(f.document.snapshot.tabs.first { $0.id == restoredID }?.spaceID == "target")
            #expect(!f.document.snapshot.spaces!.contains { $0.id == "source" })
            // Unsupported desktop pages are recovery data, not silently discarded.
            #expect(workspace.selectedTab?.state.error != nil)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
        }
    }

    @Test func failedArchiveAndRestoreRetainEffectsAndFreshIdentityThroughFIFORetry() async throws {
        try await withMobileArchiveFixture { f in
            let first = await f.workspace(engine: MobileArchiveEngine(), scene: "first")
            let second = await f.workspace(engine: MobileArchiveEngine(), scene: "second")
            let original = try f.store.loadSnapshotStrict()
            let revision = first.archiveRevision
            try f
                .sql(
                    "CREATE TRIGGER fail_archive BEFORE INSERT ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            first.closeTab(id: "a")
            #expect(f.document.hasUncommittedWrites && f.document.persistenceFailure?.isRetryable == true)
            #expect(!first.canRestoreArchivedTab && !second.canRestoreArchivedTab)
            #expect(!first.tabs.contains { $0.id == "a" } && !second.tabs.contains { $0.id == "a" })
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            #expect(first.archiveRevision == revision)
            #expect(try f.store.loadSnapshotStrict() == original && f.queue().isEmpty)
            second.closeTab(id: "b")
            #expect(f.document.snapshot.tabs.contains { $0.id == "b" })
            #expect(f.document.renameTab(id: "b", title: "Edit after failed close"))
            let admitted = f.document.snapshot
            f.document.applyRemoteSyncSnapshot(.init(tabs: []))
            #expect(f.document.snapshot == admitted)
            #expect(!f.document.retryPersistence())
            try f.sql("DROP TRIGGER fail_archive")
            #expect(f.document.retryPersistence())
            #expect(try f.store.loadSnapshotStrict() == admitted)
            #expect(first.archiveRevision == revision + 1)
            #expect(try f.operations() == [
                .deleteTab(id: "a"), .patchTab(
                    id: "b",
                    fields: .init(userTitleOverride: .set("Edit after failed close"))
                ),
            ])
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            let queueBeforeRestore = try f.queue()

            try f
                .sql(
                    "CREATE TRIGGER fail_restore BEFORE UPDATE OF restored_tab_id ON browser_tab_archive_receipts BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            let freshID = try #require(first.restoreArchivedTab(id: entry.id))
            #expect(freshID != "a" && first.selectedTabID == freshID)
            #expect(second.restoreArchivedTab(id: entry.id) == nil)
            #expect(f.document.snapshot.tabs.filter { $0.id == freshID }.count == 1)
            #expect(try f.queue() == queueBeforeRestore && f.store.loadArchiveEntry(id: entry.id) == entry)
            #expect(f.document.renameTab(id: freshID, title: "After failed restore"))
            let restored = f.document.snapshot
            try f.sql("DROP TRIGGER fail_restore")
            #expect(f.document.retryPersistence())
            #expect(try f.store.loadSnapshotStrict() == restored)
            #expect(try f.store.loadArchiveEntry(id: entry.id) == nil)
            #expect(try f.queue().count == queueBeforeRestore.count + 2)
            #expect(second.restoreArchivedTab(id: entry.id) == nil)
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try reopened.loadSnapshotStrict()?.tabs.filter { $0.id == freshID }.count == 1)
            #expect(try reopened.pendingSyncQueue(for: f.owner) == f.queue())
        }
    }

    @Test func persistentUnloadEngineCloseAndRemoteOrCascadeDeleteDoNotCreateArchive() async throws {
        try await withMobileArchiveFixture { f in
            let engine = MobileArchiveEngine()
            let workspace = await f.workspace(engine: engine, scene: "first")
            let original = try f.store.loadSnapshotStrict()
            for id in ["pin", "favorite"] {
                workspace.selectTab(id: id)
                let runtime = try #require(workspace.selectedTab?.runtimeID)
                workspace.closeTab(id: id)
                #expect(f.document.snapshot.tabs.contains { $0.id == id })
                #expect(workspace.tabs.first { $0.id == id }?.runtimeID != runtime)
                #expect(engine.closed.contains(runtime))
            }
            #expect(try f.store.loadSnapshotStrict() == original && f.queue().isEmpty)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            let closedRuntime = try #require(workspace.tabs.first { $0.id == "b" }?.runtimeID)
            engine.onEvent?(.closed(id: closedRuntime))
            #expect(!f.document.snapshot.tabs.contains { $0.id == "b" })
            #expect(try f.store.loadArchivePage().entries.isEmpty)

            let event = try mobileArchiveEvents([
                .init(entityType: .tab, entityID: "remote", op: .delete, spaceData: nil, tabData: nil),
            ], startingAt: 100)
            let remote = try f.store.applyRemoteSyncEvents(event, cursor: 100, for: f.owner)
            f.document.applyRemoteSyncSnapshot(remote)
            #expect(!workspace.tabs.contains { $0.id == "remote" })
            #expect(f.document.delete(entity: .init(entityType: .folder, entityID: "folder")))
            #expect(!workspace.tabs.contains { $0.id == "pin" })
            #expect(f.document.delete(entity: .init(entityType: .space, entityID: "source")))
            #expect(workspace.tabs.contains { $0.id == "favorite" })
            #expect(try f.store.loadArchivePage().entries.isEmpty)
        }
    }

    @Test func archivingLastTodayTabLeavesEmptySpaceWithoutCreatingBlankTab() async throws {
        try await withMobileArchiveFixture { f in
            let workspace = await f.workspace(engine: MobileArchiveEngine(), scene: "first")
            #expect(f.document.delete(entity: .init(entityType: .space, entityID: "source")))
            #expect(f.document.removeTab(id: "favorite"))
            workspace.selectTab(id: "remote")
            #expect(workspace.tabs.map(\.id) == ["remote"])
            let before = try f.queue()
            workspace.closeTab(id: "remote")
            #expect(workspace.tabs.isEmpty && workspace.selectedTabID == nil)
            #expect(workspace.selectedSpaceID == "target")
            #expect(f.document.snapshot.tabs.isEmpty)
            #expect(try f.store.loadSnapshotStrict()?.tabs.isEmpty == true)
            #expect(try f.queue().count == before.count + 1)
            #expect(try f.lastOperations() == [.deleteTab(id: "remote")])
            #expect(try f.store.loadArchivePage().entries.map(\.tab.id) == ["remote"])
        }
    }

    @Test func archiveSheetKeepsFailedRestoreVisibleAndNativeRetryConsumesItOnce() async throws {
        try await withMobileArchiveFixture { f in
            let engine = MobileArchiveEngine()
            let workspace = await f.workspace(engine: engine, scene: "ui-retry")
            workspace.closeTab(id: "a")
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            let host = try MobileArchivePresentation(workspace: workspace, contentView: engine.hostView)
            defer { host.close() }
            let archive = try await host.open()
            let archiveNavigation = try #require(archive.navigationController)
            let before = try f.queue()
            let oldIDs = Set(workspace.tabs.map(\.id))
            try f
                .sql(
                    "CREATE TRIGGER fail_restore BEFORE UPDATE OF restored_tab_id ON browser_tab_archive_receipts BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            archive.tableView(archive.tableView, didSelectRowAt: .init(row: 0, section: 0))
            let freshID = try #require(workspace.tabs.first { !oldIDs.contains($0.id) }?.id)
            #expect(workspace.sessionError != nil && f.document.hasUncommittedWrites)
            #expect(archiveNavigation.presentingViewController != nil)
            #expect(!archiveNavigation.isBeingDismissed && !archive.isBeingDismissed && archive.view.window === host
                .window)
            archive.view.layoutIfNeeded()
            let retry = try #require(mobileArchiveView("browser.archive.retry", in: archive.view) as? UIButton)
            #expect(!retry.isHidden && retry.isEnabled && retry.bounds.height >= 44)
            #expect(try f.store.loadArchiveEntry(id: entry.id) == entry && f.queue() == before)
            archive.tableView(archive.tableView, didSelectRowAt: .init(row: 0, section: 0))
            #expect(Set(workspace.tabs.map(\.id)).subtracting(oldIDs) == [freshID])

            try f.sql("DROP TRIGGER fail_restore")
            retry.sendActions(for: .touchUpInside)
            try #require(await mobileArchiveEventually {
                !f.document.hasUncommittedWrites && workspace.sessionError == nil &&
                    archive.tableView.numberOfRows(inSection: 0) == 0
            })
            #expect(try f.store.loadArchiveEntry(id: entry.id) == nil)
            #expect(try f.queue().count == before.count + 1)
            #expect(Set(workspace.tabs.map(\.id)).subtracting(oldIDs) == [freshID])
            #expect(workspace.selectedTabID == freshID)
            #expect(archiveNavigation.presentingViewController != nil && archive.view.window === host.window)
            let after = try f.queue()
            #expect(workspace.restoreArchivedTab(id: entry.id) == nil)
            #expect(try f.queue() == after)
            // Retry refreshes the list; the native Done action closes recovery UI.
            let done = try #require(archive.navigationItem.rightBarButtonItem)
            let action = try #require(done.action)
            #expect(UIApplication.shared.sendAction(action, to: done.target, from: done, for: nil))
            try #require(await mobileArchiveEventually { archiveNavigation.presentingViewController == nil })
        }
    }

    @Test func archiveMissingSpacePickerCallbackDismissesPickerThenArchiveNavigation() async throws {
        try await withMobileArchiveFixture { f in
            let engine = MobileArchiveEngine()
            let workspace = await f.workspace(engine: engine, scene: "ui-destination")
            workspace.closeTab(id: "a")
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            #expect(f.document.delete(entity: .init(entityType: .space, entityID: "source")))
            let host = try MobileArchivePresentation(workspace: workspace, contentView: engine.hostView)
            defer { host.close() }
            let archive = try await host.open()
            let archiveNavigation = try #require(archive.navigationController)
            let before = try f.queue()
            archive.tableView(archive.tableView, didSelectRowAt: .init(row: 0, section: 0))
            try #require(await mobileArchiveEventually {
                (archive.presentedViewController as? UIAlertController)?.view.window === host.window
            })
            let picker = try #require(archive.presentedViewController as? UIAlertController)
            try #require(await mobileArchiveEventually { !picker.isBeingPresented })
            #expect(picker.preferredStyle == .actionSheet)
            #expect(picker.actions.filter { $0.style == .default }.map(\.title) == ["Target"])
            #expect(picker.actions.contains { $0.style == .cancel })
            #expect(try f.queue() == before && f.store.loadArchiveEntry(id: entry.id) == entry)
            // UIKit exposes no public action-handler invocation. Exercise the
            // callback installed by the real UIAlertAction after proving its
            // sheet is presented; no private handler or KVC is used.
            archive.chooseDestination("target", for: entry, dismissing: picker)
            try #require(await mobileArchiveEventually {
                picker.presentingViewController == nil && archiveNavigation.presentingViewController == nil &&
                    workspace.selectedTab?.spaceID == "target" && workspace.selectedTab?.id != "remote"
            })
            let fresh = try #require(workspace.selectedTab)
            #expect(fresh.id != "a" && fresh.urlString == entry.tab.urlString)
            #expect(workspace.selectedSpaceID == "target")
            #expect(try f.store.loadArchiveEntry(id: entry.id) == nil)
            #expect(try f.queue().count == before.count + 1)
            #expect(mobileArchiveController(in: host.root) == nil)
        }
    }

    @Test func archiveMutationGuardIsSharedAndCompletionCannotEraseLaterUnsavedTabEdit() async throws {
        try await withMobileArchiveFixture { f in
            #expect(f.document.archiveTab(id: "a"))
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            let gate = MobileArchiveOperationGate(store: f.store)
            let document = try BrowserMobileProfileDocument(store: gate, initialSnapshot: f.store.loadSnapshotStrict())
            let first = await f.workspace(engine: MobileArchiveEngine(), scene: "guard-first", document: document)
            let second = await f.workspace(engine: MobileArchiveEngine(), scene: "guard-second", document: document)
            let revision = first.archiveRevision
            let removal = Task { await first.deleteArchivedTab(id: entry.id) }
            defer { gate.release() }
            try #require(await mobileArchiveEventually { gate.isWaiting })
            #expect(first.isArchiveOperationInFlight && second.isArchiveOperationInFlight)
            #expect(document.canEdit && !first.canManageArchive && !second.canRestoreArchivedTab)
            #expect(!document.archiveTab(id: "b"))
            #expect(second.restoreArchivedTab(id: entry.id) == nil)
            let refused = await second.deleteArchivedTab(id: entry.id)
            #expect(!refused)
            try f
                .sql(
                    "CREATE TRIGGER fail_during_archive BEFORE INSERT ON browser_tabs BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            #expect(document.renameTab(id: "b", title: "Unsaved while Archive awaits"))
            #expect(document.hasUncommittedWrites && first.sessionError != nil)
            gate.release()
            let succeeded = await removal.value
            #expect(succeeded)
            #expect(first.archiveRevision == revision + 1 && second.archiveRevision == revision + 1)
            #expect(!first.isArchiveOperationInFlight && !second.isArchiveOperationInFlight)
            #expect(document.hasUncommittedWrites && document.persistenceFailure?.isRetryable == true)
            #expect(try f.store.loadArchiveEntry(id: entry.id) == nil)
            #expect(document.snapshot.tabs.first { $0.id == "b" }?.userTitleOverride == "Unsaved while Archive awaits")
            #expect(try f.store.loadSnapshotStrict()?.tabs.first { $0.id == "b" }?.userTitleOverride == nil)
            try f.sql("DROP TRIGGER fail_during_archive")
            #expect(document.retryPersistence())
            #expect(first.canManageArchive && second.canManageArchive && !document.hasUncommittedWrites)
            #expect(try f.store.loadSnapshotStrict() == document.snapshot)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            #expect(try f.lastOperations() == [.patchTab(
                id: "b",
                fields: .init(userTitleOverride: .set("Unsaved while Archive awaits"))
            )])
        }
    }

    @Test func nativeArchiveSearchRejectsStaleRepliesAndDoneClosesActiveSearchSheet() async throws {
        try await withMobileArchiveFixture { f in
            let engine = MobileArchiveEngine()
            let workspace = await f.workspace(engine: engine, scene: "held-search")
            workspace.closeTab(id: "a")
            workspace.closeTab(id: "b")
            let entries = try f.store.loadArchivePage().entries
            let a = try #require(entries.first { $0.tab.id == "a" })
            let b = try #require(entries.first { $0.tab.id == "b" })
            let before = try f.queue()
            let loader = MobileArchiveHeldSearch()
            defer { loader.finishAll() }
            let host = try MobileArchivePresentation(workspace: workspace, contentView: engine.hostView)
            defer { host.close() }
            let archive = BrowserMobileArchiveViewController(
                workspace: workspace,
                searchLoader: { query, cursor, limit in
                    try await loader.load(query: query, cursor: cursor, limit: limit)
                }
            )
            try await host.present(archive)
            try #require(await mobileArchiveEventually { loader.requests.count == 1 })
            #expect(loader.requests[0].query.isEmpty && loader.requests[0].cursor == nil && loader.requests[0]
                .limit == 50)
            loader.resolve(0, entries: entries)
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 2 })
            let search = try #require(archive.navigationItem.searchController)
            #expect(search.searchBar.searchTextField.accessibilityIdentifier == "browser.archive.search")
            search.isActive = true
            search.searchBar.text = "older"
            archive.updateSearchResults(for: search)
            try #require(await mobileArchiveEventually { loader.requests.count == 2 })
            search.searchBar.text = "newer"
            archive.updateSearchResults(for: search)
            // Native debounce must clear the previous rows before permitting restore.
            #expect(archive.tableView.numberOfRows(inSection: 0) == 0)
            try #require(await mobileArchiveEventually { loader.requests.count == 3 })
            loader.resolve(2, entries: [b])
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 1 })
            archive.tableView.layoutIfNeeded()
            #expect(archive.tableView
                .cellForRow(at: .init(row: 0, section: 0))?
                .accessibilityIdentifier == "browser.archive.entry." + b.id)
            loader.resolve(1, entries: [a])
            try #require(await mobileArchiveEventually { loader.finished.contains(1) })
            await Task.yield()
            #expect(archive.tableView
                .cellForRow(at: .init(row: 0, section: 0))?
                .accessibilityIdentifier == "browser.archive.entry." + b.id)

            search.searchBar.text = "cancelled"
            archive.updateSearchResults(for: search)
            try #require(await mobileArchiveEventually { loader.requests.count == 4 })
            search.isActive = false
            try #require(await mobileArchiveEventually { loader.requests.count == 5 })
            #expect(loader.requests[4].query.isEmpty)
            loader.resolve(4, entries: entries)
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 2 })
            loader.resolve(3, entries: [])
            try #require(await mobileArchiveEventually { loader.finished.contains(3) })
            await Task.yield()
            #expect(archive.tableView.numberOfRows(inSection: 0) == 2)

            search.isActive = true
            search.searchBar.text = "after-close"
            archive.updateSearchResults(for: search)
            try #require(await mobileArchiveEventually { loader.requests.count == 6 })
            let navigation = try #require(archive.navigationController)
            try sendMobileArchiveBar(archive.navigationItem.rightBarButtonItem)
            try #require(await mobileArchiveEventually { navigation.presentingViewController == nil })
            loader.resolve(5, entries: [a])
            try #require(await mobileArchiveEventually { loader.finished.contains(5) })
            await Task.yield()
            #expect(mobileArchiveController(in: host.root) == nil)
            #expect(try f.queue() == before && f.store.loadArchivePage().entries == entries)
        }
    }

    @Test func nativeArchiveSearchSwipeDeleteFailureAndRetryUseStableEntryAndRefreshOtherScene() async throws {
        try await withMobileArchiveFixture { f in
            let engine = MobileArchiveEngine()
            let workspace = await f.workspace(engine: engine, scene: "search-delete")
            let second = await f.workspace(engine: MobileArchiveEngine(), scene: "search-other")
            #expect(f.document.renameTab(id: "a", title: "Café one"))
            #expect(f.document.renameTab(id: "b", title: "Résumé two"))
            workspace.closeTab(id: "a")
            workspace.closeTab(id: "b")
            let entries = try f.store.loadArchivePage().entries
            let entry = try #require(entries.first { $0.tab.id == "b" })
            let before = try f.queue()
            let revision = workspace.archiveRevision
            let host = try MobileArchivePresentation(workspace: workspace, contentView: engine.hostView)
            defer { host.close() }
            let archive = try await host.open()
            let search = try #require(archive.navigationItem.searchController)
            search.searchBar.text = "RESUME"
            archive.updateSearchResults(for: search)
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 1 })
            archive.tableView.layoutIfNeeded()
            let path = IndexPath(row: 0, section: 0)
            let cell = try #require(archive.tableView.cellForRow(at: path))
            #expect(cell.accessibilityIdentifier == "browser.archive.entry." + entry.id)
            let action = try #require(archive.tableView(
                archive.tableView,
                trailingSwipeActionsConfigurationForRowAt: path
            )?.actions
                .first)
            #expect(action.title == "Delete")
            try f
                .sql(
                    "CREATE TRIGGER fail_archive_delete BEFORE DELETE ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            var result: Bool?
            action.handler(action, cell) { result = $0 }
            try #require(await mobileArchiveEventually { result != nil })
            #expect(result == false && workspace.archiveRevision == revision && second.archiveRevision == revision)
            #expect(try f.store.loadArchiveEntry(id: entry.id) == entry && f.queue() == before)
            let retry = try #require(mobileArchiveView("browser.archive.retry", in: archive.view) as? UIButton)
            try #require(await mobileArchiveEventually { !retry.isHidden && retry.isEnabled })
            try f.sql("DROP TRIGGER fail_archive_delete")
            retry.sendActions(for: .touchUpInside)
            try #require(await mobileArchiveEventually { workspace.archiveRevision == revision + 1 })
            #expect(second.archiveRevision == revision + 1)
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 0 })
            #expect(try f.store.loadArchiveEntry(id: entry.id) == nil)
            #expect(try f.queue() == before)
            search.searchBar.text = "CAFE"
            archive.updateSearchResults(for: search)
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 1 })
            archive.tableView.layoutIfNeeded()
            let remaining = try #require(entries.first { $0.tab.id == "a" })
            #expect(archive.tableView
                .cellForRow(at: path)?
                .accessibilityIdentifier == "browser.archive.entry." + remaining.id)
            try sendMobileArchiveBar(archive.navigationItem.rightBarButtonItem)
        }
    }

    @Test func nativeArchiveClearUsesCapturedConfirmationAndRetryKeepsLaterArchive() async throws {
        try await withMobileArchiveFixture { f in
            let engine = MobileArchiveEngine()
            let workspace = await f.workspace(engine: engine, scene: "clear")
            let second = await f.workspace(engine: MobileArchiveEngine(), scene: "clear-other")
            workspace.closeTab(id: "a")
            workspace.closeTab(id: "b")
            let entries = try f.store.loadArchivePage().entries
            let host = try MobileArchivePresentation(workspace: workspace, contentView: engine.hostView)
            defer { host.close() }
            let archive = try await host.open()
            let clear = try #require(archive.toolbarItems?
                .first { $0.accessibilityIdentifier == "browser.archive.clear" })
            let search = try #require(archive.navigationItem.searchController)
            search.isActive = true
            search.searchBar.text = "no-archive-entry-matches-this"
            archive.updateSearchResults(for: search)
            try #require(await mobileArchiveEventually {
                search.isActive && !search.isBeingPresented && archive.tableView.numberOfRows(inSection: 0) == 0 &&
                    (archive.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text == "No Matching Tabs"
            })
            #expect(clear.isEnabled)
            try sendMobileArchiveBar(clear)
            try #require(await mobileArchiveEventually {
                archive.pendingClearBoundary != nil && archive.presentedViewController is UIAlertController
            })
            #expect(!search.isActive)
            let cancelledPicker = try #require(archive.presentedViewController as? UIAlertController)
            try #require(await mobileArchiveEventually { !cancelledPicker.isBeingPresented })
            #expect(cancelledPicker.actions.contains { $0.style == .cancel })
            archive.cancelClear(dismissing: cancelledPicker)
            try #require(await mobileArchiveEventually { archive.presentedViewController == nil })
            #expect(archive.pendingClearBoundary == nil)
            #expect(try f.store.loadArchivePage().entries == entries)

            try sendMobileArchiveBar(clear)
            try #require(await mobileArchiveEventually {
                archive.pendingClearBoundary != nil && archive.presentedViewController is UIAlertController
            })
            let boundary = try #require(archive.pendingClearBoundary)
            let picker = try #require(archive.presentedViewController as? UIAlertController)
            try #require(await mobileArchiveEventually { !picker.isBeingPresented })
            #expect(picker.actions.contains { $0.style == .destructive })
            #expect(picker.popoverPresentationController?.barButtonItem === clear)
            second.closeTab(id: "remote")
            let later = try #require(try f.store.loadArchivePage().entries.first { $0.tab.id == "remote" })
            let before = try f.queue()
            let revision = workspace.archiveRevision
            try f
                .sql(
                    "CREATE TRIGGER fail_clear BEFORE DELETE ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            archive.chooseClearBoundary(boundary, dismissing: picker)
            try #require(await mobileArchiveEventually {
                guard let retry = mobileArchiveView("browser.archive.retry", in: archive.view) as? UIButton
                else { return false }
                return !retry.isHidden && retry.isEnabled && workspace.archiveError != nil
            })
            let retry = try #require(mobileArchiveView("browser.archive.retry", in: archive.view) as? UIButton)
            #expect(workspace.archiveRevision == revision && second.archiveRevision == revision)
            #expect(try f.store.loadArchivePage().entries.count == 3 && f.queue() == before)
            try f.sql("DROP TRIGGER fail_clear")
            retry.sendActions(for: .touchUpInside)
            try #require(await mobileArchiveEventually { workspace.archiveRevision == revision + 1 })
            #expect(second.archiveRevision == revision + 1)
            try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 1 })
            #expect(try f.store.loadArchivePage().entries == [later] && f.queue() == before)
            let repeated = await second.clearArchive(through: boundary)
            #expect(repeated && workspace.archiveRevision == revision + 2)
            #expect(try f.store.loadArchivePage().entries == [later] && f.queue() == before)
            try sendMobileArchiveBar(archive.navigationItem.rightBarButtonItem)
        }
    }

    @Test(arguments: [false, true])
    func realWebKitCloseNativeArchiveRestoreAndSQLiteReopenLoadFreshTab(compact: Bool) async throws {
        let server = try MobileArchiveHTTPFixture()
        try await server.start()
        defer { server.stop() }
        try await withMobileArchiveFixture { f in
            let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
            let workspace = await f.workspace(engine: engine, scene: "web")
            let root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
            let window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
            window.rootViewController = root
            window.frame.size = compact ? CGSize(width: 320, height: 700) : CGSize(width: 1024, height: 768)
            root.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
            root.traitOverrides.verticalSizeClass = .regular
            window.makeKeyAndVisible()
            defer {
                engine.shutdown()
                window.isHidden = true
                window.rootViewController = nil
            }
            root.loadViewIfNeeded()
            root.view.frame = window.bounds
            root.view.layoutIfNeeded()
            workspace.selectTab(id: "a")
            let url = try server.url()
            root.pageController.addressField.text = url.absoluteString
            #expect(root.pageController.textFieldShouldReturn(root.pageController.addressField))
            try #require(await mobileArchiveEventually {
                workspace.selectedTab?.title == "Archive document" && workspace.selectedTab?.state.isLoading == false
            })
            let oldRuntime = try #require(workspace.selectedTab?.runtimeID)
            let oldView = try #require(engine.webView(for: oldRuntime))
            #expect(f.document.renameTab(id: "a", title: "Saved custom title"))
            root.render()
            root.view.layoutIfNeeded()
            try #require(await mobileArchiveEventually { root.isCollapsed == compact })
            let sidebar: BrowserMobileTabsViewController
            if compact {
                let tabsButton = try #require(mobileArchiveView(
                    "browser.showTabs",
                    in: root.pageController.view
                ) as? UIButton)
                tabsButton.sendActions(for: .touchUpInside)
                try #require(await mobileArchiveEventually {
                    (root.presentedViewController as? UINavigationController)?
                        .topViewController is BrowserMobileTabsViewController
                })
                let navigation = try #require(root.presentedViewController as? UINavigationController)
                try #require(await mobileArchiveEventually {
                    navigation.view.window === window && !navigation.isBeingPresented
                })
                navigation.sheetPresentationController?.selectedDetentIdentifier = .large
                sidebar = try #require(navigation.topViewController as? BrowserMobileTabsViewController)
            } else {
                sidebar = root.tabsController
            }
            let table = sidebar.tableView!
            table.layoutIfNeeded()
            table.scrollToRow(at: .init(row: 0, section: 2), at: .middle, animated: false)
            table.layoutIfNeeded()
            let path = try #require(table.indexPathsForVisibleRows?.first {
                table.cellForRow(at: $0)?.accessibilityIdentifier == "browser.tab.a"
            })
            let action = try #require(sidebar.tableView(table, trailingSwipeActionsConfigurationForRowAt: path)?
                .actions
                .first)
            let cell = try #require(table.cellForRow(at: path))
            var closed = false
            action.handler(action, cell) { closed = $0 }
            #expect(closed && !workspace.tabs.contains { $0.id == "a" })
            #expect(engine.webView(for: oldRuntime) == nil && oldView.navigationDelegate == nil)
            let entry = try #require(try f.store.loadArchivePage().entries.first)
            #expect(entry.tab.urlString == url.absoluteString && entry.tab.userTitleOverride == "Saved custom title")

            let bars = (sidebar.navigationItem.leftBarButtonItems ?? []) +
                (sidebar.navigationItem.rightBarButtonItems ?? [])
            let archiveButton = try #require(bars.first { $0.accessibilityIdentifier == "browser.archive" })
            let archiveAction = try #require(archiveButton.action)
            #expect(UIApplication.shared.sendAction(
                archiveAction,
                to: archiveButton.target,
                from: archiveButton,
                for: nil
            ))
            // Keep the Archive controller in a separate frame, so the test does
            // not retain it through dismissal of the compact outer tabs sheet.
            try await selectMobileArchiveEntry(in: root, window: window, entryID: entry.id)
            try #require(await mobileArchiveEventually {
                workspace.selectedTab?.id != "a" && workspace.selectedTab?.urlString == url.absoluteString &&
                    workspace.selectedTab?.title == "Archive document" && workspace.selectedTab?.state
                    .isLoading == false
            })
            let fresh = try #require(workspace.selectedTab)
            try #require(await mobileArchiveEventually { root.presentedViewController == nil })
            #expect(root.pageController.view.window === window && engine.hostView.window === window)
            #expect(fresh.id != "a" && fresh.runtimeID != oldRuntime)
            #expect(fresh.userTitleOverride == "Saved custom title")
            #expect(engine.webView(for: fresh.runtimeID) !== oldView)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            #expect(await workspace.shutdown())
            let reopenedStore = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            let reopenedDocument = try BrowserMobileProfileDocument(
                store: reopenedStore,
                loadSnapshot: { try reopenedStore.loadSnapshotStrict() }
            )
            let reopenedEngine = BrowserWebKitEngine(dataStore: .nonPersistent())
            defer { reopenedEngine.shutdown() }
            let reopened = BrowserMobileWorkspace(
                engine: reopenedEngine, sceneID: "reopened", profileLoader: { reopenedDocument },
                preferences: f.preferences
            )
            await reopened.restore()
            reopened.selectTab(id: fresh.id)
            try #require(await mobileArchiveEventually {
                reopened.selectedTab?.title == "Archive document" && reopened.selectedTab?.state.isLoading == false
            })
            #expect(reopened.selectedTabID == fresh.id && reopened.selectedTab?
                .userTitleOverride == "Saved custom title")
            #expect(reopened.selectedTab?.runtimeID != fresh.runtimeID)
            #expect(try reopenedStore.loadArchivePage().entries.isEmpty)
            #expect(try reopenedStore.pendingSyncQueue(for: f.owner) == f.queue())
            #expect(await reopened.shutdown())
        }
    }
}

@MainActor private func selectMobileArchiveEntry(
    in root: BrowserMobileViewController, window: UIWindow, entryID: String
) async throws {
    try #require(await mobileArchiveEventually { mobileArchiveController(in: root) != nil })
    let archive = try #require(mobileArchiveController(in: root))
    try #require(await mobileArchiveEventually { archive.view.window === window && !archive.isBeingPresented })
    try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) == 1 })
    let search = try #require(archive.navigationItem.searchController)
    search.isActive = true
    search.searchBar.text = "SAVED CUSTOM"
    archive.updateSearchResults(for: search)
    try #require(await mobileArchiveEventually {
        search.isActive && !search.isBeingPresented && archive.tableView.numberOfRows(inSection: 0) == 1
    })
    archive.view.layoutIfNeeded()
    #expect(archive.tableView.accessibilityIdentifier == "browser.archive.list")
    try #require(archive.tableView.numberOfRows(inSection: 0) == 1)
    let path = IndexPath(row: 0, section: 0)
    let cell = try #require(archive.tableView.cellForRow(at: path))
    #expect(cell.accessibilityIdentifier == "browser.archive.entry." + entryID)
    #expect((cell.contentConfiguration as? UIListContentConfiguration)?.text == "Saved custom title")
    archive.tableView(archive.tableView, didSelectRowAt: path)
}

// MARK: - MobileArchivePresentation

@MainActor private final class MobileArchivePresentation {
    // MARK: Lifecycle

    init(workspace: BrowserMobileWorkspace, contentView: UIView) throws {
        self.root = BrowserMobileViewController(workspace: workspace, contentView: contentView)
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
        window.rootViewController = root
        window.frame.size = CGSize(width: 1024, height: 768)
        root.traitOverrides.horizontalSizeClass = .regular
        root.traitOverrides.verticalSizeClass = .regular
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
    }

    // MARK: Internal

    let root: BrowserMobileViewController
    let window: UIWindow

    func open() async throws -> BrowserMobileArchiveViewController {
        let sidebar = root.tabsController
        let bars = (sidebar.navigationItem.leftBarButtonItems ?? []) +
            (sidebar.navigationItem.rightBarButtonItems ?? [])
        let button = try #require(bars.first { $0.accessibilityIdentifier == "browser.archive" })
        let action = try #require(button.action)
        #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
        try #require(await mobileArchiveEventually { mobileArchiveController(in: root) != nil })
        let archive = try #require(mobileArchiveController(in: root))
        try #require(await mobileArchiveEventually { archive.view.window === self.window && !archive.isBeingPresented })
        try #require(await mobileArchiveEventually { archive.tableView.numberOfRows(inSection: 0) > 0 })
        archive.view.layoutIfNeeded()
        return archive
    }

    func present(_ archive: BrowserMobileArchiveViewController) async throws {
        let navigation = UINavigationController(rootViewController: archive)
        navigation.modalPresentationStyle = .formSheet
        root.tabsController.present(navigation, animated: true)
        try #require(await mobileArchiveEventually {
            archive.view.window === self.window && !navigation.isBeingPresented
        })
        archive.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

// MARK: - MobileArchiveFixture

@MainActor private final class MobileArchiveFixture {
    // MARK: Lifecycle

    init(directory: URL) throws {
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        try store.bindSyncOwner(owner)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "source", title: "Source", systemImageName: "globe"),
                .init(id: "target", title: "Target", systemImageName: "star"),
            ],
            pinnedTabFolders: [.init(id: "folder", spaceID: "source", title: "Folder", pinnedSiblingRank: 0)],
            tabs: [
                .init(id: "a", urlString: "about:blank", spaceID: "source", lastActivityTimestamp: 1_800_000_000),
                .init(id: "b", urlString: "about:blank", spaceID: "source"),
                .init(
                    id: "pin",
                    urlString: "about:blank",
                    pinnedURLString: "about:blank",
                    placement: .spacePinned,
                    spaceID: "source",
                    pinnedFolderID: "folder",
                    pinnedSiblingRank: 0
                ),
                .init(id: "favorite", urlString: "about:blank", placement: .app, spaceID: "source"),
                .init(id: "remote", urlString: "about:blank", spaceID: "target"),
            ]
        )
        let events = try mobileArchiveEvents(BrowserSyncFolderProjection.canonicalChanges(snapshot))
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        var nextID = 0
        self.document = try BrowserMobileProfileDocument(
            store: store, initialSnapshot: store.loadSnapshotStrict(), idProvider: {
                nextID += 1
                return "generated-\(nextID)"
            }, dateProvider: { Date(timeIntervalSince1970: 1_800_000_100) }
        )
    }

    // MARK: Internal

    let databaseURL: URL
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://archive.example")!, userID: "mobile-archive")
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let preferencesName = "MobileArchive." + UUID().uuidString
    let preferences: UserDefaults
    var workspaces = [BrowserMobileWorkspace]()

    func workspace(
        engine: any BrowserMobileEngine, scene: String, document suppliedDocument: BrowserMobileProfileDocument? = nil
    ) async -> BrowserMobileWorkspace {
        let document = suppliedDocument ?? document
        let workspace = BrowserMobileWorkspace(
            engine: engine,
            sceneID: scene,
            profileLoader: { document },
            preferences: preferences
        )
        workspaces.append(workspace)
        await workspace.restore()
        #expect(workspace.isReady && workspace.supportsArchive)
        return workspace
    }

    func queue() throws -> [BrowserSyncQueuedMutation] { try store.pendingSyncQueue(for: owner) }
    func operations() throws -> [BrowserSyncFolderOperation] {
        try queue().flatMap {
            guard case .folders(let mutation) = $0 else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return mutation.operations
        }
    }

    func lastOperations() throws -> [BrowserSyncFolderOperation] {
        guard case .folders(let mutation) = try #require(try queue().last)
        else { throw BrowserSyncQueueError.protocolVersionMismatch }
        return mutation.operations
    }

    func sql(_ sql: String) throws { try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) } }
    func stop() async {
        for workspace in workspaces {
            _ = await workspace.shutdown()
        }
        workspaces.removeAll()
        preferences.removePersistentDomain(forName: preferencesName)
    }
}

// MARK: - MobileArchiveEngine

@MainActor private final class MobileArchiveEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var closed = [String]()

    func createTab(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func selectTab(id _: String?) {}
    func navigate(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func closeTab(id: String) { closed.append(id)
        onEvent?(.closed(id: id))
    }

    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() {}
}

private func mobileArchiveEvents(_ changes: [BrowserSyncChange], startingAt: Int = 1) throws -> [BrowserSyncEvent] {
    try changes.enumerated().map { offset, change in
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
        var payload = object["data"] as? [String: Any] ?? [:]
        payload["id"] = change.entityID
        let wire: [String: Any] = [
            "serverSeq": startingAt + offset, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
            "entityID": change.entityID, "op": change.op.rawValue, "data": payload, "createdAt": "2026-10-03T00:00:00Z",
        ]
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
    }
}

@MainActor private func withMobileArchiveFixture(_ body: (MobileArchiveFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileArchive-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runMobileArchiveFixture(directory: directory, body)
}

@MainActor private func runMobileArchiveFixture(
    directory: URL,
    _ body: (MobileArchiveFixture) async throws -> Void
) async throws {
    let fixture = try MobileArchiveFixture(directory: directory)
    do { try await body(fixture) } catch { await fixture.stop()
        throw error
    }
    await fixture.stop()
}

@MainActor private func mobileArchiveEventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor private func mobileArchiveController(in controller: UIViewController)
-> BrowserMobileArchiveViewController? {
    if let archive = controller as? BrowserMobileArchiveViewController {
        return archive
    }
    if let presented = controller.presentedViewController,
       let archive = mobileArchiveController(in: presented)
    {
        return archive
    }
    return controller.children.lazy.compactMap { mobileArchiveController(in: $0) }.first
}

@MainActor private func mobileArchiveView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { mobileArchiveView(id, in: $0) }.first
}

// MARK: - MobileArchiveHeldSearch

@MainActor private final class MobileArchiveHeldSearch {
    // MARK: Internal

    struct Request { let query: String
        let cursor: BrowserTabArchiveCursor?
        let limit: Int
    }

    var requests = [Request]()
    var finished = Set<Int>()

    func load(query: String, cursor: BrowserTabArchiveCursor?, limit: Int) async throws -> BrowserTabArchivePage {
        let id = requests.count
        requests.append(.init(query: query, cursor: cursor, limit: limit))
        defer { finished.insert(id) }
        // Deliberately ignore cancellation, like a response already in flight.
        return try await withCheckedThrowingContinuation { replies[id] = $0 }
    }

    func resolve(_ id: Int, entries: [BrowserTabArchiveEntry]) {
        replies.removeValue(forKey: id)?.resume(returning: .init(entries: entries, nextCursor: nil))
    }

    func finishAll() {
        for reply in replies.values {
            reply.resume(throwing: CancellationError())
        }
        replies.removeAll()
    }

    // MARK: Private

    private var replies = [Int: CheckedContinuation<BrowserTabArchivePage, any Error>]()
}

// MARK: - MobileArchiveOperationGate

private final class MobileArchiveOperationGate: BrowserTabSessionSnapshotStoring, BrowserTabArchiveStoring {
    // MARK: Lifecycle

    init(store: BrowserSQLiteSessionStore) { self.store = store }

    // MARK: Internal

    let store: BrowserSQLiteSessionStore

    var isWaiting: Bool { continuation != nil }

    func release() { let saved = continuation
        continuation = nil
        saved?.resume()
    }

    func loadSnapshot() -> BrowserTabSessionSnapshot? { store.loadSnapshot() }
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) { store.saveSnapshot(snapshot) }
    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws { try store.writeSessionBatch(writes) }
    func loadArchiveEntry(id: String) throws -> BrowserTabArchiveEntry? { try store.loadArchiveEntry(id: id) }
    func loadArchivePage(before: BrowserTabArchiveCursor?, limit: Int) throws -> BrowserTabArchivePage {
        try store.loadArchivePage(before: before, limit: limit)
    }

    nonisolated(nonsending) func searchArchivePage(
        query: String,
        before: BrowserTabArchiveCursor?,
        limit: Int
    ) async throws -> BrowserTabArchivePage {
        try await store.searchArchivePage(query: query, before: before, limit: limit)
    }

    nonisolated(nonsending) func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        try await store.archiveClearBoundary()
    }

    nonisolated(nonsending) func removeArchiveEntry(id: String) async throws -> Bool {
        await withCheckedContinuation { continuation = $0 }
        return try await store.removeArchiveEntry(id: id)
    }

    nonisolated(nonsending) func clearArchive(through boundary: BrowserTabArchiveBoundary) async throws -> Int {
        try await store.clearArchive(through: boundary)
    }

    // MARK: Private

    private var continuation: CheckedContinuation<Void, Never>?
}

@MainActor private func sendMobileArchiveBar(_ item: UIBarButtonItem?) throws {
    let item = try #require(item)
    let action = try #require(item.action)
    #expect(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
}

// MARK: - MobileArchiveHTTPFixture

/// Disposable HTTP content ensures restore really loads the archived URL,
/// instead of injecting HTML into a new view after the fact.
@MainActor private final class MobileArchiveHTTPFixture {
    // MARK: Lifecycle

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    // MARK: Internal

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready: timeout?.cancel()
                        startContinuation?.resume()
                        startContinuation = nil
                    case .failed(let error), .waiting(let error):
                        timeout?.cancel()
                        startContinuation?.resume(throwing: error)
                        startContinuation = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                    let body = "<html><head><title>Archive document</title></head><body>Loaded archived URL</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
            }
            listener.start(queue: .main)
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                startContinuation?.resume(throwing: URLError(.timedOut))
                startContinuation = nil
                listener.cancel()
            }
        }
    }

    func url() throws -> URL {
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/archived"))
    }

    func stop() {
        timeout?.cancel()
        startContinuation?.resume(throwing: URLError(.cancelled))
        startContinuation = nil
        listener.cancel()
    }

    // MARK: Private

    private let listener: NWListener
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
}
