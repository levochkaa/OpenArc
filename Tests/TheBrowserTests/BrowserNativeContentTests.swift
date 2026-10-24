import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeContentTests {
    @Test func replacingEngineHostDetachesOldViewAndTracksViewportSize() {
        let oldHost = NSView()
        let nextHost = NSView()
        let viewport = BrowserViewportClipView(hostView: oldHost)
        viewport.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        viewport.layoutSubtreeIfNeeded()
        #expect(oldHost.frame == viewport.bounds)
        viewport.update(hostView: nextHost)
        viewport.layoutSubtreeIfNeeded()
        #expect(oldHost.superview == nil)
        #expect(nextHost.superview === viewport)
        #expect(nextHost.frame == viewport.bounds)
        viewport.frame.size = NSSize(width: 340, height: 260)
        viewport.layoutSubtreeIfNeeded()
        #expect(nextHost.frame == viewport.bounds)
        #expect(viewport.subviews.count == 1)
    }

    @Test func fullscreenClippingKeepsOnlySidebarAdjacentCorners() {
        let fullscreen = BrowserContentClipping(isSidebarVisible: true, usesWindowContentInsets: false)
        #expect(fullscreen.corners == [.layerMinXMinYCorner, .layerMinXMaxYCorner])
        #expect(fullscreen.radius == BrowserChromeLayout.leadingContentCornerRadius)
        let edgeToEdge = BrowserContentClipping(isSidebarVisible: false, usesWindowContentInsets: false)
        #expect(edgeToEdge.corners.isEmpty)
        #expect(edgeToEdge.radius == 0)
        let windowed = BrowserContentClipping(isSidebarVisible: false, usesWindowContentInsets: true)
        #expect(windowed.corners == [
            .layerMinXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMinYCorner,
            .layerMaxXMaxYCorner,
        ])
    }

    @Test func aRightSidebarRoundsTheTrailingCornersInFullscreen() {
        let right = BrowserContentClipping(
            isSidebarVisible: true,
            usesWindowContentInsets: false,
            sidebarPosition: .right
        )
        #expect(right.corners == [.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
    }

    @Test func aRightSidebarMirrorsTheWindowChrome() {
        func layout(position: BrowserSidebarPosition, visible: Bool, hover: Bool = false) -> BrowserWindowChromeLayout {
            BrowserWindowChromeLayout(
                windowSize: CGSize(width: 1200, height: 800),
                sidebarWidth: 240,
                isSidebarVisible: visible,
                isHoverSidebarPresented: hover,
                isOverlayChromeVisible: hover,
                isFullscreen: false,
                showsSiteToolbar: false,
                showsBookmarksBar: false,
                extensionSidePanelWidth: 300,
                sidebarPosition: position
            )
        }
        let inset = BrowserChromeLayout.browserContentEdgeInset
        let left = layout(position: .left, visible: true)
        let right = layout(position: .right, visible: true)
        #expect(left.sidebarFrame.minX == 0)
        #expect(right.sidebarFrame == CGRect(x: 960, y: 0, width: 240, height: 800))
        #expect(right.contentFrame.minX == inset)
        #expect(right.contentFrame.width == left.contentFrame.width, "The content keeps its width on either side")
        #expect(right.extensionFrame.maxX == 960, "Extensions sit between the content and the sidebar")
        #expect(right.contentFrame.maxX + BrowserChromeLayout.sidebarOuterPadding == right.extensionFrame.minX)
        #expect(
            layout(position: .right, visible: false).sidebarFrame.minX == 1200,
            "A hidden sidebar leaves to the right"
        )
        let hover = layout(position: .right, visible: false, hover: true).sidebarFrame
        #expect(hover.maxX == 1200 - BrowserChromeLayout.sidebarHoverOverlayEdgeInset)
        let hidden = layout(position: .right, visible: false)
        #expect(hidden.contentFrame.minX == inset)
        #expect(hidden.trailingInset == inset)
    }

    @Test func aTrailingCommandBarAnchorGrowsTowardTheWindowMiddle() {
        let anchor = CGRect(x: 960, y: 40, width: 220, height: 36)
        let layout = BrowserCommandBarLayout(
            availableSize: CGSize(width: 1200, height: 800),
            style: .compact(anchorFrame: anchor, sidebarWidth: 240, matchesAnchorWidth: false),
            displayText: "example.com",
            suggestionCount: 0
        )
        #expect(layout.isTrailingAnchor)
        #expect(layout.origin.x + layout.panelWidth == anchor.maxX)
        #expect(layout.origin.x >= BrowserChromeLayout.sidebarOuterPadding)
    }

    @Test func hiddenTabCannotLeaveAnInvisibleEngineViewInteractive() {
        let host = NSView()
        let view = BrowserContentNSView(hostView: host)
        view.update(
            hostView: host,
            isContextReady: true,
            hasSelectedTab: false,
            isSidebarVisible: true,
            usesWindowContentInsets: true
        )
        #expect(view.viewport.isHidden)
        view.update(
            hostView: host,
            isContextReady: true,
            hasSelectedTab: true,
            isSidebarVisible: false,
            usesWindowContentInsets: false
        )
        #expect(!view.viewport.isHidden)
        #expect(view.viewport.layer?.cornerRadius == 0)
    }

    @Test func extensionPanelRetainsHostAndRoutesCloseAction() {
        let host = NSView()
        let view = BrowserExtensionSidePanelNSView(hostView: host)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        var closed = 0
        view.onClose = { closed += 1 }
        view.update(
            sidePanel: .init(
                panelID: "panel",
                extensionID: "extension",
                title: "Test",
                urlString: "about:blank",
                iconData: nil
            ),
            hostView: host,
            isContextReady: true,
            usesWindowContentInsets: true
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.viewport.frame.minY == BrowserChromeLayout.extensionSidePanelHeaderHeight)
        #expect(view.viewport.frame.maxY == view.bounds.maxY)
        #expect(host.superview === view.viewport)
        view.closeButton.performClick(nil)
        #expect(closed == 1)
    }

    @Test func sidebarEdgeResetsOnDoubleClickAndCollapsesWhenDraggedNarrow() throws {
        let handle = BrowserNativeResizeHandle()
        var width: CGFloat = 400
        var phases = [Bool]()
        var collapses = 0
        handle.getWidth = { width }
        handle.setWidth = { width = $0 }
        handle.defaultWidth = 224
        handle.hapticsEnabled = false
        handle.collapseWidth = BrowserChromeLayout.sidebarCollapseDragWidth
        handle.onCollapse = { collapses += 1 }
        handle.onResizePhaseChange = { phases.append($0) }
        func event(clicks: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 100, y: 100),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: clicks,
                pressure: 1
            ))
        }
        try handle.mouseDown(with: event(clicks: 2))
        #expect(width == 224, "A double click restores the default width")
        #expect(phases == [true, false])
        try handle.mouseDown(with: event(clicks: 1))
        handle.updateDrag(translation: -100)
        try handle.mouseUp(with: event(clicks: 1))
        #expect(collapses == 0, "A drag that stays wide keeps the sidebar")
        try handle.mouseDown(with: event(clicks: 1))
        handle.updateDrag(translation: -200)
        try handle.mouseUp(with: event(clicks: 1))
        #expect(collapses == 1, "Dragging below the collapse width hides the sidebar")
        #expect(BrowserChromeModel.maxSidebarWidth == 500)
        #expect(BrowserChromeLayout.sidebarSnapThreshold == 14)
    }

    @Test func resizeSnapsWithoutAccumulatingTranslationAndEndsCleanly() throws {
        let handle = BrowserNativeResizeHandle()
        var width: CGFloat = 330
        var phases = [Bool]()
        handle.getWidth = { width }
        handle.setWidth = { width = $0 }
        handle.defaultWidth = 360
        handle.direction = -1
        handle.hapticsEnabled = false
        handle.onResizePhaseChange = { phases.append($0) }
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        handle.mouseDown(with: down)
        handle.updateDrag(translation: -25)
        #expect(width == 360)
        handle.updateDrag(translation: -50)
        #expect(width == 380)
        handle.mouseUp(with: down)
        #expect(!handle.isResizing)
        #expect(phases == [true, false])
        handle.updateDrag(translation: -100)
        #expect(width == 380)
    }

    @Test func faviconReuseIgnoresCacheUpdatesForPreviousURL() async throws {
        let cache = BrowserFaviconCache(dataLoader: { _ in nil })
        let firstURL = try #require(URL(string: "https://first.example/icon.png"))
        let secondURL = try #require(URL(string: "https://second.example/icon.png"))
        let first = NSImage(size: NSSize(width: 16, height: 16))
        let second = NSImage(size: NSSize(width: 16, height: 16))
        let view = BrowserFaviconNSView(cache: cache)
        cache.store(first, for: firstURL)
        view.update(url: firstURL, pageURLString: "https://first.example")
        #expect(view.image === first)
        view.update(url: secondURL, pageURLString: "https://second.example")
        #expect(view.image !== first)
        cache.store(second, for: secondURL)
        cache.store(NSImage(), for: firstURL)
        for _ in 0..<100 {
            if view.image === second {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(view.image === second)
    }
}
