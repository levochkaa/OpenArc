import AppKit
import Testing

// MARK: - BrowserNativeSidebarDragTests

@Suite(.serialized)
@MainActor struct BrowserNativeSidebarDragTests {
    @Test func nativeLayoutGapMatchesDropAndPreviewLandsBeforeRevealingTheMovedRow() async throws {
        let f = SidebarDragFixture()
        let h = SidebarDragHarness(f)
        defer { h.close() }
        let original = f.model.tabs
        try h.begin("x")
        let geometry = try #require(h.state.drag.geometry)
        let destination = BrowserSidebarDropDestination(container: .pinned("s"), beforeItem: f.item("b"))
        let slot = try #require(geometry.slots.first { $0.proposal.destination == destination })
        h.move(slot.hitFrame.center)
        #expect(f.model.tabs == original, "Hover must never mutate model order")
        let proposal = try #require(h.state.drag.proposal)
        guard case .line(let line) = proposal.feedback else { Issue.record("Expected line")
            return
        }
        #expect(geometry.rows.allSatisfy { !$0.frame.intersects(line) })
        let indicator = try #require(h.named("browser.sidebar.drop-indicator") as? BrowserSidebarInsertionIndicator)
        #expect(indicator.lineFrame == line)
        let floating = try #require(h.named("browser.sidebar.drag-preview"))
        #expect(indicator.visibleLineSegments.allSatisfy { !$0.intersects(floating.frame) })
        #expect(!indicator.visibleLineSegments.isEmpty)
        try h.snapshot("/tmp/thebrowser-drag-gap.png")
        h.release(slot.hitFrame.center)
        #expect(f.pinnedNames() == ["a", "x", "b"])
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(h.state.drag.phase == .settling)
            #expect(try #require(h.row(f.item("x"))).dragOpacity == 0)
        }
        let target = try #require(h.view.restingFrame(for: f.item("x")))
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.state.drag.phase == .idle)
        let preview = try #require(h.named("browser.sidebar.drag-preview"))
        #expect(preview.isHidden)
        #expect(preview.frame == target)
        #expect(try #require(h.row(f.item("x"))).dragOpacity == 1)
        #expect(!h.window.isVisible)
    }

    @Test func appGridExpansionRebuildsListCoordinatesWithoutReorderingListRows() throws {
        let f = SidebarDragFixture(apps: ["app1", "app2", "app3", "app4"])
        let h = SidebarDragHarness(f)
        defer { h.close() }
        try h.begin("x")
        let before = try #require(h.state.drag.geometry)
        let appSlot = try #require(before.slots.first { $0.proposal.destination.container == .app })
        h.move(appSlot.hitFrame.center)
        h.view.refresh()
        h.view.layoutSubtreeIfNeeded()
        let expanded = try #require(h.state.drag.geometry)
        #expect(f.names(f.model.temporaryTabs) == ["x", "y"])
        #expect(expanded.rows.map(\.item) == before.rows.map(\.item))
        #expect(try #require(expanded.rows.first).frame.minY > #require(before.rows.first).frame.minY + 30)
        let temp = try #require(expanded.rows.first { $0.item == f.item("y") })
        h.move(CGPoint(x: temp.frame.midX, y: temp.frame.maxY - 5))
        h.view.refresh()
        let current = try #require(h.state.drag.geometry)
        let proposal = try #require(h.state.drag.proposal)
        guard case .line(let line) = proposal.feedback else { Issue.record("Expected temporary insertion line")
            return
        }
        #expect(current.rows.allSatisfy { !$0.frame.intersects(line) })
        #expect(proposal.destination.container.section == .temporary)
        #expect(
            current.rows.map(\.frame) == expanded.rows.map(\.frame),
            "Leaving the expanded grid must not pull the list out from under the pointer"
        )
        try h.snapshot("/tmp/thebrowser-drag-grid.png")
    }

    @Test func leavingGridDuringItsExpansionFreezesTheActualListPosition() async throws {
        let f = SidebarDragFixture(apps: ["app1", "app2", "app3", "app4"])
        let h = SidebarDragHarness(f)
        defer { h.close() }
        try h.begin("x")
        let first = try #require(h.state.drag.geometry?.slots.first { $0.proposal.destination.container == .app })
        h.move(first.hitFrame.center)
        h.view.refresh(animated: true)
        try await Task.sleep(for: .milliseconds(60))
        h.view.layoutSubtreeIfNeeded()
        let during = try #require(h.state.drag.geometry)
        let target = try #require(during.rows.first { $0.item == f.item("y") })
        h.move(CGPoint(x: target.frame.midX, y: target.frame.maxY - 5))
        h.view.refresh()
        try await Task.sleep(for: .milliseconds(100))
        h.view.layoutSubtreeIfNeeded()
        let stopped = try #require(h.state.drag.geometry?.rows.first { $0.item == f.item("y") })
        #expect(abs(stopped.frame.minY - target.frame.minY) < 0.01)
        #expect(h.state.drag.proposal?.destination == .init(container: .temporary("s")))
    }

    @Test func droppingIntoCollapsedFolderMergesPreviewIntoItsHeader() async throws {
        let f = SidebarDragFixture(
            pinned: [("one", "folder"), ("two", "folder")],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder", isExpanded: false)]
        )
        let h = SidebarDragHarness(f)
        defer { h.close() }
        try h.begin("x")
        let slot = try #require(h.state.drag.geometry?.slots.first { $0.proposal.feedback == .folder("folder") })
        h.move(slot.hitFrame.center)
        try h.snapshot("/tmp/thebrowser-drag-folder.png")
        h.release(slot.hitFrame.center)
        #expect(f.model.tabs.first { $0.id == f.id("x") }?.pinnedFolderID == "folder")
        #expect(f.pinnedNames().first == "x")
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.state.drag.phase == .idle)
        #expect(try #require(h.named("browser.sidebar.drag-preview")).isHidden)
        #expect(h.row(.folder("folder"))?.dragOpacity == 1)
    }

    @Test func liftingWithEmptySectionsDoesNotMoveTheExistingList() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y"])
        let h = SidebarDragHarness(f)
        defer { h.close() }
        let row = try #require(h.row(f.item("y")))
        let original = row.convert(row.bounds, to: row.dragCoordinateView)
        try h.begin("y")
        let geometry = try #require(h.state.drag.geometry)
        #expect(geometry.rows.first { $0.item == f.item("y") }?.frame == original)
        let entry = try #require(geometry.appEntryFrame)
        h.move(entry.center)
        h.view.refresh()
        #expect(h.state.drag.proposal?.destination == .init(container: .app))
        #expect(h.state.drag.projectedPlan?.tabs.filter { $0.placement == .app }.count == 1)
    }

    @Test func folderDragReleasesEveryHiddenDescendant() async throws {
        let f = SidebarDragFixture(pinned: [("a", nil), ("one", "child"), ("two", "child"), ("b", nil)], folders: [
            .init(id: "parent", spaceID: "s", title: "Parent"),
            .init(id: "child", spaceID: "s", parentFolderID: "parent", title: "Child"),
        ])
        let h = SidebarDragHarness(f)
        defer { h.close() }
        let row = try #require(h.row(.folder("parent")))
        let point = row.convert(row.bounds.center, to: row.dragCoordinateView)
        #expect(h.view.beginDragging(
            item: .folder("parent"),
            from: row,
            value: .init(
                startLocation: point,
                location: point,
                translation: .zero,
                predictedEndTranslation: .zero
            )
        ))
        #expect(h.state.drag.hiddenFolderIDs == ["parent", "child"])
        let destination = BrowserSidebarDropDestination(container: .pinned("s"))
        let slot = try #require(h.state.drag.geometry?.slots.first { $0.proposal.destination == destination })
        h.move(slot.hitFrame.center)
        h.release(slot.hitFrame.center)
        try await Task.sleep(for: .milliseconds(500))
        #expect(f.pinnedNames() == ["a", "b", "one", "two"])
        #expect(h.state.drag.hiddenFolderIDs.isEmpty)
        #expect(h.rows.allSatisfy { $0.dragOpacity == 1 })
    }

    @Test func grabAnchorIsCapturedBeforeTheSourceViewMoves() throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let row = BrowserNativePressableView(frame: CGRect(x: 20, y: 100, width: 200, height: 36))
        root.addSubview(row)
        row.dragCoordinateView = root
        let down = row.convert(CGPoint(x: 50, y: 18), to: nil)
        var captured: BrowserNativeDragValue?
        row.onBeginDragSession = { captured = $0
            return true
        }
        func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }
        try row.mouseDown(with: event(.leftMouseDown, point: down))
        row.frame.origin.y += 90
        try row.mouseDragged(with: event(.leftMouseDragged, point: CGPoint(x: down.x + 10, y: down.y)))
        #expect(captured?.grabAnchor == CGPoint(x: 0.25, y: 0.5))
        try row.mouseUp(with: event(.leftMouseUp, point: down))
    }

    @Test func scrollingDuringDragUsesCurrentViewportAndNeverDrawsOnNewTab() throws {
        let f = SidebarDragFixture(temporary: (0..<40).map { "t\($0)" })
        let h = SidebarDragHarness(f, height: 360)
        defer { h.close() }
        try h.begin("t0")
        let before = try #require(h.state.drag.geometry)
        let point = CGPoint(x: 160, y: before.listViewport.maxY - 3)
        h.move(point)
        for _ in 0..<12 {
            h.view.autoscrollDrag(elapsed: 0.05)
        }
        let after = try #require(h.state.drag.geometry)
        #expect(try #require(after.rows.first).frame.minY < #require(before.rows.first).frame.minY - 100)
        if let proposal = h.state.drag.proposal, case .line(let line) = proposal.feedback {
            #expect(after.listViewport.contains(line))
            #expect(after.rows.allSatisfy { !$0.frame.intersects(line) })
            let newTab = try #require(h.named("browser.sidebar.new-tab"))
            let newTabFrame = newTab.convert(newTab.bounds, to: h.coordinateView)
            #expect(!newTabFrame.intersects(line))
        }
        try h.snapshot("/tmp/thebrowser-drag-scroll.png")
    }

    @Test func cancellationRestoresEveryRowAndDoesNotCommit() async throws {
        let f = SidebarDragFixture()
        let h = SidebarDragHarness(f)
        defer { h.close() }
        let tabs = f.model.tabs
        try h.begin("x")
        h.move(CGPoint(x: 500, y: 200))
        #expect(h.state.drag.proposal == nil)
        h.view.cancelDragging()
        try await Task.sleep(for: .milliseconds(500))
        #expect(f.model.tabs == tabs)
        #expect(h.state.drag.phase == .idle)
        #expect(h.rows.allSatisfy { $0.dragOpacity == 1 && !$0.isDragging && !$0.isPressed })
    }

    @Test func immediateRedragUsesCommittedIdentityAndCurrentPreviewPosition() async throws {
        let f = SidebarDragFixture()
        let h = SidebarDragHarness(f)
        defer { h.close() }
        try h.begin("x")
        let firstGeometry = try #require(h.state.drag.geometry)
        let first = try #require(firstGeometry.slots.first {
            $0.proposal.destination == .init(container: .pinned("s"), beforeItem: f.item("b"))
        })
        h.move(first.hitFrame.center)
        h.release(first.hitFrame.center)
        let preview = try #require(h.named("browser.sidebar.drag-preview") as? BrowserNativePressableView)
        let point = preview.frame.center
        let value = BrowserNativeDragValue(
            startLocation: point,
            location: point,
            translation: .zero,
            predictedEndTranslation: .zero
        )
        #expect(preview.onBeginDragSession?(value) == true)
        #expect(h.state.drag.payload?.primary == f.item("x"))
        let secondGeometry = try #require(h.state.drag.geometry)
        let last = try #require(secondGeometry.slots.first {
            $0.proposal.destination == .init(container: .temporary("s"))
        })
        h.move(last.hitFrame.center)
        h.release(last.hitFrame.center)
        #expect(f.names(f.model.temporaryTabs) == ["y", "x"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.rows.allSatisfy { $0.dragOpacity == 1 && !$0.isPressed && !$0.isDragging })
    }

    @Test func closingSourceDuringDragCleansUpItsPresentation() throws {
        let f = SidebarDragFixture()
        let h = SidebarDragHarness(f)
        defer { h.close() }
        try h.begin("x")
        f.model.closeTab(id: f.id("x"))
        h.state.update(snapshot: f.model.sidebarSnapshot, sidebarWidth: 240, isResizing: false)
        h.view.refresh()
        #expect(h.state.drag.phase == .idle)
        #expect(try #require(h.named("browser.sidebar.drag-preview")).isHidden)
        #expect(h.rows.filter(\.isInteractionEnabled).allSatisfy { $0.dragOpacity == 1 })
    }

    @Test func temporaryMultiSelectionDragsAndLandsAsAStableGroup() async throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        let h = SidebarDragHarness(f)
        defer { h.close() }
        h.state.toggleSidebarTabSelection(f.id("y"))
        h.state.toggleSidebarTabSelection(f.id("x"))
        try h.begin("y")
        #expect(h.state.drag.payload?.tabIDs == Set([f.id("x"), f.id("y")]))
        let geometry = try #require(h.state.drag.geometry)
        let target = try #require(geometry.slots.first {
            $0.proposal.destination == .init(container: .temporary("s"))
        })
        h.move(target.hitFrame.center)
        #expect(h.state.drag.proposal?.destination == target.proposal.destination)
        h.release(target.hitFrame.center)
        #expect(f.names(f.model.temporaryTabs) == ["z", "x", "y"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.state.drag.phase == .idle)
        #expect(h.rows.allSatisfy { $0.dragOpacity == 1 && !$0.isDragging })
    }

    @Test func windowDeactivationCancelsOnlyTheOwnedSession() {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let session = BrowserSidebarDragEventSession()
        var cancellations = 0
        session.onCancel = { cancellations += 1
            session.stop()
        }
        session.start(in: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(cancellations == 1)
        session.onCancel = {}
        #expect(!window.isVisible)
    }

    @Test func claimedNativeDragDoesNotDeliverADuplicateDropOrClick() throws {
        let row = BrowserNativePressableView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        var starts = 0, clicks = 0, legacyDrops = 0
        row.onBeginDragSession = { _ in starts += 1
            return true
        }
        row.onClick = { _ in clicks += 1 }
        row.onDragEnded = { _ in legacyDrops += 1 }
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: 100, y: y),
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }
        try row.mouseDown(with: event(.leftMouseDown, y: 15))
        try row.mouseDragged(with: event(.leftMouseDragged, y: 30))
        try row.mouseDragged(with: event(.leftMouseDragged, y: 35))
        try row.mouseUp(with: event(.leftMouseUp, y: 35))
        #expect(starts == 1 && clicks == 0 && legacyDrops == 0)
        #expect(!row.isDragging && !row.isPressed)
    }
}

// MARK: - SidebarDragHarness

@MainActor private final class SidebarDragHarness {
    // MARK: Lifecycle

    init(_ fixture: SidebarDragFixture, height: CGFloat = 600) {
        self.fixture = fixture
        self.state = BrowserNativeSidebarState(
            model: fixture.model,
            snapshot: fixture.model.sidebarSnapshot,
            sidebarWidth: 240
        )
        self.view = BrowserNativeSidebarNSView(state: state, header: NSView(), footer: NSView())
        self.window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 240, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let background = BrowserNativeSurface(frame: CGRect(x: 0, y: 0, width: 240, height: height))
        background.fillColor = .white
        background.strokeWidth = 0
        background.addSubview(view)
        window.contentView = background
        view.frame = CGRect(x: 0, y: 0, width: 240, height: height)
        view.appearance = NSAppearance(named: .aqua)
        view.refresh()
        view.layoutSubtreeIfNeeded()
    }

    // MARK: Internal

    let fixture: SidebarDragFixture
    let window: NSWindow
    let state: BrowserNativeSidebarState
    let view: BrowserNativeSidebarNSView

    var coordinateView: NSView? { rows.compactMap(\.dragCoordinateView).first }
    var rows: [BrowserNativeSidebarRowNSView] { allViews(view).compactMap { $0 as? BrowserNativeSidebarRowNSView } }

    func named(_ id: String) -> NSView? { allViews(view).first { $0.accessibilityIdentifier() == id } }
    func row(_ item: BrowserSidebarItemID) -> BrowserNativeSidebarRowNSView? {
        let id =
            switch item { case .tab(let id): "browser.sidebar.tab.\(id)"
            case .folder(let id): "browser.sidebar.folder.\(id)" }
        return named(id) as? BrowserNativeSidebarRowNSView
    }

    func begin(_ name: String) throws {
        let sourceRow = try #require(row(fixture.item(name)))
        let point = sourceRow.convert(sourceRow.bounds.center, to: sourceRow.dragCoordinateView)
        #expect(view.beginDragging(
            item: fixture.item(name),
            from: sourceRow,
            value: .init(
                startLocation: point,
                location: point,
                translation: .zero,
                predictedEndTranslation: .zero
            )
        ))
    }

    func move(_ point: CGPoint) { view.updateDrag(atWindowPoint: coordinateView!.convert(point, to: nil)) }
    func release(_ point: CGPoint) { view.finishDragging(atWindowPoint: coordinateView!.convert(point, to: nil)) }
    func close() { view.cancelDragging()
        window.close()
    }

    func snapshot(_ path: String) throws {
        view.layoutSubtreeIfNeeded()
        for row in rows where row.kind == .newTab {
            row.titleLabel.stringValue = "New Tab"
        }
        let surface = try #require(window.contentView)
        let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    // MARK: Private

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
