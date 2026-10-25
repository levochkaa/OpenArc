import AppKit
import Testing

// MARK: - BrowserSpaceDockTests

@Suite(.serialized)
@MainActor struct BrowserSpaceDockTests {
    @Test func movingASpaceReordersAndSavesTheSpaces() {
        let store = InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "a", title: "A", systemImageName: "star"),
                .init(id: "b", title: "B", systemImageName: "book"),
                .init(id: "c", title: "C", systemImageName: "globe"),
            ],
            tabs: [.init(id: "t", urlString: "https://a.example", spaceID: "a")]
        ))
        let driver = FakeBrowserTabDriver()
        let model = BrowserChromeModel(
            tabDriver: driver, sessionSnapshotStore: store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            extensionManager: FakeBrowserExtensionManager(), windowTitleHandler: { _ in }, allTabsClosedHandler: {}
        )
        defer {
            model.discardUnsavedSessionForClosure()
            model.prepareForTermination()
        }
        model.handleContextReady()
        driver.flushPendingCreateEvents()

        #expect(model.moveSpace(id: "a", toIndex: 2))
        #expect(model.spaces.map(\.id) == ["b", "c", "a"])
        #expect(store.savedSnapshots.last?.spaces?.map(\.id) == ["b", "c", "a"])
        // Indices past the ends clamp; the same place and unknown Spaces do nothing.
        #expect(model.moveSpace(id: "a", toIndex: -5))
        #expect(model.spaces.map(\.id) == ["a", "b", "c"])
        #expect(!model.moveSpace(id: "a", toIndex: 0))
        #expect(!model.moveSpace(id: "missing", toIndex: 1))
    }

    @Test func dockClicksSelectAndDragsReorder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let dock = BrowserSpaceDockNSView()
        dock.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        dock.itemSize = 32
        dock.itemSpacing = 8
        window.contentView = dock
        var clicked = [String]()
        var moves = [(String, Int)]()
        let items = ["a", "b", "c"].map { id in
            let button = BrowserNativeChromeButton(symbol: "star", title: id) { clicked.append(id) }
            button.menu = NSMenu(title: "menu \(id)")
            dock.addSubview(button)
            return (id: id, button: button)
        }
        dock.items = items
        dock.onMove = { moves.append(($0, $1)) }
        dock.layoutSubtreeIfNeeded()
        // Three 32 pt icons with 8 pt gaps, centered in 200 pt: 44, 84, 124.
        #expect(items.map { item in item.button.frame.minX } == [44, 84, 124])

        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            // The dock is flipped; window coordinates grow upward.
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 20), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        // A click without movement presses the button.
        try dock.mouseDown(with: event(.leftMouseDown, 100))
        try dock.mouseDragged(with: event(.leftMouseDragged, 102))
        try dock.mouseUp(with: event(.leftMouseUp, 102))
        #expect(clicked == ["b"] && moves.isEmpty)

        // Dragging "a" over the last slot moves it there.
        try dock.mouseDown(with: event(.leftMouseDown, 60))
        try dock.mouseDragged(with: event(.leftMouseDragged, 100))
        #expect(dock.draggedID == "a")
        try dock.mouseDragged(with: event(.leftMouseDragged, 140))
        try dock.mouseUp(with: event(.leftMouseUp, 140))
        #expect(moves.count == 1 && moves.first?.0 == "a" && moves.first?.1 == 2)
        #expect(dock.draggedID == nil && clicked == ["b"])

        // Clicks beside the icons fall through; menus are the icons' own.
        #expect(dock.hitTest(NSPoint(x: 10, y: 20)) == nil)
        #expect(try dock.menu(for: event(.rightMouseDown, 130))?.title == "menu c")

        // A sidebar drag finds the icon under the pointer, gaps included, and
        // shows the one it rests on.
        #expect(dock.spaceID(atWindowPoint: NSPoint(x: 41, y: 20)) == "a")
        #expect(dock.spaceID(atWindowPoint: NSPoint(x: 120, y: 20)) == "c")
        #expect(dock.spaceID(atWindowPoint: NSPoint(x: 20, y: 20)) == nil)
        dock.dropTargetID = "b"
        #expect(items.map { item in item.button.isDropTarget } == [false, true, false])
        dock.dropTargetID = nil
        #expect(items.allSatisfy { item in !item.button.isDropTarget })
    }

    @Test func restingOnASpaceIconSwitchesToItAfterAPause() async throws {
        let f = SidebarDragFixture()
        let drag = BrowserSidebarDragState(model: f.model)
        drag.begin(
            payload: f.payload("x"),
            sourceFrame: CGRect(x: 0, y: 200, width: 220, height: 36),
            start: CGPoint(x: 20, y: 210),
            pointer: CGPoint(x: 20, y: 500)
        )
        // Passing over an icon does not switch.
        drag.updateDockTarget("t")
        drag.updateDockTarget(nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.model.selectedSpaceID == "s")

        drag.updateDockTarget("t")
        #expect(drag.dockSpaceID == "t" && drag.proposal == nil)
        for _ in 0..<50 where f.model.selectedSpaceID != "t" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.model.selectedSpaceID == "t")
        #expect(drag.isDragging)
        _ = drag.release(at: CGPoint(x: 20, y: 500), cancel: true)
    }

    @Test func droppingOnASpaceIconMovesItemsToTheTopOfTheirSectionThere() throws {
        let f = SidebarDragFixture()
        f.model.selectSpace(id: "t")
        f.model.createNewTab()
        f.driver.flushPendingCreateEvents()
        let existing = try #require(f.model
            .tabs
            .first { tab in
                tab.spaceID == "t" && tab.placement == .temporary
            }?.id)
        f.model.selectSpace(id: "s")

        func drop(_ payload: BrowserSidebarDragPayload, on spaceID: String) -> Bool {
            let drag = BrowserSidebarDragState(model: f.model)
            drag.begin(
                payload: payload,
                sourceFrame: CGRect(x: 0, y: 200, width: 220, height: 36),
                start: CGPoint(x: 20, y: 210),
                pointer: CGPoint(x: 20, y: 500)
            )
            drag.updateDockTarget(spaceID)
            return drag.release(at: CGPoint(x: 20, y: 500))
        }

        func tab(_ name: String) -> BrowserChromeModel.Tab? {
            let id = f.id(name)
            return f.model.tabs.first { tab in tab.id == id }
        }

        // A temporary tab goes above the Space's temporary tabs; a pinned one
        // to the top of its pinned tabs.
        #expect(drop(f.payload("x"), on: "t"))
        let temporary: [String] = f.model
            .tabs
            .filter { tab in
                tab.spaceID == "t" && tab.placement == .temporary
            }
            .map { tab in tab.id }
        #expect(temporary == [f.id("x"), existing])
        #expect(drop(f.payload("b"), on: "t"))
        #expect(tab("b")?.spaceID == "t")
        #expect(tab("b")?.placement == .spacePinned)
        // Items already in the Space stay put.
        #expect(!drop(f.payload("y"), on: "s"))
        #expect(tab("y")?.spaceID == "s")
    }
}
