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
    }
}
