import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func nativeSidebarDropQueuesOnlyActedOnTabAndDefersRowsUntilAllTerminals() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        f.workspace.selectTab(id: "b")
        let runtimes = f.workspace.tabs.map(\.runtimeID)
        let selectedRuntime = f.engine.selectedID
        #expect(!f.sidebar.responds(to: NSSelectorFromString("tableView:moveRowAtIndexPath:toIndexPath:")))
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 1, section: 2, fraction: 0.9))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move && proposal.intent == .unspecified)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        #expect(f.todayIDs == ["b", "a", "c"])
        #expect(f.workspace.selectedTabID == "b" && f.engine.selectedID == selectedRuntime)
        #expect(Set(f.workspace.tabs.map(\.runtimeID)) == Set(runtimes))
        #expect(f.engine.closed.isEmpty)
        let mutations = try f.mutations()
        #expect(mutations.count == 1)
        #expect(mutations.first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "source", placement: .temporary, pinnedFolderID: nil),
            before: .init(entityType: .tab, entityID: "c"),
            after: .init(entityType: .tab, entityID: "b")
        )])
        #expect(coordinator.previewTarget != nil)
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])

        // A newer document tree arrives during UIKit's animation. Refresh must
        // use that tree after both session terminals and the animation complete.
        #expect(f.document.removeTab(id: "c"))
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        coordinator.animation.finish()
        #expect(f.rowIDs(section: 2).count == 3)
        f.sidebar.tableView(f.table, dropSessionDidEnd: drop)
        #expect(f.rowIDs(section: 2) == ["browser.tab.b", "browser.tab.a"])
        #expect(await f.workspace.shutdown())
    }

    @Test func sidebarNoOpAndEscapeCancelPreserveDurableBytesAndQueue() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        let before = try f.durableState()
        let drag = try f.begin(row: 0, section: 2)
        let noOp = SidebarDropSession(drag: drag, point: f.point(row: 1, section: 2, fraction: 0.1))
        #expect(f.hover(noOp).operation == .forbidden)
        f.end(drag, noOp)
        #expect(try f.durableState() == before)

        let cancelled = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: cancelled, point: f.point(row: 2, section: 2, fraction: 0.9))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move)
        let command = try #require(f.sidebar.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        let action = try #require(command.action)
        #expect(UIApplication.shared.sendAction(action, to: f.sidebar, from: command, for: nil))
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        #expect(coordinator.previewTarget == nil)
        f.end(cancelled, drop)
        #expect(try f.durableState() == before)
        #expect(await f.workspace.shutdown())
    }

    @Test func sidebarDropRejectsStaleTargetsSourcesAndChangedSpace() async throws {
        for change in ["target-delete", "target-move", "source-move", "space-switch"] {
            let f = try SidebarDragFixture()
            defer { f.cleanup() }
            await f.start()
            let drag = try f.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: f.point(row: 2, section: 2, fraction: 0.9))
            let proposal = f.hover(drop)
            #expect(proposal.operation == .move)
            switch change {
            case "target-delete": #expect(f.document.removeTab(id: "c"))
            case "target-move": #expect(f.document.setPlacement(
                    tabID: "c", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
                ))
            case "source-move": #expect(f.document.setPlacement(
                    tabID: "a", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
                ))
            default: f.workspace.selectSpace(id: "other")
            }
            let afterChange = try f.durableState()
            #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])
            let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
            f.sidebar.tableView(f.table, performDropWith: coordinator)
            #expect(coordinator.previewTarget == nil)
            #expect(try f.durableState() == afterChange)
            f.end(drag, drop)
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func nativeFolderDropUsesCurrentSubtreeAndQueuesOnlyFolderRoot() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        f.workspace.selectTab(id: "deep")
        let selectedRuntime = f.engine.selectedID
        let runtimes = Set(f.workspace.tabs.map(\.runtimeID))
        let drag = try f.begin(row: 0, section: 1)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 4, section: 1, fraction: 0.5))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move && proposal.intent == .insertIntoDestinationIndexPath)

        // The drag carries one stable root. Descendants can leave or enter the
        // canonical tree while the rendered rows remain frozen.
        #expect(f.document.setPlacement(tabID: "child", placement: .spacePinned, spaceID: "source"))
        #expect(f.document.setPlacement(
            tabID: "a", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
        ))
        let earlierRows = try f.mutations()
        #expect(f.rowIDs(section: 1) == [
            "browser.folder.folder", "browser.tab.child", "browser.folder.nested",
            "browser.tab.deep", "browser.folder.empty",
        ])
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        let allRows = try f.mutations()
        #expect(Array(allRows.prefix(earlierRows.count)) == earlierRows)
        #expect(allRows.count == earlierRows.count + 1)
        #expect(allRows.last?.operations == [.move(
            items: [.init(entityType: .folder, entityID: "folder")],
            destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: "empty")
        )])
        let snapshot = f.document.snapshot
        #expect(snapshot.pinnedTabFolders?.first { $0.id == "folder" }?.parentFolderID == "empty")
        #expect(snapshot.pinnedTabFolders?.first { $0.id == "nested" }?.parentFolderID == "folder")
        #expect(snapshot.tabs.first { $0.id == "a" }?.pinnedFolderID == "folder")
        #expect(snapshot.tabs.first { $0.id == "deep" }?.pinnedFolderID == "nested")
        #expect(snapshot.tabs.first { $0.id == "child" }?.pinnedFolderID == nil)
        #expect(f.workspace.selectedTabID == "deep" && f.engine.selectedID == selectedRuntime)
        #expect(Set(f.workspace.tabs.map(\.runtimeID)) == runtimes)
        #expect(f.engine.closed.isEmpty)
        f.end(drag, drop)
        coordinator.animation.finish()
        #expect(try f.store.loadSnapshotStrict() == snapshot)
        #expect(await f.workspace.shutdown())
    }

    @Test func sidebarBoundaryUsesWholeSubtreeNestedIndentAndEmptySection() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.9))
        #expect(f.hover(drop).operation == .move)
        let line = try #require(f.table.subviews.first { $0.accessibilityIdentifier == "browser.dropBoundary" })
        let subtreeBottom = f.table.rectForRow(at: .init(row: 3, section: 1)).maxY
        #expect(abs(line.frame.midY - subtreeBottom) < 0.5)
        #expect(abs(line.frame.minX - f.table.layoutMargins.left) < 0.5)
        drop.point = f.point(row: 2, section: 1, fraction: 0.9)
        #expect(f.hover(drop).operation == .move)
        #expect(abs(line.frame.midY - subtreeBottom) < 0.5)
        #expect(abs(line.frame.minX - f.table.layoutMargins.left - 16) < 0.5)

        let header = f.table.rectForHeader(inSection: 0)
        drop.point = CGPoint(x: header.midX, y: header.midY)
        let emptyProposal = f.hover(drop)
        #expect(emptyProposal.operation == .move && emptyProposal.intent == .unspecified)
        #expect(abs(line.frame.midY - header.maxY) < 0.5)
        let emptyCoordinator = SidebarDropCoordinator(session: drop, proposal: emptyProposal)
        #expect(emptyCoordinator.destinationIndexPath == nil)
        f.sidebar.tableView(f.table, performDropWith: emptyCoordinator)
        #expect(f.document.snapshot.tabs.first { $0.id == "a" }?.placement == .app)
        f.end(drag, drop)
        emptyCoordinator.animation.finish()
        #expect(f.rowIDs(section: 0) == ["browser.tab.a"])

        let endDrag = try f.begin(row: 0, section: 0)
        let last = f.table.rectForRow(at: .init(row: 1, section: 2))
        let endDrop = SidebarDropSession(drag: endDrag, point: CGPoint(x: last.midX, y: last.maxY + 30))
        #expect(f.table.bounds.contains(endDrop.point))
        let endProposal = f.hover(endDrop)
        #expect(endProposal.operation == .move)
        #expect(abs(line.frame.midY - last.maxY) < 0.5)
        let endCoordinator = SidebarDropCoordinator(session: endDrop, proposal: endProposal)
        f.sidebar.tableView(f.table, performDropWith: endCoordinator)
        #expect(f.todayIDs == ["b", "c", "a"])
        f.end(endDrag, endDrop)
        endCoordinator.animation.finish()
        #expect(await f.workspace.shutdown())
    }

    @Test func sidebarRejectsForeignExternalAndMultipleDragPayloads() async throws {
        let f = try SidebarDragFixture()
        let other = try SidebarDragFixture()
        defer { other.cleanup()
            f.cleanup()
        }
        await f.start()
        await other.start()
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 2, section: 2, fraction: 0.9))
        #expect(f.sidebar.tableView(f.table, canHandle: drop))
        #expect(!other.sidebar.tableView(other.table, canHandle: drop))
        let sameDocumentSidebar = BrowserMobileTabsViewController(workspace: f.workspace)
        sameDocumentSidebar.loadViewIfNeeded()
        #expect(!sameDocumentSidebar.tableView(sameDocumentSidebar.tableView, canHandle: drop))
        drop.localDragSession = nil
        #expect(!f.sidebar.tableView(f.table, canHandle: drop))
        drop.localDragSession = drag
        drop.items.append(drag.items[0])
        #expect(!f.sidebar.tableView(f.table, canHandle: drop))
        #expect(f.sidebar
            .tableView(f.table, itemsForAddingTo: drag, at: .init(row: 1, section: 2), point: .zero)
            .isEmpty)
        f.end(drag, drop)
        #expect(try f.mutations().isEmpty)
        #expect(try other.mutations().isEmpty)
        #expect(await f.workspace.shutdown())
        #expect(await other.workspace.shutdown())
    }
}

// MARK: - SidebarDragFixture

@MainActor private final class SidebarDragFixture {
    // MARK: Lifecycle

    init() throws {
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        try store.bindSyncOwner(owner)
        let changes = BrowserSyncFolderProjection.canonicalChanges(sidebarDragSnapshot())
        let events = try changes.enumerated().map { offset, change in
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
            var payload = object["data"] as? [String: Any] ?? [:]
            payload["id"] = change.entityID
            let wire: [String: Any] = [
                "serverSeq": offset + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
                "entityID": change.entityID, "op": change.op.rawValue, "data": payload,
                "createdAt": "2026-10-03T00:00:00Z",
            ]
            return try JSONDecoder().decode(BrowserSyncEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        }
        _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
        let document = try BrowserMobileProfileDocument(store: store, initialSnapshot: store.loadSnapshotStrict())
        self.document = document
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: "drag", profileLoader: { document }, preferences: preferences
        )
        self.sidebar = BrowserMobileTabsViewController(workspace: workspace)
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
        workspace.onChange = { [weak sidebar] in sidebar?.render() }
    }

    // MARK: Internal

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidebarDrag-\(UUID())")
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "owner")
    let preferencesName = "SidebarDrag.\(UUID())"
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let workspace: BrowserMobileWorkspace
    let sidebar: BrowserMobileTabsViewController
    let engine = SidebarDragEngine()
    let preferences: UserDefaults
    let window: UIWindow

    var table: UITableView { sidebar.tableView }
    var todayIDs: [String] {
        document.snapshot.tabs.filter { $0.placement == .temporary && $0.spaceID == "source" }.compactMap(\.id)
    }

    func start() async {
        await workspace.restore()
        workspace.selectSpace(id: "source")
        window.rootViewController = sidebar
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 1100)
        window.makeKeyAndVisible()
        sidebar.loadViewIfNeeded()
        table.estimatedRowHeight = 0
        table.rowHeight = 52
        sidebar.render()
        sidebar.view.frame = window.bounds
        sidebar.view.layoutIfNeeded()
        table.layoutIfNeeded()
    }

    func begin(row: Int, section: Int) throws -> SidebarDragSession {
        let session = SidebarDragSession()
        session.items = sidebar.tableView(table, itemsForBeginning: session, at: .init(row: row, section: section))
        try #require(session.items.count == 1)
        return session
    }

    func point(row: Int, section: Int, fraction: CGFloat) -> CGPoint {
        let rect = table.rectForRow(at: .init(row: row, section: section))
        return .init(x: rect.midX, y: rect.minY + rect.height * fraction)
    }

    func hover(_ session: SidebarDropSession) -> UITableViewDropProposal {
        sidebar.tableView(table, dropSessionDidUpdate: session, withDestinationIndexPath: nil)
    }

    func end(_ drag: SidebarDragSession, _ drop: SidebarDropSession) {
        sidebar.tableView(table, dragSessionDidEnd: drag)
        sidebar.tableView(table, dropSessionDidEnd: drop)
    }

    func rowIDs(section: Int) -> [String] {
        table.layoutIfNeeded()
        return (0..<table.numberOfRows(inSection: section)).compactMap {
            table.cellForRow(at: .init(row: $0, section: section))?.accessibilityIdentifier
        }
    }

    func mutations() throws -> [BrowserSyncFolderMutation] {
        try store.pendingSyncQueue(for: owner).map { row in
            guard case .folders(let mutation) = row else { throw BrowserSyncQueueError.protocolVersionMismatch }
            return mutation
        }
    }

    func durableState() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(DurableState(snapshot: store.loadSnapshotStrict(), queue: mutations()))
    }

    func cleanup() {
        workspace.onChange = nil
        engine.shutdown()
        window.isHidden = true
        window.rootViewController = nil
        preferences.removePersistentDomain(forName: preferencesName)
        // The fixture still owns SQLite here. Defer deletion until its final
        // owner is released; never unlink an open database during a test.
        Task { @MainActor [weak store, directory] in
            await Task.yield()
            guard store == nil else { return }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Private

    private struct DurableState: Encodable {
        let snapshot: BrowserTabSessionSnapshot?
        let queue: [BrowserSyncFolderMutation]
    }
}

// MARK: - SidebarDragDropSession

@MainActor private class SidebarDragDropSession: NSObject, UIDragDropSession {
    var items = [UIDragItem]()
    var point = CGPoint.zero
    var allowsMoveOperation = true
    var isRestrictedToDraggingApplication = true

    func location(in _: UIView) -> CGPoint { point }
    func hasItemsConforming(toTypeIdentifiers _: [String]) -> Bool { true }
    func canLoadObjects(ofClass _: any NSItemProviderReading.Type) -> Bool { false }
}

// MARK: - SidebarDragSession

@MainActor private final class SidebarDragSession: SidebarDragDropSession, UIDragSession {
    var localContext: Any?
}

// MARK: - SidebarDropSession

@MainActor private final class SidebarDropSession: SidebarDragDropSession, UIDropSession {
    // MARK: Lifecycle

    init(drag: SidebarDragSession, point: CGPoint) {
        self.localDragSession = drag
        super.init()
        items = drag.items
        self.point = point
    }

    // MARK: Internal

    var localDragSession: (any UIDragSession)?
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none
    nonisolated let progress = Progress(totalUnitCount: 0)

    func loadObjects(
        ofClass _: any NSItemProviderReading.Type,
        completion: @escaping ([any NSItemProviderReading]) -> Void
    ) -> Progress {
        completion([])
        return progress
    }
}

// MARK: - SidebarDropItem

@MainActor private final class SidebarDropItem: NSObject, UITableViewDropItem {
    // MARK: Lifecycle

    init(_ item: UIDragItem) { self.dragItem = item }

    // MARK: Internal

    let dragItem: UIDragItem
    let sourceIndexPath: IndexPath? = nil
    let previewSize = CGSize(width: 100, height: 44)
}

// MARK: - SidebarDragAnimation

@MainActor private final class SidebarDragAnimation: NSObject, UIDragAnimating {
    var completions = [(UIViewAnimatingPosition) -> Void]()

    func addAnimations(_ animations: @escaping () -> Void) { animations() }
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) { completions.append(completion) }
    func finish() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(.end) }
    }
}

// MARK: - SidebarDropCoordinator

@MainActor private final class SidebarDropCoordinator: NSObject, UITableViewDropCoordinator {
    // MARK: Lifecycle

    init(session: SidebarDropSession, proposal: UITableViewDropProposal) {
        self.session = session
        self.proposal = proposal
        self.items = session.items.map { SidebarDropItem($0) }
    }

    // MARK: Internal

    let items: [any UITableViewDropItem]
    let destinationIndexPath: IndexPath? = nil
    let proposal: UITableViewDropProposal
    let session: any UIDropSession
    let animation = SidebarDragAnimation()
    var previewTarget: UIDragPreviewTarget?

    func drop(_: UIDragItem, to target: UIDragPreviewTarget) -> any UIDragAnimating {
        previewTarget = target
        return animation
    }

    func drop(_: UIDragItem, toRowAt _: IndexPath) -> any UIDragAnimating {
        Issue.record("Expected semantic preview target, not UIKit row insertion")
        return animation
    }

    func drop(_: UIDragItem, intoRowAt _: IndexPath, rect _: CGRect) -> any UIDragAnimating {
        Issue.record("Expected semantic preview target")
        return animation
    }

    func drop(_: UIDragItem, to _: UITableViewDropPlaceholder) -> any UITableViewDropPlaceholderContext {
        fatalError("Local sidebar moves never insert a placeholder")
    }
}

// MARK: - SidebarDragEngine

@MainActor private final class SidebarDragEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    var selectedID: String?
    var closed = [String]()

    func createTab(id _: String, url _: URL) {}
    func selectTab(id: String?) { selectedID = id }
    func navigate(id _: String, url _: URL) {}
    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func closeTab(id: String) { closed.append(id) }
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() { onEvent = nil
        onPopupCreated = nil
    }
}

private func sidebarDragSnapshot() -> BrowserTabSessionSnapshot {
    .init(spaces: [
        .init(id: "source", title: "Source", systemImageName: "globe"),
        .init(id: "other", title: "Other", systemImageName: "star"),
    ], pinnedTabFolders: [
        .init(id: "folder", spaceID: "source", title: "Folder", pinnedSiblingRank: 10.5),
        .init(id: "nested", spaceID: "source", parentFolderID: "folder", title: "Nested", pinnedSiblingRank: 20.25),
        .init(id: "empty", spaceID: "source", title: "Empty", pinnedSiblingRank: 30.75),
    ], tabs: [
        .init(
            id: "child",
            urlString: "about:blank",
            placement: .spacePinned,
            spaceID: "source",
            pinnedFolderID: "folder",
            pinnedSiblingRank: 10.5
        ),
        .init(
            id: "deep",
            urlString: "about:blank",
            placement: .spacePinned,
            spaceID: "source",
            pinnedFolderID: "nested",
            pinnedSiblingRank: 10.5
        ),
        .init(id: "a", urlString: "about:blank", spaceID: "source"),
        .init(id: "b", urlString: "about:blank", spaceID: "source"),
        .init(id: "c", urlString: "about:blank", spaceID: "source"),
    ])
}
