// BrowserLibraryMediaTests.swift

import AppKit
import Testing

// MARK: - BrowserLibraryMediaTests

@Suite(.serialized)
@MainActor struct BrowserLibraryMediaTests {
    @Test func mediaComesFromEveryFolderNewestFirstAndOnlyPictures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryMedia-\(UUID())")
        let downloads = root.appendingPathComponent("Downloads")
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in true }
            .tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let old = downloads.appendingPathComponent("old.png")
        let new = desktop.appendingPathComponent("new.png")
        try png.write(to: old)
        try png.write(to: new)
        try Data("text".utf8).write(to: desktop.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: old.path,
        )

        let files = BrowserLibraryNSView.mediaFiles(in: [downloads, desktop, downloads], query: "")
        #expect(
            files.map(\.lastPathComponent) == ["new.png", "old.png"],
            "Both folders, newest first, no text, no repeats",
        )
        #expect(BrowserLibraryNSView.mediaFiles(in: [downloads, desktop], query: "old")
            .map(\.lastPathComponent) == ["old.png"])
    }
}

// MARK: - BrowserLibraryDownloadRowTests

@MainActor struct BrowserLibraryDownloadRowTests {
    @Test func aFinishedDownloadNamesItsKindAndSite() {
        let detail = BrowserLibraryNSView.downloadDetail(kind: "Disk Image", urlString: "https://www.userapi.com/a.iso")
        #expect(detail == BrowserStrings.libraryDownloadKindFromHost(kind: "Disk Image", host: "userapi.com"))
        #expect(BrowserLibraryNSView.downloadDetail(kind: nil, urlString: "https://example.com/x") == "example.com")
    }

    @Test func downloadsAreGroupedByDay() {
        let now = Date()
        #expect(BrowserLibraryNSView.dayHeader(for: now) == BrowserStrings.libraryToday)
        #expect(BrowserLibraryNSView.dayHeader(for: now.addingTimeInterval(-86400)) == BrowserStrings.libraryYesterday)
    }

    @Test func archivedPagesListTheirAddressWithoutTheScheme() {
        #expect(BrowserLibraryNSView.archiveDetail(for: "https://www.example.com/") == "example.com")
        #expect(BrowserLibraryNSView
            .archiveDetail(for: "https://example.com/?ref=a") == "example.com/?ref=a")
        #expect(BrowserLibraryNSView.archiveDetail(for: "openarc://history/") == "openarc://history")
        #expect(BrowserLibraryNSView
            .archiveDetail(for: "view-source:https://example.com") == "view-source:https://example.com")
    }
}

// MARK: - BrowserDownloadsTrayTests

@MainActor struct BrowserDownloadsTrayTests {
    @Test func theTrayListsTheNewestFilesNewestLastWithoutUnfinishedOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadsTray-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.crdownload", ".hidden"]
        for (index, name) in names.enumerated() {
            let url = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)],
                ofItemAtPath: url.path,
            )
        }
        let entries = BrowserDownloadsTrayView.recentEntries(in: root)
        #expect(entries.count == BrowserDownloadsTrayView.maximumEntries)
        #expect(!entries.contains { $0.url.pathExtension == "crdownload" || $0.url.lastPathComponent.hasPrefix(".") })
        #expect(entries.map(\.date) == entries.map(\.date).sorted(), "The newest by the button, at the bottom")
    }

    @Test func aCanceledDownloadTakesItsPlaceByDateAndSaysWhereItCameFrom() {
        func entry(_ name: String, _ minute: Double, canceled: Bool = false) -> BrowserDownloadsTrayView.Entry {
            BrowserDownloadsTrayView.Entry(
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                date: Date(timeIntervalSince1970: minute * 60),
                progress: canceled ? BrowserStrings.downloadsTrayCanceled(host: "httpbin.org") : nil,
                isCanceled: canceled,
            )
        }
        let running = BrowserDownloadsTrayView.Entry(
            url: URL(fileURLWithPath: "/tmp/big.iso"),
            date: Date(timeIntervalSince1970: 0),
            progress: "1 MB of 2 MB",
        )
        let merged = BrowserDownloadsTrayView.merged(
            files: [entry("a", 1), entry("b", 3), entry("big.iso", 0)],
            canceled: [entry("2048", 2, canceled: true)],
            running: [running],
        )
        #expect(merged.map(\.url.lastPathComponent) == ["a", "2048", "b", "big.iso"])
        #expect(merged[1].isCanceled)
        #expect(merged[1].progress == BrowserStrings.downloadsTrayCanceled(host: "httpbin.org"))
        #expect(BrowserStrings.downloadsTrayCanceled(host: nil) == BrowserStrings.downloadsCanceledDetail)
    }
}

// MARK: - BrowserLibraryMediaSourceTests

@MainActor struct BrowserLibraryMediaSourceTests {
    @Test func everyFolderShowsUntilItIsTurnedOffAndTheChoiceIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: BrowserTestDefaults.suiteName("MediaSources")))
        let store = BrowserUserPreferencesStore(userDefaults: defaults)
        #expect(store.hiddenMediaSources.isEmpty, "All folders by default")
        store.hiddenMediaSources.insert(.desktop)
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).hiddenMediaSources == [.desktop])
        let custom = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(BrowserLibraryMediaSource.downloads
            .folder(downloadDirectoryPath: custom)?
            .standardizedFileURL
            .path == custom)
    }
}
