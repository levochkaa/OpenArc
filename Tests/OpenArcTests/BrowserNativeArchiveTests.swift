import AppKit
import GRDB
import Testing

// MARK: - BrowserNativeArchiveTests

@Suite(.serialized) @MainActor struct BrowserNativeArchiveTests {
    @Test func archiveSearchIgnoresCanceledRepliesAndKeepsSelectionByStableID() async throws {
        try await withNativeArchive { f in
            let gate = NativeArchiveLoadGate()
            let controller = BrowserArchiveViewController(model: f.model, pageLoader: gate.load)
            defer {
                controller.invalidate()
                gate.completeAll(page: .init(entries: [], nextCursor: nil))
            }
            _ = controller.view
            try await nativeArchiveWait { gate.queries == [""] }
            gate.complete("", page: .init(entries: [f.entries[0], f.entries[1]], nextCursor: nil))
            try await nativeArchiveWait { !controller.isLoading }
            controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            #expect(controller.selectedArchiveID == f.entries[1].id)
            f.model.syncArchiveDidChange()
            try await nativeArchiveWait { gate.queries == ["", ""] }
            gate.complete("", page: .init(entries: [f.entries[1], f.entries[0]], nextCursor: nil))
            try await nativeArchiveWait { !controller.isLoading }
            #expect(controller.table.selectedRow == 0 && controller.selectedArchiveID == f.entries[1].id)

            controller.searchField.stringValue = "old"
            controller.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
            try await nativeArchiveWait { gate.queries.last == "old" }
            controller.searchField.stringValue = "new"
            controller.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
            try await nativeArchiveWait { gate.queries.last == "new" }
            gate.complete("new", page: .init(entries: [f.entries[1]], nextCursor: nil))
            try await nativeArchiveWait { !controller.isLoading }
            gate.complete("old", page: .init(entries: [f.entries[0]], nextCursor: nil))
            await Task.yield()
            #expect(controller.entries == [f.entries[1]])
            #expect(controller.selectedArchiveID == nil)
            #expect(try f.store.loadArchivePage().entries.count == 3)
            controller.searchField.stringValue = "closed"
            controller.controlTextDidChange(.init(name: NSControl.textDidChangeNotification))
            try await nativeArchiveWait { gate.queries.last == "closed" }
            controller.invalidate()
            gate.complete("closed", page: .init(entries: [], nextCursor: nil))
            await Task.yield()
            #expect(controller.entries == [f.entries[1]])
        }
    }

    @Test func archiveRestoreButtonRetriesDurableFailureWithoutConsumingOrAllocatingEngine() async throws {
        try await withNativeArchive { f in
            let controller = BrowserArchiveViewController(model: f.model)
            defer { controller.invalidate() }
            _ = controller.view
            try await nativeArchiveWait { !controller.isLoading }
            let entry = try #require(controller.entries.first { $0.tab.spaceID == "work" })
            let row = try #require(controller.entries.firstIndex { $0.id == entry.id })
            controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let before = try f.store.loadSnapshotStrict()
            let created = f.driver.createdTabRequests.count
            try f
                .sql(
                    "CREATE TRIGGER fail_restore BEFORE UPDATE OF restored_tab_id ON browser_tab_archive_receipts BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            controller.restoreButton.performClick(nil)
            try await nativeArchiveWait { !controller.retryButton.isHidden }
            #expect(try f.store.loadSnapshotStrict() == before)
            #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
            #expect(f.driver.createdTabRequests.count == created)
            #expect(controller.selectedArchiveID == entry.id)
            try f.sql("DROP TRIGGER fail_restore")
            controller.retryButton.performClick(nil)
            try await nativeArchiveWait {
                (try? f.store.loadArchiveEntry(id: entry.id)) == nil && f.driver.createdTabRequests.count > created
            }
            #expect(f.driver.createdTabRequests.count == created + 1)
            let restored = try #require(f.model.tabs.last)
            #expect(restored.syncID != entry.tab.id)
            #expect(restored.urlString == entry.tab.urlString)
            #expect(restored.userTitleOverride == entry.tab.userTitleOverride)
            #expect(f.model.selectedTabID == restored.id)
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            #expect(try reopened.loadArchiveEntry(id: entry.id) == nil)
            #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == restored.syncID } == true)
        }
    }

    @Test func missingSpaceRequiresExplicitNativePickerAndClearUsesCapturedBoundaryEvenAfterRetry() async throws {
        try await withNativeArchive { f in
            let alerts = NativeArchiveAlerts()
            let controller = BrowserArchiveViewController(model: f.model, alertPresenter: alerts.present)
            defer { controller.invalidate() }
            _ = controller.view
            try await nativeArchiveWait { !controller.isLoading }
            let missing = try #require(controller.entries.first { $0.tab.spaceID == "deleted" })
            let row = try #require(controller.entries.firstIndex { $0.id == missing.id })
            controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            controller.restoreButton.performClick(nil)
            let picker = try #require(alerts.alert?.accessoryView as? NSPopUpButton)
            #expect(picker.numberOfItems == 1 && picker.selectedItem?.representedObject as? String == "work")
            #expect(try f.store.loadArchiveEntry(id: missing.id) == missing)
            alerts.respond(.alertSecondButtonReturn)
            #expect(try f.store.loadArchiveEntry(id: missing.id) == missing)
            controller.restoreButton.performClick(nil)
            alerts.respond(.alertFirstButtonReturn)
            try await nativeArchiveWait { (try? f.store.loadArchiveEntry(id: missing.id)) == nil }
            f.driver.flushPendingCreateEvents()
            try await nativeArchiveWait { !controller.isLoading && controller.clearButton.isEnabled }
            #expect(f.model.tabs.last?.spaceID == "work")

            controller.clearButton.performClick(nil)
            try await nativeArchiveWait { controller.pendingClearBoundary != nil }
            let originalBoundary = try #require(controller.pendingClearBoundary)
            #expect(alerts.alert?.alertStyle == .warning)
            alerts.respond(.alertSecondButtonReturn)
            #expect(controller.pendingClearBoundary == nil)
            #expect(try f.store.loadArchivePage().entries.count == 2)
            controller.clearButton.performClick(nil)
            try await nativeArchiveWait { controller.pendingClearBoundary != nil }
            #expect(controller.pendingClearBoundary == originalBoundary)
            let later = try f.appendArchive(id: "later", date: -100)
            try f
                .sql(
                    "CREATE TRIGGER fail_clear BEFORE DELETE ON browser_tab_archive BEGIN SELECT RAISE(ABORT, 'injected'); END"
                )
            alerts.respond(.alertFirstButtonReturn)
            try await nativeArchiveWait { !controller.retryButton.isHidden }
            #expect(try f.store.loadArchivePage().entries.count == 3)
            try f.sql("DROP TRIGGER fail_clear")
            controller.retryButton.performClick(nil)
            try await nativeArchiveWait { (try? f.store.loadArchivePage().entries) == [later] }
            #expect(try f.store.loadArchivePage().entries == [later])
            #expect(controller.pendingClearBoundary == nil)
        }
    }

    @Test func closingArchiveBeforeQueuedRestoreRunsCannotConsumeEntry() async throws {
        try await withNativeArchive { f in
            let controller = BrowserArchiveViewController(model: f.model)
            _ = controller.view
            try await nativeArchiveWait { !controller.isLoading }
            let row = try #require(controller.entries.firstIndex { $0.tab.spaceID == "work" })
            let entry = controller.entries[row]
            controller.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let before = try f.store.loadSnapshotStrict()
            let engines = f.driver.createdTabRequests
            controller.restoreButton.performClick(nil)
            controller.invalidate() // Same MainActor turn, before the queued action begins.
            await Task.yield()
            #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
            #expect(try f.store.loadSnapshotStrict() == before)
            #expect(f.driver.createdTabRequests == engines)
        }
    }

    @Test func archiveContentCanBeRemovedBeforeBrowserEngineContextIsReady() async throws {
        try await withNativeArchive(ready: false) { f in
            #expect(f.model.canBrowseArchive && !f.model.canRestoreArchivedTab)
            let alerts = NativeArchiveAlerts()
            let controller = BrowserArchiveViewController(model: f.model, alertPresenter: alerts.present)
            defer { controller.invalidate() }
            _ = controller.view
            try await nativeArchiveWait { !controller.isLoading }
            controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let id = try #require(controller.selectedArchiveID)
            #expect(!controller.restoreButton.isEnabled)
            #expect(controller.removeButton.isEnabled && controller.clearButton.isEnabled)
            controller.removeButton.performClick(nil)
            try await nativeArchiveWait { (try? f.store.loadArchiveEntry(id: id)) == nil && !controller.isLoading }
            controller.clearButton.performClick(nil)
            try await nativeArchiveWait { controller.pendingClearBoundary != nil }
            alerts.respond(.alertFirstButtonReturn)
            try await nativeArchiveWait { (try? f.store.loadArchivePage().entries.isEmpty) == true }
            #expect(f.driver.createdTabRequests.isEmpty)
        }
    }

    @Test func archivePaginationDeleteKeyboardAndCompactWindowKeepNativeActionsReachable() async throws {
        try await withNativeArchive { f in
            let gate = NativeArchiveLoadGate()
            let controller = BrowserArchiveViewController(model: f.model, pageLoader: gate.load)
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: 680, height: 340),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            defer { controller.invalidate()
                gate.completeAll(page: .init(entries: [], nextCursor: nil))
                window.contentViewController = nil
            }
            _ = controller.view
            try await nativeArchiveWait { gate.queries.count == 1 }
            let cursor = BrowserTabArchiveCursor(archivedAt: f.entries[0].archivedAt, id: f.entries[0].id)
            gate.complete("", page: .init(entries: [f.entries[0]], nextCursor: cursor))
            try await nativeArchiveWait { !controller.isLoading }
            #expect(controller.olderButton.isEnabled && !controller.newerButton.isEnabled)
            controller.olderButton.performClick(nil)
            try await nativeArchiveWait { gate.cursors.count == 2 }
            #expect(gate.cursors.last! == cursor)
            gate.complete("", page: .init(entries: [f.entries[1]], nextCursor: nil))
            try await nativeArchiveWait { !controller.isLoading }
            #expect(controller.newerButton.isEnabled && !controller.olderButton.isEnabled)
            controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}",
                isARepeat: false,
                keyCode: 51
            ))
            controller.table.keyDown(with: key)
            try await nativeArchiveWait { (try? f.store.loadArchiveEntry(id: f.entries[1].id)) == nil }
            // Release the post-delete refresh before closing its suspended read.
            try await nativeArchiveWait { gate.queries.count >= 3 }
            gate.completeAll(page: .init(entries: [], nextCursor: nil))
            try await nativeArchiveWait { !controller.isLoading }
            controller.view.layoutSubtreeIfNeeded()
            for button in [
                controller.restoreButton,
                controller.removeButton,
                controller.clearButton,
                controller.newerButton,
                controller.olderButton,
            ] {
                #expect(controller.view.bounds.contains(button.convert(button.bounds, to: controller.view)))
                #expect(button.frame.height > 0)
            }
            let commandF = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "f",
                charactersIgnoringModifiers: "f",
                isARepeat: false,
                keyCode: 3
            ))
            #expect(controller.performKeyEquivalent(with: commandF))
            #expect(controller.searchField.currentEditor() === window.firstResponder)
            #expect(controller.table.accessibilityIdentifier() == "browser.archive.list")
        }
    }
}

// MARK: - NativeArchiveLoadGate

@MainActor private final class NativeArchiveLoadGate {
    // MARK: Internal

    private(set) var queries = [String]()
    private(set) var cursors = [BrowserTabArchiveCursor?]()

    func load(_ query: String, _ cursor: BrowserTabArchiveCursor?, _: Int) async throws -> BrowserTabArchivePage {
        queries.append(query)
        cursors.append(cursor)
        return try await withCheckedThrowingContinuation { held.append((query, $0)) }
    }

    func complete(_ query: String, page: BrowserTabArchivePage) {
        guard let index = held.firstIndex(where: { $0.0 == query }) else { return }
        held.remove(at: index).1.resume(returning: page)
    }

    func completeAll(page: BrowserTabArchivePage) {
        let pending = held
        held.removeAll()
        pending.forEach { $0.1.resume(returning: page) }
    }

    // MARK: Private

    private var held = [(String, CheckedContinuation<BrowserTabArchivePage, any Error>)]()
}

// MARK: - NativeArchiveAlerts

@MainActor private final class NativeArchiveAlerts {
    // MARK: Internal

    private(set) var alert: NSAlert?

    func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    func respond(_ response: NSApplication.ModalResponse) {
        let callback = completion
        alert = nil
        completion = nil
        callback?(response)
    }

    // MARK: Private

    private var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?
}

@MainActor private func nativeArchiveWait(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Native Archive did not reach the expected state")
    throw NativeArchiveTestError.timeout
}

// MARK: - NativeArchiveTestError

private enum NativeArchiveTestError: Error { case timeout }

@MainActor private func withNativeArchive(
    ready: Bool = true,
    _ body: @MainActor (NativeArchiveFixture) async throws -> Void
) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runNativeArchive(directory: directory, ready: ready, body: body)
}

@MainActor private func runNativeArchive(
    directory: URL,
    ready: Bool,
    body: @MainActor (NativeArchiveFixture) async throws -> Void
) async throws {
    let fixture = try NativeArchiveFixture(directory: directory, ready: ready)
    defer { fixture.model.discardUnsavedSessionForClosure()
        fixture.model.prepareForTermination()
        fixture.preferences.removePersistentDomain(forName: fixture.suite)
    }
    try await body(fixture)
}

// MARK: - NativeArchiveFixture

@MainActor private final class NativeArchiveFixture {
    // MARK: Lifecycle

    init(directory: URL, ready: Bool) throws {
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.preferences = try #require(UserDefaults(suiteName: suite))
        let space = BrowserSpaceSessionSnapshot(id: "work", title: "Work", systemImageName: "globe")
        var snapshot = BrowserTabSessionSnapshot(spaces: [space], tabs: [
            .init(id: "active", urlString: "https://active.example", spaceID: "work", lastActivityTimestamp: 100),
        ] + (0..<3).map { index in
            .init(
                id: "old-\(index)",
                urlString: "https://example.com/\(index)",
                userTitleOverride: "Name \(index)",
                spaceID: index == 2
                    ? "deleted"
                    : "work",
                lastActivityTimestamp: 50
            )
        })
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        var archived = [BrowserTabArchiveEntry]()
        for index in 0..<3 {
            let tab = try #require(snapshot.tabs.first { $0.id == "old-\(index)" })
            let entry = BrowserTabArchiveEntry(
                id: "archive-\(index)",
                tab: tab,
                archivedAt: Double(index + 1),
                title: "Page \(index)"
            )
            snapshot = .init(spaces: snapshot.spaces, tabs: snapshot.tabs.filter { $0.id != tab.id })
            try store.writeSessionBatch([.init(
                snapshot: snapshot,
                origin: .local(syncMove: nil),
                archiveAction: .insert(entry)
            )])
            archived.append(entry)
        }
        self.entries = archived
        self.model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: store,
            sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: preferences),
            shortcutStore: BrowserShortcutStore(userDefaults: preferences),
            extensionManager: FakeBrowserExtensionManager(),
            dateProvider: { Date(timeIntervalSince1970: 100) },
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {}
        )
        if ready {
            model.handleContextReady()
            driver.flushPendingCreateEvents()
        }
    }

    // MARK: Internal

    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()
    let suite = "NativeArchive." + UUID().uuidString
    let preferences: UserDefaults
    let entries: [BrowserTabArchiveEntry]

    func sql(_ sql: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) }
    }

    func appendArchive(id: String, date: TimeInterval) throws -> BrowserTabArchiveEntry {
        let old = try #require(try store.loadSnapshotStrict())
        let tab = BrowserTabSessionSnapshotTab(
            id: id,
            urlString: "https://later.example",
            spaceID: "work",
            lastActivityTimestamp: 100
        )
        try store.writeSessionBatch([.init(
            snapshot: .init(spaces: old.spaces, tabs: old.tabs + [tab]),
            origin: .local(syncMove: nil)
        )])
        let entry = BrowserTabArchiveEntry(id: "archive-" + id, tab: tab, archivedAt: date)
        try store.writeSessionBatch([.init(
            snapshot: old,
            origin: .local(syncMove: nil),
            archiveAction: .insert(entry)
        )])
        return entry
    }
}
