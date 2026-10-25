// BrowserTabIconTests.swift

import AppKit
import Testing

// MARK: - BrowserTabIconTests

@Suite(.serialized)
@MainActor struct BrowserTabIconTests {
    @Test func tabIconsSurviveTheStoreButNotEquality() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabIcons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("session.sqlite")
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "s", title: "Space", systemImageName: "star")],
            tabs: [
                .init(
                    id: "a",
                    urlString: "https://a.example",
                    placement: .spacePinned,
                    spaceID: "s",
                    systemImageName: "leaf",
                ),
                .init(id: "b", urlString: "https://b.example", spaceID: "s"),
            ],
        )
        do {
            let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            store.saveSnapshot(snapshot)
        }
        let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        let tabs = try #require(reopened.loadSnapshot()?.tabs)
        #expect(tabs.map(\.systemImageName) == ["leaf", nil])
        #expect(
            BrowserTabSessionSnapshotTab(id: "a", urlString: "https://a.example", systemImageName: "leaf")
                == BrowserTabSessionSnapshotTab(id: "a", urlString: "https://a.example"),
            "Icons are local, so sync and archive checks ignore them",
        )
    }

    @Test func aTabsIconShowsInTheSidebarAndOutlivesItsRuntimeID() throws {
        let f = SidebarDragFixture(pinned: [("a", nil), ("b", nil)], temporary: ["x"])
        let b = f.id("b")
        #expect(f.model.setIcon("leaf", forTabID: b))
        #expect(!f.model.setIcon("leaf", forTabID: b), "Choosing the same icon changes nothing")
        #expect(f.model.sidebarSnapshot.tabIcons[b] == "leaf")
        let saved = try #require(f.store.savedSnapshots.last)
        #expect(saved.tabs.first { $0.userTitleOverride == "b" }?.systemImageName == "leaf")

        // The unloaded tab reopens under a new runtime ID and keeps its icon.
        f.model.selectTab(id: b)
        #expect(f.id("b") != b)
        #expect(f.model.icon(forTabID: f.id("b")) == "leaf")
        #expect(f.model.setIcon(nil, forTabID: f.id("b")))
        #expect(f.model.sidebarSnapshot.tabIcons.isEmpty)
    }

    @Test func anIconOnlyChangeIsNotDroppedAsADuplicateWrite() {
        func write(_ icon: String?) -> BrowserSessionWrite {
            BrowserSessionWrite(
                snapshot: .init(tabs: [.init(id: "a", urlString: "https://a.example", systemImageName: icon)]),
                origin: .local(syncMove: nil),
            )
        }
        var buffer = BrowserSessionWriteBuffer()
        let accepted = [buffer.append(write(nil)), buffer.append(write("leaf")), buffer.append(write("leaf"))]
        #expect(accepted == [true, true, true])
        #expect(buffer.writes.map { $0.snapshot.tabs.first?.systemImageName } == [nil, "leaf"])
    }

    @Test func splitChipsShowATabsIconInsteadOfItsFavicon() {
        let tab = BrowserChromeModel.Tab(id: "a", syncID: "a", spaceID: "s", title: "A", urlString: "https://a.example")
        let chip = BrowserNativeSidebarSplitChipView()
        chip.update(tab: tab, focused: false, icon: "leaf")
        let images = chip.subviews.compactMap { $0 as? NSImageView }.filter { !$0.isHidden }
        #expect(images.count == 1 && !(images[0] is BrowserFaviconNSView) && images[0].image != nil)
        chip.update(tab: tab, focused: false)
        #expect(chip.subviews
            .compactMap { $0 as? NSImageView }
            .filter { !$0.isHidden }
            .allSatisfy { $0 is BrowserFaviconNSView })
    }
}

// MARK: - BrowserExpiryRecoveryIconTests

@Test func archiveEntriesRecoveredFromThisDeviceKeepItsIcon() {
    let canonical = BrowserTabArchiveEntry(
        id: "entry",
        tab: .init(id: "a", urlString: "https://a.example/old", spaceID: "s", lastActivityTimestamp: 100),
        archivedAt: 200,
        title: "Old",
    )
    let local = BrowserTabSessionSnapshot(tabs: [.init(
        id: "a",
        urlString: "https://a.example/new",
        spaceID: "s",
        systemImageName: "leaf",
    )])
    let entries = BrowserSyncExpiryRecovery.localEntries(canonical: canonical, pending: [], local: local)
    #expect(!entries.isEmpty && entries.allSatisfy { $0.tab.systemImageName == "leaf" })
}
