import Foundation

// MARK: - BrowserSyncExpiryOperation

/// Conditional intent only. It never carries a client cutoff or archive content.
struct BrowserSyncExpiryOperation: Codable, Equatable {
    // MARK: Lifecycle

    init(id: String, expectedServerSeq: Int, inactiveForSeconds: Int) {
        self.entityID = id
        self.expectedServerSeq = expectedServerSeq
        self.inactiveForSeconds = inactiveForSeconds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "expire",
              try values.decode(String.self, forKey: .entityType) == "tab"
        else { throw BrowserSyncExpiryError.invalidOperation }
        self.entityID = try values.decode(String.self, forKey: .entityID)
        self.expectedServerSeq = try values.decode(Int.self, forKey: .expectedServerSeq)
        self.inactiveForSeconds = try values.decode(Int.self, forKey: .inactiveForSeconds)
        try validate()
    }

    // MARK: Internal

    let entityID: String
    let expectedServerSeq: Int
    let inactiveForSeconds: Int

    func validate() throws {
        guard !entityID.isEmpty, expectedServerSeq > 0, expectedServerSeq <= 9_007_199_254_740_991,
              [43200, 86400, 259_200, 604_800, 2_592_000].contains(inactiveForSeconds)
        else { throw BrowserSyncExpiryError.invalidOperation }
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("expire", forKey: .kind)
        try values.encode("tab", forKey: .entityType)
        try values.encode(entityID, forKey: .entityID)
        try values.encode(expectedServerSeq, forKey: .expectedServerSeq)
        try values.encode(inactiveForSeconds, forKey: .inactiveForSeconds)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind, entityType, entityID, expectedServerSeq, inactiveForSeconds
    }
}

// MARK: - BrowserSyncExpiryMutation

struct BrowserSyncExpiryMutation: Codable, Equatable {
    let id: String
    let operations: [BrowserSyncExpiryOperation]

    func validate() throws {
        guard UUID(uuidString: id) != nil else { throw BrowserSyncQueueError.invalidMutationIdentity }
        guard !operations.isEmpty, operations.count <= 100,
              Set(operations.map(\.entityID)).count == operations.count
        else { throw BrowserSyncExpiryError.invalidOperation }
        for operation in operations {
            try operation.validate()
        }
    }
}

// MARK: - BrowserSyncExpiryError

enum BrowserSyncExpiryError: Error, Equatable {
    case invalidOperation
}

// MARK: - BrowserSyncExpiryPushRequest

struct BrowserSyncExpiryPushRequest: Encodable {
    let protocolVersion = 5
    let mutationID: String
    let deviceID: String
    let operations: [BrowserSyncExpiryOperation]
}

// MARK: - BrowserSyncExpiryOutcome

struct BrowserSyncExpiryOutcome: Codable, Equatable {
    enum Status: String, Codable { case applied, deleted, rejected }
    enum Reason: String, Codable {
        case missing
        case stateChanged = "state_changed"
        case notTemporary = "not_temporary"
        case activityUnknown = "activity_unknown"
        case notExpired = "not_expired"
        case responseLimit = "response_limit"
    }

    let operationIndex: Int
    let status: Status
    let reason: Reason?
}

// MARK: - BrowserSyncExpiryPushResponse

struct BrowserSyncExpiryPushResponse: Codable, Equatable {
    let protocolVersion: Int
    let mutationID: String
    let cursor: Int
    let events: [BrowserSyncEvent]
    let outcomes: [BrowserSyncExpiryOutcome]

    /// Validate at both transport and coordinator boundaries; injected transports
    /// must not bypass the receipt contract and consume an unrelated queue row.
    func validate(for mutation: BrowserSyncExpiryMutation) throws {
        try mutation.validate()
        guard protocolVersion == 5, mutationID == mutation.id, cursor >= 0,
              cursor <= 9_007_199_254_740_991,
              outcomes.count == mutation.operations.count,
              Set(outcomes.map(\.operationIndex)) == Set(mutation.operations.indices)
        else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        let requestedIDs = Set(mutation.operations.map(\.entityID))
        var canonical = [String: BrowserSyncEvent]()
        for event in events {
            guard event.entityType == "tab", requestedIDs.contains(event.entityID),
                  event.serverSeq > 0, event.serverSeq <= cursor,
                  canonical.updateValue(event, forKey: event.entityID) == nil
            else { throw BrowserRemoteSyncError.invalidMutationReceipt }
        }
        for outcome in outcomes {
            let operation = mutation.operations[outcome.operationIndex]
            let event = canonical[operation.entityID]
            switch outcome.status {
            case .applied, .deleted:
                guard outcome.reason == nil, let event, event.op == "delete",
                      case .deleted(let id, let recovery) = event.data, id == operation.entityID
                else { throw BrowserRemoteSyncError.invalidMutationReceipt }
                if outcome.status == .applied {
                    guard let recovery, recovery.sourceServerSeq == operation.expectedServerSeq else {
                        throw BrowserRemoteSyncError.invalidMutationReceipt
                    }
                    _ = try recovery.entry(event: event, id: mutation.id)
                }
            case .rejected:
                guard let reason = outcome.reason else { throw BrowserRemoteSyncError.invalidMutationReceipt }
                if reason == .responseLimit {
                    guard event == nil else { throw BrowserRemoteSyncError.invalidMutationReceipt }
                } else if let event {
                    guard event.op == "upsert", case .tab(let data) = event.data, data.id == operation.entityID else {
                        throw BrowserRemoteSyncError.invalidMutationReceipt
                    }
                }
            }
        }
    }
}
