import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserSidebarDropTests {
    @Test func childInsertionUsesSiblingIdentityInsteadOfGlobalPinnedIndex() {
        let f = SidebarDragFixture(
            pinned: [("root", nil), ("one", "folder"), ("two", "folder"), ("three", "folder")],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        let target = BrowserSidebarDropDestination(
            container: .pinned("s", folderID: "folder"),
            beforeItem: f.item("three")
        )
        #expect(f.model.commitSidebarDrop(payload: f.payload("one"), destination: target))
        #expect(f.pinnedNames() == ["root", "two", "one", "three"])
        #expect(f.model.commitSidebarDrop(
            payload: f.payload("x"),
            destination: .init(container: target.container, beforeItem: f.item("two"))
        ))
        #expect(f.pinnedNames() == ["root", "x", "two", "one", "three"])
        #expect(f.model.tabs.first { $0.id == f.id("x") }?.pinnedFolderID == "folder")
    }

    @Test func movingFolderUsesRootItemsRatherThanItsFlatTabCount() {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("one", "folder"), ("two", "folder"), ("b", nil), ("c", nil)],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        #expect(f.model.commitSidebarDrop(
            payload: f.folderPayload("folder"),
            destination: .init(container: .pinned("s"), beforeItem: f.item("c"))
        ))
        #expect(f.pinnedNames() == ["a", "b", "one", "two", "c"])
    }

    @Test func nestedFolderWithoutDirectParentTabsStaysVisibleAndMovesAsOneSubtree() {
        let f = SidebarDragFixture(pinned: [("one", "child"), ("two", "child"), ("root", nil)], folders: [
            .init(id: "parent", spaceID: "s", title: "Parent"),
            .init(id: "child", spaceID: "s", parentFolderID: "parent", title: "Child"),
        ])
        let rows = f.model.sidebarSnapshot.visiblePinnedRows(in: "s")
        #expect(rows.map(\.id) == [
            "folder-parent",
            "folder-child",
            "tab-\(f.id("one"))",
            "tab-\(f.id("two"))",
            "tab-\(f.id("root"))",
        ])
        #expect(f.model.commitSidebarDrop(
            payload: f.folderPayload("parent"),
            destination: .init(container: .pinned("s"))
        ))
        #expect(f.pinnedNames() == ["root", "one", "two"])
        #expect(f.model.sidebarMovePlan(
            payload: f.folderPayload("parent"),
            destination: .init(container: .pinned("s", folderID: "child"))
        ) == nil)
    }

    @Test func repeatedCrossSectionMovesKeepIdentitySelectionAndSinglePersistenceCommit() {
        let f = SidebarDragFixture()
        f.model.selectTab(id: f.id("x"))
        let count = f.store.savedSnapshots.count
        #expect(f.model.commitSidebarDrop(payload: f.payload("x"), destination: .init(container: .pinned("s"))))
        #expect(f.pinnedNames() == ["a", "b", "x"])
        #expect(f.store.savedSnapshots.count == count + 1)
        #expect(f.model.commitSidebarDrop(payload: f.payload("x"), destination: .init(container: .temporary("s"))))
        #expect(f.names(f.model.temporaryTabs) == ["y", "x"])
        #expect(f.model.commitSidebarDrop(
            payload: f.payload("y"),
            destination: .init(container: .pinned("s"), beforeItem: f.item("b"))
        ))
        #expect(f.pinnedNames() == ["a", "y", "b"])
        #expect(f.model.selectedTabID == f.id("x"))
    }

    @Test func multiSelectionKeepsRelativeOrderAcrossFolders() {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("one", "f"), ("two", "f"), ("b", nil)],
            folders: [.init(id: "f", spaceID: "s", title: "Folder")]
        )
        #expect(f.model.commitSidebarDrop(
            payload: f.payload("b", "one"),
            destination: .init(container: .pinned("s"), beforeItem: f.item("a"))
        ))
        #expect(f.pinnedNames() == ["one", "b", "a", "two"])
        #expect(f.model.tabs.first { $0.id == f.id("one") }?.pinnedFolderID == nil)
        #expect(f.model.commitSidebarDrop(
            payload: f.payload("b", "one"),
            destination: .init(container: .temporary("s"), beforeItem: f.item("y"))
        ))
        #expect(f.names(f.model.temporaryTabs) == ["x", "one", "b", "y"])
        #expect(f.pinnedNames() == ["a", "two"])
    }

    @Test func multiSelectionMovesMixedRowsAcrossSpacesWithoutReplacingDestinationSelection() throws {
        let f = SidebarDragFixture(
            pinned: [("one", "folder"), ("two", "folder"), ("root", nil)],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        f.model.selectTab(id: f.id("one"))
        let payload = f.payload("x", "two", "one")
        f.model.selectSpace(id: "t")
        f.model.createNewTab()
        f.driver.flushPendingCreateEvents()
        let activeID = try #require(f.model.selectedTabID)
        let saves = f.store.savedSnapshots.count
        #expect(f.model.commitSidebarDrop(
            payload: payload,
            destination: .init(container: .temporary("t"), beforeItem: .tab(activeID))
        ))
        #expect(f.model.temporaryTabs.map(\.id) == [f.id("one"), f.id("two"), f.id("x"), activeID])
        #expect(f.model.selectedTabID == activeID)
        #expect(f.model.pinnedTabFolders.isEmpty)
        #expect(f.model.tabs.filter { payload.tabIDs.contains($0.id) }.allSatisfy {
            $0.spaceID == "t" && $0.placement == .temporary && $0.pinnedFolderID == nil && $0.pinnedURLString == nil
        })
        #expect(f.model.spaces.first { $0.id == "s" }?.selectedTabID != f.id("one"))
        #expect(f.store.savedSnapshots.count == saves + 1)
    }

    @Test func groupDropPreservesIncomingTabsAndRejectsMissingMembers() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        let payload = f.payload("y", "x")
        let target = BrowserSidebarDropDestination(container: .temporary("s"))
        #expect(f.model.sidebarMovePlan(payload: payload, destination: target) != nil)
        f.model.createNewTab()
        f.driver.flushPendingCreateEvents()
        let incoming = try #require(f.model.selectedTabID)
        #expect(f.model.commitSidebarDrop(payload: payload, destination: target))
        #expect(f.model.temporaryTabs.map(\.id) == [f.id("z"), incoming, f.id("x"), f.id("y")])
        #expect(f.model.sidebarMovePlan(payload: payload, destination: .init(container: .app)) == nil)
        f.model.closeTab(id: f.id("x"))
        let before = f.model.sidebarSnapshot
        #expect(!f.model.commitSidebarDrop(payload: payload, destination: .init(container: .pinned("s"))))
        #expect(f.model.sidebarSnapshot == before)
    }

    @Test func everyTemporaryGapAndPayloadProducesTheReferenceOrder() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["a", "b", "c", "d"])
        let names = ["a", "b", "c", "d"]
        for mask in 1..<16 {
            let moving = names.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let payload = try BrowserSidebarDragPayload(
                primary: f.item(#require(moving.last)),
                tabIDs: Set(moving.map(f.id))
            )
            for insertion in 0...names.count {
                let destination = BrowserSidebarDropDestination(
                    container: .temporary("s"),
                    beforeItem: insertion < names.count ? f.item(names[insertion]) : nil
                )
                var expected = names.filter { !moving.contains($0) }
                let beforeCount = names.prefix(insertion).filter { !moving.contains($0) }.count
                expected.insert(contentsOf: moving, at: beforeCount)
                let plan = f.model.sidebarMovePlan(payload: payload, destination: destination)
                #expect(plan.map { f.names($0.tabs) } == (expected == names ? nil : expected))
            }
        }
    }

    @Test func appCapacityAndNoOpDoNotAdvertiseAnotherDestination() {
        let f = SidebarDragFixture(apps: (0..<8).map { "app\($0)" })
        #expect(f.model.sidebarMovePlan(payload: f.payload("x"), destination: .init(container: .app)) == nil)
        #expect(f.model.sidebarMovePlan(
            payload: f.payload("a"),
            destination: .init(container: .pinned("s"), beforeItem: f.item("a"))
        ) == nil)
        #expect(f.model.sidebarMovePlan(
            payload: f.payload("a"),
            destination: .init(container: .pinned("s"), beforeItem: f.item("b"))
        ) == nil)
    }

    @Test func removedAnchorCancelsRatherThanAppendingSomewhereElse() {
        let f = SidebarDragFixture()
        let target = BrowserSidebarDropDestination(container: .pinned("s"), beforeItem: f.item("b"))
        let payload = f.payload("x")
        #expect(f.model.sidebarMovePlan(payload: payload, destination: target) != nil)
        f.model.closeTab(id: f.id("b"))
        #expect(!f.model.commitSidebarDrop(payload: payload, destination: target))
        #expect(f.model.temporaryTabs.contains { $0.id == payload.primary.rawID })
    }

    @Test func gapAfterExpandedFolderAgreesWithCommittedOrder() throws {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("one", "folder"), ("two", "folder"), ("b", nil)],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let rowSpecs: [(BrowserSidebarItemID, CGFloat, Int)] = [
            (f.item("a"), 10, 0), (.folder("folder"), 51, 0), (f.item("one"), 92, 1),
            (f.item("two"), 133, 1), (f.item("b"), 174, 0), (f.item("x"), 251, 0),
        ]
        let rows = rowSpecs.map { item, y, depth in BrowserSidebarDragRowGeometry(
            item: item,
            container: tree.container(of: item)!,
            frame: CGRect(x: CGFloat(depth) * 16, y: y, width: 224 - CGFloat(depth) * 16, height: 36)
        ) }
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: rows,
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 400),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        )
        let proposal = try #require(geometry.proposal(at: CGPoint(x: 80, y: 179), previous: nil))
        #expect(proposal.destination == .init(container: .pinned("s"), beforeItem: f.item("b")))
        guard case .line(let line) = proposal.feedback else { Issue.record("Expected gap line")
            return
        }
        #expect(line.midY == 171.5)
        #expect(rows.allSatisfy { !$0.frame.intersects(line) })
        #expect(f.model.commitSidebarDrop(payload: f.payload("x"), destination: proposal.destination))
        #expect(f.pinnedNames() == ["a", "one", "two", "x", "b"])
    }

    @Test func newTabAndDividerCannotPullTheTemporaryInsertionLineUpward() throws {
        let f = SidebarDragFixture()
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let rows = [
            BrowserSidebarDragRowGeometry(
                item: f.item("b"),
                container: .pinned("s"),
                frame: CGRect(x: 0, y: 10, width: 224, height: 36)
            ),
            BrowserSidebarDragRowGeometry(
                item: f.item("x"),
                container: .temporary("s"),
                frame: CGRect(x: 0, y: 110, width: 224, height: 36)
            ),
        ]
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("a"),
            rows: rows,
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        )
        let proposal = try #require(geometry.proposal(at: CGPoint(x: 60, y: 113), previous: nil))
        guard case .line(let line) = proposal.feedback else { Issue.record("Expected gap line")
            return
        }
        #expect(line.midY == 107.5)
        #expect(proposal.destination.container.section == .temporary)
    }

    @Test func folderAndSpaceBodiesHighlightAndInsertAtTheStart() throws {
        let f = SidebarDragFixture(
            pinned: [("one", "folder"), ("two", "folder")],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let rows = [
            BrowserSidebarDragRowGeometry(
                item: .folder("folder"),
                container: .pinned("s"),
                frame: CGRect(x: 0, y: 50, width: 224, height: 36)
            ),
            BrowserSidebarDragRowGeometry(
                item: f.item("one"),
                container: .pinned("s", folderID: "folder"),
                frame: CGRect(x: 16, y: 91, width: 208, height: 36)
            ),
        ]
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: rows,
            listViewport: CGRect(x: 0, y: 45, width: 224, height: 300),
            spaceHeader: (
                "s",
                CGRect(x: 0, y: 0, width: 224, height: 36)
            ),
            appFrame: nil,
            rowWidth: 224
        )
        let folder = try #require(geometry.proposal(at: CGPoint(x: 80, y: 74), previous: nil))
        #expect(folder.feedback == .folder("folder"))
        #expect(folder.destination.beforeItem == f.item("one"))
        #expect(folder.previewSize.width == 208)
        let space = try #require(geometry.proposal(at: CGPoint(x: 80, y: 18), previous: nil))
        #expect(space.feedback == .space("s"))
        #expect(space.destination.beforeItem == .folder("folder"))
    }

    @Test func jitterDoesNotFlipBetweenAdjacentSiblingSlots() throws {
        let f = SidebarDragFixture()
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let row = BrowserSidebarDragRowGeometry(
            item: f.item("a"),
            container: .pinned("s"),
            frame: CGRect(x: 0, y: 10, width: 224, height: 36)
        )
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: [row],
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        )
        let initial = try #require(geometry.proposal(at: CGPoint(x: 80, y: 27), previous: nil))
        for y in [27.9, 28.1, 27.8, 28.2] {
            #expect(geometry.proposal(at: CGPoint(x: 80, y: y), previous: initial)?.destination == initial.destination)
        }
        #expect(geometry.proposal(at: CGPoint(x: 80, y: 33), previous: initial)?.destination != initial.destination)
    }

    @Test func offscreenRowsCannotAcceptDropOrPaintIntoAnotherViewport() {
        let f = SidebarDragFixture()
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let row = BrowserSidebarDragRowGeometry(
            item: f.item("a"),
            container: .pinned("s"),
            frame: CGRect(x: 0, y: -100, width: 224, height: 36)
        )
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: [row],
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        )
        #expect(geometry.slots.isEmpty)
        #expect(geometry.proposal(at: CGPoint(x: 80, y: -80), previous: nil) == nil)
    }

    @Test func originalGrabPointSurvivesSizeChangesAndThresholdMovement() {
        let f = SidebarDragFixture()
        let drag = BrowserSidebarDragState(model: f.model)
        drag.begin(
            payload: f.payload("x"),
            sourceFrame: CGRect(x: 16, y: 200, width: 208, height: 36),
            start: CGPoint(x: 180, y: 212),
            pointer: CGPoint(x: 187, y: 240)
        )
        #expect(abs(drag.anchor.x - 164.0 / 208) < 0.0001)
        #expect(abs(drag.anchor.y - 1.0 / 3) < 0.0001)
        for size in [CGSize(width: 208, height: 36), CGSize(width: 50, height: 50)] {
            let origin = CGPoint(
                x: drag.pointer.x - size.width * drag.anchor.x,
                y: drag.pointer.y - size.height * drag.anchor.y
            )
            #expect(CGRect(origin: origin, size: size).contains(drag.pointer))
        }
    }

    @Test func gridPreviewUsesFutureCellWidth() throws {
        let f = SidebarDragFixture(apps: ["app"])
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: [],
            listViewport: CGRect(x: 0, y: 100, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: CGRect(x: 0, y: 0, width: 224, height: 50),
            rowWidth: 224
        )
        let proposal = try #require(geometry.proposal(at: CGPoint(x: 180, y: 20), previous: nil))
        #expect(proposal.destination.beforeItem == nil)
        #expect(proposal.previewSize.width == 109.5)
        #expect(proposal.feedback == .app)
    }

    @Test func gridNewRowEntryDoesNotJumpBackAfterExpansion() throws {
        let f = SidebarDragFixture(apps: ["p", "q", "r", "s"])
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let layout = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
        let originalHeight = layout.height(for: 4, availableWidth: 224)
        let point = CGPoint(x: 30, y: originalHeight - 2)
        func geometry(height: CGFloat) -> BrowserSidebarDragGeometry {
            .init(
                tree: tree,
                payload: f.payload("x"),
                rows: [],
                listViewport: CGRect(x: 0, y: 160, width: 224, height: 300),
                spaceHeader: nil,
                appFrame: CGRect(x: 0, y: 0, width: 224, height: height),
                rowWidth: 224
            )
        }
        let first = try #require(geometry(height: originalHeight).proposal(at: point, previous: nil))
        #expect(first.destination == .init(container: .app))
        let next = try #require(geometry(height: layout.height(for: 5, availableWidth: 224)).proposal(
            at: point,
            previous: first
        ))
        #expect(next.destination == first.destination)
        #expect(next.previewSize == first.previewSize)
    }

    @Test func collapsedHiddenChildrenDoNotCreateTwoTargetsForOneVisibleGap() {
        let f = SidebarDragFixture(
            pinned: [("one", "f"), ("hidden", "f"), ("three", "f")],
            folders: [.init(id: "f", spaceID: "s", title: "Folder", isExpanded: false)]
        )
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let rows = [
            BrowserSidebarDragRowGeometry(
                item: f.item("one"),
                container: .pinned("s", folderID: "f"),
                frame: CGRect(x: 16, y: 50, width: 208, height: 36)
            ),
            BrowserSidebarDragRowGeometry(
                item: f.item("three"),
                container: .pinned("s", folderID: "f"),
                frame: CGRect(x: 16, y: 91, width: 208, height: 36)
            ),
        ]
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: rows,
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        )
        let targets = Set(geometry.slots.compactMap { slot -> BrowserSidebarDropDestination? in
            if case .line(let line) = slot.proposal.feedback, line.midY == 88.5 {
                return slot.proposal.destination
            }
            return nil
        })
        #expect(targets == [.init(container: .pinned("s", folderID: "f"), beforeItem: f.item("three"))])
    }

    @Test func everyRootGapAndPayloadProducesTheReferenceOrder() {
        let f = SidebarDragFixture(pinned: [("a", nil), ("b", nil), ("c", nil), ("d", nil)], temporary: [])
        let snapshot = f.model.sidebarSnapshot
        let names = ["a", "b", "c", "d"]
        for mask in 1..<16 {
            let moving = names.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let payload = BrowserSidebarDragPayload(primary: f.item(moving[0]), tabIDs: Set(moving.map(f.id)))
            for insertion in 0...names.count {
                let destination = BrowserSidebarDropDestination(
                    container: .pinned("s"),
                    beforeItem: insertion < names.count
                        ? f.item(names[insertion])
                        : nil
                )
                let remaining = names.filter { !moving.contains($0) }
                let beforeCount = names.prefix(insertion).filter { !moving.contains($0) }.count
                var expected = remaining
                expected.insert(contentsOf: moving, at: beforeCount)
                let plan = f.model.sidebarMovePlan(payload: payload, destination: destination)
                if expected == names {
                    #expect(plan == nil)
                } else {
                    #expect(plan.map { f.names($0.tabs) } == expected)
                }
                #expect(f.model.sidebarSnapshot == snapshot, "Planning a hover must be read-only")
            }
        }
    }

    @Test func crossSpaceDropDoesNotReplaceAnUnrelatedActiveDestinationTab() throws {
        let f = SidebarDragFixture()
        f.model.selectTab(id: f.id("x"))
        let payload = f.payload("x")
        f.model.selectSpace(id: "t")
        f.model.createNewTab()
        f.driver.flushPendingCreateEvents()
        let active = try #require(f.model.selectedTabID)
        #expect(f.model.commitSidebarDrop(payload: payload, destination: .init(container: .temporary("t"))))
        #expect(f.model.selectedTabID == active)
        #expect(f.model.spaces.first { $0.id == "t" }?.selectedTabID == active)
        #expect(f.model.spaces.first { $0.id == "s" }?.selectedTabID != payload.primary.rawID)
    }

    @Test func folderReorderDoesNotMarkEveryChildAsRecentlyVisited() {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("one", "folder"), ("two", "folder"), ("b", nil)],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        f.model.selectTab(id: f.id("a"))
        let payload = f.folderPayload("folder")
        let times = Dictionary(uniqueKeysWithValues: f.model.tabs.map { ($0.id, $0.lastActivityAt) })
        #expect(f.model.commitSidebarDrop(payload: payload, destination: .init(container: .pinned("s"))))
        for tab in f.model.tabs where payload.tabIDs.contains(tab.id) {
            #expect(tab.lastActivityAt == times[tab.id])
        }
    }

    @Test func pointerMotionDoesNotReplanOrRelayoutAnUnchangedDestination() {
        let f = SidebarDragFixture()
        var plans = 0, layouts = 0, haptics = 0
        let drag = BrowserSidebarDragState(model: f.model) { payload, destination in
            plans += 1
            return f.model.sidebarMovePlan(payload: payload, destination: destination)
        }
        drag.onLayoutChange = { layouts += 1 }
        drag.onTargetChange = { haptics += 1 }
        drag.begin(
            payload: f.payload("x"),
            sourceFrame: CGRect(x: 0, y: 100, width: 224, height: 36),
            start: .zero,
            pointer: CGPoint(x: 100, y: 12)
        )
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        drag.updateGeometry(.init(
            tree: tree,
            payload: f.payload("x"),
            rows: [
                .init(item: f.item("a"), container: .pinned("s"), frame: CGRect(x: 0, y: 10, width: 224, height: 36)),
            ],
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        ))
        let count = plans
        for i in 0..<500 {
            drag.updatePointer(CGPoint(x: 60 + Double(i % 50), y: 12))
        }
        #expect(plans == count)
        #expect(haptics == 1)
        #expect(layouts == 0)
        #expect(f.pinnedNames() == ["a", "b"])
    }

    @Test func noOpDoesNotExpandACollapsedFolder() {
        let f = SidebarDragFixture(pinned: [("one", "child"), ("two", "child")], folders: [
            .init(id: "parent", spaceID: "s", title: "Parent"),
            .init(id: "child", spaceID: "s", parentFolderID: "parent", title: "Child", isExpanded: false),
        ])
        #expect(f.model.sidebarMovePlan(
            payload: f.folderPayload("child"),
            destination: .init(container: .pinned("s", folderID: "parent"), beforeItem: .folder("child"))
        ) == nil)
        #expect(f.model.pinnedTabFolders.first { $0.id == "child" }?.isExpanded == false)
    }

    @Test func offscreenFolderHeaderDoesNotHideAVisibleChildInsertionCue() throws {
        let f = SidebarDragFixture(
            pinned: [("one", "folder")],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")]
        )
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("x"),
            rows: [
                .init(
                    item: .folder("folder"),
                    container: .pinned("s"),
                    frame: CGRect(x: 0, y: -40, width: 224, height: 36)
                ),
                .init(
                    item: f.item("one"),
                    container: .pinned("s", folderID: "folder"),
                    frame: CGRect(x: 16, y: 8, width: 208, height: 36)
                ),
            ],
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: nil,
            appFrame: nil,
            rowWidth: 224
        )
        let proposal = try #require(geometry.proposal(at: CGPoint(x: 80, y: 10), previous: nil))
        guard case .line(let line) = proposal.feedback else { Issue.record("Offscreen highlight hid the insertion cue")
            return
        }
        #expect(line.midY == 5.5)
        #expect(proposal.destination.beforeItem == f.item("one"))
    }

    @Test func clippedBoundaryDoesNotFallBackToAnUnrelatedSection() {
        let f = SidebarDragFixture()
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("a"),
            rows: [
                .init(
                    item: f.item("x"),
                    container: .temporary("s"),
                    frame: CGRect(x: 0, y: -4, width: 224, height: 36)
                ),
            ],
            listViewport: CGRect(x: 0, y: 0, width: 224, height: 300),
            spaceHeader: ("s", CGRect(x: 0, y: -41, width: 224, height: 36)),
            appFrame: nil,
            rowWidth: 224
        )
        #expect(geometry.proposal(at: CGPoint(x: 80, y: 1), previous: nil) == nil)
        #expect(geometry.proposal(at: CGPoint(x: 80, y: 22), previous: nil)?
            .destination
            .container
            .section == .temporary)
    }

    @Test func partiallyClippedRowCannotStealTheVisibleSpaceHeader() throws {
        let f = SidebarDragFixture()
        let tree = BrowserSidebarTabTree(snapshot: f.model.sidebarSnapshot)
        let geometry = BrowserSidebarDragGeometry(
            tree: tree,
            payload: f.payload("y"),
            rows: [
                .init(
                    item: f.item("x"),
                    container: .temporary("s"),
                    frame: CGRect(x: 0, y: 70, width: 224, height: 36)
                ),
            ],
            listViewport: CGRect(x: 0, y: 100, width: 224, height: 300),
            spaceHeader: ("s", CGRect(x: 0, y: 59, width: 224, height: 36)),
            appFrame: nil,
            rowWidth: 224
        )
        let proposal = try #require(geometry.proposal(at: CGPoint(x: 80, y: 94), previous: nil))
        #expect(proposal.feedback == .space("s"))
        #expect(proposal.destination.container == .pinned("s"))
    }

    @Test func gridKeepsItsOriginalOneToFourColumnSizing() {
        let layout = BrowserSidebarAppTabGridLayout(spacing: 5)
        #expect(layout.frames(for: 1, availableWidth: 215)[0].width == 215)
        #expect(layout.frames(for: 2, availableWidth: 215).map(\.width) == [105, 105])
        #expect(layout.frames(for: 5, availableWidth: 215).last?.width == 215)
        #expect(layout.frames(for: 8, availableWidth: 215).count == 8)
    }
}
