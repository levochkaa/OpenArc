import AppKit
import Testing

// MARK: - BrowserTabRowActionTests

@Suite(.serialized)
@MainActor struct BrowserTabRowActionTests {
    @Test func duplicateOpensTheSamePageBelowATemporaryTab() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        let copy = try #require(f.model.duplicateTab(id: x))
        #expect(f.model.temporaryTabs.map(\.id) == [x, copy, f.id("y")])
        #expect(f.model.tabs.first { $0.id == copy }?.urlString == "https://x.example")
        #expect(f.model.selectedTabID == copy)

        let pinnedCopy = try #require(f.model.duplicateTab(id: f.id("a")))
        #expect(f.model.temporaryTabs.first?.id == pinnedCopy, "A pinned tab's copy opens at the top of the temporary tabs")
        #expect(f.pinnedNames() == ["a", "b"])
    }

    @Test func moveToPutsTheTabAtTheTopOfTheSameSectionInAnotherSpace() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        #expect(f.model.spacesForMovingTab(id: f.id("y")).map(\.id) == ["t"])
        #expect(f.model.moveTabToSpace(id: f.id("y"), spaceID: "t"))
        #expect(f.model.tabs.first { $0.id == f.id("y") }?.spaceID == "t")
        #expect(f.model.tabs.first { $0.id == f.id("y") }?.placement == .temporary)
        #expect(f.model.temporaryTabs.map(\.id) == [f.id("x")])
        #expect(!f.model.moveTabToSpace(id: f.id("x"), spaceID: "s"), "A tab cannot move to its own Space")
        #expect(f.model.moveTabToSpace(id: f.id("a"), spaceID: "t"))
        #expect(f.model.tabs.first { $0.id == f.id("a") }?.placement == .spacePinned)
    }

    @Test func muteSilencesTheEngineAndShowsASpeakerThatUnmutes() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        f.model.setTabMuted(true, id: x)
        #expect(f.model.isTabMuted(id: x))
        #expect(f.driver.audioMuteRequests.last?.tabID == x && f.driver.audioMuteRequests.last?.muted == true)
        #expect(f.model.sidebarSnapshot.mutedTabIDs == [x])
        let tab = try #require(f.model.tabs.first { $0.id == x })
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            tab: tab,
            selected: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
            muted: true
        )
        row.layoutSubtreeIfNeeded()
        #expect(!row.muteButton.isHidden)
        #expect(row.titleLabel.frame.maxX <= row.muteButton.frame.minX, "The title stops before the speaker")
        var unmutes = 0
        row.onToggleMute = { unmutes += 1 }
        row.muteButton.performClick(nil)
        #expect(unmutes == 1)
        f.model.setTabMuted(false, id: x)
        #expect(!f.model.isTabMuted(id: x))
        #expect(f.driver.audioMuteRequests.last?.muted == false)
    }

    @Test func aSplitMovesToAnotherSpaceWholeAndArchivesAsOneItem() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        let (x, y) = (f.id("x"), f.id("y"))
        f.model.selectTab(id: x)
        #expect(f.model.openInSplitView(tabID: y))
        #expect(f.model.moveSplitToSpace(containingTabID: x, spaceID: "t"))
        let group = try #require(f.model.splitGroup(containingTabID: x))
        #expect(f.model.splitPaneTabIDs(of: group) == [x, y], "The split survives the move")
        #expect(f.model.tabs.filter { $0.spaceID == "t" }.map(\.id) == [x, y])
        #expect(!f.model.moveSplitToSpace(containingTabID: f.id("z"), spaceID: "t"), "A single tab is not a split")
        f.model.closeSplit(containingTabID: y)
        #expect(!f.model.tabs.contains { $0.id == x || $0.id == y })
        #expect(f.names(f.model.tabs.filter { $0.placement == .temporary }) == ["z"])
    }

    @Test func archivingASplitUnloadsPinnedPanesInsteadOfRemovingThem() {
        let f = SidebarDragFixture(temporary: ["x"])
        let (a, b) = (f.id("a"), f.id("b"))
        f.model.selectTab(id: a)
        #expect(f.model.openInSplitView(tabID: b))
        f.model.closeSplit(containingTabID: a)
        #expect(f.pinnedNames() == ["a", "b"], "Pinned panes keep their rows")
    }

    @Test func archivingOthersOrAboveClosesOnlyTemporaryTabs() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z", "w"])
        #expect(f.model.temporaryTabIDsAbove(id: f.id("z")) == [f.id("x"), f.id("y")])
        #expect(f.model.temporaryTabIDsAbove(id: f.id("a")).isEmpty, "Pinned rows have no such action")
        f.model.closeTemporaryTabsAbove(id: f.id("y"))
        #expect(f.names(f.model.temporaryTabs) == ["y", "z", "w"])
        f.model.selectTab(id: f.id("z"))
        #expect(f.model.openInSplitView(tabID: f.id("w")))
        #expect(f.model.otherTemporaryTabIDs(id: f.id("z")) == [f.id("y")], "A split keeps its own panes")
        f.model.closeOtherTemporaryTabs(id: f.id("z"))
        #expect(f.names(f.model.temporaryTabs) == ["z", "w"])
        #expect(f.pinnedNames() == ["a", "b"], "Pinned tabs stay")
    }
}

// MARK: - BrowserTabCommandTests

@Suite(.serialized)
@MainActor struct BrowserTabCommandTests {
    @Test func pinDuplicateResetAndFolderCommandsActOnTheSelection() throws {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("child", "folder")],
            temporary: ["x"],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder", isExpanded: false)]
        )
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.pinToggleTitle == BrowserStrings.menuPinTab)
        #expect(f.model.togglePinSelectedTab())
        #expect(f.model.tabs.first { $0.id == f.id("x") }?.placement == .spacePinned)
        #expect(f.model.pinToggleTitle == BrowserStrings.menuUnpinTab)
        #expect(f.model.togglePinSelectedTab())
        #expect(f.model.tabs.first { $0.id == f.id("x") }?.placement == .temporary)

        #expect(f.model.duplicateSelectedTab())
        #expect(f.model.temporaryTabs.count == 2)
        #expect(!f.model.canResetSelectedTabToPinnedURL, "A temporary tab has no pinned URL")

        #expect(f.model.canSetActiveSpaceFoldersExpanded(true))
        #expect(!f.model.canSetActiveSpaceFoldersExpanded(false))
        #expect(f.model.setActiveSpaceFoldersExpanded(true))
        #expect(f.model.pinnedTabFolders.allSatisfy { $0.isExpanded })
        #expect(!f.model.setActiveSpaceFoldersExpanded(true))
        #expect(f.model.setActiveSpaceFoldersExpanded(false))
        #expect(f.model.pinnedTabFolders.allSatisfy { !$0.isExpanded })
    }

    @Test func renameTabRevealsTheRowAndAsksTheSidebarToEditIt() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        var reveals = 0
        f.model.onRevealSidebar = { reveals += 1 }
        let request = f.model.sidebarRenameRequestID
        #expect(f.model.renameSelectedTab())
        #expect(f.model.sidebarRenameRequestID == request + 1)
        #expect(reveals == 1)
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(!f.model.canRenameSelectedTab, "A split row has no title field")
    }
}

// MARK: - BrowserZoomCommandTests

@Suite(.serialized)
@MainActor struct BrowserZoomCommandTests {
    @Test func zoomFollowsTheSelectedTabAndUsesArcKeys() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        #expect(!f.model.canResetZoom)
        #expect(f.model.canZoomIn && f.model.canZoomOut)
        f.model.zoomIn()
        #expect(f.model.zoomPercent == 110)
        #expect(f.model.canResetZoom)
        f.model.selectTab(id: f.id("y"))
        #expect(f.model.zoomPercent == 100, "Another tab keeps its own zoom")
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.zoomPercent == 110)
        f.model.resetZoom()
        #expect(f.model.zoomPercent == 100)

        #expect(BrowserCommands.zoomIn.shortcut == BrowserKeyboardShortcut("="))
        #expect(BrowserCommands.resetZoom.shortcut == BrowserKeyboardShortcut("0"))
        #expect(BrowserCommands.stopLoading.shortcut == BrowserKeyboardShortcut("."))
        #expect(f.model.showDeveloperTools())
        #expect(f.driver.devToolsCount == 1)
        #expect(BrowserCommands.developerTools.shortcut == BrowserKeyboardShortcut("i", modifiers: [.command, .option]))
        // AZERTY types "à" on the 0 key.
        #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: 29,
            modifierFlags: [.command],
            charactersIgnoringModifiers: "à"
        ) == .resetZoom)
    }
}
