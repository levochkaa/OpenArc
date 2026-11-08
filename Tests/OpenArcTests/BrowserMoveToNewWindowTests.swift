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
        f.model.onMoveTabsToNewWindow = { urls, _, point in
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

    @Test func aTodayTabTakesItsLivePageToTheNewWindow() throws {
        let f = SidebarDragFixture()
        let x = f.id("x"), a = f.id("a")
        f.driver.detachablePageTabIDs = [x, a]
        var pages = [BrowserTabPageHandoff?]()
        f.model.onMoveTabsToNewWindow = { _, handed, _ in pages = handed }
        #expect(f.model.moveTabsToNewWindow(ids: [x, a], at: .zero))
        #expect(pages.count == 2)
        #expect(pages[0] == nil, "A pinned tab's page stays")
        let moved = try #require(pages[1])
        #expect(moved.urlString == "https://x.example")
        #expect(f.driver.detachedPageTabIDs == [x])
        #expect(!f.driver.closedTabRequests.map(\.id).contains(x), "The page does not close")
        #expect(!f.model.tabs.contains { $0.id == x })

        let target = SidebarDragFixture(pinned: [], temporary: [])
        let created = target.driver.createdTabRequests.count
        let id = try #require(target.model.adoptPageAsNewTab(moved, makeActive: true))
        #expect(target.driver.createdTabRequests.count == created, "Nothing loads")
        let tab = try #require(target.model.tabs.first { $0.id == id })
        #expect(tab.urlString == "https://x.example" && tab.creationState == .ready && tab.placement == .temporary)
        #expect(target.model.selectedTabID == id)
    }

    @Test func anotherWindowTakesDroppedTabsAndTodayTabsLeaveThisOne() {
        let source = SidebarDragFixture()
        let target = SidebarDragFixture(pinned: [], temporary: ["t"])
        let x = source.id("x"), a = source.id("a")
        let before = target.model.tabs.count
        #expect(source.model.moveTabs(ids: [x, a], toWindowOf: target.model))
        target.driver.flushPendingCreateEvents()
        let added = target.model.tabs.dropFirst(before).map(\.urlString)
        #expect(Set(added) == ["https://a.example", "https://x.example"])
        #expect(target.model.tabs.first { $0.id == target.model.selectedTabID }?.urlString == "https://a.example")
        #expect(!source.model.tabs.contains { $0.id == x }, "A Today tab leaves")
        #expect(source.model.tabs.contains { $0.id == a }, "A pinned tab stays")
    }

    @Test func aWindowOfTheSameProfileShowsTheTabInstead() {
        let source = SidebarDragFixture()
        let target = SidebarDragFixture()
        let group = BrowserProfileWindowGroup()
        group.add(source.model)
        group.add(target.model)
        let x = source.id("x")
        let syncID = source.model.tabs.first { $0.id == x }?.syncID
        let count = target.model.tabs.count
        #expect(source.model.moveTabs(ids: [x], toWindowOf: target.model))
        #expect(target.model.tabs.count == count, "The same tabs, nothing copied")
        #expect(target.model.tabs.first { $0.id == target.model.selectedTabID }?.syncID == syncID)
        #expect(source.model.tabs.contains { $0.id == x })
    }

    @Test func aPageInFullscreenLeavesItWhenAnotherTabIsShown() {
        let f = SidebarDragFixture()
        let x = f.id("x"), y = f.id("y")
        f.model.selectTab(id: x)
        f.driver.onPageFullscreenChanged?(x, true)
        #expect(f.model.pageFullscreenTabID == x)
        f.model.selectTab(id: y)
        #expect(f.driver.exitPageFullscreenCount == 1)
        f.driver.onPageFullscreenChanged?(x, false)
        #expect(f.model.pageFullscreenTabID == nil)
    }

    @Test func tabsALinkOpensGoBelowTheirOpenerInOrder() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y", "z"])
        let x = f.id("x")
        let one = try #require(URL(string: "https://one.example"))
        let two = try #require(URL(string: "https://two.example"))
        let first = try #require(f.model.openURLInBackgroundTab(one))
        f.driver.onTabOpenedFromTab?(first, x)
        let second = try #require(f.model.openURLInBackgroundTab(two))
        f.driver.onTabOpenedFromTab?(second, x)
        #expect(f.model.temporaryTabs.map(\.id) == [x, first, second, f.id("y"), f.id("z")])
    }

    @Test func aWindowNeverTakesItsOwnTabs() {
        let f = SidebarDragFixture()
        #expect(!f.model.moveTabs(ids: [f.id("x")], toWindowOf: f.model))
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
