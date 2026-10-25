// BrowserArchiveProjectionWriteTests.swift

import Foundation
import Testing

// MARK: - BrowserArchiveProjectionWriteTests

@Suite(.serialized) @MainActor struct BrowserArchiveProjectionWriteTests {
    @Test(arguments: [false, true])
    func receiptedNormalizationCannotRecreateConsumedOrClearedArchive(restoresEntry: Bool) async throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let write = try normalizedArchiveWrite(in: f)
        guard case .insert(let entry) = try #require(write.archiveAction) else {
            Issue.record("Expected an Archive insert")
            return
        }
        try f.store.writeSessionBatch([write])
        #expect(try f.store.loadArchiveEntry(id: entry.id) == entry)
        #expect(try f.operations() == [.deleteTab(id: "a")])
        let current = try #require(try f.store.loadSnapshotStrict())
        let survivor = try #require(current.tabs.first)
        var latestTabs = [BrowserTabSessionSnapshotTab(
            id: survivor.id, urlString: survivor.urlString,
            userTitleOverride: "Later survivor edit", placement: survivor.placement,
            spaceID: survivor.spaceID, lastActivityTimestamp: survivor.lastActivityTimestamp,
        )]
        if restoresEntry {
            latestTabs.append(.init(
                id: "restored-a", urlString: entry.tab.urlString,
                userTitleOverride: entry.tab.userTitleOverride, spaceID: "work",
            ))
            try f.store.writeSessionBatch([.init(
                snapshot: archiveProjectionSnapshot(current, tabs: latestTabs), origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: entry.id, tabID: "restored-a"),
            )])
        } else {
            let boundary = try await f.store.archiveClearBoundary()
            let cleared = try await f.store.clearArchive(through: boundary)
            #expect(cleared == 1)
            try f.store.writeSessionBatch([.init(
                snapshot: archiveProjectionSnapshot(current, tabs: latestTabs), origin: .local(syncMove: nil),
            )])
        }
        let later = try f.evidence()
        #expect(later.archive.isEmpty)
        let reopened = try BrowserSQLiteSessionStore(databaseURL: f.databaseURL)
        try reopened.writeSessionBatch([write])
        #expect(try f.evidence() == later)
        #expect(try reopened.loadArchivePage().entries.isEmpty)
        #expect(try reopened.loadSnapshotStrict()?.tabs.contains { $0.id == "a" } == false)
        #expect(try f.hasTombstone("a"))
    }

    @Test func normalizationRollsBackWhenItsArchivePreimageDoesNotMatch() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let valid = try normalizedArchiveWrite(in: f)
        let projection = try #require(valid.archiveProjectionSnapshot)
        let invalid = BrowserSessionWrite(
            snapshot: valid.snapshot, origin: valid.origin, archiveAction: valid.archiveAction,
            archiveProjectionSnapshot: archiveProjectionSnapshot(projection, tabs: projection.tabs.map {
                $0.id == "a" ? .init(id: "a", urlString: "https://example.com/wrong", spaceID: "work") : $0
            }),
        )
        let before = try f.evidence()
        #expect(throws: BrowserTabArchiveError.invalidTransition) {
            try f.store.writeSessionBatch([invalid])
        }
        #expect(try f.evidence() == before)
        try f.store.writeSessionBatch([valid])
        #expect(try f.store.loadSnapshotStrict() == valid.snapshot)
        #expect(try f.operations() == [.deleteTab(id: "a")])
    }

    @Test func normalizationIsRejectedForOrdinaryRestoreAndRemoteWritesBeforeTheBatchBegins() throws {
        let f = try ConfirmedCloseFixture()
        defer { f.close() }
        let valid = try normalizedArchiveWrite(in: f)
        let projection = try #require(valid.archiveProjectionSnapshot)
        let invalid: [(BrowserSessionWrite, BrowserTabArchiveError)] = [
            (.init(
                snapshot: valid.snapshot,
                origin: .local(syncMove: nil),
                archiveProjectionSnapshot: projection,
            ), .invalidTransition),
            (.init(
                snapshot: valid.snapshot,
                origin: .local(syncMove: nil),
                archiveAction: .restore(archiveID: "archive-a", tabID: "b"),
                archiveProjectionSnapshot: projection,
            ), .invalidTransition),
            (.init(
                snapshot: valid.snapshot,
                origin: .remoteProjection,
                archiveProjectionSnapshot: projection,
            ), .requiresLocalWrite),
            (.init(
                snapshot: valid.snapshot,
                origin: .remoteProjection,
                archiveAction: valid.archiveAction,
                archiveProjectionSnapshot: projection,
            ), .requiresLocalWrite),
        ]
        let before = try f.evidence()
        for (write, error) in invalid {
            #expect(throws: error) { try write.validate() }
            #expect(throws: error) { try f.store.writeSessionBatch([valid, write]) }
            #expect(try f.evidence() == before)
        }
    }

    @Test func normalizationBytesCountTowardTheSameBoundedFailureBufferAction() throws {
        let snapshot = BrowserTabSessionSnapshot(tabs: [])
        let entry = BrowserTabArchiveEntry(
            id: "archive-a", tab: .init(id: "a", urlString: "https://example.com/a"), archivedAt: 1,
        )
        let ordinary = BrowserSessionWrite(
            snapshot: snapshot,
            origin: .local(syncMove: nil),
            archiveAction: .insert(entry),
        )
        let projection = BrowserTabSessionSnapshot(tabs: [entry.tab])
        let normalized = BrowserSessionWrite(
            snapshot: snapshot, origin: ordinary.origin, archiveAction: ordinary.archiveAction,
            archiveProjectionSnapshot: projection,
        )
        let encoder = JSONEncoder()
        let originalBytes = try encoder.encode(snapshot).count + encoder.encode(BrowserTabArchiveAction.insert(entry))
            .count
        let allBytes = try originalBytes + encoder.encode(projection).count
        var ordinaryBuffer = BrowserSessionWriteBuffer(maximumBytes: originalBytes)
        let ordinaryAccepted = ordinaryBuffer.append(ordinary)
        #expect(ordinaryAccepted && ordinaryBuffer.encodedBytes == originalBytes)
        var tooSmall = BrowserSessionWriteBuffer(maximumBytes: originalBytes)
        let normalizedAccepted = tooSmall.append(normalized)
        #expect(!normalizedAccepted && tooSmall.writes.isEmpty)
        #expect(tooSmall.failure?.reason == .bufferLimitExceeded)
        var exact = BrowserSessionWriteBuffer(maximumBytes: allBytes)
        let exactAccepted = exact.append(normalized)
        #expect(exactAccepted && exact.writes == [normalized] && exact.encodedBytes == allBytes)
        let duplicateAccepted = exact.append(normalized)
        #expect(duplicateAccepted && exact.writes.count == 1 && exact.encodedBytes == allBytes)
    }
}

@MainActor private func normalizedArchiveWrite(in f: ConfirmedCloseFixture) throws -> BrowserSessionWrite {
    let original = try #require(try f.store.loadSnapshotStrict())
    let originalTab = try #require(original.tabs.first { $0.id == "a" })
    let liveTab = BrowserTabSessionSnapshotTab(
        id: "a", urlString: "https://example.com/live-a", userTitleOverride: originalTab.userTitleOverride,
        spaceID: originalTab.spaceID, lastActivityTimestamp: originalTab.lastActivityTimestamp,
    )
    let projection = archiveProjectionSnapshot(original, tabs: original.tabs.map { $0.id == "a" ? liveTab : $0 })
    return BrowserSessionWrite(
        snapshot: archiveProjectionSnapshot(original, tabs: original.tabs.filter { $0.id != "a" }),
        origin: .local(syncMove: nil),
        archiveAction: .insert(.init(id: "archive-a", tab: liveTab, archivedAt: f.clock.now, title: "Live page")),
        archiveProjectionSnapshot: projection,
    )
}

private func archiveProjectionSnapshot(
    _ snapshot: BrowserTabSessionSnapshot, tabs: [BrowserTabSessionSnapshotTab],
) -> BrowserTabSessionSnapshot {
    .init(version: snapshot.version, spaces: snapshot.spaces, pinnedTabFolders: snapshot.pinnedTabFolders, tabs: tabs)
}
