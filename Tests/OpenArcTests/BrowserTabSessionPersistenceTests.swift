// BrowserTabSessionPersistenceTests.swift

import CoreGraphics
import Foundation
import Testing

@Test func snapshotRoundTripPersistsJSONToDisk() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)
    let snapshot = BrowserTabSessionSnapshot(
        pinnedTabFolders: [
            BrowserPinnedTabFolderSessionSnapshot(
                id: "folder-1",
                spaceID: "space-1",
                parentFolderID: "folder-parent",
                title: "Reading",
                systemImageName: "book",
                isExpanded: false,
            ),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(
                urlString: "https://one.example",
                pinnedURLString: "https://pinned.example",
                userTitleOverride: "Pinned",
                placement: .spacePinned,
                spaceID: "space-1",
                pinnedFolderID: "folder-1",
                lastActivityTimestamp: 1234,
            ),
            BrowserTabSessionSnapshotTab(
                urlString: "https://two.example/path",
                spaceID: "space-2",
                lastActivityTimestamp: 5678,
            ),
        ],
    )

    store.saveSnapshot(snapshot)

    #expect(store.loadSnapshot() == snapshot)
}

@Test func snapshotRoundTripPersistsSpaces() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)
    let snapshot = BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(
                id: "space-1",
                title: "Work",
                systemImageName: "briefcase",
                isPinnedSectionCollapsed: true,
                selectedTabIndex: 1,
            ),
            BrowserSpaceSessionSnapshot(
                id: "space-2",
                title: "Read",
                systemImageName: "book",
                selectedTabIndex: nil,
            ),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(
                urlString: "https://one.example",
                placement: .spacePinned,
                spaceID: "space-1",
            ),
            BrowserTabSessionSnapshotTab(
                urlString: "https://two.example",
                spaceID: "space-2",
            ),
        ],
    )

    store.saveSnapshot(snapshot)

    #expect(store.loadSnapshot() == snapshot)
}

@Test func snapshotLoadMigratesLegacyTabURLStringFormat() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let legacyJSON = """
    {
      "version": 1,
      "tabURLStrings": [
        "https://one.example",
        "https://two.example/path"
      ]
    }
    """

    try Data(legacyJSON.utf8).write(to: harness.snapshotURL, options: .atomic)

    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)

    #expect(
        store.loadSnapshot() == BrowserTabSessionSnapshot(
            version: 1,
            tabs: [
                BrowserTabSessionSnapshotTab(urlString: "https://one.example"),
                BrowserTabSessionSnapshotTab(urlString: "https://two.example/path"),
            ],
        ),
    )
}

@Test func snapshotLoadMigratesVersionOneTabsWithoutPinMetadata() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let legacyJSON = """
    {
      "version": 1,
      "tabs": [
        {
          "urlString": "https://one.example",
          "userTitleOverride": "Workspace"
        }
      ]
    }
    """

    try Data(legacyJSON.utf8).write(to: harness.snapshotURL, options: .atomic)

    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)

    #expect(
        store.loadSnapshot() == BrowserTabSessionSnapshot(
            version: 1,
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://one.example",
                    userTitleOverride: "Workspace",
                ),
            ],
        ),
    )
}

@Test func snapshotLoadMigratesLegacyPinnedMetadataToSpacePinnedPlacement() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let legacyJSON = """
    {
      "version": 2,
      "tabs": [
        {
          "urlString": "https://one.example",
          "isPinned": true
        },
        {
          "urlString": "https://two.example",
          "isPinned": false
        }
      ]
    }
    """

    try Data(legacyJSON.utf8).write(to: harness.snapshotURL, options: .atomic)

    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)

    #expect(
        store.loadSnapshot() == BrowserTabSessionSnapshot(
            version: 2,
            tabs: [
                BrowserTabSessionSnapshotTab(
                    urlString: "https://one.example",
                    placement: .spacePinned,
                ),
                BrowserTabSessionSnapshotTab(urlString: "https://two.example"),
            ],
        ),
    )
}

@Test func missingSnapshotFileReturnsNil() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)

    #expect(store.loadSnapshot() == nil)
}

@Test func invalidSnapshotJSONReturnsNil() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    try Data("{".utf8).write(to: harness.snapshotURL, options: .atomic)
    let store = BrowserTabSessionSnapshotStore(snapshotURL: harness.snapshotURL)

    #expect(store.loadSnapshot() == nil)
}

@Test func selectedTabIndexLoadsWithClamping() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserSessionPreferencesStore(userDefaults: harness.userDefaults)
    harness.userDefaults.set(99, forKey: "browser.session.selectedTabIndex")

    #expect(store.loadSelectedTabIndex(tabCount: 3) == 2)

    harness.userDefaults.set(-5, forKey: "browser.session.selectedTabIndex")

    #expect(store.loadSelectedTabIndex(tabCount: 3) == 0)
}

@Test func selectedSpaceIndexLoadsWithClamping() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserSessionPreferencesStore(userDefaults: harness.userDefaults)
    harness.userDefaults.set(99, forKey: "browser.session.selectedSpaceIndex")

    #expect(store.loadSelectedSpaceIndex(spaceCount: 3) == 2)

    harness.userDefaults.set(-5, forKey: "browser.session.selectedSpaceIndex")

    #expect(store.loadSelectedSpaceIndex(spaceCount: 3) == 0)
}

@Test func sidebarWidthLoadsWithClamping() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserSessionPreferencesStore(userDefaults: harness.userDefaults)
    let minimumWidth = BrowserChromeModel.minSidebarWidth
    let maximumWidth = BrowserChromeModel.maxSidebarWidth

    harness.userDefaults.set(Double(maximumWidth * 4), forKey: "browser.session.sidebarWidth")
    #expect(
        store.loadSidebarWidth(minimum: minimumWidth, maximum: maximumWidth) == maximumWidth,
    )

    harness.userDefaults.set(Double(minimumWidth / 4), forKey: "browser.session.sidebarWidth")
    #expect(
        store.loadSidebarWidth(minimum: minimumWidth, maximum: maximumWidth) == minimumWidth,
    )
}

@Test func temporaryTabLifetimeDefaultsAndPersists() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    let store = BrowserSessionPreferencesStore(userDefaults: harness.userDefaults)

    #expect(store.loadTemporaryTabLifetime() == .thirtyDays)

    store.saveTemporaryTabLifetime(.sevenDays)

    #expect(store.loadTemporaryTabLifetime() == .sevenDays)
}

@Test func invalidTemporaryTabLifetimeFallsBackToDefault() throws {
    let harness = try PersistenceHarness()
    defer { harness.cleanup() }

    harness.userDefaults.set("bad-value", forKey: "browser.settings.temporaryTabLifetime")
    let store = BrowserSessionPreferencesStore(userDefaults: harness.userDefaults)

    #expect(store.loadTemporaryTabLifetime() == .thirtyDays)
}

// MARK: - PersistenceHarness

private struct PersistenceHarness {
    // MARK: Internal

    let snapshotURL: URL
    let userDefaultsSuiteName: String
    let userDefaults: UserDefaults

    init() throws {
        let temporaryDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        self.snapshotURL = temporaryDirectory
            .appendingPathComponent(BrowserTabSessionSnapshotStore.snapshotFileName, isDirectory: false)

        self.userDefaultsSuiteName = "OpenArcTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName) else {
            throw PersistenceHarnessError.missingUserDefaultsSuite
        }
        self.userDefaults = userDefaults
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent())
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}

// MARK: - PersistenceHarnessError

private enum PersistenceHarnessError: Error {
    case missingUserDefaultsSuite
}
