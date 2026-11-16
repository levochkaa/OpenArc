// BrowserNativeSidebarTests.swift

import AppKit
import Testing

// MARK: - BrowserNativeSidebarTests

@Suite(.serialized)
@MainActor struct BrowserNativeSidebarTests {
    // MARK: Internal

    @Test func clearRequiresSecondActionForActiveTemporaryTab() throws {
        let (model, _) = makeModel()
        let active = try #require(model.temporaryTabs.last)
        model.selectTab(id: active.id)
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        try state.clearTemporaryTabs(in: #require(model.selectedSpaceID))
        #expect(model.temporaryTabs.map(\.id) == [active.id])
        #expect(state.activeTemporaryTabClearConfirmationTabID == active.id)
        state.update(snapshot: snapshot(model), sidebarWidth: 240, isResizing: false)
        try state.clearTemporaryTabs(in: #require(model.selectedSpaceID))
        #expect(model.temporaryTabs.isEmpty)
        #expect(model.spacePinnedTabs.count == 1)
        #expect(state.activeTemporaryTabClearConfirmationTabID == nil)
    }

    @Test func undoingClearRevokesClearConfirmation() throws {
        let (model, driver) = makeModel()
        let active = try #require(model.temporaryTabs.last)
        model.selectTab(id: active.id)
        let before = model.temporaryTabs.count
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        try state.clearTemporaryTabs(in: #require(model.selectedSpaceID))
        state.update(snapshot: snapshot(model), sidebarWidth: 240, isResizing: false)
        #expect(state.activeTemporaryTabClearConfirmationTabID == active.id)
        for request in driver.closedTabRequests {
            driver.emitClose(id: request.id)
        }
        model.undoManager.undo()
        driver.flushPendingCreateEvents()
        state.update(snapshot: snapshot(model), sidebarWidth: 240, isResizing: false)
        #expect(model.temporaryTabs.count > 1 && model.temporaryTabs.count <= before)
        #expect(state.activeTemporaryTabClearConfirmationTabID == nil)
    }

    @Test func changingActiveTabRevokesClearConfirmation() throws {
        let (model, _) = makeModel()
        let active = try #require(model.temporaryTabs.last)
        model.selectTab(id: active.id)
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        state.activeTemporaryTabClearConfirmationTabID = active.id
        try model.selectTab(id: #require(model.spacePinnedTabs.first).id)
        state.update(snapshot: snapshot(model), sidebarWidth: 240, isResizing: false)
        #expect(state.activeTemporaryTabClearConfirmationTabID == nil)
    }

    @Test func resizeCancelsDragAndClearsHover() throws {
        let (model, _) = makeModel()
        let tab = try #require(model.temporaryTabs.first)
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        state.isSidebarHovered = true
        state.drag.begin(
            payload: .init(primary: .tab(tab.id), tabIDs: [tab.id]),
            sourceFrame: CGRect(x: 0, y: 0, width: 240, height: 36),
            start: .zero,
            pointer: CGPoint(x: 10, y: 20),
        )
        #expect(state.isDraggingSidebarItem)
        #expect(state.drag.payload?.primary == .tab(tab.id))
        state.update(snapshot: snapshot(model), sidebarWidth: 280, isResizing: true)
        #expect(!state.isDraggingSidebarItem)
        #expect(state.drag.payload == nil)
        #expect(!state.isSidebarHovered)
        #expect(state.tabRowInteractionResetID == 1)
    }

    @Test func folderCreationKeepsClickedActiveAndMultiSelectedTabs() throws {
        let (model, _) = makeModel()
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        let pinned = try #require(model.spacePinnedTabs.first)
        let clicked = try #require(model.temporaryTabs.first)
        state.selectedSidebarTabIDs = [pinned.id]
        let ids = state.pinnedTabFolderCreationTabIDs(fromTabID: clicked.id, in: .temporary)
        #expect(ids.contains(clicked.id))
        #expect(ids.contains(pinned.id))
        #expect(try ids.contains(#require(model.selectedTabID)))
        #expect(state.pinnedTabFolderCreationTabIDs(fromTabID: clicked.id, in: .app).isEmpty)
    }

    @Test func modifierSelectionIncludesTemporaryRowsAndSurvivesIncomingTabs() throws {
        let f = SidebarDragFixture(apps: ["app"])
        let state = BrowserNativeSidebarState(model: f.model, snapshot: f.model.sidebarSnapshot, sidebarWidth: 240)
        let a = try #require(f.model.tabs.first { $0.id == f.id("a") })
        let x = try #require(f.model.tabs.first { $0.id == f.id("x") })
        let y = try #require(f.model.tabs.first { $0.id == f.id("y") })
        state.handleSidebarTabSelection(a, in: .spacePinned, modifiers: .command)
        state.handleSidebarTabSelection(x, in: .temporary, modifiers: .command)
        #expect(state.selectedSidebarTabIDs == [a.id, x.id])
        f.model.createNewTab()
        f.driver.flushPendingCreateEvents()
        let incoming = try #require(f.model.selectedTabID)
        state.update(snapshot: f.model.sidebarSnapshot, sidebarWidth: 240, isResizing: false)
        #expect(state.selectedSidebarTabIDs == [a.id, x.id])
        state.handleSidebarTabSelection(y, in: .temporary, modifiers: .shift)
        // The new tab sits at the top of Today, inside the range.
        #expect(state.selectedSidebarTabIDs == [a.id, f.id("b"), incoming, x.id, y.id])
        state.toggleSidebarTabSelection(f.id("app"))
        #expect(!state.selectedSidebarTabIDs.contains(f.id("app")))
        f.model.selectSpace(id: "t")
        state.update(snapshot: f.model.sidebarSnapshot, sidebarWidth: 240, isResizing: false)
        #expect(state.selectedSidebarTabIDs.isEmpty)
        #expect(state.sidebarTabSelectionAnchorID == nil)
    }

    @Test func shiftSelectionStartsAtActiveTabAndSkipsCollapsedFolderChildren() throws {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("hidden", "folder"), ("b", nil)],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder", isExpanded: false)],
        )
        f.model.selectTab(id: f.id("a"))
        let state = BrowserNativeSidebarState(model: f.model, snapshot: f.model.sidebarSnapshot, sidebarWidth: 240)
        let y = try #require(f.model.tabs.first { $0.id == f.id("y") })
        state.handleSidebarTabSelection(y, in: .temporary, modifiers: .shift)
        #expect(state.selectedSidebarTabIDs == Set(["a", "b", "x", "y"].map(f.id)))
        #expect(!state.selectedSidebarTabIDs.contains(f.id("hidden")))
    }

    @Test func activeRowModifierClicksSelectInsteadOfRenamingOrResettingPinnedURL() throws {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        var value = tab()
        value.placement = .spacePinned
        value.pinnedURLString = "https://pinned.example"
        row.update(tab: value, selected: true, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        var modifiers = [NSEvent.ModifierFlags]()
        var renames = 0
        var resets = 0
        row.onModifiedSelect = { modifiers.append($0) }
        row.onBeginRename = { renames += 1 }
        row.onBackToPinnedURL = { resets += 1 }
        var separations = 0
        row.onSeparateFromPinnedTab = { separations += 1 }
        // On the icon Command separates the page; on the title it selects.
        for (flag, x) in [(NSEvent.ModifierFlags.command, 120.0), (.shift, 10), (.command, 10)] {
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: CGPoint(x: x, y: 18),
                modifierFlags: flag,
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0,
            ))
            row.onClick(event)
            row.onDoubleClick?(event)
        }
        #expect(modifiers == [.command, .command, .shift, .shift])
        #expect(separations == 2, "Command on the icon, click and double click")
        #expect(renames == 0)
        #expect(resets == 0)
    }

    @Test func folderDoubleClickTogglesInsteadOfRenaming() {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        row.update(
            folder: .init(id: "folder", spaceID: "space", title: "Folder", isExpanded: false),
            renaming: false,
            indentLevel: 0,
            dropTargeted: false,
            isResizing: false,
            resetID: 0,
        )
        var renames = 0
        var toggles = 0
        row.onBeginRename = { renames += 1 }
        row.onToggle = { toggles += 1 }
        row.onDoubleClick?(nil)
        #expect(renames == 0)
        #expect(toggles == 1)
    }

    @Test func pressingATabShowsItBeforeRelease() throws {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        var selections = 0
        var renames = 0
        row.onSelect = { selections += 1 }
        row.onBeginRename = { renames += 1 }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 120, y: 18), modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1,
            ))
        }
        row.update(tab: tab(), selected: false, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        try row.mouseDown(with: event(.leftMouseDown))
        #expect(selections == 1)
        try row.mouseUp(with: event(.leftMouseUp))
        #expect(selections == 1)
        #expect(renames == 0)

        row.update(tab: tab(), selected: true, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        try row.mouseDown(with: event(.leftMouseDown))
        #expect(selections == 1)
        try row.mouseUp(with: event(.leftMouseUp))
        #expect(renames == 1)
    }

    @Test func renamingALongTitleKeepsItsTextWhereTheTitleWas() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = BrowserNativeSurface(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        surface.appearance = NSAppearance(named: .aqua)
        surface.fillColor = .white
        surface.strokeWidth = 0
        window.contentView = surface
        let row = BrowserNativeSidebarRowNSView(frame: surface.bounds)
        surface.addSubview(row)
        let title = "feat(core): multiplayer for-you feed with presence and cursors"
        func update(renaming: Bool) {
            row.update(
                tab: .init(id: "tab", syncID: "tab", spaceID: "space", title: title, urlString: "about:blank"),
                selected: true,
                renaming: renaming,
                isResizing: false,
                closeDescriptor: BrowserCommands.archiveTab,
            )
            surface.layoutSubtreeIfNeeded()
        }
        func leadingInk() throws -> CGFloat {
            let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
            for x in Int((row.renameField.frame.minX - 10) * scale)..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.6 {
                        return CGFloat(x) / scale
                    }
                }
            }
            return .infinity
        }

        update(renaming: false)
        let titleInk = try leadingInk()
        update(renaming: true)
        #expect(window.makeFirstResponder(row.renameField))
        let editor = try #require(row.renameField.currentEditor() as? NSTextView)
        #expect(editor.textContainerInset.height != 0, "The field set its own inset")
        let clip = try #require(editor.superview)
        let clipFrame = row.renameField.convert(clip.bounds, from: clip)
        #expect(clipFrame.minX >= 0, "The editor starts where the title does")
        #expect(clipFrame.maxX <= row.renameField.bounds.maxX)
        editor.insertionPointColor = .clear
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(try abs(leadingInk() - titleInk) <= 0.5)

        // The window's shared editor goes back to how other fields use it.
        update(renaming: false)
        #expect(window.makeFirstResponder(nil))
        #expect(editor.textContainerInset == .zero)
    }

    @Test func aClosedRowFadesUnderItsNeighborsAndAPressSpringsInTheRenderServer() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        window.contentView = list
        let closed = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        let neighbor = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 40, width: 240, height: 36))
        list.addSubview(neighbor)
        list.addSubview(closed)
        for row in [closed, neighbor] {
            row.update(tab: tab(), selected: false, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        }

        let press = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 120, y: 58), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1,
        ))
        neighbor.mouseDown(with: press)
        #expect(neighbor.isPressed)
        #expect(neighbor.layer?.animation(forKey: "press") != nil)
        #expect(neighbor.layer?.affineTransform().a ?? 1 < 1, "The press scale is the model value at once")

        closed.removeAnimated()
        #expect(closed.alphaValue == 0)
        #expect(closed.layer?.animation(forKey: "removal") != nil)
        #expect(list.subviews.first === closed, "It fades under the rows that take its place")
    }

    @Test func activeRowRenamesAndOtherRowsSelect() {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        var selections = 0
        var renames = 0
        row.onSelect = { selections += 1 }
        row.onBeginRename = { renames += 1 }
        row.update(tab: tab(), selected: false, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        #expect(row.accessibilityPerformPress())
        row.update(tab: tab(), selected: true, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        #expect(row.accessibilityPerformPress())
        #expect(selections == 1)
        #expect(renames == 1)
    }

    @Test func renameDoesNotCommitAnUnchangedTitleOrRefocusAfterCancellation() {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        var commits = [String]()
        var cancellations = 0
        row.onCommitRename = { commits.append($0) }
        row.onCancelRename = { cancellations += 1 }
        row.update(
            tab: tab(),
            selected: true,
            renaming: true,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
        )
        #expect(row.renameField.pendingFocus)
        #expect(row.control(
            row.renameField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)),
        ))
        #expect(commits.isEmpty)
        #expect(cancellations == 1)
        row.update(
            tab: tab(),
            selected: true,
            renaming: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
        )
        #expect(!row.renameField.pendingFocus)
        #expect(!row.renameField.focusPermission())
        row.update(
            tab: tab(),
            selected: true,
            renaming: true,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
        )
        row.renameField.stringValue = "Custom name"
        row.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(commits == ["Custom name"])
    }

    @Test func nativeDragSuppressesClickAndUsesSidebarCoordinates() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let row = BrowserNativePressableView(frame: NSRect(x: 10, y: 20, width: 240, height: 36))
        root.addSubview(row)
        row.dragCoordinateView = root
        var clicks = 0
        var drops = [BrowserNativeDragValue]()
        row.onClick = { _ in clicks += 1 }
        row.onDragChanged = { _ in }
        row.onDragEnded = { drops.append($0) }
        func event(_ type: NSEvent.EventType, _ location: NSPoint, _ time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: time,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1,
            ))
        }
        try row.mouseDown(with: event(.leftMouseDown, NSPoint(x: 25, y: 30), 1))
        try row.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 25, y: 100), 1.1))
        try row.mouseUp(with: event(.leftMouseUp, NSPoint(x: 25, y: 110), 1.2))
        #expect(clicks == 0)
        #expect(drops.count == 1)
        #expect(drops[0].startLocation == NSPoint(x: 25, y: 30))
        #expect(drops[0].location == NSPoint(x: 25, y: 110))
        #expect(!row.isDragging)
    }

    @Test func nestedRowKeepsTitleAndRenameEditorInsideItsIndent() {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 180, height: 36))
        row.update(
            tab: tab(),
            selected: true,
            renaming: true,
            indentLevel: 2,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
        )
        row.layoutSubtreeIfNeeded()
        #expect(row.renameField.frame.minX >= BrowserChromeLayout.sidebarPinnedFolderTabIndent * 2)
        #expect(row.bounds.contains(row.renameField.frame))
        #expect(row.closeButton.isHidden)
    }

    @Test func spacePagingUsesThresholdAndResistsOuterEdge() throws {
        let (model, _) = makeModel()
        let first = try #require(model.selectedSpaceID)
        model.createNewSpace()
        let second = try #require(model.selectedSpaceID)
        model.selectSpace(id: first)
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        state.updateSpacePagerScroll(by: -100, in: state.snapshot, pageWidth: 240)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(model.selectedSpaceID == second)
        #expect(!state.isSpacePagerDragging)
        state.update(snapshot: snapshot(model), sidebarWidth: 240, isResizing: false)
        state.updateSpacePagerScroll(by: -200, in: state.snapshot, pageWidth: 240)
        #expect(state.spacePagerDragTranslation < 0)
        #expect(state.spacePagerDragTranslation > -240 * 0.14)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(model.selectedSpaceID == second)
    }

    @Test func swipePastTheFirstSpacePullsTheLibrary() async throws {
        let (model, _) = makeModel()
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        var progress = [CGFloat]()
        var ended = [Bool]()
        state.onLibrarySwipe = { progress.append($0) }
        state.onLibrarySwipeEnded = { ended.append($0) }
        state.updateSpacePagerScroll(by: 417, in: state.snapshot, pageWidth: 240)
        #expect(state.spacePagerDragTranslation == 0, "The page stays while the Library comes")
        #expect(progress == [0.5], "A swipe covers the Library's width at half of the scroll")
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(ended == [true])
        #expect(!state.isSpacePagerDragging)
        state.updateSpacePagerScroll(by: 100, in: state.snapshot, pageWidth: 240)
        try await Task.sleep(nanoseconds: 550_000_000)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(ended == [true, false], "A slow swipe has to pass the middle")
        state.updateSpacePagerScroll(by: 420, in: state.snapshot, pageWidth: 240)
        try await Task.sleep(nanoseconds: 550_000_000)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(ended == [true, false, true], "The middle is the Library's, not the sidebar's")
    }

    @Test func slowSwipeTurnsThePageOnlyPastTheMiddle() async throws {
        let (model, _) = makeModel()
        let first = try #require(model.selectedSpaceID)
        model.createNewSpace()
        let second = try #require(model.selectedSpaceID)
        model.selectSpace(id: first)
        let state = BrowserNativeSidebarState(model: model, snapshot: snapshot(model), sidebarWidth: 240)
        state.updateSpacePagerScroll(by: -200, in: state.snapshot, pageWidth: 240)
        #expect(state.spacePagerDragTranslation == -100, "A swipe moves the page by half of the scroll")
        try await Task.sleep(nanoseconds: 550_000_000)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(model.selectedSpaceID == first)
        state.updateSpacePagerScroll(by: -260, in: state.snapshot, pageWidth: 240)
        try await Task.sleep(nanoseconds: 550_000_000)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(model.selectedSpaceID == second)
    }

    @Test func hoveredCloseButtonReservesSpaceAndTruncatesLongTitle() throws {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 180, height: 36))
        row.update(tab: tab(), selected: true, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        row.titleLabel.stringValue = String(repeating: "A long tab title ", count: 8)
        row.layoutSubtreeIfNeeded()
        let oldWidth = row.titleLabel.frame.width
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0,
        ))
        row.mouseEntered(with: event)
        row.layoutSubtreeIfNeeded()
        #expect(!row.closeButton.isHidden)
        #expect(row.titleLabel.frame.width < oldWidth)
        #expect(row.titleLabel.frame.maxX <= row.closeButton.frame.minX)
        #expect(row.titleLabel.lineBreakMode == .byTruncatingTail)
        #expect(row.titleLabel.cell?.isScrollable == false)
        #expect(row.titleLabel.cell?.wraps == false)
    }

    @Test func newTabGlyphsMatchTheOriginalCenteredRowWithoutShowingAWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = BrowserNativeSurface(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        surface.appearance = NSAppearance(named: .aqua)
        surface.fillColor = .white
        surface.strokeWidth = 0
        window.contentView = surface
        let row = BrowserNativeSidebarRowNSView(frame: surface.bounds)
        surface.addSubview(row)
        row.updateNewTab(isPresented: false, isResizing: false, descriptor: BrowserCommands.newTab)
        row.titleLabel.stringValue = "New Tab"
        surface.layoutSubtreeIfNeeded()
        let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
        func inkBounds(_ range: Range<Int>) throws -> CGRect {
            var points = [CGPoint]()
            for x in range {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.85 {
                        points.append(CGPoint(x: x, y: y))
                    }
                }
            }
            return try CGRect(
                x: #require(points.map(\.x).min()),
                y: #require(points.map(\.y).min()),
                width: #require(points.map(\.x).max()) - #require(points.map(\.x).min()),
                height: #require(points.map(\.y).max()) - #require(points.map(\.y).min()),
            )
        }
        let symbol = try inkBounds(0..<Int(30 * scale))
        let text = try inkBounds(Int(30 * scale)..<Int(115 * scale))
        #expect(abs(symbol.midY - text.midY) <= scale * 0.75)
        #expect((text.minX - symbol.maxX) / scale <= 14)
        #expect(!window.isVisible)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/openarc-new-tab-native.png"))
    }

    @Test(arguments: [BrowserNativeSidebarRowNSView.Kind.tab, .space, .folder])
    func rowTitleIsCenteredLikeItsRenameEditor(kind: BrowserNativeSidebarRowNSView.Kind) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = BrowserNativeSurface(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        surface.appearance = NSAppearance(named: .aqua)
        surface.fillColor = .white
        surface.strokeWidth = 0
        window.contentView = surface
        let row = BrowserNativeSidebarRowNSView(frame: surface.bounds)
        surface.addSubview(row)
        func update(renaming: Bool) {
            switch kind {
            case .folder:
                row.update(
                    folder: .init(id: "folder", spaceID: "space", title: "HOME", isExpanded: false),
                    renaming: renaming,
                    indentLevel: 0,
                    dropTargeted: false,
                    isResizing: false,
                    resetID: 0,
                )
            case .space:
                row.update(
                    space: .init(id: "space", title: "HOME", systemImageName: "house", isPinnedSectionCollapsed: false),
                    renaming: renaming,
                    collapsed: false,
                    hasPinnedTabs: false,
                    dropTargeted: false,
                    isResizing: false,
                    resetID: 0,
                )
            default:
                row.update(
                    tab: .init(id: "tab", syncID: "tab", spaceID: "space", title: "HOME", urlString: "about:blank"),
                    selected: true,
                    renaming: renaming,
                    isResizing: false,
                    closeDescriptor: BrowserCommands.archiveTab,
                )
            }
            surface.layoutSubtreeIfNeeded()
        }
        // The text's vertical middle and its width, in points.
        func textMetrics() throws -> (midY: CGFloat, width: CGFloat) {
            let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
            let columns = Int(row.renameField.frame.minX * scale)..<Int((row.renameField.frame.minX + 40) * scale)
            var rows = [Int]()
            var inkColumns = [Int]()
            for x in columns {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.85 {
                        rows.append(y)
                        inkColumns.append(x)
                    }
                }
            }
            let midY = try CGFloat(#require(rows.min()) + #require(rows.max()) + 1) / 2 / scale
            let width = try CGFloat(#require(inkColumns.max()) - #require(inkColumns.min()) + 1) / scale
            return (midY, width)
        }

        update(renaming: false)
        let title = try textMetrics()
        update(renaming: true)
        #expect(window.makeFirstResponder(row.renameField))
        #expect(row.renameField.currentEditor() != nil)
        let editor = try textMetrics()

        // The text stays put as editing begins, within half a pixel of antialiasing
        // (the Space's 13 pt title rounds one edge row differently).
        #expect(abs(title.midY - editor.midY) <= 0.25, "title \(title), editor \(editor)")
        // The same font draws the same width.
        #expect(abs(title.width - editor.width) <= 0.5, "title \(title), editor \(editor)")
        #expect(abs(title.midY - surface.bounds.midY) <= 0.75, "title \(title), row \(surface.bounds.midY)")
        #expect(!window.isVisible)
    }

    // MARK: Private

    private func tab() -> BrowserChromeModel.Tab {
        .init(id: "tab", syncID: "tab", spaceID: "space", title: "Example", urlString: "https://example.com")
    }

    private func makeModel() -> (BrowserChromeModel, FakeBrowserTabDriver) {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("OpenArcNativeSidebarTests"))!
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(tabs: [
                .init(urlString: "https://pinned.example", placement: .spacePinned),
                .init(urlString: "https://one.example"),
                .init(urlString: "https://two.example"),
            ])),
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 2),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        return (model, driver)
    }

    private func snapshot(_ model: BrowserChromeModel) -> BrowserSidebarSnapshot {
        .init(
            spaces: model.spaces,
            selectedSpaceID: model.selectedSpaceID,
            activeSpace: model.activeSpace,
            isActiveSpacePinnedSectionCollapsed: model.isActiveSpacePinnedSectionCollapsed,
            allTabs: model.tabs,
            pinnedTabFolders: model.pinnedTabFolders,
            appTabs: model.appTabs,
            spacePinnedTabs: model.spacePinnedTabs,
            temporaryTabs: model.temporaryTabs,
            selectedTabID: model.selectedTabID,
            archivableTabIDs: Set((model.spacePinnedTabs + model.temporaryTabs).dropLast().map(\.id)),
            canGoBack: model.canGoBack,
            canGoForward: model.canGoForward,
            canStopLoading: model.canStopLoading,
            canReload: model.canReload,
        )
    }
}

// MARK: - BrowserSwipeAxisLockTests

struct BrowserSwipeAxisLockTests {
    @Test func aGestureThatStartsScrollingStaysAScroll() {
        var lock = BrowserSwipeAxisLock()
        // A sideways drift later in the same gesture leaves the list scrolling.
        let result = answers([(.began, 0, 0), (.changed, 1, 4), (.changed, 20, 1), (.ended, 0, 0)], lock: &lock)
        #expect(result == [false, false, false, false])
    }

    @Test func aSlightlySlantedStartIsStillASwipe() {
        var lock = BrowserSwipeAxisLock()
        let swipe = answers([(.began, 0, 0), (.changed, 2.5, 3), (.changed, 1, 6)], lock: &lock)
        #expect(swipe == [false, true, true])
        // The next gesture chooses again.
        let scroll = answers([(.began, 0, 0), (.changed, 0, 5)], lock: &lock)
        #expect(scroll == [false, false])
    }

    @Test func theFirstMovingPointDecidesSoAListNeverSeesASwipe() {
        var lock = BrowserSwipeAxisLock()
        let result = answers([(.began, -1, 0), (.changed, -2, 3)], lock: &lock)
        #expect(result == [true, true])
    }

    @Test func aYieldedSwipeStaysWithTheListUntilTheNextGesture() {
        var lock = BrowserSwipeAxisLock()
        #expect(answers([(.began, -3, 0)], lock: &lock) == [true])
        lock.yield()
        #expect(answers([(.changed, -9, 0), (.ended, 0, 0)], lock: &lock) == [false, false])
        #expect(answers([(.began, -3, 0)], lock: &lock) == [true])
    }

    @Test func aMouseWheelDecidesEachTick() {
        var lock = BrowserSwipeAxisLock()
        let result = answers([([], 5, 1), ([], 1, 5)], lock: &lock)
        #expect(result == [true, false])
    }

    /// Feeds a gesture's events in order and returns each answer.
    private func answers(_ events: [(NSEvent.Phase, CGFloat, CGFloat)], lock: inout BrowserSwipeAxisLock) -> [Bool] {
        events.map { lock.isSideways(phase: $0.0, dx: $0.1, dy: $0.2) }
    }
}
