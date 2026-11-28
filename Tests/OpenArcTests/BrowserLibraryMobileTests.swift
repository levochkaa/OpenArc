// BrowserLibraryMobileTests.swift

import AppKit
import Testing

// MARK: - BrowserLibraryMobileTests

@Suite(.serialized)
@MainActor struct BrowserLibraryMobileTests {
    private static func rows(in view: NSView) -> [BrowserLibraryRow] {
        view.subviews.flatMap { subview -> [BrowserLibraryRow] in
            if let row = subview as? BrowserLibraryRow { return [row] }
            return rows(in: subview)
        }
    }

    private static func sectionButtons(in view: NSView) -> [NSView] {
        view.subviews.filter {
            !$0.isHidden && ($0.accessibilityIdentifier().hasPrefix("browser.library.section."))
        }
    }

    @Test func theMobileSectionListsThePhoneTabsAndOpensOneHere() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let now = Date()
        let old = BrowserSyncMobileTabRecord(
            urlString: "https://example.com/old", title: "Old page", createdAt: now.addingTimeInterval(-3 * 86400),
        )
        let new = BrowserSyncMobileTabRecord(
            urlString: "https://www.example.com/new", createdAt: now.addingTimeInterval(-60), lastActivityAt: now,
        )
        let state = BrowserSyncMobileTabState(
            baseline: .init(entries: [
                "old": .init(serverSeq: 1, record: old),
                "new": .init(serverSeq: 2, record: new),
            ]),
            pending: [],
        )
        let feed = BrowserMobileTabsFeed(load: { state })
        let previous = BrowserMobileTabsFeed.current
        BrowserMobileTabsFeed.current = feed
        defer { BrowserMobileTabsFeed.current = previous }
        #expect(f.model.librarySections.contains(.mobile))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true,
        )
        let library = BrowserLibraryNSView(model: f.model)
        library.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        window.contentView?.addSubview(library)
        f.model.openLibrary(section: .mobile)
        library.refresh()
        library.layoutSubtreeIfNeeded()
        let rows = Self.rows(in: library)
        let titles = rows.compactMap { $0.accessibilityLabel() }
        #expect(
            titles == ["example.com/new", "Old page"],
            "The latest used first; a page without a title shows its address",
        )
        let buttons = Self.sectionButtons(in: library)
        #expect(
            buttons.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= 700 },
            "A shorter window packs the sections closer",
        )

        let tabCount = f.model.tabs.count
        _ = try #require(rows.last).accessibilityPerformPress()
        #expect(f.model.tabs.count == tabCount + 1)
        #expect(f.model.currentTab?.urlString == "https://example.com/old")
        #expect(f.model.librarySection == nil, "Opening a tab closes the Library")
        #expect(state.live.count == 2, "The phone keeps its tab")
    }

    @Test func searchMatchesTitlesAndAddresses() {
        let tabs = [
            BrowserSyncMobileTabEntry(
                id: "a", record: .init(urlString: "https://news.example", title: "Morning", createdAt: .now),
            ),
            BrowserSyncMobileTabEntry(id: "b", record: .init(urlString: "https://maps.example", createdAt: .now)),
        ]
        #expect(BrowserLibraryNSView.mobileTabs(tabs, matching: "").map(\.id) == ["a", "b"])
        #expect(BrowserLibraryNSView.mobileTabs(tabs, matching: "morn").map(\.id) == ["a"])
        #expect(BrowserLibraryNSView.mobileTabs(tabs, matching: "maps").map(\.id) == ["b"])
    }
}
