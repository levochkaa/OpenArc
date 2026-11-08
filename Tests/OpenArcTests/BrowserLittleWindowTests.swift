// BrowserLittleWindowTests.swift

import AppKit
import Testing

// MARK: - BrowserLittleWindowTests

@Suite(.serialized)
@MainActor struct BrowserLittleWindowTests {
    @Test func aSmallWindowSitsInTheTopRightCornerOfTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1084)
        let frame = BrowserPeekPanel.standaloneFrame(in: screen)
        #expect(frame.maxX == screen.maxX - 20 && frame.maxY == screen.maxY - 20)
        #expect(frame.size == NSSize(width: 1185, height: 832), "The small window's size on a 14-inch MacBook Pro")
        let large = BrowserPeekPanel.standaloneFrame(in: NSRect(x: 0, y: 0, width: 2560, height: 1410))
        #expect(large.width == 1756 && large.height == 1082, "The same share of a larger screen")
        let small = BrowserPeekPanel.standaloneFrame(in: NSRect(x: 0, y: 0, width: 700, height: 500))
        #expect(small.width == 620 && small.height == 420, "A small screen keeps some room around it")
    }

    @Test func theSmallWindowBarOpensWhatItIsGivenInASmallWindow() {
        let f = SidebarDragFixture()
        var presented = 0
        f.model.onPresentLittleWindowLauncher = {
            presented += 1
            return true
        }
        #expect(f.model.openNewLittleWindow() || !f.model.canOpenLittleWindow)
        if f.model.canOpenLittleWindow {
            #expect(presented == 1, "New Small Window asks where to go first")
        }
    }
}
