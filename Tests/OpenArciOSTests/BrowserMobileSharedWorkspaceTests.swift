import Foundation
import Testing
import UIKit

// MARK: - BrowserMobileSharedWorkspaceTests

@Suite(.serialized)
@MainActor struct BrowserMobileSharedWorkspaceTests {
    @Test func independentScenesShareActionsAndKeepSelectionAndRuntimeIdentity() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "c")
        let firstIDs = first.workspace.tabs.map(\.runtimeID), secondIDs = second.workspace.tabs.map(\.runtimeID)
        #expect(Set(firstIDs).isDisjoint(with: secondIDs))
        let writes = f.store.writes.count
        #expect(f.document.renameTab(id: "a", title: "Shared name"))
        #expect(first.workspace.tabs.first { $0.id == "a" }?.userTitleOverride == "Shared name")
        #expect(second.workspace.tabs.first { $0.id == "a" }?.userTitleOverride == "Shared name")
        #expect(first.workspace.selectedTabID == "a" && second.workspace.selectedTabID == "c")
        #expect(first.workspace.selectedSpaceID == "source" && second.workspace.selectedSpaceID == "target")
        #expect(first.workspace.tabs.map(\.runtimeID) == firstIDs)
        #expect(second.workspace.tabs.map(\.runtimeID) == secondIDs)
        #expect(f.store.writes.count == writes + 1)
        let selections = f.store.writes.count
        first.workspace.selectSpace(id: "target")
        first.workspace.selectTab(id: "c")
        #expect(f.store.writes.count == selections, "Scene selection is not a shared snapshot write")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func remoteMetadataAndOrderKeepLiveHistoryWithoutNavigationOrReplacement() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "b")
        let a = try #require(first.workspace.selectedTab)
        first.engine.emit(
            id: a.runtimeID,
            state: .init(url: URL(string: a.urlString), title: "Live page", canGoBack: true)
        )
        let firstIDs = Dictionary(uniqueKeysWithValues: first.workspace.tabs.map { ($0.id, $0.runtimeID) })
        let secondIDs = Dictionary(uniqueKeysWithValues: second.workspace.tabs.map { ($0.id, $0.runtimeID) })
        let loads = (first.engine.loads.count, second.engine.loads.count)
        let current = f.document.snapshot
        let reversed = current.tabs.reversed().map { tab in
            BrowserTabSessionSnapshotTab(
                id: tab.id,
                urlString: tab.urlString,
                pinnedURLString: tab.pinnedURLString,
                userTitleOverride: tab.id == "a" ? "Remote name" : tab.userTitleOverride,
                placement: tab.placement,
                spaceID: tab.spaceID,
                pinnedFolderID: tab.pinnedFolderID,
                lastActivityTimestamp: tab.lastActivityTimestamp,
                pinnedSiblingRank: tab.pinnedSiblingRank
            )
        }
        let writes = f.store.writes.count
        try f.remote(.init(spaces: current.spaces, pinnedTabFolders: current.pinnedTabFolders, tabs: reversed))
        #expect(first.workspace.tabs.map(\.id) == reversed.compactMap(\.id))
        #expect(first.engine.loads.count == loads.0 && second.engine.loads.count == loads.1)
        #expect(Dictionary(uniqueKeysWithValues: first.workspace.tabs.map { ($0.id, $0.runtimeID) }) == firstIDs)
        #expect(Dictionary(uniqueKeysWithValues: second.workspace.tabs.map { ($0.id, $0.runtimeID) }) == secondIDs)
        #expect(first.workspace.selectedTab?.state.canGoBack == true)
        #expect(first.workspace.selectedTabID == "a" && second.workspace.selectedTabID == "b")
        #expect(first.workspace.selectedTab?.userTitleOverride == "Remote name")
        #expect(f.store.writes.count == writes + 1, "Only the incoming committed projection writes")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func deletingFromOneSceneClosesOtherRuntimeAndLateCallbacksCannotResurrect() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        let oldFirst = try #require(first.workspace.tabs.first { $0.id == "a" })
        let oldSecond = try #require(second.workspace.tabs.first { $0.id == "a" })
        first.workspace.closeTab(id: "a")
        #expect(!first.workspace.tabs.contains { $0.id == "a" })
        #expect(!second.workspace.tabs.contains { $0.id == "a" })
        #expect(first.engine.closed.contains(oldFirst.runtimeID) && second.engine.closed.contains(oldSecond.runtimeID))
        let writes = f.store.writes.count
        first.engine.onEvent?(.state(id: oldFirst.runtimeID, .init(url: URL(string: "https://example.com/stale"))))
        second.engine.onEvent?(.closed(id: oldSecond.runtimeID))
        #expect(!f.document.snapshot.tabs.contains { $0.id == "a" })
        #expect(f.store.writes.count == writes)
        for id in f.document.snapshot.tabs.compactMap(\.id) {
            f.document.removeTab(id: id)
        }
        #expect(f.document.snapshot.tabs.isEmpty && first.workspace.tabs.isEmpty && second.workspace.tabs.isEmpty)
        #expect(first.workspace.selectedTabID == nil && second.workspace.selectedTabID == nil)
        #expect(first.engine.created.count == 4 && second.engine.created.count == 4, "No replacement blank page")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func unsupportedDesktopRecordIsDurableWithoutEngineAndCanBeOpenedOnceAfterAddressChange() async throws {
        let f = try SharedWorkspaceFixture(unsupported: true)
        defer { f.cleanup() }
        let scene = f.workspace("first")
        await scene.workspace.restore()
        scene.workspace.selectTab(id: "desktop")
        let unsupported = try #require(scene.workspace.selectedTab)
        #expect(unsupported.state.error != nil && scene.engine.selected == nil)
        #expect(!scene.engine.created.contains { $0.id == unsupported.runtimeID })
        #expect(try f.sqlite.loadSnapshotStrict()?.tabs.first { $0.id == "desktop" }?.urlString == "openarc://settings")
        let loads = scene.engine.loads.count
        scene.workspace.submit("https://example.com/recovered")
        #expect(scene.workspace.selectedTabID == "desktop")
        #expect(f.document.snapshot.tabs.first { $0.id == "desktop" }?.urlString == "https://example.com/recovered")
        #expect(scene.engine.created.filter { $0.id == unsupported.runtimeID }.count == 1)
        #expect(
            scene.engine.loads.count == loads + 1,
            "The newly selected runtime must not load the submitted URL twice"
        )
        #expect(await scene.workspace.shutdown())
    }

    @Test func ownSubmitAndPopupAdoptionReuseOneRuntimeAndPropagateToSecondScene() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        let runtime = try #require(first.workspace.selectedTab?.runtimeID)
        let created = first.engine.created.count, loads = first.engine.loads.count
        first.workspace.submit("https://example.com/typed")
        #expect(first.workspace.selectedTab?.runtimeID == runtime && first.engine.created.count == created)
        #expect(first.engine.loads.count == loads + 1)
        #expect(second.workspace.tabs.first { $0.id == "a" }?.urlString == "https://example.com/typed")
        let repeatedLoads = first.engine.loads.count, repeatedWrites = f.store.writes.count
        first.workspace.submit("https://example.com/typed")
        #expect(first.engine.loads.count == repeatedLoads + 1)
        #expect(f.store.writes.count == repeatedWrites, "Submitting the same address only reloads this scene")
        let popupRuntime = "popup-runtime"
        try first.engine.adoptPopup(id: popupRuntime, url: #require(URL(string: "https://example.com/popup")))
        let popup = try #require(first.workspace.tabs.first { $0.runtimeID == popupRuntime })
        #expect(first.workspace.selectedTabID == popup.id)
        #expect(first.engine.created.count == created, "WebKit already supplied the popup runtime")
        #expect(f.document.snapshot.tabs.filter { $0.id == popup.id }.count == 1)
        let otherPopup = try #require(second.workspace.tabs.first { $0.id == popup.id })
        #expect(otherPopup.runtimeID != popupRuntime)
        #expect(second.engine.created.filter { $0.id == otherPopup.runtimeID }.count == 1)
        first.engine.onPopupCreated?(popupRuntime, URL(string: "https://example.com/popup"))
        #expect(f.document.snapshot.tabs.filter { $0.id == popup.id }.count == 1)
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func rejectedSubmitDoesNotNavigateBeyondTheBoundedPersistenceBuffer() async throws {
        let f = try SharedWorkspaceFixture(maximumBufferedWrites: 1)
        defer { f.cleanup() }
        let scene = f.workspace("first")
        await scene.workspace.restore()
        scene.workspace.selectTab(id: "a")
        f.store.fails = true
        #expect(f.document.renameTab(id: "a", title: "Retained failed action"))
        #expect(f.document.hasUncommittedWrites && f.document.canEdit)
        let oldURL = scene.workspace.selectedTab?.urlString, loads = scene.engine.loads.count
        scene.workspace.submit("https://example.com/unretained")
        #expect(f.document.persistenceFailure?.reason == .bufferLimitExceeded)
        #expect(scene.workspace.selectedTab?.urlString == oldURL)
        #expect(f.document.snapshot.tabs.first { $0.id == "a" }?.urlString == oldURL)
        #expect(scene.engine.loads.count == loads)
        #expect(scene.workspace.sessionError != nil)
        #expect(await scene.workspace.shutdown() == false)
    }

    @Test(arguments: [BrowserTabPlacement.spacePinned, .app], [false, true])
    func persistentCloseUnloadsOnlyThisSceneAndReopensWithFreshRuntime(
        placement: BrowserTabPlacement, fromEngine: Bool
    ) async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let owner = try BrowserSyncOwner(baseURL: #require(URL(string: "https://sync.example")), userID: "owner")
        try f.sqlite.bindSyncOwner(owner)
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        #expect(f.document.setPlacement(tabID: "a", placement: placement))
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "a")
        let tab = try #require(first.workspace.selectedTab), other = try #require(second.workspace.selectedTab)
        let document = f.document.snapshot, writes = f.store.writes.count
        let queue = try f.sqlite.pendingSyncQueue(for: owner), otherLoads = second.engine.loads.count
        if fromEngine {
            first.engine.closeTab(id: tab.runtimeID)
        } else {
            first.workspace.closeTab(id: "a")
        }
        #expect(f.document.snapshot == document && f.store.writes.count == writes)
        #expect(try f.sqlite.pendingSyncQueue(for: owner) == queue)
        #expect(first.workspace.tabs.contains { $0.id == "a" })
        #expect(first.engine.closed.contains(tab.runtimeID))
        #expect(second.workspace.selectedTab?.runtimeID == other.runtimeID)
        #expect(second.engine.closed.isEmpty && second.engine.loads.count == otherLoads)
        let closedRow = try #require(first.workspace.tabs.first { $0.id == "a" })
        let creations = first.engine.created.count, loads = first.engine.loads.count
        #expect(f.document.renameSpace(id: "source", title: "Unrelated rename"))
        #expect(f.document.move(
            items: [.init(entityType: .space, entityID: "source")],
            destination: .spaces,
            after: .init(entityType: .space, entityID: "target")
        ))
        #expect(first.engine.created.count == creations && first.engine.loads.count == loads)
        #expect(!first.engine.created.contains { $0.id == closedRow.runtimeID })
        let beforeSelect = f.store.writes.count
        first.workspace.selectTab(id: "a")
        let reopened = try #require(first.workspace.selectedTab)
        #expect(reopened.id == "a" && reopened.runtimeID != tab.runtimeID)
        #expect(first.engine.created.filter { $0.id == reopened.runtimeID }.count == 1)
        #expect(first.engine.loads.filter { $0.id == reopened.runtimeID }.count == 1)
        #expect(f.store.writes.count == beforeSelect)
        #expect(second.workspace.selectedTab?.runtimeID == other.runtimeID)
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func clearingUserTitleRestoresTheCurrentPageTitleInBothScenes() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "a")
        let a = try #require(first.workspace.selectedTab), b = try #require(second.workspace.selectedTab)
        first.engine.emit(id: a.runtimeID, state: .init(url: URL(string: a.urlString), title: "First page title"))
        second.engine.emit(id: b.runtimeID, state: .init(url: URL(string: b.urlString), title: "Second page title"))
        #expect(f.document.renameTab(id: "a", title: "Custom title"))
        #expect(first.workspace.selectedTab?.userTitleOverride == "Custom title")
        #expect(second.workspace.selectedTab?.userTitleOverride == "Custom title")
        #expect(first.workspace.selectedTab?.title == "First page title")
        #expect(second.workspace.selectedTab?.title == "Second page title")
        #expect(f.document.renameTab(id: "a", title: nil))
        #expect(first.workspace.selectedTab?.userTitleOverride == nil)
        #expect(second.workspace.selectedTab?.userTitleOverride == nil)
        #expect(first.workspace.selectedTab?.title == "First page title")
        #expect(second.workspace.selectedTab?.title == "Second page title")
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func closingOneSceneAndReopeningRetainsSharedDocumentAndIndependentSelection() async throws {
        let f = try SharedWorkspaceFixture()
        defer { f.cleanup() }
        let first = f.workspace("first"), second = f.workspace("second")
        await first.workspace.restore()
        await second.workspace.restore()
        first.workspace.selectTab(id: "a")
        second.workspace.selectTab(id: "c")
        let firstRuntimeIDs = Set(first.workspace.tabs.map(\.runtimeID))
        let secondRuntimeIDs = second.workspace.tabs.map(\.runtimeID)
        let writes = f.store.writes.count
        #expect(await first.workspace.shutdown())
        #expect(f.store.writes.count == writes && second.engine.shutdownCount == 0)
        #expect(f.document.renameTab(id: "a", title: "While first scene disconnected"))
        #expect(second.workspace.selectedTabID == "c" && second.workspace.tabs.map(\.runtimeID) == secondRuntimeIDs)
        let reopened = f.workspace("first")
        await reopened.workspace.restore()
        #expect(reopened.workspace.selectedTabID == "a" && reopened.workspace.selectedSpaceID == "source")
        #expect(Set(reopened.workspace.tabs.map(\.runtimeID)).isDisjoint(with: firstRuntimeIDs))
        #expect(reopened.workspace.selectedTab?.userTitleOverride == "While first scene disconnected")
        #expect(reopened.workspace.tabs.map(\.id) == second.workspace.tabs.map(\.id))
        #expect(await reopened.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }
}

// MARK: - SharedWorkspaceFixture

@MainActor private final class SharedWorkspaceFixture {
    // MARK: Lifecycle

    init(unsupported: Bool = false, maximumBufferedWrites: Int = 32) throws {
        self.preferences = try #require(UserDefaults(suiteName: suite))
        self.sqlite = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        self.store = SharedWorkspaceStore(sqlite)
        var tabs = [
            BrowserTabSessionSnapshotTab(id: "a", urlString: "https://example.com/a", spaceID: "source"),
            .init(id: "b", urlString: "https://example.com/b", spaceID: "source"),
            .init(id: "c", urlString: "https://example.com/c", spaceID: "target"),
            .init(id: "favorite", urlString: "https://example.com/favorite", placement: .app, spaceID: "source"),
        ]
        if unsupported {
            tabs.append(.init(
                id: "desktop",
                urlString: "openarc://settings",
                placement: .spacePinned,
                spaceID: "source"
            ))
        }
        let snapshot = BrowserTabSessionSnapshot(spaces: [
            .init(id: "source", title: "Source", systemImageName: "globe"),
            .init(id: "target", title: "Target", systemImageName: "star"),
        ], tabs: tabs)
        let values = Dictionary(uniqueKeysWithValues: BrowserSyncFolderProjection.canonicalChanges(snapshot).map {
            (BrowserSyncOutboxProjection.key($0), $0)
        })
        let canonical = BrowserSyncFolderProjection.snapshot(values: values, local: snapshot)
        try sqlite.writeSessionBatch([.init(snapshot: canonical, origin: .local(syncMove: nil))])
        self.document = try BrowserMobileProfileDocument(
            store: store, initialSnapshot: sqlite.loadSnapshotStrict(), maximumBufferedWrites: maximumBufferedWrites
        )
    }

    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedWorkspace-\(UUID())")
    let suite = "SharedWorkspace.\(UUID())"
    let preferences: UserDefaults
    let sqlite: BrowserSQLiteSessionStore
    let store: SharedWorkspaceStore
    let document: BrowserMobileProfileDocument

    func workspace(_ scene: String) -> (workspace: BrowserMobileWorkspace, engine: SharedWorkspaceEngine) {
        let engine = SharedWorkspaceEngine()
        return (
            BrowserMobileWorkspace(engine: engine, sceneID: scene, profileLoader: { [document] in
                document
            }, preferences: preferences),
            engine
        )
    }

    func remote(_ snapshot: BrowserTabSessionSnapshot) throws {
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .remoteProjection)])
        document.applyRemoteSyncSnapshot(snapshot)
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - SharedWorkspaceStore

private final class SharedWorkspaceStore: BrowserTabSessionSnapshotStoring {
    // MARK: Lifecycle

    init(_ sqlite: BrowserSQLiteSessionStore) { self.sqlite = sqlite }

    // MARK: Internal

    let sqlite: BrowserSQLiteSessionStore
    var writes = [[BrowserSessionWrite]]()
    var fails = false

    func loadSnapshot() -> BrowserTabSessionSnapshot? { sqlite.loadSnapshot() }
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) { sqlite.saveSnapshot(snapshot) }
    func writeSessionBatch(_ writes: [BrowserSessionWrite]) throws {
        if fails {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try sqlite.writeSessionBatch(writes)
        self.writes.append(writes)
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
    var created = [Request](), loads = [Request](), closed = [String]()
    var selected: String?
    var shutdownCount = 0

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

    // MARK: Private

    private var records = [String: URL]()
    private var started = Set<String>()
}
