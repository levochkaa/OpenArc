// MARK: - BrowserSessionWrite

/// One ordered persistence action. Remote projections must never become local
/// mutations merely because an earlier action needs to be retried.
struct BrowserSessionWrite: Equatable {
    // MARK: Lifecycle

    init(
        snapshot: BrowserTabSessionSnapshot,
        origin: Origin,
        archiveAction: BrowserTabArchiveAction? = nil,
        archiveProjectionSnapshot: BrowserTabSessionSnapshot? = nil
    ) {
        self.snapshot = snapshot
        self.origin = origin
        self.archiveAction = archiveAction
        self.archiveProjectionSnapshot = archiveProjectionSnapshot
    }

    // MARK: Internal

    enum Origin: Equatable {
        case local(syncMove: BrowserSyncMoveIntent?)
        case remoteProjection
    }

    let snapshot: BrowserTabSessionSnapshot
    let origin: Origin
    let archiveAction: BrowserTabArchiveAction?
    /// Normalizes an unfinished engine projection before validating Archive's
    /// preimage. The Archive receipt also covers this write on every retry.
    let archiveProjectionSnapshot: BrowserTabSessionSnapshot?

    func validate() throws {
        if case .local(let syncMove) = origin, let syncMove,
           Set(syncMove.items).count != syncMove.items.count
        {
            throw BrowserSessionWriteError.duplicateMoveIDs
        }
        if archiveProjectionSnapshot != nil {
            guard case .local = origin else { throw BrowserTabArchiveError.requiresLocalWrite }
            guard case .insert? = archiveAction else { throw BrowserTabArchiveError.invalidTransition }
        }
        guard let archiveAction else { return }
        guard case .local = origin else { throw BrowserTabArchiveError.requiresLocalWrite }
        switch archiveAction {
        case .insert(let entry):
            try entry.validate()
            guard !snapshot.tabs.contains(where: { $0.id == entry.tab.id }) else {
                throw BrowserTabArchiveError.invalidTransition
            }
        case .restore(let archiveID, let tabID):
            guard !archiveID.isEmpty, !tabID.isEmpty,
                  snapshot.tabs.filter({ $0.id == tabID }).count == 1,
                  snapshot.tabs.first(where: { $0.id == tabID })?.placement == .temporary
            else { throw BrowserTabArchiveError.invalidTransition }
        }
    }
}

// MARK: - BrowserSessionWriteError

enum BrowserSessionWriteError: Error, Equatable {
    case duplicateMoveIDs
    case missingSnapshotURL
}
