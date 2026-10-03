import Foundation
import Testing
import UIKit

@MainActor @Test func mobileSceneReconnectRetainsDelayedWriterAndLatestEdits() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    let original = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    #expect(await original.workspace.flushPersistence())
    await fixture.store.holdNextSave()
    original.workspace.submit("https://example.com/in-flight")
    await fixture.store.waitForHeldSave()
    fixture.sessions.disconnect(original)
    let reconnected = try await fixture.sessions.connect(sessionID: "scene")
    #expect(reconnected.workspace === original.workspace)
    #expect(fixture.engines.count == 1 && fixture.engines[0].shutdownCount == 0)
    reconnected.workspace.submit("https://example.com/latest")
    reconnected.workspace.newTab()
    reconnected.workspace.submit("https://example.com/second")
    let ids = reconnected.workspace.tabs.map(\.id)
    let selectedID = reconnected.workspace.selectedTabID
    await fixture.store.releaseSave()
    await fixture.sessions.waitForPendingOperations()
    #expect(await reconnected.workspace.flushPersistence())
    let saved = try await BrowserMobileFileSessionStore(fileURL: fixture.url).load()
    #expect(saved?.tabs.map(\.id) == ids && saved?.selectedTabID == selectedID)
    #expect(saved?.tabs.map(\.urlString) == ["https://example.com/latest", "https://example.com/second"])
    #expect(await fixture.store.maximumConcurrentSaves() == 1)
    fixture.sessions.discard(sessionIDs: ["scene"])
    await fixture.sessions.waitForPendingOperations()
    #expect(fixture.engines[0].shutdownCount == 1)
}

@MainActor @Test func mobileSceneReconnectPreservesFailedSaveForVisibleRetry() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    let original = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    #expect(await original.workspace.flushPersistence())
    let oldBytes = try Data(contentsOf: fixture.url)
    await fixture.store.setFailure(true)
    original.workspace.submit("https://example.com/unsaved")
    #expect(await !original.workspace.flushPersistence())
    fixture.sessions.disconnect(original)
    await fixture.sessions.waitForPendingOperations()
    let reconnected = try await fixture.sessions.connect(sessionID: "scene")
    #expect(reconnected.workspace === original.workspace && reconnected.workspace.isReady)
    #expect(reconnected.workspace.sessionError != nil)
    #expect(reconnected.workspace.selectedTab?.urlString == "https://example.com/unsaved")
    #expect(try Data(contentsOf: fixture.url) == oldBytes)
    reconnected.workspace.submit("https://example.com/latest-unsaved")
    await fixture.store.setFailure(false)
    #expect(await reconnected.workspace.retryPersistence())
    #expect(reconnected.workspace.sessionError == nil && fixture.engines.count == 1)
    let saved = try await BrowserMobileFileSessionStore(fileURL: fixture.url).load()
    #expect(saved?.tabs.first?.urlString == "https://example.com/latest-unsaved")
    fixture.sessions.discard(sessionIDs: ["scene"])
    await fixture.sessions.waitForPendingOperations()
}

@MainActor @Test func mobileSceneReconnectKeepsDamagedFileUntilRestoreRetrySucceeds() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let damaged = Data("{damaged-session".utf8)
    try damaged.write(to: fixture.url)
    let original = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    fixture.sessions.disconnect(original)
    let reconnected = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    #expect(reconnected.workspace === original.workspace && !reconnected.workspace.isReady)
    #expect(reconnected.workspace.sessionError != nil && fixture.engines[0].createdIDs.isEmpty)
    reconnected.workspace.newTab()
    #expect(await !reconnected.workspace.retryPersistence())
    #expect(try Data(contentsOf: fixture.url) == damaged)
    let repaired = BrowserMobileSession(
        tabs: [.init(id: "preserved", urlString: "https://example.com/recovered", title: "Saved")],
        selectedTabID: "preserved"
    )
    try JSONEncoder().encode(repaired).write(to: fixture.url, options: .atomic)
    #expect(await reconnected.workspace.retryPersistence())
    #expect(reconnected.workspace.selectedTabID == "preserved")
    fixture.sessions.discard(sessionIDs: ["scene"])
    await fixture.sessions.waitForPendingOperations()
}

@MainActor @Test func mobileSceneStaleDisconnectCannotDetachNewConnection() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    let old = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    let current = try await fixture.sessions.connect(sessionID: "scene")
    var notifications = 0
    current.workspace.onChange = { notifications += 1 }
    fixture.sessions.disconnect(old)
    current.workspace.newTab()
    #expect(notifications > 0)
    #expect(current.workspace === old.workspace && fixture.engines.count == 1)
    fixture.sessions.discard(sessionIDs: ["scene"])
    await fixture.sessions.waitForPendingOperations()
}

@MainActor @Test func mobileSceneDiscardSerializesReopenBehindFinalSave() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    let original = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    #expect(await original.workspace.flushPersistence())
    fixture.sessions.setActive(true, for: original)
    #expect(fixture.engines[0].isJavaScriptDialogPresentationActive)
    await fixture.store.holdNextSave()
    original.workspace.submit("https://example.com/final")
    await fixture.store.waitForHeldSave()
    fixture.sessions.discard(sessionIDs: ["scene"])
    #expect(!fixture.engines[0].isJavaScriptDialogPresentationActive)
    let reconnect = Task { try await fixture.sessions.connect(sessionID: "scene") }
    await fixture.waitForShutdown()
    #expect(fixture.engines.count == 1)
    await fixture.store.releaseSave()
    let reopened = try await reconnect.value
    await fixture.sessions.waitForPendingOperations()
    #expect(reopened.workspace !== original.workspace && fixture.engines.count == 2)
    #expect(!fixture.engines[1].isJavaScriptDialogPresentationActive)
    #expect(reopened.workspace.selectedTab?.urlString == "https://example.com/final")
    #expect(await fixture.store.maximumConcurrentSaves() == 1)
    fixture.sessions.discard(sessionIDs: ["scene"])
    await fixture.sessions.waitForPendingOperations()
}

@MainActor @Test func mobileSceneDialogActivityRejectsStaleAttachmentsAndReconnectStartsInactive() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    let old = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    let engine = try #require(fixture.engines.first)
    #expect(!engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.setActive(true, for: old)
    #expect(engine.isJavaScriptDialogPresentationActive)

    let current = try await fixture.sessions.connect(sessionID: "scene")
    #expect(current.workspace === old.workspace && !engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.setActive(true, for: old)
    #expect(!engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.setActive(true, for: current)
    fixture.sessions.setActive(false, for: old)
    fixture.sessions.disconnect(old)
    #expect(engine.isJavaScriptDialogPresentationActive)

    fixture.sessions.disconnect(current)
    #expect(!engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.setActive(true, for: current)
    #expect(!engine.isJavaScriptDialogPresentationActive)
    let reconnected = try await fixture.sessions.connect(sessionID: "scene")
    #expect(reconnected.workspace === current.workspace && !engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.setActive(true, for: reconnected)
    #expect(engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.discard(sessionIDs: ["scene"])
    #expect(!engine.isJavaScriptDialogPresentationActive)
    fixture.sessions.setActive(true, for: reconnected)
    #expect(!engine.isJavaScriptDialogPresentationActive)
    await fixture.sessions.waitForPendingOperations()
}

@MainActor @Test func mobileSceneDialogActivityStaysWithinItsOwnSession() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    var engines = [String: MobileSceneEngine]()
    let sessions = BrowserMobileSceneSessions { sessionID in
        let engine = MobileSceneEngine()
        engines[sessionID] = engine
        let store = BrowserMobileFileSessionStore(
            fileURL: fixture.directory.appendingPathComponent(sessionID + ".json")
        )
        return .init(workspace: BrowserMobileWorkspace(engine: engine, store: store), contentView: engine.hostView)
    }
    let first = try await sessions.connect(sessionID: "first")
    let second = try await sessions.connect(sessionID: "second")
    await sessions.waitForPendingOperations()
    let firstEngine = try #require(engines["first"])
    let secondEngine = try #require(engines["second"])
    sessions.setActive(true, for: first)
    #expect(firstEngine.isJavaScriptDialogPresentationActive && !secondEngine.isJavaScriptDialogPresentationActive)
    sessions.setActive(true, for: second)
    sessions.setActive(false, for: first)
    #expect(!firstEngine.isJavaScriptDialogPresentationActive && secondEngine.isJavaScriptDialogPresentationActive)
    sessions.disconnect(first)
    #expect(secondEngine.isJavaScriptDialogPresentationActive)
    sessions.discard(sessionIDs: ["first", "second"])
    #expect(!firstEngine.isJavaScriptDialogPresentationActive && !secondEngine.isJavaScriptDialogPresentationActive)
    await sessions.waitForPendingOperations()
}

@MainActor @Test func mobileCancelledSceneReconnectDoesNotAcquireRetiredSession() async throws {
    let fixture = MobileSceneFixture()
    defer { fixture.cleanup() }
    let original = try await fixture.sessions.connect(sessionID: "scene")
    await fixture.sessions.waitForPendingOperations()
    #expect(await original.workspace.flushPersistence())
    await fixture.store.holdNextSave()
    original.workspace.submit("https://example.com/final")
    await fixture.store.waitForHeldSave()
    fixture.sessions.discard(sessionIDs: ["scene"])
    let reconnect = Task { try await fixture.sessions.connect(sessionID: "scene") }
    await fixture.waitForShutdown()
    reconnect.cancel()
    await fixture.store.releaseSave()
    await #expect(throws: CancellationError.self) { try await reconnect.value }
    await fixture.sessions.waitForPendingOperations()
    #expect(fixture.engines.count == 1 && fixture.engines[0].shutdownCount == 1)
    let saved = try await BrowserMobileFileSessionStore(fileURL: fixture.url).load()
    #expect(saved?.tabs.first?.urlString == "https://example.com/final")
}

@MainActor @Test func mobileSceneSyncActivityUsesSharedRegistryAndRejectsStaleAttachments() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-scene-sync-\(UUID())")
    let suite = "mobile-scene-sync-\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    var createdSessions = 0
    let registry = BrowserMobileProfileRegistry(directory: directory) { store, document in
        createdSessions += 1
        return BrowserMobileSyncSession(
            store: store, document: document, preferences: preferences,
            authSessionStore: MobileSceneSyncAuth(), environment: [:], packagedServerURL: nil
        )
    }
    let scenes = BrowserMobileSceneSessions { id in
        let engine = MobileSceneEngine()
        return .init(workspace: BrowserMobileWorkspace(
            engine: engine, sceneID: id, profileLoader: { try await registry.document() }, preferences: preferences
        ), contentView: engine.hostView)
    }
    let first = try await scenes.connect(sessionID: "first")
    // Activity can arrive while the shared SQLite profile is still opening.
    scenes.setActive(true, for: first)
    let second = try await scenes.connect(sessionID: "second")
    await scenes.waitForPendingOperations()
    let runtime = try #require(registry.syncSession)
    #expect(createdSessions == 1)
    #expect(first.workspace.profileDocument === second.workspace.profileDocument)
    #expect(first.workspace.syncSession === runtime && second.workspace.syncSession === runtime)
    #expect(runtime.isForeground)
    scenes.setActive(true, for: second)
    scenes.disconnect(first)
    #expect(runtime.isForeground)
    let replacement = try await scenes.connect(sessionID: "second")
    #expect(!runtime.isForeground)
    scenes.setActive(true, for: second)
    #expect(!runtime.isForeground, "Old attachment cannot activate replacement")
    scenes.setActive(true, for: replacement)
    scenes.setActive(false, for: second)
    scenes.disconnect(second)
    #expect(runtime.isForeground, "Old attachment cannot deactivate replacement")
    let tabs = BrowserMobileTabsViewController(workspace: replacement.workspace)
    tabs.loadViewIfNeeded()
    let accountButton = try #require(tabs.navigationItem.leftBarButtonItems?.last)
    #expect(accountButton.accessibilityIdentifier == "browser.account" && accountButton.isEnabled)
    scenes.discard(sessionIDs: ["first", "second"])
    await scenes.waitForPendingOperations()
    #expect(!runtime.isForeground)
}

// MARK: - MobileSceneSyncAuth

@MainActor private final class MobileSceneSyncAuth: BrowserSyncAuthSessionStoring {
    func loadSession() -> BrowserAuthSession? { nil }
    func saveSession(_: BrowserAuthSession) {}
    func clearSession() {}
}

// MARK: - MobileSceneFixture

@MainActor private final class MobileSceneFixture {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-scene-\(UUID())")
    lazy var store = MobileSceneStore(fileURL: url)
    private(set) var engines = [MobileSceneEngine]()
    lazy var sessions = BrowserMobileSceneSessions { [unowned self] _ in
        let engine = MobileSceneEngine()
        engine.onShutdown = { [weak self] in
            self?.shutdownWaiter?.resume()
            self?.shutdownWaiter = nil
        }
        engines.append(engine)
        return .init(workspace: BrowserMobileWorkspace(engine: engine, store: store), contentView: engine.hostView)
    }

    var url: URL { directory.appendingPathComponent("session.json") }

    func waitForShutdown() async {
        if engines.first?.shutdownCount ?? 0 > 0 {
            return
        }
        await withCheckedContinuation { shutdownWaiter = $0 }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Private

    private var shutdownWaiter: CheckedContinuation<Void, Never>?
}

// MARK: - MobileSceneEngine

@MainActor private final class MobileSceneEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var onShutdown: (() -> Void)?
    var createdIDs = [String]()
    var shutdownCount = 0
    private(set) var isJavaScriptDialogPresentationActive = false

    func setJavaScriptDialogPresentationActive(_ active: Bool) { isJavaScriptDialogPresentationActive = active }
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}

    func createTab(id: String, url: URL) {
        createdIDs.append(id)
        onEvent?(.state(id: id, .init(url: url)))
    }

    func selectTab(id _: String?) {}
    func navigate(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func closeTab(id: String) { onEvent?(.closed(id: id)) }
    func shutdown() { shutdownCount += 1
        onShutdown?()
    }
}

// MARK: - MobileSceneStore

private actor MobileSceneStore: BrowserMobileSessionStoring {
    // MARK: Lifecycle

    init(fileURL: URL) { self.file = BrowserMobileFileSessionStore(fileURL: fileURL) }

    // MARK: Internal

    func load() async throws -> BrowserMobileSession? { try await file.load() }
    func save(_ session: BrowserMobileSession) async throws {
        activeSaves += 1
        maximumSaves = max(maximumSaves, activeSaves)
        defer { activeSaves -= 1 }
        if holdSave {
            holdSave = false
            await withCheckedContinuation { continuation in
                release = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await file.save(session)
    }

    func setFailure(_ value: Bool) { fails = value }
    func holdNextSave() { holdSave = true }
    func waitForHeldSave() async {
        if release != nil {
            return
        }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func releaseSave() {
        let continuation = release
        release = nil
        continuation?.resume()
    }

    func maximumConcurrentSaves() -> Int { maximumSaves }

    // MARK: Private

    private let file: BrowserMobileFileSessionStore
    private var fails = false
    private var holdSave = false
    private var release: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var activeSaves = 0
    private var maximumSaves = 0
}
