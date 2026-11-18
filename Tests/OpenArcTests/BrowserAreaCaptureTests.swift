// BrowserAreaCaptureTests.swift

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
            defer: false,
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
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
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
            "A click, a click beside the page and Escape cancel",
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

    @Test func anOutlineFromTheMenuOpensTheCardWithThatPartAndTheGrayPage() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        let page = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        )?.representation(using: .png, properties: [:]))
        f.driver.pagePicturePNG = page
        var requests = [BrowserCaptureRequest]()
        f.model.onPresentCapture = { requests.append($0) }
        let part = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)

        #expect(f.model.captureAreaForCard(fraction: part, tabID: f.id("x")))

        let request = try #require(requests.first)
        #expect(request.placement == .outlined(part) && request.kind == .area && request.tabID == f.id("x"))
        #expect(request.pagePNG == page)
        let picture = try #require(BrowserCaptureImaging.cgImage(png: request.png))
        #expect(picture.width == 100 && picture.height == 50)
        #expect(f.driver.regionCaptures.isEmpty, "Nothing goes to the clipboard on its own")
        #expect(!f.model.captureAreaForCard(fraction: part, tabID: "other"))
    }

    @Test func shiftCommandDragCopiesWhileTheMenuOpensTheCard() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        var copies = [Bool]()
        f.model.onBeginAreaCapture = { [weak model = f.model] in
            copies.append(model?.areaCaptureCopiesToClipboard ?? false)
            return true
        }
        #expect(f.model.beginAreaCapture())
        #expect(f.model.beginAreaCapture(copyingToClipboard: true))
        #expect(copies == [false, true])
        #expect(!f.model.areaCaptureCopiesToClipboard)
    }

    @Test func theCardClosesWhenAnotherTabIsShown() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        let content = BrowserContentNSView(hostView: NSView())
        content.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        content.bindTabCreation(to: f.model)
        let png = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        )?.representation(using: .png, properties: [:]))
        content.presentCaptureCard(BrowserCaptureRequest(
            png: png, kind: .image, placement: .centered, pagePNG: nil, pageURL: nil, title: nil, tabID: f.id("x"),
        ))
        #expect(content.captureCard != nil)
        #expect(content.captureCard?.card.pictureFrame.size == CGSize(width: 20, height: 10))

        f.model.selectTab(id: f.id("y"))
        content.cancelAreaCaptureIfStale()
        #expect(content.captureCard == nil)
    }

    @Test func anOutlineForAnotherTabIsCancelledAndFocusReturnsToThePage() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        let content = BrowserContentNSView(hostView: NSView())
        content.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        content.bindTabCreation(to: f.model)
        #expect(f.model.beginAreaCapture())
        #expect(content.areaCapture != nil)
        #expect(!f.model.captureArea(fraction: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), tabID: f.id("y")))

        f.model.selectTab(id: f.id("y"))
        content.cancelAreaCaptureIfStale()
        #expect(content.areaCapture == nil, "Another selected tab cancels the outline")
        #expect(f.driver.regionCaptures.isEmpty && f.driver.pageFocusCount == 1, "The keys go back to the page")

        f.model.selectTab(id: f.id("x"))
        #expect(f.model.beginAreaCapture())
        content.frame.size.width = 900
        content.cancelAreaCaptureIfStale()
        #expect(content.areaCapture == nil, "A resize cancels it too")
    }

    @Test func aPaneThatChangesSizeCancelsItsOutline() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        f.model.selectTab(id: f.id("x"))
        let content = BrowserContentNSView(hostView: NSView())
        content.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        content.bindTabCreation(to: f.model)
        f.driver.simulateSplitPaneLayout([f.id("x"), f.id("y")], frames: [
            CGRect(x: 0, y: 0, width: 496, height: 600),
            CGRect(x: 504, y: 0, width: 496, height: 600),
        ])
        #expect(f.model.beginAreaCapture())
        #expect(content.areaCapture?.pageFrame.width == 496)
        f.driver.simulateSplitPaneLayout([f.id("x")], frames: [CGRect(x: 0, y: 0, width: 1000, height: 600)])
        #expect(content.areaCapture == nil, "The pane grew, so the outline would copy the wrong part")
    }

    @Test func selectionFindActionsGoToThePageItself() async throws {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        f.driver.emitTabCreationState(id: f.id("x"), state: .ready)
        var changeCount = 1
        f.model.findPasteboardChangeCount = { changeCount }
        f.model.findPasteboardText = { "needle" }
        #expect(f.model.useSelectionForFind())
        #expect(f.driver.pageActions == [Selector(("copyToFindPboard:"))])
        try await Task.sleep(for: .milliseconds(300))
        #expect(!f.model.isFindBarPresented, "Without a new selection nothing is searched")
        changeCount = 2
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.model.isFindBarPresented && f.model.findQuery == "needle", "A late answer still opens it")

        #expect(f.model.jumpToSelection())
        #expect(f.driver.pageActions.last == #selector(NSResponder.centerSelectionInVisibleArea(_:)))
        f.driver.pageActionResult = false
        #expect(!f.model.useSelectionForFind(), "No page view, no find")
    }
}
