import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func stationaryWindowPointerScrollRequeriesTargetAndCommitsFrozenIdentityAfterLiveInsertion() async throws {
        let f = try SidebarDragFixture(snapshot: sidebarLongListSnapshot())
        defer { f.cleanup() }
        await f.start()
        let drag = try f.begin(row: 0, section: 2)
        let point = f.point(row: 4, section: 2, fraction: 0.1)
        let drop = SidebarDropSession(drag: drag, point: point)
        let windowPoint = f.table.convert(point, to: f.window)
        drop.fixLocation(windowPoint, in: f.window)
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move)
        let line = try #require(f.table.subviews.first { $0.accessibilityIdentifier == "browser.dropBoundary" })
        #expect(abs(line.frame.midY - f.table.rectForRow(at: .init(row: 4, section: 2)).minY) < 0.5)
        let queries = drop.locationQueryCount
        let geometry = f.scroll(row: 22, section: 2, fraction: 0.1, under: windowPoint)
        // No explicit hover call here: UIKit's scroll delegate must reread the
        // stationary point in window coordinates against the new table bounds.
        #expect(drop.locationQueryCount > queries)
        #expect(f.table.indexPathForRow(at: drop.location(in: f.table)) == .init(row: 22, section: 2), "\(geometry)")
        #expect(!line.isHidden)
        #expect(abs(line.frame.midY - f.table.rectForRow(at: .init(row: 22, section: 2)).minY) < 0.5, "\(geometry)")
        let inserted = try #require(f.document.createTab(spaceID: "source"))
        #expect(f.document.move(
            items: [.init(entityType: .tab, entityID: inserted)],
            destination: .tabs(spaceID: "source", placement: .temporary, pinnedFolderID: nil),
            before: .init(entityType: .tab, entityID: "row-0")
        ))
        let precedingQueue = try f.mutations()
        #expect(f.table.numberOfRows(inSection: 2) == 80)
        let target = try #require(f.table.cellForRow(at: .init(row: 22, section: 2)))
        #expect(target.accessibilityIdentifier == "browser.tab.row-22")
        let anchorPath = try #require(f.table.indexPathsForVisibleRows?.sorted().first { $0.section == 2 })
        let anchorID = try #require(f.table.cellForRow(at: anchorPath)?.accessibilityIdentifier)
        let anchorY = f.table.convert(f.table.rectForRow(at: anchorPath), to: f.window).minY
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        let queue = try f.mutations()
        #expect(queue.count == precedingQueue.count + 1)
        #expect(Array(queue.prefix(precedingQueue.count)) == precedingQueue)
        #expect(queue.last?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "row-0")],
            destination: .tabs(spaceID: "source", placement: .temporary, pinnedFolderID: nil),
            before: .init(entityType: .tab, entityID: "row-22"),
            after: .init(entityType: .tab, entityID: "row-21")
        )])
        f.end(drag, drop)
        #expect(f.table.numberOfRows(inSection: 2) == 80)
        coordinator.animations.forEach { $0.finish() }
        #expect(f.table.numberOfRows(inSection: 2) == 81)
        let restored = try #require(f.table.indexPathsForVisibleRows?.first {
            f.table.cellForRow(at: $0)?.accessibilityIdentifier == anchorID
        })
        #expect(abs(f.table.convert(f.table.rectForRow(at: restored), to: f.window).minY - anchorY) < 0.5)
        #expect(await f.workspace.shutdown())
    }

    @Test func terminalRefreshRestoresFirstSurvivingVisibleAnchorAfterTopVisibleDeletion() async throws {
        let f = try SidebarDragFixture(snapshot: sidebarLongListSnapshot())
        defer { f.cleanup() }
        await f.start()
        let drag = try f.begin(row: 0, section: 2)
        let point = f.point(row: 4, section: 2, fraction: 0.1)
        let drop = SidebarDropSession(drag: drag, point: point)
        let windowPoint = f.table.convert(point, to: f.window)
        drop.fixLocation(windowPoint, in: f.window)
        #expect(f.hover(drop).operation == .move)
        let geometry = f.scroll(row: 24, section: 2, fraction: 0.35, under: windowPoint)
        #expect(f.table.indexPathForRow(at: drop.location(in: f.table)) == .init(row: 24, section: 2), "\(geometry)")
        let visible = (f.table.indexPathsForVisibleRows ?? []).filter { $0.section == 2 }.sorted()
        try #require(visible.count > 2)
        let deletedPath = visible[0], survivingPath = visible[1]
        let deletedID = try #require(f.table.cellForRow(at: deletedPath)?.accessibilityIdentifier)
        let survivorID = try #require(f.table.cellForRow(at: survivingPath)?.accessibilityIdentifier)
        let survivorY = f.table.convert(f.table.rectForRow(at: survivingPath), to: f.window).minY
        let prefix = "browser.tab."
        #expect(f.document.removeTab(id: String(deletedID.dropFirst(prefix.count))))
        let changed = try f.durableState()
        #expect(f.table.cellForRow(at: deletedPath)?.accessibilityIdentifier == deletedID)
        #expect(f.table.numberOfRows(inSection: 2) == 80)
        f.end(drag, drop)
        #expect(f.table.numberOfRows(inSection: 2) == 79)
        let restored = try #require(f.table.indexPathsForVisibleRows?.first {
            f.table.cellForRow(at: $0)?.accessibilityIdentifier == survivorID
        })
        #expect(abs(f.table.convert(f.table.rectForRow(at: restored), to: f.window).minY - survivorY) < 0.5)
        #expect(try f.durableState() == changed)
        #expect(await f.workspace.shutdown())
    }

    @Test func stationaryWindowPointerScrollCancelsOldFolderDwellAndTargetsNewVisibleFolder() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let source = try SidebarDragFixture(snapshot: sidebarLongFolderSnapshot())
        let destination = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
        defer { destination.cleanup()
            source.cleanup()
        }
        // Bootstrap carries the shared tree, while expansion is local state.
        // Collapse through the document before capturing either sidebar.
        for index in 0..<40 {
            #expect(source.document.setFolderExpanded(id: "folder-\(index)", isExpanded: false))
        }
        await source.start(spaceID: "other")
        await destination.start()
        #expect(destination.table.numberOfRows(inSection: 1) == 40)
        #expect(destination.table.cellForRow(at: .init(row: 2, section: 1))?.accessibilityIdentifier
            == "browser.folder.folder-2")
        let drag = try source.begin(row: 0, section: 2)
        let point = destination.point(row: 2, section: 1, fraction: 0.5)
        let drop = SidebarDropSession(drag: drag, point: point)
        let windowPoint = destination.table.convert(point, to: destination.window)
        drop.fixLocation(windowPoint, in: destination.window)
        #expect(destination.hover(drop).operation == .move)
        try #require(scheduler.requests.count == 1)
        let queries = drop.locationQueryCount
        let geometry = destination.scroll(row: 12, section: 1, fraction: 0.5, under: windowPoint)
        #expect(drop.locationQueryCount > queries)
        #expect(destination.table.indexPathForRow(at: drop.location(in: destination.table)) == .init(
            row: 12,
            section: 1
        ), "\(geometry)")
        #expect(scheduler.requests[0].cancelled)
        try #require(scheduler.requests.count == 2)
        let before = try source.durableState()
        scheduler.fire(0)
        #expect(table.batchCount == 0)
        scheduler.fire(1)
        try await table.waitForBatches()
        #expect(table.batchCount == 1)
        #expect(destination.rowIDs(section: 1).contains("browser.tab.child-12"))
        #expect(!destination.rowIDs(section: 1).contains("browser.tab.child-2"))
        #expect(try source.durableState() == before)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        #expect(destination.table.numberOfRows(inSection: 1) == 40)
        #expect(try source.durableState() == before)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func stationaryWindowPointerPaletteScrollUpdatesHighlightAndCommitsCurrentSpace() async throws {
        let f = try SidebarDragFixture(snapshot: sidebarManySpacesSnapshot())
        defer { f.cleanup() }
        await f.start(showNavigation: true)
        let drag = try f.begin(row: 0, section: 2)
        let palette = try f.openSpacePalette()
        let scroll = try #require(palette.controller.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let drop = SidebarDropSession(drag: drag, point: .zero)
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.space-0.pinned").operation == .move)
        let original = try #require(sidebarDragView(
            withID: "browser.spaceDrop.space-0.pinned",
            in: palette.controller.view
        ))
        let target = try #require(sidebarDragView(
            withID: "browser.spaceDrop.space-6.today",
            in: palette.controller.view
        ))
        let windowPoint = palette.controller.view.convert(drop.point, to: f.window)
        drop.fixLocation(windowPoint, in: f.window)
        let targetWindowY = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: f.window).y
        let queries = drop.locationQueryCount
        let before = try f.durableState()
        scroll.setContentOffset(
            CGPoint(x: 0, y: scroll.contentOffset.y + targetWindowY - windowPoint.y),
            animated: false
        )
        palette.controller.view.layoutIfNeeded()
        #expect(drop.locationQueryCount > queries)
        #expect(target.bounds.contains(target.convert(windowPoint, from: f.window)))
        #expect(original.backgroundColor?.isEqual(UIColor.tertiarySystemGroupedBackground) == true)
        #expect(target.backgroundColor?.isEqual(palette.controller.view.tintColor.withAlphaComponent(0.16)) == true)
        #expect(try f.durableState() == before)
        // No explicit sessionDidUpdate after scroll: the installed inner scroll
        // delegate must refresh both the feedback and commit's captured target.
        palette.perform(drop)
        #expect(try f.mutations().count == 1)
        #expect(try f.mutations().first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "drag")],
            destination: .tabs(spaceID: "space-6", placement: .temporary, pinnedFolderID: nil)
        )])
        let animations = palette.installAnimations(for: drag.items)
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        palette.end(drop)
        #expect(palette.controller.parent === f.sidebar)
        animations.forEach { $0.finish() }
        #expect(palette.controller.parent == nil)
        #expect(await f.workspace.shutdown())
    }

    @Test func paletteScrollCannotCommitDeletedTargetOrRestoreExitedSession() async throws {
        for change in ["delete-target", "exit", "gap", "gap-recover"] {
            let f = try SidebarDragFixture(snapshot: sidebarManySpacesSnapshot())
            defer { f.cleanup() }
            await f.start(showNavigation: true)
            let drag = try f.begin(row: 0, section: 2)
            let palette = try f.openSpacePalette()
            let scroll = try #require(palette.controller.view.subviews.compactMap { $0 as? UIScrollView }.first)
            let drop = SidebarDropSession(drag: drag, point: .zero)
            #expect(try palette.hover(drop, targetID: "browser.spaceDrop.space-0.pinned").operation == .move)
            let windowPoint = palette.controller.view.convert(drop.point, to: f.window)
            drop.fixLocation(windowPoint, in: f.window)
            let target = try #require(sidebarDragView(
                withID: "browser.spaceDrop.space-5.today",
                in: palette.controller.view
            ))
            if change == "delete-target" {
                #expect(f.document.delete(entity: .init(entityType: .space, entityID: "space-5")))
            } else if change == "exit" {
                palette.exit(drop)
            }
            let targetPoint = CGPoint(x: target.bounds.midX, y: change.hasPrefix("gap") ? -4 : target.bounds.midY)
            let targetWindowY = target.convert(targetPoint, to: f.window).y
            let changed = try f.durableState()
            scroll.setContentOffset(
                CGPoint(x: 0, y: scroll.contentOffset.y + targetWindowY - windowPoint.y),
                animated: false
            )
            palette.controller.view.layoutIfNeeded()
            #expect(target.backgroundColor?.isEqual(UIColor.tertiarySystemGroupedBackground) == true)
            palette.perform(drop)
            #expect(try f.durableState() == changed)
            var recoveredAnimations = [SidebarDragAnimation]()
            if change == "gap-recover" {
                let centerY = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: f.window).y
                scroll.setContentOffset(
                    CGPoint(x: 0, y: scroll.contentOffset.y + centerY - windowPoint.y),
                    animated: false
                )
                palette.controller.view.layoutIfNeeded()
                #expect(target.backgroundColor?
                    .isEqual(palette.controller.view.tintColor.withAlphaComponent(0.16)) == true)
                // Recover from the gap using only the next scroll callback.
                palette.perform(drop)
                #expect(try f.mutations().count == 1)
                #expect(try f.mutations().first?.operations == [.move(
                    items: [.init(entityType: .tab, entityID: "drag")],
                    destination: .tabs(spaceID: "space-5", placement: .temporary, pinnedFolderID: nil)
                )])
                recoveredAnimations = palette.installAnimations(for: drag.items)
            }
            f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
            palette.end(drop)
            recoveredAnimations.forEach { $0.finish() }
            #expect(palette.controller.parent == nil)
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func addingAboveAndBelowUsesFrozenSidebarOrderAndAllInterwindowPreviews() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        source.workspace.selectTab(id: "deep")
        destination.workspace.selectTab(id: "destination-page")
        let sourceRuntime = source.engine.selectedID
        let destinationRuntime = destination.engine.selectedID
        try source.toggleSelection()
        source.select(row: 1, section: 2)
        let before = try source.durableState()
        let drag = try source.begin(row: 1, section: 2)
        let initialItem = try #require(drag.items.first)
        let addedAbove = source.add(to: drag, row: 0, section: 2)
        try #require(addedAbove.count == 1)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        drag.items.append(contentsOf: addedAbove)
        drop.items = drag.items
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        let addedBelow = source.add(to: drag, row: 2, section: 2)
        try #require(addedBelow.count == 1)
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        drag.items.append(contentsOf: addedBelow)
        drop.items = drag.items
        #expect(Set(source.table.indexPathsForSelectedRows ?? []) == Set([
            IndexPath(row: 0, section: 2), IndexPath(row: 1, section: 2), IndexPath(row: 2, section: 2),
        ]))
        #expect(drag.items.map(ObjectIdentifier.init) == [initialItem, addedAbove[0], addedBelow[0]]
            .map(ObjectIdentifier.init))
        #expect(try source.durableState() == before)
        #expect(source.engine.selectedID == sourceRuntime && destination.engine.selectedID == destinationRuntime)
        #expect(source.workspace.selectedTabID == "deep" && destination.workspace.selectedTabID == "destination-page")
        let sourceRows = source.rowIDs(section: 2)
        let destinationRows = destination.rowIDs(section: 2)
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        #expect(try source.mutations().count == 1)
        #expect(try source.mutations().first?.operations == [.move(
            items: ["a", "b", "c"].map { .init(entityType: .tab, entityID: $0) },
            destination: .tabs(spaceID: "other", placement: .temporary, pinnedFolderID: nil),
            after: .init(entityType: .tab, entityID: "destination-page")
        )])
        try #require(coordinator.animations.count == 3)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        coordinator.animations[2].finish()
        coordinator.animations[0].finish()
        #expect(source.rowIDs(section: 2) == sourceRows && destination.rowIDs(section: 2) == destinationRows)
        coordinator.animations[1].finish()
        #expect(source.rowIDs(section: 2).isEmpty)
        #expect(destination.rowIDs(section: 2) == [
            "browser.tab.destination-page",
            "browser.tab.a",
            "browser.tab.b",
            "browser.tab.c",
        ])
        #expect(source.engine.closed.isEmpty && destination.engine.closed.isEmpty)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func addingRejectsDuplicateIncompleteClonedAndForeignNativeSessions() async throws {
        let source = try SidebarDragFixture()
        let other = try SidebarDragFixture(sharing: source)
        defer { other.cleanup()
            source.cleanup()
        }
        await source.start()
        await other.start()
        let before = try source.durableState()
        let drag = try source.begin(row: 1, section: 2)
        #expect(source.add(to: drag, row: 1, section: 2).isEmpty)
        #expect(other.add(to: drag, row: 0, section: 2).isEmpty)
        let added = source.add(to: drag, row: 0, section: 2)
        try #require(added.count == 1)
        #expect(source.add(to: drag, row: 2, section: 2).isEmpty)
        let clone = UIDragItem(itemProvider: added[0].itemProvider)
        clone.localObject = added[0].localObject
        drag.items.append(clone)
        #expect(source.add(to: drag, row: 2, section: 2).isEmpty)
        drag.items.removeLast()
        drag.items.append(added[0])
        #expect(source.add(to: drag, row: 0, section: 2).isEmpty)
        let drop = SidebarDropSession(drag: drag, point: other.point(row: 2, section: 2, fraction: 0.9))
        #expect(other.sidebar.tableView(other.table, canHandle: drop))
        #expect(try source.durableState() == before)
        source.end(drag, drop)
        #expect(await source.workspace.shutdown())
        #expect(await other.workspace.shutdown())
    }

    @Test func addingRejectsAncestorOverlapAndPreservesEveryPreviouslyCapturedContainer() async throws {
        for invalidation in [
            "add-ancestor",
            "add-descendant",
            "frozen-ancestor",
            "old-root-moved",
            "new-row-moved",
            "old-root-deleted",
        ] {
            let f = try SidebarDragFixture()
            defer { f.cleanup() }
            await f.start()
            let drag: SidebarDragSession =
                if invalidation == "add-ancestor" {
                    try f.begin(row: 1, section: 1)
                } else if invalidation == "frozen-ancestor" {
                    try f.begin(row: 3, section: 1)
                } else if invalidation == "add-descendant" {
                    try f.begin(row: 0, section: 1)
                } else {
                    try f.begin(row: 1, section: 2)
                }
            switch invalidation {
            case "frozen-ancestor": #expect(f.document.move(
                    items: [.init(entityType: .folder, entityID: "nested")],
                    destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: nil)
                ))
            case "old-root-moved": #expect(f.document.setPlacement(tabID: "b", placement: .temporary, spaceID: "other"))
            case "new-row-moved": #expect(f.document.setPlacement(
                    tabID: "a",
                    placement: .spacePinned,
                    spaceID: "source",
                    pinnedFolderID: "folder"
                ))
            case "old-root-deleted": #expect(f.document.removeTab(id: "b"))
            default: break
            }
            let before = try f.durableState()
            let oldItems = drag.items.map(ObjectIdentifier.init)
            let added = ["add-ancestor", "frozen-ancestor"].contains(invalidation)
                ? f.add(to: drag, row: 0, section: 1)
                : invalidation == "add-descendant"
                    ? f.add(to: drag, row: 3, section: 1)
                    : f.add(to: drag, row: 0, section: 2)
            #expect(added.isEmpty && drag.items.map(ObjectIdentifier.init) == oldItems)
            #expect(try f.durableState() == before)
            f.end(drag, SidebarDropSession(drag: drag, point: .zero))
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func addingFromRevealedRowsCancelsEveryOldMembershipDwellAndHover() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let source = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
        #expect(source.document.setFolderExpanded(id: "nested", isExpanded: false))
        let drag = try source.begin(row: 0, section: 2)
        let hover = SidebarDropSession(drag: drag, point: source.point(row: 0, section: 1, fraction: 0.5))
        #expect(source.hover(hover).operation == .move)
        scheduler.fire(0)
        try await table.waitForBatches()
        hover.point = source.point(row: 2, section: 1, fraction: 0.5)
        #expect(source.hover(hover).operation == .move)
        try #require(scheduler.requests.count == 2)
        let header = destination.table.rectForHeader(inSection: 1)
        let drop = SidebarDropSession(drag: drag, point: CGPoint(x: header.midX, y: header.midY))
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move)
        let oldItemsCoordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        let before = try source.durableState()
        let added = source.add(to: drag, row: 1, section: 1)
        try #require(added.count == 1)
        drag.items.append(contentsOf: added)
        drop.items = drag.items
        hover.items = drag.items
        #expect(scheduler.requests[1].cancelled)
        scheduler.fire(1)
        #expect(!source.rowIDs(section: 1).contains("browser.tab.deep"))
        let stale = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: stale)
        #expect(try stale.droppedItems.isEmpty && (source.durableState()) == before)
        let freshProposal = destination.hover(drop)
        #expect(freshProposal.operation == .move)
        destination.sidebar.tableView(destination.table, performDropWith: oldItemsCoordinator)
        #expect(try oldItemsCoordinator.droppedItems.isEmpty && (source.durableState()) == before)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: freshProposal)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        #expect(try source.mutations().last?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "child"), .init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "other", placement: .spacePinned, pinnedFolderID: nil)
        )])
        source.end(drag, hover)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        coordinator.animations.forEach { $0.finish() }
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func addingFolderUpdatesOpenPaletteEligibilityWithoutMovingItsCapturedTargets() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start(showNavigation: true)
        let drag = try f.begin(row: 0, section: 2)
        let palette = try f.openSpacePalette()
        let drop = SidebarDropSession(drag: drag, point: .zero)
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.today").operation == .move)
        let today = try #require(sidebarDragView(withID: "browser.spaceDrop.other.today", in: palette.controller.view))
        let pinned = try #require(sidebarDragView(
            withID: "browser.spaceDrop.other.pinned",
            in: palette.controller.view
        ))
        let todayFrame = today.convert(today.bounds, to: f.window)
        let pinnedFrame = pinned.convert(pinned.bounds, to: f.window)
        let before = try f.durableState()
        let added = f.add(to: drag, row: 0, section: 1)
        try #require(added.count == 1)
        drag.items.append(contentsOf: added)
        drop.items = drag.items
        palette.controller.view.layoutIfNeeded()
        #expect(today === sidebarDragView(withID: "browser.spaceDrop.other.today", in: palette.controller.view))
        #expect(pinned === sidebarDragView(withID: "browser.spaceDrop.other.pinned", in: palette.controller.view))
        #expect(today.convert(today.bounds, to: f.window) == todayFrame)
        #expect(pinned.convert(pinned.bounds, to: f.window) == pinnedFrame)
        palette.perform(drop)
        #expect(try f.durableState() == before)
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.today").operation == .forbidden)
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.pinned").operation == .move)
        palette.perform(drop)
        #expect(try f.mutations().count == 1)
        #expect(try f.mutations().first?.operations == [.move(
            items: [.init(entityType: .folder, entityID: "folder"), .init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "other", placement: .spacePinned, pinnedFolderID: nil)
        )])
        let animations = palette.installAnimations(for: drag.items)
        try #require(animations.count == 2)
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        palette.end(drop)
        animations[0].finish()
        #expect(palette.controller.parent === f.sidebar)
        animations[1].finish()
        #expect(palette.controller.parent == nil)
        #expect(await f.workspace.shutdown())
    }

    @Test func addingRejectsInactiveSharedProjectionAndCommittedSessionWithoutChangingActivePage() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        table.holdsBatchCompletions = true
        let source = try SidebarDragFixture()
        let expanding = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
        defer { expanding.cleanup()
            source.cleanup()
        }
        await source.start()
        await expanding.start()
        #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
        source.workspace.selectTab(id: "c")
        let runtime = source.engine.selectedID
        let before = try source.durableState()
        let drag = try source.begin(row: 0, section: 2)
        source.sidebar.updateSidebarDragSceneState(.foregroundInactive)
        #expect(source.add(to: drag, row: 1, section: 2).isEmpty)
        source.sidebar.updateSidebarDragSceneState(.foregroundActive)
        let hover = SidebarDropSession(drag: drag, point: expanding.point(row: 0, section: 1, fraction: 0.5))
        #expect(expanding.hover(hover).operation == .move)
        scheduler.fire(0)
        try await table.waitForBatches()
        try #require(table.heldBatchCompletions.count == 1)
        #expect(source.add(to: drag, row: 1, section: 2).isEmpty)
        table.finishHeldBatches(finished: true)
        let added = source.add(to: drag, row: 1, section: 2)
        try #require(added.count == 1)
        drag.items.append(contentsOf: added)
        #expect(source.workspace.selectedTabID == "c" && source.engine.selectedID == runtime)
        #expect(try source.durableState() == before)
        // An ordinary tap fallback after an empty addition must not navigate.
        source.sidebar.tableView(source.table, didSelectRowAt: .init(row: 0, section: 2))
        #expect(source.workspace.selectedTabID == "c")
        let drop = SidebarDropSession(drag: drag, point: source.point(row: 2, section: 2, fraction: 0.9))
        let proposal = source.hover(drop)
        #expect(proposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        source.sidebar.tableView(source.table, performDropWith: coordinator)
        let committed = try source.durableState()
        #expect(source.add(to: drag, row: 2, section: 2).isEmpty)
        #expect(try source.durableState() == committed)
        source.end(drag, drop)
        expanding.sidebar.tableView(expanding.table, dropSessionDidEnd: hover)
        coordinator.animations.forEach { $0.finish() }
        #expect(await source.workspace.shutdown())
        #expect(await expanding.workspace.shutdown())
    }

    @Test func unchangedMembershipNotificationDoesNotCancelNewReceiverDwellOrHover() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let source = try SidebarDragFixture()
        let departing = try SidebarDragFixture(sharing: source)
        let receiver = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
        defer { receiver.cleanup()
            departing.cleanup()
            source.cleanup()
        }
        #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
        await source.start()
        await departing.start()
        await receiver.start()
        let drag = try source.begin(row: 0, section: 2)
        let oldDrop = SidebarDropSession(drag: drag, point: departing.point(row: 2, section: 2, fraction: 0.9))
        #expect(departing.hover(oldDrop).operation == .move)
        let drop = SidebarDropSession(drag: drag, point: receiver.point(row: 0, section: 1, fraction: 0.5))
        #expect(receiver.hover(drop).operation == .move)
        try #require(scheduler.requests.count == 1)
        departing.sidebar.tableView(departing.table, dropSessionDidExit: oldDrop)
        #expect(!scheduler.requests[0].cancelled)
        scheduler.fire(0)
        try await table.waitForBatches()
        #expect(receiver.rowIDs(section: 1).contains("browser.tab.child"))
        drop.point = receiver.point(row: 1, section: 1, fraction: 0.1)
        let proposal = receiver.hover(drop)
        departing.sidebar.tableView(departing.table, dropSessionDidEnd: oldDrop)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        receiver.sidebar.tableView(receiver.table, performDropWith: coordinator)
        #expect(try source.mutations().count == 1)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        receiver.sidebar.tableView(receiver.table, dropSessionDidEnd: drop)
        coordinator.animations.forEach { $0.finish() }
        #expect(await source.workspace.shutdown())
        #expect(await departing.workspace.shutdown())
        #expect(await receiver.workspace.shutdown())
    }

    @Test func hoverExpansionRevealsNestedFrozenRowsWithoutChangingDurableCollapseOrReloading() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
        defer { f.cleanup() }
        await f.start()
        #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
        #expect(f.document.setFolderExpanded(id: "nested", isExpanded: false))
        let durable = try f.durableState()
        let reloads = table.reloadCount
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
        #expect(f.hover(drop).operation == .move)
        try #require(scheduler.requests.count == 1)
        #expect(scheduler.requests[0].delay == .milliseconds(600))
        #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
        scheduler.fire(0)
        try await table.waitForBatches()
        #expect(f.rowIDs(section: 1) == [
            "browser.folder.folder", "browser.tab.child", "browser.folder.nested", "browser.folder.empty",
        ])
        drop.point = f.point(row: 2, section: 1, fraction: 0.5)
        #expect(f.hover(drop).operation == .move)
        try #require(scheduler.requests.count == 2)
        scheduler.fire(1)
        try await table.waitForBatches()
        #expect(f.rowIDs(section: 1) == [
            "browser.folder.folder", "browser.tab.child", "browser.folder.nested", "browser.tab.deep",
            "browser.folder.empty",
        ])
        #expect(table.batchCount == 2)
        #expect(table.insertedRows == [
            [.init(row: 1, section: 1), .init(row: 2, section: 1)], [.init(row: 3, section: 1)],
        ])
        #expect(table.reloadCount == reloads)
        #expect(try f.durableState() == durable)
        #expect(f.document
            .snapshot
            .pinnedTabFolders?
            .filter { ["folder", "nested"].contains($0.id) }
            .allSatisfy { !$0.isExpanded } == true)
        f.end(drag, drop)
        #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
        #expect(try f.durableState() == durable)
        #expect(await f.workspace.shutdown())
    }

    @Test func hoverTimerCannotRevealRowsAfterLeaveInactiveEscapeOrNewNativeToken() async throws {
        for cancellation in ["leave", "inactive", "escape", "new-token"] {
            let scheduler = SidebarManualHoverScheduler()
            let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
            let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
            defer { f.cleanup() }
            await f.start()
            #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
            let before = try f.durableState()
            let drag = try f.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
            #expect(f.hover(drop).operation == .move)
            try #require(scheduler.requests.count == 1)
            var replacement: SidebarDragSession?
            switch cancellation {
            case "leave": f.sidebar.tableView(f.table, dropSessionDidExit: drop)
            case "inactive": f.sidebar.updateSidebarDragSceneState(.foregroundInactive)
            case "escape":
                let command = try #require(f.sidebar.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
                let action = try #require(command.action)
                #expect(UIApplication.shared.sendAction(action, to: f.sidebar, from: command, for: nil))
            default:
                f.end(drag, drop)
                replacement = try f.begin(row: 1, section: 2)
            }
            #expect(scheduler.requests[0].cancelled)
            scheduler.fire(0)
            #expect(table.batchCount == 0)
            #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
            #expect(try f.durableState() == before)
            f.sidebar.updateSidebarDragSceneState(.foregroundActive)
            if let replacement {
                f.end(replacement, SidebarDropSession(drag: replacement, point: .zero))
            } else {
                f.end(drag, drop)
            }
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func hoverRevalidatesCapturedTargetAndSourceBeforeTimerExpansion() async throws {
        for change in ["delete-folder", "move-folder", "delete-source", "move-source"] {
            let scheduler = SidebarManualHoverScheduler()
            let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
            let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
            defer { f.cleanup() }
            await f.start()
            #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
            let drag = try f.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
            #expect(f.hover(drop).operation == .move)
            try #require(scheduler.requests.count == 1)
            switch change {
            case "delete-folder": #expect(f.document.delete(entity: .init(entityType: .folder, entityID: "folder")))
            case "move-folder": #expect(f.document.move(
                    items: [.init(entityType: .folder, entityID: "folder")],
                    destination: .tabs(spaceID: "other", placement: .spacePinned, pinnedFolderID: nil)
                ))
            case "delete-source": #expect(f.document.removeTab(id: "a"))
            default: #expect(f.document.setPlacement(tabID: "a", placement: .temporary, spaceID: "other"))
            }
            let changed = try f.durableState()
            scheduler.fire(0)
            #expect(table.batchCount == 0)
            #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
            #expect(try f.durableState() == changed)
            f.end(drag, drop)
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func hoverTimerQueriesCurrentPointerAndScrolledGeometryWithoutAnotherHoverCallback() async throws {
        for scroll in [false, true] {
            let scheduler = SidebarManualHoverScheduler()
            let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
            let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
            defer { f.cleanup() }
            await f.start()
            #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
            let before = try f.durableState()
            let drag = try f.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
            #expect(f.hover(drop).operation == .move)
            try #require(scheduler.requests.count == 1)
            if scroll {
                let windowPoint = f.table.convert(drop.point, to: f.window)
                drop.pointProvider = { [weak window = f.window] view in view.convert(windowPoint, from: window) }
                f.table.setContentOffset(CGPoint(x: 0, y: f.table.contentOffset.y + 80), animated: false)
                f.table.layoutIfNeeded()
            } else {
                drop.point = f.point(row: 0, section: 1, fraction: 0.05)
            }
            scheduler.fire(0)
            #expect(table.batchCount == 0)
            #expect(try f.durableState() == before)
            f.end(drag, drop)
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func hoverExpansionDoesNotLeakConcurrentNewRowsIntoFrozenTree() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
        defer { f.cleanup() }
        await f.start()
        #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
        #expect(f.hover(drop).operation == .move)
        try #require(scheduler.requests.count == 1)
        let tab = try #require(f.document.createTab(
            spaceID: "source",
            placement: .spacePinned,
            pinnedFolderID: "folder"
        ))
        let folder = try #require(f.document.createFolder(
            spaceID: "source",
            parentFolderID: "folder",
            title: "New folder"
        ))
        #expect(f.document.renameTab(id: "child", title: "Latest metadata"))
        let current = try f.durableState()
        let reloads = table.reloadCount
        scheduler.fire(0)
        try await table.waitForBatches()
        #expect(f.rowIDs(section: 1) == [
            "browser.folder.folder", "browser.tab.child", "browser.folder.nested", "browser.tab.deep",
            "browser.folder.empty",
        ])
        #expect(!f.rowIDs(section: 1).contains("browser.tab." + tab))
        #expect(!f.rowIDs(section: 1).contains("browser.folder." + folder))
        #expect(table.reloadCount == reloads)
        #expect(try f.durableState() == current)
        f.end(drag, drop)
        #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
        #expect(f.document.setFolderExpanded(id: "folder", isExpanded: true))
        #expect(f.rowIDs(section: 1).contains("browser.tab." + tab))
        #expect(f.rowIDs(section: 1).contains("browser.folder." + folder))
        #expect(await f.workspace.shutdown())
    }

    @Test func hoverRevealedNestedChildAcceptsOneExactInterwindowGroupMoveAndRetainsTransientRows() async throws {
        for before in [true, false] {
            let scheduler = SidebarManualHoverScheduler()
            let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
            let source = try SidebarDragFixture()
            let destination = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
            defer { destination.cleanup()
                source.cleanup()
            }
            #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
            #expect(source.document.setFolderExpanded(id: "nested", isExpanded: false))
            await source.start()
            await destination.start()
            source.workspace.selectTab(id: "b")
            destination.workspace.selectTab(id: "b")
            let sourceRuntime = source.engine.selectedID
            let destinationRuntime = destination.engine.selectedID
            try source.toggleSelection()
            source.select(row: 0, section: 2)
            source.select(row: 2, section: 2)
            let drag = try source.begin(row: 0, section: 2, expectedItems: 2)
            let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 1, fraction: 0.5))
            #expect(destination.hover(drop).operation == .move)
            try #require(scheduler.requests.count == 1)
            scheduler.fire(0)
            try await table.waitForBatches()
            drop.point = destination.point(row: 2, section: 1, fraction: 0.5)
            #expect(destination.hover(drop).operation == .move)
            try #require(scheduler.requests.count == 2)
            scheduler.fire(1)
            try await table.waitForBatches()
            let expandedRows = destination.rowIDs(section: 1)
            let reloads = table.reloadCount
            drop.point = destination.point(row: 3, section: 1, fraction: before ? 0.1 : 0.9)
            let proposal = destination.hover(drop)
            #expect(proposal.operation == .move)
            let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
            destination.sidebar.tableView(destination.table, performDropWith: coordinator)
            let anchor = BrowserSyncEntityReference(entityType: .tab, entityID: "deep")
            #expect(try source.mutations().count == 1)
            #expect(try source.mutations().first?.operations == [.move(
                items: [.init(entityType: .tab, entityID: "a"), .init(entityType: .tab, entityID: "c")],
                destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: "nested"),
                before: before ? anchor : nil, after: before ? nil : anchor
            )])
            #expect(source.engine.selectedID == sourceRuntime && destination.engine.selectedID == destinationRuntime)
            #expect(source.engine.closed.isEmpty && destination.engine.closed.isEmpty)
            try #require(coordinator.animations.count == 2)
            source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
            destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
            coordinator.animations[1].finish()
            #expect(destination.rowIDs(section: 1) == expandedRows)
            #expect(table.reloadCount == reloads)
            coordinator.animations[0].finish()
            #expect(destination.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
            #expect(source.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
            #expect(source.document
                .snapshot
                .pinnedTabFolders?
                .filter { ["folder", "nested"].contains($0.id) }
                .allSatisfy { !$0.isExpanded } == true)
            #expect(await source.workspace.shutdown())
            #expect(await destination.workspace.shutdown())
        }
    }

    @Test func hoverCanRevealNoOpAppendFolderThenMoveExistingLastChildBeforeFirst() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let source = try SidebarDragFixture(snapshot: .init(
            spaces: [.init(id: "source", title: "Source", systemImageName: "globe")],
            pinnedTabFolders: [.init(id: "folder", spaceID: "source", title: "Folder")],
            tabs: ["first", "last"].enumerated().map { rank, id in
                .init(
                    id: id,
                    urlString: "about:blank",
                    placement: .spacePinned,
                    spaceID: "source",
                    pinnedFolderID: "folder",
                    pinnedSiblingRank: Double(rank)
                )
            }
        ))
        let destination = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start()
        let drag = try source.begin(row: 2, section: 1)
        #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
        #expect(source.rowIDs(section: 1) == ["browser.folder.folder", "browser.tab.first", "browser.tab.last"])
        #expect(destination.rowIDs(section: 1) == ["browser.folder.folder"])
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 1, fraction: 0.5))
        let appendProposal = destination.hover(drop)
        let before = try source.durableState()
        let noOpCoordinator = SidebarDropCoordinator(session: drop, proposal: appendProposal)
        destination.sidebar.tableView(destination.table, performDropWith: noOpCoordinator)
        #expect(try source.durableState() == before)
        #expect(noOpCoordinator.droppedItems.isEmpty)
        try #require(scheduler.requests.count == 1)
        scheduler.fire(0)
        try await table.waitForBatches()
        #expect(destination.rowIDs(section: 1) == ["browser.folder.folder", "browser.tab.first", "browser.tab.last"])
        #expect(try source.durableState() == before)
        drop.point = destination.point(row: 1, section: 1, fraction: 0.1)
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        #expect(try source.mutations().count == 1)
        #expect(try source.mutations().first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "last")],
            destination: .tabs(spaceID: "source", placement: .spacePinned, pinnedFolderID: "folder"),
            before: .init(entityType: .tab, entityID: "first")
        )])
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        coordinator.animations.forEach { $0.finish() }
        #expect(destination.rowIDs(section: 1) == ["browser.folder.folder"])
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func hoverNativeBatchCompletionHoldsBothEndpointsAndInterruptedCompletionRestoresCollapse() async throws {
        for cancel in [false, true] {
            let scheduler = SidebarManualHoverScheduler()
            let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
            table.holdsBatchCompletions = true
            let source = try SidebarDragFixture()
            let destination = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
            defer { destination.cleanup()
                source.cleanup()
            }
            #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
            await source.start()
            await destination.start()
            let originalSourceRows = source.rowIDs(section: 2)
            let drag = try source.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 1, fraction: 0.5))
            let proposal = destination.hover(drop)
            #expect(proposal.operation == .move)
            try #require(scheduler.requests.count == 1)
            let durable = try source.durableState()
            let reloads = table.reloadCount
            scheduler.fire(0)
            try await table.waitForBatches()
            try #require(table.heldBatchCompletions.count == 1)
            #expect(table.batchCount == 1 && table.reloadCount == reloads)
            let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
            destination.sidebar.tableView(destination.table, performDropWith: coordinator)
            #expect(coordinator.droppedItems.isEmpty)
            #expect(try source.durableState() == durable)
            if cancel {
                destination.sidebar.updateSidebarDragSceneState(.background)
            }
            source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
            destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
            #expect(source.rowIDs(section: 2) == originalSourceRows)
            #expect(destination.rowIDs(section: 1).contains("browser.tab.child"))
            #expect(table.reloadCount == reloads)
            // UIKit's real batch ran; defer its client completion to exercise
            // asynchronous/interrupted lifecycle ordering deterministically.
            table.finishHeldBatches(finished: false)
            #expect(destination.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
            #expect(try source.durableState() == durable)
            #expect(await source.workspace.shutdown())
            #expect(await destination.workspace.shutdown())
        }
    }

    @Test func hoverBatchInOneWindowBlocksAnotherReceiverCommitUntilProjectionCompletes() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        table.holdsBatchCompletions = true
        let source = try SidebarDragFixture()
        let expanding = try SidebarDragFixture(sharing: source, hoverScheduler: scheduler, trackingTable: table)
        let receiving = try SidebarDragFixture(sharing: source)
        defer { receiving.cleanup()
            expanding.cleanup()
            source.cleanup()
        }
        #expect(source.document.setFolderExpanded(id: "folder", isExpanded: false))
        await source.start()
        await expanding.start()
        await receiving.start()
        let drag = try source.begin(row: 0, section: 2)
        let hover = SidebarDropSession(drag: drag, point: expanding.point(row: 0, section: 1, fraction: 0.5))
        #expect(expanding.hover(hover).operation == .move)
        let drop = SidebarDropSession(drag: drag, point: receiving.point(row: 2, section: 2, fraction: 0.9))
        let proposal = receiving.hover(drop)
        #expect(proposal.operation == .move)
        let reloads = table.reloadCount
        scheduler.fire(0)
        try await table.waitForBatches()
        try #require(table.heldBatchCompletions.count == 1)
        let stale = SidebarDropCoordinator(session: drop, proposal: proposal)
        receiving.sidebar.tableView(receiving.table, performDropWith: stale)
        #expect(stale.droppedItems.isEmpty)
        #expect(try source.mutations().isEmpty)
        #expect(table.reloadCount == reloads)
        table.finishHeldBatches(finished: false)
        let freshProposal = receiving.hover(drop)
        #expect(freshProposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: freshProposal)
        receiving.sidebar.tableView(receiving.table, performDropWith: coordinator)
        #expect(try source.mutations().count == 1)
        #expect(try source.mutations().first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "source", placement: .temporary, pinnedFolderID: nil),
            after: .init(entityType: .tab, entityID: "c")
        )])
        let expandedRows = expanding.rowIDs(section: 1)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        expanding.sidebar.tableView(expanding.table, dropSessionDidEnd: hover)
        receiving.sidebar.tableView(receiving.table, dropSessionDidEnd: drop)
        #expect(expanding.rowIDs(section: 1) == expandedRows && table.reloadCount == reloads)
        coordinator.animations.forEach { $0.finish() }
        #expect(expanding.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
        #expect(await source.workspace.shutdown())
        #expect(await expanding.workspace.shutdown())
        #expect(await receiving.workspace.shutdown())
    }

    @Test func hoverDueWhileUIKitHasPendingUpdatesRetriesWithoutAnotherPointerEvent() async throws {
        let scheduler = SidebarManualHoverScheduler()
        let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
        let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
        defer { f.cleanup() }
        await f.start()
        #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
        let before = try f.durableState()
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
        #expect(f.hover(drop).operation == .move)
        table.forcedUncommittedUpdates = true
        scheduler.fire(0)
        #expect(table.batchCount == 0)
        try #require(scheduler.requests.count == 2)
        #expect(scheduler.requests[1].delay < .milliseconds(600))
        table.forcedUncommittedUpdates = false
        scheduler.fire(1)
        try await table.waitForBatches()
        #expect(table.batchCount == 1)
        #expect(f.rowIDs(section: 1).contains("browser.tab.child"))
        #expect(try f.durableState() == before)
        f.end(drag, drop)
        #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
        #expect(await f.workspace.shutdown())
    }

    @Test func hoverPendingUpdateRetriesAreBoundedAndCanceledRetryCannotExpand() async throws {
        for cancel in [true, false] {
            let scheduler = SidebarManualHoverScheduler()
            let table = SidebarHoverTrackingTable(frame: .zero, style: .insetGrouped)
            let f = try SidebarDragFixture(hoverScheduler: scheduler, trackingTable: table)
            defer { f.cleanup() }
            await f.start()
            #expect(f.document.setFolderExpanded(id: "folder", isExpanded: false))
            let before = try f.durableState()
            let drag = try f.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: f.point(row: 0, section: 1, fraction: 0.5))
            #expect(f.hover(drop).operation == .move)
            table.forcedUncommittedUpdates = true
            scheduler.fire(0)
            try #require(scheduler.requests.count == 2)
            if cancel {
                f.sidebar.updateSidebarDragSceneState(.foregroundInactive)
                table.forcedUncommittedUpdates = false
                scheduler.fire(1)
                #expect(table.batchCount == 0)
                f.sidebar.updateSidebarDragSceneState(.foregroundActive)
            } else {
                var index = 1
                while index < scheduler.requests.count, index < 20 {
                    scheduler.fire(index)
                    index += 1
                }
                #expect(scheduler.requests.count == 11)
                #expect(scheduler.requests.dropFirst().allSatisfy { $0.delay == .milliseconds(50) })
                #expect(table.batchCount == 0)
                table.forcedUncommittedUpdates = false
                _ = f.hover(drop)
                try await table.waitForBatches()
                #expect(table.batchCount == 1)
                #expect(scheduler.requests.count == 11)
            }
            #expect(try f.durableState() == before)
            f.end(drag, drop)
            #expect(f.rowIDs(section: 1) == ["browser.folder.folder", "browser.folder.empty"])
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func interwindowGroupMoveUsesCurrentSubtreeAndHoldsBothTablesThroughEveryAnimation() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        // Both native windows use the host's one real scene. These delegated
        // calls prove cross-window ownership, not a physical Stage Manager drag.
        #expect(source.window !== destination.window && source.workspace !== destination.workspace)
        #expect(source.document === destination.document && source.store === destination.store)
        source.workspace.selectTab(id: "b")
        destination.workspace.selectTab(id: "destination-page")
        let sourceRuntime = source.engine.selectedID
        let destinationRuntime = destination.engine.selectedID
        let sourceRuntimes = source.workspace.tabs.map(\.runtimeID)
        let destinationRuntimes = destination.workspace.tabs.map(\.runtimeID)
        #expect(Set(sourceRuntimes).isDisjoint(with: destinationRuntimes))
        try source.toggleSelection()
        source.select(row: 0, section: 1)
        source.select(row: 0, section: 2)
        let sourceRows = source.rowIDs(section: 1)
        let destinationRows = destination.rowIDs(section: 1)
        let drag = try source.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 1, fraction: 0.5))
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move && proposal.intent == .insertIntoDestinationIndexPath)
        #expect(source.document.setPlacement(tabID: "child", placement: .spacePinned, spaceID: "source"))
        #expect(source.document.setPlacement(
            tabID: "c", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
        ))
        #expect(source.document.renameTab(id: "a", title: "Renamed while dragging"))
        let previous = try source.mutations()
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        let mutations = try source.mutations()
        #expect(mutations.count == previous.count + 1)
        #expect(Array(mutations.prefix(previous.count)) == previous)
        #expect(mutations.last?.operations == [.move(
            items: [.init(entityType: .folder, entityID: "folder"), .init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "other", placement: .spacePinned, pinnedFolderID: "destination-folder"),
            after: .init(entityType: .tab, entityID: "destination-pin")
        )])
        let snapshot = source.document.snapshot
        #expect(snapshot.tabs.first { $0.id == "child" }?.spaceID == "source")
        #expect(snapshot.tabs.first { $0.id == "c" }?.spaceID == "other")
        #expect(snapshot.tabs.first { $0.id == "deep" }?.spaceID == "other")
        #expect(snapshot.tabs.first { $0.id == "a" }?.userTitleOverride == "Renamed while dragging")
        #expect(snapshot.pinnedTabFolders?.first { $0.id == "folder" }?.parentFolderID == "destination-folder")
        #expect(snapshot.pinnedTabFolders?.first { $0.id == "nested" }?.spaceID == "other")
        #expect(source.workspace.selectedSpaceID == "source" && source.workspace.selectedTabID == "b")
        #expect(destination.workspace.selectedSpaceID == "other" && destination.workspace
            .selectedTabID == "destination-page")
        #expect(source.engine.selectedID == sourceRuntime && destination.engine.selectedID == destinationRuntime)
        #expect(Set(source.workspace.tabs.map(\.runtimeID)) == Set(sourceRuntimes))
        #expect(Set(destination.workspace.tabs.map(\.runtimeID)) == Set(destinationRuntimes))
        #expect(source.engine.closed.isEmpty && destination.engine.closed.isEmpty)
        try #require(coordinator.animations.count == 2)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        #expect(source.rowIDs(section: 1) == sourceRows)
        #expect(destination.rowIDs(section: 1) == destinationRows)
        coordinator.animations[1].finish()
        #expect(source.rowIDs(section: 1) == sourceRows)
        #expect(destination.rowIDs(section: 1) == destinationRows)
        coordinator.animations[0].finish()
        #expect(source.rowIDs(section: 1) == ["browser.folder.empty", "browser.tab.child"])
        #expect(destination.rowIDs(section: 1) == [
            "browser.folder.destination-folder", "browser.tab.destination-pin", "browser.folder.folder",
            "browser.folder.nested", "browser.tab.deep", "browser.tab.c", "browser.tab.a",
        ])
        // Duplicate terminal/animation/commit callbacks cannot enqueue again.
        coordinator.animations.forEach { $0.finish() }
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        #expect(try source.mutations() == mutations)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func interwindowInlineAnimationsPreserveIndependentSelectionsUntilBothTerminals() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        source.workspace.selectTab(id: "a")
        destination.workspace.selectTab(id: "destination-page")
        let movedRuntime = try #require(source.workspace.selectedTab?.runtimeID)
        let destinationRuntime = destination.engine.selectedID
        try source.toggleSelection()
        source.select(row: 0, section: 2)
        source.select(row: 2, section: 2)
        let drag = try source.begin(row: 2, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move)
        let beforeSourceRows = source.rowIDs(section: 2)
        let beforeDestinationRows = destination.rowIDs(section: 2)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal, completesInline: true)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        #expect(try source.mutations().first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a"), .init(entityType: .tab, entityID: "c")],
            destination: .tabs(spaceID: "other", placement: .temporary, pinnedFolderID: nil),
            after: .init(entityType: .tab, entityID: "destination-page")
        )])
        #expect(coordinator.animations.map(\.completionCount) == [1, 1])
        #expect(source.workspace.selectedSpaceID == "source" && source.workspace.selectedTabID == "b")
        #expect(destination.workspace.selectedSpaceID == "other" && destination.workspace
            .selectedTabID == "destination-page")
        #expect(source.workspace.tabs.first { $0.id == "a" }?.runtimeID == movedRuntime)
        #expect(destination.engine.selectedID == destinationRuntime)
        #expect(source.rowIDs(section: 2) == beforeSourceRows)
        #expect(destination.rowIDs(section: 2) == beforeDestinationRows)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        #expect(source.rowIDs(section: 2) == beforeSourceRows)
        #expect(destination.rowIDs(section: 2) == beforeDestinationRows)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        #expect(source.rowIDs(section: 2) == ["browser.tab.b"])
        #expect(destination.rowIDs(section: 2) == ["browser.tab.destination-page", "browser.tab.a", "browser.tab.c"])
        #expect(source.engine.closed.isEmpty && destination.engine.closed.isEmpty)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func interwindowExitReenterAndAnotherDestinationCannotCommitTheSameSessionTwice() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let first = try SidebarDragFixture(sharing: source)
        let second = try SidebarDragFixture(sharing: source)
        defer { second.cleanup()
            first.cleanup()
            source.cleanup()
        }
        await source.start()
        await first.start(spaceID: "other")
        await second.start(spaceID: "other")
        let drag = try source.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: first.point(row: 0, section: 2, fraction: 0.9))
        first.sidebar.tableView(first.table, dropSessionDidEnter: drop)
        let firstProposal = first.hover(drop)
        #expect(firstProposal.operation == .move)
        first.sidebar.tableView(first.table, dropSessionDidExit: drop)
        let firstCoordinator = SidebarDropCoordinator(session: drop, proposal: firstProposal)
        first.sidebar.tableView(first.table, performDropWith: firstCoordinator)
        #expect(try source.mutations().isEmpty)
        #expect(source.document.renameTab(id: "destination-page", title: "Changed between endpoints"))
        first.sidebar.tableView(first.table, dropSessionDidEnter: drop)
        #expect(first.hover(drop).operation == .move)
        first.sidebar.tableView(first.table, dropSessionDidExit: drop)
        drop.point = second.point(row: 0, section: 2, fraction: 0.1)
        second.sidebar.tableView(second.table, dropSessionDidEnter: drop)
        let proposal = second.hover(drop)
        #expect(proposal.operation == .move)
        let before = try source.mutations()
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        second.sidebar.tableView(second.table, performDropWith: coordinator)
        let committed = try source.mutations()
        #expect(committed.count == before.count + 1)
        #expect(committed.last?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "other", placement: .temporary, pinnedFolderID: nil),
            before: .init(entityType: .tab, entityID: "destination-page")
        )])
        #expect(first.hover(drop).operation == .forbidden)
        first.sidebar.tableView(first.table, performDropWith: firstCoordinator)
        #expect(try source.mutations() == committed)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        second.sidebar.tableView(second.table, dropSessionDidEnd: drop)
        first.sidebar.tableView(first.table, dropSessionDidEnd: drop)
        coordinator.animations.forEach { $0.finish() }
        #expect(first.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.destination-page"])
        #expect(second.rowIDs(section: 2) == first.rowIDs(section: 2))
        #expect(await source.workspace.shutdown())
        #expect(await first.workspace.shutdown())
        #expect(await second.workspace.shutdown())
    }

    @Test func interwindowStaleRootsTargetsAndDestinationSpaceRejectTheWholeGroup() async throws {
        for mutation in ["delete-root", "reparent-root", "delete-target", "reparent-target", "delete-space"] {
            let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
            let destination = try SidebarDragFixture(sharing: source)
            defer { destination.cleanup()
                source.cleanup()
            }
            await source.start()
            await destination.start(spaceID: "other")
            try source.toggleSelection()
            source.select(row: 0, section: 2)
            source.select(row: 2, section: 2)
            let drag = try source.begin(row: 0, section: 2, expectedItems: 2)
            let drop = SidebarDropSession(drag: drag, point: destination.point(row: 1, section: 1, fraction: 0.1))
            destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
            let proposal = destination.hover(drop)
            #expect(proposal.operation == .move)
            switch mutation {
            case "delete-root": #expect(source.document.removeTab(id: "c"))
            case "reparent-root": #expect(source.document.setPlacement(
                    tabID: "c", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
                ))
            case "delete-target": #expect(source.document.removeTab(id: "destination-pin"))
            case "reparent-target": #expect(source.document.setPlacement(
                    tabID: "destination-pin", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
                ))
            default: #expect(source.document.delete(entity: .init(entityType: .space, entityID: "other")))
            }
            let changed = try source.durableState()
            let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
            destination.sidebar.tableView(destination.table, performDropWith: coordinator)
            #expect(try source.durableState() == changed)
            #expect(coordinator.droppedItems.isEmpty)
            source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
            destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
            #expect(await source.workspace.shutdown())
            #expect(await destination.workspace.shutdown())
        }
    }

    @Test func interwindowAdmissionRequiresExactDocumentAndUnmodifiedNativeItems() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        let foreign = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        defer { foreign.cleanup()
            destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        await foreign.start(spaceID: "other")
        #expect(source.owner == foreign.owner && source.document !== foreign.document)
        try source.toggleSelection()
        source.select(row: 0, section: 2)
        source.select(row: 2, section: 2)
        let drag = try source.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        #expect(!foreign.sidebar.tableView(foreign.table, canHandle: drop))
        let clone = UIDragItem(itemProvider: drag.items[1].itemProvider)
        clone.localObject = drag.items[1].localObject
        drop.items = [drag.items[0], clone]
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        drop.items = [drag.items[0]]
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        drop.items = [drag.items[0], drag.items[0]]
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        drop.items = drag.items
        drop.localDragSession = nil
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        drop.localDragSession = drag
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        #expect(try source.mutations().isEmpty && foreign.mutations().isEmpty)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
        #expect(await foreign.workspace.shutdown())
    }

    @Test func interwindowAdmissionIsReadOnlyAndRejectsAnEndpointWithAnotherDrag() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        let drag = try source.begin(row: 0, section: 2)
        let unrelated = try destination.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        destination.end(unrelated, SidebarDropSession(drag: unrelated, point: .zero))
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        let newID = try #require(source.document.createTab(spaceID: "other"))
        // A canHandle query must not acquire a destination hold. No enter or
        // hover callback has occurred, so the live table must show this tab.
        #expect(destination.rowIDs(section: 2) == ["browser.tab.destination-page", "browser.tab." + newID])
        #expect(try source.mutations().count == 1)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func interwindowEscapeAndDisappearanceCancelAdmissionWithoutDroppingTerminalHolds() async throws {
        for endpoint in ["source-escape", "destination-escape", "source-disappears", "destination-disappears"] {
            let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
            let destination = try SidebarDragFixture(sharing: source)
            defer { destination.cleanup()
                source.cleanup()
            }
            await source.start()
            await destination.start(spaceID: "other")
            let drag = try source.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
            destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
            let proposal = destination.hover(drop)
            #expect(proposal.operation == .move)
            let target = endpoint.hasPrefix("source") ? source : destination
            if endpoint.hasSuffix("escape") {
                let command = try #require(target.sidebar.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
                let action = try #require(command.action)
                #expect(UIApplication.shared.sendAction(action, to: target.sidebar, from: command, for: nil))
            } else {
                target.sidebar.beginAppearanceTransition(false, animated: false)
                target.sidebar.endAppearanceTransition()
            }
            let before = try source.durableState()
            let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
            destination.sidebar.tableView(destination.table, performDropWith: coordinator)
            #expect(coordinator.droppedItems.isEmpty)
            #expect(try source.durableState() == before)
            #expect(destination.hover(drop).operation == .forbidden)
            source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
            destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
            #expect(await source.workspace.shutdown())
            #expect(await destination.workspace.shutdown())
        }
    }

    @Test func interwindowForegroundInactiveSuspendsOnlyReceiverAndSameTokenResumes() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        let drag = try source.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move)
        // Drive the production scene-state handler per controller. The host
        // shares one scene; this is not an observed OS activation transition.
        source.sidebar.updateSidebarDragSceneState(.foregroundInactive)
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        destination.sidebar.updateSidebarDragSceneState(.foregroundInactive)
        #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
        let staleCoordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: staleCoordinator)
        #expect(try source.mutations().isEmpty)
        #expect(staleCoordinator.droppedItems.isEmpty)
        destination.sidebar.updateSidebarDragSceneState(.foregroundActive)
        #expect(destination.sidebar.tableView(destination.table, canHandle: drop))
        let resumed = destination.hover(drop)
        #expect(resumed.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: resumed)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        #expect(try source.mutations().count == 1)
        #expect(source.document.snapshot.tabs.first { $0.id == "a" }?.spaceID == "other")
        source.sidebar.updateSidebarDragSceneState(.foregroundActive)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        coordinator.animations.forEach { $0.finish() }
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func interwindowBackgroundAndDisconnectInvalidateTokenDespiteReactivationAndLateCallbacks() async throws {
        for endpoint in ["source", "destination"] {
            for state in [UIScene.ActivationState.background, .unattached] {
                let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
                let destination = try SidebarDragFixture(sharing: source)
                defer { destination.cleanup()
                    source.cleanup()
                }
                await source.start()
                await destination.start(spaceID: "other")
                let drag = try source.begin(row: 0, section: 2)
                let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
                destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
                let proposal = destination.hover(drop)
                #expect(proposal.operation == .move)
                let changed = endpoint == "source" ? source : destination
                changed.sidebar.updateSidebarDragSceneState(state)
                changed.sidebar.updateSidebarDragSceneState(.foregroundActive)
                #expect(!destination.sidebar.tableView(destination.table, canHandle: drop))
                let before = try source.durableState()
                let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
                destination.sidebar.tableView(destination.table, performDropWith: coordinator)
                #expect(try source.durableState() == before)
                #expect(coordinator.droppedItems.isEmpty)
                source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
                destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
                // A canceled old token must not poison a later native session.
                let next = try source.begin(row: 0, section: 2)
                let nextDrop = SidebarDropSession(drag: next, point: drop.point)
                #expect(destination.sidebar.tableView(destination.table, canHandle: nextDrop))
                destination.sidebar.tableView(destination.table, performDropWith: coordinator)
                #expect(try source.durableState() == before)
                source.sidebar.tableView(source.table, dragSessionDidEnd: next)
                #expect(await source.workspace.shutdown())
                #expect(await destination.workspace.shutdown())
            }
        }
    }

    @Test func interwindowDisconnectAfterCommitRetainsPreviewRowsUntilLastCompletion() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        let destination = try SidebarDragFixture(sharing: source)
        defer { destination.cleanup()
            source.cleanup()
        }
        await source.start()
        await destination.start(spaceID: "other")
        try source.toggleSelection()
        source.select(row: 0, section: 2)
        source.select(row: 2, section: 2)
        let sourceRows = source.rowIDs(section: 2)
        let destinationRows = destination.rowIDs(section: 2)
        let drag = try source.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
        let proposal = destination.hover(drop)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        try #require(coordinator.animations.count == 2)
        let committed = try source.durableState()
        source.sidebar.updateSidebarDragSceneState(.unattached)
        destination.sidebar.updateSidebarDragSceneState(.background)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        destination.sidebar.tableView(destination.table, dropSessionDidEnd: drop)
        coordinator.animations[0].finish()
        #expect(source.rowIDs(section: 2) == sourceRows)
        #expect(destination.rowIDs(section: 2) == destinationRows)
        coordinator.animations[1].finish()
        #expect(source.rowIDs(section: 2) == ["browser.tab.b"])
        #expect(destination.rowIDs(section: 2) == ["browser.tab.destination-page", "browser.tab.a", "browser.tab.c"])
        #expect(try source.durableState() == committed)
        source.sidebar.updateSidebarDragSceneState(.foregroundActive)
        destination.sidebar.updateSidebarDragSceneState(.foregroundActive)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        coordinator.animations.forEach { $0.finish() }
        #expect(try source.durableState() == committed)
        #expect(await source.workspace.shutdown())
        #expect(await destination.workspace.shutdown())
    }

    @Test func interwindowReleasedDestinationCannotStrandSourcePreviewBarrier() async throws {
        let source = try SidebarDragFixture(snapshot: sidebarInterwindowSnapshot())
        defer { source.cleanup() }
        await source.start()
        try source.toggleSelection()
        source.select(row: 0, section: 2)
        source.select(row: 2, section: 2)
        let rows = source.rowIDs(section: 2)
        let drag = try source.begin(row: 0, section: 2, expectedItems: 2)
        // Return only the animator completions from a finished async frame.
        // Keeping the fake coordinator would also keep its diagnostic preview
        // target and UIKit table hierarchy; neither is needed for this proof.
        let (animations, releasedController) = try await retiredSidebarDestination(source: source, drag: drag)
        try #require(animations.count == 2)
        let committed = try source.durableState()
        // UIKit may defer view-controller teardown until the main run loop
        // drains its autorelease pool. Yielding one Swift task is insufficient.
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while releasedController.value != nil, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(releasedController.value == nil)
        source.sidebar.tableView(source.table, dragSessionDidEnd: drag)
        #expect(source.rowIDs(section: 2) == rows)
        animations[1].finish()
        #expect(source.rowIDs(section: 2) == rows)
        animations[0].finish()
        #expect(source.rowIDs(section: 2) == ["browser.tab.b"])
        #expect(try source.durableState() == committed)
        #expect(await source.workspace.shutdown())
    }

    @Test func spaceButtonOpensDropTargetsWithoutSwitchingSpaceAndMovesCurrentGroupSubtree() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start(showNavigation: true)
        f.workspace.selectTab(id: "b")
        let selectedRuntime = f.engine.selectedID
        let runtimes = Set(f.workspace.tabs.map(\.runtimeID))
        try f.toggleSelection()
        f.select(row: 0, section: 1)
        f.select(row: 0, section: 2)
        let drag = try f.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: .zero)
        let beforeOpening = try f.durableState()
        let sourceRows = f.rowIDs(section: 1)
        f.sidebar.tableView(f.table, dropSessionDidEnter: drop)
        let palette = try f.openSpacePalette()
        #expect(palette.controller.parent === f.sidebar)
        #expect(f.sidebar.presentedViewController == nil)
        #expect(f.workspace.selectedSpaceID == "source" && f.workspace.selectedTabID == "b")
        #expect(f.engine.selectedID == selectedRuntime)
        #expect(try f.durableState() == beforeOpening)
        #expect(f.rowIDs(section: 1) == sourceRows)
        let paletteFrame = palette.controller.view.convert(palette.controller.view.bounds, to: f.window)
        let navigationBar = try #require(f.sidebar.navigationController?.navigationBar)
        let navigationBarFrame = navigationBar.convert(navigationBar.bounds, to: f.window)
        #expect(!navigationBar.isHidden)
        #expect(paletteFrame.minY >= navigationBarFrame.maxY + 7.5)
        let visibleTableFrame = f.table.convert(f.table.bounds, to: f.window)
        #expect(paletteFrame.maxY <= visibleTableFrame.maxY - f.table.safeAreaInsets.bottom - 7.5)
        let oldOffset = f.table.contentOffset
        f.table.setContentOffset(CGPoint(x: oldOffset.x, y: oldOffset.y + 40), animated: false)
        f.sidebar.view.layoutIfNeeded()
        let scrolledFrame = palette.controller.view.convert(palette.controller.view.bounds, to: f.window)
        #expect(abs(scrolledFrame.minY - paletteFrame.minY) < 0.5)
        #expect(abs(scrolledFrame.minX - paletteFrame.minX) < 0.5)
        #expect(scrolledFrame.size == paletteFrame.size)
        f.table.setContentOffset(oldOffset, animated: false)
        f.sidebar.view.layoutIfNeeded()
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.today").operation == .forbidden)
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.pinned").operation == .move)
        f.sidebar.tableView(f.table, dropSessionDidExit: drop)
        #expect(palette.controller.parent === f.sidebar)

        #expect(f.document.setPlacement(tabID: "child", placement: .spacePinned, spaceID: "source"))
        #expect(f.document.setPlacement(
            tabID: "c", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
        ))
        let previousQueue = try f.mutations()
        palette.perform(drop)
        let queue = try f.mutations()
        #expect(Array(queue.prefix(previousQueue.count)) == previousQueue)
        #expect(queue.count == previousQueue.count + 1)
        #expect(queue.last?.operations == [.move(
            items: [.init(entityType: .folder, entityID: "folder"), .init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "other", placement: .spacePinned, pinnedFolderID: nil)
        )])
        let moved = f.document.snapshot
        #expect(moved.pinnedTabFolders?.first { $0.id == "folder" }?.spaceID == "other")
        #expect(moved.pinnedTabFolders?.first { $0.id == "nested" }?.spaceID == "other")
        #expect(moved.tabs.first { $0.id == "child" }?.spaceID == "source")
        #expect(moved.tabs.first { $0.id == "c" }?.spaceID == "other")
        #expect(moved.tabs.first { $0.id == "deep" }?.spaceID == "other")
        #expect(moved.tabs.first { $0.id == "a" }?.spaceID == "other")
        #expect(f.workspace.selectedSpaceID == "source" && f.workspace.selectedTabID == "b")
        #expect(f.engine.selectedID == selectedRuntime && Set(f.workspace.tabs.map(\.runtimeID)) == runtimes)
        #expect(f.engine.closed.isEmpty)

        let animations = palette.installAnimations(for: drag.items)
        try #require(animations.count == 2)
        #expect(f.rowIDs(section: 1) == sourceRows)
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        animations[1].finish()
        #expect(palette.controller.parent === f.sidebar)
        #expect(f.rowIDs(section: 1) == sourceRows)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: f.window.windowScene)
        #expect(palette.controller.parent === f.sidebar)
        #expect(try f.mutations() == queue)
        palette.end(drop)
        #expect(palette.controller.parent === f.sidebar)
        animations[0].finish()
        palette.conclude(drop)
        #expect(palette.controller.parent == nil)
        #expect(f.rowIDs(section: 1) == ["browser.folder.empty", "browser.tab.child"])
        #expect(await f.workspace.shutdown())
    }

    @Test func crossSpaceTodayDropRetainsMovedRuntimeAndUsesExistingActiveTabFallback() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start(showNavigation: true)
        f.workspace.selectTab(id: "a")
        let runtime = try #require(f.workspace.selectedTab?.runtimeID)
        try f.toggleSelection()
        f.select(row: 0, section: 2)
        f.select(row: 2, section: 2)
        let drag = try f.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: .zero)
        let palette = try f.openSpacePalette()
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.today").operation == .move)
        palette.perform(drop)
        let queue = try f.mutations()
        #expect(queue.count == 1)
        #expect(queue.first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a"), .init(entityType: .tab, entityID: "c")],
            destination: .tabs(spaceID: "other", placement: .temporary, pinnedFolderID: nil)
        )])
        #expect(f.document.snapshot.tabs.filter { $0.spaceID == "other" }.compactMap(\.id) == ["a", "c"])
        #expect(f.workspace.selectedSpaceID == "source")
        #expect(f.workspace.selectedTabID != "a")
        #expect(f.workspace.visibleTabs.contains { $0.id == f.workspace.selectedTabID })
        #expect(f.workspace.tabs.first { $0.id == "a" }?.runtimeID == runtime)
        #expect(f.engine.closed.isEmpty)
        let animations = palette.installAnimations(for: drag.items, completesInline: true)
        #expect(animations.map(\.completionCount) == [1, 1])
        palette.conclude(drop)
        palette.end(drop)
        #expect(palette.controller.parent === f.sidebar)
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        #expect(palette.controller.parent == nil)
        #expect(f.rowIDs(section: 2) == ["browser.tab.b"])
        #expect(await f.workspace.shutdown())
    }

    @Test func crossSpaceTargetKeepsCapturedIdentityAfterSpaceRenameAndReorder() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start(showNavigation: true)
        let drag = try f.begin(row: 0, section: 2)
        let drop = SidebarDropSession(drag: drag, point: .zero)
        let palette = try f.openSpacePalette()
        #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.pinned").operation == .move)
        let capturedPoint = drop.point
        #expect(f.document.renameSpace(id: "other", title: "Renamed destination"))
        #expect(f.document.move(
            items: [.init(entityType: .space, entityID: "other")], destination: .spaces,
            before: .init(entityType: .space, entityID: "source")
        ))
        #expect(f.document.snapshot.spaces?.map(\.id) == ["other", "source"])
        let previous = try f.mutations()
        #expect(drop.point == capturedPoint)
        palette.perform(drop)
        #expect(f.document.snapshot.tabs.first { $0.id == "a" }?.spaceID == "other")
        #expect(try f.mutations().count == previous.count + 1)
        #expect(try f.mutations().last?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a")],
            destination: .tabs(spaceID: "other", placement: .spacePinned, pinnedFolderID: nil)
        )])
        let animations = palette.installAnimations(for: drag.items)
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        palette.end(drop)
        animations.forEach { $0.finish() }
        palette.conclude(drop)
        #expect(palette.controller.parent == nil)
        #expect(await f.workspace.shutdown())
    }

    @Test func crossSpaceDropRejectsDeletedDestinationReparentedSourceAndOwningSceneCancellation() async throws {
        for change in ["space-deleted", "source-moved", "scene-inactive"] {
            let f = try SidebarDragFixture()
            defer { f.cleanup() }
            await f.start(showNavigation: true)
            let drag = try f.begin(row: 0, section: 2)
            let drop = SidebarDropSession(drag: drag, point: .zero)
            let palette = try f.openSpacePalette()
            #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.today").operation == .move)
            switch change {
            case "space-deleted": #expect(f.document.delete(entity: .init(entityType: .space, entityID: "other")))
            case "source-moved": #expect(f.document.setPlacement(
                    tabID: "a", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
                ))
            default:
                // This drives the installed notification callback, not an OS
                // background transition. An unrelated object must be ignored.
                NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
                #expect(try palette.hover(drop, targetID: "browser.spaceDrop.other.today").operation == .move)
                NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: f.window.windowScene)
            }
            let changed = try f.durableState()
            palette.perform(drop)
            #expect(try f.durableState() == changed)
            f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
            palette.end(drop)
            palette.conclude(drop)
            #expect(palette.controller.parent == nil)
            #expect(await f.workspace.shutdown())
        }
    }

    @Test func crossSpacePaletteRejectsForeignAndExternalSessionsWithoutWriting() async throws {
        let f = try SidebarDragFixture()
        let other = try SidebarDragFixture()
        defer { other.cleanup()
            f.cleanup()
        }
        await other.start(showNavigation: true)
        let foreign = try other.begin(row: 0, section: 2)
        await f.start(showNavigation: true)
        let drag = try f.begin(row: 0, section: 2)
        let ownDrop = SidebarDropSession(drag: drag, point: .zero)
        let palette = try f.openSpacePalette()
        let foreignDrop = SidebarDropSession(drag: foreign, point: .zero)
        #expect(!palette.canHandle(foreignDrop))
        #expect(try palette.hover(foreignDrop, targetID: "browser.spaceDrop.other.pinned").operation == .forbidden)
        let externalDrop = SidebarDropSession(drag: drag, point: foreignDrop.point)
        externalDrop.localDragSession = nil
        #expect(!palette.canHandle(externalDrop))
        palette.perform(foreignDrop)
        palette.perform(externalDrop)
        #expect(try f.mutations().isEmpty && other.mutations().isEmpty)
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        palette.end(ownDrop)
        palette.conclude(ownDrop)
        #expect(palette.controller.parent == nil)
        other.end(foreign, foreignDrop)
        #expect(await f.workspace.shutdown())
        #expect(await other.workspace.shutdown())
    }

    @Test func selectedNoncontiguousTabsMoveAsOneOrderedBlockAfterEveryAnimationEnds() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        f.workspace.selectTab(id: "b")
        let selectedRuntime = f.engine.selectedID
        let runtimes = Set(f.workspace.tabs.map(\.runtimeID))
        var navigations = 0
        f.sidebar.didSelectTab = { navigations += 1 }
        try f.toggleSelection()
        // Selection order differs from sidebar order. Lifting C must still
        // carry the stable block [A, C], without changing the active page.
        f.select(row: 2, section: 2)
        f.select(row: 0, section: 2)
        f.sidebar.render()
        f.sidebar.render()
        #expect(f.table.isEditing)
        #expect(Set(f.table.indexPathsForSelectedRows ?? []) == Set([
            IndexPath(row: 0, section: 2), IndexPath(row: 2, section: 2),
        ]))
        #expect(f.workspace.selectedTabID == "b" && f.engine.selectedID == selectedRuntime)
        #expect(navigations == 0)
        #expect(try f.mutations().isEmpty)
        let drag = try f.begin(row: 2, section: 2, expectedItems: 2)
        #expect(drag.beginRows == [IndexPath(row: 2, section: 2), IndexPath(row: 0, section: 2)])
        #expect(drag.beginResponses[.init(row: 2, section: 2)]?.count == 1)
        #expect(drag.beginResponses[.init(row: 0, section: 2)]?.count == 1)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 1, section: 2, fraction: 0.1))
        #expect(f.sidebar.tableView(f.table, canHandle: drop))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move && proposal.intent == .unspecified)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        let mutations = try f.mutations()
        #expect(mutations.count == 1)
        #expect(mutations.first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "a"), .init(entityType: .tab, entityID: "c")],
            destination: .tabs(spaceID: "source", placement: .temporary, pinnedFolderID: nil),
            before: .init(entityType: .tab, entityID: "b")
        )])
        #expect(f.todayIDs == ["a", "c", "b"])
        #expect(coordinator.droppedItems.map(ObjectIdentifier.init) == drag.items.map(ObjectIdentifier.init))
        try #require(coordinator.animations.count == 2)
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])
        #expect(f.workspace.selectedTabID == "b" && f.engine.selectedID == selectedRuntime)
        #expect(Set(f.workspace.tabs.map(\.runtimeID)) == runtimes && f.engine.closed.isEmpty)

        // A newer tree and reversed terminal/completion order must not release
        // the captured rows while either group's preview is still animating.
        #expect(f.document.removeTab(id: "b"))
        f.sidebar.tableView(f.table, dropSessionDidEnd: drop)
        coordinator.animations[1].finish()
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])
        coordinator.animations[0].finish()
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.c"])
        let currentTab = f.workspace.selectedTabID
        let currentRuntime = f.engine.selectedID
        try f.toggleSelection()
        #expect(!f.table.isEditing && (f.table.indexPathsForSelectedRows ?? []).isEmpty)
        #expect(f.sidebar.navigationItem.rightBarButtonItems?.contains { $0 === f.dismissButton } == true)
        #expect(f.workspace.selectedTabID == currentTab && f.engine.selectedID == currentRuntime)
        #expect(await f.workspace.shutdown())
    }

    @Test func inlineGroupPreviewCompletionsKeepRowsHeldThroughTheSessionTerminals() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        try f.toggleSelection()
        f.select(row: 0, section: 2)
        f.select(row: 2, section: 2)
        let drag = try f.begin(row: 2, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 1, section: 2, fraction: 0.1))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal, completesInline: true)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        #expect(coordinator.droppedItems.count == 2)
        #expect(coordinator.animations.map(\.completionCount) == [1, 1])
        #expect(f.todayIDs == ["a", "c", "b"])
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])
        f.sidebar.tableView(f.table, dragSessionDidEnd: drag)
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.b", "browser.tab.c"])
        f.sidebar.tableView(f.table, dropSessionDidEnd: drop)
        #expect(f.rowIDs(section: 2) == ["browser.tab.a", "browser.tab.c", "browser.tab.b"])
        #expect(try f.mutations().count == 1)
        #expect(await f.workspace.shutdown())
    }

    @Test func beginningOnAnUnselectedRowReplacesTheGroupAndMovesOnlyThatRow() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        try f.toggleSelection()
        f.select(row: 0, section: 2)
        f.select(row: 2, section: 2)
        let drag = try f.begin(row: 1, section: 2)
        #expect(drag.beginRows == [IndexPath(row: 1, section: 2)])
        #expect(f.table.indexPathsForSelectedRows == [IndexPath(row: 1, section: 2)])
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 2, section: 2, fraction: 0.9))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        let mutations = try f.mutations()
        #expect(mutations.count == 1)
        #expect(mutations.first?.operations == [.move(
            items: [.init(entityType: .tab, entityID: "b")],
            destination: .tabs(spaceID: "source", placement: .temporary, pinnedFolderID: nil),
            after: .init(entityType: .tab, entityID: "c")
        )])
        #expect(f.todayIDs == ["a", "c", "b"])
        f.end(drag, drop)
        coordinator.animation.finish()
        #expect(await f.workspace.shutdown())
    }

    @Test func selectedBlockNoOpAndEscapeCancelLeaveTheDurableQueueUnchanged() async throws {
        let f = try SidebarDragFixture()
        defer { f.cleanup() }
        await f.start()
        try f.toggleSelection()
        f.select(row: 1, section: 2)
        f.select(row: 0, section: 2)
        let before = try f.durableState()
        let drag = try f.begin(row: 1, section: 2, expectedItems: 2)
        let noOp = SidebarDropSession(drag: drag, point: f.point(row: 2, section: 2, fraction: 0.1))
        let noOpProposal = f.hover(noOp)
        #expect(noOpProposal.operation == .forbidden)
        let noOpCoordinator = SidebarDropCoordinator(session: noOp, proposal: noOpProposal)
        f.sidebar.tableView(f.table, performDropWith: noOpCoordinator)
        #expect(noOpCoordinator.droppedItems.isEmpty)
        f.end(drag, noOp)
        #expect(try f.durableState() == before)

        let cancelled = try f.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: cancelled, point: f.point(row: 2, section: 2, fraction: 0.9))
        let proposal = f.hover(drop)
        #expect(proposal.operation == .move)
        let command = try #require(f.sidebar.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        let action = try #require(command.action)
        #expect(UIApplication.shared.sendAction(action, to: f.sidebar, from: command, for: nil))
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        f.sidebar.tableView(f.table, performDropWith: coordinator)
        #expect(coordinator.droppedItems.isEmpty)
        f.end(cancelled, drop)
        #expect(try f.durableState() == before)
        #expect(await f.workspace.shutdown())
    }

    @Test func selectedBlockRejectsTheWholeMoveWhenOneRootDisappearsOrChangesContainer() async throws {
        for remove in [true, false] {
            let f = try SidebarDragFixture()
            defer { f.cleanup() }
            await f.start()
            try f.toggleSelection()
            f.select(row: 0, section: 2)
            f.select(row: 2, section: 2)
            let drag = try f.begin(row: 0, section: 2, expectedItems: 2)
            let drop = SidebarDropSession(drag: drag, point: f.point(row: 1, section: 2, fraction: 0.1))
            let proposal = f.hover(drop)
            #expect(proposal.operation == .move)
            if remove {
                #expect(f.document.removeTab(id: "c"))
            } else {
                #expect(f.document.setPlacement(
                    tabID: "c", placement: .spacePinned, spaceID: "source", pinnedFolderID: "folder"
                ))
            }
            let afterConcurrentChange = try f.durableState()
            let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
            f.sidebar.tableView(f.table, performDropWith: coordinator)
            #expect(coordinator.droppedItems.isEmpty)
            #expect(try f.durableState() == afterConcurrentChange)
            #expect(f.todayIDs == ["a", "b"])
            f.end(drag, drop)
            #expect(await f.workspace.shutdown())
        }
    }

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
        try f.toggleSelection()
        f.select(row: 1, section: 1)
        f.select(row: 0, section: 1)
        #expect(f.workspace.selectedTabID == "deep" && f.engine.selectedID == selectedRuntime)
        #expect(f.rowIDs(section: 1).count == 5)
        // An empty descendant callback may never become a native drag. It must
        // not require a terminal callback to unlock the selection controls.
        let abandoned = SidebarDragSession()
        #expect(f.sidebar.tableView(f.table, itemsForBeginning: abandoned, at: .init(row: 1, section: 1)).isEmpty)
        try f.toggleSelection()
        #expect(!f.table.isEditing)
        try f.toggleSelection()
        f.select(row: 1, section: 1)
        f.select(row: 0, section: 1)
        // Folder and selected child normalize to one root/preview. Selection
        // must not toggle disclosure, navigate, or freeze descendant membership.
        let drag = try f.begin(row: 1, section: 1)
        #expect(drag.beginRows == [IndexPath(row: 1, section: 1), IndexPath(row: 0, section: 1)])
        #expect(drag.beginResponses[.init(row: 1, section: 1)]?.isEmpty == true)
        #expect(drag.beginResponses[.init(row: 0, section: 1)]?.count == 1)
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

    @Test func sidebarAcceptsOneCompleteGroupAndRejectsForeignExternalOrMismatchedPayloads() async throws {
        let f = try SidebarDragFixture()
        let other = try SidebarDragFixture()
        defer { other.cleanup()
            f.cleanup()
        }
        await f.start()
        await other.start()
        try f.toggleSelection()
        f.select(row: 0, section: 2)
        f.select(row: 2, section: 2)
        let drag = try f.begin(row: 0, section: 2, expectedItems: 2)
        let drop = SidebarDropSession(drag: drag, point: f.point(row: 1, section: 2, fraction: 0.1))
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
        drop.items = [drag.items[0]]
        #expect(!f.sidebar.tableView(f.table, canHandle: drop))
        let foreignDrag = try other.begin(row: 0, section: 2)
        drop.items = [drag.items[0], foreignDrag.items[0]]
        #expect(!f.sidebar.tableView(f.table, canHandle: drop))
        let clone = UIDragItem(itemProvider: drag.items[1].itemProvider)
        clone.localObject = drag.items[1].localObject
        drop.items = [drag.items[0], clone]
        #expect(!f.sidebar.tableView(f.table, canHandle: drop))
        drop.items = drag.items
        #expect(f.sidebar.tableView(f.table, canHandle: drop))
        #expect(f.add(to: drag, row: 0, section: 2).isEmpty)
        f.end(drag, drop)
        other.end(foreignDrag, SidebarDropSession(drag: foreignDrag, point: .zero))
        #expect(try f.mutations().isEmpty)
        #expect(try other.mutations().isEmpty)
        #expect(await f.workspace.shutdown())
        #expect(await other.workspace.shutdown())
    }
}

// MARK: - SidebarManualHoverScheduler

@MainActor private final class SidebarManualHoverScheduler: BrowserMobileSidebarHoverScheduling {
    // MARK: Internal

    struct Request {
        let delay: Duration
        let action: @MainActor () -> Void
        var cancelled = false
    }

    var requests = [Request]()

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        cancel()
        activeIndex = requests.count
        requests.append(.init(delay: delay, action: action))
    }

    func cancel() {
        if let activeIndex {
            requests[activeIndex].cancelled = true
        }
        activeIndex = nil
    }

    /// Deliberately permits canceled requests: production generations, not the
    /// fake's cancellation, must reject a callback already queued for delivery.
    func fire(_ index: Int) {
        if activeIndex == index {
            activeIndex = nil
        }
        requests[index].action()
    }

    // MARK: Private

    private var activeIndex: Int?
}

// MARK: - SidebarHoverTrackingTable

@MainActor private final class SidebarHoverTrackingTable: UITableView {
    override var hasUncommittedUpdates: Bool { forcedUncommittedUpdates || super.hasUncommittedUpdates }

    var reloadCount = 0
    var batchCount = 0
    var pendingBatches = 0
    var insertedRows = [[IndexPath]]()
    var holdsBatchCompletions = false
    var heldBatchCompletions = [(Bool) -> Void]()
    var forcedUncommittedUpdates = false

    override func reloadData() {
        reloadCount += 1
        super.reloadData()
    }

    override func insertRows(at indexPaths: [IndexPath], with animation: UITableView.RowAnimation) {
        insertedRows.append(indexPaths)
        super.insertRows(at: indexPaths, with: animation)
    }

    override func performBatchUpdates(_ updates: (() -> Void)?, completion: ((Bool) -> Void)? = nil) {
        batchCount += 1
        pendingBatches += 1
        super.performBatchUpdates(updates) { [weak self] finished in
            self?.pendingBatches -= 1
            if self?.holdsBatchCompletions == true, let completion {
                self?.heldBatchCompletions.append(completion)
            } else {
                completion?(finished)
            }
        }
    }

    func finishHeldBatches(finished: Bool) {
        let callbacks = heldBatchCompletions
        heldBatchCompletions.removeAll()
        callbacks.forEach { $0(finished) }
    }

    func waitForBatches() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pendingBatches > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
        }
        try #require(pendingBatches == 0)
        layoutIfNeeded()
    }
}

// MARK: - SidebarDragFixture

@MainActor private final class SidebarDragFixture {
    // MARK: Lifecycle

    init(
        sharing shared: SidebarDragFixture? = nil,
        snapshot: BrowserTabSessionSnapshot = sidebarDragSnapshot(),
        hoverScheduler: (any BrowserMobileSidebarHoverScheduling)? = nil,
        trackingTable: SidebarHoverTrackingTable? = nil
    ) throws {
        let document: BrowserMobileProfileDocument
        if let shared {
            self.store = shared.store
            document = shared.document
        } else {
            self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
            try store.bindSyncOwner(owner)
            let changes = BrowserSyncFolderProjection.canonicalChanges(snapshot)
            let events = try changes.enumerated().map { offset, change in
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as! [String: Any]
                var payload = object["data"] as? [String: Any] ?? [:]
                payload["id"] = change.entityID
                let wire: [String: Any] = [
                    "serverSeq": offset + 1, "deviceID": NSNull(), "entityType": change.entityType.rawValue,
                    "entityID": change.entityID, "op": change.op.rawValue, "data": payload,
                    "createdAt": "2026-10-03T00:00:00Z",
                ]
                return try JSONDecoder().decode(
                    BrowserSyncEvent.self,
                    from: JSONSerialization.data(withJSONObject: wire)
                )
            }
            _ = try store.completeFolderSyncBootstrap(events: events, cursor: events.count, for: owner)
            document = try BrowserMobileProfileDocument(store: store, initialSnapshot: store.loadSnapshotStrict())
        }
        self.document = document
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: UUID().uuidString, profileLoader: { document }, preferences: preferences
        )
        self.sidebar = BrowserMobileTabsViewController(
            workspace: workspace,
            hoverScheduler: hoverScheduler ?? BrowserMobileSidebarHoverScheduler(),
            tableView: trackingTable
        )
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
        sidebar.navigationItem.rightBarButtonItem = dismissButton
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
    let dismissButton = UIBarButtonItem(barButtonSystemItem: .done, target: nil, action: nil)

    var table: UITableView { sidebar.tableView }
    var todayIDs: [String] {
        document.snapshot.tabs.filter { $0.placement == .temporary && $0.spaceID == "source" }.compactMap(\.id)
    }

    func start(showNavigation: Bool = false, spaceID: String = "source") async {
        await workspace.restore()
        workspace.selectSpace(id: spaceID)
        let root: UIViewController = showNavigation ? UINavigationController(rootViewController: sidebar) : sidebar
        window.rootViewController = root
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 1100)
        window.makeKeyAndVisible()
        sidebar.loadViewIfNeeded()
        table.estimatedRowHeight = 0
        table.rowHeight = 52
        sidebar.render()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
        sidebar.view.layoutIfNeeded()
        table.layoutIfNeeded()
    }

    func openSpacePalette() throws -> SidebarSpaceDropHarness {
        let button = try #require(sidebar.navigationItem.titleView as? UIButton)
        #expect(button.accessibilityIdentifier == "browser.spaces")
        #expect(button.window === window)
        #expect(button.interactions.contains { $0 is UISpringLoadedInteraction })
        // The installed spring handler dispatches this same real control action.
        // This test proves callback wiring, not physical hover recognition.
        button.sendActions(for: .primaryActionTriggered)
        let controller = try #require(sidebar.children.first {
            $0.viewIfLoaded?.accessibilityIdentifier == "browser.spaceDropTargets"
        })
        sidebar.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let interaction = try #require(controller.view.interactions.compactMap { $0 as? UIDropInteraction }.first)
        return try SidebarSpaceDropHarness(controller: controller, interaction: interaction)
    }

    func toggleSelection() throws {
        let buttons = (sidebar.navigationItem.leftBarButtonItems ?? [])
            + (sidebar.navigationItem.rightBarButtonItems ?? []) + (sidebar.toolbarItems ?? [])
        let button = try #require(buttons.first { $0.accessibilityIdentifier == "browser.selectTabs" })
        let action = try #require(button.action)
        #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
        table.layoutIfNeeded()
    }

    func select(row: Int, section: Int) {
        let indexPath = IndexPath(row: row, section: section)
        table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        sidebar.tableView(table, didSelectRowAt: indexPath)
    }

    func begin(row: Int, section: Int, expectedItems: Int = 1) throws -> SidebarDragSession {
        let session = SidebarDragSession()
        let lifted = IndexPath(row: row, section: section)
        let selected = table.indexPathsForSelectedRows ?? []
        var initialRows = [lifted]
        if table.isEditing, selected.contains(lifted) {
            initialRows += selected.sorted().reversed().filter { $0 != lifted }
        }
        // UIKit asks once per selected row, not once per whole selection. Keep
        // callback order independent from sidebar order and accumulate results
        // only after each callback, as a native drag session does.
        for indexPath in initialRows {
            let items = sidebar.tableView(table, itemsForBeginning: session, at: indexPath)
            session.beginRows.append(indexPath)
            session.beginResponses[indexPath] = items
            session.items.append(contentsOf: items)
        }
        try #require(session.items.count == expectedItems)
        #expect(Set(session.items.map(ObjectIdentifier.init)).count == expectedItems)
        return session
    }

    func point(row: Int, section: Int, fraction: CGFloat) -> CGPoint {
        let rect = table.rectForRow(at: .init(row: row, section: section))
        return .init(x: rect.midX, y: rect.minY + rect.height * fraction)
    }

    /// One input scroll, using measured geometry rather than an assumed row
    /// pitch. Final layout is intentionally not followed by a corrective scroll
    /// or hover: stale production feedback must remain observable.
    func scroll(row: Int, section: Int, fraction: CGFloat, under windowPoint: CGPoint) -> String {
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        table.layoutIfNeeded()
        let index = IndexPath(row: row, section: section)
        func geometry() -> String {
            "window=\(window.bounds), frame=\(table.frame), bounds=\(table.bounds), "
                + "offset=\(table.contentOffset), insets=\(table.contentInset)/\(table.adjustedContentInset), "
                + "row=\(table.rectForRow(at: index)), header=\(table.rectForHeader(inSection: section)), "
                + "pointer=\(table.convert(windowPoint, from: window))"
        }
        let before = geometry()
        let target = table.convert(point(row: row, section: section, fraction: fraction), to: window)
        let offset = table.contentOffset
        let requested = CGPoint(x: offset.x, y: offset.y + target.y - windowPoint.y)
        table.setContentOffset(requested, animated: false)
        table.layoutIfNeeded()
        return "before: \(before); requested=\(requested); after: \(geometry())"
    }

    func add(to session: SidebarDragSession, row: Int, section: Int) -> [UIDragItem] {
        sidebar.tableView(
            table,
            itemsForAddingTo: session,
            at: .init(row: row, section: section),
            point: point(row: row, section: section, fraction: 0.5)
        )
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

// MARK: - SidebarWeakController

@MainActor private final class SidebarWeakController {
    weak var value: BrowserMobileTabsViewController?
}

@MainActor private func retiredSidebarDestination(
    source: SidebarDragFixture, drag: SidebarDragSession
) async throws -> ([SidebarDragAnimation], SidebarWeakController) {
    let destination = try SidebarDragFixture(sharing: source)
    await destination.start(spaceID: "other")
    let released = SidebarWeakController()
    released.value = destination.sidebar
    let animations = autoreleasepool {
        let drop = SidebarDropSession(drag: drag, point: destination.point(row: 0, section: 2, fraction: 0.9))
        destination.sidebar.tableView(destination.table, dropSessionDidEnter: drop)
        let proposal = destination.hover(drop)
        #expect(proposal.operation == .move)
        let coordinator = SidebarDropCoordinator(session: drop, proposal: proposal)
        destination.sidebar.tableView(destination.table, performDropWith: coordinator)
        coordinator.previewTarget = nil
        return coordinator.animations
    }
    destination.sidebar.updateSidebarDragSceneState(.unattached)
    #expect(await destination.workspace.shutdown())
    autoreleasepool {
        destination.cleanup()
    }
    return (animations, released)
}

// MARK: - SidebarSpaceDropHarness

@MainActor private struct SidebarSpaceDropHarness {
    // MARK: Lifecycle

    init(controller: UIViewController, interaction: UIDropInteraction) throws {
        self.controller = controller
        self.interaction = interaction
        self.delegate = try #require(interaction.delegate)
    }

    // MARK: Internal

    let controller: UIViewController
    let interaction: UIDropInteraction
    let delegate: any UIDropInteractionDelegate

    func canHandle(_ session: SidebarDropSession) -> Bool {
        delegate.dropInteraction?(interaction, canHandle: session) ?? false
    }

    func hover(_ session: SidebarDropSession, targetID: String) throws -> UIDropProposal {
        controller.view.layoutIfNeeded()
        let target = try #require(sidebarDragView(withID: targetID, in: controller.view))
        session.point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: controller.view)
        if canHandle(session) {
            delegate.dropInteraction?(interaction, sessionDidEnter: session)
        }
        return try #require(delegate.dropInteraction?(interaction, sessionDidUpdate: session))
    }

    func perform(_ session: SidebarDropSession) {
        delegate.dropInteraction?(interaction, performDrop: session)
    }

    func installAnimations(for items: [UIDragItem], completesInline: Bool = false) -> [SidebarDragAnimation] {
        items.map { item in
            let animation = SidebarDragAnimation(completesInline: completesInline)
            delegate.dropInteraction?(interaction, item: item, willAnimateDropWith: animation)
            return animation
        }
    }

    func end(_ session: SidebarDropSession) {
        delegate.dropInteraction?(interaction, sessionDidEnd: session)
    }

    func exit(_ session: SidebarDropSession) {
        delegate.dropInteraction?(interaction, sessionDidExit: session)
    }

    func conclude(_ session: SidebarDropSession) {
        delegate.dropInteraction?(interaction, concludeDrop: session)
    }
}

@MainActor private func sidebarDragView(withID id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    for child in view.subviews {
        if let found = sidebarDragView(withID: id, in: child) {
            return found
        }
    }
    return nil
}

// MARK: - SidebarDragDropSession

@MainActor private class SidebarDragDropSession: NSObject, UIDragDropSession {
    // MARK: Internal

    var items = [UIDragItem]()
    var point = CGPoint.zero
    var allowsMoveOperation = true
    var isRestrictedToDraggingApplication = true
    var pointProvider: ((UIView) -> CGPoint)?
    private(set) var locationQueryCount = 0

    func fixLocation(_ point: CGPoint, in window: UIWindow) {
        fixedWindowPoint = point
        coordinateWindow = window
    }

    func location(in view: UIView) -> CGPoint {
        locationQueryCount += 1
        if let fixedWindowPoint, let coordinateWindow {
            return view.convert(fixedWindowPoint, from: coordinateWindow)
        }
        return pointProvider?(view) ?? point
    }

    func hasItemsConforming(toTypeIdentifiers _: [String]) -> Bool { true }
    func canLoadObjects(ofClass _: any NSItemProviderReading.Type) -> Bool { false }

    // MARK: Private

    private weak var coordinateWindow: UIWindow?
    private var fixedWindowPoint: CGPoint?
}

// MARK: - SidebarDragSession

@MainActor private final class SidebarDragSession: SidebarDragDropSession, UIDragSession {
    var localContext: Any?
    var beginRows = [IndexPath]()
    var beginResponses = [IndexPath: [UIDragItem]]()
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
    // MARK: Lifecycle

    init(completesInline: Bool = false) { self.completesInline = completesInline }

    // MARK: Internal

    let completesInline: Bool
    var completionCount = 0
    var completions = [(UIViewAnimatingPosition) -> Void]()

    func addAnimations(_ animations: @escaping () -> Void) { animations() }
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {
        if completesInline {
            completionCount += 1
            completion(.end)
        } else {
            completions.append(completion)
        }
    }

    func finish() {
        let pending = completions
        completions.removeAll()
        for completion in pending {
            completionCount += 1
            completion(.end)
        }
    }
}

// MARK: - SidebarDropCoordinator

@MainActor private final class SidebarDropCoordinator: NSObject, UITableViewDropCoordinator {
    // MARK: Lifecycle

    init(session: SidebarDropSession, proposal: UITableViewDropProposal, completesInline: Bool = false) {
        self.session = session
        self.proposal = proposal
        self.items = session.items.map { SidebarDropItem($0) }
        self.completesInline = completesInline
        self.animation = SidebarDragAnimation(completesInline: completesInline)
    }

    // MARK: Internal

    let items: [any UITableViewDropItem]
    let destinationIndexPath: IndexPath? = nil
    let proposal: UITableViewDropProposal
    let session: any UIDropSession
    let completesInline: Bool
    let animation: SidebarDragAnimation
    var animations = [SidebarDragAnimation]()
    var droppedItems = [UIDragItem]()
    var previewTarget: UIDragPreviewTarget?

    func drop(_ item: UIDragItem, to target: UIDragPreviewTarget) -> any UIDragAnimating {
        previewTarget = target
        droppedItems.append(item)
        let nextAnimation = animations.isEmpty ? animation : SidebarDragAnimation(completesInline: completesInline)
        animations.append(nextAnimation)
        return nextAnimation
    }

    func drop(_: UIDragItem, toRowAt _: IndexPath) -> any UIDragAnimating {
        Issue.record("Expected semantic preview target, not UIKit row insertion")
        return SidebarDragAnimation()
    }

    func drop(_: UIDragItem, intoRowAt _: IndexPath, rect _: CGRect) -> any UIDragAnimating {
        Issue.record("Expected semantic preview target")
        return SidebarDragAnimation()
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

private func sidebarInterwindowSnapshot() -> BrowserTabSessionSnapshot {
    let base = sidebarDragSnapshot()
    return .init(
        spaces: base.spaces,
        pinnedTabFolders: (base.pinnedTabFolders ?? []) + [
            .init(id: "destination-folder", spaceID: "other", title: "Destination", pinnedSiblingRank: 1),
        ],
        tabs: base.tabs + [
            .init(
                id: "destination-pin",
                urlString: "about:blank",
                placement: .spacePinned,
                spaceID: "other",
                pinnedFolderID: "destination-folder",
                pinnedSiblingRank: 1
            ),
            .init(id: "destination-page", urlString: "about:blank", spaceID: "other"),
        ]
    )
}

private func sidebarLongListSnapshot() -> BrowserTabSessionSnapshot {
    .init(
        spaces: [.init(id: "source", title: "Source", systemImageName: "globe")],
        tabs: (0..<80).map { .init(id: "row-\($0)", urlString: "about:blank", spaceID: "source") }
    )
}

private func sidebarLongFolderSnapshot() -> BrowserTabSessionSnapshot {
    .init(spaces: [
        .init(id: "source", title: "Source", systemImageName: "globe"),
        .init(id: "other", title: "Other", systemImageName: "globe"),
    ], pinnedTabFolders: (0..<40).map {
        .init(
            id: "folder-\($0)",
            spaceID: "source",
            title: "Folder \($0)",
            isExpanded: false,
            pinnedSiblingRank: Double($0)
        )
    }, tabs: (0..<40).map {
        .init(
            id: "child-\($0)",
            urlString: "about:blank",
            placement: .spacePinned,
            spaceID: "source",
            pinnedFolderID: "folder-\($0)",
            pinnedSiblingRank: 0
        )
    } + [.init(id: "drag", urlString: "about:blank", spaceID: "other")])
}

private func sidebarManySpacesSnapshot() -> BrowserTabSessionSnapshot {
    .init(spaces: [.init(id: "source", title: "Source", systemImageName: "globe")] + (0..<12).map {
        .init(id: "space-\($0)", title: "Space \($0)", systemImageName: "globe")
    }, tabs: [.init(id: "drag", urlString: "about:blank", spaceID: "source")])
}
