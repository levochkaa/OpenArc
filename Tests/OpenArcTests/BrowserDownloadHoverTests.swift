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
}
