// BrowserDownloadsTests.swift

import Foundation
import Testing

@Test
@MainActor func downloadsModelMergesProgressUpdatesByID() {
    var dates = [
        Date(timeIntervalSince1970: 100),
        Date(timeIntervalSince1970: 120),
    ]
    let model = BrowserDownloadsModel(dateProvider: { dates.removeFirst() })

    model.apply(BrowserDownloadUpdate(
        id: "download-1",
        fileName: "archive.zip",
        urlString: "https://example.com/archive.zip",
        fullPath: "/Users/lev/Downloads/archive.zip",
        receivedBytes: 50,
        totalBytes: 100,
        currentSpeedBytesPerSecond: 10,
        state: .inProgress,
    ))

    #expect(model.items.count == 1)
    #expect(model.items[0].progressFraction == 0.5)
    #expect(model.hasActiveDownloads)

    model.apply(BrowserDownloadUpdate(
        id: "download-1",
        fileName: "archive.zip",
        urlString: "https://example.com/archive.zip",
        fullPath: nil,
        receivedBytes: 100,
        totalBytes: 100,
        currentSpeedBytesPerSecond: 0,
        state: .completed,
    ))

    #expect(model.items.count == 1)
    #expect(model.items[0].state == .completed)
    #expect(model.items[0].fullPath == "/Users/lev/Downloads/archive.zip")
    #expect(model.items[0].finishedAt == Date(timeIntervalSince1970: 120))
    #expect(!model.hasActiveDownloads)
}

@Test
@MainActor func clearFinishedDownloadsKeepsActiveDownloads() {
    let model = BrowserDownloadsModel(dateProvider: { Date(timeIntervalSince1970: 100) })

    model.apply(BrowserDownloadUpdate(
        id: "active",
        fileName: "active.dmg",
        urlString: "https://example.com/active.dmg",
        fullPath: "/Users/lev/Downloads/active.dmg",
        receivedBytes: 25,
        totalBytes: 100,
        currentSpeedBytesPerSecond: 5,
        state: .inProgress,
    ))
    model.apply(BrowserDownloadUpdate(
        id: "done",
        fileName: "done.dmg",
        urlString: "https://example.com/done.dmg",
        fullPath: "/Users/lev/Downloads/done.dmg",
        receivedBytes: 100,
        totalBytes: 100,
        currentSpeedBytesPerSecond: 0,
        state: .completed,
    ))

    model.clearFinishedDownloads()

    #expect(model.items.map(\.id) == ["active"])
}

@Test
@MainActor func onlyARunningDownloadCanBeCanceled() {
    let model = BrowserDownloadsModel()
    var canceled = [String]()
    model.onCancel = { canceled.append($0) }
    for (id, state) in [("running", BrowserDownloadState.inProgress), ("done", .completed)] {
        model.apply(BrowserDownloadUpdate(
            id: id,
            fileName: "\(id).zip",
            urlString: "https://example.com/\(id).zip",
            fullPath: nil,
            receivedBytes: 1,
            totalBytes: 2,
            currentSpeedBytesPerSecond: 1,
            state: state,
        ))
    }
    for item in model.items {
        model.cancel(item)
    }
    #expect(canceled == ["running"])
}
