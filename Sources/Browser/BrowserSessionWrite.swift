// MARK: - BrowserSessionWrite

/// One ordered persistence action. Remote projections must never become local
/// mutations merely because an earlier action needs to be retried.
struct BrowserSessionWrite: Equatable {
    enum Origin: Equatable {
        case local(syncMove: BrowserSyncMoveIntent?)
        case remoteProjection
    }

    let snapshot: BrowserTabSessionSnapshot
    let origin: Origin

    func validate() throws {
        if case .local(let syncMove) = origin, let syncMove,
           Set(syncMove.items).count != syncMove.items.count
        {
            throw BrowserSessionWriteError.duplicateMoveIDs
        }
    }
}

// MARK: - BrowserSessionWriteError

enum BrowserSessionWriteError: Error, Equatable {
    case duplicateMoveIDs
    case missingSnapshotURL
}
