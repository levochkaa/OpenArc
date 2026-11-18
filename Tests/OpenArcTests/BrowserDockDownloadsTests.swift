// BrowserDockDownloadsTests.swift

import Foundation
import Testing

@Test func dockShowsHowManyDownloadsRunAndHowFarTheyAreTogether() {
    func item(_ id: String, _ received: Int64, of total: Int64, _ state: BrowserDownloadState) -> BrowserDownloadItem {
        BrowserDownloadItem(
            id: id, fileName: id, urlString: "https://example.com/\(id)", fullPath: nil,
            receivedBytes: received, totalBytes: total, currentSpeedBytesPerSecond: 0, state: state,
            startedAt: Date(), updatedAt: Date(), finishedAt: nil,
        )
    }
    let idle = BrowserDockDownloadProgress(items: [item("done", 10, of: 10, .completed)])
    #expect(idle.activeCount == 0 && idle.badgeLabel == nil, "Finished downloads leave the icon alone")

    let running = BrowserDockDownloadProgress(items: [
        item("a", 25, of: 100, .inProgress),
        item("b", 75, of: 100, .inProgress),
        item("c", 5, of: 0, .inProgress),
        item("old", 50, of: 50, .completed),
    ])
    #expect(running.badgeLabel == "3", "A download of unknown size still counts")
    #expect(running.fraction == 0.5, "Only downloads of known size make up the bar")

    let unsized = BrowserDockDownloadProgress(items: [item("c", 5, of: 0, .inProgress)])
    #expect(unsized.badgeLabel == "1" && unsized.fraction == nil)
}
