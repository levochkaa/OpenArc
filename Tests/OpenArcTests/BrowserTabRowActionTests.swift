// BrowserTabRowActionTests.swift

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
        #expect(
            f.model.temporaryTabs.first?.id == pinnedCopy,
            "A pinned tab's copy opens at the top of the temporary tabs",
        )
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
            muted: true,
        )
        row.layoutSubtreeIfNeeded()
        #expect(!row.muteButton.isHidden)
        #expect(
            row.muteButton.frame.maxX <= row.titleLabel.frame.minX,
            "The speaker sits between the icon and the title",
        )
        var unmutes = 0
        row.onToggleMute = { unmutes += 1 }
        row.muteButton.performClick(nil)
        #expect(unmutes == 1)
        f.model.setTabMuted(false, id: x)
        #expect(!f.model.isTabMuted(id: x))
        #expect(f.driver.audioMuteRequests.last?.muted == false)

        // A tab with sound shows a speaker that mutes it.
        f.driver.onMediaStateChanged?(x, BrowserTabMediaState(
            isPlaying: true, audible: true, video: false, hasPreviousTrack: false, hasNextTrack: false, title: "",
        ))
        #expect(f.model.sidebarSnapshot.audibleTabIDs == [x])
        row.update(
            tab: tab,
            selected: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
            audible: true,
        )
        row.layoutSubtreeIfNeeded()
        #expect(!row.muteButton.isHidden)
        #expect(row.muteButton.accessibilityIdentifier() == "browser.sidebar.mute-tab.\(x)")
        f.driver.onMediaStateChanged?(x, nil)
        #expect(f.model.sidebarSnapshot.audibleTabIDs.isEmpty)

        // Pinned rows show it too, after the pinned icon.
        var pinned = try #require(f.model.tabs.first { $0.placement == .spacePinned })
        pinned.pinnedURLString = pinned.urlString
        let pinnedRow = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        pinnedRow.update(
            tab: pinned,
            selected: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
            audible: true,
        )
        pinnedRow.layoutSubtreeIfNeeded()
        #expect(!pinnedRow.muteButton.isHidden)
        #expect(pinnedRow.muteButton.frame.maxX <= pinnedRow.titleLabel.frame.minX)
        row.update(tab: tab, selected: false, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        #expect(row.muteButton.isHidden)
    }

    @Test func formatFontRunsThePagesEditingCommandInTheShownTab() {
        let f = SidebarDragFixture(temporary: ["x"])
        let x = f.id("x")
        f.model.selectTab(id: x)
        for style in [BrowserTextStyle.bold, .italic, .underline] {
            f.model.applyTextStyle(style)
            #expect(f.driver.evaluatedScripts.last?.tabID == x)
            #expect(f.driver.evaluatedScripts.last?.code == "document.execCommand('\(style.rawValue)'); undefined")
        }
    }

    @Test func aTabUsingTheCameraOrMicrophoneShowsARecordingDot() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        f.driver.onCaptureChanged?(x, true)
        f.driver.onCaptureChanged?("gone", true)
        #expect(f.model.sidebarSnapshot.recordingTabIDs == [x], "Only tabs that still exist")

        let tab = try #require(f.model.tabs.first { $0.id == x })
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            tab: tab,
            selected: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
            audible: true,
            recording: true,
        )
        row.layoutSubtreeIfNeeded()
        #expect(!row.recordingDot.isHidden)
        #expect(row.recordingDot.frame.minX >= BrowserChromeLayout.sidebarRowLeadingColumnWidth - 2)
        #expect(row.recordingDot.frame.maxX <= row.muteButton.frame.minX, "The dot leads the speaker")
        #expect(row.muteButton.frame.maxX <= row.titleLabel.frame.minX)

        let tile = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 60, height: 48))
        tile.update(
            tab: tab,
            appTile: true,
            selected: false,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
            recording: true,
        )
        tile.layoutSubtreeIfNeeded()
        #expect(!tile.recordingDot.isHidden)
        #expect(tile.recordingDot.frame.minX < 10 && tile.recordingDot.frame.minY < 10, "Favorites lead with it")

        let y = try #require(f.model.tabs.first { $0.id == f.id("y") })
        let chip = BrowserNativeSidebarSplitChipView(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
        chip.update(tab: y, focused: false, recording: true)
        chip.layoutSubtreeIfNeeded()
        #expect(!chip.recordingDot.isHidden)
        chip.update(tab: y, focused: false)
        #expect(chip.recordingDot.isHidden)

        f.driver.onCaptureChanged?(x, false)
        #expect(f.model.sidebarSnapshot.recordingTabIDs.isEmpty)
        f.driver.onCaptureChanged?(x, true)
        f.driver.onRenderProcessTerminated?(x, 1)
        #expect(f.model.sidebarSnapshot.recordingTabIDs.isEmpty, "A crashed page captures nothing")
        row.update(tab: tab, selected: false, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        #expect(row.recordingDot.isHidden)
    }

    @Test func aPinnedTabAwayFromItsPageShowsASlashBetweenIconAndTitle() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        var pinned = try #require(f.model.tabs.first { $0.placement == .spacePinned })
        pinned.pinnedURLString = pinned.urlString
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(tab: pinned, selected: false, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
        row.layoutSubtreeIfNeeded()
        #expect(row.pinnedSlash.isHidden, "A pinned tab on its pinned page has no slash")
        let titleOnPinnedPage = row.titleLabel.frame.minX

        pinned.pinnedURLString = "https://example.com/pinned"
        #expect(pinned.canResetToPinnedURL)
        for selected in [false, true] {
            row.update(tab: pinned, selected: selected, isResizing: false, closeDescriptor: BrowserCommands.archiveTab)
            row.layoutSubtreeIfNeeded()
            #expect(!row.pinnedSlash.isHidden, "Shown without hover, selected or not")
            #expect(row.pinnedSlash.frame.minX >= BrowserChromeLayout.sidebarRowLeadingColumnWidth / 2 + 8)
            #expect(row.pinnedSlash.frame.maxX < row.titleLabel.frame.minX)
            #expect(row.titleLabel.frame.minX > titleOnPinnedPage)
        }

        row.update(
            tab: pinned,
            selected: true,
            renaming: true,
            isResizing: false,
            closeDescriptor: BrowserCommands.archiveTab,
        )
        #expect(row.pinnedSlash.isHidden, "Renaming hides it")
    }

    @Test func aFolderIconIsFlatWhileCollapsedAndTiltedOpenWhileExpanded() {
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        for expanded in [false, true, false] {
            row.update(
                folder: .init(
                    id: "folder",
                    spaceID: "space",
                    parentFolderID: nil,
                    title: "Folder",
                    systemImageName: nil,
                    isExpanded: expanded,
                    pinnedSiblingRank: nil,
                ),
                renaming: false,
                indentLevel: 0,
                dropTargeted: false,
                isResizing: false,
                resetID: 0,
            )
            #expect(row.folderIcon.isTilted == expanded)
        }
    }

    @Test func aSplitMovesToAnotherSpaceWholeAndArchivesAsOneItem() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        let x = f.id("x")
        let y = f.id("y")
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
        let a = f.id("a")
        let b = f.id("b")
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
    @Test func pinDuplicateResetAndFolderCommandsActOnTheSelection() {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("child", "folder")],
            temporary: ["x"],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder", isExpanded: false)],
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
        #expect(!f.model.pinnedTabFolders.contains { !$0.isExpanded })
        #expect(!f.model.setActiveSpaceFoldersExpanded(true))
        #expect(f.model.setActiveSpaceFoldersExpanded(false))
        #expect(f.model.pinnedTabFolders.allSatisfy { !$0.isExpanded })
    }

    @Test func newFolderIsEmptyAndLeavesTheSelectedTabWhereItIs() throws {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        let folderID = try #require(f.model.createFolderInSelectedSpace())
        #expect(f.model.pinnedTabFolders.first { $0.id == folderID }?.title == BrowserStrings
            .pinnedTabFolderDefaultTitle)
        #expect(f.model.folderToRename == folderID)
        #expect(f.model.pinnedTabFolders.first { $0.id == folderID }?.pinnedSiblingRank == 2, "After a and b")
        let tab = f.model.tabs.first { $0.id == f.id("x") }
        #expect(tab?.placement == .temporary && tab?.pinnedFolderID == nil)
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

// MARK: - BrowserPictureInPictureTests

@Suite(.serialized)
@MainActor struct BrowserPictureInPictureTests {
    @Test func leavingATabSendsItsVideoToPictureInPictureUntilTheUserReturns() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        let x = f.id("x")
        let y = f.id("y")
        let z = f.id("z")
        f.model.selectTab(id: x)
        let start = f.driver.pictureInPictureRequests.count
        f.model.selectTab(id: y)
        #expect(f.driver.pictureInPictureRequests.dropFirst(start).map(\.tabID) == [x])
        #expect(f.driver.pictureInPictureRequests.last?.active == true)
        f.model.selectTab(id: x)
        #expect(
            f.driver.pictureInPictureRequests.dropFirst(start).map(\.active) == [true, false, true],
            "Returning to x brings its video back and y's goes to Picture in Picture",
        )
        // Moving focus between panes of a split keeps both on screen.
        #expect(f.model.openInSplitView(tabID: z))
        let beforeFocus = f.driver.pictureInPictureRequests.filter(\.active).count
        f.model.selectTab(id: x)
        #expect(f.driver.pictureInPictureRequests.filter(\.active).count == beforeFocus)
        f.model.userPreferencesStore.pictureInPictureEnabled = false
        let beforeDisabled = f.driver.pictureInPictureRequests.filter(\.active).count
        f.model.selectTab(id: y)
        #expect(f.driver.pictureInPictureRequests.filter(\.active).count == beforeDisabled)
    }
}

// MARK: - BrowserZoomCommandTests

@Suite(.serialized)
@MainActor struct BrowserZoomCommandTests {
    @Test func zoomFollowsTheSelectedTabAndUsesTheZoomKeys() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        #expect(!f.model.canResetZoom)
        #expect(f.model.canZoomIn && f.model.canZoomOut)
        f.model.zoomIn()
        #expect(f.model.zoomPercent == 110)
        #expect(f.model.canResetZoom)
        f.model.selectTab(id: f.id("y"))
        #expect(f.model.zoomPercent == 100, "The shown zoom is the page's own")
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.zoomPercent == 110)
        // The engine zooms per site; a tab of the same site shows that zoom.
        f.driver.zoomLevelsByTabID[f.id("y")] = f.driver.zoomLevelsByTabID[f.id("x")]
        f.model.selectTab(id: f.id("y"))
        #expect(f.model.zoomPercent == 110)
        f.model.selectTab(id: f.id("x"))
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
            charactersIgnoringModifiers: "à",
        ) == .resetZoom)
    }
}

// MARK: - BrowserSplitNameTests

@Suite(.serialized)
@MainActor struct BrowserSplitNameTests {
    @Test func aRenamedSplitKeepsItsNameAndIconAndShowsThemInItsRow() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        let group = try #require(f.model.selectedSplitGroup)
        #expect(f.model.setSplitTitle("  Research  ", groupID: group.id))
        #expect(f.model.setSplitIcon("book", groupID: group.id))
        let saved = try #require(f.store.savedSnapshots.last?.splitGroups?.first)
        #expect(saved.title == "Research" && saved.systemImageName == "book")
        let decoded = try JSONDecoder().decode(
            BrowserTabSplitGroupSessionSnapshot.self,
            from: JSONEncoder().encode(saved),
        )
        #expect(decoded.title == "Research", "The name survives the stored JSON")
        let members = f.model.splitPaneTabIDs(of: group)
        #expect(f.model.sidebarSnapshot.splitNames[members] == .init(title: "Research", systemImageName: "book"))

        let tabs = members.compactMap { id in f.model.tabs.first { $0.id == id } }
        let row = BrowserNativeSidebarRowNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.update(
            split: tabs,
            focusedTabID: f.model.selectedTabID,
            selected: true,
            name: .init(title: "Research", systemImageName: "book"),
            isResizing: false,
        )
        row.layoutSubtreeIfNeeded()
        #expect(!row.titleLabel.isHidden && row.titleLabel.stringValue == "Research")

        #expect(f.model.setSplitTitle("", groupID: group.id))
        #expect(f.model.sidebarSnapshot.splitNames.isEmpty, "An empty name brings the pane chips back")
    }
}

// MARK: - BrowserResetSpaceTabsTests

@MainActor struct BrowserResetSpaceTabsTests {
    @Test func resetAllTabsInThisSpaceReturnsPinnedTabsToTheirPages() {
        let f = SidebarDragFixture(pinned: [("a", nil), ("b", nil)], temporary: ["x"])
        #expect(!f.model.canResetSpaceTabs(), "Nothing has left its pinned page")
        f.model.selectTab(id: f.id("b"))
        let a = f.id("a")
        let b = f.id("b")
        f.driver.emitUpdate(id: a, urlString: "https://a.example/deep")
        f.driver.emitUpdate(id: b, urlString: "https://b.example/deep")
        #expect(f.model.canResetSpaceTabs() && !f.model.canResetSpaceTabs(spaceID: "t"))

        #expect(f.model.resetSpaceTabs())
        #expect(f.driver.targetedNavigationRequests.last?.id == b, "The shown tab reloads its pinned page")
        #expect(f.driver.targetedNavigationRequests.last?.urlString.hasPrefix("https://b.example") == true)
        #expect(f.driver.confirmedCloseRequests.contains { $0.id == a }, "A hidden pinned tab unloads")
        #expect(f.model
            .tabs
            .first { $0.userTitleOverride == "a" }?
            .urlString
            .hasPrefix("https://a.example/deep") == false)
    }

    @Test func resettingKeepsTheSplitPanesOfAHiddenSplitLoaded() {
        let f = SidebarDragFixture(pinned: [("a", nil), ("b", nil)], temporary: ["x"])
        f.model.selectTab(id: f.id("a"))
        #expect(f.model.openInSplitView(tabID: f.id("b")))
        f.model.selectTab(id: f.id("x"))
        let a = f.id("a")
        let b = f.id("b")
        f.driver.emitUpdate(id: a, urlString: "https://a.example/deep")
        f.driver.emitUpdate(id: b, urlString: "https://b.example/deep")
        #expect(f.model.resetSpaceTabs())
        #expect(!f.driver.confirmedCloseRequests.contains { $0.id == a || $0.id == b }, "The hidden split stays whole")
        #expect(Set(f.driver.targetedNavigationRequests.suffix(2).map(\.id)) == [a, b])
    }
}

// MARK: - BrowserViewSourceTests

@MainActor struct BrowserViewSourceTests {
    @Test func viewSourceOpensThePagesSourceAsATab() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.canViewSource)
        #expect(f.model.viewSourceOfSelectedTab())
        #expect(f.driver.createdTabRequests.last?.urlString == "view-source:https://x.example")
        #expect(BrowserCommandID.viewSource.defaultDescriptor.shortcut
            == BrowserKeyboardShortcut("u", modifiers: [.command, .option]))

        // Chromium reports the source view by its inner URL; the tab keeps its own.
        let source = try #require(f.model.selectedTabID)
        f.driver.emitUpdate(id: source, urlString: "https://x.example")
        #expect(f.model.tabs.first { $0.id == source }?.urlString == "view-source:https://x.example")
        #expect(!f.model.canViewSource, "A source view has no source of its own")
    }
}
