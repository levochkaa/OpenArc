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
}
