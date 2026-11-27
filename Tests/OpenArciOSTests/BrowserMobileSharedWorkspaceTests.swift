// BrowserMobileSharedWorkspaceTests.swift

import Foundation
import Testing
import UIKit

// MARK: - BrowserMobileSharedWorkspaceTests

/// Windows of one profile share its mobile tabs; each keeps its own
/// selection and pages.
@Suite(.serialized)
@MainActor struct BrowserMobileSharedWorkspaceTests {
    @Test func independentScenesShareTabsAndKeepSelectionAndRuntimeIdentity() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first")
        let second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "c")
        let firstIDs = first.workspace.tabs.map(\.runtimeID)
        let secondIDs = second.workspace.tabs.map(\.runtimeID)
        #expect(Set(firstIDs).isDisjoint(with: secondIDs))
        let loads = (first.engine.loads.count, second.engine.loads.count)
        #expect(f.document.updateMobileTab(id: "b", urlString: "https://example.com/shared"))
        #expect(first.workspace.tabs.first { $0.id == "b" }?.urlString == "https://example.com/shared")
        #expect(second.workspace.tabs.first { $0.id == "b" }?.urlString == "https://example.com/shared")
        #expect(first.engine.loads.count == loads.0 + 1 && second.engine.loads.count == loads.1 + 1)
        #expect(first.workspace.selectedTabID == "a" && second.workspace.selectedTabID == "c")
        #expect(first.workspace.tabs.map(\.runtimeID) == firstIDs)
        #expect(second.workspace.tabs.map(\.runtimeID) == secondIDs)
        let writes = f.store.writes.count
        first.workspace.selectTab(id: "c")
        #expect(f.store.writes.count == writes, "Selecting a mobile tab never writes Spaces")
        #expect(second.workspace.selectedTabID == "c")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func closingFromOneSceneClosesOtherRuntimeAndLateCallbacksCannotResurrect() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first")
        let second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        let oldFirst = try #require(first.workspace.tabs.first { $0.id == "a" })
        let oldSecond = try #require(second.workspace.tabs.first { $0.id == "a" })
        first.workspace.closeTab(id: "a")
        #expect(!first.workspace.tabs.contains { $0.id == "a" })
        #expect(!second.workspace.tabs.contains { $0.id == "a" })
        #expect(first.engine.closed.contains(oldFirst.runtimeID) && second.engine.closed.contains(oldSecond.runtimeID))
        first.engine.onEvent?(.state(id: oldFirst.runtimeID, .init(url: URL(string: "https://example.com/stale"))))
        second.engine.onEvent?(.closed(id: oldSecond.runtimeID))
        #expect(f.document.mobileTab(id: "a") == nil)
        #expect(try f.sqlite.loadMobileTabs()?.map(\.id) == ["b", "c"])
        for id in f.document.mobileTabs.map(\.id) {
            f.document.closeMobileTab(id: id)
        }
        // A window always holds a tab: the first to notice opens one blank tab for both.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(f.document.mobileTabs.map(\.record.urlString) == ["about:blank"])
        #expect(first.workspace.tabs.map(\.id) == f.document.mobileTabs.map(\.id))
        #expect(second.workspace.tabs.map(\.id) == f.document.mobileTabs.map(\.id))
        #expect(first.workspace.selectedTabID == f.document.mobileTabs.first?.id)
        #expect(f.store.writes.isEmpty, "Mobile tabs never touch Spaces")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func unsupportedSyncedAddressShowsAnErrorWithoutEngineAndOpensOnceAfterAddressChange() async throws {
        let f = try SharedWorkspaceFixture(unsupported: true)
        defer { f.cleanup() }
        let scene = f.workspace("first")
        await scene.workspace.restore()
        scene.workspace.selectTab(id: "desktop")
        let unsupported = try #require(scene.workspace.selectedTab)
        #expect(unsupported.state.error != nil && scene.engine.selected == nil)
        #expect(!scene.engine.created.contains { $0.id == unsupported.runtimeID })
        #expect(try f.sqlite.loadMobileTabs()?.first { $0.id == "desktop" }?.record.urlString == "openarc://settings")
        let loads = scene.engine.loads.count
        scene.workspace.submit("https://example.com/recovered")
        #expect(scene.workspace.selectedTabID == "desktop")
        #expect(f.document.mobileTab(id: "desktop")?.record.urlString == "https://example.com/recovered")
        #expect(scene.engine.created.count(where: { $0.id == unsupported.runtimeID }) == 1)
        #expect(
            scene.engine.loads.count == loads + 1,
            "The newly selected runtime must not load the submitted URL twice",
        )
        #expect(await scene.workspace.shutdown())
    }

    @Test func ownSubmitAndPopupAdoptionReuseOneRuntimeAndPropagateToSecondScene() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first")
        let second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        let runtime = try #require(first.workspace.selectedTab?.runtimeID)
        let created = first.engine.created.count
        let loads = first.engine.loads.count
        first.workspace.submit("https://example.com/typed")
        #expect(first.workspace.selectedTab?.runtimeID == runtime && first.engine.created.count == created)
        #expect(first.engine.loads.count == loads + 1)
        #expect(second.workspace.tabs.first { $0.id == "a" }?.urlString == "https://example.com/typed")
        let repeatedLoads = first.engine.loads.count
        let saved = try f.sqlite.loadMobileTabs()
        first.workspace.submit("https://example.com/typed")
        #expect(first.engine.loads.count == repeatedLoads + 1)
        #expect(try f.sqlite.loadMobileTabs() == saved, "Submitting the same address only reloads this scene")
        let popupRuntime = "popup-runtime"
        try first.engine.adoptPopup(id: popupRuntime, url: #require(URL(string: "https://example.com/popup")))
        let popup = try #require(first.workspace.tabs.first { $0.runtimeID == popupRuntime })
        #expect(first.workspace.selectedTabID == popup.id)
        #expect(first.engine.created.count == created, "WebKit already supplied the popup runtime")
        #expect(f.document.mobileTabs.map(\.id).filter { $0 == popup.id }.count == 1)
        let otherPopup = try #require(second.workspace.tabs.first { $0.id == popup.id })
        #expect(otherPopup.runtimeID != popupRuntime)
        #expect(second.engine.created.count(where: { $0.id == otherPopup.runtimeID }) == 1)
        first.engine.onPopupCreated?(popupRuntime, URL(string: "https://example.com/popup"))
        #expect(f.document.mobileTabs.map(\.id).filter { $0 == popup.id }.count == 1)
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func aFailedSaveKeepsThePageWhereItWasAndSaysSo() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let scene = f.workspace("first")
        await scene.workspace.restore()
        scene.workspace.selectTab(id: "a")
        f.store.fails = true
        let oldURL = scene.workspace.selectedTab?.urlString
        let loads = scene.engine.loads.count
        scene.workspace.submit("https://example.com/unsaved")
        #expect(scene.workspace.selectedTab?.urlString == oldURL)
        #expect(f.document.mobileTab(id: "a")?.record.urlString == oldURL)
        #expect(scene.engine.loads.count == loads)
        #expect(scene.workspace.navigationError == f.document.mobileTabError && scene.workspace.navigationError != nil)
        #expect(scene.workspace.sessionError == nil, "One failed save leaves the window usable")
        f.store.fails = false
        scene.workspace.submit("https://example.com/saved")
        #expect(scene.workspace.selectedTab?.urlString == "https://example.com/saved")
        #expect(scene.workspace.navigationError == nil)
        #expect(await scene.workspace.shutdown())
    }

    @Test func pageTitlesStayPerSceneAndTheSavedTitleFollowsThePage() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first")
        let second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "a")
        let a = try #require(first.workspace.selectedTab)
        let b = try #require(second.workspace.selectedTab)
        first.engine.emit(id: a.runtimeID, state: .init(url: URL(string: a.urlString), title: "First page title"))
        second.engine.emit(id: b.runtimeID, state: .init(url: URL(string: b.urlString), title: "Second page title"))
        #expect(first.workspace.selectedTab?.title == "First page title")
        #expect(second.workspace.selectedTab?.title == "Second page title")
        #expect(f.document.mobileTab(id: "a")?.record.title == "Second page title", "The latest report is saved")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func closingOneSceneAndReopeningRetainsSharedTabsAndIndependentSelection() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first")
        let second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "c")
        let firstRuntimeIDs = Set(first.workspace.tabs.map(\.runtimeID))
        let secondRuntimeIDs = second.workspace.tabs.map(\.runtimeID)
        #expect(await first.workspace.shutdown())
        #expect(second.engine.shutdownCount == 0)
        #expect(f.document.updateMobileTab(id: "a", urlString: "https://example.com/while-away"))
        #expect(second.workspace.selectedTabID == "c" && second.workspace.tabs.map(\.runtimeID) == secondRuntimeIDs)
        let reopened = f.workspace("first")
        await reopened.workspace.restore()
        #expect(reopened.workspace.selectedTabID == "a")
        #expect(Set(reopened.workspace.tabs.map(\.runtimeID)).isDisjoint(with: firstRuntimeIDs))
        #expect(reopened.workspace.selectedTab?.urlString == "https://example.com/while-away")
        #expect(reopened.workspace.tabs.map(\.id) == second.workspace.tabs.map(\.id))
        #expect(await reopened.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }
}

// MARK: - SharedWorkspaceFixture

@MainActor private final class SharedWorkspaceFixture {
    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedWorkspace-\(UUID())")
    let suite = "SharedWorkspace.\(UUID())"
    let preferences: UserDefaults
    let sqlite: BrowserSQLiteSessionStore
    let store: SharedWorkspaceStore
    let document: BrowserMobileProfileDocument

    init(unsupported: Bool = false) throws {
        self.preferences = try #require(UserDefaults(suiteName: suite))
        self.sqlite = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        self.store = SharedWorkspaceStore(sqlite)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        var tabs = ["a", "b", "c"].enumerated().map { offset, id in
            BrowserSyncMobileTabEntry(id: id, record: .init(
                urlString: "https://example.com/" + id, createdAt: created.addingTimeInterval(Double(offset)),
            ))
        }
        if unsupported {
            tabs.append(.init(id: "desktop", record: .init(urlString: "openarc://settings", createdAt: created)))
        }
        try sqlite.saveMobileTabs(tabs)
        self.document = try BrowserMobileProfileDocument(store: store, initialSnapshot: sqlite.loadSnapshotStrict())
    }

    func workspace(_ scene: String) -> (workspace: BrowserMobileWorkspace, engine: SharedWorkspaceEngine) {
        let engine = SharedWorkspaceEngine()
        return (
            BrowserMobileWorkspace(engine: engine, sceneID: scene, profileLoader: { [document] in
                document
            }, preferences: preferences),
            engine,
        )
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - SharedWorkspaceStore

private final class SharedWorkspaceStore: BrowserTabSessionSnapshotStoring, BrowserMobileTabStoring {
    // MARK: Internal

    let sqlite: BrowserSQLiteSessionStore
    var writes = [[BrowserSessionWrite]]()
    var fails = false

    init(_ sqlite: BrowserSQLiteSessionStore) { self.sqlite = sqlite }

    func loadSnapshot() -> BrowserTabSessionSnapshot? { sqlite.loadSnapshot() }
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) { sqlite.saveSnapshot(snapshot) }
    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws {
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try sqlite.writeSessionBatch(writes)
        self.writes.append(writes)
    }

    func loadMobileTabs() throws -> [BrowserSyncMobileTabEntry]? { try sqlite.loadMobileTabs() }
    func loadSyncMobileTabState() throws -> BrowserSyncMobileTabState? { try sqlite.loadSyncMobileTabState() }
    func saveMobileTabs(
        _ tabs: [BrowserSyncMobileTabEntry], operations: [BrowserSyncMobileTabOperation],
        archiving entry: BrowserTabArchiveEntry?, restoringArchiveID: String?,
    ) throws -> Bool {
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return try sqlite.saveMobileTabs(
            tabs, operations: operations, archiving: entry, restoringArchiveID: restoringArchiveID,
        )
    }
}

// MARK: - SharedWorkspaceEngine

@MainActor private final class SharedWorkspaceEngine: BrowserMobileEngine {
    // MARK: Internal

    struct Request { let id: String
        let url: URL
    }

    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var created = [Request]()
    var loads = [Request]()
    var closed = [String]()
    var selected: String?
    var shutdownCount = 0

    // MARK: Private

    private var records = [String: URL]()
    private var started = Set<String>()

    func createTab(id: String, url: URL) {
        created.append(.init(id: id, url: url))
        records[id] = url
        emit(id: id, state: .init(url: url))
    }

    func selectTab(id: String?) {
        selected = id
        if let id, let url = records[id], started.insert(id).inserted {
            loads.append(.init(id: id, url: url))
            emit(id: id, state: .init(url: url, isLoading: true))
        }
    }

    func navigate(id: String, url: URL) {
        guard records[id] != nil else { return }
        records[id] = url
        started.insert(id)
        loads.append(.init(id: id, url: url))
        emit(id: id, state: .init(url: url, isLoading: true))
    }

    func closeTab(id: String) {
        records.removeValue(forKey: id)
        closed.append(id)
        onEvent?(.closed(id: id))
    }

    func emit(id: String, state: BrowserMobilePageState) { onEvent?(.state(id: id, state)) }
    func adoptPopup(id: String, url: URL) {
        records[id] = url
        started.insert(id)
        onPopupCreated?(id, url)
        emit(id: id, state: .init(url: url))
    }

    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() { shutdownCount += 1
        records.removeAll()
    }
}
