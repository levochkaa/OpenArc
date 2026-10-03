import Foundation
import Synchronization
import Testing

// MARK: - BrowserMobileDownloadDeletionTests

@MainActor struct BrowserMobileDownloadDeletionTests {
    @Test func failedDeletePreservesExactManifestAndRetryUsesLatestCompletedRecords() async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt", bytes: Data("first".utf8))
        let second = try await f.seed("second.txt", bytes: Data("second".utf8))
        let downloads = BrowserMobileDownloads(disk: f.disk)
        await downloads.load()
        let original = try Data(contentsOf: f.manifest)
        f.faults.failWrites(true)
        #expect(await !(downloads.remove(id: first.id)))
        #expect(downloads.canRetryPersistence && downloads.error != nil && !downloads.isDeleting(id: first.id))
        #expect(Set(downloads.entries.map(\.id)) == [first.id, second.id])
        #expect(try Data(contentsOf: f.manifest) == original)
        #expect(try Data(contentsOf: f.url(first)) == Data("first".utf8))
        await #expect(throws: BrowserMobileDownloadError.busy) { try await downloads.acquireExport(id: first.id) }
        let beforeRetry = BrowserMobileDownloads(directory: f.directory)
        await beforeRetry.load()
        #expect(Set(beforeRetry.entries.map(\.id)) == [first.id, second.id])

        f.faults.failWrites(false)
        let later = try await f.seed("later.txt", bytes: Data("later completion".utf8))
        await downloads.retryPersistence()
        #expect(Set(downloads.entries.map(\.id)) == [second.id, later.id])
        #expect(downloads.error == nil && !downloads.canRetryPersistence)
        #expect(!FileManager.default.fileExists(atPath: f.url(first).path))
        #expect(await downloads.remove(id: first.id))
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(Set(reopened.entries.map(\.id)) == [second.id, later.id])
        let saved = try await reopened.exportURL(id: later.id)
        #expect(try Data(contentsOf: saved) == Data("later completion".utf8))
    }

    @Test func committedDeleteAndInterruptedCleanupFailuresRemainRecoverableAfterReopen() async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let removed = try await f.seed("removed.txt")
        let retained = try await f.seed("retained.txt")
        let downloads = BrowserMobileDownloads(disk: f.disk)
        await downloads.load()
        f.faults.failCleanup(true)
        #expect(await downloads.remove(id: removed.id))
        #expect(downloads.entries.map(\.id) == [retained.id])
        #expect(downloads.canRetryPersistence && downloads.error != nil)
        #expect(FileManager.default.fileExists(atPath: f.url(removed).path))
        let orphanID = UUID()
        let orphan = f.directory.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data("interrupted".utf8).write(to: orphan.appendingPathComponent("partial"))

        let reopenedDisk = f.makeDisk()
        let reopened = BrowserMobileDownloads(disk: reopenedDisk)
        await reopened.load()
        #expect(reopened.entries.map(\.id) == [retained.id])
        #expect(reopened.error != nil && reopened.canRetryPersistence)
        #expect(reopened.canDelete(id: retained.id))
        let state = try await reopenedDisk.snapshot()
        #expect(state.pendingCleanupIDs == [removed.id, orphanID])
        let exported = try await reopened.exportURL(id: retained.id)
        #expect(try Data(contentsOf: exported) == Data("fixture".utf8))
        f.faults.failCleanup(false)
        await reopened.retryPersistence()
        #expect(reopened.error == nil && !reopened.canRetryPersistence)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: f.url(removed).path))
        #expect(FileManager.default.fileExists(atPath: f.url(retained).path))
    }

    @Test(arguments: [false, true])
    func unavailableDurableFileCanBeDeletedWithoutFollowingItsSymlink(symlink: Bool) async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let entry = try await f.seed("gone.txt")
        try FileManager.default.removeItem(at: f.url(entry))
        let outside = f.directory.appendingPathComponent("unrelated.txt")
        let untouched = Data("not this download".utf8)
        try untouched.write(to: outside)
        if symlink {
            try FileManager.default.createSymbolicLink(at: f.url(entry), withDestinationURL: outside)
        }
        let downloads = BrowserMobileDownloads(disk: f.disk)
        await downloads.load()
        #expect(downloads.entries.first?.status == .failed && downloads.canDelete(id: entry.id))
        await #expect(throws: BrowserMobileDownloadError.notCompleted) {
            try await downloads.acquireExport(id: entry.id)
        }
        #expect(await downloads.remove(id: entry.id))
        #expect(downloads.entries.isEmpty)
        #expect(try Data(contentsOf: outside) == untouched)
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(reopened.entries.isEmpty && reopened.error == nil)
    }

    @Test func independentExportLeasesBlockOnlyTheirOwnDownloadAndBusyDeleteNeverQueues() async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let other = try await f.seed("other.txt")
        let downloads = BrowserMobileDownloads(disk: f.disk)
        await downloads.load()
        let firstLease = try await downloads.acquireExport(id: first.id)
        var secondLease: BrowserMobileDownloadExportLease? = try await downloads.acquireExport(id: first.id)
        #expect(firstLease.downloadID == first.id && secondLease?.url == firstLease.url)
        #expect(!downloads.canDelete(id: first.id) && downloads.canDelete(id: other.id))
        #expect(await !(downloads.remove(id: first.id)))
        #expect(!downloads.canRetryPersistence && downloads.error == nil)
        #expect(await downloads.remove(id: other.id))
        firstLease.finish()
        firstLease.finish()
        #expect(!downloads.canDelete(id: first.id))
        secondLease = nil
        #expect(downloads.canDelete(id: first.id))
        await downloads.retryPersistence()
        #expect(downloads.entries.map(\.id) == [first.id])
        #expect(try Data(contentsOf: firstLease.url) == Data("fixture".utf8))
    }

    @Test func exportReservesBeforeAwaitAndCancellationOrDiskFailureReleasesOnlyItsToken() async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let entry = try await f.seed("leased.txt")
        let controlled = HeldDownloadDisk(base: f.disk)
        let downloads = BrowserMobileDownloads(disk: controlled)
        await downloads.load()
        let retainedLease = try await downloads.acquireExport(id: entry.id)
        await controlled.holdNextExport()
        let pending = Task { try await downloads.acquireExport(id: entry.id) }
        try await deletionWait { await controlled.isExportHeld }
        #expect(!downloads.canDelete(id: entry.id))
        #expect(await !(downloads.remove(id: entry.id)))
        pending.cancel()
        await controlled.releaseExport()
        do { _ = try await pending.value
            Issue.record("Cancelled export must not publish a lease")
        } catch { #expect(error is CancellationError) }
        #expect(!downloads.canDelete(id: entry.id))
        retainedLease.finish()
        #expect(downloads.canDelete(id: entry.id))
        try FileManager.default.removeItem(at: f.url(entry))
        await #expect(throws: (any Error).self) { try await downloads.acquireExport(id: entry.id) }
        #expect(downloads.canDelete(id: entry.id))
        await downloads.retryPersistence()
        #expect(downloads.entries.map(\.id) == [entry.id])
    }

    @Test func olderFailedDiscardCannotRestoreCleanupErrorAfterNewerSuccessfulRetry() async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let retained = try await f.seed("retained.txt", bytes: Data("retained bytes".utf8))
        let controlled = HeldDownloadDisk(base: f.disk)
        let downloads = BrowserMobileDownloads(disk: controlled)
        await downloads.load()
        let partialID = UUID()
        let partial = try await f.disk.prepare(id: partialID, filename: "partial.txt")
        try Data("partial bytes".utf8).write(to: partial)

        f.faults.failCleanup(true)
        await controlled.holdNextDiscard()
        let oldCleanup = Task { await downloads.discardIncompleteDownload(id: partialID) }
        try await deletionWait { await controlled.isDiscardHeld }
        f.faults.failCleanup(false)
        await downloads.retryPersistence()
        #expect(downloads.error == nil && !downloads.canRetryPersistence)
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        await controlled.releaseDiscard()
        await oldCleanup.value
        #expect(downloads.error == nil && !downloads.canRetryPersistence)
        #expect(downloads.entries.map(\.id) == [retained.id])
        #expect(try Data(contentsOf: f.url(retained)) == Data("retained bytes".utf8))
    }

    @Test func olderLoadCannotResurrectCommittedRemovalAndConcurrentDeleteCannotAdmitExport() async throws {
        let f = DownloadDeletionFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let second = try await f.seed("second.txt")
        let controlled = HeldDownloadDisk(base: f.disk)
        let downloads = BrowserMobileDownloads(disk: controlled)
        await downloads.load()
        await controlled.holdNextSnapshot()
        let olderLoad = Task { await downloads.load() }
        try await deletionWait { await controlled.isSnapshotHeld }
        #expect(await downloads.remove(id: first.id))
        #expect(downloads.entries.map(\.id) == [second.id])
        await controlled.releaseSnapshot()
        await olderLoad.value
        #expect(downloads.entries.map(\.id) == [second.id])

        await controlled.holdNextRemoval()
        let deletion = Task { await downloads.remove(id: second.id) }
        try await deletionWait { await controlled.isRemovalHeld }
        #expect(downloads.isDeleting(id: second.id) && !downloads.canDelete(id: second.id))
        #expect(await !(downloads.remove(id: second.id)))
        await #expect(throws: BrowserMobileDownloadError.busy) { try await downloads.acquireExport(id: second.id) }
        await controlled.releaseRemoval()
        #expect(await deletion.value)
        #expect(downloads.entries.isEmpty && !downloads.canRetryPersistence)
        #expect(await downloads.remove(id: second.id))
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(reopened.entries.isEmpty)
    }
}

// MARK: - DownloadDeletionFaults

private final class DownloadDeletionFaults: Sendable {
    // MARK: Internal

    func failWrites(_ value: Bool) { flags.withLock { $0.writes = value } }
    func failCleanup(_ value: Bool) { flags.withLock { $0.cleanup = value } }
    func write(_ data: Data, to url: URL) throws {
        if flags.withLock({ $0.writes }) {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL) throws {
        if flags.withLock({ $0.cleanup }) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Private

    private struct Flags { var writes = false
        var cleanup = false
    }

    private let flags = Mutex(Flags())
}

// MARK: - DownloadDeletionFixture

@MainActor private final class DownloadDeletionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadDeletion-\(UUID())")
    let faults = DownloadDeletionFaults()
    lazy var disk = makeDisk()

    var manifest: URL { directory.appendingPathComponent("downloads.json") }

    func makeDisk() -> BrowserMobileDownloadDisk {
        BrowserMobileDownloadDisk(
            directory: directory,
            writeManifest: { [faults] in try faults.write($0, to: $1) },
            removeItem: { [faults] in try faults.remove($0) }
        )
    }

    func seed(_ filename: String, bytes: Data = Data("fixture".utf8)) async throws -> BrowserMobileDownload {
        let entry = BrowserMobileDownload(
            id: UUID(),
            filename: filename,
            sourceURL: nil,
            status: .downloading,
            receivedBytes: 0,
            totalBytes: nil,
            error: nil
        )
        let destination = try await disk.prepare(id: entry.id, filename: filename)
        try bytes.write(to: destination)
        return try await disk.complete(entry)
    }

    func url(_ entry: BrowserMobileDownload) -> URL {
        directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent(entry.filename)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - HeldDownloadDisk

private actor HeldDownloadDisk: BrowserMobileDownloadStoring {
    // MARK: Lifecycle

    init(base: BrowserMobileDownloadDisk) { self.base = base }

    // MARK: Internal

    var isSnapshotHeld: Bool { snapshotContinuation != nil }
    var isExportHeld: Bool { exportContinuation != nil }
    var isRemovalHeld: Bool { removalContinuation != nil }
    var isDiscardHeld: Bool { discardContinuation != nil }

    func holdNextSnapshot() { shouldHoldSnapshot = true }
    func holdNextExport() { shouldHoldExport = true }
    func holdNextRemoval() { shouldHoldRemoval = true }
    func holdNextDiscard() { shouldHoldDiscard = true }
    func snapshot() async throws -> BrowserMobileDownloadDiskState {
        let value = try await base.snapshot()
        guard shouldHoldSnapshot else { return value }
        shouldHoldSnapshot = false
        heldSnapshot = value
        return await withCheckedContinuation { snapshotContinuation = $0 }
    }

    func releaseSnapshot() {
        if let continuation = snapshotContinuation, let value = heldSnapshot {
            snapshotContinuation = nil
            heldSnapshot = nil
            continuation.resume(returning: value)
        }
    }

    func exportURL(id: UUID) async throws -> URL {
        let url = try await base.exportURL(id: id)
        guard shouldHoldExport else { return url }
        shouldHoldExport = false
        heldURL = url
        return await withCheckedContinuation { exportContinuation = $0 }
    }

    func releaseExport() {
        if let continuation = exportContinuation, let url = heldURL {
            exportContinuation = nil
            heldURL = nil
            continuation.resume(returning: url)
        }
    }

    func prepare(id: UUID, filename: String) async throws -> URL { try await base.prepare(id: id, filename: filename) }
    func completeState(_ entry: BrowserMobileDownload) async throws -> BrowserMobileDownloadDiskState {
        try await base.completeState(entry)
    }

    func removeState(id: UUID) async throws -> BrowserMobileDownloadDiskState {
        if shouldHoldRemoval {
            shouldHoldRemoval = false
            await withCheckedContinuation { removalContinuation = $0 }
        }
        return try await base.removeState(id: id)
    }

    func releaseRemoval() { removalContinuation?.resume()
        removalContinuation = nil
    }

    func retryCleanup() async throws -> BrowserMobileDownloadDiskState { try await base.retryCleanup() }
    func discardState(id: UUID) async throws -> BrowserMobileDownloadDiskState {
        let value = try await base.discardState(id: id)
        guard shouldHoldDiscard else { return value }
        shouldHoldDiscard = false
        heldDiscard = value
        return await withCheckedContinuation { discardContinuation = $0 }
    }

    func releaseDiscard() {
        if let continuation = discardContinuation, let value = heldDiscard {
            discardContinuation = nil
            heldDiscard = nil
            continuation.resume(returning: value)
        }
    }

    // MARK: Private

    private let base: BrowserMobileDownloadDisk
    private var shouldHoldSnapshot = false
    private var shouldHoldExport = false
    private var shouldHoldRemoval = false
    private var shouldHoldDiscard = false
    private var snapshotContinuation: CheckedContinuation<BrowserMobileDownloadDiskState, Never>?
    private var heldSnapshot: BrowserMobileDownloadDiskState?
    private var exportContinuation: CheckedContinuation<URL, Never>?
    private var heldURL: URL?
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var discardContinuation: CheckedContinuation<BrowserMobileDownloadDiskState, Never>?
    private var heldDiscard: BrowserMobileDownloadDiskState?
}

@MainActor private func deletionWait(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The held disk operation did not arrive")
    throw URLError(.timedOut)
}
