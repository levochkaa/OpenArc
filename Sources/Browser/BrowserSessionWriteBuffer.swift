import Foundation

// MARK: - BrowserSessionPersistenceFailure

struct BrowserSessionPersistenceFailure: Equatable {
    enum Reason: Equatable {
        case writeFailed
        case mutationTooLarge
        case invalidMoveIntent
        case bufferLimitExceeded
        case snapshotEncodingFailed
    }

    let reason: Reason

    var isRetryable: Bool { reason == .writeFailed }
}

// MARK: - BrowserSessionWriteBuffer

/// Only failed writes are retained. A terminal limit never evicts an earlier
/// action or pretends the uncaptured tail can be recovered by retrying the FIFO.
struct BrowserSessionWriteBuffer {
    // MARK: Lifecycle

    init(maximumCount: Int = 32, maximumBytes: Int = 32 * 1024 * 1024) {
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }

    // MARK: Internal

    private(set) var writes = [BrowserSessionWrite]()
    private(set) var failure: BrowserSessionPersistenceFailure?
    private(set) var encodedBytes = 0

    var isTerminal: Bool { failure?.isRetryable == false }

    @discardableResult mutating func append(_ write: BrowserSessionWrite) -> Bool {
        guard !isTerminal else { return false }
        // Callback/closure retries of the exact same write add no new action.
        guard writes.last != write else { return true }
        guard writes.count < maximumCount else {
            failure = .init(reason: .bufferLimitExceeded)
            return false
        }
        do {
            let encoder = JSONEncoder()
            let archiveBytes = try write.archiveAction.map { try encoder.encode($0).count } ?? 0
            let size = try encoder.encode(write.snapshot).count + archiveBytes
            guard size <= maximumBytes - encodedBytes else {
                failure = .init(reason: .bufferLimitExceeded)
                return false
            }
            writes.append(write)
            encodedBytes += size
            return true
        } catch {
            failure = .init(reason: .snapshotEncodingFailed)
            return false
        }
    }

    mutating func recordFailure(_ error: Error) {
        guard !isTerminal else { return }
        failure =
            if error as? BrowserSyncQueueError == .mutationTooLarge {
                .init(reason: .mutationTooLarge)
            } else if error as? BrowserSessionWriteError == .duplicateMoveIDs {
                .init(reason: .invalidMoveIntent)
            } else {
                .init(reason: .writeFailed)
            }
    }

    mutating func clearAfterSuccess() {
        guard !isTerminal else { return }
        writes.removeAll()
        encodedBytes = 0
        failure = nil
    }

    // MARK: Private

    private let maximumCount: Int
    private let maximumBytes: Int
}
