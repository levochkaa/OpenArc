// BrowserMoveToNewWindowTests.swift

import AppKit
import Testing

// MARK: - BrowserMoveToNewWindowTests

@Suite(.serialized)
@MainActor struct BrowserMoveToNewWindowTests {
    @Test func tabsDroppedOutsideTheWindowOpenInANewOneAndTodayTabsLeave() throws {
        let f = SidebarDragFixture()
        var opened = [[URL]]()
        var points = [CGPoint]()
        f.model.onMoveTabsToNewWindow = { urls, point in
            opened.append(urls)
            points.append(point)
        }
        let revision = f.model.archiveRevision
        let x = f.id("x"), a = f.id("a")
        #expect(f.model.moveTabsToNewWindow(ids: [x, a], at: CGPoint(x: 900, y: 500)))
        #expect(try opened == [[
            #require(URL(string: "https://a.example")),
            #require(URL(string: "https://x.example")),
        ]])
        #expect(points == [CGPoint(x: 900, y: 500)])
        #expect(!f.model.tabs.contains { $0.id == x }, "A Today tab moves to the new window")
        #expect(f.model.tabs.contains { $0.id == a }, "A pinned tab stays")
        #expect(f.model.archiveRevision == revision, "Moving is not archiving")
    }

    @Test func nothingMovesWithoutAWindowToTakeTheTabs() {
        let f = SidebarDragFixture()
        #expect(!f.model.moveTabsToNewWindow(ids: [f.id("x")], at: .zero))
        #expect(f.model.tabs.contains { $0.id == f.id("x") })
    }

    @Test func theNewWindowSitsUnderTheDropInsideTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        let min = CGSize(width: 960, height: 640)
        let size = CGSize(width: 1400, height: 1000)
        let frame = BrowserWindowGeometry.frame(
            droppedAt: CGPoint(x: 600, y: 1200),
            size: size,
            minSize: min,
            visible: screen,
        )
        #expect(frame.minX == 560 && frame.maxY == 1220 && frame.size == size)
        let corner = BrowserWindowGeometry.frame(
            droppedAt: CGPoint(x: 2550, y: 10),
            size: size,
            minSize: min,
            visible: screen,
        )
        #expect(screen.contains(corner), "A drop near the edge keeps the window on screen")
        let small = BrowserWindowGeometry.frame(
            droppedAt: CGPoint(x: 600, y: 900),
            size: CGSize(width: 300, height: 200),
            minSize: min,
            visible: screen,
        )
        #expect(small.size == min)
    }
}
