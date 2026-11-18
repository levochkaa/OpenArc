// BrowserMobileWorkspaceTests.swift

import Foundation
import Testing
import UIKit

@MainActor @Test func mobileJavaScriptDialogTokensAreTransientAndStaleCompletionsCannotResolveNewDialog() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    await workspace.restore()
    workspace.submit("https://example.com/dialog")
    #expect(await workspace.flushPersistence())
    let baseline = try Data(contentsOf: f.url)
    let tab = try #require(workspace.selectedTab)
    workspace.setJavaScriptDialogPresentationActive(true)
    let prompt = mobileWorkspaceDialog(runtimeID: tab.runtimeID, kind: .prompt(defaultText: "Initial"))
    engine.onEvent?(.javaScriptDialogRequested(prompt))
    #expect(workspace.javaScriptDialog == prompt)
    engine.onEvent?(.javaScriptDialogRequested(prompt))
    #expect(engine.dialogResponses.isEmpty, "A duplicate request cannot consume its live token")

    let overlapping = mobileWorkspaceDialog(runtimeID: tab.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(overlapping))
    #expect(engine.dialogResponses.count == 1)
    #expect(engine.dialogResponses.last?.id == overlapping.id)
    #expect(engine.dialogResponses.last?.response == .cancel)
    #expect(workspace.javaScriptDialog == prompt)
    engine.onEvent?(.javaScriptDialogFinished(id: UUID()))
    workspace.resolveJavaScriptDialog(id: overlapping.id, response: .accept(text: nil))
    #expect(workspace.javaScriptDialog == prompt && engine.dialogResponses.count == 1)
    #expect(await workspace.flushPersistence())
    #expect(try Data(contentsOf: f.url) == baseline, "A visible prompt never writes its token, text or response")

    workspace.resolveJavaScriptDialog(id: prompt.id, response: .accept(text: ""))
    #expect(workspace.javaScriptDialog == nil)
    #expect(engine.dialogResponses.last?.id == prompt.id)
    #expect(engine.dialogResponses.last?.response == .accept(text: ""), "Empty prompt input differs from Cancel")
    workspace.resolveJavaScriptDialog(id: prompt.id, response: .cancel)
    #expect(engine.dialogResponses.count == 2)
    let next = mobileWorkspaceDialog(runtimeID: tab.runtimeID, kind: .alert)
    engine.onEvent?(.javaScriptDialogRequested(next))
    engine.onEvent?(.javaScriptDialogFinished(id: prompt.id))
    #expect(workspace.javaScriptDialog == next)
    engine.onEvent?(.javaScriptDialogFinished(id: next.id))
    #expect(workspace.javaScriptDialog == nil && engine.dialogResponses.count == 2)
    #expect(await workspace.flushPersistence())
    #expect(try Data(contentsOf: f.url) == baseline)
    #expect(await workspace.shutdown())

    let reopened = BrowserMobileWorkspace(
        engine: MobileWorkspaceEngine(), store: BrowserMobileFileSessionStore(fileURL: f.url),
    )
    await reopened.restore()
    #expect(reopened.javaScriptDialog == nil)
    #expect(reopened.selectedTab?.id == tab.id && reopened.selectedTab?.urlString == tab.urlString)
    #expect(await reopened.shutdown())
}

@MainActor @Test func mobileJavaScriptDialogsRequireActiveSelectedRuntimeAndCancelAcrossTabLifecycle() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    workspace.setJavaScriptDialogPresentationActive(true)
    let beforeRestore = mobileWorkspaceDialog(runtimeID: "not-created")
    engine.onEvent?(.javaScriptDialogRequested(beforeRestore))
    #expect(workspace.javaScriptDialog == nil && engine.dialogResponses.last?.response == .cancel)
    await workspace.restore()
    let first = try #require(workspace.selectedTab)
    workspace.newTab()
    let second = try #require(workspace.selectedTab)
    for runtimeID in ["unknown", first.runtimeID] {
        let rejected = mobileWorkspaceDialog(runtimeID: runtimeID)
        engine.onEvent?(.javaScriptDialogRequested(rejected))
        #expect(workspace.javaScriptDialog == nil)
        #expect(engine.dialogResponses.last?.id == rejected.id && engine.dialogResponses.last?.response == .cancel)
    }

    let selected = mobileWorkspaceDialog(runtimeID: second.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(selected))
    #expect(workspace.javaScriptDialog == selected)
    workspace.selectTab(id: first.id)
    #expect(workspace.javaScriptDialog == nil)
    #expect(engine.dialogResponses.last?.id == selected.id && engine.dialogResponses.last?.response == .cancel)
    let countAfterSwitch = engine.dialogResponses.count
    workspace.resolveJavaScriptDialog(id: selected.id, response: .accept(text: nil))
    #expect(engine.dialogResponses.count == countAfterSwitch)

    let oldTab = mobileWorkspaceDialog(runtimeID: first.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(oldTab))
    workspace.newTab()
    #expect(engine.dialogResponses.last?.id == oldTab.id && engine.dialogResponses.last?.response == .cancel)
    let third = try #require(workspace.selectedTab)
    let closing = mobileWorkspaceDialog(runtimeID: third.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(closing))
    workspace.closeTab(id: third.id)
    #expect(workspace.javaScriptDialog == nil && !workspace.tabs.contains { $0.id == third.id })
    #expect(engine.dialogResponses.last?.id == closing.id && engine.dialogResponses.last?.response == .cancel)

    let current = try #require(workspace.selectedTab)
    let disappearing = mobileWorkspaceDialog(runtimeID: current.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(disappearing))
    workspace.setJavaScriptDialogPresentationActive(false)
    #expect(!engine.dialogPresentationActive && workspace.javaScriptDialog == nil)
    #expect(engine.dialogResponses.last?.id == disappearing.id && engine.dialogResponses.last?.response == .cancel)
    let inactive = mobileWorkspaceDialog(runtimeID: current.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(inactive))
    #expect(workspace.javaScriptDialog == nil && engine.dialogResponses.last?.id == inactive.id)
    #expect(engine.dialogResponses.last?.response == .cancel)

    workspace.setJavaScriptDialogPresentationActive(true)
    let shuttingDown = mobileWorkspaceDialog(runtimeID: current.runtimeID)
    engine.onEvent?(.javaScriptDialogRequested(shuttingDown))
    #expect(workspace.javaScriptDialog == shuttingDown)
    #expect(await workspace.shutdown())
    #expect(workspace.javaScriptDialog == nil && !engine.dialogPresentationActive)
    #expect(engine.dialogResponses.last?.id == shuttingDown.id && engine.dialogResponses.last?.response == .cancel)
    #expect(engine.onEvent == nil && engine.shutdownCount == 1)
    let countAfterShutdown = engine.dialogResponses.count
    workspace.resolveJavaScriptDialog(id: shuttingDown.id, response: .accept(text: nil))
    workspace.setJavaScriptDialogPresentationActive(true)
    #expect(!engine.dialogPresentationActive && engine.dialogResponses.count == countAfterShutdown)
}

private func mobileWorkspaceDialog(
    runtimeID: String, kind: BrowserMobileJavaScriptDialog.Kind = .confirm,
) -> BrowserMobileJavaScriptDialog {
    BrowserMobileJavaScriptDialog(
        id: UUID(), runtimeID: runtimeID, origin: "https://example.com", message: "Page message", kind: kind,
    )
}

@MainActor @Test(arguments: [false, true])
func mobileChangedURLClearsPreviousTitleThroughFailureAndFileReopen(engineReported: Bool) async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    await workspace.restore()
    workspace.submit("https://example.com/titled")
    let tab = try #require(workspace.selectedTab)
    engine.emitState(id: tab.runtimeID, url: "https://example.com/titled", title: "Previous title")
    #expect(workspace.selectedTab?.title == "Previous title")
    let nextURL = try #require(URL(string: "https://example.com/untitled"))
    if engineReported {
        engine.onEvent?(.state(id: tab.runtimeID, .init(url: nextURL, isLoading: true)))
    } else {
        workspace.submit(nextURL.absoluteString)
    }
    #expect(workspace.selectedTab?.title == "")
    engine.onEvent?(.state(id: tab.runtimeID, .init(url: nextURL, error: "Cannot load page")))
    #expect(workspace.selectedTab?.title == "")
    #expect(await workspace.shutdown())

    let reopened = BrowserMobileWorkspace(
        engine: MobileWorkspaceEngine(), store: BrowserMobileFileSessionStore(fileURL: f.url),
    )
    await reopened.restore()
    #expect(reopened.selectedTab?.id == tab.id)
    #expect(reopened.selectedTab?.urlString == nextURL.absoluteString)
    #expect(reopened.selectedTab?.title == "")
    #expect(await reopened.shutdown())
}

@MainActor @Test func mobileSessionReopensStableIDsOrderSelectionAndLatestURL() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    await workspace.restore()
    try #require(workspace.isReady && workspace.tabs.count == 1)
    let first = try #require(workspace.selectedTab)
    workspace.submit("example.com/first")
    engine.emitState(id: first.runtimeID, url: "https://example.com/first", title: "First page")
    workspace.newTab()
    let second = try #require(workspace.selectedTab)
    workspace.submit("https://example.com/second")
    workspace.selectTab(id: first.id)
    #expect(await workspace.flushPersistence())
    #expect(workspace.tabs.map(\.id) == [first.id, second.id])
    #expect(workspace.tabs.first?.title == "First page", "Synchronous create events find their logical tab")
    #expect(await workspace.shutdown())

    let nextEngine = MobileWorkspaceEngine()
    let reopened = BrowserMobileWorkspace(engine: nextEngine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    await reopened.restore()
    #expect(reopened.tabs.map(\.id) == [first.id, second.id])
    #expect(reopened.selectedTabID == first.id)
    #expect(reopened.tabs.map(\.urlString) == ["https://example.com/first", "https://example.com/second"])
    #expect(reopened.tabs.first?.title == "First page")
    #expect(Set(reopened.tabs.map(\.runtimeID)).isDisjoint(with: [first.runtimeID, second.runtimeID]))
    #expect(nextEngine.selectedID == reopened.selectedTab?.runtimeID)
    #expect(await reopened.shutdown())
}

@MainActor @Test func mobileFailedSaveKeepsLatestEditsAndRetryAtomicallyReplacesOldFile() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let store = ControlledMobileStore(fileURL: f.url)
    let workspace = BrowserMobileWorkspace(engine: MobileWorkspaceEngine(), store: store)
    await workspace.restore()
    #expect(await workspace.flushPersistence())
    let originalBytes = try Data(contentsOf: f.url)
    await store.setFailure(true)
    workspace.submit("https://example.com/first-edit")
    #expect(await !workspace.flushPersistence())
    #expect(workspace.sessionError != nil && workspace.isReady)
    workspace.submit("https://example.com/latest-edit")
    workspace.newTab()
    workspace.submit("https://example.com/second-tab")
    #expect(await !workspace.flushPersistence())
    #expect(try Data(contentsOf: f.url) == originalBytes)
    let stableIDs = workspace.tabs.map(\.id)
    await store.setFailure(false)
    #expect(await workspace.retryPersistence())
    #expect(workspace.sessionError == nil)
    let saved = try await BrowserMobileFileSessionStore(fileURL: f.url).load()
    #expect(saved?.tabs.map(\.id) == stableIDs)
    #expect(saved?.tabs.map(\.urlString) == ["https://example.com/latest-edit", "https://example.com/second-tab"])
    #expect(saved?.selectedTabID == workspace.selectedTabID)
    #expect(await workspace.shutdown())
}

@MainActor @Test func mobileSerializedSavesCoalesceLatestSnapshotWithoutOvertakingInFlightWrite() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let store = ControlledMobileStore(fileURL: f.url)
    let workspace = BrowserMobileWorkspace(engine: MobileWorkspaceEngine(), store: store)
    await workspace.restore()
    #expect(await workspace.flushPersistence())
    await store.holdNextSave()
    workspace.submit("https://example.com/in-flight")
    await store.waitForHeldSave()
    workspace.submit("https://example.com/skipped-intermediate")
    workspace.submit("https://example.com/latest")
    await store.releaseSave()
    #expect(await workspace.flushPersistence())
    let writes = await store.savedSessions()
    #expect(writes.suffix(2).compactMap { $0.tabs.first?.urlString } == [
        "https://example.com/in-flight", "https://example.com/latest",
    ])
    #expect(await store.maximumConcurrentSaves() == 1)
    let saved = try await BrowserMobileFileSessionStore(fileURL: f.url).load()
    #expect(saved?.tabs.first?.urlString == "https://example.com/latest")
    #expect(await workspace.shutdown())
}

@MainActor @Test(arguments: [false, true])
func mobileCorruptOrUnknownVersionRemainsIntactUntilSuccessfulRestoreRetry(unknownVersion: Bool) async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let bytes = unknownVersion
        ? try JSONEncoder().encode(BrowserMobileSession(version: 99, tabs: [], selectedTabID: nil))
        : Data("{invalid-session".utf8)
    try bytes.write(to: f.url)
    let store = BrowserMobileFileSessionStore(fileURL: f.url)
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: store)
    await workspace.restore()
    #expect(!workspace.isReady && !workspace.isRestoring && workspace.sessionError != nil)
    workspace.newTab()
    workspace.submit("example.com")
    #expect(workspace.tabs.isEmpty && engine.createdIDs.isEmpty)
    #expect(await !workspace.retryPersistence())
    #expect(try Data(contentsOf: f.url) == bytes)
    await #expect(throws: BrowserMobileSessionError.restoreRequired) {
        try await store.save(.init(tabs: [], selectedTabID: nil))
    }
    #expect(try Data(contentsOf: f.url) == bytes)

    let repaired = BrowserMobileSession(
        tabs: [.init(id: "preserved", urlString: "https://example.com/recovered", title: "Saved")],
        selectedTabID: "preserved",
    )
    try JSONEncoder().encode(repaired).write(to: f.url, options: .atomic)
    #expect(await workspace.retryPersistence())
    #expect(workspace.selectedTabID == "preserved" && workspace.selectedTab?.title == "Saved")
    #expect(await workspace.shutdown())
}

@MainActor @Test func mobilePopupsAdoptOneStableIdentityAndClosedRuntimeEventsAreIgnored() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    await workspace.restore()
    let original = try #require(workspace.selectedTab)
    let popupURL = try #require(URL(string: "https://example.com/popup"))
    engine.onPopupCreated?("popup-runtime", popupURL)
    let popup = try #require(workspace.selectedTab)
    #expect(popup.runtimeID == "popup-runtime" && popup.id != original.id)
    engine.emitState(id: popup.runtimeID, url: "https://example.com/popup", title: "Popup")
    engine.onPopupCreated?("popup-runtime", popupURL)
    #expect(workspace.tabs.count == 2 && workspace.selectedTab?.title == "Popup")
    workspace.closeTab(id: popup.id)
    engine.emitState(id: popup.runtimeID, url: "https://example.com/late", title: "Must not return")
    engine.onEvent?(.closed(id: popup.runtimeID))
    #expect(workspace.tabs.map(\.id) == [original.id] && workspace.selectedTabID == original.id)
    workspace.closeTab(id: original.id)
    #expect(workspace.tabs.count == 1 && workspace.selectedTab?.urlString == "about:blank")
    #expect(workspace.selectedTabID != original.id)
    #expect(await workspace.shutdown())
    let saved = try await BrowserMobileFileSessionStore(fileURL: f.url).load()
    #expect(saved?.tabs.count == 1 && saved?.tabs.first?.urlString == "about:blank")
}

@MainActor @Test func mobileNavigationUsesSharedResolverRejectsUnsupportedSchemesAndControlsSelectedRuntime(
) async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: BrowserMobileFileSessionStore(fileURL: f.url))
    await workspace.restore()
    for input in ["openarc://settings", "file:///tmp/example", "mailto:me@example.com", "javascript:alert(1)"] {
        workspace.submit(input)
        #expect(workspace.navigationError != nil)
        #expect(workspace.selectedTab?.urlString == "about:blank")
    }
    #expect(engine.navigatedURLs.isEmpty)
    workspace.submit("example.com")
    #expect(workspace.selectedTab?.urlString == "https://example.com" && workspace.navigationError == nil)
    workspace.submit("two words")
    #expect(workspace.selectedTab?.urlString.contains("google.com/search?q=two%20words") == true)
    let tab = try #require(workspace.selectedTab)
    engine.onEvent?(.state(id: tab.runtimeID, .init(
        url: URL(string: tab.urlString),
        isLoading: true,
        canGoBack: true,
        canGoForward: true,
    )))
    workspace.goBack()
    workspace.goForward()
    workspace.reloadOrStop()
    engine.onEvent?(.state(id: tab.runtimeID, .init(url: URL(string: tab.urlString))))
    workspace.reloadOrStop()
    #expect(engine.commands == [
        "back:\(tab.runtimeID)",
        "forward:\(tab.runtimeID)",
        "stop:\(tab.runtimeID)",
        "reload:\(tab.runtimeID)",
    ])
    #expect(await workspace.shutdown())
}

@MainActor @Test func mobileShutdownDuringRestoreDoesNotCreateTabsOrOverwriteSession() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let initial = BrowserMobileSession(
        tabs: [.init(id: "saved", urlString: "https://example.com/", title: "")],
        selectedTabID: "saved",
    )
    let bytes = try JSONEncoder().encode(initial)
    try bytes.write(to: f.url)
    let store = ControlledMobileStore(fileURL: f.url)
    await store.holdNextLoad()
    let engine = MobileWorkspaceEngine()
    let workspace = BrowserMobileWorkspace(engine: engine, store: store)
    let restore = Task { await workspace.restore() }
    await store.waitForHeldLoad()
    #expect(workspace.isRestoring)
    _ = await workspace.shutdown()
    await store.releaseLoad()
    await restore.value
    workspace.newTab()
    #expect(!workspace.isReady && workspace.tabs.isEmpty && engine.createdIDs.isEmpty)
    #expect(engine.shutdownCount == 1)
    #expect(try Data(contentsOf: f.url) == bytes)
}

@MainActor @Test func mobileSwitcherListsTabsOldestFirstByLastSelection() async throws {
    let f = MobileWorkspaceFixture()
    defer { f.cleanup() }
    let workspace = BrowserMobileWorkspace(
        engine: MobileWorkspaceEngine(), store: BrowserMobileFileSessionStore(fileURL: f.url),
    )
    await workspace.restore()
    workspace.submit("https://one.example/")
    let first = try #require(workspace.selectedTabID)
    workspace.submitInNewTab("https://two.example/")
    let second = try #require(workspace.selectedTabID)
    workspace.submitInNewTab("https://three.example/")
    let third = try #require(workspace.selectedTabID)
    #expect(Set([first, second, third]).count == 3, "A loaded tab opens new pages in new tabs")
    #expect(workspace.switcherTabs.map(\.id) == [first, second, third])

    workspace.selectTab(id: first)
    #expect(workspace.switcherTabs.map(\.id) == [second, third, first], "The selected tab moves to the newest end")
    #expect(workspace.recentTabIDs.prefix(3) == [first, third, second])
}

// MARK: - MobileWorkspaceFixture

private struct MobileWorkspaceFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-workspace-\(UUID())")

    var url: URL { directory.appendingPathComponent("session.json") }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - MobileWorkspaceEngine

@MainActor private final class MobileWorkspaceEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var createdIDs = [String]()
    var navigatedURLs = [URL]()
    var selectedID: String?
    var commands = [String]()
    var shutdownCount = 0
    var dialogPresentationActive = false
    var dialogResponses = [(id: UUID, response: BrowserMobileJavaScriptDialogResponse)]()

    func createTab(id: String, url: URL) {
        createdIDs.append(id)
        onEvent?(.state(id: id, .init(url: url)))
    }

    func selectTab(id: String?) { selectedID = id }
    func navigate(id: String, url: URL) {
        navigatedURLs.append(url)
        onEvent?(.state(id: id, .init(url: url, isLoading: true)))
    }

    func goBack(id: String) { commands.append("back:\(id)") }
    func goForward(id: String) { commands.append("forward:\(id)") }
    func reload(id: String) { commands.append("reload:\(id)") }
    func stop(id: String) { commands.append("stop:\(id)") }
    func closeTab(id: String) { onEvent?(.closed(id: id)) }
    func setJavaScriptDialogPresentationActive(_ active: Bool) { dialogPresentationActive = active }
    func resolveJavaScriptDialog(id: UUID, response: BrowserMobileJavaScriptDialogResponse) {
        dialogResponses.append((id, response))
        onEvent?(.javaScriptDialogFinished(id: id))
    }

    func shutdown() { shutdownCount += 1 }
    func emitState(id: String, url: String, title: String) {
        onEvent?(.state(id: id, .init(url: URL(string: url), title: title)))
    }
}

// MARK: - ControlledMobileStore

private actor ControlledMobileStore: BrowserMobileSessionStoring {
    // MARK: Private

    private let file: BrowserMobileFileSessionStore
    private var fails = false
    private var shouldHoldSave = false
    private var shouldHoldLoad = false
    private var saveRelease: CheckedContinuation<Void, Never>?
    private var loadRelease: CheckedContinuation<Void, Never>?
    private var saveWaiters = [CheckedContinuation<Void, Never>]()
    private var loadWaiters = [CheckedContinuation<Void, Never>]()
    private var sessions = [BrowserMobileSession]()
    private var activeSaves = 0
    private var maximumSaves = 0

    init(fileURL: URL) { self.file = BrowserMobileFileSessionStore(fileURL: fileURL) }

    // MARK: Internal

    func load() async throws -> BrowserMobileSession? {
        if shouldHoldLoad {
            shouldHoldLoad = false
            await withCheckedContinuation { continuation in
                loadRelease = continuation
                loadWaiters.forEach { $0.resume() }
                loadWaiters.removeAll()
            }
        }
        return try await file.load()
    }

    func save(_ session: BrowserMobileSession) async throws {
        activeSaves += 1
        maximumSaves = max(maximumSaves, activeSaves)
        defer { activeSaves -= 1 }
        if shouldHoldSave {
            shouldHoldSave = false
            await withCheckedContinuation { continuation in
                saveRelease = continuation
                saveWaiters.forEach { $0.resume() }
                saveWaiters.removeAll()
            }
        }
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await file.save(session)
        sessions.append(session)
    }

    func setFailure(_ value: Bool) { fails = value }
    func holdNextSave() { shouldHoldSave = true }
    func holdNextLoad() { shouldHoldLoad = true }
    func waitForHeldSave() async {
        if saveRelease != nil {
            return
        }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    func waitForHeldLoad() async {
        if loadRelease != nil {
            return
        }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func releaseSave() { let continuation = saveRelease
        saveRelease = nil
        continuation?.resume()
    }

    func releaseLoad() { let continuation = loadRelease
        loadRelease = nil
        continuation?.resume()
    }

    func savedSessions() -> [BrowserMobileSession] { sessions }
    func maximumConcurrentSaves() -> Int { maximumSaves }
}
