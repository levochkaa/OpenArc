import AppKit
import GRDB
import Testing

// MARK: - BrowserArchiveCommandTests

@Suite(.serialized) @MainActor struct BrowserArchiveCommandTests {
    @Test(arguments: [false, true])
    func viewArchiveFromEitherCommandBarKeepsItsOriginatingProfile(currentPage: Bool) async throws {
        let route = ArchiveCommandRoute()
        let first = try ArchiveCommandProfile(name: "First", route: route)
        defer { first.close() }
        let second = try ArchiveCommandProfile(name: "Second", route: route)
        defer { second.close() }
        defer { route.close() }
        // Registry order must not replace the model that produced the command.
        route.registeredOwners = [second.model, first.model]
        let firstState = try first.evidence()
        let secondState = try second.evidence()
        let firstRuntime = first.runtimeEvidence()
        let secondRuntime = second.runtimeEvidence()

        try await first.submit(.viewArchive, currentPage: currentPage)
        let controller = try #require(route.controller(for: first.model))
        try await archiveCommandWait { !controller.isLoading }
        #expect(controller.model === first.model)
        #expect(route.controller(for: second.model) == nil)
        #expect(route.origins == [ObjectIdentifier(first.model)])
        #expect(route.dismissedBeforeRouting == [true] && route.results == [true])
        #expect(controller.entries.map(\.id) == first.entries.reversed().map(\.id))

        try await first.submit(.viewArchive, currentPage: currentPage)
        #expect(route.controller(for: first.model) === controller)
        #expect(route.createdControllerCount == 1)
        #expect(route.results == [true, true])
        #expect(try first.evidence() == firstState)
        #expect(try second.evidence() == secondState)
        #expect(first.runtimeEvidence() == firstRuntime)
        #expect(second.runtimeEvidence() == secondRuntime)
    }

    @Test func clearCommandReusesTheCapturedConfirmationAndRetriesOnlyThatBoundary() async throws {
        let route = ArchiveCommandRoute()
        let first = try ArchiveCommandProfile(name: "First", route: route)
        defer { first.close() }
        let second = try ArchiveCommandProfile(name: "Second", route: route)
        defer { second.close() }
        defer { route.close() }
        route.registeredOwners = [second.model, first.model]
        let firstState = try first.evidence()
        let secondState = try second.evidence()
        let firstRuntime = first.runtimeEvidence()
        let secondRuntime = second.runtimeEvidence()

        try await first.submit(.clearArchive)
        let controller = try #require(route.controller(for: first.model))
        let alerts = try #require(route.alerts(for: first.model))
        try await archiveCommandWait { controller.pendingClearBoundary != nil }
        let cancelledBoundary = try #require(controller.pendingClearBoundary)
        #expect(alerts.alert?.alertStyle == .warning && alerts.presentationCount == 1)
        try await first.submit(.clearArchive, currentPage: true)
        #expect(controller.pendingClearBoundary == cancelledBoundary)
        #expect(alerts.presentationCount == 1 && route.createdControllerCount == 1)
        alerts.respond(.alertSecondButtonReturn)
        #expect(controller.pendingClearBoundary == nil)
        #expect(try first.evidence() == firstState)
        #expect(try second.evidence() == secondState)

        try await first.submit(.clearArchive)
        try await archiveCommandWait { controller.pendingClearBoundary != nil }
        let boundary = try #require(controller.pendingClearBoundary)
        #expect(boundary == cancelledBoundary)
        let later = try first.appendArchive(id: "later", date: -100)
        try await first.submit(.clearArchive, currentPage: true)
        #expect(controller.pendingClearBoundary == boundary && alerts.presentationCount == 2)
        #expect(try first.store.loadArchivePage().entries.count == 3)
        try first.sql("""
        CREATE TRIGGER fail_archive_command_clear BEFORE DELETE ON browser_tab_archive
        BEGIN SELECT RAISE(ABORT, 'injected Archive command failure'); END
        """)
        let beforeFailure = try first.evidence()
        alerts.respond(.alertFirstButtonReturn)
        try await archiveCommandWait { !controller.retryButton.isHidden }
        #expect(try first.evidence() == beforeFailure)
        #expect(controller.pendingClearBoundary == nil)
        // Retry keeps the original confirmation even after more Archive entries
        // arrive and the registry order changes.
        let whileFailed = try first.appendArchive(id: "during-retry", date: -200)
        route.registeredOwners = [first.model, second.model]
        let beforeRetry = try first.evidence()
        try first.sql("DROP TRIGGER fail_archive_command_clear")
        try await archiveCommandWait { controller.retryButton.isEnabled }
        controller.retryButton.performClick(nil)
        try await archiveCommandWait {
            (try? first.store.loadArchivePage().entries.map(\.id)) == [later.id, whileFailed.id]
        }
        let cleared = try first.evidence()
        #expect(cleared.session == beforeRetry.session)
        #expect(cleared.receipts == beforeRetry.receipts)
        #expect(try first.store.loadArchivePage().entries == [later, whileFailed])
        #expect(try second.evidence() == secondState)
        #expect(first.runtimeEvidence() == firstRuntime)
        #expect(second.runtimeEvidence() == secondRuntime)
        #expect(route.controller(for: second.model) == nil)
        #expect(route.origins.allSatisfy { $0 == ObjectIdentifier(first.model) })
        #expect(route.dismissedBeforeRouting.allSatisfy { $0 })
        #expect(route.results.allSatisfy { $0 })
    }

    @Test func archiveCommandsWorkBeforeEngineReadinessAndStaleSubmissionCannotNavigate() async throws {
        let route = ArchiveCommandRoute()
        let profile = try ArchiveCommandProfile(name: "Unready", route: route, ready: false)
        defer { profile.close() }
        defer { route.close() }
        route.registeredOwners = [profile.model]
        #expect(profile.model.canBrowseArchive && !profile.model.canRestoreArchivedTab)
        let before = try profile.evidence()
        try await profile.submit(.viewArchive)
        let controller = try #require(route.controller(for: profile.model))
        try await archiveCommandWait { !controller.isLoading }
        #expect(controller.entries.count == 2)
        #expect(!controller.restoreButton.isEnabled && controller.clearButton.isEnabled)
        try await profile.submit(.clearArchive)
        try await archiveCommandWait { controller.pendingClearBoundary != nil }
        try #require(route.alerts(for: profile.model)).respond(.alertSecondButtonReturn)
        #expect(profile.driver.createdTabRequests.isEmpty)
        #expect(profile.driver.targetedNavigationRequests.isEmpty)
        #expect(profile.driver.closedTabRequests.isEmpty)
        #expect(try profile.evidence() == before)

        let bar = profile.model.commandBarModel
        let view = try await profile.prepare(.clearArchive, bar: bar)
        let presented = route.presentationCount
        profile.model.prepareForTermination()
        #expect(view.control(
            view.queryField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(!bar.isPresented && route.results.last == false)
        #expect(route.presentationCount == presented)
        #expect(profile.driver.createdTabRequests.isEmpty && profile.driver.targetedNavigationRequests.isEmpty)
        #expect(try profile.evidence() == before)
    }
}

// MARK: - ArchiveCommandRoute

@MainActor private final class ArchiveCommandRoute {
    // MARK: Internal

    var registeredOwners = [BrowserChromeModel]()
    private(set) var origins = [ObjectIdentifier]()
    private(set) var dismissedBeforeRouting = [Bool]()
    private(set) var results = [Bool]()
    private(set) var presentationCount = 0
    private(set) var createdControllerCount = 0

    func perform(_ command: BrowserCommandID, from model: BrowserChromeModel) {
        origins.append(ObjectIdentifier(model))
        dismissedBeforeRouting
            .append(!model.commandBarModel.isPresented && !model.currentPageCommandBarModel.isPresented)
        results.append(BrowserArchiveCommandRouting.perform(
            command, from: model, registeredOwners: registeredOwners, isTerminating: false,
            present: { [unowned self] owner in
                presentationCount += 1
                let id = ObjectIdentifier(owner)
                if let existing = controllers[id] {
                    return existing
                }
                let alerts = ArchiveCommandAlerts()
                let controller = BrowserArchiveViewController(model: owner, alertPresenter: alerts.present)
                controllers[id] = controller
                alertPresenters[id] = alerts
                createdControllerCount += 1
                _ = controller.view
                return controller
            }
        ))
    }

    func controller(for model: BrowserChromeModel) -> BrowserArchiveViewController? {
        controllers[ObjectIdentifier(model)]
    }

    func alerts(for model: BrowserChromeModel) -> ArchiveCommandAlerts? {
        alertPresenters[ObjectIdentifier(model)]
    }

    func close() {
        controllers.values.forEach { $0.invalidate() }
        controllers.removeAll()
        alertPresenters.removeAll()
        registeredOwners.removeAll()
    }

    // MARK: Private

    private var controllers = [ObjectIdentifier: BrowserArchiveViewController]()
    private var alertPresenters = [ObjectIdentifier: ArchiveCommandAlerts]()
}

// MARK: - ArchiveCommandAlerts

@MainActor private final class ArchiveCommandAlerts {
    // MARK: Internal

    private(set) var alert: NSAlert?
    private(set) var presentationCount = 0

    func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
        presentationCount += 1
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

// MARK: - ArchiveCommandProfile

@MainActor private final class ArchiveCommandProfile {
    // MARK: Lifecycle

    init(name: String, route: ArchiveCommandRoute, ready: Bool = true) throws {
        _ = NSApplication.shared
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveCommand-\(UUID())")
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.defaults = try #require(UserDefaults(suiteName: suite))
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        self.owner = BrowserSyncOwner(baseURL: URL(string: "https://archive-command.example")!, userID: name)
        try store.bindSyncOwner(owner)
        let seed = BrowserTabSessionSnapshot(
            spaces: [.init(id: "work", title: "Work", systemImageName: "globe", selectedTabIndex: 0)],
            tabs: ["active", "old-0", "old-1"].map { (id: String) in
                .init(id: id, urlString: "https://example.com/\(id)", spaceID: "work", lastActivityTimestamp: 100)
            }
        )
        let events = try archiveCommandEvents(seed)
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        var archived = [BrowserTabArchiveEntry]()
        for index in 0..<2 {
            let snapshot = try #require(try store.loadSnapshotStrict())
            let tab = try #require(snapshot.tabs.first { $0.id == "old-\(index)" })
            let entry = BrowserTabArchiveEntry(
                id: "archive-\(index)",
                tab: tab,
                archivedAt: Double(index + 1),
                title: "Page \(index)"
            )
            try store.writeSessionBatch([.init(
                snapshot: .init(spaces: snapshot.spaces, tabs: snapshot.tabs.filter { $0.id != tab.id }),
                origin: .local(syncMove: nil), archiveAction: .insert(entry)
            )])
            archived.append(entry)
        }
        self.entries = archived
        self.model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store, sessionPreferencesStore: store,
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            profile: .init(directoryName: name, name: name),
            dateProvider: { Date(timeIntervalSince1970: 100) },
            commandHandler: { [weak route] command, owner in route?.perform(command, from: owner) },
            windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        if ready {
            model.handleContextReady()
            driver.flushPendingCreateEvents()
            for tab in model.tabs {
                driver.emitTabCreationState(id: tab.id, state: .ready)
            }
        }
    }

    // MARK: Internal

    let directory: URL
    let databaseURL: URL
    let suite = "ArchiveCommand.\(UUID())"
    let defaults: UserDefaults
    let owner: BrowserSyncOwner
    let store: BrowserSQLiteSessionStore
    let model: BrowserChromeModel
    let driver = FakeBrowserTabDriver()
    let entries: [BrowserTabArchiveEntry]

    func prepare(_ command: BrowserCommandID, bar: BrowserCommandBarModel) async throws -> BrowserCommandBarNSView {
        let query = command == .viewArchive ? "view archive" : "clear archive"
        let view = BrowserCommandBarNSView(model: bar, faviconCache: BrowserFaviconCache(dataLoader: { _ in nil }))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        bar.present(initialQuery: query)
        await bar.waitForPendingSuggestionLoad()
        let suggestion = try #require(bar.suggestions.first { $0.commandID == command })
        #expect(suggestion.kind == .command && suggestion.shortcut == nil)
        #expect(suggestion.resolvedURLString.isEmpty)
        bar.selectSuggestion(id: suggestion.id)
        return view
    }

    func submit(_ command: BrowserCommandID, currentPage: Bool = false) async throws {
        let bar = currentPage ? model.currentPageCommandBarModel : model.commandBarModel
        let view = try await prepare(command, bar: bar)
        #expect(view.control(
            view.queryField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(!bar.isPresented)
    }

    func appendArchive(id: String, date: TimeInterval) throws -> BrowserTabArchiveEntry {
        let snapshot = try #require(try store.loadSnapshotStrict())
        let tab = BrowserTabSessionSnapshotTab(
            id: id,
            urlString: "https://example.com/\(id)",
            spaceID: "work",
            lastActivityTimestamp: 100
        )
        try store.writeSessionBatch([.init(
            snapshot: .init(spaces: snapshot.spaces, tabs: snapshot.tabs + [tab]),
            origin: .local(syncMove: nil)
        )])
        let entry = BrowserTabArchiveEntry(id: "archive-" + id, tab: tab, archivedAt: date)
        try store.writeSessionBatch([.init(
            snapshot: snapshot,
            origin: .local(syncMove: nil),
            archiveAction: .insert(entry)
        )])
        return entry
    }

    func sql(_ sql: String) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: sql) }
    }

    func evidence() throws -> ArchiveCommandEvidence {
        try DatabaseQueue(path: databaseURL.path).read { db in
            try .init(
                session: .init(
                    snapshot: store.loadSnapshotStrict(),
                    queue: Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_outbox ORDER BY position"),
                    baseline: Data.fetchAll(db, sql: "SELECT payload FROM browser_sync_baseline ORDER BY id"),
                    preferences: String.fetchAll(
                        db,
                        sql: "SELECT key || ':' || value FROM browser_preferences ORDER BY key"
                    ),
                    cursor: store.syncCursor(for: owner)
                ),
                archive: Data.fetchAll(db, sql: "SELECT payload FROM browser_tab_archive ORDER BY id"),
                receipts: String.fetchAll(
                    db,
                    sql: "SELECT id || ':' || hex(entry_digest) || ':' || COALESCE(restored_tab_id,'') FROM browser_tab_archive_receipts ORDER BY id"
                )
            )
        }
    }

    func runtimeEvidence() -> ArchiveCommandRuntimeEvidence {
        .init(
            ids: model.tabs.map(\.id),
            selectedID: model.selectedTabID,
            selectedSpaceID: model.selectedSpaceID,
            creates: driver.createdTabRequests.count,
            closes: driver.closedTabRequests.count,
            navigations: driver.targetedNavigationRequests.count,
            activeNavigations: driver.activeTabNavigationURLStrings.count,
            selections: driver.selectedTabIDs.count
        )
    }

    func close() {
        model.discardUnsavedSessionForClosure()
        model.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - ArchiveCommandEvidence

private struct ArchiveCommandEvidence: Equatable {
    let session: ArchiveCommandSessionEvidence
    let archive: [Data]
    let receipts: [String]
}

// MARK: - ArchiveCommandSessionEvidence

private struct ArchiveCommandSessionEvidence: Equatable {
    let snapshot: BrowserTabSessionSnapshot?
    let queue: [Data]
    let baseline: [Data]
    let preferences: [String]
    let cursor: Int
}

// MARK: - ArchiveCommandRuntimeEvidence

private struct ArchiveCommandRuntimeEvidence: Equatable {
    let ids: [String]
    let selectedID: String?
    let selectedSpaceID: String?
    let creates: Int
    let closes: Int
    let navigations: Int
    let activeNavigations: Int
    let selections: Int
}

private func archiveCommandEvents(_ snapshot: BrowserTabSessionSnapshot) throws -> [BrowserSyncEvent] {
    try BrowserSyncFolderProjection.canonicalChanges(snapshot).enumerated().map { index, change in
        let encoded = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        var data = encoded["data"] as? [String: Any] ?? [:]
        data["id"] = change.entityID
        return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: [
            "serverSeq": index + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
            "entityID": change.entityID, "op": change.op.rawValue, "data": data, "createdAt": "2026-10-03T00:00:00Z",
        ]))
    }
}

@MainActor private func archiveCommandWait(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Archive command did not reach its expected state")
    throw ArchiveCommandTestError.timeout
}

// MARK: - ArchiveCommandTestError

private enum ArchiveCommandTestError: Error { case timeout }
