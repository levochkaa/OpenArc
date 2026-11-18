// BrowserDownloadHoverTests.swift

import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserDownloadHoverTests {
    // MARK: Internal

    @Test func theFlownBadgeNeverTakesThePointerFromTheArchiveButton() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("report.pdf", in: folder)
        let view = BrowserDownloadFlightView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let center = CGPoint(x: 40, y: 560)
        view.launch(from: CGPoint(x: 300, y: 200), toBinCenter: center, tint: .white) { .completed(file) }
        #expect(view.hitTest(center) == nil, "The archive button under it still gets hover and clicks")
        #expect(view.hitTest(CGPoint(x: 300, y: 200)) == nil)
    }

    @Test func theLibraryButtonsTooltipSitsBesideIt() {
        let origin = BrowserTooltipPlacementResolver.topLeft(
            sourceFrame: CGRect(x: 10, y: 500, width: 30, height: 30),
            tooltipSize: CGSize(width: 120, height: 26),
            containerSize: CGSize(width: 800, height: 600),
            placement: .trailingCapsule,
            verticalGap: 8,
        )
        #expect(origin == CGPoint(x: 48, y: 502), "Right of the button, on its center line, clear of the tray above")
    }

    @Test func aFlownDownloadsOutcomeFollowsItsItem() {
        func item(_ state: BrowserDownloadState, path: String?) -> BrowserDownloadItem {
            BrowserDownloadItem(
                id: "a", fileName: "a.zip", urlString: "https://example.com/a.zip", fullPath: path,
                receivedBytes: 1, totalBytes: 1, currentSpeedBytesPerSecond: 0, state: state,
                startedAt: Date(), updatedAt: Date(), finishedAt: nil,
            )
        }
        typealias Flight = BrowserDownloadFlightView
        #expect(Flight.outcome(of: item(.inProgress, path: "/tmp/a.zip")) == .running)
        #expect(Flight.outcome(of: item(.completed, path: "/tmp/a.zip")) == .completed(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(Flight.outcome(of: item(.completed, path: nil)) == .ended)
        #expect(Flight.outcome(of: item(.canceled, path: "/tmp/a.zip")) == .ended)
        #expect(Flight.outcome(of: item(.interrupted, path: "/tmp/a.zip")) == .ended)
        #expect(Flight.outcome(of: nil) == .ended, "A cleared download has nothing to show")
    }

    @Test func aTrayRowTurnsIntoItsFileWhenTheDownloadFinishes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("photo.png", in: folder)
        var canceled = false
        let tray = BrowserDownloadsTrayView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        tray.show([BrowserDownloadsTrayView.Entry(
            url: file,
            date: Date(),
            progress: "1 MB of 2 MB",
            fraction: 0.5,
            title: "photo.png",
            onCancel: { canceled = true },
        )])
        let row = try #require(tray.rows.first)
        #expect(row.showsProgress)
        #expect(!row.isFile)
        #expect(!row.cancelButton.isHidden)
        row.cancelButton.performClick(nil)
        #expect(canceled)
        tray.refresh([BrowserDownloadsTrayView.Entry(url: file, date: Date())])
        #expect(tray.rows.first === row, "The row under the pointer stays")
        #expect(!row.showsProgress)
        #expect(row.isFile)
        #expect(row.cancelButton.isHidden)
        #expect(row.tooltipTitle == "photo.png", "Hover shows the file's full name")
    }

    @Test func trayRowsAreKeptWhenTheListShiftsUnderThem() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try write("a.txt", in: folder)
        let second = try write("b.txt", in: folder)
        let tray = BrowserDownloadsTrayView(frame: NSRect(x: 0, y: 0, width: 240, height: 112))
        tray.show([BrowserDownloadsTrayView.Entry(url: first, date: Date())])
        let row = try #require(tray.rows.first)
        tray.refresh([
            BrowserDownloadsTrayView.Entry(url: first, date: Date()),
            BrowserDownloadsTrayView.Entry(url: second, date: Date()),
        ])
        #expect(tray.rows.count == 2)
        #expect(tray.rows.first === row)
        #expect(row.superview === tray)
    }

    @Test func aFinishedFilesMenusMatchWhereTheyOpen() {
        let picture = BrowserDownloadFile(url: URL(fileURLWithPath: "/tmp/sunset.png"))
        let archive = BrowserDownloadFile(url: URL(fileURLWithPath: "/tmp/archive.zip"))
        #expect(picture.isImage)
        #expect(!archive.isImage)
        #expect(picture.copyTitle == BrowserStrings.downloadsCopyImage)
        #expect(archive.copyTitle == BrowserStrings.downloadsCopyFile)
        #expect(picture.openTitle == BrowserStrings.downloadsOpenImage)
        #expect(archive.openTitle == BrowserStrings.downloadsOpen)
        #expect(BrowserDownloadFile.openInTitle(applicationName: "Preview") == BrowserStrings.downloadsOpenIn("Preview"))
        #expect(BrowserDownloadFile.openInTitle(applicationName: nil) == BrowserStrings.downloadsOpen)
        typealias Menu = BrowserDownloadFileMenu
        #expect(Menu.items(
            for: picture,
            inTray: true,
            applicationName: "Preview",
            shareTitles: ["Messages", "AirDrop"],
            canRemoveFromList: false,
        ) == [
            .copy, .separator, .share("Messages"), .share("AirDrop"), .separator,
            .openIn(BrowserStrings.downloadsOpenIn("Preview")), .showInFinder, .separator, .moveToTrash,
        ])
        #expect(Menu.items(
            for: archive,
            inTray: true,
            applicationName: "Archive Utility",
            shareTitles: [],
            canRemoveFromList: false,
        ) == [
            .copy, .separator, .openIn(BrowserStrings.downloadsOpenIn("Archive Utility")), .showInFinder,
            .separator, .moveToTrash,
        ])
        #expect(Menu.items(
            for: picture,
            inTray: false,
            applicationName: "Preview",
            shareTitles: [],
            canRemoveFromList: true,
        ) == [.open, .copy, .showInFinder, .separator, .removeFromList, .moveToTrash])
    }

    @Test func copyingAPicturePutsTheFileAndTheImageOnThePasteboard() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("dot.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("openarc-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        BrowserDownloadFileMenu.copy(BrowserDownloadFile(url: url), to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls == [url])
        #expect(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
    }

    @Test func aDraggedDownloadPromisesACopyAndOffersItsAddress() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try write("notes.txt", in: folder)
        let provider = BrowserDownloadFileDrag.provider(for: source)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("openarc-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(provider.writableTypes(for: pasteboard).contains(.fileURL))
        #expect(provider.pasteboardPropertyList(forType: .fileURL) as? String == source.absoluteString)
        let drag = BrowserDownloadFileDrag.shared
        #expect(drag.filePromiseProvider(provider, fileNameForType: provider.fileType) == "notes.txt")
        let destination = folder.appendingPathComponent("dropped.txt")
        var finished = false
        var failure: Error?
        drag.filePromiseProvider(provider, writePromiseTo: destination) {
            finished = true
            failure = $0
        }
        #expect(finished)
        #expect(failure == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.path), "The download stays where it is")
    }

    @Test func removingADownloadFromTheListKeepsTheFileAndForgetsIt() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("a.zip", in: folder)
        let historyURL = folder.appendingPathComponent("history.json")
        let model = BrowserDownloadsModel(history: BrowserDownloadHistory(fileURL: historyURL))
        model.apply(BrowserDownloadUpdate(
            id: "a", fileName: "a.zip", urlString: "https://example.com/a.zip", fullPath: file.path,
            receivedBytes: 1, totalBytes: 1, currentSpeedBytesPerSecond: 0, state: .completed,
        ))
        let item = try #require(model.items.first)
        model.remove(item)
        #expect(model.items.isEmpty)
        #expect(BrowserDownloadHistory(fileURL: historyURL).items.isEmpty, "Gone after a relaunch too")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aLibraryDownloadRowRevealsItsMoreButtonOnlyWhileHovered() throws {
        func row(isDownload: Bool) -> BrowserLibraryRow {
            var content = BrowserLibraryRowContent(
                title: "archive.zip",
                detail: "Zip Archive",
                faviconPageURL: nil,
                fileIcon: nil,
                progress: nil,
                onOpen: {},
                menu: { BrowserNativeMenus.menu() },
            )
            content.isDownload = isDownload
            let view = BrowserLibraryRow(content: content)
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 42)
            view.layoutSubtreeIfNeeded()
            return view
        }
        let download = row(isDownload: true)
        #expect(!download.isMoreButtonShown)
        #expect(download.tooltipTitle == "archive.zip")
        download.mouseEntered(with: try enterExit(.mouseEntered))
        #expect(download.isMoreButtonShown)
        download.mouseExited(with: try enterExit(.mouseExited))
        #expect(!download.isMoreButtonShown)
        let archived = row(isDownload: false)
        archived.mouseEntered(with: try enterExit(.mouseEntered))
        #expect(!archived.isMoreButtonShown, "Archived tabs keep their plain rows")
    }

    @Test func anUnfinishedLibraryDownloadsMenuOffersWhatItCan() {
        func item(_ state: BrowserDownloadState) -> BrowserDownloadItem {
            BrowserDownloadItem(
                id: "a", fileName: "a.zip", urlString: "https://example.com/a.zip", fullPath: "/tmp/a.zip",
                receivedBytes: 1, totalBytes: 2, currentSpeedBytesPerSecond: 0, state: state,
                startedAt: Date(), updatedAt: Date(), finishedAt: nil,
            )
        }
        let model = BrowserDownloadsModel()
        func titles(_ state: BrowserDownloadState) -> [String] {
            BrowserLibraryNSView.downloadMenu(for: item(state), in: model).items.map(\.title)
        }
        #expect(titles(.inProgress) == [BrowserStrings.downloadsCancelAction, BrowserStrings.libraryRevealInFinder])
        #expect(titles(.canceled) == [BrowserStrings.downloadsRemoveFromList])
        #expect(titles(.interrupted) == [BrowserStrings.downloadsRemoveFromList])
    }

    // MARK: Private

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openarc-download-hover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func enterExit(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil,
        ))
    }
}
