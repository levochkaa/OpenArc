// BrowserPageTopWindowDragTests.swift

import AppKit
import Testing

// MARK: - BrowserPageTopWindowDragTests

@MainActor struct BrowserPageTopWindowDragTests {
    @Test func dragsFromThePageTopMoveTheWindowAndClicksStillReachThePage() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = NSView(frame: root.bounds)
        let overlay = NSButton(frame: NSRect(x: 0, y: 280, width: 40, height: 20))
        root.addSubview(page)
        root.addSubview(overlay)
        window.contentView = root

        let drag = BrowserPageTopWindowDrag()
        var enabled = true
        var drags = [NSEvent]()
        var replays = [NSEvent]()
        drag.pageView = { page }
        drag.region = { enabled ? NSRect(x: 0, y: 300 - 36, width: 400, height: 36) : nil }
        drag.performDrag = { _, event in drags.append(event) }
        drag.replay = { _, event in replays.append(event) }
        drag.start(in: window)
        defer { drag.stop() }

        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1,
            ))
        }

        // A drag past 3 pt moves the window; a small wobble does not.
        let press = try event(.leftMouseDown, 200, 290)
        #expect(drag.handle(press) == nil)
        #expect(try drag.handle(event(.leftMouseDragged, 201, 290)) == nil)
        #expect(drags.isEmpty)
        #expect(try drag.handle(event(.leftMouseDragged, 210, 290)) == nil)
        #expect(drags.count == 1 && drags.first === press)

        // A click hands the page the press, then the release.
        let click = try event(.leftMouseDown, 200, 280)
        #expect(drag.handle(click) == nil)
        let release = try event(.leftMouseUp, 200, 280)
        #expect(drag.handle(release) === release)
        #expect(replays.count == 1 && replays.first === click)

        // Below the strip, double clicks, controls over the page and the
        // setting off leave presses alone.
        let below = try event(.leftMouseDown, 200, 200)
        #expect(drag.handle(below) === below)
        let double = try event(.leftMouseDown, 200, 290, clicks: 2)
        #expect(drag.handle(double) === double)
        let onButton = try event(.leftMouseDown, 20, 290)
        #expect(drag.handle(onButton) === onButton)
        enabled = false
        let off = try event(.leftMouseDown, 200, 290)
        #expect(drag.handle(off) === off)
        #expect(drags.count == 1 && replays.count == 1)
        #expect(drag.pendingPress == nil)
    }
}
