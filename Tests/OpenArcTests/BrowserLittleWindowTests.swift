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

    @Test func theSmallWindowBarHasACloseButtonBesideItsField() throws {
        let f = SidebarDragFixture()
        let model = f.model.littleWindowCommandBarModel
        let bar = BrowserCommandBarNSView(model: model)
        bar.frame = NSRect(x: 0, y: 0, width: 506, height: 640)
        #expect(!bar.showsCloseButton, "Command bars in a window have none")
        bar.showsCloseButton = true
        model.present()
        bar.layoutSubtreeIfNeeded()
        let close = try #require(bar.descendant(withIdentifier: "browser.command.close") as? BrowserNativeChromeButton)
        let field = try #require(bar.descendant(withIdentifier: "browser.command.query"))
        #expect(!close.isHidden && close.frame.width == 24)
        #expect(field.frame.maxX <= close.frame.minX, "The text stops before it")
        close.onAction()
        #expect(!model.isPresented)
    }
}

private extension NSView {
    func descendant(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier { return self }
        for child in subviews {
            if let match = child.descendant(withIdentifier: identifier) { return match }
        }
        return nil
    }
}
