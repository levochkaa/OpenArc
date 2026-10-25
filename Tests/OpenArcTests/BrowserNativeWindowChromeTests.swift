// BrowserNativeWindowChromeTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeWindowChromeTests {
    // MARK: Internal

    @Test func hoverSidebarNeverResizesOrMovesThePage() {
        let hidden = geometry(sidebar: false)
        let overlay = geometry(sidebar: false, hover: true)
        #expect(hidden.contentFrame == overlay.contentFrame)
        #expect(hidden.sidebarFrame.maxX == 0)
        #expect(overlay.sidebarFrame.minX == BrowserChromeLayout.sidebarHoverOverlayEdgeInset)
        #expect(overlay.sidebarFrame.minY > 0)
        #expect(overlay.sidebarFrame.maxY < overlay.windowSize.height)
        let pinned = geometry(sidebar: true)
        #expect(pinned.contentFrame.minX == pinned.sidebarWidth)
        #expect(pinned.sidebarFrame.minX == 0)
        #expect(pinned.sidebarFrame.height == pinned.windowSize.height)
    }

    @Test func toolbarAndBookmarksReserveHeightWhileExtensionOnlyReservesPageWidth() {
        let plain = geometry(sidebar: true)
        let chrome = geometry(sidebar: true, toolbar: true, bookmarks: true, extensionWidth: 300)
        #expect(chrome.toolbarFrame.maxY < chrome.bookmarksFrame.minY)
        #expect(chrome.bookmarksFrame.maxY < chrome.contentFrame.minY)
        #expect(chrome.contentFrame.maxX + BrowserChromeLayout.sidebarOuterPadding == chrome.extensionFrame.minX)
        #expect(chrome.extensionFrame.maxX == chrome.toolbarFrame.maxX)
        #expect(chrome.bookmarksFrame.width == plain.contentFrame.width)
        #expect(chrome.extensionFrame.height == chrome.contentFrame.height)
        #expect(chrome.contentFrame.maxY == plain.contentFrame.maxY)
    }

    @Test func fullscreenRemovesOuterInsetsAndKeepsPinnedSidebarSeparation() {
        let fullscreen = geometry(sidebar: false, fullscreen: true)
        #expect(fullscreen.contentFrame == CGRect(origin: .zero, size: fullscreen.windowSize))
        let sidebar = geometry(sidebar: true, fullscreen: true)
        #expect(sidebar.contentFrame.minX == sidebar.sidebarWidth)
        #expect(sidebar.contentFrame.minY == 0)
        #expect(sidebar.contentFrame.maxX == sidebar.windowSize.width)
        let toolbar = geometry(sidebar: false, fullscreen: true, toolbar: true)
        #expect(toolbar.toolbarFrame.minY == BrowserChromeLayout.sidebarOuterPadding)
        #expect(toolbar.contentFrame.maxY == toolbar.windowSize.height)
    }

    @Test func transparentWindowMarginsPassPageClicksAndOnlyInterceptTheMargins() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let margins = BrowserNativeWindowMargins(frame: container.bounds)
        container.addSubview(margins)
        margins.configure(blockedLeadingWidth: 240, leading: 0, top: 8, trailing: 8, bottom: 8)
        #expect(margins.hitTest(margins.convert(NSPoint(x: 500, y: 300), to: container)) == nil)
        #expect(margins.hitTest(margins.convert(NSPoint(x: 100, y: 4), to: container)) == nil)
        #expect(margins.hitTest(margins.convert(NSPoint(x: 500, y: 4), to: container)) === margins)
        #expect(margins.hitTest(margins.convert(NSPoint(x: 796, y: 300), to: container)) === margins)
        margins.isHidden = true
        #expect(margins.hitTest(margins.convert(NSPoint(x: 796, y: 300), to: container)) == nil)
    }

    // MARK: Private

    private func geometry(
        sidebar: Bool,
        hover: Bool = false,
        fullscreen: Bool = false,
        toolbar: Bool = false,
        bookmarks: Bool = false,
        extensionWidth: CGFloat? = nil,
    ) -> BrowserWindowChromeLayout {
        .init(
            windowSize: CGSize(width: 1200, height: 800),
            sidebarWidth: 260,
            isSidebarVisible: sidebar,
            isHoverSidebarPresented: hover,
            isOverlayChromeVisible: hover,
            isFullscreen: fullscreen,
            showsSiteToolbar: toolbar,
            showsBookmarksBar: bookmarks,
            extensionSidePanelWidth: extensionWidth,
        )
    }
}
