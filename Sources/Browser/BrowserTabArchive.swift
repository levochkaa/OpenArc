import Foundation

// MARK: - BrowserTabArchiveEntry

/// A profile-local recovery record. Restoring creates a new tab identity; the
/// original identity can remain permanently deleted in the sync protocol.
struct BrowserTabArchiveEntry: Codable, Equatable {
    // MARK: Lifecycle

    init(id: String, tab: BrowserTabSessionSnapshotTab, archivedAt: TimeInterval, title: String? = nil) {
        self.id = id
        self.tab = tab
        self.archivedAt = archivedAt
        self.title = title
    }

    // MARK: Internal

    let id: String
    let tab: BrowserTabSessionSnapshotTab
    let archivedAt: TimeInterval
    let title: String?

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

// MARK: - BrowserTabArchiveAction

enum BrowserTabArchiveAction: Codable, Equatable {
    case insert(BrowserTabArchiveEntry)
    case restore(archiveID: String, tabID: String)
}

// MARK: - BrowserTabArchiveStoring

protocol BrowserTabArchiveStoring {
    func loadArchiveEntry(id: String) throws -> BrowserTabArchiveEntry?
    func loadArchivePage(before: BrowserTabArchiveCursor?, limit: Int) throws -> BrowserTabArchivePage
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
    case restoredTabIDNotFresh
    case unsupportedStore
    case requiresLocalWrite
}
