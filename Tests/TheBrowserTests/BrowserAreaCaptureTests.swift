import AppKit
import Testing

// MARK: - BrowserAreaCaptureTests

@Suite(.serialized)
@MainActor struct BrowserAreaCaptureTests {
    @Test func aDraggedOutlineBecomesFractionsOfThePage() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let overlay = BrowserAreaCaptureOverlay(pageFrame: CGRect(x: 100, y: 50, width: 400, height: 300))
        overlay.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = overlay
        var results = [CGRect?]()
        overlay.onFinish = { results.append($0) }

        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            // The overlay is flipped; window coordinates grow upward.
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 400 - y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        try overlay.mouseDown(with: event(.leftMouseDown, 200, 125))
        try overlay.mouseDragged(with: event(.leftMouseDragged, 700, 425))
        try overlay.mouseUp(with: event(.leftMouseUp, 700, 425))
        #expect(results == [CGRect(x: 0.25, y: 0.25, width: 0.75, height: 0.75)], "Drags stop at the page edge")

        try overlay.mouseDown(with: event(.leftMouseDown, 200, 125))
        try overlay.mouseUp(with: event(.leftMouseUp, 201, 126))
        try overlay.mouseDown(with: event(.leftMouseDown, 20, 20))
        overlay.cancelOperation(nil)
        #expect(
            results.count == 4 && results.dropFirst().allSatisfy { $0 == nil },
            "A click, a click beside the page and Escape cancel"
        )
    }

    @Test func captureAsksTheWindowForAnOutlineThenTheEngineForThatPart() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        #expect(!f.model.canCaptureArea, "Only a window that can outline the page offers it")
        var outlines = 0
        f.model.onBeginAreaCapture = {
            outlines += 1
            return true
        }
        #expect(f.model.canCaptureArea && f.model.beginAreaCapture() && outlines == 1)
        let part = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        #expect(f.model.captureArea(fraction: part))
        #expect(f.driver.regionCaptures == [part])
        #expect(!f.model.captureArea(fraction: .zero))
    }
}
