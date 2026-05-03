import Foundation
import Testing

@Test
@MainActor
func restoreCreatesTabsInSavedOrderAndSelectsSavedIndex() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            tabURLStrings: [
                "https://one.example",
                "https://two.example",
                "https://three.example",
            ]
        )
    )
    let preferencesStore = InMemorySessionPreferencesStore(
        storedSelectedTabIndex: 1,
        storedSidebarWidth: BrowserChromeModel.maxSidebarWidth * 4
    )
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(
        model.tabs.map(\.urlString) == [
            "https://one.example",
            "https://two.example",
            "https://three.example",
        ]
    )
    #expect(driver.createdTabRequests.map(\.makeActive) == [true, false, false])
    #expect(model.selectedTabID == model.tabs[1].id)
    #expect(driver.selectedTabIDs.last == model.tabs[1].id)
    #expect(model.sidebarWidth == BrowserChromeModel.maxSidebarWidth)
    #expect(model.isSidebarVisible)
}

@Test
@MainActor
func emptySnapshotFallsBackToInitialTab() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.tabs.map(\.urlString) == [BrowserChromeModel.defaultNewTabURLString])
    #expect(driver.createdTabRequests.count == 1)
}

@Test
@MainActor
func launchStartsWithVisibleSidebarEvenIfPreviousInstanceHidIt() {
    let firstDriver = FakeBrowserTabDriver()
    let firstSnapshotStore = InMemorySessionSnapshotStore()
    let firstPreferencesStore = InMemorySessionPreferencesStore()
    let firstModel = makeModel(
        driver: firstDriver,
        snapshotStore: firstSnapshotStore,
        preferencesStore: firstPreferencesStore
    )

    firstModel.handleContextReady()
    firstDriver.flushPendingCreateEvents()
    firstModel.toggleSidebar()
    #expect(!firstModel.isSidebarVisible)

    let secondDriver = FakeBrowserTabDriver()
    let secondSnapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: firstSnapshotStore.savedSnapshots.last
    )
    let secondModel = makeModel(
        driver: secondDriver,
        snapshotStore: secondSnapshotStore,
        preferencesStore: firstPreferencesStore
    )

    secondModel.handleContextReady()
    secondDriver.flushPendingCreateEvents()

    #expect(secondModel.isSidebarVisible)
}

@Test
@MainActor
func persistentURLChangesTriggerSaveButTitleFaviconAndNavigationDoNot() throws {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialSaveCount = snapshotStore.savedSnapshots.count
    let tabID = try tabID(from: model)

    driver.emitUpdate(id: tabID, title: "Renamed", urlString: nil, faviconURLString: nil)
    driver.emitUpdate(
        id: tabID,
        title: nil,
        urlString: nil,
        faviconURLString: "https://one.example/favicon.ico"
    )
    driver.emitNavigationStateChange(id: tabID, canGoBack: true, canGoForward: false)

    #expect(snapshotStore.savedSnapshots.count == initialSaveCount)

    driver.emitUpdate(id: tabID, title: nil, urlString: "https://updated.example", faviconURLString: nil)

    #expect(snapshotStore.savedSnapshots.count == initialSaveCount + 1)
    #expect(snapshotStore.savedSnapshots.last?.tabURLStrings == ["https://updated.example"])
}

@Test
@MainActor
func userTitleOverridePersistsAcrossUpdatesAndRestore() throws {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let tabID = try tabID(from: model)

    model.setUserTitleOverride("Workspace", forTabID: tabID)

    #expect(model.tabs.first?.displayTitle == "Workspace")
    #expect(snapshotStore.savedSnapshots.last?.tabs.first?.userTitleOverride == "Workspace")

    let saveCountAfterOverride = snapshotStore.savedSnapshots.count
    driver.emitUpdate(id: tabID, title: "Updated Page", urlString: nil, faviconURLString: nil)

    #expect(model.tabs.first?.displayTitle == "Workspace")
    #expect(model.tabs.first?.pageTitle == "Updated Page")
    #expect(snapshotStore.savedSnapshots.count == saveCountAfterOverride)

    let restoredDriver = FakeBrowserTabDriver()
    let restoredModel = makeModel(
        driver: restoredDriver,
        snapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: snapshotStore.savedSnapshots.last),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    restoredModel.handleContextReady()
    restoredDriver.flushPendingCreateEvents()

    #expect(restoredModel.tabs.first?.displayTitle == "Workspace")
    #expect(restoredModel.tabs.first?.userTitleOverride == "Workspace")
}

@Test
@MainActor
func createSelectAndClosePersistState() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialSaveCount = snapshotStore.savedSnapshots.count

    model.createNewTab()
    driver.flushPendingCreateEvents()

    #expect(snapshotStore.savedSnapshots.count == initialSaveCount + 1)
    #expect(snapshotStore.savedSnapshots.last?.tabURLStrings.count == 2)
    #expect(preferencesStore.storedSelectedTabIndex == 1)

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id

    model.selectTab(id: firstTabID)

    #expect(preferencesStore.storedSelectedTabIndex == 0)

    model.closeTab(id: secondTabID)

    #expect(snapshotStore.savedSnapshots.last?.tabURLStrings.count == 1)
}

@Test
@MainActor
func sidebarWidthChangesOnlyPersistPreferencesWhenCommitted() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialSnapshotSaveCount = snapshotStore.savedSnapshots.count
    let initialSidebarWidthSaveCount = preferencesStore.savedSidebarWidths.count

    model.setSidebarWidth(BrowserChromeModel.maxSidebarWidth)

    #expect(model.sidebarWidth == BrowserChromeModel.maxSidebarWidth)
    #expect(preferencesStore.savedSidebarWidths.count == initialSidebarWidthSaveCount)
    #expect(snapshotStore.savedSnapshots.count == initialSnapshotSaveCount)

    model.persistSidebarWidthPreferenceIfAllowed()

    #expect(preferencesStore.savedSidebarWidths.count == initialSidebarWidthSaveCount + 1)
    #expect(preferencesStore.savedSidebarWidths.last == BrowserChromeModel.maxSidebarWidth)
    #expect(snapshotStore.savedSnapshots.count == initialSnapshotSaveCount)
}

@Test
@MainActor
func sessionMutationsDoNotPersistSidebarWidthImplicitly() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.setSidebarWidth(BrowserChromeModel.maxSidebarWidth)
    let initialSidebarWidthSaveCount = preferencesStore.savedSidebarWidths.count

    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.selectTab(id: model.tabs[0].id)

    #expect(preferencesStore.savedSidebarWidths.count == initialSidebarWidthSaveCount)
}

@Test
@MainActor
func terminationPersistsLatestSidebarWidthPreference() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.setSidebarWidth(BrowserChromeModel.maxSidebarWidth)

    model.prepareForTermination()

    #expect(preferencesStore.savedSidebarWidths.last == BrowserChromeModel.maxSidebarWidth)
}

@Test
@MainActor
func pinningAndClearingTemporaryTabsPreservesPinnedTabs() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let pinnedTabID = model.tabs[0].id
    model.togglePinned(forTabID: pinnedTabID)

    #expect(model.pinnedTabs.map(\.id) == [pinnedTabID])
    #expect(model.temporaryTabs.count == 2)

    model.clearTemporaryTabs()

    #expect(model.tabs.map(\.id) == [pinnedTabID])
    #expect(model.pinnedTabs.map(\.id) == [pinnedTabID])
    #expect(model.temporaryTabs.isEmpty)
    #expect(snapshotStore.savedSnapshots.last?.tabs.count == 1)
    #expect(snapshotStore.savedSnapshots.last?.tabs.first?.isPinned == true)
}

@Test
@MainActor
func movingTemporaryTabIntoPinnedSectionPinsAndPersistsSidebarOrder() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.moveTab(withID: secondTabID, toPinnedState: true, atSectionIndex: 0)

    #expect(model.tabs.map(\.id) == [secondTabID, firstTabID, thirdTabID])
    #expect(model.pinnedTabs.map(\.id) == [secondTabID])
    #expect(model.temporaryTabs.map(\.id) == [firstTabID, thirdTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.urlString) == [
        model.tabs[0].urlString,
        model.tabs[1].urlString,
        model.tabs[2].urlString,
    ])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.isPinned) == [true, false, false])
}

@Test
@MainActor
func movingPinnedTabIntoTemporarySectionUnpinsAndPersistsSidebarOrder() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.togglePinned(forTabID: thirdTabID)
    model.moveTab(withID: thirdTabID, toPinnedState: false, atSectionIndex: 1)

    #expect(model.tabs.map(\.id) == [firstTabID, thirdTabID, secondTabID])
    #expect(model.pinnedTabs.isEmpty)
    #expect(model.temporaryTabs.map(\.id) == [firstTabID, thirdTabID, secondTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.isPinned) == [false, false, false])
}

@Test
@MainActor
func movingWithinPinnedSectionReordersPinnedTabs() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.togglePinned(forTabID: firstTabID)
    model.togglePinned(forTabID: secondTabID)
    model.moveTab(withID: secondTabID, toPinnedState: true, atSectionIndex: 0)

    #expect(model.tabs.map(\.id) == [secondTabID, firstTabID, thirdTabID])
    #expect(model.pinnedTabs.map(\.id) == [secondTabID, firstTabID])
    #expect(model.temporaryTabs.map(\.id) == [thirdTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.isPinned) == [true, true, false])
}

@Test
@MainActor
func movingTabsBetweenSectionEndsKeepsMovedTabsSelectable() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id
    let fourthTabID = model.tabs[3].id

    model.togglePinned(forTabID: firstTabID)
    model.togglePinned(forTabID: secondTabID)
    model.selectTab(id: thirdTabID)
    model.moveTab(withID: thirdTabID, toPinnedState: true, atSectionIndex: model.pinnedTabs.count)

    #expect(model.tabs.map(\.id) == [firstTabID, secondTabID, thirdTabID, fourthTabID])
    #expect(model.pinnedTabs.map(\.id) == [firstTabID, secondTabID, thirdTabID])
    #expect(model.temporaryTabs.map(\.id) == [fourthTabID])
    #expect(model.selectedTabID == thirdTabID)
    #expect(preferencesStore.storedSelectedTabIndex == 2)

    model.moveTab(withID: firstTabID, toPinnedState: false, atSectionIndex: model.temporaryTabs.count)
    model.selectTab(id: firstTabID)

    #expect(model.tabs.map(\.id) == [secondTabID, thirdTabID, fourthTabID, firstTabID])
    #expect(model.pinnedTabs.map(\.id) == [secondTabID, thirdTabID])
    #expect(model.temporaryTabs.map(\.id) == [fourthTabID, firstTabID])
    #expect(model.selectedTabID == firstTabID)
    #expect(driver.selectedTabIDs.last == firstTabID)
    #expect(preferencesStore.storedSelectedTabIndex == 3)
}

@Test
@MainActor
func archiveTabsBelowUsesVisibleSidebarOrder() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let pinnedTabID = model.tabs[2].id
    let firstTemporaryTabID = model.tabs[0].id
    let secondTemporaryTabID = model.tabs[1].id
    let thirdTemporaryTabID = model.tabs[3].id

    model.togglePinned(forTabID: pinnedTabID)

    #expect(model.hasTabsBelow(id: pinnedTabID))
    model.closeTabsBelow(id: pinnedTabID)

    #expect(model.tabs.map(\.id) == [pinnedTabID])
    #expect(
        driver.closedTabRequests.map(\.id) == [
            firstTemporaryTabID,
            secondTemporaryTabID,
            thirdTemporaryTabID,
        ]
    )
    #expect(!model.hasTabsBelow(id: pinnedTabID))
}

@Test
@MainActor
func archiveSelectedTabClosesCurrentTabAndSelectsFallback() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.selectTab(id: secondTabID)

    #expect(model.canArchiveSelectedTab)
    #expect(model.archiveSelectedTab())

    #expect(model.tabs.map(\.id) == [firstTabID, thirdTabID])
    #expect(model.selectedTabID == thirdTabID)
    #expect(driver.selectedTabIDs.last == thirdTabID)
    #expect(driver.closedTabRequests.last == FakeBrowserTabDriver.CloseTabRequest(id: secondTabID, forceClose: false))
}

@Test
@MainActor
func expiredTemporaryTabsArchiveButPinnedTabsRemain() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://pinned.example",
                    isPinned: true,
                    lastActivityTimestamp: 0
                ),
                BrowserTabSessionSnapshotTab(
                    urlString: "https://stale.example",
                    lastActivityTimestamp: 0
                ),
                BrowserTabSessionSnapshotTab(
                    urlString: "https://selected.example",
                    lastActivityTimestamp: 0
                ),
            ]
        )
    )
    let preferencesStore = InMemorySessionPreferencesStore(
        storedSelectedTabIndex: 2,
        storedTemporaryTabLifetime: .twelveHours
    )
    let now = Date(timeIntervalSince1970: 24 * 60 * 60)
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore,
        dateProvider: { now }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.tabs.map(\.urlString) == [
        "https://pinned.example",
        "https://selected.example",
    ])
    #expect(model.pinnedTabs.map(\.urlString) == ["https://pinned.example"])
    #expect(model.temporaryTabs.map(\.urlString) == ["https://selected.example"])
    #expect(driver.closedTabRequests.map(\.id) == ["tab-2"])
}

@Test
@MainActor
func changingTemporaryTabLifetimePersistsAndArchivesExpiredTabs() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    var currentDate = Date(timeIntervalSince1970: 0)
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore,
        dateProvider: { currentDate }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    currentDate = Date(timeIntervalSince1970: 8 * 24 * 60 * 60)
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.setTemporaryTabLifetime(.sevenDays)

    #expect(preferencesStore.storedTemporaryTabLifetime == .sevenDays)
    #expect(model.temporaryTabLifetime == .sevenDays)
    #expect(model.tabs.count == 1)
    #expect(driver.closedTabRequests.map(\.id) == ["tab-1"])
}

@Test
@MainActor
func cleanShutdownPersistsLastSessionAndSuppressesFurtherCloseCallbacks() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let saveCountBeforeTermination = snapshotStore.savedSnapshots.count

    model.prepareForTermination()

    let saveCountAfterTermination = snapshotStore.savedSnapshots.count
    let savedSnapshotAtTermination = snapshotStore.savedSnapshots.last

    #expect(saveCountAfterTermination == saveCountBeforeTermination + 1)
    #expect(savedSnapshotAtTermination?.tabURLStrings.count == 2)

    for tabID in model.tabs.map(\.id) {
        driver.emitClose(id: tabID)
    }

    #expect(snapshotStore.savedSnapshots.count == saveCountAfterTermination)
    #expect(snapshotStore.savedSnapshots.last == savedSnapshotAtTermination)
}

@Test
@MainActor
func presentCommandBarDoesNotCreateTabUntilSubmit() async {
    let driver = FakeBrowserTabDriver()
    let suggestionProvider = FakeSuggestionProvider()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        suggestionProvider: suggestionProvider
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    #expect(driver.createdTabRequests.count == 1)

    model.presentCommandBar()

    #expect(model.commandBarModel.isPresented)
    #expect(driver.createdTabRequests.count == 1)

    model.commandBarModel.query = "openai.com"
    await model.commandBarModel.waitForPendingSuggestionLoad()
    model.commandBarModel.submitSelection()

    #expect(driver.createdTabRequests.count == 2)
    #expect(driver.createdTabRequests.last?.urlString == "https://openai.com")
    #expect(!model.commandBarModel.isPresented)
}

@Test
@MainActor
func selectingAnotherTabDismissesCommandBar() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let alternateTabID = try #require(model.tabs.first?.id)
    model.presentCommandBar()
    #expect(model.commandBarModel.isPresented)

    model.selectTab(id: alternateTabID)

    #expect(!model.commandBarModel.isPresented)
}

@Test
@MainActor
func toggleCommandBarDismissesWhenAlreadyPresented() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    model.toggleCommandBar()
    #expect(model.commandBarModel.isPresented)

    model.toggleCommandBar()
    #expect(!model.commandBarModel.isPresented)
}

@Test
@MainActor
func loadingStateSwitchesToStopActionWithoutAffectingReloadAvailability() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let tabID = try tabID(from: model)

    #expect(model.canReload)
    #expect(!model.canStopLoading)

    driver.emitLoadingStateChange(id: tabID, isLoading: true)

    #expect(model.canReload)
    #expect(model.canStopLoading)

    model.stopLoadingCurrentTab()

    #expect(driver.stopLoadingCount == 1)

    driver.emitLoadingStateChange(id: tabID, isLoading: false)

    #expect(!model.canStopLoading)
}

@Test
@MainActor
func printCurrentPageRequiresReadySelectedTab() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    #expect(!model.canPrintPage)
    model.printCurrentPage()
    #expect(driver.printCount == 0)

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.canPrintPage)
    model.printCurrentPage()
    #expect(driver.printCount == 1)
}

@Test
@MainActor
func pasteAndMatchStyleRequiresReadySelectedTab() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    #expect(!model.canPasteAndMatchStyle)
    #expect(!model.pasteAndMatchStyleCurrentTab())
    #expect(driver.pasteAndMatchStyleCount == 0)

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.canPasteAndMatchStyle)
    #expect(model.pasteAndMatchStyleCurrentTab())
    #expect(driver.pasteAndMatchStyleCount == 1)
}

@Test
@MainActor
func findBarRunsSearchAndClearsSelectionOnDismiss() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    #expect(!model.canFindInPage)
    model.presentFindBar()
    #expect(!model.isFindBarPresented)

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.canFindInPage)
    model.presentFindBar()

    #expect(model.isFindBarPresented)
    #expect(model.findBarFocusRequest == 1)
    #expect(driver.stopFindingClearSelectionRequests == [true])
    #expect(driver.findRequests.isEmpty)

    model.findQuery = "browser"

    #expect(model.canStepThroughFindMatches)
    #expect(
        driver.findRequests.last == FakeBrowserTabDriver.FindRequest(
            text: "browser",
            forward: true,
            matchCase: false,
            findNext: false
        )
    )

    model.findNextInPage()
    model.findPreviousInPage()

    #expect(Array(driver.findRequests.suffix(2)) == [
        FakeBrowserTabDriver.FindRequest(
            text: "browser",
            forward: true,
            matchCase: false,
            findNext: true
        ),
        FakeBrowserTabDriver.FindRequest(
            text: "browser",
            forward: false,
            matchCase: false,
            findNext: true
        ),
    ])

    model.dismissFindBar()

    #expect(!model.isFindBarPresented)
    #expect(driver.stopFindingClearSelectionRequests == [true, true])
}

@Test
@MainActor
func findBarIsDisabledForWindowedSettingsTabs() throws {
    for urlString in ["tb://settings", "tb://settings/privacy", "chrome://settings", "about:settings"] {
        let driver = FakeBrowserTabDriver()
        let model = makeModel(
            driver: driver,
            snapshotStore: InMemorySessionSnapshotStore(),
            preferencesStore: InMemorySessionPreferencesStore()
        )

        model.handleContextReady()
        driver.flushPendingCreateEvents()
        model.openURLInNewTab(try #require(URL(string: urlString)))
        driver.flushPendingCreateEvents()

        #expect(model.selectedTabUsesWindowedBrowser)
        #expect(!model.canFindInPage)

        model.presentFindBar()

        #expect(!model.isFindBarPresented)
        #expect(driver.findRequests.isEmpty)
    }
}

@Test
@MainActor
func findCommandFocusesSettingsSearchForWindowedSettingsTabs() throws {
    for urlString in ["tb://settings", "tb://settings/privacy", "chrome://settings", "about:settings"] {
        let driver = FakeBrowserTabDriver()
        let model = makeModel(
            driver: driver,
            snapshotStore: InMemorySessionSnapshotStore(),
            preferencesStore: InMemorySessionPreferencesStore()
        )

        model.handleContextReady()
        driver.flushPendingCreateEvents()
        model.openURLInNewTab(try #require(URL(string: urlString)))
        driver.flushPendingCreateEvents()

        #expect(model.selectedTabUsesWindowedBrowser)
        #expect(model.canPresentFindInPage)
        #expect(!model.canFindInPage)

        #expect(model.presentFindInPage())

        #expect(!model.isFindBarPresented)
        #expect(driver.findRequests.isEmpty)
        #expect(driver.focusSearchInActiveChromeSettingsTabCount == 1)
    }
}

@Test
@MainActor
func selectingWindowedSettingsTabDismissesFindBar() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let normalTabID = try #require(model.selectedTabID)

    model.openURLInNewTab(try #require(URL(string: "tb://settings/privacy")))
    driver.flushPendingCreateEvents()
    let settingsTabID = try #require(model.selectedTabID)

    model.selectTab(id: normalTabID)
    model.presentFindBar()
    model.findQuery = "browser"
    let findRequestCount = driver.findRequests.count

    model.selectTab(id: settingsTabID)

    #expect(model.selectedTabUsesWindowedBrowser)
    #expect(!model.canFindInPage)
    #expect(!model.isFindBarPresented)
    #expect(driver.findRequests.count == findRequestCount)
    #expect(Array(driver.stopFindingClearSelectionRequests.suffix(2)) == [true, true])
}

@Test
@MainActor
func findBarUsesFindResultsToDisableMatchStepping() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.presentFindBar()
    model.findQuery = "missing"

    let selectedTabID = try #require(model.selectedTabID)
    #expect(model.canStepThroughFindMatches)

    driver.emitFindResult(id: selectedTabID, matchCount: 0, finalUpdate: false)
    #expect(model.canStepThroughFindMatches)

    driver.emitFindResult(id: selectedTabID, matchCount: 0, finalUpdate: true)
    #expect(!model.canStepThroughFindMatches)

    let findRequestCount = driver.findRequests.count
    model.findNextInPage()
    model.findPreviousInPage()

    #expect(driver.findRequests.count == findRequestCount)

    model.findQuery = "browser"
    #expect(model.canStepThroughFindMatches)

    driver.emitFindResult(id: selectedTabID, matchCount: 2, activeMatchOrdinal: 1)
    #expect(model.canStepThroughFindMatches)
}

@Test
@MainActor
func presentingFindBarAgainRefreshesFocusRequest() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    model.presentFindBar()
    model.presentFindBar()

    #expect(model.isFindBarPresented)
    #expect(model.findBarFocusRequest == 2)
}

@MainActor
private func makeModel(
    driver: FakeBrowserTabDriver,
    snapshotStore: InMemorySessionSnapshotStore,
    preferencesStore: InMemorySessionPreferencesStore,
    suggestionProvider: BrowserSuggestionProviding = FakeSuggestionProvider(),
    dateProvider: @escaping () -> Date = Date.init
) -> BrowserChromeModel {
    BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: snapshotStore,
        sessionPreferencesStore: preferencesStore,
        commandBarSuggestionProvider: suggestionProvider,
        dateProvider: dateProvider,
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {}
    )
}

@MainActor
private func tabID(from model: BrowserChromeModel) throws -> String {
    #expect(model.tabs.count == 1)
    guard let tabID = model.tabs.first?.id else {
        throw BrowserChromeModelTestError.missingTab
    }

    return tabID
}

private enum BrowserChromeModelTestError: Error {
    case missingTab
}
