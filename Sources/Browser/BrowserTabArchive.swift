// BrowserTabArchive.swift

import Foundation

// MARK: - BrowserTabArchiveEntry

/// A profile-local recovery record. Restoring creates a new tab identity; the
/// original identity can remain permanently deleted in the sync protocol.
struct BrowserTabArchiveEntry: Codable, Equatable {
    // MARK: Internal

    let id: String
    let tab: BrowserTabSessionSnapshotTab
    let archivedAt: TimeInterval
    let title: String?

    init(id: String, tab: BrowserTabSessionSnapshotTab, archivedAt: TimeInterval, title: String? = nil) {
        self.id = id
        self.tab = tab
        self.archivedAt = archivedAt
        self.title = title
    }

    func validate() throws {
        guard !id.isEmpty, let tabID = tab.id, !tabID.isEmpty,
              tab.placement == .temporary, !tab.urlString.isEmpty,
              archivedAt.isFinite
        else { throw BrowserTabArchiveError.invalidEntry }
    }
}

// MARK: - BrowserTabArchiveCursor

struct BrowserTabArchiveCursor: Equatable {
    let archivedAt: TimeInterval
    let id: String
}

// MARK: - BrowserTabArchivePage

struct BrowserTabArchivePage: Equatable {
    let entries: [BrowserTabArchiveEntry]
    let nextCursor: BrowserTabArchiveCursor?
}

// MARK: - BrowserTabArchiveBoundary

/// The durable insertion high-water mark, captured before Clear confirmation.
/// Wall-clock adjustments and later insertions cannot widen this scope.
struct BrowserTabArchiveBoundary: Equatable {
    let insertionSequence: Int64
}

// MARK: - BrowserTabArchiveAction

enum BrowserTabArchiveAction: Codable, Equatable {
    case insert(BrowserTabArchiveEntry)
    case restore(archiveID: String, tabID: String)
}

// MARK: - BrowserTabArchiveStoring

protocol BrowserTabArchiveStoring {
    func loadArchiveEntry(id: String) throws -> BrowserTabArchiveEntry?
    func loadArchivePage(before: BrowserTabArchiveCursor?, limit: Int) throws -> BrowserTabArchivePage
    nonisolated(nonsending) func searchArchivePage(
        query: String, before: BrowserTabArchiveCursor?, limit: Int,
    ) async throws -> BrowserTabArchivePage
    nonisolated(nonsending) func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary
    nonisolated(nonsending) func removeArchiveEntry(id: String) async throws -> Bool
    nonisolated(nonsending) func clearArchive(through boundary: BrowserTabArchiveBoundary) async throws -> Int
}

extension BrowserTabArchiveStoring {
    func loadArchivePage() throws -> BrowserTabArchivePage {
        try loadArchivePage(before: nil, limit: 50)
    }
}

// MARK: - BrowserTabArchiveError

enum BrowserTabArchiveError: Error, Equatable {
    case archiveAlreadyRestored
    case archiveIDConflict
    case entryMissing
    case invalidEntry
    case invalidTransition
    case invalidCursor
    case invalidLimit
    case invalidQuery
    case invalidBoundary
    case restoredTabIDNotFresh
    case unsupportedStore
    case requiresLocalWrite
}
