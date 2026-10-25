// BrowserMobileDownloadClearTests.swift

import Foundation
import Synchronization
import Testing

// MARK: - BrowserMobileDownloadClearTests

@MainActor struct BrowserMobileDownloadClearTests {
    @Test func capturedBatchPreservesLaterCompletionsAndReservesEveryMemberBeforeAwait() async throws {
        let f = DownloadClearFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let missing = try await f.seed("missing.txt")
        try FileManager.default.removeItem(at: f.url(missing))
        let controlled = HeldClearDisk(base: f.disk)
        let downloads = BrowserMobileDownloads(disk: controlled)
        await downloads.load()
        let scope = try #require(downloads.captureCompletedClear())
        #expect(scope.ids == [first.id, missing.id] && scope.count == 2)
        let later = try await f.seed("after-confirmation.txt")
        await downloads.load()

        await controlled.holdNextClear()
        let clearing = Task { await downloads.clearCompleted(scope) }
        try await clearWait { await controlled.isClearHeld }
        #expect(downloads.isClearingCompleted && !downloads.canClearCompleted)
        #expect(downloads.isDeleting(id: first.id) && downloads.isDeleting(id: missing.id))
        #expect(!downloads.canDelete(id: first.id) && downloads.canDelete(id: later.id))
        #expect(await downloads.clearCompleted(scope) == .busy)
        #expect(await !downloads.remove(id: first.id))
        await #expect(throws: BrowserMobileDownloadError.busy) { try await downloads.acquireExport(id: first.id) }
        let lateLease = try await downloads.acquireExport(id: later.id)
        let duringAwait = try await f.seed("during-await.txt")
        let beforeCommit = f.faults.writeCount
        await controlled.releaseClear()
        #expect(await clearing.value == .removed)
        #expect(f.faults.writeCount == beforeCommit + 1)
        #expect(Set(downloads.entries.map(\.id)) == [later.id, duringAwait.id])
        #expect(!downloads.isClearingCompleted && downloads.error == nil)
        #expect(try Data(contentsOf: lateLease.url) == Data(later.filename.utf8))
        lateLease.finish()
        #expect(await downloads.clearCompleted(scope) == .removed)
        #expect(f.faults.writeCount == beforeCommit + 1)
        let reopened = BrowserMobileDownloads(directory: f.directory)
        await reopened.load()
        #expect(Set(reopened.entries.map(\.id)) == [later.id, duringAwait.id])
    }

    @Test func failedBatchRetainsOneExactRetryAndNeverBecomesIndividualDeletes() async throws {
        let f = DownloadClearFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let second = try await f.seed("second.txt")
        let downloads = BrowserMobileDownloads(disk: f.disk)
        await downloads.load()
        let scope = try #require(downloads.captureCompletedClear())
        let originalManifest = try Data(contentsOf: f.manifest)
        f.faults.failWrites(true)
        let beforeFailure = f.faults.writeCount
        #expect(await downloads.clearCompleted(scope) == .failed)
        #expect(f.faults.writeCount == beforeFailure + 1)
        #expect(try Data(contentsOf: f.manifest) == originalManifest)
        #expect(Set(downloads.entries.map(\.id)) == scope.ids)
        for entry in [first, second] {
            #expect(try Data(contentsOf: f.url(entry)) == Data(entry.filename.utf8))
            #expect(!downloads.canDelete(id: entry.id))
            #expect(await !downloads.remove(id: entry.id))
            await #expect(throws: BrowserMobileDownloadError.busy) { try await downloads.acquireExport(id: entry.id) }
        }
        #expect(downloads.canRetryPersistence && downloads.error != nil && !downloads.isClearingCompleted)
        #expect(downloads.captureCompletedClear() == nil)
        #expect(await downloads.clearCompleted(scope) == .busy)
        let reopenedBeforeRetry = BrowserMobileDownloads(directory: f.directory)
        await reopenedBeforeRetry.load()
        #expect(Set(reopenedBeforeRetry.entries.map(\.id)) == scope.ids)
        #expect(!reopenedBeforeRetry.canRetryPersistence)

        f.faults.failWrites(false)
        let later = try await f.seed("later.txt")
        let unrelated = try await f.seed("unrelated.txt")
        await downloads.load()
        let lease = try await downloads.acquireExport(id: later.id)
        #expect(await downloads.remove(id: unrelated.id))
        let beforeRetry = f.faults.writeCount
        await downloads.retryPersistence()
        #expect(f.faults.writeCount == beforeRetry + 1)
        #expect(downloads.entries.map(\.id) == [later.id])
        #expect(!downloads.canRetryPersistence && downloads.error == nil)
        #expect(try Data(contentsOf: lease.url) == Data(later.filename.utf8))
        lease.finish()
        let final = BrowserMobileDownloads(directory: f.directory)
        await final.load()
        #expect(final.entries.map(\.id) == [later.id])
    }

    @Test func anyExportRejectsWholeBatchWithoutQueuingAnIntent() async throws {
        let f = DownloadClearFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let second = try await f.seed("second.txt")
        let downloads = BrowserMobileDownloads(disk: f.disk)
        await downloads.load()
        let firstLease = try await downloads.acquireExport(id: first.id)
        let secondLease = try await downloads.acquireExport(id: first.id)
        let scope = try #require(downloads.captureCompletedClear())
        #expect(scope.ids == [first.id, second.id])
        let before = f.faults.writeCount
        #expect(await downloads.clearCompleted(scope) == .busy)
        firstLease.finish()
        #expect(await downloads.clearCompleted(scope) == .busy)
        secondLease.finish()
        await downloads.retryPersistence()
        #expect(!downloads.canRetryPersistence && downloads.error == nil)
        #expect(f.faults.writeCount == before)
        #expect(Set(downloads.entries.map(\.id)) == scope.ids)
        #expect(await downloads.clearCompleted(scope) == .removed)
        #expect(downloads.entries.isEmpty)
    }

    @Test func activeAndFailedIndividualRemovalCannotBeAbsorbedIntoClear() async throws {
        let f = DownloadClearFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let second = try await f.seed("second.txt")
        let controlled = HeldClearDisk(base: f.disk)
        let downloads = BrowserMobileDownloads(disk: controlled)
        await downloads.load()
        let scope = try #require(downloads.captureCompletedClear())
        await controlled.holdNextRemoval()
        f.faults.failWrites(true)
        let deleting = Task { await downloads.remove(id: first.id) }
        try await clearWait { await controlled.isRemovalHeld }
        #expect(await downloads.clearCompleted(scope) == .busy)
        await controlled.releaseRemoval()
        #expect(await !deleting.value)
        #expect(await downloads.clearCompleted(scope) == .busy)
        f.faults.failWrites(false)
        let before = f.faults.writeCount
        await downloads.retryPersistence()
        #expect(f.faults.writeCount == before + 1)
        #expect(downloads.entries.map(\.id) == [second.id])
        #expect(!downloads.canRetryPersistence)
        // The rejected Clear did not become a deferred batch. Its original
        // scope can later be confirmed against only the surviving record.
        #expect(await downloads.clearCompleted(scope) == .removed)
        #expect(downloads.entries.isEmpty)
    }

    @Test func scopesBelongToTheirCoordinatorAndCaptureAloneNeverChangesDisk() async throws {
        let f = DownloadClearFixture()
        defer { f.remove() }
        let entry = try await f.seed("one.txt")
        let first = BrowserMobileDownloads(disk: f.disk)
        let other = BrowserMobileDownloads(disk: f.disk)
        await first.load()
        await other.load()
        let scope = try #require(first.captureCompletedClear())
        let bytes = try Data(contentsOf: f.manifest)
        let before = f.faults.writeCount
        #expect(await other.clearCompleted(scope) == .invalidScope)
        #expect(try Data(contentsOf: f.manifest) == bytes && f.faults.writeCount == before)
        #expect(first.canDelete(id: entry.id) && other.canDelete(id: entry.id))
        let uncommittedID = UUID()
        let uncommitted = try await f.disk.prepare(id: uncommittedID, filename: "partial.txt")
        try Data("partial".utf8).write(to: uncommitted)
        #expect(first.captureCompletedClear()?.ids == [entry.id])
        #expect(await first.remove(id: entry.id))
        let afterRemove = f.faults.writeCount
        #expect(await first.clearCompleted(scope) == .removed)
        #expect(f.faults.writeCount == afterRemove)
        #expect(FileManager.default.fileExists(atPath: uncommitted.path))
        #expect(!first.canClearCompleted && first.captureCompletedClear() == nil)
    }

    @Test func lateSnapshotCannotRestoreBatchAndCleanupFailureSurvivesReopen() async throws {
        let f = DownloadClearFixture()
        defer { f.remove() }
        let first = try await f.seed("first.txt")
        let second = try await f.seed("second.txt")
        let controlled = HeldClearDisk(base: f.disk)
        let downloads = BrowserMobileDownloads(disk: controlled)
        await downloads.load()
        let scope = try #require(downloads.captureCompletedClear())
        let retained = try await f.seed("retained.txt")
        await downloads.load()
        await controlled.holdNextSnapshot()
        let staleLoad = Task { await downloads.load() }
        try await clearWait { await controlled.isSnapshotHeld }
        f.faults.failCleanup(true)
        #expect(await downloads.clearCompleted(scope) == .removed)
        #expect(downloads.entries.map(\.id) == [retained.id])
        #expect(downloads.canRetryPersistence && downloads.error != nil)
        await controlled.releaseSnapshot()
        await staleLoad.value
        #expect(downloads.entries.map(\.id) == [retained.id])
        #expect(downloads.canRetryPersistence && downloads.error != nil)

        let reopened = BrowserMobileDownloads(disk: f.makeDisk())
        await reopened.load()
        #expect(reopened.entries.map(\.id) == [retained.id])
        #expect(reopened.canRetryPersistence)
        #expect(FileManager.default.fileExists(atPath: f.url(first).path))
        #expect(FileManager.default.fileExists(atPath: f.url(second).path))
        f.faults.failCleanup(false)
        await reopened.retryPersistence()
        #expect(reopened.error == nil && !reopened.canRetryPersistence)
        #expect(!FileManager.default.fileExists(atPath: f.url(first).path))
        #expect(!FileManager.default.fileExists(atPath: f.url(second).path))
        #expect(try Data(contentsOf: f.url(retained)) == Data(retained.filename.utf8))
    }
}

// MARK: - DownloadClearFaults

private final class DownloadClearFaults: Sendable {
    // MARK: Private

    private struct State { var writesFail = false
        var cleanupFails = false
        var writeCount = 0
    }

    private let state = Mutex(State())

    // MARK: Internal

    var writeCount: Int { state.withLock { $0.writeCount } }

    func failWrites(_ value: Bool) { state.withLock { $0.writesFail = value } }
    func failCleanup(_ value: Bool) { state.withLock { $0.cleanupFails = value } }
    func write(_ data: Data, to url: URL) throws {
        let fail = state.withLock { value in value.writeCount += 1
            return value.writesFail
        }
        if fail {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL) throws {
        if state.withLock({ $0.cleanupFails }) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - DownloadClearFixture

@MainActor private final class DownloadClearFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let faults = DownloadClearFaults()
    lazy var disk = makeDisk()

    var manifest: URL { directory.appendingPathComponent("downloads.json") }

    func makeDisk() -> BrowserMobileDownloadDisk {
        BrowserMobileDownloadDisk(
            directory: directory,
            writeManifest: { [faults] in try faults.write($0, to: $1) },
            removeItem: { [faults] in try faults.remove($0) },
        )
    }

    func seed(_ filename: String) async throws -> BrowserMobileDownload {
        let entry = BrowserMobileDownload(
            id: UUID(),
            filename: filename,
            sourceURL: nil,
            status: .downloading,
            receivedBytes: 0,
            totalBytes: nil,
            error: nil,
        )
        let url = try await disk.prepare(id: entry.id, filename: filename)
        try Data(filename.utf8).write(to: url)
        return try await disk.complete(entry)
    }

    func url(_ entry: BrowserMobileDownload) -> URL {
        directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent(entry.filename)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - HeldClearDisk

private actor HeldClearDisk: BrowserMobileDownloadStoring {
    // MARK: Private

    private let base: BrowserMobileDownloadDisk
    private var holdClear = false
    private var holdRemoval = false
    private var holdSnapshot = false
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var snapshotContinuation: CheckedContinuation<BrowserMobileDownloadDiskState, Never>?
    private var heldSnapshot: BrowserMobileDownloadDiskState?

    // MARK: Internal

    var isClearHeld: Bool { clearContinuation != nil }
    var isRemovalHeld: Bool { removalContinuation != nil }
    var isSnapshotHeld: Bool { snapshotContinuation != nil }

    init(base: BrowserMobileDownloadDisk) { self.base = base }

    func holdNextClear() { holdClear = true }
    func holdNextRemoval() { holdRemoval = true }
    func holdNextSnapshot() { holdSnapshot = true }
    func releaseClear() { clearContinuation?.resume()
        clearContinuation = nil
    }

    func releaseRemoval() { removalContinuation?.resume()
        removalContinuation = nil
    }

    func releaseSnapshot() {
        if let value = heldSnapshot {
            snapshotContinuation?.resume(returning: value)
        }
        snapshotContinuation = nil
        heldSnapshot = nil
    }

    func snapshot() async throws -> BrowserMobileDownloadDiskState {
        let value = try await base.snapshot()
        guard holdSnapshot else { return value }
        holdSnapshot = false
        heldSnapshot = value
        return await withCheckedContinuation { snapshotContinuation = $0 }
    }

    func removeState(ids: Set<UUID>) async throws -> BrowserMobileDownloadDiskState {
        if holdClear {
            holdClear = false
            await withCheckedContinuation { clearContinuation = $0 }
        }
        return try await base.removeState(ids: ids)
    }

    func removeState(id: UUID) async throws -> BrowserMobileDownloadDiskState {
        if holdRemoval {
            holdRemoval = false
            await withCheckedContinuation { removalContinuation = $0 }
        }
        return try await base.removeState(id: id)
    }

    func prepare(id: UUID, filename: String) async throws -> URL { try await base.prepare(id: id, filename: filename) }
    func completeState(_ entry: BrowserMobileDownload) async throws -> BrowserMobileDownloadDiskState {
        try await base.completeState(entry)
    }

    func retryCleanup() async throws -> BrowserMobileDownloadDiskState { try await base.retryCleanup() }
    func exportURL(id: UUID) async throws -> URL { try await base.exportURL(id: id) }
    func discardState(id: UUID) async throws -> BrowserMobileDownloadDiskState { try await base.discardState(id: id) }
}

@MainActor private func clearWait(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The held disk operation did not arrive")
    throw URLError(.timedOut)
}
