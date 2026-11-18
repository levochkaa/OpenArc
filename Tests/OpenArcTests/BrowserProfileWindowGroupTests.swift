// BrowserProfileWindowGroupTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserProfileWindowGroupTests {
    /// Two windows of one profile over one store, as the application sets them up.
    @MainActor private final class Pair {
        let first: SidebarDragFixture
        let second: BrowserChromeModel
        let secondDriver = FakeBrowserTabDriver()
        let group = BrowserProfileWindowGroup()

        init(
            pinned: [(String, String?)] = [("a", nil)],
            temporary: [String] = ["x", "y"],
            beforeJoining: (SidebarDragFixture) -> Void = { _ in },
        ) {
            self.first = SidebarDragFixture(pinned: pinned, temporary: temporary)
            beforeJoining(first)
            let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserProfileWindowGroupTests"))!
            self.second = BrowserChromeModel(
                tabDriver: secondDriver,
                sessionSnapshotStore: first.store,
                sessionPreferencesStore: InMemorySessionPreferencesStore(),
                commandBarSuggestionProvider: FakeSuggestionProvider(),
                userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
                shortcutStore: BrowserShortcutStore(userDefaults: defaults),
                extensionManager: FakeBrowserExtensionManager(),
                windowTitleHandler: { _ in },
                allTabsClosedHandler: {},
            )
            group.add(first.model)
            group.add(second)
            second.isAdditionalWindow = true
            second.firstSpaceID = first.model.selectedSpaceID
            second.handleContextReady()
            secondDriver.flushPendingCreateEvents()
        }

        func titles(_ model: BrowserChromeModel) -> [String] {
            model.tabs.map { $0.userTitleOverride ?? $0.title }
        }
    }

    @Test func aTabDroppedOnTheOtherWindowsSidebarLandsAtItsLineAndShowsThere() throws {
        let pair = Pair(temporary: ["x", "y", "z"])
        let source = pair.first.model
        let x = try #require(source.tabs.first { $0.userTitleOverride == "x" })
        let zHere = try #require(pair.second.tabs.first { $0.userTitleOverride == "z" })
        #expect(pair.second.acceptTabs(
            ids: [x.id],
            fromWindowOf: source,
            at: .init(container: .temporary("s"), beforeItem: .tab(zHere.id)),
        ))
        func today(_ model: BrowserChromeModel, _ space: String = "s") -> [String] {
            model.sidebarSnapshot.temporaryTabs(in: space).map { $0.userTitleOverride ?? $0.title }
        }
        #expect(today(pair.second) == ["y", "x", "z"])
        #expect(today(source) == ["y", "x", "z"], "The other window lists the same order")
        #expect(pair.second.tabs.first { $0.id == pair.second.selectedTabID }?.syncID == x.syncID)

        // Into the Space the other window shows.
        pair.second.selectSpace(id: "t")
        let y = try #require(source.tabs.first { $0.userTitleOverride == "y" })
        #expect(pair.second.acceptTabs(ids: [y.id], fromWindowOf: source, at: .init(container: .temporary("t"))))
        #expect(today(pair.second, "t") == ["y"])
        #expect(today(source, "t") == ["y"])
        #expect(!pair.second.acceptTabs(ids: [y.id], fromWindowOf: source, at: .init(container: .app)))
    }

    @Test func anAdditionalWindowStartsWithTheSameTabsAndNoPages() {
        let pair = Pair()
        #expect(pair.second.tabs.map(\.syncID) == pair.first.model.tabs.map(\.syncID))
        #expect(pair.secondDriver.createdTabRequests.isEmpty, "Pages stay in the first window")
        #expect(pair.second.selectedTabID == nil)
        #expect(pair.second.selectedSpaceID == pair.first.model.selectedSpaceID)
    }

    @Test func aNewWindowShowsTitlesThatCameWithoutASave() throws {
        var syncID = ""
        let pair = Pair { first in
            let tab = first.model.tabs.last!
            syncID = tab.syncID
            first.driver.emitUpdate(id: tab.id, title: "Google")
        }
        let row = try #require(pair.second.tabs.first { $0.syncID == syncID })
        #expect(row.title == "Google", "The row shows the page's title, not its host")
    }

    @Test func itSeesTheSessionEvenWhenLaunchRestoreIsOff() throws {
        let pair = Pair()
        pair.first.model.userPreferencesStore.restoreWindowsOnLaunch = false
        let defaults =
            try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserProfileWindowGroupTests")))
        let prefs = BrowserUserPreferencesStore(userDefaults: defaults)
        prefs.restoreWindowsOnLaunch = false
        let driver = FakeBrowserTabDriver()
        let third = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: pair.first.store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: prefs,
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        pair.group.add(third)
        third.isAdditionalWindow = true
        third.handleContextReady()
        #expect(third.tabs.count == pair.first.model.tabs.count)
        #expect(pair.first.model.tabs.count == 3, "The first window keeps its tabs")
    }

    @Test func aNewTabShowsInTheOtherWindowWithoutAPage() throws {
        let pair = Pair()
        try pair.second.openURLInNewTab(#require(URL(string: "https://new.example")))
        pair.secondDriver.flushPendingCreateEvents()
        let created = try #require(pair.second.tabs.last { $0.urlString.contains("new.example") })
        let there = try #require(pair.first.model.tabs.first { $0.syncID == created.syncID })
        #expect(there.urlString.contains("new.example"))
        #expect(!pair.first.driver.createdTabRequests.contains { $0.urlString.contains("new.example") })
        #expect(pair.second.hasPage(forSyncID: created.syncID))
        #expect(!pair.first.model.hasPage(forSyncID: created.syncID))
    }

    @Test func openingATabMovesItsPageAcross() throws {
        let pair = Pair()
        let source = pair.first.model
        let syncID = try #require(source.tabs.first { $0.userTitleOverride == "x" }?.syncID)
        let idThere = try #require(source.tabs.first { $0.syncID == syncID }?.id)
        source.selectTab(id: idThere)
        #expect(source.hasPage(forSyncID: syncID))

        let idHere = try #require(pair.second.tabs.first { $0.syncID == syncID }?.id)
        pair.second.selectTab(id: idHere)

        #expect(pair.secondDriver.createdTabRequests.count == 1)
        #expect(pair.second.hasPage(forSyncID: syncID))
        #expect(!source.hasPage(forSyncID: syncID))
        #expect(pair.first.driver.closedTabRequests.map(\.id).contains(idThere))
        #expect(source.selectedTabID != nil && source.tabs.first { $0.id == source.selectedTabID }?.syncID != syncID)
        #expect(source.tabs.contains { $0.syncID == syncID }, "The row stays")
        #expect(pair.second.tabs.first { $0.id == pair.second.selectedTabID }?.syncID == syncID)
    }

    @Test func openingATabBringsItsLivePageAcross() throws {
        let pair = Pair()
        let source = pair.first.model
        let syncID = try #require(source.tabs.first { $0.userTitleOverride == "x" }?.syncID)
        let idThere = try #require(source.tabs.first { $0.syncID == syncID }?.id)
        source.selectTab(id: idThere)
        pair.first.driver.detachablePageTabIDs = [idThere]
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        pair.first.driver.movedPagePicture = bitmap.representation(using: .png, properties: [:])

        let idHere = try #require(pair.second.tabs.first { $0.syncID == syncID }?.id)
        pair.second.selectTab(id: idHere)

        // The first window keeps the tab selected and shows a picture of its page.
        let selectedThere = try #require(source.tabs.first { $0.id == source.selectedTabID })
        #expect(selectedThere.syncID == syncID)
        #expect(source.showsMovedPage)
        #expect(source.movedPagePicture != nil)

        #expect(pair.secondDriver.createdTabRequests.isEmpty, "The page does not load again")
        #expect(pair.first.driver.detachedPageTabIDs == [idThere])
        #expect(!pair.first.driver.closedTabRequests.map(\.id).contains(idThere))
        let adopted = try #require(pair.secondDriver.adoptedPages.first)
        #expect(adopted.page == idThere && adopted.makeActive)
        let shown = try #require(pair.second.tabs.first { $0.id == pair.second.selectedTabID })
        #expect(shown.syncID == syncID && shown.id == adopted.id)
        #expect(shown.creationState == .ready && shown.canGoBack)
        #expect(pair.second.hasPage(forSyncID: syncID))
        #expect(!source.hasPage(forSyncID: syncID))
        #expect(source.tabs.contains { $0.syncID == syncID }, "The row stays")

        // A click on the picture brings the same page back.
        pair.secondDriver.detachablePageTabIDs = [adopted.id]
        source.showMovedPageHere()
        #expect(pair.first.driver.adoptedPages.first?.page == adopted.id)
        #expect(source.hasPage(forSyncID: syncID))
        #expect(!source.showsMovedPage && source.movedPageTabIDs.isEmpty)
        #expect(!pair.second.hasPage(forSyncID: syncID))
        #expect(pair.second.showsMovedPage, "Now the second window shows the picture")
    }

    @Test func aNewPageTitleShowsInTheOtherWindow() throws {
        let pair = Pair()
        let source = pair.first.model
        let id = pair.first.id("x")
        let syncID = try #require(source.tabs.first { $0.id == id }?.syncID)
        pair.first.driver.emitUpdate(id: id, title: "Renamed page")
        #expect(pair.second.tabs.first { $0.syncID == syncID }?.title == "Renamed page")
    }

    @Test func aBlankWindowOffersTheOtherWindowsTabsAsPagesBeforeTyping() throws {
        let first = SidebarDragFixture(temporary: ["x"])
        let defaults =
            try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserProfileWindowGroupTests.blank")))
        let blank = BrowserChromeModel(
            tabDriver: FakeBrowserTabDriver(),
            sessionSnapshotStore: first.store,
            sessionPreferencesStore: InMemorySessionPreferencesStore(),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowMode: .blank,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        let group = BrowserProfileWindowGroup()
        group.add(first.model)
        group.add(blank)
        blank.handleContextReady()
        let other = try #require(first.model.tabs.first { $0.id == first.id("x") })

        blank.commandBarModel.present()
        let row = blank.commandBarModel.suggestions.first { $0.resolvedURLString == other.urlString }
        #expect(row != nil, "The other window's tab is offered")
        #expect(row?.kind == .history && row?.tabIDs.isEmpty == true, "As a page to open here")
        blank.commandBarModel.dismiss()
    }

    @Test func aClosingWindowLeavesItsPagesToTheOthers() throws {
        let pair = Pair()
        let source = pair.first.model
        let x = pair.first.id("x")
        let y = pair.first.id("y")
        source.selectTab(id: x)
        pair.first.driver.detachablePageTabIDs = [x]
        let syncX = try #require(source.tabs.first { $0.id == x }?.syncID)
        let syncY = try #require(source.tabs.first { $0.id == y }?.syncID)
        let rowY = try #require(pair.second.tabs.first { $0.syncID == syncY }?.id)
        pair.second.selectTab(id: rowY)

        source.handPagesToOtherWindows()

        #expect(pair.secondDriver.adoptedPages.map(\.page) == [x])
        #expect(pair.secondDriver.adoptedPages.first?.makeActive == false, "It stays in the background")
        #expect(pair.second.hasPage(forSyncID: syncX))
        #expect(pair.second.tabs.first { $0.id == pair.second.selectedTabID }?.syncID == syncY)
        #expect(pair.secondDriver.createdTabRequests.count == 1, "Only the selected tab loaded; x did not")
    }

    @Test func aClosedWindowClosesThePagesItKept() {
        let pair = Pair()
        let source = pair.first.model
        let pages = source.tabs.filter { source.hasPage(forSyncID: $0.syncID) }.map(\.id)
        #expect(!pages.isEmpty)
        source.prepareForTermination()
        source.closePagesOfClosedWindow()
        let closed = Set(pair.first.driver.closedTabRequests.filter(\.forceClose).map(\.id))
        #expect(Set(pages).isSubset(of: closed))
    }

    @Test func aPageThatCannotMoveLoadsAgain() throws {
        let pair = Pair()
        let source = pair.first.model
        let syncID = try #require(source.tabs.first { $0.userTitleOverride == "x" }?.syncID)
        let idThere = try #require(source.tabs.first { $0.syncID == syncID }?.id)
        source.selectTab(id: idThere)

        let idHere = try #require(pair.second.tabs.first { $0.syncID == syncID }?.id)
        pair.second.selectTab(id: idHere)

        #expect(pair.secondDriver.adoptedPages.isEmpty)
        #expect(pair.secondDriver.createdTabRequests.count == 1)
        #expect(pair.first.driver.closedTabRequests.map(\.id).contains(idThere))
    }

    @Test func closingATabRemovesItEverywhere() throws {
        let pair = Pair()
        let id = pair.first.id("y")
        let syncID = try #require(pair.first.model.tabs.first { $0.id == id }?.syncID)
        pair.first.model.closeTab(id: id, forceClose: true)
        pair.first.driver.emitClose(id: id)
        #expect(!pair.second.tabs.contains { $0.syncID == syncID })
        #expect(pair.second.tabs.map(\.syncID) == pair.first.model.tabs.map(\.syncID))
    }

    @Test func closingATabWithoutAPageStillArchivesIt() throws {
        let pair = Pair()
        let syncID = try #require(pair.second.tabs.first { $0.userTitleOverride == "y" }?.syncID)
        let id = try #require(pair.second.tabs.first { $0.syncID == syncID }?.id)
        pair.second.closeTab(id: id)
        #expect(!pair.second.tabs.contains { $0.syncID == syncID })
        #expect(!pair.first.model.tabs.contains { $0.syncID == syncID })
    }

    @Test func spacesAndFoldersFollow() throws {
        let pair = Pair()
        let spaces = pair.first.model.spaces.count
        pair.first.model.createNewSpace()
        #expect(pair.second.spaces.count == spaces + 1)
        let added = try #require(pair.first.model.spaces.last)
        #expect(pair.second.spaces.last?.id == added.id)
        pair.first.model.setTheme(BrowserSpaceTheme(key: .init(1, 0.5, 0.3)), forSpaceID: added.id)
        #expect(pair.second.spaceThemesByID[added.id] != nil)
        #expect(pair.second.selectedSpaceID != added.id, "Each window keeps its own Space")
    }

    @Test func choosingASpaceDoesNotTakeAPageFromTheOtherWindow() throws {
        let pair = Pair()
        let source = pair.first.model
        let live = try #require(source.tabs.first { source.hasPage(forSyncID: $0.syncID) })
        pair.second.selectSpace(id: "t")
        pair.second.selectSpace(id: "s")
        #expect(source.hasPage(forSyncID: live.syncID), "It stays where it is")
        #expect(pair.first.driver.closedTabRequests.isEmpty)
    }

    @Test func extraWindowsAreRememberedForTheNextLaunch() throws {
        let suite = BrowserTestDefaults.suiteName("BrowserProfileWindowGroupTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BrowserAdditionalWindowRecord.load(from: defaults).isEmpty)
        let record = BrowserAdditionalWindowRecord(
            profileID: "Default", frame: "{{1, 2}, {3, 4}}", spaceID: "s", selectedTabSyncID: "x",
        )
        BrowserAdditionalWindowRecord.save([record], to: defaults)
        #expect(BrowserAdditionalWindowRecord.load(from: defaults) == [record])
        BrowserAdditionalWindowRecord.save([], to: defaults)
        #expect(defaults.object(forKey: BrowserAdditionalWindowRecord.defaultsKey) == nil)
    }

    @Test func aRestoredWindowTakesItsTabBack() throws {
        let pair = Pair()
        let syncID = try #require(pair.first.model.tabs.first { $0.userTitleOverride == "x" }?.syncID)
        pair.second.selectTab(syncID: syncID)
        #expect(pair.second.selectedTabSyncID == syncID)
        #expect(!pair.first.model.hasPage(forSyncID: syncID))
    }

    @Test func onlyTheOldestWindowExpiresTabs() {
        let pair = Pair()
        #expect(pair.second.isAdditionalWindow)
        pair.group.remove(pair.first.model)
        #expect(!pair.second.isAdditionalWindow, "The next window takes over")
    }
}
