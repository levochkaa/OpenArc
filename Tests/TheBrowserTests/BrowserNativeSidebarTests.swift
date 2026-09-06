import AppKit
import Testing

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
            pointer: CGPoint(x: 10, y: 20)
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
        state.selectedPinnedTabIDs = [pinned.id]
        let ids = state.pinnedTabFolderCreationTabIDs(fromTabID: clicked.id, in: .temporary)
        #expect(ids.contains(clicked.id))
        #expect(ids.contains(pinned.id))
        #expect(try ids.contains(#require(model.selectedTabID)))
        #expect(state.pinnedTabFolderCreationTabIDs(fromTabID: clicked.id, in: .app).isEmpty)
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
            closeDescriptor: BrowserCommands.archiveTab
        )
        #expect(row.renameField.pendingFocus)
        #expect(row.control(
            row.renameField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(commits.isEmpty)
        #expect(cancellations == 1)
        row.update(
            tab: tab(),
            selected: true,
            renaming: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab
        )
        #expect(!row.renameField.pendingFocus)
        #expect(!row.renameField.focusPermission())
        row.update(
            tab: tab(),
            selected: true,
            renaming: true,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab
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
                pressure: 1
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
            closeDescriptor: BrowserCommands.archiveTab
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
        state.updateSpacePagerScroll(by: 200, in: state.snapshot, pageWidth: 240)
        #expect(state.spacePagerDragTranslation > 0)
        #expect(state.spacePagerDragTranslation < 240 * 0.14)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(model.selectedSpaceID == first)
        state.updateSpacePagerScroll(by: -100, in: state.snapshot, pageWidth: 240)
        state.finishSpacePagerScroll(in: state.snapshot, pageWidth: 240)
        #expect(model.selectedSpaceID == second)
        #expect(!state.isSpacePagerDragging)
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
            pressure: 0
        ))
        row.mouseEntered(with: event)
        row.layoutSubtreeIfNeeded()
        #expect(!row.closeButton.isHidden)
        #expect(row.titleLabel.frame.width < oldWidth)
        #expect(row.titleLabel.frame.maxX < row.closeButton.frame.minX)
        #expect(row.titleLabel.lineBreakMode == .byTruncatingTail)
        #expect(row.titleLabel.cell?.isScrollable == false)
        #expect(row.titleLabel.cell?.wraps == false)
    }

    @Test func newTabGlyphsMatchTheOriginalCenteredRowWithoutShowingAWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
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
                height: #require(points.map(\.y).max()) - #require(points.map(\.y).min())
            )
        }
        let symbol = try inkBounds(0..<Int(30 * scale))
        let text = try inkBounds(Int(30 * scale)..<Int(115 * scale))
        #expect(abs(symbol.midY - text.midY) <= scale * 0.75)
        #expect((text.minX - symbol.maxX) / scale <= 12)
        #expect(!window.isVisible)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/thebrowser-new-tab-native.png"))
    }

    // MARK: Private

    private func tab() -> BrowserChromeModel.Tab {
        .init(id: "tab", syncID: "tab", spaceID: "space", title: "Example", urlString: "https://example.com")
    }

    private func makeModel() -> (BrowserChromeModel, FakeBrowserTabDriver) {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: "TheBrowserNativeSidebarTests.\(UUID().uuidString)")!
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
            allTabsClosedHandler: {}
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
            canReload: model.canReload
        )
    }
}
