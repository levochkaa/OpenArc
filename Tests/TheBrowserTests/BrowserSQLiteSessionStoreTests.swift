import Foundation
import Testing

@Test func sqliteSessionStorePersistsSnapshotAndPreferences() throws {
    let harness = try SQLiteSessionHarness()
    defer { harness.cleanup() }

    let store = try BrowserSQLiteSessionStore(databaseURL: harness.databaseURL)
    let snapshot = BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(
                id: "space-1",
                title: "Work",
                systemImageName: "briefcase",
                isPinnedSectionCollapsed: true,
                selectedTabIndex: 0
            ),
        ],
        pinnedTabFolders: [
            BrowserPinnedTabFolderSessionSnapshot(
                id: "folder-sync-1",
                spaceID: "space-1",
                parentFolderID: "folder-parent",
                title: "Focus",
                systemImageName: "star",
                isExpanded: false
            ),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(
                id: "tab-sync-1",
                urlString: "https://example.com",
                userTitleOverride: "Example",
                placement: .spacePinned,
                spaceID: "space-1",
                pinnedFolderID: "folder-sync-1",
                lastActivityTimestamp: 123
            ),
        ]
    )

    store.saveSnapshot(snapshot)
    store.saveSelectedTabIndex(3)
    store.saveSelectedSpaceIndex(2)
    store.saveSidebarWidth(512)
    store.saveTemporaryTabLifetime(.sevenDays)
    store.saveSyncCursor(42)

    let restored = try #require(store.loadSnapshot())
    #expect(restored == snapshot)
    #expect(store.loadSelectedTabIndex(tabCount: 2) == 1)
    #expect(store.loadSelectedSpaceIndex(spaceCount: 2) == 1)
    #expect(store.loadSidebarWidth(minimum: 200, maximum: 400) == 400)
    #expect(store.loadTemporaryTabLifetime() == .sevenDays)
    #expect(store.syncCursor() == 42)
}

@Test func syncChangesIncludeUpsertsAndDeletes() {
    let previous = BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(id: "space-old", title: "Old", systemImageName: "clock"),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(id: "tab-old", urlString: "https://old.example"),
        ]
    )
    let current = BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(id: "space-new", title: "New", systemImageName: "star"),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(
                id: "tab-new",
                urlString: "https://new.example",
                placement: .app,
                spaceID: "space-new"
            ),
        ]
    )

    let changes = BrowserRemoteSyncClient.changes(from: previous, to: current)

    #expect(changes.map(\.entityID).contains("space-new"))
    #expect(changes.map(\.entityID).contains("tab-new"))
    #expect(changes.contains { $0.entityID == "space-old" && $0.op == .delete })
    #expect(changes.contains { $0.entityID == "tab-old" && $0.op == .delete })
}

@Test func syncSnapshotMergerAppliesRemoteEvents() throws {
    let current = BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(id: "space-old", title: "Old", systemImageName: "clock"),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(id: "tab-old", urlString: "https://old.example", spaceID: "space-old"),
        ]
    )
    let events = [
        BrowserSyncEvent(
            serverSeq: 1,
            deviceID: "remote-device",
            entityType: "space",
            entityID: "space-new",
            op: "upsert",
            data: .space(
                BrowserSyncEventSpaceData(
                    id: "space-new",
                    title: "Remote",
                    systemImageName: "cloud",
                    rank: 0,
                    isPinnedSectionCollapsed: false,
                    selectedTabID: "tab-new"
                )
            ),
            createdAt: "2026-05-29T00:00:00Z"
        ),
        BrowserSyncEvent(
            serverSeq: 2,
            deviceID: "remote-device",
            entityType: "tab",
            entityID: "tab-new",
            op: "upsert",
            data: .tab(
                BrowserSyncEventTabData(
                    id: "tab-new",
                    spaceID: "space-new",
                    placement: .spacePinned,
                    rank: 0,
                    urlString: "https://remote.example",
                    title: nil,
                    userTitleOverride: "Remote Tab",
                    faviconURLString: nil,
                    lastActivityAt: "2026-05-29T00:00:00Z"
                )
            ),
            createdAt: "2026-05-29T00:00:01Z"
        ),
        BrowserSyncEvent(
            serverSeq: 3,
            deviceID: "remote-device",
            entityType: "tab",
            entityID: "tab-old",
            op: "delete",
            data: .deleted(id: "tab-old"),
            createdAt: "2026-05-29T00:00:02Z"
        ),
    ]

    let merged = BrowserSyncSnapshotMerger.snapshot(applying: events, to: current)
    let space = try #require(merged.spaces?.first)
    let tab = try #require(merged.tabs.first)

    #expect(space.id == "space-new")
    #expect(space.selectedTabIndex == 0)
    #expect(tab.id == "tab-new")
    #expect(tab.urlString == "https://remote.example")
    #expect(tab.userTitleOverride == "Remote Tab")
    #expect(tab.placement == .spacePinned)
}

@Test func syncSnapshotMergerPreservesLocalPinnedTabFolders() throws {
    let current = BrowserTabSessionSnapshot(
        spaces: [
            BrowserSpaceSessionSnapshot(id: "space-1", title: "Work", systemImageName: "briefcase"),
        ],
        pinnedTabFolders: [
            BrowserPinnedTabFolderSessionSnapshot(
                id: "folder-1",
                spaceID: "space-1",
                title: "Reading",
                systemImageName: "book",
                isExpanded: false
            ),
        ],
        tabs: [
            BrowserTabSessionSnapshotTab(
                id: "tab-1",
                urlString: "https://old.example",
                placement: .spacePinned,
                spaceID: "space-1",
                pinnedFolderID: "folder-1"
            ),
        ]
    )
    let events = [
        BrowserSyncEvent(
            serverSeq: 1,
            deviceID: "remote-device",
            entityType: "tab",
            entityID: "tab-1",
            op: "upsert",
            data: .tab(
                BrowserSyncEventTabData(
                    id: "tab-1",
                    spaceID: "space-1",
                    placement: .spacePinned,
                    rank: 0,
                    urlString: "https://new.example",
                    title: nil,
                    userTitleOverride: nil,
                    faviconURLString: nil,
                    lastActivityAt: nil
                )
            ),
            createdAt: "2026-05-29T00:00:00Z"
        ),
    ]

    let merged = BrowserSyncSnapshotMerger.snapshot(applying: events, to: current)
    let tab = try #require(merged.tabs.first)

    #expect(merged.pinnedTabFolders == current.pinnedTabFolders)
    #expect(tab.urlString == "https://new.example")
    #expect(tab.pinnedFolderID == "folder-1")
}

// MARK: - SQLiteSessionHarness

private struct SQLiteSessionHarness {
    // MARK: Lifecycle

    init() throws {
        self.directoryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("TheBrowserTests-\(UUID().uuidString)", isDirectory: true)
        self.databaseURL = directoryURL.appendingPathComponent("Browser.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // MARK: Internal

    let directoryURL: URL
    let databaseURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
