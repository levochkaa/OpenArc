// BrowserLibrarySpaceRowTests.swift

import AppKit
import Testing

// MARK: - BrowserLibrarySpaceRowTests

@Suite(.serialized)
@MainActor struct BrowserLibrarySpaceRowTests {
    @Test func aSpaceCardListsPinnedRowsThenTodayWithALineBetween() {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("one", "folder")],
            temporary: ["x"],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")],
        )
        let rows = BrowserLibrarySpaceRow.rows(for: "s", in: f.model.sidebarSnapshot)
        let titles = rows.map { row -> String in
            switch row {
            case .tab(let title, _, _): title
            case .folder(let title): "[\(title)]"
            case .divider: "—"
            }
        }
        #expect(titles == ["a", "[Folder]", "—", "x"])
    }

    @Test func aSpaceWithOnlyTodayTabsHasNoLine() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y"])
        let rows = BrowserLibrarySpaceRow.rows(for: "s", in: f.model.sidebarSnapshot)
        #expect(!rows.contains(.divider))
        #expect(rows.count == 2)
    }
}
