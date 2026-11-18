// BrowserEaselsTests.swift

import AppKit
import Foundation
import Testing

// MARK: - BrowserEaselModelTests

@MainActor struct BrowserEaselModelTests {
    @Test func easelAddressesNameTheirEasel() {
        let urlString = BrowserEaselURL.urlString(forEaselID: "A1B2-C3")
        #expect(urlString == "openarc://easel/A1B2-C3")
        #expect(BrowserEaselURL.easelID(from: urlString) == "A1B2-C3")
        #expect(BrowserEaselURL.easelID(from: "OPENARC://EASEL/abc") == "abc")
        #expect(BrowserEaselURL.easelID(from: "openarc://easel/") == nil)
        #expect(BrowserEaselURL.easelID(from: "openarc://easel/a/b") == nil)
        #expect(BrowserEaselURL.easelID(from: "openarc://easel/..%2F") == nil)
        #expect(BrowserEaselURL.easelID(from: "https://easel/abc") == nil)
        #expect(BrowserEaselURL.easelID(from: "openarc://settings/") == nil)
    }

    @Test func theEngineServesEaselPagesItselfRatherThanChromium() {
        #expect(BrowserInternalURLNormalizer.canonicalURLString(for: "openarc://easel/abc") == nil)
        #expect(BrowserInternalURLNormalizer.chromiumURLString(forCanonicalURLString: "openarc://easel/abc") == nil)
        #expect(BrowserInternalURLNormalizer.host(for: "openarc://easel/abc") == nil)
        #expect(BrowserInternalURLNormalizer.chromiumURLString(forCanonicalURLString: "openarc://history") != nil)
    }

    @Test func aNewEaselHoldsItsTitleAtTheTop() {
        let document = BrowserEaselDocument.new(id: "e", title: "Trip")
        #expect(document.objects.count == 1)
        #expect(document.title == "Trip")
        #expect(document.titleObject?.frame == BrowserEaselDocument.titleFrame)
        #expect(document.titleObject?.content.text?.style == .h2)
        #expect(BrowserEaselDocument.new(id: "f", title: "  ").title == BrowserStrings.easelUntitled)
    }

    @Test func paletteColorsSwapBlackAndWhiteInTheDark() {
        #expect(BrowserEaselColor.lightGreen.rgb(palette: .vibrant, isDark: false) == 0x34E895)
        #expect(BrowserEaselColor.lightGreen.rgb(palette: .chill, isDark: false) == 0xD0D87F)
        #expect(BrowserEaselColor.black.rgb(palette: .vibrant, isDark: true) == 0xFFFFFF)
        #expect(BrowserEaselColor.white.rgb(palette: .chill, isDark: true) == 0x000000)
        #expect(BrowserEaselColor.pickerRows.flatMap(\.self).count == BrowserEaselColor.allCases.count)
    }

    @Test func textStylesStepBetweenUltraAndBody() {
        #expect(BrowserEaselTextStyle.body.larger == .h2)
        #expect(BrowserEaselTextStyle.ultra.larger == nil)
        #expect(BrowserEaselTextStyle.body.smaller == nil)
        #expect(BrowserEaselFont.mono.next == .clean)
        #expect(BrowserEaselFont.clean.metrics(for: .h2).size == 24)
        #expect(BrowserEaselFont.fancy.metrics(for: .h1).size == 48)
    }

    @Test func documentsRoundTripThroughJSON() throws {
        var document = BrowserEaselDocument.new(id: "doc", title: "Board")
        document.objects.append(BrowserEaselObject(
            id: "arrow",
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            content: .shape(BrowserEaselShape(
                kind: .arrow,
                color: .purple,
                arrowStart: CGPoint(x: 1, y: 0),
                arrowEnd: CGPoint(x: 0, y: 1),
            )),
        ))
        document.objects.append(BrowserEaselObject(
            id: "capture",
            frame: CGRect(x: 0, y: 100, width: 300, height: 200),
            content: .capture(BrowserEaselCapture(
                fileName: "a.png",
                urlString: "https://example.com",
                title: "Example",
                region: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                isLive: true,
                capturedAt: Date(timeIntervalSince1970: 100),
            )),
        ))
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(BrowserEaselDocument.self, from: data) == document)
        #expect(document.fileNames == ["a.png"])
        #expect(document.contentBottom == 300)
    }
}

// MARK: - BrowserEaselStoreTests

@MainActor struct BrowserEaselStoreTests {
    static func png(color: NSColor = .systemRed, size: CGSize = CGSize(width: 40, height: 20)) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    @Test func savedEaselsLoadAgainNewestFirstAndDeleteWithTheirPictures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("easels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserEaselStore(directory: directory)
        let older = BrowserEaselDocument.new(id: "older", title: "Older", now: Date(timeIntervalSince1970: 10))
        var newer = BrowserEaselDocument.new(id: "newer", title: "Newer", now: Date(timeIntervalSince1970: 20))
        let png = try #require(Self.png())
        let name = store.addImage(png, toEaselID: "newer")
        newer.objects.append(BrowserEaselObject(
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            content: .image(BrowserEaselImage(fileName: name)),
        ))
        final class Notified: @unchecked Sendable { var ids = [String]() }
        let notified = Notified()
        let observer = NotificationCenter.default.addObserver(
            forName: BrowserEaselStore.didChangeNotification,
            object: store,
            queue: nil,
        ) { notified.ids.append($0.userInfo?["id"] as? String ?? "") }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.save(older)
        store.save(newer)
        store.save(newer)
        #expect(notified.ids == ["older", "newer"], "Saving the same document again changes nothing")

        let reloaded = BrowserEaselStore(directory: directory)
        #expect(reloaded.allDocuments.map(\.id) == ["newer", "older"])
        #expect(reloaded.document(id: "newer") == newer)
        #expect(reloaded.image(named: name, easelID: "newer") != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("newer/easel.json").path))

        reloaded.delete(id: "newer")
        #expect(reloaded.document(id: "newer") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("newer").path))
        #expect(BrowserEaselStore(directory: directory).allDocuments.map(\.id) == ["older"])
    }

    @Test func aStoreWithoutAFolderKeepsEverythingInMemory() throws {
        let store = BrowserEaselStore(directory: nil)
        store.save(.new(id: "a", title: "A"))
        #expect(store.document(id: "a")?.title == "A")
        let name = try store.addImage(#require(Self.png()), toEaselID: "a")
        #expect(store.imageData(named: name, easelID: "a") != nil)
    }
}

// MARK: - BrowserEaselEditorTests

@MainActor struct BrowserEaselEditorTests {
    @Test func shapesTakeTheDraggedRectangleOrTheDefaultSizeOnAClick() {
        let editor = makeEditor()
        let dragged = editor.insertShape(.rectangle, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 120))
        #expect(editor.document.object(dragged)?.frame == CGRect(x: 100, y: 120, width: 200, height: 80))
        #expect(editor.document.object(dragged)?.content.shape?.color == .lightGreen)
        #expect(editor.selectedObjectID == dragged)

        let clicked = editor.insertShape(.circle, from: CGPoint(x: 500, y: 500), to: CGPoint(x: 501, y: 500))
        #expect(editor.document.object(clicked)?.frame == CGRect(x: 425, y: 425, width: 150, height: 150))
        #expect(editor.document.object(clicked)?.content.shape?.color == .red)

        let square = editor.insertShape(
            .rectangle,
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 50, y: 20),
            keepsSquare: true,
        )
        #expect(editor.document.object(square)?.frame.size == CGSize(width: 50, height: 50))
        #expect(editor.document.modifiedAt == Date(timeIntervalSince1970: 50))
    }

    @Test func arrowsKeepTheirDirection() throws {
        let editor = makeEditor()
        let id = editor.insertShape(.arrow, from: CGPoint(x: 400, y: 100), to: CGPoint(x: 100, y: 300))
        let shape = try #require(editor.document.object(id)?.content.shape)
        #expect(shape.arrowStart == CGPoint(x: 1, y: 0))
        #expect(shape.arrowEnd == CGPoint(x: 0, y: 1))

        let object = try #require(editor.document.object(id))
        let (frame, moved) = BrowserEaselEditor.movedArrow(
            frame: object.frame,
            shape: shape,
            handle: .arrowEnd,
            to: CGPoint(x: 600, y: 100),
        )
        #expect(frame == CGRect(x: 400, y: 99.5, width: 200, height: 1))
        #expect(moved.arrowStart.x == 0 && moved.arrowEnd.x == 1)

        #expect(BrowserEaselEditor.hitObject(at: CGPoint(x: 250, y: 200), in: editor.document, tolerance: 4) == id)
        #expect(BrowserEaselEditor.hitObject(at: CGPoint(x: 120, y: 120), in: editor.document, tolerance: 4) == nil)
    }

    @Test func penStrokesKeepTheirPointsWithinTheirFrame() throws {
        let editor = makeEditor()
        #expect(editor.insertDrawing([CGPoint(x: 1, y: 1)]) == nil)
        let id = try #require(editor.insertDrawing([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 200, y: 150),
            CGPoint(x: 300, y: 100),
        ]))
        let object = try #require(editor.document.object(id))
        #expect(object.frame == CGRect(x: 100, y: 100, width: 200, height: 50))
        #expect(object.content.shape?.points == [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0)])
        #expect(editor.selectedObjectID == nil, "The pen goes on drawing")
    }

    @Test func everyEditIsOneUndoStep() {
        let editor = makeEditor()
        var saved = [BrowserEaselDocument]()
        editor.onChange = { saved.append($0) }
        let id = editor.insertShape(.rectangle, from: .zero, to: CGPoint(x: 100, y: 100))
        editor.setColor(.darkBlue, of: id)
        editor.setFrame(CGRect(x: 50, y: 60, width: 100, height: 100), of: id)
        #expect(saved.count == 3)
        #expect(editor.undoManager.undoActionName == BrowserStrings.easelUndoMove)

        editor.undoManager.undo()
        #expect(editor.document.object(id)?.frame.origin == .zero)
        editor.undoManager.undo()
        #expect(editor.document.object(id)?.content.shape?.color == .lightGreen)
        editor.undoManager.undo()
        #expect(editor.document.object(id) == nil)
        #expect(editor.selectedObjectID == nil, "Undo takes away the selection of a removed object")
        editor.undoManager.redo()
        #expect(editor.document.object(id) != nil)
        #expect(saved.count == 7)
        #expect(!editor.change("Nothing") { _ in }, "An edit that changes nothing records nothing")
    }

    @Test func objectsMoveToTheFrontOrBackAndDuplicateBesideThemselves() throws {
        let editor = makeEditor()
        let first = editor.insertShape(.rectangle, from: .zero, to: CGPoint(x: 10, y: 10))
        let second = editor.insertShape(.circle, from: .zero, to: CGPoint(x: 10, y: 10))
        editor.bringToFront(first)
        #expect(editor.document.objects.last?.id == first)
        editor.sendToBack(first)
        #expect(editor.document.objects.first?.id == first)
        editor.selectedObjectID = second
        let copy = try #require(editor.duplicateSelection())
        #expect(editor.document.object(copy)?.frame.origin == CGPoint(x: 20, y: 20))
        #expect(editor.selectedObjectID == copy)
        editor.deleteSelection()
        #expect(editor.document.object(copy) == nil)
    }

    @Test func titleCopiesAreNotTitlesAndAnyTextCanBecomeTheTitle() throws {
        let editor = makeEditor()
        let title = try #require(editor.document.titleObject?.id)
        editor.selectedObjectID = title
        let copy = try #require(editor.duplicateSelection())
        #expect(editor.document.object(copy)?.content.text?.isTitle == false)
        editor.setText("Plans", of: copy)
        editor.makeTitle(copy)
        #expect(editor.document.title == "Plans")
        #expect(editor.document.object(title)?.content.text?.isTitle == false)
    }

    @Test func textStepsThroughStylesAndFontsAndFitsItsLines() throws {
        let editor = makeEditor()
        let id = editor.insertText(at: CGPoint(x: 100, y: 400), string: "Hello")
        let bodyHeight = try #require(editor.document.object(id)?.frame.height)
        #expect(editor.stepTextStyle(of: id, larger: true))
        #expect(editor.document.object(id)?.content.text?.style == .h2)
        #expect(try #require(editor.document.object(id)?.frame.height) > bodyHeight)
        for _ in 0..<3 {
            editor.stepTextStyle(of: id, larger: true)
        }
        #expect(editor.document.object(id)?.content.text?.style == .ultra)
        #expect(!editor.stepTextStyle(of: id, larger: true))
        editor.cycleFont(of: id)
        #expect(editor.document.object(id)?.content.text?.font == .hip)
    }

    @Test func liveCapturesAndPaletteAndGuidesAreUndoable() {
        let editor = makeEditor()
        let id = editor.insertCapture(
            BrowserEaselCapture(
                fileName: "c.png",
                urlString: "https://example.com",
                title: "E",
                region: CGRect(x: 0, y: 0, width: 1, height: 1),
                capturedAt: Date(),
            ),
            size: CGSize(width: 1000, height: 500),
            center: CGPoint(x: 500, y: 500),
        )
        #expect(editor.document.object(id)?.frame == CGRect(x: 250, y: 375, width: 500, height: 250))
        editor.setLive(true, of: id)
        #expect(editor.document.object(id)?.content.capture?.isLive == true)
        editor.setPalette(.chill)
        editor.setUsesAlignmentGuides(false)
        #expect(editor.document.palette == .chill && !editor.document.usesAlignmentGuides)
        editor.undoManager.undo()
        editor.undoManager.undo()
        editor.undoManager.undo()
        #expect(editor.document.palette == .vibrant && editor.document.object(id)?.content.capture?.isLive == false)
    }

    @Test func cornersResizeAgainstTheOppositeCorner() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(BrowserEaselEditor.resizedFrame(
            frame,
            handle: .bottomRight,
            to: CGPoint(x: 400, y: 300),
            keepsAspect: false,
        )
            == CGRect(x: 100, y: 100, width: 300, height: 200))
        #expect(BrowserEaselEditor.resizedFrame(frame, handle: .topLeft, to: CGPoint(x: 0, y: 150), keepsAspect: false)
            == CGRect(x: 0, y: 150, width: 300, height: 50))
        #expect(BrowserEaselEditor.resizedFrame(
            frame,
            handle: .bottomRight,
            to: CGPoint(x: 500, y: 150),
            keepsAspect: true,
        )
            == CGRect(x: 100, y: 100, width: 400, height: 200))
        #expect(BrowserEaselEditor.resizedFrame(
            frame,
            handle: .bottomRight,
            to: CGPoint(x: 100, y: 100),
            keepsAspect: false,
        )
        .size == CGSize(width: BrowserEaselEditor.minimumSize, height: BrowserEaselEditor.minimumSize))
    }

    @Test func movingObjectsSnapToOtherObjectsAndThePageCenter() {
        let others = [CGRect(x: 100, y: 100, width: 100, height: 100)]
        let snap = BrowserEaselEditor.snapOffset(for: CGRect(x: 203, y: 297, width: 50, height: 50), among: others)
        #expect(snap.offset == CGPoint(x: -3, y: 0))
        #expect(snap.verticals == [200])
        #expect(snap.horizontals.isEmpty)
        let below = BrowserEaselEditor.snapOffset(for: CGRect(x: 600, y: 196, width: 50, height: 50), among: others)
        #expect(below.offset == CGPoint(x: 0, y: 4) && below.horizontals == [200])
        let centered = BrowserEaselEditor.snapOffset(for: CGRect(x: 448, y: 0, width: 100, height: 10), among: [])
        #expect(centered.offset.x == 2 && centered.verticals == [500])
        let far = BrowserEaselEditor.snapOffset(for: CGRect(x: 700, y: 700, width: 10, height: 10), among: others)
        #expect(far.offset == .zero && far.verticals.isEmpty && far.horizontals.isEmpty)
    }

    private func makeEditor() -> BrowserEaselEditor {
        BrowserEaselEditor(document: .new(id: "e", title: "Title", now: Date(timeIntervalSince1970: 0))) {
            Date(timeIntervalSince1970: 50)
        }
    }
}

// MARK: - BrowserEaselChromeModelTests

@MainActor struct BrowserEaselChromeModelTests {
    @Test func newEaselsArePinnedAtTheEndOfTheSpaceAndShowTheirTitle() throws {
        let (model, driver) = makeEaselModel()
        let tabID = try #require(model.createEasel(.new(id: "first", title: "Moodboard")))
        driver.flushPendingCreateEvents()
        let tab = try #require(model.tabs.first { $0.id == model.selectedTabID })
        #expect(tab.id == tabID)
        #expect(tab.urlString == "openarc://easel/first")
        #expect(tab.placement == .spacePinned)
        #expect(tab.displayTitle == "Moodboard")
        #expect(model.easelID(forTabID: tabID) == "first")
        #expect(model.visibleEaselTabIDs == [tabID])
        #expect(model.easelStore.document(id: "first")?.title == "Moodboard")
        #expect(model.sidebarSnapshot.tabIcons[tabID] == "scribble.variable")

        let second = try #require(model.createEasel())
        let pinned = model.tabs.filter { $0.placement == .spacePinned }.map(\.id)
        #expect(pinned.suffix(2) == [tabID, second], "Each new Easel goes below the last pinned row")
    }

    @Test func openingAnEaselSelectsItsTabOrPinsANewOne() throws {
        let (model, _) = makeEaselModel()
        let tabID = try #require(model.createEasel(.new(id: "e1", title: "One")))
        try model.selectTab(id: #require(model.tabs.first { $0.urlString.hasPrefix("https") }?.id))
        #expect(model.openEasel(id: "e1"))
        #expect(model.selectedTabID == tabID)

        model.easelStore.save(.new(id: "e2", title: "Two"))
        #expect(model.openEasel(id: "e2"))
        #expect(model.easelID(forTabID: model.selectedTabID) == "e2")
        #expect(!model.openEasel(id: "missing"))
    }

    @Test func deletingAnEaselRemovesItsDrawingAndItsTab() throws {
        let (model, _) = makeEaselModel()
        let tabID = try #require(model.createEasel(.new(id: "gone", title: "Gone")))
        model.deleteEasel(id: "gone")
        #expect(!model.tabs.contains { $0.id == tabID })
        #expect(model.easelStore.document(id: "gone") == nil)
    }

    @Test func theTitleFollowsTheCanvasAndTheRowRename() throws {
        let (model, _) = makeEaselModel()
        let tabID = try #require(model.createEasel(.new(id: "t", title: "Before")))
        let editor = try BrowserEaselEditor(document: #require(model.easelStore.document(id: "t")))
        // The canvas syncs as it shows, then the title changes on it.
        model.syncEaselTitle(tabID: tabID, editor: editor)
        try editor.setText("After", of: #require(editor.document.titleObject?.id))
        model.syncEaselTitle(tabID: tabID, editor: editor)
        #expect(model.tabs.first { $0.id == tabID }?.displayTitle == "After")

        model.setUserTitleOverride("Renamed", forTabID: tabID)
        model.syncEaselTitle(tabID: tabID, editor: editor)
        #expect(editor.document.title == "Renamed")

        // A row renamed while the Easel was not on screen wins over its canvas.
        model.setUserTitleOverride("Offscreen", forTabID: tabID)
        let reopened = BrowserEaselEditor(document: editor.document)
        model.syncEaselTitle(tabID: tabID, editor: reopened)
        #expect(reopened.document.title == "Offscreen")
    }

    @Test func easelsBelongToNormalWindowsAndTheLibrary() {
        let (model, _) = makeEaselModel()
        #expect(model.librarySections.contains(.easels))
        #expect(model.isCommandBarActionAvailable(.newEasel))
        #expect(model.viewEasels())
        #expect(model.librarySection == .easels)
        #expect(BrowserCommandID.newEasel.defaultDescriptor.shortcut
            == BrowserKeyboardShortcut("e", modifiers: [.control, .shift]))

        let (incognito, _) = makeEaselModel(windowMode: .incognito)
        #expect(!incognito.librarySections.contains(.easels))
        #expect(incognito.createEasel() == nil)
        #expect(!incognito.viewEasels())
        #expect(!incognito.isCommandBarActionAvailable(.newEasel))
    }

    @Test func aCaptureJoinsTheEaselThatAskedForIt() throws {
        let (model, _) = makeEaselModel()
        let pageID = try #require(model.tabs.first?.id)
        let easelTab = try #require(model.createEasel(.new(id: "cap", title: "Captures")))
        #expect(model.openInSplitView(tabID: pageID, anchorTabID: easelTab))
        model.easelCaptureTargetID = "cap"
        model.noteAreaCapture(fraction: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25), tabID: pageID)
        let png = try #require(BrowserEaselStoreTests.png(size: CGSize(width: 400, height: 200)))
        model.didCopyAreaCapture(png: png)
        let document = try #require(model.easelStore.document(id: "cap"))
        let capture = try #require(document.objects.last?.content.capture)
        #expect(capture.urlString == "https://example.com")
        #expect(capture.region == CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25))
        #expect(document.objects.last?.frame.size == CGSize(width: 200, height: 100))
        #expect(model.easelStore.image(named: capture.fileName, easelID: "cap") != nil)
        #expect(model.easelCaptureTargetID == nil)

        model.didCopyAreaCapture(png: png)
        #expect(
            model.easelStore.document(id: "cap")?.objects.count == document.objects.count,
            "Captures without a waiting Easel stay on the clipboard only",
        )
    }

    @Test func liveCapturesAskTheirOpenPageForTheSameRegion() throws {
        let (model, driver) = makeEaselModel()
        let pageID = try #require(model.tabs.first?.id)
        let region = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let capture = BrowserEaselCapture(
            fileName: "c.png",
            urlString: "https://example.com",
            title: "Example",
            region: region,
            isLive: true,
            capturedAt: Date(),
        )
        driver.tabRegionPNG = BrowserEaselStoreTests.png()
        var received: Data?
        model.refreshLiveCapture(capture) { received = $0 }
        #expect(driver.capturedTabRegions.map(\.tabID) == [pageID])
        #expect(driver.capturedTabRegions.first?.fraction == region)
        #expect(received != nil)

        var closed: Data? = Data()
        var other = capture
        other.urlString = "https://elsewhere.example"
        model.refreshLiveCapture(other) { closed = $0 }
        #expect(closed == nil, "A page that is not open keeps its last picture")
        #expect(driver.capturedTabRegions.count == 1)
    }

    @Test func sendToNewEaselMakesAnEaselWithThePicture() throws {
        let (model, _) = makeEaselModel()
        let pageID = try #require(model.tabs.first?.id)
        model.noteAreaCapture(fraction: CGRect(x: 0, y: 0, width: 1, height: 1), tabID: pageID)
        let png = try #require(BrowserEaselStoreTests.png())
        let tabID = try #require(model.sendCaptureToNewEasel(png: png))
        let id = try #require(model.easelID(forTabID: tabID))
        let objects = try #require(model.easelStore.document(id: id)?.objects)
        #expect(objects.count == 2)
        #expect(objects.last?.content.capture?.urlString == "https://example.com")
    }

    private func makeEaselModel(
        windowMode: BrowserWindowMode = .normal,
    ) -> (BrowserChromeModel, FakeBrowserTabDriver) {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserEaselModelTests"))!
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
                tabs: [.init(urlString: "https://example.com")],
            )),
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowMode: windowMode,
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.easelStoreOverride = BrowserEaselStore(directory: nil)
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        return (model, driver)
    }
}

// MARK: - BrowserEaselRenderTests

/// Offscreen pictures of the canvas. With OPENARC_EASEL_SNAPSHOTS set (through
/// TEST_RUNNER_OPENARC_EASEL_SNAPSHOTS) the PNGs are written to that folder.
@MainActor struct BrowserEaselRenderTests {
    private static func render(_ view: NSView) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = view.appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @Test func theCanvasDrawsShapesTextAndCapturesAtTheWindowsScale() throws {
        let store = BrowserEaselStore(directory: nil)
        var document = BrowserEaselDocument.new(id: "render", title: "Weekend Trip")
        let png = try #require(BrowserEaselStoreTests.png(color: .systemTeal, size: CGSize(width: 600, height: 300)))
        let picture = store.addImage(png, toEaselID: "render")
        document.objects += [
            BrowserEaselObject(
                id: "rect",
                frame: CGRect(x: 100, y: 160, width: 250, height: 180),
                content: .shape(BrowserEaselShape(kind: .rectangle, color: .lightGreen)),
            ),
            BrowserEaselObject(
                id: "circle",
                frame: CGRect(x: 420, y: 160, width: 180, height: 180),
                content: .shape(BrowserEaselShape(kind: .circle, color: .red)),
            ),
            BrowserEaselObject(
                frame: CGRect(x: 100, y: 400, width: 250, height: 120),
                content: .shape(BrowserEaselShape(
                    kind: .arrow,
                    color: .lightBlue,
                    arrowStart: CGPoint(x: 0, y: 0),
                    arrowEnd: CGPoint(x: 1, y: 1),
                )),
            ),
            BrowserEaselObject(
                frame: CGRect(x: 420, y: 400, width: 250, height: 120),
                content: .shape(BrowserEaselShape(
                    kind: .freehand,
                    color: .black,
                    points: [
                        CGPoint(x: 0, y: 0),
                        CGPoint(x: 0.3, y: 1),
                        CGPoint(x: 0.6, y: 0.2),
                        CGPoint(x: 1, y: 0.8),
                    ],
                )),
            ),
            BrowserEaselObject(
                frame: CGRect(x: 100, y: 560, width: 300, height: 30),
                content: .text(BrowserEaselText(string: "Pack the tent")),
            ),
            BrowserEaselObject(
                frame: CGRect(x: 650, y: 560, width: 300, height: 150),
                content: .capture(BrowserEaselCapture(
                    fileName: picture,
                    urlString: "https://example.com",
                    title: "Example",
                    region: CGRect(x: 0, y: 0, width: 1, height: 1),
                    isLive: true,
                    capturedAt: Date(),
                )),
            ),
        ]
        store.save(document)
        let directory = ProcessInfo.processInfo.environment["OPENARC_EASEL_SNAPSHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = BrowserEaselView(easelID: "render", store: store)
            view.frame = CGRect(x: 0, y: 0, width: 1000, height: 760)
            view.appearance = NSAppearance(named: appearance)
            view.editor?.selectedObjectID = "rect"
            let rep = try #require(Self.render(view))
            #expect(rep.pixelsWide == 1000 * Int(rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1))
            let ratio = CGFloat(rep.pixelsWide) / rep.size.width
            func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                try #require(rep.colorAt(x: Int(x * ratio), y: Int(y * ratio))?.usingColorSpace(.sRGB))
            }
            let background = try color(980, 60)
            let isDark = name == "dark"
            #expect(abs(background.redComponent - (isDark ? 14 : 254) / 255) < 0.03, "\(name) canvas")
            // A rectangle fills with 75 % of its color over the canvas.
            let fill = try color(225, 250)
            #expect(fill.greenComponent > fill.redComponent + 0.2, "\(name) rectangle is green")
            let circle = try color(510, 250)
            #expect(circle.redComponent > circle.greenComponent + 0.3, "\(name) circle is red")
            let toolbar = try color(14, 760 - 34)
            #expect(isDark ? toolbar.redComponent < 0.2 : toolbar.redComponent > 0.8, "\(name) toolbar")
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("easel-\(name).png"))
            }
        }
        let export = try #require(BrowserEaselRenderer.image(document, pixelWidth: 800, isDark: false, store: store))
        #expect(export.pixelsWide == 800)
        #expect(export.pixelsHigh == Int(ceil((document.contentBottom + 40) * 0.8)))
        #expect(BrowserEaselRenderer.thumbnail(document, store: store, isDark: false)?.size.width == 100)
    }

    @Test func anEaselWithoutItsDrawingSaysSo() {
        let view = BrowserEaselView(easelID: "elsewhere", store: BrowserEaselStore(directory: nil))
        #expect(view.editor == nil)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let labels = descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
        #expect(labels.map(\.stringValue) == [BrowserStrings.easelMissing])
    }
}
