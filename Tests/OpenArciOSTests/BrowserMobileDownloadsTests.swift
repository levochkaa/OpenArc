// BrowserMobileDownloadsTests.swift

import Foundation
import Testing

// MARK: - BrowserMobileDownloadsTests

@MainActor struct BrowserMobileDownloadsTests {
    @Test func generatedProvenanceNeverLeaksThroughTheOriginalRequestFallback() throws {
        let page = try #require(URL(string: "https://example.com/source"))
        let request = try #require(URL(string: "https://example.com/attachment"))
        let blank = try #require(URL(string: "about:blank"))
        for raw in [
            "blob:https://example.com/private-token",
            "data:application/octet-stream;base64,c2VjcmV0",
            "file:///private/download",
            "javascript:alert(1)",
        ] {
            let generated = try #require(URL(string: raw))
            #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: nil, requestURL: generated) == nil)
            #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: generated, requestURL: nil) == nil)
            #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: generated, requestURL: generated) == nil)
            #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: page, requestURL: generated) == page)
            #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: generated, requestURL: request) == request)
        }
        #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: nil, requestURL: request) == request)
        #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: blank, requestURL: request) == blank)
        #expect(BrowserMobileDownloads.persistentSourceURL(sourceURL: nil, requestURL: nil) == nil)
    }

    @Test func completedFilesReopenWithUniqueSafeDestinationsAndExactBytes() async throws {
        let f = DownloadDiskFixture()
        defer { f.remove() }
        let disk = BrowserMobileDownloadDisk(directory: f.directory)
        let filename = BrowserMobileDownloadDisk.safeFilename("../../private\\report.txt")
        #expect(filename == "report.txt")
        let first = f.entry(filename: filename)
        let second = f.entry(filename: filename)
        let firstURL = try await disk.prepare(id: first.id, filename: filename)
        let secondURL = try await disk.prepare(id: second.id, filename: filename)
        #expect(firstURL != secondURL)
        #expect(firstURL.deletingLastPathComponent().lastPathComponent == first.id.uuidString)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        try Data("first file".utf8).write(to: firstURL)
        try Data("second file".utf8).write(to: secondURL)
        let savedFirst = try await disk.complete(first)
        let savedSecond = try await disk.complete(second)
        #expect(savedFirst.status == .completed && savedFirst.receivedBytes == 10 && savedFirst.totalBytes == 10)
        #expect(savedSecond.status == .completed && savedSecond.receivedBytes == 11)
        #expect(try await disk.complete(first) == savedFirst)
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(reopened.error == nil && !reopened.isLoading && !reopened.canRetryPersistence)
        #expect(reopened.entries == [savedSecond, savedFirst])
        let exported = try await reopened.exportURL(id: first.id)
        #expect(try Data(contentsOf: exported) == Data("first file".utf8))
        let exportedSecond = try await reopened.exportURL(id: second.id)
        #expect(try Data(contentsOf: exportedSecond) == Data("second file".utf8))
    }

    @Test func failedManifestCommitRetainsFileAndRetriesExactlyOnce() async throws {
        let f = DownloadDiskFixture()
        defer { f.remove() }
        let disk = BrowserMobileDownloadDisk(directory: f.directory)
        let entry = f.entry()
        let file = try await disk.prepare(id: entry.id, filename: entry.filename)
        let bytes = Data("downloaded while disk metadata is blocked".utf8)
        try bytes.write(to: file)
        // A directory at the manifest path deterministically rejects atomic
        // replacement, without relying on simulator filesystem permissions.
        try FileManager.default.createDirectory(at: f.manifest, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await disk.complete(entry) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try await disk.load().isEmpty)
        await #expect(throws: BrowserMobileDownloadError.notCompleted) { try await disk.exportURL(id: entry.id) }
        try FileManager.default.removeItem(at: f.manifest)
        let saved = try await disk.complete(entry)
        #expect(try await disk.complete(entry) == saved)
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(reopened.entries == [saved])
        #expect(try await Data(contentsOf: reopened.exportURL(id: entry.id)) == bytes)
    }

    @Test func malformedManifestFailsClosedAndRetryRecoversAfterRepair() async throws {
        let f = DownloadDiskFixture()
        defer { f.remove() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let orphan = f.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let orphanFile = orphan.appendingPathComponent("keep.txt")
        try Data("keep until manifest is valid".utf8).write(to: orphanFile)
        let corrupt = Data("{\"version\":999,\"entries\":[]}".utf8)
        try corrupt.write(to: f.manifest)
        let downloads = BrowserMobileDownloads(directory: f.directory)
        var observations = 0
        let token = downloads.observe { observations += 1 }
        await downloads.load()
        #expect(downloads.entries.isEmpty && downloads.error != nil && downloads.canRetryPersistence)
        #expect(observations >= 2)
        #expect(try Data(contentsOf: f.manifest) == corrupt)
        #expect(FileManager.default.fileExists(atPath: orphanFile.path))
        let disk = BrowserMobileDownloadDisk(directory: f.directory)
        await #expect(throws: BrowserMobileDownloadError.invalidManifest) {
            try await disk.prepare(id: UUID(), filename: "new.txt")
        }
        #expect(try Data(contentsOf: f.manifest) == corrupt)
        try Data("{\"version\":1,\"entries\":[]}".utf8).write(to: f.manifest, options: .atomic)
        await downloads.retryPersistence()
        #expect(downloads.error == nil && downloads.entries.isEmpty && !downloads.canRetryPersistence)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        downloads.removeObserver(token)
        let calls = observations
        await downloads.load()
        #expect(observations == calls)
    }

    @Test func missingOrSymlinkedCompletedFileCannotBeExported() async throws {
        let f = DownloadDiskFixture()
        defer { f.remove() }
        let disk = BrowserMobileDownloadDisk(directory: f.directory)
        let entry = f.entry()
        let file = try await disk.prepare(id: entry.id, filename: entry.filename)
        try Data("original".utf8).write(to: file)
        _ = try await disk.complete(entry)
        try FileManager.default.removeItem(at: file)
        let missing = BrowserMobileDownloads(directory: f.directory)
        await missing.load()
        #expect(missing.entries.first?.status == .failed && missing.entries.first?.error != nil)
        await #expect(throws: BrowserMobileDownloadError.notCompleted) { try await missing.exportURL(id: entry.id) }
        let external = f.directory.appendingPathComponent("outside.txt")
        try Data("must not be shared as the download".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        await #expect(throws: BrowserMobileDownloadError.missingFile) { try await disk.exportURL(id: entry.id) }
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(reopened.entries.first?.status == .failed)
    }

    @Test func interruptedFilesAreRemovedWithoutTouchingCompletedOrUnrelatedFiles() async throws {
        let f = DownloadDiskFixture()
        defer { f.remove() }
        let disk = BrowserMobileDownloadDisk(directory: f.directory)
        let complete = f.entry()
        let savedFile = try await disk.prepare(id: complete.id, filename: complete.filename)
        try Data("saved".utf8).write(to: savedFile)
        _ = try await disk.complete(complete)
        let interrupted = f.entry()
        let partialFile = try await disk.prepare(id: interrupted.id, filename: interrupted.filename)
        try Data("partial".utf8).write(to: partialFile)
        let unrelated = f.directory.appendingPathComponent("unrelated.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        let reopened = BrowserMobileDownloadDisk(directory: f.directory)
        #expect(try await reopened.load().map(\.id) == [complete.id])
        #expect(!FileManager.default.fileExists(atPath: partialFile.path))
        #expect(FileManager.default.fileExists(atPath: savedFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        try await reopened.discard(id: complete.id)
        #expect(FileManager.default.fileExists(atPath: savedFile.path))
    }

    @Test func filenameSanitizationAndDuplicateDestinationCannotEscapeOrOverwrite() async throws {
        let f = DownloadDiskFixture()
        defer { f.remove() }
        #expect(BrowserMobileDownloadDisk.safeFilename("../../") == "Download")
        #expect(BrowserMobileDownloadDisk.safeFilename(" ..:\u{0} \n") == "Download")
        let long = BrowserMobileDownloadDisk.safeFilename(String(repeating: "😀", count: 100))
        #expect(long.utf8.count <= 200 && !long.isEmpty)
        let disk = BrowserMobileDownloadDisk(directory: f.directory)
        let entry = f.entry()
        let destination = try await disk.prepare(id: entry.id, filename: entry.filename)
        let bytes = Data("never overwrite".utf8)
        try bytes.write(to: destination)
        await #expect(throws: BrowserMobileDownloadError.invalidDestination) {
            try await disk.prepare(id: entry.id, filename: entry.filename)
        }
        await #expect(throws: BrowserMobileDownloadError.invalidDestination) {
            try await disk.prepare(id: UUID(), filename: "../escape")
        }
        #expect(try Data(contentsOf: destination) == bytes)
        try await disk.discard(id: entry.id)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

// MARK: - DownloadDiskFixture

private struct DownloadDiskFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileDownloads-\(UUID())")

    var manifest: URL { directory.appendingPathComponent("downloads.json") }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func entry(filename: String = "file.txt") -> BrowserMobileDownload {
        .init(
            id: UUID(), filename: filename, sourceURL: URL(string: "https://example.com/file"),
            status: .downloading, receivedBytes: 0, totalBytes: nil, error: nil,
        )
    }
}
