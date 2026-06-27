import Foundation
import Testing

@Test
@MainActor func restoreCreatesTabsInSavedOrderAndSelectsSavedIndex() {
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
    #expect(model.spaces.map(\.id) == [BrowserChromeModel.defaultSpaceID])
    #expect(model.tabs.map(\.spaceID) == Array(repeating: BrowserChromeModel.defaultSpaceID, count: 3))
    #expect(driver.createdTabRequests.map(\.makeActive) == [false, true, false])
    #expect(model.selectedTabID == model.tabs[1].id)
    #expect(driver.selectedTabIDs.last == model.tabs[1].id)
    #expect(model.sidebarWidth == BrowserChromeModel.maxSidebarWidth)
    #expect(model.isSidebarVisible)
}

@Test
@MainActor func restorePersistsSpacesAndSelectsSavedSpaceTab() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [
                BrowserSpaceSessionSnapshot(
                    id: "space-1",
                    title: "Work",
                    systemImageName: "briefcase",
                    selectedTabIndex: 1
                ),
                BrowserSpaceSessionSnapshot(
                    id: "space-2",
                    title: "Read",
                    systemImageName: "book",
                    isPinnedSectionCollapsed: true,
                    selectedTabIndex: 0
                ),
            ],
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://pin.example",
                    placement: .spacePinned,
                    spaceID: "space-1"
                ),
                BrowserTabSessionSnapshotTab(
                    urlString: "https://work.example",
                    spaceID: "space-1"
                ),
                BrowserTabSessionSnapshotTab(
                    urlString: "https://read.example",
                    spaceID: "space-2"
                ),
            ]
        )
    )
    let preferencesStore = InMemorySessionPreferencesStore(storedSelectedSpaceIndex: 1)
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.spaces.map(\.id) == ["space-1", "space-2"])
    #expect(model.selectedSpaceID == "space-2")
    #expect(model.activeSpace?.title == "Read")
    #expect(model.isActiveSpacePinnedSectionCollapsed)
    #expect(model.activeSpaceTabs.map(\.urlString) == ["https://read.example"])
    #expect(model.selectedTabID == model.activeSpaceTabs.first?.id)
    #expect(driver.selectedTabIDs.last == model.selectedTabID)
}

@Test
@MainActor func restoreEmptySelectedSpaceDeselectsBrowserView() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [
                BrowserSpaceSessionSnapshot(id: "space-1", title: "Work", systemImageName: "briefcase"),
                BrowserSpaceSessionSnapshot(id: "space-2", title: "Read", systemImageName: "book"),
            ],
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://work.example",
                    spaceID: "space-1"
                ),
            ]
        )
    )
    let preferencesStore = InMemorySessionPreferencesStore(storedSelectedSpaceIndex: 1)
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.selectedSpaceID == "space-2")
    #expect(model.activeSpaceTabs.isEmpty)
    #expect(model.selectedTabID == nil)
    #expect(driver.deselectActiveTabCount == 1)
}

@Test
@MainActor func restoreSessionPreferenceOffSkipsSavedTabs() throws {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let userPreferencesStore = BrowserUserPreferencesStore(userDefaults: userDefaults)
    userPreferencesStore.restoreWindowsOnLaunch = false

    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            tabURLStrings: [
                "https://one.example",
                "https://two.example",
            ]
        )
    )
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: InMemorySessionPreferencesStore(),
        userPreferencesStore: userPreferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.tabs.map(\.urlString) == [BrowserChromeModel.defaultNewTabURLString])
    #expect(driver.createdTabRequests.count == 1)
}

@Test
@MainActor func emptySnapshotFallsBackToInitialTab() {
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
@MainActor func incognitoWindowSkipsRestoreAndPersistence() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(tabURLStrings: ["https://saved.example"])
    )
    let preferencesStore = InMemorySessionPreferencesStore(storedSidebarWidth: BrowserChromeModel.maxSidebarWidth)
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore,
        windowMode: .incognito
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    #expect(model.isIncognito)
    #expect(!model.supportsSpaces)
    #expect(!model.supportsAppTabs)
    #expect(model.tabs.map(\.urlString) == [
        BrowserChromeModel.defaultNewTabURLString,
        BrowserChromeModel.defaultNewTabURLString,
    ])
    #expect(model.sidebarWidth == BrowserChromeModel.defaultSidebarWidth)
    #expect(snapshotStore.savedSnapshots.isEmpty)
    #expect(preferencesStore.savedSelectedTabIndices.isEmpty)
    #expect(preferencesStore.savedSelectedSpaceIndices.isEmpty)
}

@Test
@MainActor func incognitoWindowKeepsSingleSpaceAndRejectsAppTabs() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        windowMode: .incognito
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialTabID = try #require(model.selectedTabID)

    model.createNewSpace()
    model.moveTab(withID: initialTabID, toPlacement: .app, atSectionIndex: 0)
    model.togglePinned(forTabID: initialTabID)

    #expect(model.spaces.map(\.id) == [BrowserChromeModel.defaultSpaceID])
    #expect(model.selectedSpaceID == BrowserChromeModel.defaultSpaceID)
    #expect(model.appTabs.isEmpty)
    #expect(model.spacePinnedTabs.map(\.id) == [initialTabID])
}

@Test
@MainActor func createEmptySpaceSelectsItWithoutCreatingTab() {
    let driver = FakeBrowserTabDriver()
    var nextSpaceNumber = 0
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        spaceIDProvider: {
            nextSpaceNumber += 1
            return "space-\(nextSpaceNumber)"
        }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialTabCount = model.tabs.count
    let initialCreateRequestCount = driver.createdTabRequests.count

    model.createNewSpace()

    #expect(model.spaces.map(\.id) == [BrowserChromeModel.defaultSpaceID, "space-1"])
    #expect(model.selectedSpaceID == "space-1")
    #expect(model.selectedTabID == nil)
    #expect(model.activeSpaceTabs.isEmpty)
    #expect(model.tabs.count == initialTabCount)
    #expect(driver.createdTabRequests.count == initialCreateRequestCount)
    #expect(driver.deselectActiveTabCount == 1)
}

@Test
@MainActor func creatingTabInEmptySpaceKeepsOriginalSpaceTabsSeparate() {
    let driver = FakeBrowserTabDriver()
    var nextSpaceNumber = 0
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        spaceIDProvider: {
            nextSpaceNumber += 1
            return "space-\(nextSpaceNumber)"
        }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let defaultTabID = model.tabs[0].id
    model.togglePinned(forTabID: defaultTabID)

    model.createNewSpace()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    #expect(model.selectedSpaceID == "space-1")
    #expect(model.spacePinnedTabs.isEmpty)
    #expect(model.temporaryTabs.map(\.spaceID) == ["space-1"])
    #expect(!model.canMoveTab(withID: defaultTabID, toPlacement: .temporary, atSectionIndex: 0))

    model.selectPreviousSpace()

    #expect(model.selectedSpaceID == BrowserChromeModel.defaultSpaceID)
    #expect(model.spacePinnedTabs.map(\.id) == [defaultTabID])
    #expect(model.temporaryTabs.isEmpty)
}

@Test
@MainActor func deleteSelectedSpaceClosesItsTabsAndSelectsAdjacentSpace() throws {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore()
    let preferencesStore = InMemorySessionPreferencesStore()
    var nextSpaceNumber = 0
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore,
        spaceIDProvider: {
            nextSpaceNumber += 1
            return "space-\(nextSpaceNumber)"
        }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let defaultTabID = try #require(model.tabs.first?.id)

    model.createNewSpace()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let deletedSpaceID = "space-1"
    let deletedTabIDs = model.tabs.filter { $0.spaceID == deletedSpaceID }.map(\.id)
    for tabID in deletedTabIDs {
        model.togglePinned(forTabID: tabID)
    }
    let folderID = try #require(model.createPinnedTabFolder(containingTabIDs: Set(deletedTabIDs)))

    #expect(model.canDeleteSpace(id: deletedSpaceID))
    #expect(model.pinnedTabFolders.map(\.id) == [folderID])
    #expect(model.deleteSpace(id: deletedSpaceID))

    #expect(model.spaces.map(\.id) == [BrowserChromeModel.defaultSpaceID])
    #expect(model.selectedSpaceID == BrowserChromeModel.defaultSpaceID)
    #expect(model.selectedTabID == defaultTabID)
    #expect(model.tabs.map(\.id) == [defaultTabID])
    #expect(model.pinnedTabFolders.isEmpty)
    #expect(driver.closedTabRequests.map(\.id) == deletedTabIDs)
    #expect(driver.closedTabRequests.map(\.forceClose) == Array(repeating: false, count: deletedTabIDs.count))
    #expect(snapshotStore.savedSnapshots.last?.spaces?.map(\.id) == [BrowserChromeModel.defaultSpaceID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.id) == [model.tabs[0].syncID])
    #expect(preferencesStore.storedSelectedSpaceIndex == 0)
}

@Test
@MainActor func deleteOnlySpaceIsIgnored() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(!model.canDeleteSpace(id: BrowserChromeModel.defaultSpaceID))
    #expect(!model.deleteSpace(id: BrowserChromeModel.defaultSpaceID))
    #expect(model.spaces.map(\.id) == [BrowserChromeModel.defaultSpaceID])
    #expect(model.tabs.count == 1)
    #expect(driver.closedTabRequests.isEmpty)
}

@Test
@MainActor func movingTabToAnotherSpaceUpdatesOnlyTheTargetSpace() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        spaceIDProvider: { "space-2" }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    model.selectTab(id: firstTabID)
    model.createNewSpace()
    model.selectSpace(id: BrowserChromeModel.defaultSpaceID)

    model.moveTab(
        withID: secondTabID,
        toPlacement: .temporary,
        atSectionIndex: 0,
        targetSpaceID: "space-2"
    )

    #expect(model.selectedSpaceID == BrowserChromeModel.defaultSpaceID)
    #expect(model.selectedTabID == firstTabID)
    #expect(model.temporaryTabs.map(\.id) == [firstTabID])
    #expect(model.tabs.first { $0.id == secondTabID }?.spaceID == "space-2")

    model.selectSpace(id: "space-2")

    #expect(model.temporaryTabs.map(\.id) == [secondTabID])
    #expect(model.selectedTabID == secondTabID)
}

@Test
@MainActor func spaceMetadataMutationsPersistAndRestore() {
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
    let spaceID = BrowserChromeModel.defaultSpaceID

    model.setTitle("Focus", forSpaceID: spaceID)
    model.setIcon("star", forSpaceID: spaceID)
    model.toggleActiveSpacePinnedSectionCollapsed()

    let savedSpace = snapshotStore.savedSnapshots.last?.spaces?.first
    #expect(savedSpace?.title == "Focus")
    #expect(savedSpace?.systemImageName == "star")
    #expect(savedSpace?.isPinnedSectionCollapsed == true)

    let restoredDriver = FakeBrowserTabDriver()
    let restoredModel = makeModel(
        driver: restoredDriver,
        snapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: snapshotStore.savedSnapshots.last),
        preferencesStore: preferencesStore
    )

    restoredModel.handleContextReady()
    restoredDriver.flushPendingCreateEvents()

    #expect(restoredModel.activeSpace?.title == "Focus")
    #expect(restoredModel.activeSpace?.systemImageName == "star")
    #expect(restoredModel.isActiveSpacePinnedSectionCollapsed)
}

@Test
@MainActor func closingLastTabLeavesSelectedSpaceEmptyWithoutReplacement() {
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
    let tabID = model.tabs[0].id
    let initialCreateRequestCount = driver.createdTabRequests.count

    model.closeTab(id: tabID)

    #expect(model.tabs.isEmpty)
    #expect(model.selectedTabID == nil)
    #expect(driver.createdTabRequests.count == initialCreateRequestCount)
    #expect(driver.deselectActiveTabCount == 1)
    #expect(snapshotStore.savedSnapshots.last?.tabs.isEmpty == true)
}

@Test
@MainActor func clearTemporaryTabsOnlyClearsActiveSpace() {
    let driver = FakeBrowserTabDriver()
    var nextSpaceNumber = 0
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        spaceIDProvider: {
            nextSpaceNumber += 1
            return "space-\(nextSpaceNumber)"
        }
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    let defaultSpaceTabIDs = model.tabs.map(\.id)

    model.createNewSpace()
    model.createNewTab()
    driver.flushPendingCreateEvents()
    model.createNewTab()
    driver.flushPendingCreateEvents()

    model.clearTemporaryTabs()

    #expect(model.selectedSpaceID == "space-1")
    #expect(model.activeSpaceTabs.isEmpty)
    #expect(model.tabs.map(\.id) == defaultSpaceTabIDs)

    model.selectPreviousSpace()

    #expect(model.temporaryTabs.map(\.id) == defaultSpaceTabIDs)
}

@Test
@MainActor func archiveExpiredTemporaryTabsOnlyArchivesActiveSpace() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [
                BrowserSpaceSessionSnapshot(id: "space-1", title: "Work", systemImageName: "briefcase"),
                BrowserSpaceSessionSnapshot(
                    id: "space-2",
                    title: "Read",
                    systemImageName: "book",
                    selectedTabIndex: 1
                ),
            ],
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://inactive-stale.example",
                    spaceID: "space-1",
                    lastActivityTimestamp: 0
                ),
                BrowserTabSessionSnapshotTab(
                    urlString: "https://active-stale.example",
                    spaceID: "space-2",
                    lastActivityTimestamp: 0
                ),
                BrowserTabSessionSnapshotTab(
                    urlString: "https://active-selected.example",
                    spaceID: "space-2",
                    lastActivityTimestamp: 0
                ),
            ]
        )
    )
    let preferencesStore = InMemorySessionPreferencesStore(
        storedSelectedSpaceIndex: 1,
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
        "https://inactive-stale.example",
        "https://active-selected.example",
    ])
    #expect(driver.closedTabRequests.map(\.id) == ["tab-2"])
}

@Test
@MainActor func archiveTabsBelowOnlyUsesActiveSpaceTabs() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            spaces: [
                BrowserSpaceSessionSnapshot(id: "space-1", title: "Work", systemImageName: "briefcase"),
                BrowserSpaceSessionSnapshot(id: "space-2", title: "Read", systemImageName: "book"),
            ],
            tabs: [
                BrowserTabSessionSnapshotTab(urlString: "https://inactive.example", spaceID: "space-1"),
                BrowserTabSessionSnapshotTab(urlString: "https://active-one.example", spaceID: "space-2"),
                BrowserTabSessionSnapshotTab(urlString: "https://active-two.example", spaceID: "space-2"),
            ]
        )
    )
    let preferencesStore = InMemorySessionPreferencesStore(storedSelectedSpaceIndex: 1)
    let model = makeModel(
        driver: driver,
        snapshotStore: snapshotStore,
        preferencesStore: preferencesStore
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let activeFirstTabID = model.activeSpaceTabs[0].id

    model.closeTabsBelow(id: activeFirstTabID)

    #expect(model.tabs.map(\.urlString) == [
        "https://inactive.example",
        "https://active-one.example",
    ])
    #expect(driver.closedTabRequests.map(\.id) == ["tab-3"])
}

@Test
@MainActor func launchStartsWithVisibleSidebarEvenIfPreviousInstanceHidIt() {
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
@MainActor func persistentURLChangesTriggerSaveButTitleFaviconAndNavigationDoNot() throws {
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
@MainActor func userTitleOverridePersistsAcrossUpdatesAndRestore() throws {
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
@MainActor func createSelectAndClosePersistState() {
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
@MainActor func sidebarWidthChangesOnlyPersistPreferencesWhenCommitted() {
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
@MainActor func sessionMutationsDoNotPersistSidebarWidthImplicitly() {
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
@MainActor func terminationPersistsLatestSidebarWidthPreference() {
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
@MainActor func pinningAndClearingTemporaryTabsPreservesPinnedTabs() {
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

    #expect(model.spacePinnedTabs.map(\.id) == [pinnedTabID])
    #expect(model.temporaryTabs.count == 2)

    model.clearTemporaryTabs()

    #expect(model.tabs.map(\.id) == [pinnedTabID])
    #expect(model.spacePinnedTabs.map(\.id) == [pinnedTabID])
    #expect(model.temporaryTabs.isEmpty)
    #expect(snapshotStore.savedSnapshots.last?.tabs.count == 1)
    #expect(snapshotStore.savedSnapshots.last?.tabs.first?.placement == .spacePinned)
}

@Test
@MainActor func movingTemporaryTabIntoPinnedSectionPinsAndPersistsSidebarOrder() {
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

    model.moveTab(withID: secondTabID, toPlacement: .spacePinned, atSectionIndex: 0)

    #expect(model.tabs.map(\.id) == [secondTabID, firstTabID, thirdTabID])
    #expect(model.spacePinnedTabs.map(\.id) == [secondTabID])
    #expect(model.temporaryTabs.map(\.id) == [firstTabID, thirdTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.urlString) == [
        model.tabs[0].urlString,
        model.tabs[1].urlString,
        model.tabs[2].urlString,
    ])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.placement) == [.spacePinned, .temporary, .temporary])
}

@Test
@MainActor func movingPinnedTabIntoTemporarySectionUnpinsAndPersistsSidebarOrder() {
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
    model.moveTab(withID: thirdTabID, toPlacement: .temporary, atSectionIndex: 1)

    #expect(model.tabs.map(\.id) == [firstTabID, thirdTabID, secondTabID])
    #expect(model.spacePinnedTabs.isEmpty)
    #expect(model.temporaryTabs.map(\.id) == [firstTabID, thirdTabID, secondTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.placement) == [.temporary, .temporary, .temporary])
}

@Test
@MainActor func movingWithinPinnedSectionReordersPinnedTabs() {
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
    model.moveTab(withID: secondTabID, toPlacement: .spacePinned, atSectionIndex: 0)

    #expect(model.tabs.map(\.id) == [secondTabID, firstTabID, thirdTabID])
    #expect(model.spacePinnedTabs.map(\.id) == [secondTabID, firstTabID])
    #expect(model.temporaryTabs.map(\.id) == [thirdTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.placement) == [.spacePinned, .spacePinned, .temporary])
}

@Test
@MainActor func creatingPinnedTabFolderGroupsSelectedPinnedTabsAndPersists() throws {
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
    let folderID = try #require(model.createPinnedTabFolder(containingTabIDs: Set([firstTabID, secondTabID])))

    #expect(model.pinnedTabFolders.map(\.id) == [folderID])
    #expect(model.pinnedTabFolders.first?.title == BrowserStrings.pinnedTabFolderDefaultTitle)
    #expect(model.spacePinnedTabs.map(\.id) == [firstTabID, secondTabID])
    #expect(model.spacePinnedTabs.map(\.pinnedFolderID) == [folderID, folderID])
    #expect(model.temporaryTabs.map(\.id) == [thirdTabID])
    #expect(snapshotStore.savedSnapshots.last?.pinnedTabFolders?.map(\.id) == [folderID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.pinnedFolderID) == [folderID, folderID, nil])
}

@Test
@MainActor func movingTabsIntoAndOutOfPinnedFolderUpdatesFolderMembership() throws {
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
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.togglePinned(forTabID: firstTabID)
    model.togglePinned(forTabID: secondTabID)
    model.togglePinned(forTabID: thirdTabID)
    let folderID = try #require(model.createPinnedTabFolder(containingTabIDs: Set([firstTabID, secondTabID])))

    model.moveTab(
        withID: thirdTabID,
        toPlacement: .spacePinned,
        atSectionIndex: 2,
        targetPinnedFolderID: folderID
    )

    #expect(model.spacePinnedTabs.map(\.id) == [firstTabID, secondTabID, thirdTabID])
    #expect(model.spacePinnedTabs.map(\.pinnedFolderID) == [folderID, folderID, folderID])

    model.moveTab(withID: firstTabID, toPlacement: .spacePinned, atSectionIndex: 0)

    #expect(model.spacePinnedTabs.map(\.id) == [firstTabID, secondTabID, thirdTabID])
    #expect(model.spacePinnedTabs.map(\.pinnedFolderID) == [nil, folderID, folderID])
    #expect(model.pinnedTabFolders.map(\.id) == [folderID])
}

@Test
@MainActor func movingPinnedTabFolderReordersItsChildrenAsAGroup() throws {
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
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.togglePinned(forTabID: firstTabID)
    model.togglePinned(forTabID: secondTabID)
    model.togglePinned(forTabID: thirdTabID)
    let folderID = try #require(model.createPinnedTabFolder(containingTabIDs: Set([firstTabID, secondTabID])))

    model.movePinnedTabFolder(withID: folderID, toRootSectionIndex: 1)

    #expect(model.spacePinnedTabs.map(\.id) == [thirdTabID, firstTabID, secondTabID])
    #expect(model.spacePinnedTabs.map(\.pinnedFolderID) == [nil, folderID, folderID])
}

@Test
@MainActor func movingMultiplePinnedTabsPreservesSelectionOrder() {
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
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let firstTabID = model.tabs[0].id
    let secondTabID = model.tabs[1].id
    let thirdTabID = model.tabs[2].id

    model.togglePinned(forTabID: firstTabID)
    model.togglePinned(forTabID: secondTabID)
    model.togglePinned(forTabID: thirdTabID)

    model.moveTabs(
        withIDs: Set([firstTabID, secondTabID]),
        toPlacement: .spacePinned,
        atSectionIndex: 3
    )

    #expect(model.spacePinnedTabs.map(\.id) == [thirdTabID, firstTabID, secondTabID])
}

@Test
@MainActor func movingPinnedTabFolderIntoAnotherFolderNestsIt() throws {
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
    model.togglePinned(forTabID: thirdTabID)
    model.togglePinned(forTabID: fourthTabID)
    let parentFolderID = try #require(model.createPinnedTabFolder(containingTabIDs: Set([firstTabID, secondTabID])))
    let childFolderID = try #require(model.createPinnedTabFolder(containingTabIDs: Set([thirdTabID, fourthTabID])))

    model.movePinnedTabFolder(
        withID: childFolderID,
        toRootSectionIndex: 2,
        targetParentFolderID: parentFolderID
    )

    #expect(model.pinnedTabFolders.first { $0.id == childFolderID }?.parentFolderID == parentFolderID)
    #expect(!model.canMovePinnedTabFolder(
        withID: parentFolderID,
        toRootSectionIndex: 2,
        targetParentFolderID: childFolderID
    ))

    model.movePinnedTabFolder(withID: childFolderID, toRootSectionIndex: 0)

    #expect(model.pinnedTabFolders.first { $0.id == childFolderID }?.parentFolderID == nil)
}

@Test
@MainActor func movingTabsBetweenSectionEndsKeepsMovedTabsSelectable() {
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
    model.moveTab(withID: thirdTabID, toPlacement: .spacePinned, atSectionIndex: model.spacePinnedTabs.count)

    #expect(model.tabs.map(\.id) == [firstTabID, secondTabID, thirdTabID, fourthTabID])
    #expect(model.spacePinnedTabs.map(\.id) == [firstTabID, secondTabID, thirdTabID])
    #expect(model.temporaryTabs.map(\.id) == [fourthTabID])
    #expect(model.selectedTabID == thirdTabID)
    #expect(preferencesStore.storedSelectedTabIndex == 2)

    model.moveTab(withID: firstTabID, toPlacement: .temporary, atSectionIndex: model.temporaryTabs.count)
    model.selectTab(id: firstTabID)

    #expect(model.tabs.map(\.id) == [secondTabID, thirdTabID, fourthTabID, firstTabID])
    #expect(model.spacePinnedTabs.map(\.id) == [secondTabID, thirdTabID])
    #expect(model.temporaryTabs.map(\.id) == [fourthTabID, firstTabID])
    #expect(model.selectedTabID == firstTabID)
    #expect(driver.selectedTabIDs.last == firstTabID)
    #expect(preferencesStore.storedSelectedTabIndex == 3)
}

@Test
@MainActor func appTabPlacementPersistsAndRestores() {
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

    let firstTabID = model.tabs[0].id
    let appTabID = model.tabs[1].id
    model.moveTab(withID: appTabID, toPlacement: .app, atSectionIndex: 0)

    #expect(model.tabs.map(\.id) == [appTabID, firstTabID])
    #expect(model.appTabs.map(\.id) == [appTabID])
    #expect(snapshotStore.savedSnapshots.last?.tabs.map(\.placement) == [.app, .temporary])

    let restoredDriver = FakeBrowserTabDriver()
    let restoredModel = makeModel(
        driver: restoredDriver,
        snapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: snapshotStore.savedSnapshots.last),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    restoredModel.handleContextReady()
    restoredDriver.flushPendingCreateEvents()

    #expect(restoredModel.appTabs.map(\.urlString) == [model.tabs[0].urlString])
    #expect(restoredModel.temporaryTabs.map(\.urlString) == [model.tabs[1].urlString])
}

@Test
@MainActor func appTabsAreNotArchivedWithExpiredTemporaryTabs() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://app.example",
                    placement: .app,
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
        "https://app.example",
        "https://selected.example",
    ])
    #expect(model.appTabs.map(\.urlString) == ["https://app.example"])
    #expect(model.temporaryTabs.map(\.urlString) == ["https://selected.example"])
    #expect(driver.closedTabRequests.map(\.id) == ["tab-2"])
}

@Test
@MainActor func appTabCapacityBlocksNinthAppTabButAllowsInternalReorder() throws {
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
    for _ in 0..<BrowserChromeModel.appTabCapacity {
        model.createNewTab()
        driver.flushPendingCreateEvents()
    }

    let appTabIDs = Array(model.tabs.prefix(BrowserChromeModel.appTabCapacity).map(\.id))
    for tabID in appTabIDs {
        model.moveTab(withID: tabID, toPlacement: .app, atSectionIndex: model.appTabs.count)
    }

    let ninthTabID = try #require(model.tabs.last?.id)
    #expect(model.appTabs.map(\.id) == appTabIDs)
    #expect(!model.canMoveTab(withID: ninthTabID, toPlacement: .app, atSectionIndex: model.appTabs.count))

    try model.moveTab(withID: #require(appTabIDs.last), toPlacement: .app, atSectionIndex: 0)

    #expect(try model.appTabs.map(\.id) == [#require(appTabIDs.last)] + Array(appTabIDs.dropLast()))
    #expect(model.temporaryTabs.map(\.id) == [ninthTabID])
}

@Test
@MainActor func movingAcrossAppSpacePinnedAndTemporaryPreservesOrderAndSelection() {
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

    model.moveTab(withID: secondTabID, toPlacement: .app, atSectionIndex: 0)
    model.moveTab(withID: thirdTabID, toPlacement: .spacePinned, atSectionIndex: 0)
    model.selectTab(id: secondTabID)
    model.moveTab(withID: secondTabID, toPlacement: .temporary, atSectionIndex: model.temporaryTabs.count)

    #expect(model.tabs.map(\.id) == [thirdTabID, firstTabID, secondTabID])
    #expect(model.appTabs.isEmpty)
    #expect(model.spacePinnedTabs.map(\.id) == [thirdTabID])
    #expect(model.temporaryTabs.map(\.id) == [firstTabID, secondTabID])
    #expect(model.selectedTabID == secondTabID)
    #expect(driver.selectedTabIDs.last == secondTabID)
    #expect(preferencesStore.storedSelectedTabIndex == 2)
}

@Test
@MainActor func archiveTabsBelowUsesVisibleSidebarOrder() {
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
@MainActor func archiveSelectedTabClosesCurrentTabAndSelectsFallback() {
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
@MainActor func undoNewTabArchivesCreatedTabAndRedoRestoresIt() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialTabID = try #require(model.tabs.first?.id)

    model.createNewTab()
    driver.flushPendingCreateEvents()
    let createdTabID = try #require(model.tabs.last?.id)

    #expect(model.undoManager.canUndo)
    model.undoManager.undo()

    #expect(model.tabs.map(\.id) == [initialTabID])
    #expect(model.selectedTabID == initialTabID)
    #expect(driver.closedTabRequests.last == FakeBrowserTabDriver.CloseTabRequest(id: createdTabID, forceClose: false))

    driver.emitClose(id: createdTabID)
    #expect(model.undoManager.canRedo)
    model.undoManager.redo()
    driver.flushPendingCreateEvents()

    let restoredTabID = try #require(model.tabs.last?.id)
    #expect(model.tabs.map(\.urlString) == [
        BrowserChromeModel.defaultNewTabURLString,
        BrowserChromeModel.defaultNewTabURLString,
    ])
    #expect(restoredTabID != createdTabID)
    #expect(model.selectedTabID == restoredTabID)
    #expect(driver.createdTabRequests.last?.makeActive == true)
}

@Test
@MainActor func undoArchivedTabRestoresTabStateAndRedoArchivesRestoredTab() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    try model.openURLInNewTab(#require(URL(string: "https://two.example")))
    driver.flushPendingCreateEvents()
    try model.openURLInNewTab(#require(URL(string: "https://three.example")))
    driver.flushPendingCreateEvents()

    let secondTabID = model.tabs[1].id
    let expectedURLStrings = model.tabs.map(\.urlString)
    model.setUserTitleOverride("Docs", forTabID: secondTabID)
    model.selectTab(id: secondTabID)

    #expect(model.archiveSelectedTab())
    driver.emitClose(id: secondTabID)

    model.undoManager.undo()
    driver.flushPendingCreateEvents()

    let restoredTab = model.tabs[1]
    #expect(model.tabs.map(\.urlString) == expectedURLStrings)
    #expect(restoredTab.id != secondTabID)
    #expect(restoredTab.userTitleOverride == "Docs")
    #expect(model.selectedTabID == restoredTab.id)

    #expect(model.undoManager.canRedo)
    model.undoManager.redo()

    #expect(model.tabs.map(\.urlString) == [
        BrowserChromeModel.defaultNewTabURLString,
        "https://three.example",
    ])
    #expect(driver.closedTabRequests.last == FakeBrowserTabDriver.CloseTabRequest(
        id: restoredTab.id,
        forceClose: false
    ))
}

@Test
@MainActor func undoCreationTracksTabAcrossArchiveRestore() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let initialTabID = try #require(model.tabs.first?.id)

    model.createNewTab()
    driver.flushPendingCreateEvents()
    let createdTabID = try #require(model.tabs.last?.id)

    #expect(model.archiveSelectedTab())
    driver.emitClose(id: createdTabID)
    model.undoManager.undo()
    driver.flushPendingCreateEvents()
    let restoredTabID = try #require(model.tabs.last?.id)

    model.undoManager.undo()

    #expect(model.tabs.map(\.id) == [initialTabID])
    #expect(driver.closedTabRequests.last == FakeBrowserTabDriver.CloseTabRequest(id: restoredTabID, forceClose: false))
}

@Test
@MainActor func expiredTemporaryTabsArchiveButPinnedTabsRemain() {
    let driver = FakeBrowserTabDriver()
    let snapshotStore = InMemorySessionSnapshotStore(
        loadedSnapshot: BrowserTabSessionSnapshot(
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://pinned.example",
                    placement: .spacePinned,
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
    #expect(model.spacePinnedTabs.map(\.urlString) == ["https://pinned.example"])
    #expect(model.temporaryTabs.map(\.urlString) == ["https://selected.example"])
    #expect(driver.closedTabRequests.map(\.id) == ["tab-2"])
}

@Test
@MainActor func changingTemporaryTabLifetimePersistsAndArchivesExpiredTabs() {
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
@MainActor func cleanShutdownPersistsLastSessionAndSuppressesFurtherCloseCallbacks() {
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
@MainActor func presentCommandBarDoesNotCreateTabUntilSubmit() async {
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
@MainActor func currentPageCommandBarNavigatesSelectedTabWithoutCreatingNewTab() async {
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
    let initialCreatedTabCount = driver.createdTabRequests.count

    model.presentCurrentPageCommandBar()

    #expect(model.currentPageCommandBarModel.isPresented)
    #expect(model.currentPageCommandBarModel.query == BrowserChromeModel.defaultNewTabURLString)

    model.currentPageCommandBarModel.query = "openai.com"
    await model.currentPageCommandBarModel.waitForPendingSuggestionLoad()
    model.currentPageCommandBarModel.submitSelection()

    #expect(driver.createdTabRequests.count == initialCreatedTabCount)
    #expect(driver.activeTabNavigationURLStrings == ["https://openai.com"])
    #expect(!model.currentPageCommandBarModel.isPresented)
}

@Test
@MainActor func presentingNewTabCommandBarDismissesCurrentPageCommandBar() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    model.presentCurrentPageCommandBar()
    #expect(model.currentPageCommandBarModel.isPresented)

    model.presentCommandBar()

    #expect(model.commandBarModel.isPresented)
    #expect(!model.currentPageCommandBarModel.isPresented)
}

@Test
@MainActor func presentingCurrentPageCommandBarDismissesNewTabCommandBar() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    model.presentCommandBar()
    #expect(model.commandBarModel.isPresented)

    model.presentCurrentPageCommandBar()

    #expect(!model.commandBarModel.isPresented)
    #expect(model.currentPageCommandBarModel.isPresented)
}

@Test
@MainActor func selectingAnotherTabDismissesCommandBar() throws {
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
@MainActor func toggleCommandBarDismissesWhenAlreadyPresented() {
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
@MainActor func loadingStateSwitchesToStopActionWithoutAffectingReloadAvailability() throws {
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
@MainActor func printCurrentPageRequiresReadySelectedTab() {
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
@MainActor func pasteAndMatchStyleRequiresReadySelectedTab() {
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
@MainActor func captureFullPageRequiresSelectedTab() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    #expect(!model.captureFullPageSelectedTabToPasteboard())
    #expect(driver.captureFullPageToPasteboardCount == 0)

    model.handleContextReady()
    driver.flushPendingCreateEvents()

    #expect(model.captureFullPageSelectedTabToPasteboard())
    #expect(driver.captureFullPageToPasteboardCount == 1)
}

@Test
@MainActor func findBarRunsSearchAndClearsSelectionOnDismiss() {
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
@MainActor func findBarIsEnabledForInternalWebUITabs() throws {
    for urlString in [
        "tb://settings",
        "tb://settings/privacy",
        "chrome://settings",
        "about:settings",
        "tb://extensions",
        "tb://extensions/?id=abc",
        "chrome://extensions",
        "tb://history",
        "chrome://history",
        "tb://password-manager/passwords",
        "chrome://password-manager/passwords",
    ] {
        let driver = FakeBrowserTabDriver()
        let model = makeModel(
            driver: driver,
            snapshotStore: InMemorySessionSnapshotStore(),
            preferencesStore: InMemorySessionPreferencesStore()
        )

        model.handleContextReady()
        driver.flushPendingCreateEvents()
        try model.openURLInNewTab(#require(URL(string: urlString)))
        driver.flushPendingCreateEvents()

        #expect(!model.selectedTabUsesWindowedBrowser)
        #expect(model.canFindInPage)
        #expect(model.canPresentFindInPage)

        model.presentFindBar()

        #expect(model.isFindBarPresented)
        #expect(driver.stopFindingClearSelectionRequests == [true])
    }
}

@Test
@MainActor func findCommandUsesNormalFindBarForInternalWebUITabs() throws {
    for urlString in [
        "tb://settings",
        "tb://settings/privacy",
        "chrome://settings",
        "about:settings",
        "tb://extensions",
        "tb://extensions/?id=abc",
        "chrome://extensions",
        "tb://history",
        "chrome://history",
        "tb://password-manager/passwords",
        "chrome://password-manager/passwords",
    ] {
        let driver = FakeBrowserTabDriver()
        let model = makeModel(
            driver: driver,
            snapshotStore: InMemorySessionSnapshotStore(),
            preferencesStore: InMemorySessionPreferencesStore()
        )

        model.handleContextReady()
        driver.flushPendingCreateEvents()
        try model.openURLInNewTab(#require(URL(string: urlString)))
        driver.flushPendingCreateEvents()

        #expect(!model.selectedTabUsesWindowedBrowser)
        #expect(model.canPresentFindInPage)
        #expect(model.canFindInPage)

        #expect(model.presentFindInPage())

        #expect(model.isFindBarPresented)
        #expect(driver.findRequests.isEmpty)
        #expect(driver.stopFindingClearSelectionRequests == [true])
    }
}

@Test
@MainActor func selectingInternalWebUITabKeepsFindBarMounted() throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    let normalTabID = try #require(model.selectedTabID)

    try model.openURLInNewTab(#require(URL(string: "tb://settings/privacy")))
    driver.flushPendingCreateEvents()
    let settingsTabID = try #require(model.selectedTabID)

    model.selectTab(id: normalTabID)
    model.presentFindBar()
    model.findQuery = "browser"
    let findRequestCount = driver.findRequests.count

    model.selectTab(id: settingsTabID)

    #expect(!model.selectedTabUsesWindowedBrowser)
    #expect(model.canFindInPage)
    #expect(model.isFindBarPresented)
    #expect(driver.findRequests.count == findRequestCount + 1)
    #expect(driver.findRequests.last?.text == "browser")
}

@Test
@MainActor func findBarUsesFindResultsToDisableMatchStepping() throws {
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
@MainActor func presentingFindBarAgainRefreshesFocusRequest() {
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

@Test
@MainActor func tabSwitcherCommitsPreviousTabOnOptionRelease() throws {
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
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let previousTabID = try #require(model.tabs.dropLast().last?.id)

    #expect(model.advanceTabSwitcher())
    #expect(model.tabSwitcherState?.selectedTabID == previousTabID)
    #expect(model.commitTabSwitcher())
    #expect(model.selectedTabID == previousTabID)
    #expect(model.tabSwitcherState == nil)
}

@Test
@MainActor func tabSwitcherCyclesThroughRecentTabsWhileHeld() throws {
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
    model.createNewTab()
    driver.flushPendingCreateEvents()

    let oldestTabID = try #require(model.tabs.first?.id)

    #expect(model.advanceTabSwitcher())
    #expect(model.advanceTabSwitcher())
    #expect(model.tabSwitcherState?.selectedTabID == oldestTabID)
    #expect(model.commitTabSwitcher())
    #expect(model.selectedTabID == oldestTabID)
}

@Test
@MainActor func tabSwitcherLimitsOverlayToFiveMostRecentTabs() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    for _ in 0..<5 {
        model.createNewTab()
        driver.flushPendingCreateEvents()
    }

    let expectedIDs = Array(model.tabs.suffix(5).reversed().map(\.id))

    #expect(model.advanceTabSwitcher())
    #expect(model.tabSwitcherState?.entries.map(\.id) == expectedIDs)
    #expect(model.cancelTabSwitcher())
}

@Test
@MainActor func commandBarSuggestsInternalChromiumPages() async throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        suggestionProvider: FakeSuggestionProvider()
    )

    model.commandBarModel.present()
    model.commandBarModel.query = "bookmarks"
    await model.commandBarModel.waitForPendingSuggestionLoad()

    let bookmarkSuggestion = try #require(
        model.commandBarModel.suggestions.first { $0.displayText == "Open Bookmarks" }
    )
    #expect(bookmarkSuggestion.resolvedURLString == "tb://bookmarks/")
    #expect(bookmarkSuggestion.detailText == "tb://bookmarks")
}

@Test
@MainActor func commandBarOpeningPinnedFolderTabSelectsExistingTab() async throws {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore(),
        suggestionProvider: FakeSuggestionProvider()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    try model.openURLInNewTab(#require(URL(string: "https://docs.example")))
    driver.flushPendingCreateEvents()
    try model.openURLInNewTab(#require(URL(string: "https://mail.example")))
    driver.flushPendingCreateEvents()

    let docsTabID = model.tabs[1].id
    let mailTabID = model.tabs[2].id
    model.togglePinned(forTabID: docsTabID)
    model.togglePinned(forTabID: mailTabID)
    _ = try #require(model.createPinnedTabFolder(containingTabIDs: Set([docsTabID, mailTabID])))
    let createdTabCount = driver.createdTabRequests.count

    try await submitOpenTabSuggestion(matching: "docs", in: model)
    driver.flushPendingCreateEvents()

    #expect(model.selectedTabID == docsTabID)
    #expect(driver.createdTabRequests.count == createdTabCount)

    try await submitOpenTabSuggestion(matching: "mail", in: model)
    driver.flushPendingCreateEvents()

    #expect(model.selectedTabID == mailTabID)
    #expect(driver.createdTabRequests.count == createdTabCount)
    #expect(model.spacePinnedTabs.map(\.id) == [docsTabID, mailTabID])
}

@Test
@MainActor func openBookmarksManagerCreatesCanonicalInternalTab() {
    let driver = FakeBrowserTabDriver()
    let model = makeModel(
        driver: driver,
        snapshotStore: InMemorySessionSnapshotStore(),
        preferencesStore: InMemorySessionPreferencesStore()
    )

    model.handleContextReady()
    driver.flushPendingCreateEvents()
    model.openBookmarksManager()

    #expect(driver.createdTabRequests.last?.urlString == "tb://bookmarks/")
}

@MainActor private func makeModel(
    driver: FakeBrowserTabDriver,
    snapshotStore: InMemorySessionSnapshotStore,
    preferencesStore: InMemorySessionPreferencesStore,
    suggestionProvider: BrowserSuggestionProviding = FakeSuggestionProvider(),
    userPreferencesStore: BrowserUserPreferencesStore? = nil,
    shortcutStore: BrowserShortcutStore? = nil,
    extensionManager: (any BrowserExtensionManaging)? = nil,
    windowMode: BrowserWindowMode = .normal,
    dateProvider: @escaping () -> Date = Date.init,
    spaceIDProvider: @escaping () -> String = { UUID().uuidString }
) -> BrowserChromeModel {
    let userDefaults = isolatedUserDefaults()
    return BrowserChromeModel(
        tabDriver: driver,
        sessionSnapshotStore: snapshotStore,
        sessionPreferencesStore: preferencesStore,
        commandBarSuggestionProvider: suggestionProvider,
        userPreferencesStore: userPreferencesStore ?? BrowserUserPreferencesStore(userDefaults: userDefaults),
        shortcutStore: shortcutStore ?? BrowserShortcutStore(userDefaults: userDefaults),
        extensionManager: extensionManager ?? FakeBrowserExtensionManager(),
        windowMode: windowMode,
        dateProvider: dateProvider,
        spaceIDProvider: spaceIDProvider,
        windowTitleHandler: { _ in },
        allTabsClosedHandler: {}
    )
}

private func isolatedUserDefaults() -> UserDefaults {
    let suiteName = "TheBrowserTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return userDefaults
}

@MainActor private func tabID(from model: BrowserChromeModel) throws -> String {
    #expect(model.tabs.count == 1)
    guard let tabID = model.tabs.first?.id else {
        throw BrowserChromeModelTestError.missingTab
    }

    return tabID
}

@MainActor private func submitOpenTabSuggestion(
    matching query: String,
    in model: BrowserChromeModel
) async throws {
    model.commandBarModel.present()
    model.commandBarModel.query = query
    await model.commandBarModel.waitForPendingSuggestionLoad()

    let suggestion = try #require(model.commandBarModel.suggestions.first { $0.kind == .openTab })
    model.commandBarModel.submitSuggestion(id: suggestion.id)
}

// MARK: - BrowserChromeModelTestError

private enum BrowserChromeModelTestError: Error {
    case missingTab
}
