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
    await fixture.store.holdNextSave()
    original.workspace.submit("https://example.com/final")
    await fixture.store.waitForHeldSave()
    fixture.sessions.discard(sessionIDs: ["scene"])
    let reconnect = Task { try await fixture.sessions.connect(sessionID: "scene") }
    await fixture.waitForShutdown()
    #expect(fixture.engines.count == 1)
    await fixture.store.releaseSave()
    let reopened = try await reconnect.value
    await fixture.sessions.waitForPendingOperations()
    #expect(reopened.workspace !== original.workspace && fixture.engines.count == 2)
    #expect(reopened.workspace.selectedTab?.urlString == "https://example.com/final")
    #expect(await fixture.store.maximumConcurrentSaves() == 1)
    fixture.sessions.discard(sessionIDs: ["scene"])
    await fixture.sessions.waitForPendingOperations()
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
