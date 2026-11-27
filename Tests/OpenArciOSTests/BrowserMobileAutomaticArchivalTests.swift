// BrowserMobileAutomaticArchivalTests.swift

import BrowserMobileTestHost
import Foundation
import GRDB
import Testing
import UIKit

// MARK: - BrowserMobileAutomaticArchivalTests

@MainActor struct BrowserMobileAutomaticArchivalTests {
    @Test func settingsShowsTheArchiveTimingInItsOwnRow() async throws {
        try await withAutomaticArchiveFixture { f in
            let workspace = await f.workspace("settings")
            #expect(f.document.setAutomaticTabArchival(lifetime: .sevenDays))
            let settings = BrowserMobilePhoneSettingsViewController(workspace: workspace)
            settings.loadViewIfNeeded()
            settings.beginAppearanceTransition(true, animated: false)
            settings.endAppearanceTransition()
            let table = settings.tableView!
            let cells = (0..<table.numberOfSections).flatMap { section in
                (0..<table.numberOfRows(inSection: section)).compactMap {
                    settings.tableView(table, cellForRowAt: IndexPath(row: $0, section: section))
                }
            }
            let row = try #require(cells.first { $0.accessibilityIdentifier == "browser.settings.archiveInactiveTabs" })
            let content = try #require(row.contentConfiguration as? UIListContentConfiguration)
            #expect(content.secondaryText == "After 7 Days")
            let button = try #require(row.contentView.subviews.compactMap { $0 as? UIButton }.first)
            #expect(button.showsMenuAsPrimaryAction)
            let choices = button.menu?.children.compactMap { $0 as? UIAction } ?? []
            #expect(choices.map(\.title) == [
                "Off", "After 12 Hours", "After 1 Day", "After 3 Days", "After 7 Days", "After 30 Days",
            ])
            #expect(choices.filter { $0.state == .on }.map(\.title) == ["After 7 Days"])
        }
    }

    @Test func allAttachedScenesMustHydrateAndOnlyActiveSelectionsRefresh() async throws {
        try await withAutomaticArchiveFixture { f in
            let gate = AutomaticArchiveLoadGate()
            let scenes = BrowserMobileSceneSessions { id in
                let engine = AutomaticArchiveEngine()
                let workspace = f.makeWorkspace(id, engine: engine, loader: {
                    if id == "delayed" {
                        await gate.wait()
                    }
                    return f.document
                })
                return .init(workspace: workspace, contentView: engine.hostView)
            }
            let first = try await scenes.connect(sessionID: "first")
            await scenes.waitForPendingOperations()
            first.workspace.selectTab(id: "m1")
            scenes.setActive(true, for: first)
            #expect(f.document.setAutomaticTabArchival(lifetime: .twelveHours))
            #expect(f.document.expirySchedulingState()?.protectedTabIDs == [], "Mobile tabs hold no Space tab back")
            let second = try await scenes.connect(sessionID: "delayed")
            defer { gate.release() }
            try #require(await automaticArchiveEventually { gate.isWaiting })
            let before = f.document.snapshot
            #expect(f.document.expirySchedulingState() == nil)
            #expect(!f.document.refreshExpiryActivity())
            f.document.performAutomaticTabArchivalCheck()
            #expect(try f.document.snapshot == before && f.store.loadArchivePage().entries.isEmpty)
            gate.release()
            await scenes.waitForPendingOperations()
            second.workspace.selectTab(id: "m2")
            #expect(f.document.expirySchedulingState() != nil)
            let inactiveActivity = f.mobileActivity("m2")
            f.clock.now += 600
            #expect(f.document.refreshExpiryActivity())
            #expect(f.mobileActivity("m1") == f.clock.now && f.mobileActivity("m2") == inactiveActivity)
            scenes.disconnect(second)
            scenes.setActive(true, for: second)
            f.clock.now += 600
            #expect(f.document.refreshExpiryActivity())
            #expect(f.mobileActivity("m2") == inactiveActivity, "Stale connections cannot record activity")
            scenes.disconnect(first)
            #expect(f.document.expirySchedulingState() == nil)
            await scenes.waitForPendingOperations()
        }
    }

    @Test(arguments: [AutomaticArchiveBinding.local, .bound, .paused, .signedOut])
    func localSweepNeverBypassesDurableBindingAndProtectsUnknownAndFutureTabs(
        binding: AutomaticArchiveBinding,
    ) async throws {
        try await withAutomaticArchiveFixture(binding: binding) { f in
            let firstEngine = AutomaticArchiveEngine()
            let secondEngine = AutomaticArchiveEngine()
            let first = await f.workspace("first", engine: firstEngine)
            let second = await f.workspace("second", engine: secondEngine)
            first.selectTab(id: "m1")
            second.selectTab(id: "m2")
            first.setSceneAttached(true)
            second.setSceneAttached(true)
            first.setActivityActive(true)
            #expect(f.document.setAutomaticTabArchival(lifetime: .twelveHours))
            let before = try f.rows()
            f.document.performAutomaticTabArchivalCheck()
            let entries = try f.store.loadArchivePage().entries
            #expect(firstEngine.closed.isEmpty && secondEngine.closed.isEmpty, "Space tabs have no page here")
            #expect(first.tabs.map(\.id) == ["m1", "m2"], "Mobile tabs never expire")
            if binding == .local {
                #expect(Set(entries.compactMap(\.tab.id)) == ["a", "b", "c"])
                #expect(Set(f.document.snapshot.tabs.compactMap(\.id)) == ["unknown", "future", "pin", "favorite"])
                let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
                #expect(try reopened.loadArchivePage().entries == entries)
                #expect(try reopened.loadSnapshotStrict() == f.document.snapshot)
                let entry = try #require(entries.first)
                let restored = try #require(first.restoreArchivedTab(id: entry.id))
                #expect(first.selectedTabID == restored)
                #expect(f.document.mobileTab(id: restored)?.record.urlString == entry.tab.urlString)
                f.document.performAutomaticTabArchivalCheck()
                #expect(try f.store.loadArchivePage().entries.count == entries.count - 1)
                #expect(f.document.mobileTab(id: restored) != nil)
            } else {
                #expect(entries.isEmpty)
                #expect(f.document.snapshot.tabs.contains { $0.id == "c" })
                #expect(try f.rows() == before, "Bound/Pause/logout cannot enqueue an unconditional local delete")
            }
            #expect(second.selectedTabID == "m2")
        }
    }

    @Test func localArchiveSQLFailureStopsSweepAndRetryKeepsOneRecoveryEntryEach() async throws {
        try await withAutomaticArchiveFixture { f in
            let first = await f.workspace("first")
            let second = await f.workspace("second")
            first.setSceneAttached(true)
            second.setSceneAttached(true)
            first.setActivityActive(true)
            #expect(f.document.setAutomaticTabArchival(lifetime: .twelveHours))
            try f
                .sql(
                    "CREATE TRIGGER fail_auto_archive BEFORE INSERT ON browser_tab_archive BEGIN SELECT RAISE(ABORT,'injected'); END",
                )
            f.document.performAutomaticTabArchivalCheck()
            #expect(f.document.hasUncommittedWrites && f.document.expirySchedulingState() == nil)
            #expect(try f.store.loadArchivePage().entries.isEmpty)
            #expect(try f.store.loadSnapshotStrict()?.tabs.contains { $0.id == "c" } == true)
            f.document.performAutomaticTabArchivalCheck()
            try f.sql("DROP TRIGGER fail_auto_archive")
            #expect(f.document.retryPersistence())
            f.document.performAutomaticTabArchivalCheck()
            let entries = try f.store.loadArchivePage().entries
            #expect(entries.compactMap(\.tab.id).sorted() == ["a", "b", "c"])
            f.document.performAutomaticTabArchivalCheck()
            #expect(try f.store.loadArchivePage().entries == entries)
            #expect(try f.rows().isEmpty)
        }
    }

    @Test func offStillRefreshesMobileActivityWithoutWritingSpaces() async throws {
        try await withAutomaticArchiveFixture(binding: .bound) { f in
            let workspace = await f.workspace("first")
            workspace.selectTab(id: "m1")
            workspace.setSceneAttached(true)
            workspace.setActivityActive(true)
            let state = try #require(f.document.expirySchedulingState())
            #expect(state.inactiveForSeconds == nil)
            let before = try f.rows()
            f.clock.now += 600
            #expect(f.document.refreshExpiryActivity())
            #expect(f.mobileActivity("m1") == f.clock.now)
            #expect(f.document.refreshExpiryActivity())
            #expect(try f.rows() == before, "Mobile activity never queues Space writes")
            #expect(try f.store.loadArchivePage().entries.isEmpty)
        }
    }
}

extension BrowserMobileUITests {
    @Test(arguments: [false, true])
    func nativeArchiveTimingChoicesPersistAtomicallyAndRetryTheSelectedValue(compact: Bool) async throws {
        try await withAutomaticArchiveFixture { f in
            let workspace = await f.workspace("ui")
            let archive = BrowserMobileArchiveViewController(workspace: workspace)
            let navigation = UINavigationController(rootViewController: archive)
            let window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
            window.frame.size = compact ? CGSize(width: 320, height: 640) : CGSize(width: 1024, height: 768)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            navigation.loadViewIfNeeded()
            navigation.view.frame = window.bounds
            navigation.view.layoutIfNeeded()
            defer { window.isHidden = true
                window.rootViewController = nil
            }
            let button = try #require(archive.navigationItem.leftBarButtonItem)
            #expect(button.accessibilityIdentifier == "browser.archive.timing" && button.isEnabled)
            let identifiers = try #require(button.menu).children.compactMap { ($0 as? UIAction)?.identifier.rawValue }
            #expect(identifiers == ["off", "12h", "24h", "3d", "7d", "30d"].map { "browser.archive.timing." + $0 })
            #expect(automaticArchiveSelectedMenuID(button) == "browser.archive.timing.off")
            // This invokes the production callback used by UIAction handlers;
            // menu metadata/layout above are UIKit, physical menu taps are not simulated.
            archive.chooseAutomaticArchival(.threeDays)
            #expect(workspace.automaticTabArchivalEnabled && workspace.temporaryTabLifetime == .threeDays)
            #expect(automaticArchiveSelectedMenuID(button) == "browser.archive.timing.3d")
            try f
                .sql(
                    "CREATE TRIGGER fail_auto_settings BEFORE INSERT ON browser_preferences BEGIN SELECT RAISE(ABORT,'injected'); END",
                )
            archive.chooseAutomaticArchival(.twelveHours)
            #expect(workspace.automaticTabArchivalError != nil)
            #expect(automaticArchiveSelectedMenuID(button) == "browser.archive.timing.3d")
            let stillSaved = try f.store.loadAutomaticTabArchivalSettings()
            #expect(stillSaved.enabled && stillSaved.lifetime == .threeDays)
            try f.sql("DROP TRIGGER fail_auto_settings")
            let retry = try #require(automaticArchiveView(in: archive.view, id: "browser.archive.retry") as? UIButton)
            archive.view.layoutIfNeeded()
            #expect(!retry.isHidden && retry.isEnabled && retry.bounds.height >= 44)
            retry.sendActions(for: .touchUpInside)
            #expect(workspace.automaticTabArchivalError == nil && workspace.temporaryTabLifetime == .twelveHours)
            #expect(automaticArchiveSelectedMenuID(button) == "browser.archive.timing.12h")
            archive.chooseAutomaticArchival(nil)
            let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
            let saved = try reopened.loadAutomaticTabArchivalSettings()
            #expect(!saved.enabled && saved.lifetime == .twelveHours)
            #expect(try f.rows().isEmpty && f.store.loadArchivePage().entries.isEmpty)
        }
    }
}

// MARK: - AutomaticArchiveBinding

enum AutomaticArchiveBinding: CaseIterable { case local, bound, paused, signedOut }

// MARK: - AutomaticArchiveClock

@MainActor private final class AutomaticArchiveClock { var now: TimeInterval = 1_000_000 }

// MARK: - AutomaticArchiveFixture

@MainActor private final class AutomaticArchiveFixture {
    // MARK: Internal

    let databaseURL: URL
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://autoarchive.example")!, userID: "user")
    let preferencesName = "AutomaticArchive." + UUID().uuidString
    let preferences: UserDefaults
    let clock = AutomaticArchiveClock()
    var workspaces = [BrowserMobileWorkspace]()

    init(directory: URL, binding: AutomaticArchiveBinding) throws {
        self.databaseURL = directory.appendingPathComponent("Profile.sqlite")
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        self.store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "work", title: "Work", systemImageName: "globe")],
            tabs: [
                Self.tab("a"), Self.tab("b"), Self.tab("c"), Self.tab("unknown", activity: nil),
                Self.tab("future", activity: 2_000_000), Self.tab("pin", placement: .spacePinned),
                Self.tab("favorite", placement: .app),
            ],
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        if binding != .local {
            try store.bindSyncOwner(owner)
            // First-bind rows are irrelevant here; adopt exactly the already-durable seed.
            try DatabaseQueue(path: databaseURL.path).write { try $0.execute(sql: "DELETE FROM browser_sync_outbox") }
            let events = try BrowserSyncFolderProjection.canonicalChanges(snapshot).enumerated().map { index, change in
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
                var data = object["data"] as! [String: Any]
                data["id"] = change.entityID
                object["data"] = data
                object["serverSeq"] = index + 1
                object["deviceID"] = "fixture"
                object["createdAt"] = "2026-10-03T00:00:00Z"
                return try JSONDecoder().decode(
                    BrowserSyncEvent.self,
                    from: JSONSerialization.data(withJSONObject: object),
                )
            }
            _ = try store.completeExpirySyncBootstrap(events: events, cursor: events.count, for: owner)
            if binding == .paused {
                try store.pauseSync()
            }
            if binding == .signedOut {
                try store.requireSyncSignIn()
            }
        }
        // This phone's own tabs, which the sweep never takes.
        try store.saveMobileTabs(["m1", "m2"].map { id in
            .init(id: id, record: .init(
                urlString: "https://autoarchive.example/mobile-" + id, createdAt: Date(timeIntervalSince1970: 0),
                lastActivityAt: Date(timeIntervalSince1970: 0),
            ))
        })
        let clock = clock
        self.document = try BrowserMobileProfileDocument(
            store: store, initialSnapshot: store.loadSnapshotStrict(),
            dateProvider: { Date(timeIntervalSince1970: clock.now) },
            automaticArchivalCheckInterval: nil,
        )
    }

    static func tab(
        _ id: String,
        activity: TimeInterval? = 0,
        placement: BrowserTabPlacement = .temporary,
    ) -> BrowserTabSessionSnapshotTab {
        .init(
            id: id,
            urlString: "https://autoarchive.example/" + id,
            placement: placement,
            spaceID: "work",
            lastActivityTimestamp: activity,
        )
    }

    func makeWorkspace(
        _ id: String, engine: AutomaticArchiveEngine,
        loader: (@MainActor () async throws -> BrowserMobileProfileDocument)? = nil,
    ) -> BrowserMobileWorkspace {
        let document = document
        let workspace = BrowserMobileWorkspace(
            engine: engine,
            sceneID: id,
            profileLoader: loader ?? { document },
            preferences: preferences,
        )
        workspaces.append(workspace)
        return workspace
    }

    func workspace(_ id: String, engine: AutomaticArchiveEngine = .init()) async -> BrowserMobileWorkspace {
        let workspace = makeWorkspace(id, engine: engine)
        await workspace.restore()
        return workspace
    }

    func activity(_ id: String) -> TimeInterval? { document.snapshot.tabs.first { $0.id == id }?.lastActivityTimestamp }
    func mobileActivity(_ id: String) -> TimeInterval? {
        document.mobileTab(id: id)?.record.lastActivityAt?.timeIntervalSince1970
    }

    func rows() throws -> [Data] {
        try DatabaseQueue(path: databaseURL.path).read { try Data.fetchAll(
            $0,
            sql: "SELECT payload FROM browser_sync_outbox ORDER BY position",
        ) }
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

// MARK: - AutomaticArchiveEngine

@MainActor private final class AutomaticArchiveEngine: BrowserMobileEngine {
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

// MARK: - AutomaticArchiveLoadGate

@MainActor private final class AutomaticArchiveLoadGate {
    // MARK: Internal

    var isWaiting = false

    // MARK: Private

    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async { await withCheckedContinuation { continuation = $0
        isWaiting = true
    } }
    func release() { continuation?.resume()
        continuation = nil
    }
}

@MainActor private func automaticArchiveSelectedMenuID(_ button: UIBarButtonItem) -> String? {
    button.menu?.children.compactMap { $0 as? UIAction }.first { $0.state == .on }?.identifier.rawValue
}

@MainActor private func automaticArchiveView(in view: UIView, id: String) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { automaticArchiveView(in: $0, id: id) }.first
}

@MainActor private func automaticArchiveEventually(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

@MainActor private func withAutomaticArchiveFixture(
    binding: AutomaticArchiveBinding = .local, _ body: (AutomaticArchiveFixture) async throws -> Void,
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticArchive-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runAutomaticArchiveFixture(directory: directory, binding: binding, body)
}

@MainActor private func runAutomaticArchiveFixture(
    directory: URL, binding: AutomaticArchiveBinding, _ body: (AutomaticArchiveFixture) async throws -> Void,
) async throws {
    let fixture = try AutomaticArchiveFixture(directory: directory, binding: binding)
    do {
        try await body(fixture)
        await fixture.stop()
    } catch {
        await fixture.stop()
        throw error
    }
}
